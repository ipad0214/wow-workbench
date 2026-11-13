// WoW Forever armory: reads the character state that the armory page embeds as
// `var characterProfileInitialState = {...}`. This is the website's own state, not an official API,
// so it can break when Blizzard changes the page; callers treat ArmoryUnreadable as "fall back to manual".

export class ArmoryUnreadable extends Error {}

// Mapped by id, not by the localized names in the page (those depend on locale and gender)
export const CLASSES = { 1: "Krieger", 2: "Paladin", 3: "Jäger", 4: "Schurke", 5: "Priester", 7: "Schamane", 8: "Magier", 9: "Hexenmeister", 11: "Druide" };
export const RACES = { 1: "Mensch", 2: "Orc", 3: "Zwerg", 4: "Nachtelf", 5: "Untoter", 6: "Tauren", 7: "Gnom", 8: "Troll" };
export const PROFESSIONS = {
  171: "Alchemie", 164: "Schmiedekunst", 333: "Verzauberkunst", 202: "Ingenieurskunst", 165: "Lederverarbeitung",
  197: "Schneiderei", 186: "Bergbau", 182: "Kräuterkunde", 393: "Kürschnerei",
  185: "Kochkunst", 129: "Erste Hilfe", 356: "Angeln",
};

// realm type ("ruleset"); Forever has no realms, only these. Each one has its own auction houses.
export const RULESETS = { 1: "pvp", 2: "normal", 3: "rp", 15: "rppvp" };

const STATE_RE = /var characterProfileInitialState\s*=\s*(\{[\s\S]*?\});\s*<\/script>/;

export const slugFor = (name, surname) => `${name}-${surname}`.toLocaleLowerCase("de");

// onUnknown(list) is called with professions the mapping doesn't know yet (e.g. new Forever ones)
export function parseArmory(html, onUnknown = () => {}) {
  const m = STATE_RE.exec(html);
  if (!m) throw new ArmoryUnreadable("state block missing");
  let c;
  try { c = JSON.parse(m[1]).character; } catch { throw new ArmoryUnreadable("state is not JSON"); }
  if (!c || typeof c.name !== "string") throw new ArmoryUnreadable("no character in state");

  const skills = {};
  const unknown = [];
  for (const p of [...(c.professions?.primaries ?? []), ...(c.professions?.secondaries ?? [])]) {
    const name = PROFESSIONS[p?.id];
    const tier = p?.tiers?.[0];
    if (!name) { unknown.push(`${p?.id}:${p?.name}`); continue; }
    if (Number.isInteger(tier?.skillPoints)) skills[name] = [tier.skillPoints, tier.maxSkillPoints ?? 0];
  }
  if (unknown.length) onUnknown(unknown);
  return {
    name: c.name,
    surname: typeof c.surname === "string" ? c.surname : "",
    level: Number.isInteger(c.level) ? c.level : 0,
    cls: CLASSES[c.class?.id] ?? "",
    race: RACES[c.race?.id] ?? "",
    ...(RULESETS[c.ruleset?.rulesetId] && { realm: RULESETS[c.ruleset.rulesetId] }),
    skills,
  };
}
