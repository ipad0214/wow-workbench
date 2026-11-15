-- Werkbank addon: the profile of every character: level, class, race, faction, professions with skill
-- points, and the recipes it has learned. Each character saves its own on login and whenever something
-- changes; the other characters keep their last state. Skills and recipes only change while a character
-- is played, so that state is current.
--
-- WerkbankDB.chars[key].profile = {
--   at, level, class, classFile, race, faction,
--   profs   = { ["Schmiedekunst"] = { 285, 300 } },          -- like the armory's skills on the website
--   recipes = { ["Schmiedekunst"] = { at, known = { [productId] = true } } },
-- }
-- Recipes are stored by product item id, the key of the recipe database (Data.lua); enchants by their
-- negative spell id. They can only be read while the profession window is open.
local _, ns = ...
local Data, Core = ns.Data, ns.Core
local Profile = {}
ns.Profile = Profile

-- profession names by lower-case German or English name, for the classic calls that only give names
local BY_NAME = {}
for _, p in pairs(Data.profNames) do BY_NAME[string.lower(p[1])] = p[1]; BY_NAME[string.lower(p[2])] = p[1] end

local function profName(line, name)
  return (line and Data.profNames[line] and Data.profNames[line][1]) or (name and BY_NAME[string.lower(name)]) or nil
end
local function pack(...) return { n = select("#", ...), ... } end
local function call(t, f, ...)
  if type(t) == "table" and type(t[f]) == "function" then return t[f](...) end
end

-- ---------- professions ----------
-- profs { [German name] = { skill, max } }, raw (everything the client returned, for /werkbank debug),
-- via (which call was used; nil when this client has neither)
function Profile.readProfessions()
  local profs, raw, via = {}, {}, nil
  local function add(name, line, rank, max)
    local de = profName(line, name)
    raw[#raw + 1] = { name = name, line = line, rank = rank, max = max, de = de }
    if de and rank then profs[de] = { rank, max or 0 } end
  end
  if type(GetProfessions) == "function" and type(GetProfessionInfo) == "function" then
    via = "GetProfessions"
    local idx = pack(GetProfessions())
    for i = 1, idx.n do
      if idx[i] then
        local name, _, rank, max, _, _, line = GetProfessionInfo(idx[i])
        add(name, line, rank, max)
      end
    end
  end
  if #raw == 0 and type(GetNumSkillLines) == "function" and type(GetSkillLineInfo) == "function" then
    via = "GetSkillLineInfo"
    for i = 1, GetNumSkillLines() or 0 do
      local name, header, _, rank, _, _, max = GetSkillLineInfo(i)
      if not header and name and BY_NAME[string.lower(name)] then add(name, nil, rank, max) end
    end
  end
  return profs, raw, via
end

-- ---------- learned recipes of the open profession window ----------
local function idFromLink(link)
  if not link then return nil end
  local item = tonumber(string.match(link, "item:(%d+)"))
  if item then return item end
  local spell = tonumber(string.match(link, "enchant:(%d+)") or string.match(link, "spell:(%d+)"))
  return spell and -spell or nil
end

-- recipe id -> output item (false: none), for this session; the window sends many updates
local outputs = {}
local function outputOf(T, id)
  if outputs[id] == nil then
    local s = call(T, "GetRecipeSchematic", id, false)
    local out = type(s) == "table" and s.outputItemID or idFromLink(call(T, "GetRecipeItemLink", id))
    outputs[id] = (out and out > 0) and out or false
  end
  return outputs[id]
end

-- the modern client: C_TradeSkillUI. Returns the profession and { [key] = true }, or nil and why not.
local function scanModern()
  local T = C_TradeSkillUI
  if type(T) ~= "table" or type(T.GetAllRecipeIDs) ~= "function" then return nil end
  -- a linked profession, a guild's or an NPC's: not this character's recipes
  if call(T, "IsTradeSkillLinked") or call(T, "IsTradeSkillGuild") or call(T, "IsNPCCrafting") then return nil, "fremd" end
  local name, line
  local info = call(T, "GetBaseProfessionInfo")
  if type(info) == "table" and info.professionID then
    line, name = info.professionID, info.professionName
  else
    local a, b = call(T, "GetTradeSkillLine")
    if type(a) == "number" then line, name = a, b else name = a end
  end
  local prof = profName(line, name)
  if not prof then return nil, "Beruf unbekannt: " .. tostring(name) .. " (" .. tostring(line) .. ")" end
  local known = {}
  for _, id in ipairs(T.GetAllRecipeIDs() or {}) do
    local r = call(T, "GetRecipeInfo", id)
    if type(r) == "table" and r.learned then
      -- the database knows enchants by -spell id, other recipes by their item; a newer client may name a
      -- scroll as an enchant's output, so both keys are kept
      known[-id] = true
      local out = outputOf(T, id)
      if out then known[out] = true end
    end
  end
  return prof, known, "C_TradeSkillUI"
end

-- the classic client: one window for trade skills (GetTradeSkill*), one for Enchanting (GetCraft*)
local function scanClassic(kind)
  local num, info, link, line
  if kind == "craft" then
    num, info, link, line = GetNumCrafts, GetCraftInfo, GetCraftItemLink, GetCraftDisplaySkillLine
  else
    num, info, link, line = GetNumTradeSkills, GetTradeSkillInfo, GetTradeSkillItemLink, GetTradeSkillLine
  end
  if type(num) ~= "function" or type(info) ~= "function" or type(link) ~= "function" or type(line) ~= "function" then return nil end
  local name = line()
  local prof = profName(nil, name)
  if not prof then return nil, "Beruf unbekannt: " .. tostring(name) end
  local known = {}
  for i = 1, num() or 0 do
    local _, a, b = info(i)
    local kindOf = kind == "craft" and b or a   -- GetCraftInfo has the subname in between
    if kindOf ~= "header" and kindOf ~= "subheader" then
      local id = idFromLink(link(i))
      if id then known[id] = true end
    end
  end
  return prof, known, kind == "craft" and "GetCraftInfo" or "GetTradeSkillInfo"
end

-- ---------- saving ----------
local last = {}   -- the last read of this session, for /werkbank debug

local function profile()
  local c = Core.me()
  c.profile = c.profile or { profs = {}, recipes = {} }
  return c.profile
end

-- level, class, race, faction and professions of the current character
function Profile.update()
  if not Core.db() then return end   -- some events come before PLAYER_LOGIN
  local p = profile()
  local className, classFile, classID = UnitClass("player")
  local raceName, _, raceID = UnitRace("player")
  p.class, p.classFile = Data.classNames[classID] or className, classFile
  p.race = Data.raceNames[raceID] or raceName
  p.faction, p.level = UnitFactionGroup("player"), UnitLevel("player")
  local profs, raw, via = Profile.readProfessions()
  last.profs = { raw = raw, via = via, classID = classID, raceID = raceID }
  if via then
    p.profs = profs
    -- a profession that was dropped takes its recipes with it
    for prof in pairs(p.recipes) do if not profs[prof] then p.recipes[prof] = nil end end
  end
  p.at = time()
  ns.UI.refresh()
end

-- the recipes of the profession window that is open right now. A recipe can't be unlearned (only the
-- whole profession, see Profile.update), so every read adds to what was seen: a window that is still
-- filling in, or filtered, never loses recipes.
function Profile.scanRecipes(kind)
  if not Core.db() then return end
  local prof, known, via
  if kind then
    prof, known, via = scanClassic(kind)
  else
    prof, known, via = scanModern()
    if not prof and known == nil then prof, known, via = scanClassic("trade") end
  end
  if not prof then
    last.recipes = { error = known }
    return
  end
  last.recipes = { prof = prof, via = via, known = known }
  local p = profile()
  local saved = p.recipes[prof] or { known = {} }
  local added = false
  for id in pairs(known) do
    if not saved.known[id] then saved.known[id], added = true, true end
  end
  saved.at = time()
  p.recipes[prof] = saved
  if added then ns.UI.refresh() end
