// site/sync.js against the shared fixtures; test/sync/run.lua checks the addon against the same files.
// Run: node --test test/sync/
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { createRequire } from "node:module";

const S = createRequire(import.meta.url)("../../site/sync.js");
const dir = new URL("./fixtures/", import.meta.url);
const lines = f => readFileSync(new URL(f, dir), "utf8").split("\n").filter(l => l.trim() && !l.startsWith("#"));
const parseStock = s => Object.fromEntries((s || "").split(",").filter(Boolean).map(x => x.split("=").map(Number)));

// net-*.txt: "list <WB1 without checksum>", then blocks "case <name>" / "stock <id=n,…>" / expected rows
function netCases(file) {
  const out = []; let list = null, cur = null;
  for (const l of lines(file)) {
    const [word, ...rest] = l.split(" "), arg = rest.join(" ");
    if (word === "list") list = arg;
    else if (word === "case") out.push(cur = { name: arg, stock: {}, expect: [] });
    else if (word === "stock") cur.stock = parseStock(arg);
    else cur.expect.push(l);
  }
  return { list: `${list};${S.checksum(list)}`, cases: out };
}

for (const file of readdirSync(dir).filter(f => f.startsWith("net-"))) {
  const { list, cases } = netCases(file);
  for (const c of cases) {
    test(`${file}: ${c.name}`, () => {
      assert.deepEqual(S.canonical(S.evaluate(S.decodeList(list), c.stock)), [...c.expect].sort());
    });
  }
  test(`${file}: decode(encode(decode(x))) equals decode(x)`, () => {
    // object keys may come back in another order; the entries must be the same
    assert.deepEqual(S.decodeList(S.encodeList(S.decodeList(list))), S.decodeList(list));
  });
}

test("checksum is Adler-32 over UTF-8 in base 36", () => {
  for (const l of lines("checksum.txt")) {
    const [sum, ...text] = l.split(" ");
    assert.equal(S.checksum(text.join(" ")), sum, text.join(" "));
  }
});

test("counts: the addon's WC1 string decodes to the fixture", () => {
  let t, wc1; const chars = [];
  for (const l of lines("counts.txt")) {
    const [w, a, b, c] = l.split(" ");
    if (w === "t") t = Number(a);
    else if (w === "char") chars.push({ name: a, at: Number(b), items: parseStock(c) });
    else if (w === "wc1") wc1 = a;
  }
  const got = S.decodeCounts(wc1);
  assert.equal(got.t, t);
  assert.deepEqual(got.chars.sort((x, y) => x.name < y.name ? -1 : 1), chars.sort((x, y) => x.name < y.name ? -1 : 1));
  assert.equal(S.encodeCounts({ t, chars }), wc1);
});

test("a cut-off or changed string is rejected", () => {
  const wc1 = lines("counts.txt").find(l => l.startsWith("wc1 ")).slice(4);
  assert.throws(() => S.decodeCounts(wc1.slice(0, -10)), S.SyncError);
  assert.throws(() => S.decodeCounts(wc1.replace("2589*40", "2589*41")), S.SyncError);
  assert.throws(() => S.decodeCounts("hello"), /Kein Werkbank-Text/);
  assert.throws(() => S.decodeList(wc1), /WB1/);
});

test("line breaks and text around the string are ignored", () => {
  const wc1 = lines("counts.txt").find(l => l.startsWith("wc1 ")).slice(4);
  const wrapped = "Bestand:\n" + wc1.slice(0, 30) + "\r\n" + wc1.slice(30) + "\n";
  assert.equal(S.decodeCounts(wrapped).chars.length, 3);
});

test("the SavedVariables file gives the stored WC1 string", () => {
  const wc1 = lines("counts.txt").find(l => l.startsWith("wc1 ")).slice(4);
  const file = `\nWerkbankDB = {\n["export"] = "${wc1}",\n["list"] = {\n},\n}\n`;
  assert.equal(S.countsFromSavedVariables(file).chars.length, 3);
  assert.throws(() => S.countsFromSavedVariables("WerkbankDB = {}"), /noch kein Bestand/);
});

test("names lose the separator characters", () => {
  const list = S.encodeList({ t: 1, chars: ["Bank;Twink,1"], roots: [], crafts: {}, raws: {} });
  assert.deepEqual(S.decodeList(list).chars, ["BankTwink1"]);
});

test("a crafter index outside the character list is rejected", () => {
  const body = "WB1;1;Ulfrik;100:1;100:1:3:0:;";
  assert.throws(() => S.decodeList(`${body};${S.checksum(body)}`), /Handwerker/);
});
