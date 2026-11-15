-- The generated recipe database loads in Lua and its indexes agree with the data.
-- Run from the repo root: lua test/addon/data.lua
local root = (arg and arg[0] or ""):match("^(.*)test/addon/data%.lua$") or "./"
local ns = {}
local D = assert(loadfile(root .. "addon/Werkbank/Data.lua"))("Werkbank", ns)

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then passed = passed + 1 else failed = failed + 1; io.write("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "") .. "\n") end
end

local items = 0
for _ in pairs(D.items) do items = items + 1 end
check("namespace set", ns.Data == D)
check("2281 items", items == 2281, items)
check("1232 recipes", #D.recipes == 1232, #D.recipes)
check("German profession names", #D.profsDe == #D.profs and D.profsDe[2] == "Schmiedekunst")
check("names by id from api/armory.mjs", D.profNames[164][1] == "Schmiedekunst" and D.profNames[393][2] == "Skinning"
  and D.classNames[2] == "Paladin" and D.raceNames[3] == "Zwerg")
check("item fields", D.items[2840][1] == "Copper Bar" and D.items[2840][11] == "Kupferbarren", D.items[2840][11])
check("enchants under the negative spell id", D.items[-7418] and D.items[-7418][11] == "Armschiene - Schwache Gesundheit")
local belt = D.recipes[D.byProduct[2851][1]]
check("recipe fields", belt[1] == 2851 and D.profsDe[belt[2] + 1] == "Schmiedekunst" and belt[3] == 35
  and belt[6][1][1] == 2840 and belt[6][1][2] == 6)
check("tool as last field", D.recipes[D.byProduct[-7418][1]][8] == 6218)

local inProfs, usedOk, productsOk = 0, true, true
for _, list in pairs(D.byProf) do inProfs = inProfs + #list end
for n, r in ipairs(D.recipes) do
  if not D.items[r[1]] then productsOk = false end
  for _, x in ipairs(r[6]) do if not D.usedIn[x[1]][n] then usedOk = false end end
end
check("every recipe in exactly one profession", inProfs == #D.recipes, inProfs)
check("every product is an item", productsOk)
check("usedIn covers every reagent", usedOk)
check("copper bars are used by the belt", D.usedIn[2840][D.byProduct[2851][1]])

io.write(string.format("%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
