// Werkbank API: stores characters + shopping list per Keycloak account.
// Only reachable from wow-web inside the private network wow-internal. The identity comes from
// oauth2-proxy (wow-auth), which strips client-supplied X-Forwarded-* user headers and injects
// its own. Never expose this service on another network.
import http from "node:http";
import { mkdirSync, readdirSync, rmSync, existsSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { parseArmory, slugFor, ArmoryUnreadable } from "./armory.mjs";
import { validate, Bad } from "./validate.mjs";
import { createAh, AhUnavailable } from "./ah.mjs";

const PORT = Number(process.env.PORT || 3000);
const DATA_DIR = process.env.DATA_DIR || "/data";
const REQUIRED_GROUP = process.env.REQUIRED_GROUP || ""; // defence in depth, e.g. "/gamers"
// Keycloak end-session endpoint for the logout link; keeps host names out of the frontend
const LOGOUT_URL = process.env.OIDC_ISSUER_URL ? `${process.env.OIDC_ISSUER_URL.replace(/\/$/, "")}/protocol/openid-connect/logout` : "";
const MAX_BODY = 256 * 1024;
const BACKUP_KEEP = 14;
const ARMORY_BASE = process.env.ARMORY_BASE || "https://worldofwarcraft.blizzard.com/de-de/forever/eu/armory/character/";
const ARMORY_MAX = 3 * 1024 * 1024;
const ARMORY_TTL = 10 * 60 * 1000;
const ARMORY_PARALLEL = 2;

mkdirSync(`${DATA_DIR}/backup`, { recursive: true });
const db = new DatabaseSync(`${DATA_DIR}/werkbank.db`);
db.exec(`PRAGMA journal_mode=WAL;
  CREATE TABLE IF NOT EXISTS state(
    user_id TEXT PRIMARY KEY, username TEXT, data TEXT NOT NULL, updated_at TEXT NOT NULL)`);
// auction house prices: a cache that can be rebuilt any time, so it lives outside werkbank.db and its backups
const ahDb = new DatabaseSync(`${DATA_DIR}/ah-cache.db`);
ahDb.exec("PRAGMA journal_mode=WAL");
const ah = createAh({
  clientId: process.env.BNET_CLIENT_ID, clientSecret: process.env.BNET_CLIENT_SECRET,
  region: process.env.BNET_REGION || "eu", ruleset: Number(process.env.BNET_RULESET || 1), db: ahDb,
});
const getState = db.prepare("SELECT data, updated_at FROM state WHERE user_id = ?");
const putState = db.prepare(`INSERT INTO state(user_id, username, data, updated_at) VALUES(?,?,?,?)
  ON CONFLICT(user_id) DO UPDATE SET username=excluded.username, data=excluded.data, updated_at=excluded.updated_at`);

// ---------- identity ----------
function identity(req) {
  const id = req.headers["x-forwarded-user"];
  if (!id || id.length > 200) return null;
  if (REQUIRED_GROUP) {
    const groups = String(req.headers["x-forwarded-groups"] || "").split(",").map(s => s.trim());
    if (!groups.includes(REQUIRED_GROUP)) return { forbidden: true };
  }
  const name = String(req.headers["x-forwarded-preferred-username"] || req.headers["x-forwarded-email"] || "").slice(0, 80);
  return { id, name };
}

// ---------- armory ----------
class NotFound extends Error {}
const NAME_RE = /^\p{L}{2,24}$/u;
const armoryCache = new Map(); // slug -> { at, promise }; the promise also merges parallel requests
let armoryRunning = 0;
const armoryWaiting = [];
async function limited(fn) {
  if (armoryRunning >= ARMORY_PARALLEL) await new Promise(r => armoryWaiting.push(r));
  armoryRunning++;
  try { return await fn(); } finally { armoryRunning--; armoryWaiting.shift()?.(); }
}
async function fetchArmory(slug) {
  let res;
  try {
    res = await fetch(ARMORY_BASE + encodeURIComponent(slug), {
      headers: { "User-Agent": "Mozilla/5.0 (compatible; werkbank)", "Accept": "text/html" },
      signal: AbortSignal.timeout(8000),
    });
  } catch (e) { throw new ArmoryUnreadable(`fetch failed: ${e.message}`); }
  if (!res.ok) {
    res.body?.cancel().catch(() => {}); // release the connection, the error page isn't needed
    // the armory answers 500 for characters that don't exist
    if (res.status === 404 || res.status === 500) throw new NotFound();
    throw new ArmoryUnreadable(`armory status ${res.status}`);
  }
  const chunks = []; let size = 0;
  for await (const c of res.body) {
    size += c.length;
    if (size > ARMORY_MAX) throw new ArmoryUnreadable("page too large");
    chunks.push(c);
  }
  return parseArmory(Buffer.concat(chunks).toString("utf8"),
    unknown => console.warn(`armory ${slug}: unknown professions ${unknown.join(", ")}`));
}
function armory(name, surname) {
  const slug = slugFor(name, surname);
  const hit = armoryCache.get(slug);
  if (hit && Date.now() - hit.at < ARMORY_TTL) return hit.promise;
  for (const [k, v] of armoryCache) if (Date.now() - v.at >= ARMORY_TTL) armoryCache.delete(k);
  const promise = limited(() => fetchArmory(slug));
  armoryCache.set(slug, { at: Date.now(), promise });
  promise.catch(() => armoryCache.delete(slug)); // only cache hits; retry after errors right away
  return promise;
}

// ---------- http ----------
const send = (res, code, obj) => {
  const headers = { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" };
  if (code === 413) headers.Connection = "close"; // don't keep reading an oversized upload
  res.writeHead(code, headers);
  res.end(JSON.stringify(obj));
};
const tooLarge = () => Object.assign(new Error("too large"), { code: 413 });
const readBody = req => new Promise((resolve, reject) => {
  if (Number(req.headers["content-length"] || 0) > MAX_BODY) return reject(tooLarge());
  let size = 0; const chunks = [];
  req.on("data", c => {
    size += c.length;
    if (size > MAX_BODY) { req.removeAllListeners("data"); req.resume(); reject(tooLarge()); return; }
    chunks.push(c);
  });
  req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
  req.on("error", reject);
});

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  if (url.pathname === "/healthz") return send(res, 200, { ok: true });
  const who = identity(req);
  if (!who) return send(res, 401, { error: "not logged in" });
  if (who.forbidden) return send(res, 403, { error: "no access" });
  try {
    if (url.pathname === "/api/me" && req.method === "GET") return send(res, 200, { name: who.name, logoutUrl: LOGOUT_URL });
    if (url.pathname === "/api/state" && req.method === "GET") {
      const row = getState.get(who.id);
      return row ? send(res, 200, { ...JSON.parse(row.data), updatedAt: row.updated_at }) : send(res, 404, { error: "empty" });
    }
    if (url.pathname === "/api/state" && req.method === "PUT") {
      if (!String(req.headers["content-type"] || "").startsWith("application/json")) return send(res, 415, { error: "json only" });
      let parsed;
      try { parsed = JSON.parse(await readBody(req)); } catch (e) {
        if (e.code === 413) return send(res, 413, { error: "too large" });
        return send(res, 400, { error: "invalid json" });
      }
      const data = validate(parsed);
      const now = new Date().toISOString();
      putState.run(who.id, who.name, JSON.stringify(data), now);
      return send(res, 200, { updatedAt: now });
    }
    if (url.pathname === "/api/armory" && req.method === "GET") {
      const name = url.searchParams.get("name") || "", surname = url.searchParams.get("surname") || "";
      if (!NAME_RE.test(name) || !NAME_RE.test(surname)) return send(res, 400, { error: "Name und Nachname: nur Buchstaben, 2–24 Zeichen" });
      try {
        return send(res, 200, await armory(name, surname));
      } catch (e) {
        if (e instanceof NotFound) return send(res, 404, { error: "Charakter nicht im Arsenal gefunden" });
        if (e instanceof ArmoryUnreadable) {
          console.error(`armory ${slugFor(name, surname)}: ${e.message}`);
          return send(res, 502, { error: "Arsenal nicht erreichbar oder nicht lesbar" });
        }
        throw e;
      }
    }
    if (url.pathname === "/api/prices" && req.method === "GET") {
      const raw = url.searchParams.get("ids") || "";
      if (!/^\d{1,7}(,\d{1,7}){0,299}$/.test(raw)) return send(res, 400, { error: "ids: up to 300 item ids, comma separated" });
      if (!ah.configured) return send(res, 503, { error: "no-key" });
      try {
        return send(res, 200, await ah.prices([...new Set(raw.split(",").map(Number))]));
      } catch (e) {
        if (e instanceof AhUnavailable) return send(res, 502, { error: "AH-Preise nicht verfügbar" });
        throw e;
      }
    }
    return send(res, 404, { error: "not found" });
  } catch (e) {
    if (e instanceof Bad) return send(res, 400, { error: e.message });
    if (e.code === 413) return send(res, 413, { error: "too large" });
    console.error(e);
    return send(res, 500, { error: "server error" });
  }
});

// ---------- daily snapshot inside the data dir (protects against app bugs, not disk loss) ----------
function snapshot() {
  try {
    const file = `${DATA_DIR}/backup/werkbank-${new Date().toISOString().slice(0, 10)}.db`;
    if (!existsSync(file)) db.exec(`VACUUM INTO '${file}'`);
    const old = readdirSync(`${DATA_DIR}/backup`).filter(f => /^werkbank-\d{4}-\d\d-\d\d\.db$/.test(f)).sort().slice(0, -BACKUP_KEEP);
    for (const f of old) rmSync(`${DATA_DIR}/backup/${f}`);
  } catch (e) { console.error("snapshot failed:", e.message); }
}
snapshot();
setInterval(snapshot, 6 * 3600 * 1000).unref();

server.listen(PORT, () => console.log(`werkbank api on :${PORT}${ah.configured ? "" : " (no Battle.net key: AH prices off)"}`));
// fill the price cache in the background, so the first click doesn't wait for 10 house snapshots
if (ah.configured) ah.ensureFresh().catch(e => console.error(`ah: ${e.message}`));
const stop = () => server.close(() => { db.close(); ahDb.close(); process.exit(0); });
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
