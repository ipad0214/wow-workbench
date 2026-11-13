import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { cheapest, factionOf, createAh, AhUnavailable } from "../ah.mjs";

test("factionOf: Alliance and Horde, Blackwater and unknown skipped", () => {
  assert.equal(factionOf("Alliance Auction House"), "A");
  assert.equal(factionOf("Auktionshaus der Allianz"), "A");
  assert.equal(factionOf("Horde Auction House"), "H");
  assert.equal(factionOf("Blackwater Auction House"), null);
  assert.equal(factionOf(""), null);
});

test("cheapest: lowest buyout per unit, stacks divided, bid-only skipped, commodities merged", () => {
  const best = cheapest({
    auctions: [
      { item: { id: 12359 }, buyout: 4000, quantity: 20 },   // 200 per unit
      { item: { id: 12359 }, buyout: 1500, quantity: 10 },   // 150 per unit
      { item: { id: 12359 }, bid: 10, quantity: 5 },         // bid only
      { item: { id: 2589 }, buyout: 101, quantity: 2 },      // 50.5 -> 51
      { item: {}, buyout: 5, quantity: 1 },                  // broken
    ],
  }, { auctions: [{ item: { id: 12359 }, unit_price: 140, quantity: 3 }, { item: { id: 4306 }, unit_price: 99, quantity: 7 }] });
  assert.deepEqual(best.get(12359), { unit: 140, qty: 33 });
  assert.deepEqual(best.get(2589), { unit: 51, qty: 2 });
  assert.deepEqual(best.get(4306), { unit: 99, qty: 7 });
  assert.equal(best.size, 3);
});

test("cheapest: houses without auctions give an empty map", () => {
  assert.equal(cheapest({ id: 112 }, undefined).size, 0);
});

// fake Blizzard: house index with one house per faction, conditional GETs answered with 304
function fakeBlizzard() {
  const calls = [];
  const json = (body, headers = {}) => new Response(JSON.stringify(body), { status: 200, headers: { "Last-Modified": "Fri, 13 Nov 2026 10:00:00 GMT", ...headers } });
  const fetch = async (url, opts = {}) => {
    const u = new URL(url); calls.push(u.pathname);
    if (u.hostname === "oauth.battle.net") return Response.json({ access_token: "t", expires_in: 86399 });
    assert.equal(opts.headers.Authorization, "Bearer t");
    assert.equal(u.searchParams.get("namespace"), "dynamic-forever-eu");
    if (opts.headers["If-Modified-Since"]) return new Response(null, { status: 304 });
    const p = u.pathname;
    if (p === "/data/wow/ruleset/1/auctions/") return json({ auctions: [
      { id: 110, name: "Alliance Auction House" }, { id: 111, name: "Horde Auction House" }, { id: 112, name: "Blackwater Auction House" }] });
    if (p === "/data/wow/ruleset/1/auctions/110") return json({ auctions: [{ item: { id: 12359 }, buyout: 3000, quantity: 20 }] });
    if (p === "/data/wow/ruleset/1/auctions/111") return json({ auctions: [{ item: { id: 12359 }, buyout: 2000, quantity: 10 }] });
    if (p.endsWith("/commodities")) return new Response(null, { status: 404 });
    return new Response(null, { status: 404 });
  };
  return { fetch, calls };
}
const quiet = { error() {} };

test("createAh: fills the cache, answers per item and house, re-checks only after 5 minutes", async () => {
  const fb = fakeBlizzard(); let t = 1_000_000;
  const ah = createAh({ clientId: "id", clientSecret: "s", db: new DatabaseSync(":memory:"), fetch: fb.fetch, now: () => t, log: quiet });
  const r = await ah.prices([12359, 2589]);
  assert.deepEqual(r.houses.map(h => [h.id, h.faction]), [[110, "A"], [111, "H"]]);
  assert.equal(r.houses[0].updatedAt, "2026-11-13T10:00:00.000Z");
  assert.deepEqual(r.prices, { 12359: { 110: [150, 20], 111: [200, 10] } });

  const n = fb.calls.length;
  await ah.prices([12359]);
  assert.equal(fb.calls.length, n, "no Blizzard call within 5 minutes");

  t += 5 * 60 * 1000;
  const r2 = await ah.prices([12359]);
  assert.deepEqual(fb.calls.slice(n), ["/data/wow/ruleset/1/auctions/110", "/data/wow/ruleset/1/auctions/111"], "conditional GETs only");
  assert.deepEqual(r2.prices, r.prices, "a 304 keeps the cached prices");
});

test("createAh: parallel requests share one refresh", async () => {
  const fb = fakeBlizzard();
  const ah = createAh({ clientId: "id", clientSecret: "s", db: new DatabaseSync(":memory:"), fetch: fb.fetch, log: quiet });
  await Promise.all([ah.prices([1]), ah.prices([2]), ah.prices([3])]);
  assert.equal(fb.calls.filter(p => p === "/data/wow/ruleset/1/auctions/").length, 1);
});

test("createAh: without a key it is off; with Blizzard down and no cache it is unavailable", async () => {
  const off = createAh({ db: new DatabaseSync(":memory:"), log: quiet });
  assert.equal(off.configured, false);
  await assert.rejects(off.prices([1]), AhUnavailable);

  let n = 0;
  const down = createAh({ clientId: "id", clientSecret: "s", db: new DatabaseSync(":memory:"), log: quiet,
    fetch: async () => { n++; throw new Error("ECONNREFUSED"); } });
  await assert.rejects(down.prices([1]), AhUnavailable);
  await assert.rejects(down.prices([1]), AhUnavailable);
  assert.equal(n, 1, "a failed house index isn't retried on every click");
});
