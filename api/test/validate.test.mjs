import { test } from "node:test";
import assert from "node:assert/strict";
import { validate, Bad } from "../validate.mjs";

const base = { chars: [{ id: "c1", name: "Ulfrik", cls: "Paladin", race: "Mensch", profs: ["Bergbau"] }], list: [{ i: 3, item: 2851, qty: 2 }] };
const stock = {
  at: "2026-11-13T14:32:00.000Z",
  chars: [{ name: "Ulfrik", at: "2026-11-13T14:30:00.000Z", items: { 2770: 34, 2840: 2 } }],
};

test("an old state without stock stays valid and gets no stock", () => {
  const d = validate(base);
  assert.equal(d.stock, undefined);
  assert.equal(d.chars[0].name, "Ulfrik");
});

test("stock is kept as sent", () => {
  assert.deepEqual(validate({ ...base, stock }).stock, stock);
});

test("stock limits: characters, items per character, counts, ids", () => {
  const ch = items => ({ ...base, stock: { ...stock, chars: [{ ...stock.chars[0], items }] } });
  assert.throws(() => validate({ ...base, stock: { ...stock, chars: Array(21).fill(stock.chars[0]) } }), Bad);
  assert.throws(() => validate(ch(Object.fromEntries(Array.from({ length: 601 }, (_, i) => [i + 1, 1])))), Bad);
  assert.throws(() => validate(ch({ 2770: 0 })), Bad);
  assert.throws(() => validate(ch({ 2770: 100001 })), Bad);
  assert.throws(() => validate(ch({ 2770: 1.5 })), Bad);
  assert.throws(() => validate(ch({ "-5": 1 })), Bad);
  assert.throws(() => validate(ch({ abc: 1 })), Bad);
  assert.throws(() => validate(ch([1, 2])), Bad);
  assert.throws(() => validate({ ...base, stock: { ...stock, chars: [{ ...stock.chars[0], name: "" }] } }), Bad);
  assert.throws(() => validate({ ...base, stock: [] }), Bad);
});

test("the largest allowed stock fits under the 256 KB body limit", () => {
  const items = Object.fromEntries(Array.from({ length: 600 }, (_, i) => [1000000 + i, 100000]));
  const big = { ...base, stock: { ...stock, chars: Array.from({ length: 20 }, (_, i) => ({ name: "Charakter" + i, at: stock.at, items })) } };
  assert.ok(Buffer.byteLength(JSON.stringify(validate(big))) < 256 * 1024);
});
