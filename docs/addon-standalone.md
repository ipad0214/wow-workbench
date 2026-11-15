# Plan: the Werkbank addon without the website

Goal: everything the website does today happens in game, in the Werkbank addon. No copy and paste
of `WB1`/`WC1` strings, no server, no login. The website keeps running until the addon can replace it
(after step 4), then we decide whether to switch it off.

## Roadmap

| Step | What | Result in game |
|---|---|---|
| **1** | Character profiles + recipe database in the addon | Every character knows the professions, skill points and learned recipes of all your characters |
| 2 | Plan from the game's own profession window: mark a recipe "auf die Werkbank" with a quantity, open the Werkbank from there; the planner runs in Lua | Search, pick and plan entirely in game; the website's export is no longer needed |
| 3 | Search in the Werkbank window for recipes of professions the current character doesn't have | Plan an alt's recipes without logging in that alt |
| 4 | AH prices from scanning the auction house | Prices with their age, buy vs. craft comparison; then decide about the website |

Each step is its own branch and PR, and each one ends with an in-game check.

Changed on 2026-11-15 (user's request): instead of an own catalogue window, step 2 uses the game's
profession window, which already has search and filters. The own search (step 3) only covers what
that window can't show: recipes of professions the current character doesn't have.

## Step 2 in detail

### 2.1 In the profession window
- Next to the game's create buttons: a quantity box and a button **"Auf die Werkbank"**. It puts the
  selected recipe's product × quantity on the list (again: the quantity adds up).
- A button **"Werkbank"** at the top of the profession window opens and closes the Werkbank window.
- A line above the button shows how often the selected recipe is on the list ("Auf der Werkbank: 3×").
  A marker inside Blizzard's recipe list itself is left out: it would mean hooking Blizzard's list rows.
- Works with the modern window (`ProfessionsFrame`) and the classic one (`TradeSkillFrame`, Enchanting's
  `CraftFrame`); which one Forever uses is answered by `/werkbank debug`. The buttons are attached when
  the window loads, nothing of Blizzard's is replaced.

### 2.2 The list and the planner in Lua
- `WerkbankDB.shop = { { item, r, qty } }`: the list, account-wide, like the website's shopping list
  (product, recipe index, how often to craft it). An old `WB1` list of addon 1.0 is taken over once.
- New `Plan.lua`: the website's `listStructure()` with `pickRecipe`, `crafterFor` (highest skill;
  learned recipes from step 1 decide first) and the gatherers, built from `Data.lua` and the profiles.
  It produces the same structure as a decoded `WB1` string, so `Net.lua` (netting against the stock)
  and the window stay as they are. `test/plan/plan.test.mjs` runs the website's own planner functions
  (taken out of `index.html`) on 80 generated cases and writes the fixtures; `test/plan/run.lua` checks
  `Plan.lua` against them. Only the characters with a profile take part in the plan.
