-- Werkbank addon: reads bags, bank and mailbox. Everything here returns { [itemID] = count }.
-- The bank and the mailbox can only be read while they are open; the caller keeps the last result.
local _, ns = ...
local Scan = {}
ns.Scan = Scan

-- Which containers are bags, which are the character's bank and which the account bank. Taken from the
-- names in Enum.BagIndex, so it works with the old bank (Bank, BankBag_n) and the tabbed one
-- (CharacterBankTab_n). The containers that hold the bank bags themselves (Bankbag, Characterbanktab,
-- Accountbanktab without a number) are left out, or the bags would count as stock.
local bagIds, bankIds, accountIds
local function classify()
  if bagIds then return end
  bagIds, bankIds, accountIds = {}, {}, {}
  if Enum and Enum.BagIndex then
    for name, id in pairs(Enum.BagIndex) do
      local n = string.lower(name)
      if n == "backpack" or n == "reagentbag" or string.find(n, "^bag_%d+$") then
        bagIds[#bagIds + 1] = id
      elseif string.find(n, "^accountbanktab_%d+$") then
        accountIds[#accountIds + 1] = id
      elseif n == "bank" or n == "reagentbank" or string.find(n, "^bankbag_%d+$") or string.find(n, "^characterbanktab_%d+$") then
        bankIds[#bankIds + 1] = id
      end
    end
  else
    local bags, bankBags = NUM_BAG_SLOTS or 4, NUM_BANKBAGSLOTS or 7
    for i = 0, bags do bagIds[#bagIds + 1] = i end
    bankIds[#bankIds + 1] = BANK_CONTAINER or -1
    for i = bags + 1, bags + bankBags do bankIds[#bankIds + 1] = i end
  end
end

local function numSlots(bag)
  if C_Container and C_Container.GetContainerNumSlots then return C_Container.GetContainerNumSlots(bag) or 0 end
  return GetContainerNumSlots and GetContainerNumSlots(bag) or 0
end
local function slotItem(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if info then return info.itemID, info.stackCount or 1 end
    return nil
  end
  if GetContainerItemInfo then
    local _, count, _, _, _, _, _, _, _, id = GetContainerItemInfo(bag, slot)
    return id, count or 1
  end
end

-- counts and the number of slots seen (0: the containers aren't readable right now)
local function count(ids)
  local out, slots = {}, 0
  for _, bag in ipairs(ids) do
    local n = numSlots(bag)
    slots = slots + n
    for slot = 1, n do
      local id, c = slotItem(bag, slot)
      if id then out[id] = (out[id] or 0) + c end
    end
  end
  return out, slots
end

function Scan.bags()
  classify()
  return (count(bagIds))
end
-- nil when the bank isn't readable (closed)
function Scan.bank()
  classify()
  local items, slots = count(bankIds)
  if slots == 0 then return nil end
  return items
end
function Scan.accountBank()
  classify()
  if #accountIds == 0 then return nil end
  local items, slots = count(accountIds)
  if slots == 0 then return nil end
  return items
end

-- attachments of every mail in the inbox (the first 50 the client loads)
function Scan.mail()
  local out = {}
  local per = ATTACHMENTS_MAX_RECEIVE or 16
  for i = 1, (GetInboxNumItems and GetInboxNumItems() or 0) do
    for a = 1, per do
      local _, id, _, c = GetInboxItem(i, a)
      if id then out[id] = (out[id] or 0) + (c or 1) end
    end
  end
  return out
end

-- what is attached to the mail being sent right now
function Scan.sendMail()
  local out, any = {}, false
  for a = 1, (ATTACHMENTS_MAX_SEND or 12) do
    local _, id, _, c = GetSendMailItem(a)
    if id then out[id] = (out[id] or 0) + (c or 1); any = true end
  end
  return any and out or nil
end

return Scan
