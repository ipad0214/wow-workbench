-- Werkbank addon: saved data, events, and netting the stock of all characters against the list.
--
-- WerkbankDB (account-wide SavedVariables):
--   list    = the WB1 string from the website (decoded on login)
--   chars   = { ["Realm-Name"] = { name, realm, at, bags, bank, mail, transit = { { at, items } } } }
--             bank/mail: nil until the character opened them once with the addon
--   account = { at, items }   account bank, if the client has one
--   export  = the WC1 string from the last /werkbank export, logout or /reload; the website reads it
--             from this file. Only items of the list (all items while there is no list).
--   ui      = window position and filter
local addonName, ns = ...
local Codec, Net, Scan = ns.Codec, ns.Net, ns.Scan
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
-- { { name, n } } for one item, most first
function Core.holders(id)
  local out = {}
  for key, items in pairs(totals) do
    local n = items[id]
    if n and n > 0 then out[#out + 1] = { name = db.chars[key].name, n = n } end
  end
  if db.account and db.account.items[id] then out[#out + 1] = { name = "Kriegsmeutenbank", n = db.account.items[id] } end
  table.sort(out, function(a, b) return a.n > b.n end)
  return out
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

-- recompute the list against the stock; quiet: no chat message for rows that just got done
function Core.update(quiet)
  totals = {}
  for key, c in pairs(db.chars) do totals[key] = Core.charItems(c) end
  local before = Core.byId
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
          print(string.format("|cffe08a3cWerkbank:|r %s vollständig (%d/%d)", ns.UI.itemName(id), e.have, e.need))
        end
      end
    end
  else
    result, Core.byId = nil, {}
  end
  ns.UI.refresh()
end

-- returns true, or false and a message
function Core.setList(text)
  local clean = string.gsub(text or "", "[\r\n\t]", "")
  local S, err = Codec.decodeList(clean)
  if not S then return false, err end
  db.list, list = clean, S
  Core.update(true)
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

local frame = CreateFrame("Frame")
local function on(event, fn)
  -- events that this client doesn't know are skipped instead of breaking the addon
  if pcall(frame.RegisterEvent, frame, event) then frame[event] = fn end
end

on("PLAYER_LOGIN", function()
  WerkbankDB = WerkbankDB or {}
  db = WerkbankDB
  db.chars, db.ui = db.chars or {}, db.ui or {}
  -- the normalized realm ("DieAldor") is what mail recipients use
  local name = UnitName("player")
  local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or string.gsub(GetRealmName(), "[%s%-]", "")
  myKey = realm .. "-" .. name
  db.chars[myKey] = db.chars[myKey] or { name = name, realm = realm, at = 0, bags = {}, transit = {} }
  if db.list then
    local S = Codec.decodeList(db.list)
    list = S
  end
  ns.UI.init()
  scanBags()
  Core.update(true)
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
  return function(_, kind)
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
frame:SetScript("OnEvent", function(self, event, ...) self[event](self, ...) end)

return Core
