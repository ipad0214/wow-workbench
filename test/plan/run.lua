-- The addon's Plan.lua against the fixtures that test/plan/plan.test.mjs checks the website's planner
-- with, plus what only the addon knows (learned recipes). Run from the repo root: lua test/plan/run.lua
local root = (arg and arg[0] or ""):match("^(.*)test/plan/run%.lua$") or "./"
local ns = {}
for _, f in ipairs({ "Data.lua", "Codec.lua", "Plan.lua" }) do
  assert(loadfile(root .. "addon/Werkbank/" .. f))("Werkbank", ns)
end
local Plan, Codec = ns.Plan, ns.Codec

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then passed = passed + 1 else failed = failed + 1; io.write("FAIL " .. name .. (detail and ("\n" .. detail) or "") .. "\n") end
end

-- one line per entry, sorted where the order doesn't matter
local function canonical(S)
  local out = { "chars " .. table.concat(S.chars, ",") }
  for _, r in ipairs(S.roots) do out[#out + 1] = string.format("root %d %d", r.id, r.need) end
  local rest = {}
  for id, k in pairs(S.crafts) do
    local reag = {}
    for _, x in ipairs(k.reag) do reag[#reag + 1] = x[1] .. "*" .. x[2] end
    rest[#rest + 1] = string.format("craft %d y%d c%d %s %s", id, k.y, k.c, k.rootOnly and "rootOnly" or "inner", table.concat(reag, "+"))
  end
  for id, r in pairs(S.raws) do rest[#rest + 1] = string.format("raw %d %s %s", id, r.g, tostring(r.o)) end
  table.sort(rest)
  for _, l in ipairs(rest) do out[#out + 1] = l end
  return table.concat(out, "\n")
end
local function char(spec)
  local parts = {}
  for p in string.gmatch(spec, "[^|]+") do parts[#parts + 1] = p end
  local c = { name = parts[1], profs = {} }
  for i = 2, #parts do
    local prof, s = string.match(parts[i], "^(.-)=(%d+)$")
    c.profs[prof] = { tonumber(s), 300 }
  end
  return c
end

-- ---------- the shared fixtures ----------
local cur, cases = nil, 0
local function finish()
  if not cur then return end
  cases = cases + 1
  local want = assert(Codec.decodeList(cur.expect))
  local got = Plan.structure(cur.shop, cur.chars, 0)
  local a, b = canonical(got), canonical(want)
  check("plans.txt case " .. cur.name, a == b, "addon:\n" .. a .. "\nwebsite:\n" .. b)
end
for l in io.lines(root .. "test/plan/fixtures/plans.txt") do
  local word, rest = string.match(l, "^(%S+) ?(.*)$")
  if word == "case" then finish(); cur = { name = rest, chars = {}, shop = {} }
  elseif word == "char" then cur.chars[#cur.chars + 1] = char(rest)
  elseif word == "shop" then
    for n, q in string.gmatch(rest, "(%d+)%*(%d+)") do cur.shop[#cur.shop + 1] = { r = tonumber(n), qty = tonumber(q) } end
  elseif word == "expect" then cur.expect = rest end
end
finish()
check("fixtures read", cases == 80, cases)

-- ---------- learned recipes: only the addon knows them ----------
-- Kupferkettengürtel (2851): Ulfrik has the higher skill, Bandor has learned the recipe
local belt = ns.Data.byProduct[2851][1]
local ulfrik = { name = "Ulfrik", profs = { Schmiedekunst = { 100, 150 } } }
local bandor = { name = "Bandor", profs = { Schmiedekunst = { 50, 75 } } }
check("highest skill crafts without recipe data", Plan.crafterFor({ ulfrik, bandor }, "Schmiedekunst", 2851) == 1)
bandor.recipes = { Schmiedekunst = { known = { [2851] = true } } }
check("a character who learned the recipe comes first", Plan.crafterFor({ ulfrik, bandor }, "Schmiedekunst", 2851) == 2)
ulfrik.recipes = { Schmiedekunst = { known = { [2851] = true } } }
check("both learned it: the higher skill", Plan.crafterFor({ ulfrik, bandor }, "Schmiedekunst", 2851) == 1)
local S = Plan.structure({ { r = belt, qty = 2 } }, { ulfrik, bandor }, 0)
check("belt root needs 2", S.roots[1].id == 2851 and S.roots[1].need == 2)
check("bars smelted by nobody without Bergbau: bought", S.raws[2840] and S.raws[2840].g == "AH")
local e = Plan.entryFor({ ulfrik }, 2840, 5)
check("entry for an imported item", e and ns.Data.recipes[e.r][1] == 2840 and e.qty == 5)
check("no entry for an item without recipe", Plan.entryFor({ ulfrik }, 2770, 5) == nil)

io.write(string.format("%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
