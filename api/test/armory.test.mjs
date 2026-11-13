import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { parseArmory, slugFor, ArmoryUnreadable, CLASSES, RACES, PROFESSIONS } from "../armory.mjs";

const fixture = readFileSync(new URL("./fixtures/ulfrik.html", import.meta.url), "utf8");

test("reads class, race, level and skills from the embedded state", () => {
  let unknown = null;
  const c = parseArmory(fixture, u => { unknown = u; });
  assert.equal(c.name, "Ulfrik");
  assert.equal(c.surname, "Weißbart");
  assert.equal(c.level, 18);
  assert.equal(c.cls, "Paladin");
  assert.equal(c.race, "Mensch");
  assert.equal(c.realm, "normal");
  assert.deepEqual(c.skills, {
    Bergbau: [96, 150], Schmiedekunst: [71, 150], Kochkunst: [50, 150], Angeln: [20, 75], "Erste Hilfe": [60, 150],
  });
  assert.equal(unknown, null);
});

test("skips professions it doesn't know", () => {
  const html = fixture.replace('"id":186', '"id":9999');
  let unknown = null;
  const c = parseArmory(html, u => { unknown = u; });
  assert.equal(c.skills.Bergbau, undefined);
  assert.deepEqual(unknown, ["9999:Mining"]);
});

test("throws ArmoryUnreadable when the page changed", () => {
  assert.throws(() => parseArmory("<html>nothing here</html>"), ArmoryUnreadable);
  assert.throws(() => parseArmory("<script>var characterProfileInitialState = {broken;</script>"), ArmoryUnreadable);
  assert.throws(() => parseArmory("<script>var characterProfileInitialState = {};</script>"), ArmoryUnreadable);
});

test("slug is lowercase name-surname and keeps ß", () => {
  assert.equal(slugFor("Ulfrik", "Weißbart"), "ulfrik-weißbart");
});

// frontend and API are separate files without a build step; the German names must match,
// otherwise the editor's dropdowns lose the value or the API rejects stored skills
test("names match the lists in site/index.html", () => {
  const html = readFileSync(new URL("../../site/index.html", import.meta.url), "utf8");
  const list = name => JSON.parse(new RegExp(`const ${name} = (\\[[^\\]]*\\]);`).exec(html)[1]);
  const sorted = a => [...a].sort();
  assert.deepEqual(sorted(list("CLASSES")), sorted(Object.values(CLASSES)));
  assert.deepEqual(sorted(list("RACES")), sorted(Object.values(RACES)));
  assert.deepEqual(sorted([...list("PRIMARY"), ...list("SECONDARY")]), sorted(Object.values(PROFESSIONS)));
});
