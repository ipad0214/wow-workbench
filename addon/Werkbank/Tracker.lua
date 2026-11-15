-- Werkbank addon: the tracker, a compact list on the screen edge like Questie's quest tracker. It shows
-- what the current character has to do (and rows nobody is assigned to): farm, buy, craft, send. Done
-- rows stay, green with a check mark. The heading: left click folds it, drag moves it, right click opens
-- the list window. The rows take no clicks, so they never get in the way while playing.
--
-- WerkbankDB.ui.tracker = { hidden, collapsed, point }
local _, ns = ...
local Tracker = {}
ns.Tracker = Tracker

local WIDTH, LINE, HEAD = 230, 14, 18
local DONE = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t"   -- the fonts have no check mark glyph
local frame, header
local lines = {}

local function settings()
  local ui = ns.Core.db().ui
  ui.tracker = ui.tracker or {}
  return ui.tracker
end
function Tracker.shown() return not settings().hidden end
function Tracker.setShown(on)
  settings().hidden = not on
  Tracker.refresh()
  if ns.UI.refresh then ns.UI.refresh() end   -- the checkbox in the list window
end

local function create()
  frame = CreateFrame("Frame", "WerkbankTracker", UIParent)
  frame:SetSize(WIDTH, HEAD)
  frame:SetMovable(true); frame:SetClampedToScreen(true)
  local p = settings().point
  if p then frame:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -60, -260) end

  header = CreateFrame("Button", nil, frame)
  header:SetPoint("TOPLEFT"); header:SetPoint("TOPRIGHT"); header:SetHeight(HEAD)
  header.text = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  header.text:SetPoint("LEFT"); header.text:SetPoint("RIGHT"); header.text:SetJustifyH("LEFT")
  header:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  header:RegisterForDrag("LeftButton")
  header:SetScript("OnDragStart", function() frame:StartMoving() end)
  header:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    local point, _, rel, x, y = frame:GetPoint()
    settings().point = { point, rel, x, y }
  end)
  header:SetScript("OnClick", function(_, button)
    if button == "RightButton" then ns.UI.toggle() return end
    settings().collapsed = not settings().collapsed
    Tracker.refresh()
  end)
  header:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Werkbank")
    GameTooltip:AddLine("Linksklick: ein-/ausklappen. Ziehen: verschieben. Rechtsklick: Werkbank öffnen.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  header:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function line(i)
  if lines[i] then return lines[i] end
  local y = -HEAD - (i - 1) * LINE
  local l = {
    name = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
    count = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
  }
  l.count:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, y); l.count:SetWidth(70); l.count:SetJustifyH("RIGHT")
  l.name:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, y); l.name:SetPoint("RIGHT", l.count, "LEFT", -4, 0)
  l.name:SetJustifyH("LEFT"); l.name:SetWordWrap(false)
  lines[i] = l
  return l
end

-- { text, count, done, section } for the current character
local function entries(rows)
  local out = {}
  local function section(title, list, row)
    if #list == 0 then return end
    out[#out + 1] = { section = title }
    for _, x in ipairs(list) do out[#out + 1] = row(x) end
  end
  local function have(x) return { text = x.name, count = x.have .. "/" .. x.need, done = x.have >= x.need } end
  section("Farmen", rows.farm, have)
  section("Kaufen", rows.buy, have)
  section("Herstellen", rows.crafts, function(x)
    return { text = x.name, count = x.crafts > 0 and ("noch " .. x.crafts .. "×") or "", done = x.crafts == 0 }
  end)
  local send = {}
  for _, m in ipairs(rows.mail) do if m.from == rows.my then send[#send + 1] = m end end
  section("Post", send, function(m)
    return { text = m.qty .. "× " .. ns.UI.itemName(m.id), count = "» " .. (rows.chars[m.to + 1] or "?") }
  end)
  return out
end

function Tracker.refresh()
  local Core = ns.Core
  if not Core.db() then return end
  local rows = Tracker.shown() and ns.UI.planRows(function(i, my) return i == my or i < 0 end)
  if not rows then
    if frame then frame:Hide() end
    return
  end
  if not frame then create() end
  local set = settings()
  header.text:SetText((set.collapsed and "+ " or "- ") .. "Werkbank · " .. Core.me().name)
  local list = set.collapsed and {} or entries(rows)
  if not set.collapsed and #list == 0 then list[1] = { text = "|cffa0a0a0Nichts zu tun|r", count = "" } end
  for i, e in ipairs(list) do
    local l = line(i)
    if e.section then
      l.name:SetFontObject("GameFontNormalSmall"); l.name:SetText(e.section); l.count:SetText("")
    else
      l.name:SetFontObject("GameFontHighlightSmall")
      l.name:SetText("  " .. (e.done and "|cff40c040" .. e.text .. "|r" or e.text))
      l.count:SetText(e.done and DONE or e.count)
    end
    l.name:Show(); l.count:Show()
  end
  for i = #list + 1, #lines do lines[i].name:Hide(); lines[i].count:Hide() end
  frame:SetHeight(HEAD + #list * LINE)
  frame:Show()
end

ns.Core.onUpdate(Tracker.refresh)

return Tracker
