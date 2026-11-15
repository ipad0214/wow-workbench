// addon/Werkbank/Data.lua must be what addon/build-data.mjs makes from site/data.js, so the addon and the
// website plan with the same recipes. Run: node --test test/addon/
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { readData, toLua, TARGET } from "../../addon/build-data.mjs";

test("Data.lua is current (run: node addon/build-data.mjs)", () => {
  assert.equal(readFileSync(TARGET, "utf8"), toLua(readData()));
});

test("strings are escaped for Lua", () => {
  const lua = toLua({ profs: ["Mining"], classes: [], subs: [], slots: [], recipes: [],
    items: { 1: ['a "b" \\c', 1, 0, 0, 0, 0, "X", "", "", 0, "ü"] } });
  assert.match(lua, /I\[1\] = \{"a \\"b\\" \\\\c",1,0,0,0,0,"X","","",0,"ü"\}/);
});

test("an unknown profession stops the build", () => {
  assert.throws(() => toLua({ profs: ["Jewelcrafting"], classes: [], subs: [], slots: [], items: {}, recipes: [] }), /Jewelcrafting/);
});
