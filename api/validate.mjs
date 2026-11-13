// Validation of the per-account state that the page PUTs to /api/state. Everything is checked
// against fixed limits, so one account can't fill the database or the backups.
import { PROFESSIONS, RULESETS } from "./armory.mjs";

export class Bad extends Error {}
const str = (v, max, { min = 0 } = {}) => {
  if (typeof v !== "string" || v.length < min || v.length > max) throw new Bad("invalid string");
  return v;
};
const int = (v, lo, hi) => {
  if (!Number.isInteger(v) || v < lo || v > hi) throw new Bad("invalid number");
  return v;
};
const arr = (v, max) => {
  if (!Array.isArray(v) || v.length > max) throw new Bad("invalid list");
  return v;
};
const PROF_NAMES = new Set(Object.values(PROFESSIONS));
const REALMS = new Set(Object.values(RULESETS));
const realm = v => { if (!REALMS.has(v)) throw new Bad("invalid realm"); return v; };
const skills = v => {
  if (!v || typeof v !== "object" || Array.isArray(v)) throw new Bad("invalid skills");
  const entries = Object.entries(v);
  if (entries.length > 12) throw new Bad("invalid skills");
  return Object.fromEntries(entries.map(([p, s]) => {
    if (!PROF_NAMES.has(p)) throw new Bad("invalid skills");
    arr(s, 2);
    return [p, [int(s[0], 0, 450), int(s[1], 0, 450)]];
  }));
};
export function validate(body) {
  if (!body || typeof body !== "object") throw new Bad("invalid body");
  return {
    chars: arr(body.chars, 50).map(c => ({
      id: str(c?.id, 40, { min: 1 }),
      name: str(c?.name, 40, { min: 1 }),
      cls: str(c?.cls ?? "", 20),
      race: str(c?.race ?? "", 20),
      profs: arr(c?.profs ?? [], 12).map(p => str(p, 30)),
      // filled from the armory; manual characters don't have them
      ...(c?.surname != null && { surname: str(c.surname, 24) }),
      ...(c?.level != null && { level: int(c.level, 0, 80) }),
      ...(c?.skills != null && { skills: skills(c.skills) }),
      ...(c?.syncedAt != null && { syncedAt: str(c.syncedAt, 30) }),
      ...(c?.realm != null && { realm: realm(c.realm) }),
    })),
    // realm type the AH prices come from; unset: taken from the characters
    ...(body.realm != null && { realm: realm(body.realm) }),
    list: arr(body.list ?? [], 200).map(e => ({
      i: int(e?.i, 0, 1e6),
      item: int(e?.item, -1e7, 1e7),
      qty: int(e?.qty, 1, 999),
    })),
    // what the characters own, from the in-game addon (bags, bank, mail); unset: never imported
    ...(body.stock != null && { stock: stock(body.stock) }),
  };
}

const ITEM_ID = /^[1-9]\d{0,6}$/;
function stock(v) {
  if (!v || typeof v !== "object" || Array.isArray(v)) throw new Bad("invalid stock");
  return {
    at: str(v.at, 30),
    chars: arr(v.chars, 20).map(c => {
      const items = c?.items;
      if (!items || typeof items !== "object" || Array.isArray(items)) throw new Bad("invalid stock");
      const entries = Object.entries(items);
      if (entries.length > 600) throw new Bad("invalid stock");
      return {
        name: str(c.name, 40, { min: 1 }),
        at: str(c.at, 30),
        items: Object.fromEntries(entries.map(([id, n]) => {
          if (!ITEM_ID.test(id)) throw new Bad("invalid stock");
          return [id, int(n, 1, 100000)];
        })),
      };
    }),
  };
}
