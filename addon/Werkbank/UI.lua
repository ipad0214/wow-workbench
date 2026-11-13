-- Werkbank addon: the list window (/werkbank), import and export boxes, and the tooltip line.
local _, ns = ...
local UI = {}
ns.UI = UI

local ROW_H, WIDTH = 18, 360
local GROUP = { H = "Kräuterkunde", M = "Bergbau", S = "Kürschnerei", F = "Angeln", D = "Entzaubern",
  C = "Stoff", V = "Händler", X = "Drop / AH", AH = "AH / Handwerker" }
local BUY = { V = true, AH = true, X = true, C = true }
local ACCENT = "|cffe08a3c"
local main, importBox, exportBox
local rows = {}
local namesMissing, refreshQueued = false, false

-- ---------- items ----------
function UI.itemName(id)
  if id < 0 then
    local n = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(-id)
    return n or ("Zauber " .. -id)
  end
  local n = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
  if not n then
    namesMissing = true
    if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
  end
  return n or ("Item " .. id)
end
local function itemIcon(id)
  if id < 0 then return C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(-id) or 134400 end
  return C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id) or 134400
end
local function qualityColor(id)
  local q = id > 0 and C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c then return c.r, c.g, c.b end
  return 1, 1, 1
end
-- "34/60" in red, yellow or green
local function progress(have, need)
  local color = (have >= need and "|cff40c040") or (have > 0 and "|cffe0c040") or "|cffd06060"
  return string.format("%s%d/%d|r", color, have, need)
end

-- ---------- windows ----------
local function title(f, text)
  local t = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  t:SetPoint("TOP", 0, -5)
  t:SetText(text)
  return t
end
local function movable(f, key)
  f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if key then
      local point, _, rel, x, y = self:GetPoint()
      ns.Core.db().ui[key] = { point, rel, x, y }
    end
  end)
end

local function getRow(i)
  if rows[i] then return rows[i] end
  local r = CreateFrame("Button", nil, main.content)
  r:SetHeight(ROW_H)
  -- both anchors at the top: a plain RIGHT anchor would pull every row to the content's middle
  r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  r:SetPoint("TOPRIGHT", main.content, "TOPRIGHT", 0, -(i - 1) * ROW_H)
  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(16, 16); r.icon:SetPoint("LEFT", 2, 0)
  r.count = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.count:SetPoint("RIGHT", -2, 0); r.count:SetWidth(62); r.count:SetJustifyH("RIGHT")
  r.who = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  r.who:SetPoint("RIGHT", r.count, "LEFT", -4, 0); r.who:SetWidth(96); r.who:SetJustifyH("RIGHT")
  r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.name:SetPoint("LEFT", r.icon, "RIGHT", 4, 0); r.name:SetPoint("RIGHT", r.who, "LEFT", -4, 0)
  r.name:SetJustifyH("LEFT"); r.name:SetWordWrap(false)
  r:SetScript("OnEnter", function(self)
    if not self.itemID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if self.itemID > 0 then GameTooltip:SetItemByID(self.itemID) else GameTooltip:SetSpellByID(-self.itemID) end
    if self.extra then GameTooltip:AddLine(self.extra, 0.8, 0.8, 0.8, true) end
    GameTooltip:Show()
  end)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  rows[i] = r
  return r
end