end

-- ---------- /werkbank debug ----------
local say = function(text) ns.UI.say(text) end
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
function Profile.debug()
  Profile.update()
  local version, build, _, toc = "?", "?", nil, "?"
  if type(GetBuildInfo) == "function" then version, build, _, toc = GetBuildInfo() end
  say(string.format("Client %s (%s), Interface %s", tostring(version), tostring(build), tostring(toc)))
  local p, pr = profile(), last.profs
  say(string.format("%s: Stufe %s, %s (Klasse %s), %s (Rasse %s), %s", Core.me().name, tostring(p.level), tostring(p.class),
    tostring(pr.classID), tostring(p.race), tostring(pr.raceID), tostring(p.faction)))
  if not pr.via then say("Berufe: dieser Client kennt weder GetProfessions noch GetSkillLineInfo")
  elseif #pr.raw == 0 then say("Berufe über " .. pr.via .. ": keine")
  else
    for _, r in ipairs(pr.raw) do
      say(string.format("Beruf über %s: %s (Skill-Linie %s) %s/%s → %s", pr.via, tostring(r.name), tostring(r.line),
        tostring(r.rank), tostring(r.max), r.de or "|cffd06060nicht zugeordnet|r"))
    end
  end
  local rc = last.recipes
  if not rc then say("Rezepte: in dieser Sitzung noch kein Berufsfenster geöffnet")
  elseif rc.error then say("Rezepte: nicht gelesen (" .. tostring(rc.error) .. ")")
  else
    local inDb = 0
    for _, i in ipairs(Data.byProf[rc.prof] or {}) do
      if rc.known[Data.recipes[i][1]] then inDb = inDb + 1 end
    end
    say(string.format("Rezepte über %s: %s, %d Schlüssel gelesen, %d von %d Rezepten der Datenbank gelernt", rc.via, rc.prof,
      count(rc.known), inDb, #(Data.byProf[rc.prof] or {})))
  end
  say(string.format("Datenbank: %d Rezepte", #Data.recipes))
end

-- ---------- events ----------
-- run fn once the events have settled for delay seconds (the profession window sends many updates)
local function settled(delay, fn)
  local gen = 0
  return function(...)
    gen = gen + 1
    local mine, args = gen, pack(...)
    C_Timer.After(delay, function() if mine == gen then fn(unpack(args, 1, args.n)) end end)
  end
end
local scanSoon = settled(0.5, Profile.scanRecipes)
local updateSoon = settled(0.5, Profile.update)

-- Core.lua loads first, so its PLAYER_LOGIN (which sets up WerkbankDB) runs before this one
Core.on("PLAYER_LOGIN", Profile.update)
Core.on("SKILL_LINES_CHANGED", function() updateSoon() end)
Core.on("PLAYER_LEVEL_UP", function() C_Timer.After(1, Profile.update) end)
for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED", "NEW_RECIPE_LEARNED" }) do
  Core.on(event, function() scanSoon() end)
end
Core.on("CRAFT_SHOW", function() scanSoon("craft") end)
Core.on("CRAFT_UPDATE", function() scanSoon("craft") end)

return Profile
