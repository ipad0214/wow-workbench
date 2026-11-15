-- Werkbank addon: two buttons in the game's profession window, which brings its own search and filters.
-- "Auf die Werkbank" puts the selected recipe on the shopping list, as often as the window's quantity
-- box says; "Werkbank" opens the list window. A line above shows how often the recipe is on the list.
-- Works with the modern window (ProfessionsFrame) and the classic ones (TradeSkillFrame, Enchanting's
-- CraftFrame). Blizzard's frames are only anchored to, never changed.
local _, ns = ...
local Data, Core, Profile, Plan, UI = ns.Data, ns.Core, ns.Profile, ns.Plan, ns.UI
local Craft = {}
ns.Craft = Craft

-- the database recipe for the keys of a selected recipe, the open profession's first;
-- false: the database doesn't know it (e.g. a recipe WoW Forever added)
local function findRecipe(prof, ...)
  local any
  for i = 1, select("#", ...) do
    local key = select(i, ...)
    for _, n in ipairs(key and Data.byProduct[key] or {}) do
      if Plan.profOf(n) == prof then return n end
      any = any or n
    end
  end
  return any or false
end

-- the windows: where they are, the selected recipe (index or false, quantity; nil: none selected) and
-- where the buttons go
local KINDS = {
  {
    frame = function() return ProfessionsFrame and ProfessionsFrame.CraftingPage end,
    selected = function(page)
      local form = page.SchematicForm
      local info = form and form.GetRecipeInfo and form:GetRecipeInfo()
      if type(info) ~= "table" or not info.recipeID then return nil end
      local prof = Profile.openProfession()
      local n = findRecipe(prof, Profile.keysOf(info.recipeID))
      if n == false then
        -- not in the database (a WoW Forever recipe): take it as the game describes it
        local e = Profile.recipeFromGame(info.recipeID, prof)
        if e then n = Core.addRecipe(info.recipeID, e) end
      end
      local box = page.CreateMultipleInputBox
      return n, box and box.GetValue and box:GetValue()
    end,
    -- left of the game's create buttons: [Werkbank] [Auf die Werkbank] [Alle herstellen] [n] [Herstellen]
    place = function(page, add, open, note)
      if page.CreateAllButton then add:SetPoint("RIGHT", page.CreateAllButton, "LEFT", -8, 0) else add:SetPoint("BOTTOMLEFT", 12, 12) end
      open:SetPoint("RIGHT", add, "LEFT", -4, 0)
      note:SetPoint("BOTTOMLEFT", open, "TOPLEFT", 2, 5)
    end,
  },
  {
    frame = function() return TradeSkillFrame end,
    selected = function()
      local i = GetTradeSkillSelectionIndex and GetTradeSkillSelectionIndex()
      if not i or i == 0 then return nil end
      local prof = Profile.profName(nil, (GetTradeSkillLine()))
      return findRecipe(prof, Profile.idFromLink(GetTradeSkillItemLink(i))), TradeSkillInputBox and TradeSkillInputBox:GetNumber()
    end,
    -- above the create buttons, the row itself is full
    place = function(_, add, open, note)
      add:SetPoint("BOTTOMLEFT", TradeSkillCreateAllButton, "TOPLEFT", 0, 4)
      open:SetPoint("LEFT", add, "RIGHT", 4, 0)
      note:SetPoint("BOTTOMLEFT", add, "TOPLEFT", 2, 5)
    end,
  },
  {
    frame = function() return CraftFrame end,
    selected = function()
      local i = GetCraftSelectionIndex and GetCraftSelectionIndex()
      if not i or i == 0 then return nil end
      local prof = Profile.profName(nil, (GetCraftDisplaySkillLine()))
      return findRecipe(prof, Profile.idFromLink(GetCraftItemLink(i))), 1   -- enchants are cast one by one
    end,
    place = function(_, add, open, note)
      add:SetPoint("BOTTOMRIGHT", CraftCreateButton, "TOPRIGHT", 0, 4)
      open:SetPoint("RIGHT", add, "LEFT", -4, 0)
      note:SetPoint("BOTTOMRIGHT", add, "TOPRIGHT", -2, 5)
    end,
  },
}

-- the note and the button state for the recipe each open window shows
function Craft.refresh()
  for _, k in ipairs(KINDS) do
    local f = k.add and k.frame()
    if f and f:IsShown() then
      local n = k.selected(f)
      k.add:SetEnabled(n and true or false)
      local q = n and Core.shopQty(n) or 0
      if n == false then k.note:SetText("|cffa0a0a0Nicht in der Werkbank-Datenbank|r")
      elseif q > 0 then k.note:SetText(string.format("Auf der Werkbank: %d×", q))
      else k.note:SetText("") end
    end
  end
end
Core.onUpdate(Craft.refresh)
-- selection changes arrive before the window shows the new recipe; read it right after
local function refreshSoon() C_Timer.After(0, Craft.refresh) end

local function add(k)
  local n, qty = k.selected(k.frame())
  if not n then
    UI.say(n == false and "Dieses Rezept kennt die Werkbank nicht." or "Erst ein Rezept auswählen.")
    return
  end
  local total = Core.addToShop(n, qty)   -- Core.update refreshes the note
  UI.say(string.format("%s: %d× auf der Werkbank", UI.itemName(Data.recipes[n][1]), total))
end

-- the buttons, once per window; the windows are loaded on demand, so this runs on several events
local function attach()
  for _, k in ipairs(KINDS) do
    local f = not k.add and k.frame()
    if f then
      k.add = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
      k.add:SetSize(150, 22); k.add:SetText("Auf die Werkbank")
      k.add:SetScript("OnClick", function() add(k) end)
      local open = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
      open:SetSize(90, 22); open:SetText("Werkbank")
      open:SetScript("OnClick", UI.toggle)
      -- above the window's own panels, or they cover the note
      local level = f:GetFrameLevel() + 20
      k.add:SetFrameLevel(level); open:SetFrameLevel(level)
      k.note = k.add:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      k.place(f, k.add, open, k.note)
      f:HookScript("OnShow", refreshSoon)
    end
  end
  refreshSoon()
end

-- the classic windows' selection functions only exist once the window is loaded
local hooked = {}
local function hookSelection()
  for _, fn in ipairs({ "TradeSkillFrame_SetSelection", "CraftFrame_SetSelection" }) do
    if not hooked[fn] and type(_G[fn]) == "function" then hooksecurefunc(fn, refreshSoon); hooked[fn] = true end
  end
end

-- both do nothing once done, so every event that may bring a window just calls this
local function setup() attach(); hookSelection() end

Core.on("PLAYER_LOGIN", function()
  setup()
  if EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback("ProfessionsRecipeListMixin.Event.OnRecipeSelected", refreshSoon, Craft)
  end
end)
Core.on("ADDON_LOADED", setup)
-- the game loads the window on these events; run after its own handler
Core.on("TRADE_SKILL_SHOW", function() C_Timer.After(0, setup) end)
Core.on("CRAFT_SHOW", function() C_Timer.After(0, setup) end)

return Craft
