# In-game checklist for the Werkbank addon

The addon is tested outside the game (`lua test/addon/smoke.lua`, with a stand-in for the WoW API).
Whether the real client behaves like that stand-in can only be checked in game. Run this once after
installing, and again after a big client patch.

## Setup
1. Download the zip from the page ("Addon herunterladen" in the header) and unpack it, so that
   `<Forever client folder>/Interface/AddOns/Werkbank/Werkbank.toc` exists.
   For development, a symlink from there to `addon/Werkbank` in the repo works too.
2. Character screen → AddOns: "Werkbank" is listed. If it says "veraltet" (out of date): note the number
   from step 3 and put it into `## Interface:` in `Werkbank.toc`.
3. In game: `/dump (select(4, GetBuildInfo()))` → interface number: ________
   Client folder name (e.g. `_retail_`, `_forever_`): ________

## Flow
- [ ] Page: put something on the list, "Für Addon kopieren".
- [ ] `/werkbank import`, Ctrl+V, "Übernehmen" → the list window opens, sections and item names show.
- [ ] Loot or move an item from the list → the row changes without `/reload`; when a row is complete,
      a chat line "Werkbank: … vollständig" appears.
- [ ] Hover a list item in the bags → tooltip line `Werkbank: x/y`.
- [ ] Open the bank → items in the bank count; the status line no longer names this character under
      "Bank noch nicht geöffnet". Close the bank, the count stays.
- [ ] Open the mailbox with an item attached → it counts. Take it out → still counted once, not twice.
- [ ] Send an item to one of your characters that has logged in with the addon before → the total
      stays the same right after sending (it counts as "on its way" at the recipient).
- [ ] `/werkbank export`, Ctrl+C → paste on the page under "Bestand aus WoW …" → the page shows the
      characters and the rows count down.
- [ ] Log out, then on the page "Datei wählen …" → `WTF/Account/<ACCOUNT>/SavedVariables/Werkbank.lua`
      → same counts. In Chrome/Edge, "Aus WoW laden" appears afterwards.

## Characters and professions
- [ ] `/werkbank debug` on a character with two professions → both listed with the right skill points
      and a German name after the arrow (not "nicht zugeordnet"). Note which call worked: ________
- [ ] `/werkbank` → section "Charaktere": the character with class, level and its professions.
- [ ] Open a profession window, close it, `/werkbank debug` → "Rezepte über …" with the number of learned
      recipes, most of them "in der Datenbank". The window shows `x/y Rezepte` for that profession.
- [ ] Enchanting: open its window too → the enchants count (they are stored by spell id).
- [ ] Log in a second character → the first one is still listed with its professions and recipes.
- [ ] Gain a skill point or learn a recipe → the section updates without `/reload`.

## Planning in the profession window
- [ ] Open a profession window → next to the create buttons: "Werkbank" and "Auf die Werkbank". Note
      which window it is (modern with the recipe list on the left, or the classic narrow one): ________
- [ ] Select a recipe, set the quantity box to 3, "Auf die Werkbank" → chat line "…: 3× auf der Werkbank",
      above the button "Auf der Werkbank: 3×". Click again → 6×.
- [ ] Select another recipe → the line above the button disappears; back to the first → it shows again.
- [ ] Search in the window, pick a recipe from the result, add it → it is on the list.
- [ ] "Werkbank" opens the list window: section "Liste" with both entries, `-`/`+`/`x` change them, and
      Farmen / Kaufen / Herstellen are planned with your characters (crafter = the one with the skill).
- [ ] Enchanting (if a character has it): an enchant can be added too.
- [ ] "Liste leeren" asks first, then empties the list.
- [ ] `/werkbank import` with a list from the page → it replaces the in-game list.

## If something fails
`/console scriptErrors 1` shows Lua errors in game. Note the message and the line; the file names
(`Scan.lua:42`) point straight into `addon/Werkbank/`.
