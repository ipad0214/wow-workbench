-- Werkbank addon: saved data, events, the shopping list, and netting the stock of all characters
-- against the plan.
--
-- WerkbankDB (account-wide SavedVariables):
--   shop    = { { item, r, qty } }   the shopping list: product, recipe index in Data.recipes, how often
--             to craft it. Filled in the profession window (Craft.lua) or by /werkbank import.
--   shopAt  = when the list last changed
--   list    = the WB1 string of addon 1.0; turned into shop once
--   extra   = { [recipeID] = { item, prof, yMin, yMax, reag } }   recipes the database doesn't have (added by
--             WoW Forever), read from the game in the profession window; added to Data on every login
--   chars   = { ["Realm-Name"] = { name, realm, at, bags, bank, mail, transit = { { at, items } } } }
--             bank/mail: nil until the character opened them once with the addon
--   account = { at, items }   account bank, if the client has one
--   export  = the WC1 string from the last /werkbank export, logout or /reload; the website reads it
--             from this file. Only items of the list (all items while there is no list).
--   ui      = window position and filter
local addonName, ns = ...
local Data, Codec, Net, Scan, Plan = ns.Data, ns.Codec, ns.Net, ns.Scan, ns.Plan
local Core = {}
ns.Core = Core

local db, myKey, list, result
local bankOpen, mailOpen, pendingMail = false, false, nil
local totals = {}   -- [char key] = everything that character owns; rebuilt in Core.update
Core.byId = {}      -- [id] = { need, have } over all rows of the list, for tooltips

local function add(t, items)
  for id, n in pairs(items or {}) do t[id] = (t[id] or 0) + n end
end
local function lower(s) return string.lower(s or "") end

function Core.list() return list end
function Core.result() return result end
function Core.db() return db end
function Core.me() return db.chars[myKey] end

-- everything a character owns: bags, bank, mailbox, and mail from own characters still on its way
function Core.charItems(c)
  local t = {}
  add(t, c.bags); add(t, c.bank); add(t, c.mail)
  for _, tr in ipairs(c.transit or {}) do add(t, tr.items) end
  return t
end
function Core.pool()
  local t = {}
  for _, items in pairs(totals) do add(t, items) end
  if db.account then add(t, db.account.items) end
  return t
