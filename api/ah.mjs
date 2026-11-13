// Auction house prices for WoW Forever from Blizzard's Game Data API.
// Not officially documented: auction data sits under rulesets in the dynamic-forever-<region>
// namespace (see docs/ah-prices.md). Blizzard only serves whole snapshots of a house (no per-item
// lookup), so the cheapest price per item is kept in a small SQLite cache and the snapshots are
// re-checked on demand, at most every CHECK_MS per house.
const CHECK_MS = 5 * 60 * 1000;
const HOUSES_MS = 24 * 3600 * 1000;
const MAX_BYTES = 20 * 1024 * 1024;
const PARALLEL = 2;

export class AhUnavailable extends Error {}

// "A" | "H" | null; Blackwater (neutral) and anything unknown is skipped
export function factionOf(name) {
  if (/alliance|allianz/i.test(name)) return "A";
  if (/horde/i.test(name)) return "H";
  return null;
}

// lowest buyout per unit (copper) and number of units on offer, per item id
export function cheapest(house, commodities) {
  const best = new Map();
  const add = (id, unit, qty) => {
    if (!Number.isInteger(id) || !(unit > 0) || !(qty > 0)) return;
    const cur = best.get(id);
    if (!cur) best.set(id, { unit, qty });
    else { cur.unit = Math.min(cur.unit, unit); cur.qty += qty; }
  };
  // buyout is the price of the whole stack; auctions without buyout (bid only) don't count
  for (const a of house?.auctions ?? []) if (a?.buyout) add(a.item?.id, Math.ceil(a.buyout / (a.quantity || 1)), a.quantity || 1);
  for (const a of commodities?.auctions ?? []) add(a?.item?.id, a?.unit_price, a?.quantity);
  return best;
}