- The window gets the list entries on top: name, quantity, `-`/`+`, remove.
- `/werkbank import` stays for now: an imported list replaces the in-game list.
- Recipes WoW Forever added are not in the database (e.g. Bergbau's "Leitstein"). When one is selected
  in the window, the addon reads it from the game (`C_TradeSkillUI.GetRecipeSchematic`: product,
  yield, required basic reagents), keeps it in `WerkbankDB.extra` and adds it to `Data` on every login.
  Their gather groups are unknown, so their own reagents count as "Drop / AH" unless the database
  knows them.

### 2.3 Tracker (added on the user's request)
A compact list on the screen edge like Questie's quest tracker (`Tracker.lua`): only the current
character's rows and rows nobody is assigned to; done rows stay, green with a check mark. The window,
the profession window's note and the tracker are redrawn through one hook (`Core.onUpdate`).
Under each row the tracker says where the owned items lie (`Core.whereText`: bags, bank, mailbox, mail
on its way, per character, plus the account bank); item tooltip and list window use the same text.

### 2.4 Not in step 2
The own search for other characters' professions (step 3), AH prices (step 4).

## Step 1 in detail

### 1.1 One data source for the website and the addon
- Move the `DATA` object (2,281 items, 1,232 recipes, about 280 KB) from line 208 of `site/index.html`
  into its own file `site/data.js` (`const DATA = {...};`). The page loads it with a `<script>` tag
  before its own code and keeps working as before.
- New generator `addon/build-data.mjs` (Node, no dependencies) reads `site/data.js` and writes
  `addon/Werkbank/Data.lua`. `addon/build.sh` runs it before zipping.
- `Data.lua` **is committed** so that a symlink from the WoW AddOns folder to `addon/Werkbank`
  works without a build. A test fails if it is out of date with `site/data.js`.
- Format: one statement per item and recipe (`I[2840]={...}`, `R[17]={...}`) instead of one giant
  table literal. WoW runs Lua 5.1, which has limits per expression; the test machine runs Lua 5.5,
  so the file is kept in a shape that is safe for 5.1.
- Contents: the same fields as `DATA` (quality, class, subclass, slot, required level, gather group,
  source, ilvl, German and English names). The names stay in because the catalogue search (step 3)
  needs them right away; `GetItemInfo` loads names only over time. Windows still show the game's
  own names and icons.
- At load time `Data.lua` builds the same indexes as the website: `byProduct` (item → recipes) and
  `usedIn` (reagent → recipes).
- The generator also writes the names by id (professions by skill line, classes, races) from
  `api/armory.mjs`, so the addon names characters exactly like the website and has no copy of its own.
- Added to `Werkbank.toc` before `Codec.lua`. Memory: a few hundred KB, normal for an addon.

### 1.2 Character profiles (new file `Profile.lua`)
Saved per character in `WerkbankDB.chars["Realm-Name"]`, next to bags/bank/mail:

```lua
profile = {
  at = 1763200000,          -- when the profile was last read
  level = 60, class = "Paladin", race = "Zwerg", faction = "Alliance",
  profs = { ["Bergbau"] = { 300, 300 }, ["Schmiedekunst"] = { 285, 300 } },   -- like the armory's skills
  recipes = { ["Schmiedekunst"] = { at = 1763200000, known = { [12404] = true, ... } } },
}
```

- **Class, race, faction, level**: on login and on `PLAYER_LEVEL_UP`. Mapped by id
  (`UnitClass`/`UnitRace` third return value) to the same German names as `api/armory.mjs`, not by
  the localized text.
- **Professions and skill points**: on login and on `SKILL_LINES_CHANGED`. Mapped by skill line id
  with the same table as `api/armory.mjs` (171 Alchemie, 164 Schmiedekunst, 186 Bergbau, 182
  Kräuterkunde, 393 Kürschnerei, 356 Angeln, …). The client decides which call works: the modern
  `GetProfessions`/`GetProfessionInfo`, or the classic `GetNumSkillLines`/`GetSkillLineInfo` as a
  fallback. Both are guarded so that a missing call never breaks the addon (like the events in
  `Core.lua` today).
- **Learned recipes**: only readable while the character's profession window is open. On
  `TRADE_SKILL_SHOW`/`TRADE_SKILL_LIST_UPDATE` the addon reads the learned recipes of that profession
  (`C_TradeSkillUI`) and stores them by **product item id**, the key the recipe database uses
  (enchants: negative spell id, as in `DATA`). Until a window was opened once, the recipes count as
  unknown and the skill points decide (as on the website today).
- Other characters show their last state. Skills and recipes only change while that character is
  played, and it saves them then, so the data is current in practice.

### 1.3 Visible in game
- The window gets a **"Charaktere"** section: every known character with class, level, professions
  as `Schmiedekunst 285/300` and `87/240 Rezepte` (learned / in the database) or `Fenster öffnen`.
  The full checklist is in `docs/addon-ingame-check.md`.
- `/werkbank debug` prints what this client's profession calls return (ids, names, skill points,
  number of recipes). This is for the in-game check and for problem reports.
- Nothing else changes: `/werkbank import`/`export`, the list window and the tooltips work as before.

### 1.4 Tests
- `node --test test/addon/`: `Data.lua` matches `site/data.js` (the generator output is current),
  strings are escaped for Lua, an unknown profession stops the build.
- New `lua test/addon/data.lua`: `Data.lua` loads, 2,281 items and 1,232 recipes, spot checks
  (a reagent list, an enchant with a negative id), `byProduct` and `usedIn` agree with the website.
- `test/addon/smoke.lua`: stand-ins for the profession and trade skill calls; two characters log in
  one after the other → both profiles are there, a character's recipe scan is saved, the classic
  fallback works when the modern calls are missing.

### 1.5 In-game check (added to `docs/addon-ingame-check.md`)
- [ ] `/werkbank debug` on a character with two professions → both with the right skill points.
- [ ] Open a profession window → the section shows `x/y Rezepte` (learned / in the database), and
      `/werkbank debug` the number of learned recipes.
- [ ] Log in a second character → the first one is still listed with its professions.
- [ ] Learn a recipe or gain a skill point → the section updates without `/reload`.

### 1.6 Docs
README (addon section) and this file. The website's armory lookup stays until the end of step 4.

## Not in step 1
Planner, catalogue, shopping list in game, AH prices: steps 2 to 4. The website and the `WB1`
import keep working unchanged, except that the page loads its data from `site/data.js`.

## Open points and risks
- **Several WoW accounts under one Battle.net login** (WoW1, WoW2): their SavedVariables are
  separate, so they can't see each other's characters. Assumed for now: all characters are on one
  WoW account. To be confirmed by the user.
- **Profession calls on the Forever client**: Forever runs the modern client with classic content.
  Which of the two calls returns the skill points, and whether `C_TradeSkillUI` lists the recipes,
  is only known in game. `/werkbank debug` answers this at the first in-game check; the fallback is
  part of step 1 so that one of the two should work.
- **Lua version**: tests run on Lua 5.5, the game on 5.1. The generated file and new code avoid
  anything that isn't in 5.1 (no `goto`, no integer division `//`, no `utf8`).

## Delivery
Branch `feat/addon-profiles`, PR on GitHub, deploy after merge (`deploy.sh` ships the addon zip with
the page).