end
-- Where an item lies: "Taschen 3, Bank 2 · Bandor: Bank 4, Post 1 · Kriegsmeutenbank 2". The current
-- character comes first and without its name, then the others by name. Post: in the mailbox;
-- unterwegs: mail from an own character that hasn't been picked up. "" when nobody has it.
local PLACES = { { "bags", "Taschen" }, { "bank", "Bank" }, { "mail", "Post" } }
function Core.whereText(id)
  local me, others = nil, {}
  for _, c in pairs(db.chars) do
    local parts = {}
    for _, p in ipairs(PLACES) do
      local n = c[p[1]] and c[p[1]][id]
      if n and n > 0 then parts[#parts + 1] = p[2] .. " " .. n end
    end
    local t = 0
    for _, tr in ipairs(c.transit or {}) do t = t + (tr.items[id] or 0) end
    if t > 0 then parts[#parts + 1] = "unterwegs " .. t end
    if #parts > 0 then
      local text = table.concat(parts, ", ")
      if c == Core.me() then me = text else others[#others + 1] = { c.name, c.name .. ": " .. text } end
    end
  end
  table.sort(others, function(a, b) return a[1] < b[1] end)
  local out = { me }
  for _, o in ipairs(others) do out[#out + 1] = o[2] end
  local acc = db.account and db.account.items[id]
  if acc and acc > 0 then out[#out + 1] = "Kriegsmeutenbank " .. acc end
  return table.concat(out, " · ")
end
-- index of the current character in the list's characters (0-based like the list), or -1
function Core.myIndex()
  if not list then return -1 end
  local me = lower(Core.me().name)
  for i, name in ipairs(list.chars) do
    if lower(name) == me then return i - 1 end
  end
  return -1
end

-- the ids the website needs for this list: everything in it, from the finished items down to the ore
local function listIds()
  if not list then return nil end
  local ids = {}
  for _, r in ipairs(list.roots) do ids[r.id] = true end
  for id, k in pairs(list.crafts) do
    ids[id] = true
    for _, r in ipairs(k.reag) do ids[r[1]] = true end
  end
  for id in pairs(list.raws) do ids[id] = true end
  return ids
end
local function only(items, ids)
  if not ids then return items end
  local out = {}
  for id, n in pairs(items) do if ids[id] then out[id] = n end end
  return out
end
function Core.counts()
  local ids, chars = listIds(), {}
  for _, c in pairs(db.chars) do
    local at = c.at or 0
    for _, tr in ipairs(c.transit or {}) do if tr.at > at then at = tr.at end end
    chars[#chars + 1] = { name = c.name, at = at, items = only(Core.charItems(c), ids) }
  end
  if db.account then chars[#chars + 1] = { name = "Kriegsmeutenbank", at = db.account.at, items = only(db.account.items, ids) } end
  return { t = time(), chars = chars }
end
-- the WC1 string; kept in the SavedVariables for the website
function Core.writeExport()
  db.export = Codec.encodeCounts(Core.counts())
  return db.export
end

-- the characters the planner may use: those with a profile (logged in since addon 1.1), by name
function Core.planChars()
  local out = {}
  for _, c in pairs(db.chars) do
    if c.profile then out[#out + 1] = { name = c.name, profs = c.profile.profs, recipes = c.profile.recipes } end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- ---------- the shopping list ----------
local MAX_QTY = 999
function Core.shop() return db.shop end
local function shopChanged()
  db.shopAt = time()
  Core.update(true)
end
-- recipe index n, qty times more on shop (the same recipe adds up); returns the new quantity
local function put(shop, n, qty)
  for _, e in ipairs(shop) do
    if e.r == n then e.qty = math.min(MAX_QTY, e.qty + qty); return e.qty end
  end
  shop[#shop + 1] = { item = Data.recipes[n][1], r = n, qty = math.min(MAX_QTY, qty) }
  return shop[#shop].qty
end
function Core.addToShop(n, qty)
  local total = put(db.shop, n, math.max(1, math.floor(tonumber(qty) or 1)))
  shopChanged()
  return total
end
-- how often recipe n is on the list (0: not)
function Core.shopQty(n)
  for _, e in ipairs(db.shop) do if e.r == n then return e.qty end end
  return 0
end
-- entry i to qty; 0 removes it
function Core.setShopQty(i, qty)
  if not db.shop[i] then return end
  if qty <= 0 then table.remove(db.shop, i) else db.shop[i].qty = math.min(MAX_QTY, qty) end
  shopChanged()
end
function Core.clearShop()
  db.shop = {}
  shopChanged()
end
-- ---------- recipes read from the game ----------
local function register(e)
  local p
  for i, name in ipairs(Data.profsDe) do if name == e.prof then p = i - 1 end end
  if not p then
    Data.profs[#Data.profs + 1], Data.profsDe[#Data.profsDe + 1] = e.prof, e.prof
    p = #Data.profsDe - 1
  end
  local n = #Data.recipes + 1
  Data.recipes[n] = { e.item, p, 0, e.yMin, e.yMax, e.reag, 0, 0 }
  Data.index(n)
  return n
end
-- a recipe from Profile.recipeFromGame: saved for every login, and its index in Data.recipes
function Core.addRecipe(recipeID, e)
  db.extra[recipeID] = e
  return register(e)
end
local function registerSaved()
  local ids = {}
  for id in pairs(db.extra) do ids[#ids + 1] = id end
  table.sort(ids)   -- same order, same indexes on every login
  for _, id in ipairs(ids) do register(db.extra[id]) end
end

-- entries whose recipe index no longer matches its product (the database changed) get the recipe the
-- planner picks for it
local function normalizeShop()
  local out = {}
  for _, e in ipairs(db.shop) do
    local r = Data.recipes[e.r]
    if not (r and r[1] == e.item) then e.r = Plan.pickRecipe(Core.planChars(), e.item) end
    if e.r then out[#out + 1] = e end
  end
  db.shop = out
end

-- what shows the plan (list window, profession window note, tracker) registers here and is redrawn
-- after every update
local listeners = {}
function Core.onUpdate(fn) listeners[#listeners + 1] = fn end
function Core.notify() for _, fn in ipairs(listeners) do fn() end end

-- plan the list and net the stock against it; quiet: no chat message for rows that just got done
function Core.update(quiet)
  totals = {}
  for key, c in pairs(db.chars) do totals[key] = Core.charItems(c) end
  local before = Core.byId
  list = #db.shop > 0 and Plan.structure(db.shop, Core.planChars(), db.shopAt) or nil
  if list then
    result = Net.evaluate(list, Core.pool())
    local by = {}
    local function acc(id, need, have)
      local e = by[id] or { need = 0, have = 0 }
      e.need = e.need + need; e.have = e.have + have
      by[id] = e
    end
    for _, f in ipairs(result.farm) do acc(f.id, f.need, f.have) end
    for _, s in ipairs(result.crafts) do acc(s.id, s.need, s.have) end
    Core.byId = by
    if not quiet then
      for id, e in pairs(by) do
        local b = before[id]
        if b and e.need > 0 and e.have >= e.need and b.have < b.need then
          ns.UI.say(string.format("%s vollständig (%d/%d)", ns.UI.itemName(id), e.have, e.need))
        end
      end
    end
  else
    result, Core.byId = nil, {}
  end
  Core.notify()
end

-- a WB1 list from the website replaces the shopping list: its items, planned here with the characters'
-- profiles. Returns true, or false and a message.
function Core.setList(text)
  local S, err = Codec.decodeList(string.gsub(text or "", "[\r\n\t]", ""))
  if not S then return false, err end
  local chars, shop = Core.planChars(), {}
  for _, root in ipairs(S.roots) do
    local e = Plan.entryFor(chars, root.id, root.need)
    if e then put(shop, e.r, e.qty) end
  end
  db.shop, db.list = shop, nil
  shopChanged()
  return true
end

local function scanBags()
  local c = Core.me()
  c.bags, c.at = Scan.bags(), time()
  if bankOpen then
    local bank = Scan.bank()
    if bank then c.bank = bank end
    local account = Scan.accountBank()
    if account then db.account = { at = time(), items = account } end
  end
end
local function scanMail()
  if not mailOpen then return end
  local c = Core.me()
  c.mail, c.at = Scan.mail(), time()
  c.transit = {}   -- everything that was on its way is in the mailbox now
end

-- mail to one of your own characters counts at the recipient right away
local function onSendMail(recipient)
  local items = Scan.sendMail()
  if not items or not recipient then pendingMail = nil; return end
  local name, realm = string.match(recipient, "^([^%-]+)%-?(.*)$")
  pendingMail = { name = name, realm = realm ~= "" and realm or nil, items = items }
end
local function mailSent()
  local p = pendingMail
  pendingMail = nil
  if not p or not p.name then return end
  -- "Name" goes to your own realm, "Name-Realm" to that one (realm without spaces, like the client writes it)
  local realm = lower(p.realm or Core.me().realm)
  local target
  for _, c in pairs(db.chars) do
    if lower(c.name) == lower(p.name) and lower(c.realm) == realm then target = c end
  end
  if not target then return end   -- not one of yours (or not logged in with the addon yet)
  target.transit = target.transit or {}
  target.transit[#target.transit + 1] = { at = time(), items = p.items }
end

-- One event frame for the whole addon. An event can have several handlers; they run in the order they
-- were added, so Core's (loaded first, sets up WerkbankDB on login) run before Profile's.
local frame, handlers = CreateFrame("Frame"), {}
function Core.on(event, fn)
  if not handlers[event] then
    -- events that this client doesn't know are skipped instead of breaking the addon
    if not pcall(frame.RegisterEvent, frame, event) then return end
    handlers[event] = {}
  end
  table.insert(handlers[event], fn)
end
local on = Core.on

on("PLAYER_LOGIN", function()
  WerkbankDB = WerkbankDB or {}
  db = WerkbankDB
  db.chars, db.ui = db.chars or {}, db.ui or {}
  -- the normalized realm ("DieAldor") is what mail recipients use
  local name = UnitName("player")
  local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or string.gsub(GetRealmName(), "[%s%-]", "")
  myKey = realm .. "-" .. name
  db.chars[myKey] = db.chars[myKey] or { name = name, realm = realm, at = 0, bags = {}, transit = {} }
  db.shop, db.extra = db.shop or {}, db.extra or {}
  registerSaved()
  normalizeShop()
  ns.UI.init()
  scanBags()
  if db.list then Core.setList(db.list) end   -- the list of addon 1.0, once
  -- no Core.update here: Profile's PLAYER_LOGIN runs right after this one, reads the professions and
  -- updates (planning needs them)
  if type(SendMail) == "function" then hooksecurefunc("SendMail", onSendMail) end
  if C_Mail and type(C_Mail.SendMail) == "function" then hooksecurefunc(C_Mail, "SendMail", onSendMail) end
end)
on("BAG_UPDATE_DELAYED", function() if db then scanBags(); Core.update() end end)
local function bank(open)
  return function()
    bankOpen = open
    if open and db then scanBags(); Core.update() end
  end
end
on("BANKFRAME_OPENED", bank(true))
on("BANKFRAME_CLOSED", bank(false))
on("PLAYERBANKSLOTS_CHANGED", function() if db and bankOpen then scanBags(); Core.update() end end)
-- newer clients open bank and mailbox through the interaction manager
local function interaction(open)
  return function(kind)
    local T = Enum and Enum.PlayerInteractionType
    if not T then return end
    if kind == T.Banker or kind == T.CharacterBanker or kind == T.AccountBanker then bank(open)() end
    if kind == T.MailInfo then mailOpen = open; if open and db then scanMail(); Core.update() end end
  end
end
on("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", interaction(true))
on("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", interaction(false))
on("MAIL_SHOW", function() mailOpen = true end)
on("MAIL_CLOSED", function() mailOpen = false end)
on("MAIL_INBOX_UPDATE", function() if db then scanMail(); Core.update() end end)
on("MAIL_SEND_SUCCESS", function() if db then mailSent(); Core.update() end end)
on("MAIL_FAILED", function() pendingMail = nil end)
on("GET_ITEM_INFO_RECEIVED", function() ns.UI.namesArrived() end)
-- also fires on /reload, right before the SavedVariables are written
on("PLAYER_LOGOUT", function() if db then Core.writeExport() end end)
frame:SetScript("OnEvent", function(_, event, ...)
  for _, fn in ipairs(handlers[event]) do fn(...) end
end)

return Core
