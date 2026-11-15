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
  function methods:SetEnabled(v) self.enabled = v end
  function methods:GetFrameLevel() return rawget(self, "level") or 1 end
  function methods:SetFrameLevel(v) self.level = v end
  function methods:RegisterEvent(e) events[e] = events[e] or {}; table.insert(events[e], self) end
  function methods:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
  function methods:CreateFontString() local f = mock("FontString"); f.parentFrame = self; return f end
  function methods:CreateTexture() return mock("Texture") end
  function methods:AddLine(t) self.lines = self.lines or {}; table.insert(self.lines, t) end
  return setmetatable(o, { __index = function(_, k) return methods[k] or function() end end })
end
function CreateFrame(kind, name, parent)
  local f = mock(kind, name)
  f.parentFrame = parent
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

-- the character and its professions (the modern calls; the classic ones are tried further down)
local profsNow = { { "Bergbau", 186, 300, 300 }, { "Schmiedekunst", 164, 285, 300 } }
function UnitClass() return "Paladin", "PALADIN", 2 end
function UnitRace() return "Zwerg", "Dwarf", 3 end
function UnitFactionGroup() return "Alliance" end
function UnitLevel() return 60 end
function GetBuildInfo() return "1.16.0", "64000", "Nov 1 2026", 16001 end
-- like the client: prof1, prof2, archaeology, fishing, cooking, first aid, with gaps
function GetProfessions() return profsNow[1] and 1, profsNow[2] and 2, nil, nil, profsNow[3] and 3 end
function GetProfessionInfo(i) local p = profsNow[i]; return p[1], 0, p[3], p[4], 0, 0, p[2] end
-- the open profession window: recipe id -> { learned, output item }
local trade = { line = 164, name = "Schmiedekunst", linked = false, recipes = {
  [2661] = { true, 2851 },     -- Kupferkettengürtel
  [2660] = { true, 2862 },     -- Rauer Wetzstein
  [9999] = { false, 1234 },    -- not learned yet
} }
C_TradeSkillUI = {
  GetAllRecipeIDs = function() local t = {}; for id in pairs(trade.recipes) do t[#t + 1] = id end; return t end,
  GetRecipeInfo = function(id) return { learned = trade.recipes[id][1] } end,
  -- recipes[id][3]: more of the schematic; output false: the client can't describe the recipe
  GetRecipeSchematic = function(id)
    local r = trade.recipes[id]
    if not r or r[2] == false then return nil end
    local s = r[3] or {}
    s.outputItemID = r[2]
    return s
  end,
  GetBaseProfessionInfo = function() return { professionID = trade.line, professionName = trade.name } end,
  IsTradeSkillLinked = function() return trade.linked end,
}

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
local prof = db.chars["Everlook-Ulfrik"].profile
check("profile read at login", prof and prof.class == "Paladin" and prof.race == "Zwerg" and prof.faction == "Alliance" and prof.level == 60)
check("professions mapped by skill line", prof.profs["Bergbau"][1] == 300 and prof.profs["Schmiedekunst"][1] == 285
  and prof.profs["Schmiedekunst"][2] == 300)
check("recipe database loaded", #ns.Data.recipes == 1232 and ns.Data.items[2851] ~= nil)

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
check("good text accepted", not import.shown and db.shop[1] and db.shop[1].item == 2851 and db.shop[1].qty == 2, import.msg.text)
check("the import is planned in the addon", ns.Core.list().crafts[2851].c == 0 and ns.Core.list().chars[1] == "Ulfrik")
local main = frameNamed("WerkbankFrame")
check("list window opens after import", main and main.shown)

-- 12 bars needed, Ränka has 2 -> 10 bars to smelt, 10 ore, Ulfrik has 3
local e = ns.Core.byId[2770]
check("ore netted: 3 of 10", e and e.need == 10 and e.have == 3, e and (e.have .. "/" .. e.need))
-- everything the window shows right now
local function texts()
  local t = {}
  for _, f in ipairs(frames) do if f.kind == "FontString" and f.text then t[#t + 1] = f.text end end
  return table.concat(t, "\n")
end
local all = texts()
-- what the list window shows right now: the texts of its visible rows
local function windowText()
  local t = {}
  for _, f in ipairs(frames) do
    local row = f.parentFrame
    if f.kind == "FontString" and f.text and f.text ~= "" and row and row.shown and row.parentFrame == main.content then t[#t + 1] = f.text end
  end
  return table.concat(t, "\n")
end
-- the window on tab "Charaktere" (fn checks it), then back on "Liste"
local function onCharsTab(fn)
  buttonWithText("Charaktere").scripts.OnClick()
  assert(main.shown, "onCharsTab: the list window must be open"); fn(windowText())
  buttonWithText("Liste").scripts.OnClick()
end
check("window shows the farm section", all:find("Farmen", 1, true))
check("window shows ore 3/10", all:find("3/10", 1, true), all)
check("window shows craft rows with what's left", all:find("noch 10×", 1, true), all)
check("tab 'Liste' leaves the characters out", not windowText():find("Stufe 60", 1, true) and windowText():find("Farmen", 1, true), windowText())
onCharsTab(function(w)
  check("tab 'Charaktere' lists the characters", w:find("Charaktere", 1, true) and w:find("Stufe 60", 1, true) and not w:find("Farmen", 1, true), w)
  check("with their skill points", w:find("Schmiedekunst", 1, true) and w:find("285/300", 1, true), w)
  check("and asks to open the profession window", w:find("Fenster öffnen", 1, true), w)
  check("the list's own controls are hidden there", not main.only.shown and not main.clear.shown and main.tracker.shown)
  check("the tab is remembered", db.ui.tab == "chars")
end)
check("back on 'Liste' its controls are back", main.only.shown and main.clear.shown and db.ui.tab == "list")

-- ---------- the tracker on the screen edge ----------
local tracker = frameNamed("WerkbankTracker")
-- the shown texts of the tracker and its heading, top to bottom as created
local function trackerText()
  local t = {}
  for _, f in ipairs(frames) do
    local p = f.parentFrame
    if f.kind == "FontString" and f.shown and f.text and (p == tracker or (p and p.parentFrame == tracker)) then t[#t + 1] = f.text end
  end
  return table.concat(t, "\n")
end
local function trackerHeader() for _, f in ipairs(frames) do if f.kind == "Button" and f.parentFrame == tracker then return f end end end
check("tracker shows up with a list", tracker and tracker.shown)
local tt = trackerText()
check("tracker names the character", tt:find("Werkbank · Ulfrik", 1, true), tt)
check("tracker lists what to farm and craft", tt:find("Farmen", 1, true) and tt:find("Kupfererz", 1, true) and tt:find("3/10", 1, true)
  and tt:find("noch 10×", 1, true), tt)
check("tracker says where the items lie: own bags first, without a name", tt:find("Taschen 3", 1, true), tt)
check("and other characters by name", tt:find("Ränka: Taschen 2", 1, true), tt)
trackerHeader().scripts.OnClick(trackerHeader(), "LeftButton")
check("left click on the heading folds it", not trackerText():find("Kupfererz", 1, true) and trackerText():find("Werkbank", 1, true))
trackerHeader().scripts.OnClick(trackerHeader(), "LeftButton")
check("and unfolds it", trackerText():find("Kupfererz", 1, true))
-- Ränka mines (earlier in the name order than Ulfrik, so ore and smelting go to her): off Ulfrik's tracker
db.chars["Everlook-Ränka"].profile = { profs = { Bergbau = { 300, 300 } }, recipes = {} }
ns.Core.update(true)
local tt2 = trackerText()
check("rows of another character stay off the tracker", not tt2:find("Kupfererz", 1, true) and not tt2:find("Kupferbarren", 1, true)
  and tt2:find("Kupferkettengürtel", 1, true) and texts():find("Kupfererz", 1, true), tt2)
db.chars["Everlook-Ränka"].profile = nil
ns.Core.update(true)
SlashCmdList.WERKBANK("tracker")
check("/werkbank tracker hides it", not tracker.shown and db.ui.tracker.hidden and main.tracker.checked == false)
main.tracker.checked = true
main.tracker.scripts.OnClick(main.tracker)
check("the checkbox in the window shows it again", tracker.shown and not db.ui.tracker.hidden)

-- ---------- looting: 7 more ore -> ore row done, chat message ----------
containers[0][1] = { 2770, 10 }
fire("BAG_UPDATE_DELAYED")
check("ore complete after looting", ns.Core.byId[2770].have == 10)
check("chat message for the completed row", prints[#prints] and prints[#prints]:find("Kupfererz vollständig", 1, true), prints[#prints])
check("tracker: a done row turns green with a check mark", trackerText():find("|cff40c040Kupfererz", 1, true)
  and trackerText():find("ReadyCheck-Ready", 1, true), trackerText())

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
check("where: bags and bank of the current character", ns.Core.whereText(2840) == "Bank 4 · Ränka: Taschen 2", ns.Core.whereText(2840))

-- ---------- mail: Ulfrik sends 3 ore to Ränka; they leave the bags but stay counted ----------
local before = ns.Core.pool()[2770]
sendItems = { { 2770, 3 } }
SendMail("Ränka", "Erz", "")
containers[0][1] = { 2770, 7 }
fire("MAIL_SEND_SUCCESS")
fire("BAG_UPDATE_DELAYED")
check("mail to an own character counts as on its way", #db.chars["Everlook-Ränka"].transit == 1)
check("total ore unchanged while the mail travels", ns.Core.pool()[2770] == before, ns.Core.pool()[2770])
check("where: mail on its way", ns.Core.whereText(2770):find("Ränka: unterwegs 3", 1, true), ns.Core.whereText(2770))
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
check("where: the mailbox", ns.Core.whereText(2840) == "Bank 4, Post 1 · Ränka: Taschen 2", ns.Core.whereText(2840))
db.account = { at = 1, items = { [2840] = 5 } }
check("where: the account bank last", ns.Core.whereText(2840):find("Ränka: Taschen 2 · Kriegsmeutenbank 5", 1, true), ns.Core.whereText(2840))
db.account = nil
check("where: nothing owned", ns.Core.whereText(2851) == "")
fire("MAIL_CLOSED")

-- ---------- profiles: learned recipes, skill changes, the classic calls ----------
fire("TRADE_SKILL_SHOW")
local bs = prof.recipes["Schmiedekunst"]
check("learned recipes saved by product", bs and bs.known[2851] and bs.known[2862])
check("recipes not learned yet are left out", not bs.known[1234])
onCharsTab(function(w) check("window counts the database's recipes", w:find("2/240 Rezepte", 1, true), w) end)
trade.linked, trade.recipes[9999][1] = true, true
fire("TRADE_SKILL_LIST_UPDATE")
check("a linked profession is not saved as own", not prof.recipes["Schmiedekunst"].known[1234])
trade.linked = false
trade.recipes[2661][1] = false   -- a window that is still filling in, or filtered
fire("TRADE_SKILL_LIST_UPDATE")
check("a partial read adds and keeps the rest", bs.known[1234] and bs.known[2851])
for _, r in pairs(trade.recipes) do r[1] = false end
fire("TRADE_SKILL_LIST_UPDATE")
check("an empty read keeps the recipes", bs.known[2851] and bs.known[2862])
-- Enchanting: the database knows enchants by -spell id, even when the client names a scroll as output
profsNow[3] = { "Verzauberkunst", 333, 40, 75 }
fire("SKILL_LINES_CHANGED")
check("new profession after SKILL_LINES_CHANGED", prof.profs["Verzauberkunst"] and prof.profs["Verzauberkunst"][1] == 40)
trade.line, trade.name, trade.recipes = 333, "Verzauberkunst", { [7418] = { true, 38679 } }
fire("TRADE_SKILL_SHOW")
local ench = prof.recipes["Verzauberkunst"]
check("enchant saved under its negative spell id and its output", ench and ench.known[-7418] and ench.known[38679])
profsNow[3] = nil
profsNow[2] = { "Schmiedekunst", 164, 286, 300 }
fire("SKILL_LINES_CHANGED")
check("skill point gain saved", prof.profs["Schmiedekunst"][1] == 286)
check("a dropped profession takes its recipes", not prof.profs["Verzauberkunst"] and not prof.recipes["Verzauberkunst"])
check("the other professions keep their recipes", prof.recipes["Schmiedekunst"].known[2851])
onCharsTab(function(w) check("a character without profile is listed", w:find("Ränka", 1, true), w) end)

-- the classic calls, for a client without GetProfessions / C_TradeSkillUI
local modernProfs, modernTrade = GetProfessions, C_TradeSkillUI
GetProfessions, C_TradeSkillUI = nil, nil
local skills = { { "Berufe", true }, { "Skinning", false, 120, 150 }, { "Schwerter", false, 300, 300 }, { "Schneiderei", false, 75, 150 } }
function GetNumSkillLines() return #skills end
function GetSkillLineInfo(i) local x = skills[i]; return x[1], x[2], nil, x[3], 0, 0, x[4] end
local cp, _, via = ns.Profile.readProfessions()
check("classic skill list read by name", via == "GetSkillLineInfo" and cp["Kürschnerei"][1] == 120 and cp["Schneiderei"][2] == 150)
check("weapon skills are not professions", cp["Schwerter"] == nil)
local tradeRows = { { "Stoff", "header" }, { "Leinenbeutel", "easy", "|Hitem:4238::::|h[Leinenbeutel]|h" } }
function GetNumTradeSkills() return #tradeRows end
function GetTradeSkillInfo(i) return tradeRows[i][1], tradeRows[i][2] end
function GetTradeSkillItemLink(i) return tradeRows[i][3] end
function GetTradeSkillLine() return "Schneiderei", 75, 150 end
local craftRows = { { "Armschiene - Schwache Gesundheit", "", "optimal", "|Henchant:7418|h[Armschiene]|h" } }
function GetNumCrafts() return #craftRows end
function GetCraftInfo(i) return craftRows[i][1], craftRows[i][2], craftRows[i][3] end
function GetCraftItemLink(i) return craftRows[i][4] end
function GetCraftDisplaySkillLine() return "Verzauberkunst", 40, 75 end
fire("TRADE_SKILL_SHOW")
check("classic trade skill window read", prof.recipes["Schneiderei"] and prof.recipes["Schneiderei"].known[4238])
fire("CRAFT_SHOW")
check("classic enchanting window read", prof.recipes["Verzauberkunst"] and prof.recipes["Verzauberkunst"].known[-7418])
GetProfessions, C_TradeSkillUI = modernProfs, modernTrade
GetNumSkillLines, GetSkillLineInfo = nil, nil

local printed = #prints
SlashCmdList.WERKBANK("debug")
local out = table.concat(prints, "\n", printed + 1)
check("/werkbank debug names the client and the skill lines", out:find("Interface 16001", 1, true) and out:find("Skill-Linie 164", 1, true), out)
check("/werkbank debug reports the last recipe read", out:find("Rezepte über GetCraftInfo: Verzauberkunst", 1, true)
  and out:find("1 von 151", 1, true), out)

-- ---------- the profession window: "Auf die Werkbank" and "Werkbank" ----------
local function shownButton(t)
  for _, f in ipairs(frames) do if f.kind == "Button" and f.text == t and f.shown then return f end end
end
local selected, qtyBox = 2661, 3
trade.line, trade.name = 164, "Schmiedekunst"
-- 99999: a WoW Forever recipe (Leitstein): not in the database, 1 from 2 Rauer Stein + 1 Kupferbarren
-- 88888: one the client can't describe either
trade.recipes = { [2661] = { true, 2851 }, [2660] = { true, 2862 }, [88888] = { true, false },
  [99999] = { true, 77777, { quantityMin = 1, reagentSlotSchematics = {
    { reagentType = 1, quantityRequired = 2, reagents = { { itemID = 2835 } } },
    { reagentType = 1, quantityRequired = 1, reagents = { { itemID = 2840 } } },
    { reagentType = 0, quantityRequired = 1, reagents = { { itemID = 6948 } } },   -- optional: left out
  } } } }
local page = mock("Frame")
page.SchematicForm = { GetRecipeInfo = function() return selected and { recipeID = selected } end }
page.CreateMultipleInputBox = { GetValue = function() return qtyBox end }
page.CreateAllButton = mock("Button")
ProfessionsFrame = { CraftingPage = page }
fire("ADDON_LOADED", "Blizzard_Professions")
local addBtn = buttonWithText("Auf die Werkbank")
check("buttons in the profession window", addBtn and buttonWithText("Werkbank"))
check("the note says the selected recipe is on the list", texts():find("Auf der Werkbank: 2×", 1, true), texts())
addBtn.scripts.OnClick()
check("selected recipe added with the window's quantity", #db.shop == 1 and db.shop[1].qty == 5, db.shop[1].qty)
check("note updated after adding", texts():find("Auf der Werkbank: 5×", 1, true))
check("chat line for the added recipe", prints[#prints]:find("5× auf der Werkbank", 1, true), prints[#prints])
selected, qtyBox = 2660, 1
fire("TRADE_SKILL_SHOW")
check("no note for a recipe that isn't on the list", not texts():find("Auf der Werkbank: 5×", 1, true))
addBtn.scripts.OnClick()
check("another recipe becomes a new entry", #db.shop == 2 and db.shop[2].item == 2862 and db.shop[2].qty == 1)
check("its craft is planned", ns.Core.list().crafts[2862] ~= nil)
check("the note is drawn above the window's panels", rawget(addBtn, "level") and addBtn.level > 1)
selected = 88888
fire("TRADE_SKILL_SHOW")
check("a recipe nobody can describe is marked", texts():find("Nicht in der Werkbank-Datenbank", 1, true) and addBtn.enabled == false)
addBtn.scripts.OnClick()
check("and not added", #db.shop == 2 and prints[#prints]:find("kennt die Werkbank nicht", 1, true), prints[#prints])
selected = 99999
fire("TRADE_SKILL_SHOW")
check("a recipe only the game knows is taken from it", db.extra[99999] and db.extra[99999].item == 77777 and addBtn.enabled == true)
local ex = db.extra[99999]
check("with its basic reagents only", #ex.reag == 2 and ex.reag[1][1] == 2835 and ex.reag[1][2] == 2 and ex.reag[2][1] == 2840)
addBtn.scripts.OnClick()
check("and added", #db.shop == 3 and db.shop[3].item == 77777)
local k77 = ns.Core.list().crafts[77777]
check("and planned: crafted by Ulfrik from its reagents", k77 and k77.c == 0 and k77.reag[1][1] == 2835)
check("its reagents are planned too", ns.Core.list().crafts[2840] and ns.Core.list().raws[2835])
table.remove(db.shop, 3); ns.Core.update(true)
selected = 2661
main:Hide()
buttonWithText("Werkbank").scripts.OnClick()
check("'Werkbank' opens the list window", main.shown)
check("the window lists the entries", texts():find("Liste", 1, true) and texts():find("5×", 1, true), texts())
shownButton("+").scripts.OnClick()
check("+ adds one", db.shop[1].qty == 6, db.shop[1].qty)
check("the profession window's note follows the list window", texts():find("Auf der Werkbank: 6×", 1, true))
shownButton("-").scripts.OnClick()
check("- takes one", db.shop[1].qty == 5)
local xs = {}
for _, f in ipairs(frames) do if f.kind == "Button" and f.text == "x" and f.shown then xs[#xs + 1] = f end end
xs[2].scripts.OnClick()
check("x removes the entry", #db.shop == 1 and db.shop[1].item == 2851)
check("mail line uses a character the font has", not texts():find("→", 1, true))

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

-- ---------- clearing the list ----------
buttonWithText("Liste leeren").scripts.OnClick()
check("'Liste leeren' empties the list", #db.shop == 0 and ns.Core.list() == nil)
check("the window explains how to fill it", texts():find("Auf die Werkbank“ klicken", 1, true))
check("no list, no tracker", not tracker.shown)

-- ---------- the list of addon 1.0 is taken over once ----------
local ns2 = {}
for line in io.lines(root .. "addon/Werkbank/Werkbank.toc") do
  if line:match("%.lua$") then assert(loadfile(root .. "addon/Werkbank/" .. line))("Werkbank", ns2) end
end
WerkbankDB = { list = body .. ";" .. ns.Codec.checksum(body), chars = {} }
fire("PLAYER_LOGIN")
check("an old WB1 list becomes the shopping list", WerkbankDB.list == nil and WerkbankDB.shop[1] and WerkbankDB.shop[1].item == 2851)
-- next login: the recipe read from the game is there again, an entry with a stale index finds it
WerkbankDB = { chars = {}, extra = { [99999] = ex }, shop = { { item = 77777, r = 1, qty = 2 } } }
fire("PLAYER_LOGIN")
local r = WerkbankDB.shop[1] and WerkbankDB.shop[1].r
check("saved game recipes come back on login", r and ns2.Data.recipes[r][1] == 77777 and ns2.Data.byProf["Schmiedekunst"][#ns2.Data.byProf["Schmiedekunst"]] == r)

print_ = io.write(string.format("%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
