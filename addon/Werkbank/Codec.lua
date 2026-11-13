-- Werkbank addon: the list import "WB1" and the count export "WC1".
-- Mirrors site/sync.js; test/sync/run.lua checks both against the same fixtures. No WoW API in here,
-- and only Lua 5.1 features (the tests run on a newer Lua, so no integer/float assumptions either).
local _, ns = ...
ns = ns or {}
local Codec = {}
ns.Codec = Codec

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local GROUPS = { H = true, M = true, S = true, F = true, D = true, C = true, V = true, X = true, AH = true }

-- Adler-32 over the bytes of s (UTF-8), in base 36
function Codec.checksum(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + string.byte(s, i)) % 65521
    b = (b + a) % 65521
  end
  local n = b * 65536 + a
  if n == 0 then return "0" end
  local out = ""
  while n > 0 do
    local d = n % 36
    out = string.sub(DIGITS, d + 1, d + 1) .. out
    n = math.floor((n - d) / 36)
  end
  return out
end

function Codec.cleanName(s)
  s = string.gsub(tostring(s or ""), "[;,:%+%*\r\n\t]", "")
  s = string.gsub(s, "^%s+", "")
  return (string.gsub(s, "%s+$", ""))
end

-- "a::b" -> {"a", "", "b"}
local function rawsplit(s, sep)
  local out, start = {}, 1
  while true do
    local i = string.find(s, sep, start, true)
    if not i then out[#out + 1] = string.sub(s, start); return out end
    out[#out + 1] = string.sub(s, start, i - 1)
    start = i + 1
  end
end
-- like rawsplit, but an empty string is an empty list
local function split(s, sep)
  if s == nil or s == "" then return {} end
  return rawsplit(s, sep)
end

local function fail(msg) error({ werkbank = msg }, 0) end
-- the same limits as site/sync.js: item ids up to 7 digits (negative: enchants), other numbers up to 10
local function num(s, what, isId)
  local ok = type(s) == "string" and
    (isId and string.find(s, "^%-?%d+$") and #string.gsub(s, "%-", "") <= 7 or (not isId and string.find(s, "^%d+$") and #s <= 10))
  if not ok then fail(what .. " ungültig") end
  return tonumber(s)
end

-- the pasted text: drop line breaks, check version and checksum; returns the fields between them
local function unwrap(text, tag, fields)
  local s = string.gsub(tostring(text or ""), "[\r\n\t]", "")
  local at = string.find(s, tag .. ";", 1, true)
  if not at then fail("Kein Werkbank-Text gefunden (" .. tag .. ").") end
  local parts = rawsplit(string.sub(s, at), ";")
  if #parts < fields then fail("Der Text ist unvollständig. Bitte komplett kopieren.") end
  local data = table.concat(parts, ";", 1, fields - 1)
  local sum = string.gsub(parts[fields], "%s+$", "")
  if Codec.checksum(data) ~= sum then fail("Der Text ist unvollständig. Bitte komplett kopieren.") end
  local out = {}
  for i = 2, fields - 1 do out[#out + 1] = parts[i] end
  return out
end

-- returns ok, result-or-message
local function protect(fn, ...)
  local ok, res = pcall(fn, ...)
  if ok then return true, res end
  if type(res) == "table" and res.werkbank then return false, res.werkbank end
  return false, "Text nicht lesbar"
end

local function decodeList(text)
  local f = unwrap(text, "WB1", 7)
  local chars = split(f[2], ",")
  local function idx(s, what)
    if s == "" then return -1 end
    if s == nil then fail(what .. " ungültig") end
    local i = num(s, what)
    if i >= #chars then fail(what .. " ungültig") end
    return i
  end
  local S = { t = num(f[1], "Zeit"), chars = chars, roots = {}, crafts = {}, raws = {} }
  for _, r in ipairs(split(f[3], ",")) do
    local p = rawsplit(r, ":")
    S.roots[#S.roots + 1] = { id = num(p[1], "Item", true), need = num(p[2], "Menge") }
  end
  for _, k in ipairs(split(f[4], ",")) do
    local p = rawsplit(k, ":")
    local reag = {}
    for _, x in ipairs(split(p[5], "+")) do
      local q = rawsplit(x, "*")
      reag[#reag + 1] = { num(q[1], "Zutat", true), num(q[2], "Menge") }
    end
    S.crafts[num(p[1], "Item", true)] = {
      y = math.max(1, num(p[2], "Ertrag")), c = idx(p[3], "Handwerker"), rootOnly = p[4] == "1", reag = reag,
    }
  end
  for _, r in ipairs(split(f[5], ",")) do
    local p = rawsplit(r, ":")
    if not GROUPS[p[2] or ""] then fail("Quelle ungültig") end
    S.raws[num(p[1], "Item", true)] = { g = p[2], o = (p[3] == "c") and "c" or idx(p[3], "Charakter") }
  end
  return S
end
-- returns list or nil, message
function Codec.decodeList(text)
  local ok, res = protect(decodeList, text)
  if ok then return res end
  return nil, res
end

-- C = { t = seconds, chars = { { name, at, items = { [id] = n } } } }
function Codec.encodeCounts(C)
  local chars = {}
  for _, c in ipairs(C.chars) do chars[#chars + 1] = c end
  table.sort(chars, function(a, b) return Codec.cleanName(a.name) < Codec.cleanName(b.name) end)
  local out = {}
  for _, c in ipairs(chars) do
    local ids = {}
    for id, n in pairs(c.items or {}) do if n > 0 then ids[#ids + 1] = id end end
    table.sort(ids)
    local items = {}
    for _, id in ipairs(ids) do items[#items + 1] = string.format("%d*%d", id, c.items[id]) end
    out[#out + 1] = Codec.cleanName(c.name) .. ":" .. string.format("%d", c.at or 0) .. ":" .. table.concat(items, "+")
  end
  local data = "WC1;" .. string.format("%d", C.t) .. ";" .. table.concat(out, ",")
  return data .. ";" .. Codec.checksum(data)
end

return ns
