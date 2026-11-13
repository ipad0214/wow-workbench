// Werkbank <-> in-game addon (addon/Werkbank): the list export "WB1", the count export "WC1" and the
// netting of owned items against the plan. The addon has the same logic in Codec.lua and Net.lua;
// test/sync/ checks both against the same fixtures, so change them together.
//
// Structure of a list (what the website exports and the addon evaluates):
//   { t: unix seconds, chars: ["Ulfrik", …],
//     roots:  [{id, need}],                        need = list quantity × minimum yield
//     crafts: {id: {y, c, rootOnly, reag: [[id, amount], …]}}   c = crafter index or -1
//     raws:   {id: {g, o}} }                       g = H M S F D C V X AH; o = index, "c" (the consumer) or -1
// rootOnly: the item is crafted when it is on the list itself, but farmed when another recipe needs it
// (leather, enchanting mats, recipes nobody on the account can craft).
(function (root) {
  "use strict";
  const RESERVED = /[;,:+*\r\n\t]/g;   // separators of the formats; stripped from names
  const ID = /^-?\d{1,7}$/;
  const N = /^\d{1,10}$/;
  const GROUPS = new Set(["H", "M", "S", "F", "D", "C", "V", "X", "AH"]);

  class SyncError extends Error {}

  // Adler-32 over the UTF-8 bytes, base 36: needs no bit operations, so Lua 5.1 computes the same
  function checksum(s) {
    let a = 1, b = 0;
    for (const x of new TextEncoder().encode(s)) { a = (a + x) % 65521; b = (b + a) % 65521; }
    return (b * 65536 + a).toString(36);
  }
  const cleanName = s => String(s).replace(RESERVED, "").trim().slice(0, 40);
  const split = (s, sep) => s === "" ? [] : s.split(sep);
  const num = (s, re, what) => { if (!re.test(s)) throw new SyncError(`${what} ungültig`); return Number(s); };

  // a string pasted from somewhere: drop line breaks, check the version and the checksum
  function unwrap(text, tag, fields) {
    const s = String(text || "").replace(/[\r\n\t]/g, "").trim();
    const at = s.indexOf(tag + ";");
    if (at < 0) throw new SyncError(`Kein Werkbank-Text gefunden (${tag}).`);
    const body = s.slice(at), parts = body.split(";");
    if (parts.length < fields) throw new SyncError("Der Text ist unvollständig. Bitte komplett kopieren.");
    const sum = parts[fields - 1], data = parts.slice(0, fields - 1).join(";");
    if (checksum(data) !== sum) throw new SyncError("Der Text ist unvollständig. Bitte komplett kopieren.");
    return parts.slice(1, fields - 1);
  }

  // ---------- WB1: the list ----------
  function encodeList(S) {
    const crafts = Object.entries(S.crafts).map(([id, k]) =>
      [id, k.y, k.c >= 0 ? k.c : "", k.rootOnly ? 1 : 0, k.reag.map(([r, a]) => `${r}*${a}`).join("+")].join(":"));
    const raws = Object.entries(S.raws).map(([id, r]) => [id, r.g, r.o === "c" ? "c" : r.o >= 0 ? r.o : ""].join(":"));
    const data = ["WB1", S.t, S.chars.map(cleanName).join(","), S.roots.map(r => `${r.id}:${r.need}`).join(","),
      crafts.join(","), raws.join(",")].join(";");
    return `${data};${checksum(data)}`;
  }
  function decodeList(text) {
    const [t, chars, roots, crafts, raws] = unwrap(text, "WB1", 7);
    const nChars = split(chars, ",").length;
    const idx = (s, what) => { if (s === "") return -1; const i = num(s, N, what); if (i >= nChars) throw new SyncError(`${what} ungültig`); return i; };
    const S = { t: num(t, N, "Zeit"), chars: split(chars, ","), roots: [], crafts: {}, raws: {} };
    for (const r of split(roots, ",")) {
      const [id, need] = r.split(":");
      S.roots.push({ id: num(id, ID, "Item"), need: num(need, N, "Menge") });
    }
    for (const k of split(crafts, ",")) {
      const [id, y, c, f, reag = ""] = k.split(":");
      S.crafts[num(id, ID, "Item")] = {
        y: Math.max(1, num(y, N, "Ertrag")), c: idx(c, "Handwerker"), rootOnly: f === "1",
        reag: split(reag, "+").map(x => { const [rid, a] = x.split("*"); return [num(rid, ID, "Zutat"), num(a, N, "Menge")]; }),
      };
    }
    for (const r of split(raws, ",")) {
      const [id, g, o] = r.split(":");
      if (!GROUPS.has(g)) throw new SyncError("Quelle ungültig");
      S.raws[num(id, ID, "Item")] = { g, o: o === "c" ? "c" : idx(o, "Charakter") };
    }
    return S;
  }

  // ---------- WC1: what the characters own ----------
  // counts: {t, chars: [{name, at, items: {id: n}}]}
  function encodeCounts(C) {
    const chars = [...C.chars].sort((a, b) => cleanName(a.name) < cleanName(b.name) ? -1 : 1).map(c =>
      [cleanName(c.name), c.at, Object.keys(c.items).map(Number).sort((a, b) => a - b).filter(id => c.items[id] > 0)
        .map(id => `${id}*${c.items[id]}`).join("+")].join(":"));
    const data = ["WC1", C.t, chars.join(",")].join(";");
    return `${data};${checksum(data)}`;
  }
  function decodeCounts(text) {
    const [t, chars] = unwrap(text, "WC1", 4);
    return {
      t: num(t, N, "Zeit"),
      chars: split(chars, ",").map(c => {
        const [name, at, items = ""] = c.split(":");
        const out = {};
        for (const x of split(items, "+")) { const [id, n] = x.split("*"); out[num(id, ID, "Item")] = num(n, N, "Anzahl"); }
        return { name, at: num(at, N, "Zeit"), items: out };
      }),
    };
  }
  // the SavedVariables file of the addon keeps the last WC1 string; no Lua parser needed
  function countsFromSavedVariables(text) {
    const m = String(text).match(/"(WC1;[^"]*)"/);
    if (!m) throw new SyncError("In der Datei steht noch kein Bestand. Einmal einloggen, dann /reload oder ausloggen.");
    return decodeCounts(m[1]);
  }

  // ---------- netting ----------
  // stock: {id: owned}. Walks the list like the website's planner; at every node, the roots included,
  // owned items are used first and only the rest is crafted or farmed. Returns
  //   crafts: [{id, c, crafts, need, have, depth}]   in the order first seen
  //   farm:   [{o, id, g, need, have}]               o = character index, or -1 (nobody)
  //   mail:   [{from, to, id, qty}]
  // need = what reaches the node, have = how much of it the stock covers.
  function evaluate(S, stock) {
    const pool = new Map();
    for (const [id, n] of Object.entries(stock || {})) if (n > 0) pool.set(Number(id), n);
    const crafts = new Map(), farm = new Map(), mail = new Map();
    const take = (id, need) => { const p = pool.get(id) || 0, t = Math.min(p, need); if (t) pool.set(id, p - t); return t; };
    const send = (from, to, id, qty) => {
      if (from < 0 || to < 0 || from === to || !qty) return;
      const k = `${from}>${to}>${id}`; const m = mail.get(k) || { from, to, id, qty: 0 }; m.qty += qty; mail.set(k, m);
    };
    function resolve(id, need, consumer, path, isRoot, depth) {
      const have = take(id, need), rest = need - have;
      const k = S.crafts[id];
      if (k && !path.has(id) && (isRoot || !k.rootOnly)) {
        const n = Math.ceil(rest / k.y);
        const st = crafts.get(id) || { id, c: k.c, crafts: 0, need: 0, have: 0, depth: 0 };
        st.crafts += n; st.need += need; st.have += have; st.depth = Math.max(st.depth, depth); crafts.set(id, st);
        send(k.c, consumer, id, rest);
        if (n) {
          const p2 = new Set(path); p2.add(id);
          for (const [rid, a] of k.reag) resolve(rid, a * n, k.c >= 0 ? k.c : consumer, p2, false, depth + 1);
        }
        return;
      }
      const r = S.raws[id] || { g: "X", o: "c" };
      const o = r.o === "c" ? consumer : r.o;
      const key = o >= 0 ? `${o}|${id}` : `_${r.g}|${id}`;
      const f = farm.get(key) || { o, id, g: r.g, need: 0, have: 0 }; f.need += need; f.have += have; farm.set(key, f);
      send(o, consumer, id, rest);
    }
    for (const r of S.roots) resolve(r.id, r.need, -1, new Set(), true, 0);
    return { crafts: [...crafts.values()], farm: [...farm.values()], mail: [...mail.values()] };
  }

  // one line per row, sorted: what the fixtures in test/sync/ compare (Lua prints the same)
  function canonical(res) {
    const i = x => x >= 0 ? String(x) : "-";
    return [
      ...res.crafts.map(s => `craft ${s.id} ${i(s.c)} ${s.crafts} ${s.need} ${s.have} ${s.depth}`),
      ...res.farm.map(f => `farm ${f.o >= 0 ? f.o : "_" + f.g} ${f.id} ${f.g} ${f.need} ${f.have}`),
      ...res.mail.map(m => `mail ${m.from} ${m.to} ${m.id} ${m.qty}`),
    ].sort();
  }

  const api = { SyncError, checksum, cleanName, encodeList, decodeList, encodeCounts, decodeCounts, countsFromSavedVariables, evaluate, canonical };
  if (typeof module === "object" && module.exports) module.exports = api; else root.WerkbankSync = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
