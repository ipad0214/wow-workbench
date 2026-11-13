-- Werkbank addon: nets what the characters own against the list. Mirrors evaluate() in site/sync.js:
-- walk the list like the website's planner; at every node, the roots included, owned items are used
-- first and only the rest is crafted or farmed. No WoW API in here.
local _, ns = ...
ns = ns or {}
local Net = {}
ns.Net = Net

-- S: decoded WB1 list; stock: { [id] = owned }. Returns
--   crafts = { { id, c, crafts, need, have, depth } }   in the order first seen
--   farm   = { { o, id, g, need, have } }               o = character index, or -1 (nobody)
--   mail   = { { from, to, id, qty } }
-- need = what reaches the node, have = how much of it the stock covers.
function Net.evaluate(S, stock)
  local pool = {}
  for id, n in pairs(stock or {}) do if n > 0 then pool[id] = n end end
  local crafts, craftOrder = {}, {}
  local farm, farmOrder = {}, {}
  local mail, mailOrder = {}, {}

  local function take(id, need)
    local p = pool[id] or 0
    local t = math.min(p, need)
    if t > 0 then pool[id] = p - t end
    return t
  end
  local function send(from, to, id, qty)
    if from < 0 or to < 0 or from == to or qty <= 0 then return end
    local k = from .. ">" .. to .. ">" .. id
    local m = mail[k]
    if not m then m = { from = from, to = to, id = id, qty = 0 }; mail[k] = m; mailOrder[#mailOrder + 1] = m end
    m.qty = m.qty + qty
  end

  local function resolve(id, need, consumer, path, isRoot, depth)
    local have = take(id, need)
    local rest = need - have
    local k = S.crafts[id]
    if k and not path[id] and (isRoot or not k.rootOnly) then
      local n = math.ceil(rest / k.y)
      local st = crafts[id]
      if not st then
        st = { id = id, c = k.c, crafts = 0, need = 0, have = 0, depth = 0 }
        crafts[id] = st; craftOrder[#craftOrder + 1] = st
      end
      st.crafts = st.crafts + n; st.need = st.need + need; st.have = st.have + have
      if depth > st.depth then st.depth = depth end
      send(k.c, consumer, id, rest)
      if n > 0 then
        local p2 = {}
        for x in pairs(path) do p2[x] = true end
        p2[id] = true
        for _, r in ipairs(k.reag) do
          resolve(r[1], r[2] * n, (k.c >= 0) and k.c or consumer, p2, false, depth + 1)
        end
      end
      return
    end
    local r = S.raws[id] or { g = "X", o = "c" }
    local o = (r.o == "c") and consumer or r.o
    local key = (o >= 0) and (o .. "|" .. id) or ("_" .. r.g .. "|" .. id)
    local f = farm[key]
    if not f then f = { o = o, id = id, g = r.g, need = 0, have = 0 }; farm[key] = f; farmOrder[#farmOrder + 1] = f end
    f.need = f.need + need; f.have = f.have + have
    send(o, consumer, id, rest)
  end

  for _, r in ipairs(S.roots) do resolve(r.id, r.need, -1, {}, true, 0) end
  return { crafts = craftOrder, farm = farmOrder, mail = mailOrder }
end

return ns