-- the rows of the window: section headers, items, crafts, mail
local function buildLines()
  local Core = ns.Core
  local S, R = Core.list(), Core.result()
  local out = {}
  if not S or not R then
    out[1] = { header = "Noch keine Liste." }
    out[2] = { text = "Auf der Werkbank-Seite „Für Addon kopieren“," }
    out[3] = { text = "dann hier /werkbank import und Strg+V." }
    return out
  end
  local my, only = Core.myIndex(), Core.db().ui.onlyMe
  local function who(i) return i >= 0 and S.chars[i + 1] or "Niemand" end
  local function rank(i) return (i == my and -1) or (i >= 0 and i) or 999 end
  local function mine(i) return not only or i == my end
  local farm, buy, crafts, mail = {}, {}, {}, {}
  for n, f in ipairs(R.farm) do
    if mine(f.o) then
      local t = BUY[f.g] and buy or farm
      t[#t + 1] = { id = f.id, o = f.o, need = f.need, have = f.have, tag = GROUP[f.g], name = UI.itemName(f.id), n = n }
    end
  end
  for n, s in ipairs(R.crafts) do
    if mine(s.c) then
      crafts[#crafts + 1] = { id = s.id, o = s.c, need = s.need, have = s.have, crafts = s.crafts, depth = s.depth, name = UI.itemName(s.id), n = n }
    end
  end
  for n, m in ipairs(R.mail) do
    if mine(m.from) or mine(m.to) then mail[#mail + 1] = { id = m.id, from = m.from, to = m.to, qty = m.qty, n = n } end
  end
  local byWho = function(a, b)
    if rank(a.o) ~= rank(b.o) then return rank(a.o) < rank(b.o) end
    if a.name ~= b.name then return a.name < b.name end
    return a.n < b.n
  end
  table.sort(farm, byWho); table.sort(buy, byWho)
  -- deepest first, so intermediates come before what needs them
  table.sort(crafts, function(a, b) if a.depth ~= b.depth then return a.depth > b.depth end return a.n < b.n end)

  local function section(name, list, line)
    if #list == 0 then return end
    out[#out + 1] = { header = name }
    for _, x in ipairs(list) do out[#out + 1] = line(x) end
  end
  local function itemLine(x)
    local holders = {}
    for _, h in ipairs(Core.holders(x.id)) do holders[#holders + 1] = h.name .. " " .. h.n end
    return { id = x.id, name = x.name, who = who(x.o), me = x.o == my, count = progress(x.have, x.need),
      extra = (x.tag and (x.tag .. ". ") or "") .. (#holders > 0 and ("Vorhanden: " .. table.concat(holders, ", ")) or "") }
  end
  section("Farmen", farm, itemLine)
  section("Kaufen", buy, itemLine)
  section("Herstellen", crafts, function(x)
    local l = itemLine(x)
    if x.crafts > 0 then l.name = string.format("%s  |cffa0a0a0noch %d×|r", x.name, x.crafts) end
    return l
  end)
  section("Post verschicken", mail, function(x)
    return { id = x.id, name = string.format("%d× %s", x.qty, UI.itemName(x.id)), who = who(x.from) .. " → " .. who(x.to),
      me = x.from == my, count = "" }
  end)
  return out
end

local function statusText()
  local Core = ns.Core
  local S, db = Core.list(), Core.db()
  local parts = {}
  if S then parts[#parts + 1] = "Liste vom " .. date("%d.%m. %H:%M", S.t) end
  local noBank = {}
  for _, c in pairs(db.chars) do if not c.bank then noBank[#noBank + 1] = c.name end end
  table.sort(noBank)
  if #noBank > 0 then parts[#parts + 1] = "Bank noch nicht geöffnet: " .. table.concat(noBank, ", ") end
  if S and Core.myIndex() < 0 then parts[#parts + 1] = Core.me().name .. " ist nicht in der Liste" end
  return table.concat(parts, " · ")
end

function UI.refresh()
  if not main or not main:IsShown() then return end
  namesMissing = false
  local lines = buildLines()
  for i, l in ipairs(lines) do
    local r = getRow(i)
    r.itemID, r.extra = l.id, (l.extra ~= "" and l.extra) or nil
    if l.header then
      r.icon:Hide()
      r.name:SetFontObject("GameFontNormal"); r.name:SetText(l.header); r.name:SetTextColor(1, 0.82, 0)
      r.who:SetText(""); r.count:SetText("")
    elseif l.text then
      r.icon:Hide()
      r.name:SetFontObject("GameFontHighlightSmall"); r.name:SetText(l.text); r.name:SetTextColor(1, 1, 1)
      r.who:SetText(""); r.count:SetText("")
    else
      r.icon:Show(); r.icon:SetTexture(itemIcon(l.id))
      r.name:SetFontObject("GameFontHighlightSmall"); r.name:SetText(l.name); r.name:SetTextColor(qualityColor(l.id))
      r.who:SetText(l.me and ("|cffffffff" .. l.who .. "|r") or l.who)
      r.count:SetText(l.count)
    end
    r:Show()
  end
  for i = #lines + 1, #rows do rows[i]:Hide() end
  main.content:SetHeight(math.max(1, #lines * ROW_H))
  main.status:SetText(statusText())
  main.onlyLabel:SetText("nur " .. ns.Core.me().name)
  main.only:SetChecked(ns.Core.db().ui.onlyMe and true or false)
end
-- item names load asynchronously; render again once a batch arrived
function UI.namesArrived()
  if not namesMissing or refreshQueued or not main or not main:IsShown() then return end
  refreshQueued = true
  C_Timer.After(0.3, function() refreshQueued = false; UI.refresh() end)
end

local function createMain()
  main = CreateFrame("Frame", "WerkbankFrame", UIParent, "BasicFrameTemplateWithInset")
  main:SetSize(WIDTH + 44, 480)
  local p = ns.Core.db().ui.main
  if p then main:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else main:SetPoint("CENTER") end
  movable(main, "main")
  main:Hide()
  title(main, "Werkbank")
  main:SetScript("OnShow", UI.refresh)
  tinsert(UISpecialFrames, "WerkbankFrame")

  main.only = CreateFrame("CheckButton", nil, main, "UICheckButtonTemplate")
  main.only:SetSize(22, 22); main.only:SetPoint("TOPLEFT", 10, -26)
  main.only:SetScript("OnClick", function(self) ns.Core.db().ui.onlyMe = self:GetChecked() and true or false; UI.refresh() end)
  main.onlyLabel = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  main.onlyLabel:SetPoint("LEFT", main.only, "RIGHT", 2, 0)

  local scroll = CreateFrame("ScrollFrame", nil, main, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 12, -52); scroll:SetPoint("BOTTOMRIGHT", -32, 30)
  main.content = CreateFrame("Frame", nil, scroll)
  main.content:SetSize(WIDTH, 1)
  scroll:SetScrollChild(main.content)

  main.status = main:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  main.status:SetPoint("BOTTOMLEFT", 14, 10); main.status:SetPoint("BOTTOMRIGHT", -14, 10)
  main.status:SetJustifyH("LEFT"); main.status:SetWordWrap(false)
end

-- a window with a multi-line edit box and one button
local function editWindow(name, heading, buttonText, onButton)
  local f = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset")
  f:SetSize(480, 230); f:SetPoint("CENTER"); f:SetFrameStrata("DIALOG")
  movable(f)
  f:Hide()
  title(f, heading)
  tinsert(UISpecialFrames, name)
  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 14, -32); scroll:SetPoint("BOTTOMRIGHT", -34, 64)
  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true); edit:SetAutoFocus(false); edit:SetMaxLetters(0)
  edit:SetFontObject(ChatFontNormal); edit:SetWidth(420)
  edit:SetScript("OnEscapePressed", function() f:Hide() end)
  scroll:SetScrollChild(edit)
  -- clicking anywhere in the box focuses it
  scroll:EnableMouse(true)
  scroll:SetScript("OnMouseDown", function() edit:SetFocus() end)
  f.edit = edit
  f.msg = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.msg:SetPoint("BOTTOMLEFT", 16, 40); f.msg:SetPoint("BOTTOMRIGHT", -16, 40); f.msg:SetJustifyH("LEFT")
  local button = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  button:SetSize(120, 22); button:SetPoint("BOTTOMRIGHT", -14, 12); button:SetText(buttonText)
  button:SetScript("OnClick", function() onButton(f) end)
  return f
end

function UI.showImport()
  if not importBox then
    importBox = editWindow("WerkbankImport", "Werkbank: Liste einfügen", "Übernehmen", function(f)
      local ok, err = ns.Core.setList(f.edit:GetText())
      if not ok then f.msg:SetText("|cffd06060" .. err .. "|r"); return end
      f:Hide()
      print(ACCENT .. "Werkbank:|r Liste übernommen.")
      if not main then createMain() end
      main:Show()
    end)
  end
  importBox.edit:SetText("")
  importBox.msg:SetText("Auf der Werkbank-Seite „Für Addon kopieren“, dann hier Strg+V.")
  importBox:Show()
  importBox.edit:SetFocus()
end

function UI.showExport()
  local text = ns.Core.writeExport()
  if not exportBox then
    exportBox = editWindow("WerkbankExport", "Werkbank: Bestand für die Seite", "Schließen", function(f) f:Hide() end)
    -- read-only: typing puts the text back
    exportBox.edit:SetScript("OnTextChanged", function(self, user)
      if user then self:SetText(exportBox.text); self:HighlightText() end
    end)
  end
  exportBox.text = text
  exportBox.edit:SetText(text)
  exportBox.msg:SetText("Strg+C zum Kopieren, dann auf der Werkbank-Seite unter „Bestand aus WoW …“ einfügen.")
  exportBox:Show()
  exportBox.edit:SetFocus()
  exportBox.edit:HighlightText()
end

function UI.toggle()
  if not main then createMain() end
  if main:IsShown() then main:Hide() else main:Show() end
end

-- ---------- item tooltips everywhere: "Werkbank: 34/60" ----------
local function onTooltip(tooltip, data)
  if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
  local id = data and data.id
  if type(id) ~= "number" then return end
  local e = ns.Core.byId[id]
  if not e then return end
  tooltip:AddLine(ACCENT .. "Werkbank:|r " .. progress(e.have, e.need))
  local holders = {}
  for _, h in ipairs(ns.Core.holders(id)) do holders[#holders + 1] = h.name .. " " .. h.n end
  if #holders > 0 then tooltip:AddLine(table.concat(holders, ", "), 0.8, 0.8, 0.8, true) end
end

function UI.init()
  if TooltipDataProcessor and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
      pcall(onTooltip, tooltip, data)   -- never break a tooltip because of the list
    end)
  end
  SLASH_WERKBANK1 = "/werkbank"
  SlashCmdList.WERKBANK = function(msg)
    local cmd = string.lower(string.match(msg or "", "^%s*(%S*)") or "")
    if cmd == "import" then UI.showImport()
    elseif cmd == "export" then UI.showExport()
    elseif cmd == "" then UI.toggle()
    else
      print(ACCENT .. "Werkbank:|r /werkbank (Liste), /werkbank import (Liste von der Seite einfügen), /werkbank export (Bestand für die Seite)")
    end
  end
end

return UI
