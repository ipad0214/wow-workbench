-- The addon's Codec.lua and Net.lua against the fixtures that test/sync/sync.test.mjs uses for site/sync.js.
-- Run from the repo root: lua test/sync/run.lua
local root = (arg and arg[0] or ""):match("^(.*)test/sync/run%.lua$") or "./"
local ns = {}
for _, f in ipairs({ "Codec.lua", "Net.lua" }) do
  assert(loadfile(root .. "addon/Werkbank/" .. f))("Werkbank", ns)
end
local Codec, Net = ns.Codec, ns.Net

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. (detail and ("\n" .. detail) or "")) end
end
local function lines(file)
  local out = {}
  for l in io.lines(root .. "test/sync/fixtures/" .. file) do
    if l:find("%S") and l:sub(1, 1) ~= "#" then out[#out + 1] = l end
  end
  return out
end
local function parseStock(s)
  local out = {}
  for id, n in (s or ""):gmatch("(%-?%d+)=(%d+)") do out[tonumber(id)] = tonumber(n) end
  return out
end
local function i(x) return x >= 0 and string.format("%d", x) or "-" end
local function canonical(res)
  local out = {}
  for _, s in ipairs(res.crafts) do
    out[#out + 1] = string.format("craft %d %s %d %d %d %d", s.id, i(s.c), s.crafts, s.need, s.have, s.depth)
  end
  for _, f in ipairs(res.farm) do
    out[#out + 1] = string.format("farm %s %d %s %d %d", f.o >= 0 and i(f.o) or ("_" .. f.g), f.id, f.g, f.need, f.have)
  end
  for _, m in ipairs(res.mail) do out[#out + 1] = string.format("mail %d %d %d %d", m.from, m.to, m.id, m.qty) end
  table.sort(out)
  return table.concat(out, "\n")
end

-- netting
local p = io.popen('ls "' .. root .. 'test/sync/fixtures"')
for file in p:lines() do
  if file:match("^net%-") then
    local list, cases, cur = nil, {}, nil
    for _, l in ipairs(lines(file)) do
      local word, rest = l:match("^(%S+)%s?(.*)$")
      if word == "list" then list = rest
      elseif word == "case" then cur = { name = rest, stock = {}, expect = {} }; cases[#cases + 1] = cur
      elseif word == "stock" then cur.stock = parseStock(rest)
      else cur.expect[#cur.expect + 1] = l end
    end
    local S, err = Codec.decodeList(list .. ";" .. Codec.checksum(list))
    check(file .. ": decodes", S ~= nil, err)
    if S then
      for _, c in ipairs(cases) do
        table.sort(c.expect)
        local want, got = table.concat(c.expect, "\n"), canonical(Net.evaluate(S, c.stock))
        check(file .. ": " .. c.name, want == got, "want:\n" .. want .. "\ngot:\n" .. got)
      end
    end
  end
end
p:close()

-- checksum
for _, l in ipairs(lines("checksum.txt")) do
  local sum, text = l:match("^(%S+) (.*)$")
  check("checksum " .. text, Codec.checksum(text) == sum, "got " .. Codec.checksum(text))
end

-- WC1 export
local C, want = { chars = {} }, nil
for _, l in ipairs(lines("counts.txt")) do
  local w, a, b, c = l:match("^(%S+) (%S+) ?(%S*) ?(%S*)$")
  if w == "t" then C.t = tonumber(a)
  elseif w == "char" then C.chars[#C.chars + 1] = { name = a, at = tonumber(b), items = parseStock(c) }
  elseif w == "wc1" then want = a end
end
local got = Codec.encodeCounts(C)
check("WC1 export matches the fixture", got == want, "want " .. want .. "\ngot  " .. got)

-- broken input
local S, err = Codec.decodeList("WB1;1;Ulfrik;100:1;100:1:0:0:;;wrong")
check("a wrong checksum is rejected", S == nil and err:find("unvollständig"), err)
S, err = Codec.decodeList("hallo")
check("text without WB1 is rejected", S == nil and err:find("Kein Werkbank%-Text"), err)
local body = "WB1;1;Ulfrik;100:1;100:1:3:0:;"
S, err = Codec.decodeList(body .. ";" .. Codec.checksum(body))
check("a crafter index outside the character list is rejected", S == nil and err:find("Handwerker"), err)
body = "WB1;1;Ulfrik;100:1;100:1::0:2840*2;2840:M:0"
S = Codec.decodeList("Liste:\n" .. body:sub(1, 20) .. "\r\n" .. body:sub(21) .. ";" .. Codec.checksum(body) .. "  ")
check("line breaks and text around the string are ignored", S ~= nil and S.crafts[100].reag[1][2] == 2)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
