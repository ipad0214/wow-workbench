-- Werkbank addon: the planner. Builds the list structure (the same as a decoded WB1 string from the
-- website) from the shopping list, the recipe database and the characters' profiles: which recipe, who
-- crafts it, who gathers what. Net.lua then nets the stock against it. Mirrors buildPlan() and
-- listStructure() in site/index.html; test/plan/ checks both against the same fixtures. No WoW API here.
--
-- chars: { { name, profs = { [prof] = { skill, max } }, recipes = { [prof] = { known = { [id] = true } } } } }
--        in a fixed order; on equal skill the earlier character wins, like on the website.
-- shop:  { { r = recipe index in Data.recipes, qty = how often to craft it } }
local _, ns = ...
local Data = ns.Data
local Plan = {}
ns.Plan = Plan

-- gather group -> the profession that gathers it; C (cloth), V (vendor), X (drop) are gathered by
-- whoever needs them
local GATHER = { H = "Kräuterkunde", M = "Bergbau", S = "Kürschnerei", F = "Angeln", D = "Verzauberkunst" }

function Plan.profOf(n) return Data.profsDe[Data.recipes[n][2] + 1] end
local function groupOf(id) local it = Data.items[id]; return it and it[7] or "X" end

-- index of the character that crafts product with prof: the highest skill. A character that has
-- learned this very recipe comes before one that hasn't (only known once its profession window was
-- opened; the website doesn't know it, so without that data both choose alike). nil: nobody.
function Plan.crafterFor(chars, prof, product)
  local best, bestS, bestKnows
  for i, c in ipairs(chars) do
    local s = c.profs[prof]
    if s then
      local r = c.recipes and c.recipes[prof]
      local knows = (r and r.known[product]) and true or false
      if not best or (knows and not bestKnows) or (knows == bestKnows and s[1] > bestS) then
        best, bestS, bestKnows = i, s[1], knows
      end
    end
  end
  return best
end

-- the recipe for an item and its crafter: the first recipe somebody can craft, else the first one
-- (crafter nil). nil: not craftable
function Plan.pickRecipe(chars, id)
  local rs = Data.byProduct[id]
  if not rs then return nil end
  for _, n in ipairs(rs) do
    local c = Plan.crafterFor(chars, Plan.profOf(n), id)
    if c then return n, c end
  end
  return rs[1]
end

local function gatherer(chars, g)
  local prof = GATHER[g]
  if not prof then return nil end
  for i, c in ipairs(chars) do
    if c.profs[prof] then return i end
  end
end

function Plan.structure(shop, chars, t)
  local S = { t = t or 0, chars = {}, roots = {}, crafts = {}, raws = {} }
  for i, c in ipairs(chars) do S.chars[i] = c.name end
  local function ci(i) return i and (i - 1) or -1 end

  -- like resolve() on the website; the first visit of an item decides its entry
  local function resolve(id, path, isRoot, r0)
    local g = groupOf(id)
    local n, crafter
    if r0 then n, crafter = r0, Plan.crafterFor(chars, Plan.profOf(r0), id) else n, crafter = Plan.pickRecipe(chars, id) end
    -- leather and enchanting mats are gathered even when a conversion recipe exists
    local gatherRaw = not isRoot and (g == "S" or g == "D")
    if n and not path[id] and not gatherRaw and (isRoot or crafter) then
      local r = Data.recipes[n]
      if not S.crafts[id] then
        -- crafted further down the tree too, or only when it's on the list itself?
        local _, pc = Plan.pickRecipe(chars, id)
        local inner = g ~= "S" and g ~= "D" and pc
        S.crafts[id] = { y = r[4], c = ci(crafter), rootOnly = not inner, reag = r[6] }
      end
      local p2 = { [id] = true }
      for x in pairs(path) do p2[x] = true end
      for _, x in ipairs(r[6]) do resolve(x[1], p2, false) end
      return
    end
    if not S.raws[id] then
      -- a recipe nobody can craft: bought or looted by whoever needs it
      local how = (n and not crafter and not gatherRaw) and "AH" or g
      S.raws[id] = { g = how, o = GATHER[how] and ci(gatherer(chars, how)) or "c" }
    end
  end

  for _, e in ipairs(shop) do
    local r = Data.recipes[e.r]
    S.roots[#S.roots + 1] = { id = r[1], need = e.qty * r[4] }
    resolve(r[1], {}, true, e.r)
  end
  return S
end

-- a shopping list entry for an item, e.g. from an imported website list: the recipe the planner would
-- pick, and how often to craft it for need items. nil when the database has no recipe for it.
function Plan.entryFor(chars, id, need)
  local n = Plan.pickRecipe(chars, id)
  if not n then return nil end
  return { r = n, qty = math.max(1, math.ceil(need / Data.recipes[n][4])) }
end

return Plan
