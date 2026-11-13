// Werkbank API: stores characters + shopping list per Keycloak account.
// Only reachable from wow-web inside the private network wow-internal. The identity comes from
// oauth2-proxy (wow-auth), which strips client-supplied X-Forwarded-* user headers and injects
// its own. Never expose this service on another network.
import http from "node:http";
import { mkdirSync, readdirSync, rmSync, existsSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";

const PORT = Number(process.env.PORT || 3000);
const DATA_DIR = process.env.DATA_DIR || "/data";
const REQUIRED_GROUP = process.env.REQUIRED_GROUP || ""; // defence in depth, e.g. "/gamers"
const MAX_BODY = 256 * 1024;
const BACKUP_KEEP = 14;

mkdirSync(`${DATA_DIR}/backup`, { recursive: true });
const db = new DatabaseSync(`${DATA_DIR}/werkbank.db`);
db.exec(`PRAGMA journal_mode=WAL;
  CREATE TABLE IF NOT EXISTS state(
    user_id TEXT PRIMARY KEY, username TEXT, data TEXT NOT NULL, updated_at TEXT NOT NULL)`);
const getState = db.prepare("SELECT data, updated_at FROM state WHERE user_id = ?");
const putState = db.prepare(`INSERT INTO state(user_id, username, data, updated_at) VALUES(?,?,?,?)
  ON CONFLICT(user_id) DO UPDATE SET username=excluded.username, data=excluded.data, updated_at=excluded.updated_at`);

// ---------- validation ----------
class Bad extends Error {}
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
function validate(body) {
  if (!body || typeof body !== "object") throw new Bad("invalid body");
  return {
    chars: arr(body.chars, 50).map(c => ({
      id: str(c?.id, 40, { min: 1 }),
      name: str(c?.name, 40, { min: 1 }),
      cls: str(c?.cls ?? "", 20),
      race: str(c?.race ?? "", 20),
      profs: arr(c?.profs ?? [], 12).map(p => str(p, 30)),
    })),
    list: arr(body.list ?? [], 200).map(e => ({
      i: int(e?.i, 0, 1e6),
      item: int(e?.item, -1e7, 1e7),
      qty: int(e?.qty, 1, 999),
    })),
  };
}

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
    if (url.pathname === "/api/me" && req.method === "GET") return send(res, 200, { name: who.name });
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

server.listen(PORT, () => console.log(`werkbank api on :${PORT}`));
const stop = () => server.close(() => { db.close(); process.exit(0); });
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
