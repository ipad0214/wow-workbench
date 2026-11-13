-- Smoke test for the addon outside the game: a stand-in for the WoW API calls the addon makes, then
-- login, import, looting, bank, mail between own characters, export and tooltip. It checks the addon's
-- own logic, not whether the real client behaves like the stand-in; that needs the in-game checklist.
-- Run from the repo root: lua test/addon/smoke.lua
local root = (arg and arg[0] or ""):match("^(.*)test/addon/smoke%.lua$") or "./"
unpack = unpack or table.unpack

-- ---------- stand-in WoW API ----------
local frames, events, prints = {}, {}, {}
local function mock(kind, name)
  local o = { kind = kind, name = name, shown = kind ~= "Frame" or true, scripts = {}, text = nil, checked = false, children = {} }
  o.shown = true
  frames[#frames + 1] = o
  local methods = {}
  function methods:Show() local was = self.shown; self.shown = true; if not was and self.scripts.OnShow then self.scripts.OnShow(self) end end
  function methods:Hide() self.shown = false end
  function methods:IsShown() return self.shown end
  function methods:SetScript(k, fn) self.scripts[k] = fn end
  function methods:GetScript(k) return self.scripts[k] end
  function methods:SetText(t) self.text = t end
  function methods:GetText() return self.text or "" end
  function methods:SetChecked(v) self.checked = v end
  function methods:GetChecked() return self.checked end
  function methods:RegisterEvent(e) events[e] = events[e] or {}; table.insert(events[e], self) end
  function methods:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
  function methods:CreateFontString() return mock("FontString") end
  function methods:CreateTexture() return mock("Texture") end
  function methods:AddLine(t) self.lines = self.lines or {}; table.insert(self.lines, t) end
  return setmetatable(o, { __index = function(_, k) return methods[k] or function() end end })
end
function CreateFrame(kind, name)
  local f = mock(kind, name)
  if kind == "Frame" and name then f.shown = true end
  if name then _G[name] = f end
  return f
end
local function fire(event, ...)
  for _, f in ipairs(events[event] or {}) do f.scripts.OnEvent(f, event, ...) end
end
UIParent, GameTooltip, ItemRefTooltip = mock("Frame"), mock("GameTooltip"), mock("GameTooltip")
UISpecialFrames, SlashCmdList, tinsert = {}, {}, table.insert
ChatFontNormal = {}
ITEM_QUALITY_COLORS = { [1] = { r = 1, g = 1, b = 1 } }
function print(...) local t = {}; for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end; table.insert(prints, table.concat(t, " ")) end
time, date = os.time, os.date
C_Timer = { After = function(_, fn) fn() end }
function UnitName() return "Ulfrik" end
function GetRealmName() return "Everlook" end
function hooksecurefunc(a, b, c)
  local t, name, fn = _G, a, b
  if type(a) == "table" then t, name, fn = a, b, c end
  local orig = t[name]
  t[name] = function(...) local r = { orig(...) }; fn(...); return unpack(r) end
end
Enum = {
  BagIndex = { Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4, ReagentBag = 5, Bankbag = -4,
    CharacterBankTab_1 = 6, CharacterBankTab_2 = 7, AccountBankTab_1 = 12 },
  PlayerInteractionType = { Banker = 8, MailInfo = 17, AccountBanker = 68 },
  TooltipDataType = { Item = 0 },
}
local tooltipCallback
TooltipDataProcessor = { AddTooltipPostCall = function(_, fn) tooltipCallback = fn end }
local names = { [2770] = "Kupfererz", [2840] = "Kupferbarren", [2851] = "Kupferkettengürtel", [2320] = "Grober Faden" }
C_Item = {
  GetItemNameByID = function(id) return names[id] end,
  GetItemIconByID = function() return 134400 end,
  GetItemQualityByID = function() return 1 end,
  RequestLoadItemDataByID = function() end,
}
-- containers: bag -> { {id, count}, … }; bank containers only readable while "open"
local containers, bankReadable = { [0] = { { 2770, 3 }, { 6948, 1 } }, [1] = {} }, false
local function isBank(bag) return bag >= 6 end
C_Container = {
  GetContainerNumSlots = function(bag)
    if isBank(bag) and not bankReadable then return 0 end
    return containers[bag] and 16 or 0
  end,
  GetContainerItemInfo = function(bag, slot)
    local s = containers[bag] and containers[bag][slot]
    if s then return { itemID = s[1], stackCount = s[2] } end
  end,
}
local inbox, sendItems = {}, {}
function GetInboxNumItems() return #inbox end
function GetInboxItem(i, a) local m = inbox[i]; if m and a == 1 then return "x", m[1], 0, m[2] end end
function GetSendMailItem(a) local s = sendItems[a]; if s then return "x", s[1], 0, s[2] end end
function SendMail() end
ATTACHMENTS_MAX_RECEIVE, ATTACHMENTS_MAX_SEND = 16, 12

-- ---------- load the addon like the client (TOC order, shared namespace) ----------
local ns = {}
for line in io.lines(root .. "addon/Werkbank/Werkbank.toc") do
  if line:match("%.lua$") then assert(loadfile(root .. "addon/Werkbank/" .. line))("Werkbank", ns) end
end
-- Ränka logged in with the addon once before
WerkbankDB = { chars = { ["Everlook-Ränka"] = { name = "Ränka", realm = "Everlook", at = 1, bags = { [2840] = 2 }, transit = {} } } }

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then passed = passed + 1 else failed = failed + 1; print_ = io.write("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "") .. "\n") end
end
local function frameNamed(n) for _, f in ipairs(frames) do if f.name == n then return f end end end
local function buttonWithText(t) for _, f in ipairs(frames) do if f.kind == "Button" and f.text == t then return f end end end

-- ---------- login ----------
fire("PLAYER_LOGIN")
local db = WerkbankDB
check("own character created", db.chars["Everlook-Ulfrik"] ~= nil)
check("bags scanned at login", db.chars["Everlook-Ulfrik"].bags[2770] == 3)
check("no export work on every login", db.export == nil)

-- ---------- import a list: Ulfrik mines + smelts + crafts 2 belts (6 bars each) ----------
SlashCmdList.WERKBANK("import")
local import = frameNamed("WerkbankImport")
check("import window open", import and import.shown)
local body = "WB1;1763000000;Ulfrik,Ränka;2851:2;2851:1:0:0:2840*6,2840:1:0:0:2770*1;2770:M:0"
local editBox
for _, f in ipairs(frames) do if f.kind == "EditBox" then editBox = f; break end end
editBox:SetText("kaputt")
buttonWithText("Übernehmen").scripts.OnClick()
check("bad text rejected with a message", import.shown and (import.msg.text or ""):find("Kein Werkbank"), import.msg.text)
editBox:SetText(body .. ";\n" .. ns.Codec.checksum(body))
buttonWithText("Übernehmen").scripts.OnClick()
check("good text accepted", not import.shown and db.list ~= nil, import.msg.text)
local main = frameNamed("WerkbankFrame")
check("list window opens after import", main and main.shown)

-- 12 bars needed, Ränka has 2 -> 10 bars to smelt, 10 ore, Ulfrik has 3
local e = ns.Core.byId[2770]
check("ore netted: 3 of 10", e and e.need == 10 and e.have == 3, e and (e.have .. "/" .. e.need))
local rowsText = {}
for _, f in ipairs(frames) do if f.kind == "FontString" and f.text then rowsText[#rowsText + 1] = f.text end end
local all = table.concat(rowsText, "\n")
check("window shows the farm section", all:find("Farmen", 1, true))
check("window shows ore 3/10", all:find("3/10", 1, true), all)
check("window shows craft rows with what's left", all:find("noch 10×", 1, true), all)

-- ---------- looting: 7 more ore -> ore row done, chat message ----------
containers[0][1] = { 2770, 10 }
fire("BAG_UPDATE_DELAYED")
check("ore complete after looting", ns.Core.byId[2770].have == 10)
check("chat message for the completed row", prints[#prints] and prints[#prints]:find("Kupfererz vollständig", 1, true), prints[#prints])

-- ---------- bank: only read while open ----------
containers[6] = { { 2840, 4 } }
fire("PLAYERBANKSLOTS_CHANGED")
check("closed bank is not read", db.chars["Everlook-Ulfrik"].bank == nil)
bankReadable = true
fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.Banker)
check("bank read when opened", db.chars["Everlook-Ulfrik"].bank and db.chars["Everlook-Ulfrik"].bank[2840] == 4)
bankReadable = false
fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", Enum.PlayerInteractionType.Banker)
fire("BAG_UPDATE_DELAYED")
check("bank kept after closing", db.chars["Everlook-Ulfrik"].bank[2840] == 4)
check("bank bars reduce the bars to smelt", ns.Core.byId[2840].have == 6, ns.Core.byId[2840].have)

-- ---------- mail: Ulfrik sends 3 ore to Ränka; they leave the bags but stay counted ----------
local before = ns.Core.pool()[2770]
sendItems = { { 2770, 3 } }
SendMail("Ränka", "Erz", "")
containers[0][1] = { 2770, 7 }
fire("MAIL_SEND_SUCCESS")
fire("BAG_UPDATE_DELAYED")
check("mail to an own character counts as on its way", #db.chars["Everlook-Ränka"].transit == 1)
check("total ore unchanged while the mail travels", ns.Core.pool()[2770] == before, ns.Core.pool()[2770])
sendItems = { { 2770, 1 } }
SendMail("Fremder", "", "")
fire("MAIL_SEND_SUCCESS")
check("mail to someone else is not counted", ns.Core.pool()[2770] == before)
SendMail("Ränka-Anderswo", "", "")
fire("MAIL_SEND_SUCCESS")
check("mail to a same-named character on another realm is not counted", ns.Core.pool()[2770] == before)
SendMail("ränka-Everlook", "", "")
fire("MAIL_SEND_SUCCESS")
check("mail with the own realm spelled out is counted", #db.chars["Everlook-Ränka"].transit == 2)
db.chars["Everlook-Ränka"].transit[2] = nil
fire("BAG_UPDATE_DELAYED")
-- mailbox of the current character
inbox = { { 2840, 1 } }
fire("MAIL_INBOX_UPDATE")
check("inbox not read while the mailbox is closed", db.chars["Everlook-Ulfrik"].mail == nil)
fire("MAIL_SHOW")
fire("MAIL_INBOX_UPDATE")
check("inbox read while open", db.chars["Everlook-Ulfrik"].mail and db.chars["Everlook-Ulfrik"].mail[2840] == 1)
fire("MAIL_CLOSED")

-- ---------- export ----------
SlashCmdList.WERKBANK("export")
local export = frameNamed("WerkbankExport")
check("export window open", export and export.shown)
check("export holds the WC1 string", db.export:match("^WC1;%d+;.*;[0-9a-z]+$"), db.export)
check("export lists both characters", db.export:find("Ränka:", 1, true) and db.export:find("Ulfrik:", 1, true))
check("export only holds items of the list", not db.export:find("6948", 1, true), db.export)
local f = io.open(os.getenv("WC1_OUT") or "/dev/null", "w"); if f then f:write(db.export); f:close() end

-- ---------- tooltip ----------
GameTooltip.lines = {}
tooltipCallback(GameTooltip, { id = 2770 })
check("tooltip line for list items", GameTooltip.lines[1] and GameTooltip.lines[1]:find("Werkbank", 1, true), GameTooltip.lines[1])
GameTooltip.lines = {}
tooltipCallback(GameTooltip, { id = 6948 })
check("no tooltip line for other items", #GameTooltip.lines == 0)
tooltipCallback(GameTooltip, { id = setmetatable({}, { __index = function() error("secret") end }) })
check("odd tooltip data doesn't break", true)

-- ---------- filter and logout ----------
main.only.checked = true
main.only.scripts.OnClick(main.only)
check("filter 'nur Ulfrik' saved", db.ui.onlyMe == true)
db.export = nil
fire("PLAYER_LOGOUT")
check("export written at logout and /reload", db.export and db.export:sub(1, 4) == "WC1;")

print_ = io.write(string.format("%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