async function readLimited(res) {
  const chunks = []; let size = 0;
  for await (const c of res.body) {
    size += c.length;
    if (size > MAX_BYTES) throw new AhUnavailable("response too large");
    chunks.push(c);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

export function createAh({ clientId, clientSecret, region = "eu", ruleset = 1, locale = "de_DE", db,
  fetch = globalThis.fetch, now = Date.now, log = console }) {
  // the .env placeholder "change-me" counts as no key, so wow-api doesn't log in with it every 5 minutes
  const isKey = v => !!v && !/^change[- ]?me$/i.test(v.trim());
  const configured = isKey(clientId) && isKey(clientSecret);
  db.exec(`CREATE TABLE IF NOT EXISTS ah_house(
      id INTEGER PRIMARY KEY, faction TEXT NOT NULL, name TEXT NOT NULL,
      last_modified TEXT, updated_at TEXT, listings INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS ah_price(
      house INTEGER NOT NULL, item INTEGER NOT NULL, unit INTEGER NOT NULL, qty INTEGER NOT NULL,
      PRIMARY KEY(house, item)) WITHOUT ROWID;`);
  const q = {
    houses: db.prepare("SELECT id, faction, name, last_modified, updated_at, listings FROM ah_house ORDER BY faction, id"),
    upsertHouse: db.prepare(`INSERT INTO ah_house(id, faction, name) VALUES(?,?,?)
      ON CONFLICT(id) DO UPDATE SET faction=excluded.faction, name=excluded.name`),
    dropHouse: db.prepare("DELETE FROM ah_house WHERE id = ?"),
    dropPrices: db.prepare("DELETE FROM ah_price WHERE house = ?"),
    putPrice: db.prepare("INSERT INTO ah_price(house, item, unit, qty) VALUES(?,?,?,?)"),
    stamp: db.prepare("UPDATE ah_house SET last_modified = ?, updated_at = ?, listings = ? WHERE id = ?"),
    prices: db.prepare("SELECT house, item, unit, qty FROM ah_price WHERE item IN (SELECT value FROM json_each(?))"),
  };

  let token = null, tokenUntil = 0;
  async function getToken() {
    if (token && now() < tokenUntil) return token;
    const res = await fetch("https://oauth.battle.net/token", {
      method: "POST",
      headers: { Authorization: "Basic " + Buffer.from(`${clientId}:${clientSecret}`).toString("base64"),
        "Content-Type": "application/x-www-form-urlencoded" },
      body: "grant_type=client_credentials",
      signal: AbortSignal.timeout(10000),
    });
    if (!res.ok) { res.body?.cancel().catch(() => {}); throw new AhUnavailable(`token status ${res.status}`); }
    const t = await res.json();
    token = t.access_token;
    tokenUntil = now() + Math.max(60, (t.expires_in || 3600) - 300) * 1000;
    return token;
  }
  // {status, json, lastModified}; 304 and 404 come back without json, other errors throw
  async function get(path, ifModifiedSince, retried = false) {
    const url = `https://${region}.api.blizzard.com${path}?namespace=dynamic-forever-${region}&locale=${locale}`;
    const headers = { Authorization: `Bearer ${await getToken()}`, Accept: "application/json" };
    if (ifModifiedSince) headers["If-Modified-Since"] = ifModifiedSince;
    let res;
    try { res = await fetch(url, { headers, signal: AbortSignal.timeout(20000) }); }
    catch (e) { throw new AhUnavailable(`fetch ${path}: ${e.message}`); }
    const lastModified = res.headers.get("last-modified");
    if (res.status === 401 && !retried) { res.body?.cancel().catch(() => {}); token = null; return get(path, ifModifiedSince, true); }
    if (res.status === 304 || res.status === 404) { res.body?.cancel().catch(() => {}); return { status: res.status, lastModified }; }
    if (!res.ok) { res.body?.cancel().catch(() => {}); throw new AhUnavailable(`${path}: status ${res.status}`); }
    return { status: 200, json: await readLimited(res), lastModified };
  }

  let housesAt = 0;
  async function loadHouses() {
    housesAt = now(); // also after a failure: retry in HOUSES_MS, or right away when none are known
    const r = await get(`/data/wow/ruleset/${ruleset}/auctions/`);
    if (r.status !== 200) throw new AhUnavailable(`house index: status ${r.status}`);
    const keep = new Set();
    db.exec("BEGIN");
    try {
      for (const h of r.json?.auctions ?? []) {
        const f = factionOf(String(h?.name ?? ""));
        if (!f || !Number.isInteger(h.id)) continue;
        q.upsertHouse.run(h.id, f, String(h.name).slice(0, 80));
        keep.add(h.id);
      }
      for (const h of q.houses.all()) if (!keep.has(h.id)) { q.dropHouse.run(h.id); q.dropPrices.run(h.id); }
      db.exec("COMMIT");
    } catch (e) { db.exec("ROLLBACK"); throw e; }
  }

  async function refreshHouse(h) {
    const base = `/data/wow/ruleset/${ruleset}/auctions/${h.id}`;
    const r = await get(base, h.last_modified);
    if (r.status === 304) return;
    if (r.status === 404) throw new AhUnavailable(`house ${h.id}: status 404`);
    const c = await get(`${base}/commodities`);
    const best = cheapest(r.json, c.json);
    const updated = r.lastModified ? new Date(r.lastModified).toISOString() : new Date(now()).toISOString();
    db.exec("BEGIN");
    try {
      q.dropPrices.run(h.id);
      for (const [item, { unit, qty }] of best) q.putPrice.run(h.id, item, unit, qty);
      q.stamp.run(r.lastModified ?? null, updated, best.size, h.id);
      db.exec("COMMIT");
    } catch (e) { db.exec("ROLLBACK"); throw e; }
  }

  const checked = new Map(); // house id -> last check (ms), also after errors, so a broken API isn't hammered
  async function refresh() {
    if (!q.houses.all().length || now() - housesAt >= HOUSES_MS) {
      if (!q.houses.all().length && now() - housesAt < CHECK_MS) throw new AhUnavailable("house index failed recently");
      try { await loadHouses(); } catch (e) { if (!q.houses.all().length) throw e; log.error(`ah: ${e.message}`); }
    }
    const due = q.houses.all().filter(h => now() - (checked.get(h.id) ?? 0) >= CHECK_MS);
    for (const h of due) checked.set(h.id, now());
    const queue = [...due];
    await Promise.all(Array.from({ length: PARALLEL }, async () => {
      for (let h; (h = queue.shift());) {
        try { await refreshHouse(h); } catch (e) { log.error(`ah: ${e.message}`); }
      }
    }));
  }
  let running = null;
  const ensureFresh = () => running ??= refresh().finally(() => { running = null; });

  // waits up to waitMs for a refresh, then answers from the cache
  async function prices(ids, waitMs = 10000) {
    if (!configured) throw new AhUnavailable("no key");
    let failed = null;
    const done = ensureFresh().catch(e => { failed = e; });
    let timer;
    await Promise.race([done, new Promise(r => { timer = setTimeout(r, waitMs); })]);
    clearTimeout(timer);
    const houses = q.houses.all().filter(h => h.listings > 0);
    if (!houses.length) {
      if (failed) log.error(`ah: ${failed.message}`);
      throw new AhUnavailable(failed ? failed.message : "no data yet");
    }
    const out = {};
    for (const p of q.prices.all(JSON.stringify(ids))) (out[p.item] ??= {})[p.house] = [p.unit, p.qty];
    return {
      houses: houses.map(h => ({ id: h.id, faction: h.faction, name: h.name, updatedAt: h.updated_at })),
      prices: out,
    };
  }

  return { configured, prices, ensureFresh };
}
