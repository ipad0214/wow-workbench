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

## If something fails
`/console scriptErrors 1` shows Lua errors in game. Note the message and the line; the file names
(`Scan.lua:42`) point straight into `addon/Werkbank/`.
