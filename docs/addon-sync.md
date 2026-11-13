# Plan: in-game addon for the shopping list (branch `feat/addon-sync`)

Status: approved and built 2026-11-13 (answers to the open questions at the end). In-game check pending.

## Context

The Werkbank knows what to farm, buy and craft (`renderShop()` → `buildPlan()` in `site/index.html`),
but not what the characters already own. Blizzard exposes no bags or bank through any API (the armory
state and the Profile API only have equipped gear), so the counts can only come from inside the game.

WoW addons have no network and no file access. Their only way out is the SavedVariables file, which
WoW writes on logout or `/reload`. Text can be pasted into an in-game edit box. So the data moves like this:

```
Werkbank ──"Für Addon exportieren" (copy string)──► /werkbank import (paste)  ──► Addon
                                                                                   │ scans bags/bank live,
                                                                                   │ shows have/need per row
Werkbank ◄── paste string, or upload the SavedVariables file ◄── /werkbank export ─┘
```

## 1. Shared model: the list and netting

The export doesn't carry finished numbers. It carries the **plan structure**, so the addon can recalculate
when an intermediate is crafted (otherwise 20 ore → 10 bars would make the ore row "fall back" to 0/20):

- **roots**: the list entries (item id, quantity)
- **crafts**: every recipe in the plan (product id, `yMin`, reagents `[(id, amount)]`, crafter name)
- **raws**: every farm/buy row (item id, group `H/M/S/F/D/C/V/X/AH`, assigned character name)

**Netting** (same algorithm on the website and in the addon): walk the tree like `resolve()`, with an
account-wide stock pool `id → owned`. At every node, the roots included, take `min(pool, need)` from the
pool, and expand only the rest (fewer crafts → fewer reagents). A row is done when its rest is 0.
Owned finished items count too: 5 of 20 bandages in the bags → the list asks for 15.

Limitation in v1: the pool is account-wide. If the ore sits on a different alt than the crafter, the row
counts it as owned but no extra "Post verschicken" line appears. The row's tooltip shows who holds it.

### Export string `WB1`
ASCII, one line, versioned, with a checksum so a cut-off paste is detected:
`WB1;<created>;<chars>;<roots>;<crafts>;<raws>;<checksum>`. Character names are stripped of `;,:|`.
No item names (the addon gets them from `GetItemInfo`, which keeps the string short and safe).
Its size is a few hundred bytes to a few KB for a normal list.

### Count string `WC1`
`WC1;<time>;<char>:<scanned-at>:<id>*<n>+…,…;<checksum>`, with bags, bank, mail and mail in transit
summed per character. It only holds the items of the imported list (from the finished items down to
the ore), and is built on `/werkbank export` and on logout or `/reload`, not on every bag change.

## 2. Addon `addon/Werkbank/` (Lua 5.1, no libraries)

**Client:** WoW Forever runs on the modern retail client (Midnight UI and API, Midnight's addon
restrictions), not on the Classic Era client. The restrictions target combat data; bags, bank and mail
stay readable. So the addon uses the modern API (`C_Container`, `C_Item`, `Enum.BagIndex`,
`TooltipDataProcessor`). The interface number `16001` comes from one guide and is checked in game.

| File | Contents |
|---|---|
| `Werkbank.toc` | `## Interface:` = Forever's build (read in game, see Verification), `SavedVariables: WerkbankDB` |
| `Codec.lua` | `WB1` decode, `WC1` encode, checksum. No WoW API, so it can be tested outside the game |
| `Net.lua` | the netting algorithm. No WoW API, tested outside the game |
| `Scan.lua` | bags, bank (while open) and mailbox (while open), mail in transit between own characters |
| `UI.lua` | list window, import/export windows, tooltip line |

- **SavedVariables** `WerkbankDB` (account-wide): `list` (the decoded export), `chars["Realm-Name"] =
  {at, bags, bank, mail, transit}` (each `{id=n}`), `export` (the last `WC1` string, see Section 3).
- **Events**: `PLAYER_LOGIN` (scan bags), `BAG_UPDATE_DELAYED` (rescan + refresh),
  `BANKFRAME_OPENED`/`PLAYERBANKSLOTS_CHANGED` (scan the bank containers, classified by their
  `Enum.BagIndex` names). The bank of a character stays at the last seen state.
- **Mail** (the characters exchange items by post): `MAIL_INBOX_UPDATE` scans the inbox attachments
  while the mailbox is open. Mail sent to one of your own characters (`SendMail` hook +
  `MAIL_SEND_SUCCESS`) is counted at the recipient right away as "unterwegs", until the recipient opens
  the mailbox. So an item never disappears from the count while it travels between alts.
- **`/werkbank`** toggles a movable window: sections Farmen / Kaufen / Herstellen, each row has an icon,
  name, `34/60` (red → yellow → green ✓) and the assigned character. The current character's rows come
  first, and a checkbox shows only this character's rows. The tooltip shows the item tooltip plus
  owned per character ("Ulfrik 34 · Bank-Twink 12").
- **`/werkbank import`**: an edit box to paste a `WB1` string. It validates the checksum, then replaces the list.
- **`/werkbank export`**: an edit box with the `WC1` string, preselected for Ctrl+C.
- **Item tooltip** anywhere in the game: `Werkbank: 34/60` if the item is on the list.
- Only long-standing frame templates (`BasicFrameTemplateWithInset`, `UIPanelScrollFrameTemplate`,
  `InputScrollFrameTemplate`), so a UI change in the client is unlikely to break the window.

## 3. Website (`site/index.html`, new `site/sync.js`)

- **`site/sync.js`** (plain script, also loadable from Node for tests): `WB1` encode, `WC1` decode,
  checksum, and the netting. The same logic as the Lua files, checked against the same fixtures.
- **Export**: button "Für Addon exportieren" in the head of "Einkaufs- & Farmliste". It builds the
  structure from `buildPlan()` and copies the string to the clipboard ("kopiert", fallback: a text field).
- **Import**: button "Bestand aus WoW" → a dialog with a text field for the `WC1` string, or a file
  (drop or pick the SavedVariables `Werkbank.lua`; the page only extracts the `WC1` string with a regex
  and needs no Lua parser). In Chrome/Edge the file handle is remembered (File System Access API,
  handle in IndexedDB), so later it's one click on "Aus WoW laden". Safari/Firefox pick the file each time.
- On import, character names are matched to the account's characters (case-insensitive). Unknown ones
  still count toward the pool and are shown as "andere Charaktere". Only item ids that exist in the
  Werkbank data are kept (keeps the state small).
- **Shopping list** with stock: rows show `noch 26 · 34 vorhanden`, done rows are ticked and greyed out,
  craft rows count down the same way. A line in the head shows "Bestand von 14:32, Ulfrik, Bank-Twink"
  plus a checkbox "Bestand abziehen" (on by default). The single-recipe plan on the right stays gross in v1.

## 4. API (`api/server.mjs`)

`validate()` gets an optional `stock`: `{ at: ISO, chars: [{ name ≤40, at ≤30, items: {id: 0–100000} ≤600 entries }] ≤20 }`.
That's at most ~150 KB, under `MAX_BODY` (256 KB). Old states without `stock` stay valid. No new route:
stock is saved with the rest of the state, so it's per account and in the daily backups.

## 5. Distribution

Decided: friends get it from the website. The website offers the addon as a download (`site/addon/Werkbank.zip`, built by `deploy.sh` from
`addon/Werkbank/`), so friends don't need the repo. Install it by unzipping into
`<WoW folder>/<Forever client folder>/Interface/AddOns/` (the folder name will be checked in game).
For development, a symlink from there to the repo folder.

## Verification

- **Node tests** (`node --test`): `WB1`/`WC1` round trips, checksum rejects a cut-off string,
  netting fixtures (intermediate owned, partial stock, unknown characters, empty stock).
- **Lua tests** with the local `lua` (`/opt/homebrew/bin/lua`, test code kept Lua 5.1 compatible):
  `Codec.lua` + `Net.lua` against the **same fixture files** as the Node tests, so both sides give
  identical rows.
- **API**: `validate()` tests for `stock` (limits, old states without it).
- **Browser** (dev setup on :8089): export, paste a fixture `WC1`, file upload, rows and ticks.
- **In game (you)**: `/dump select(4, GetBuildInfo())` for the `## Interface` number and the client
  folder name. Then import, loot something (the row updates), open the bank, `/reload`, export →
  website. Checklist: `docs/addon-ingame-check.md`.

## Decisions (2026-11-13)

1. Finished items you already own reduce the list: 5 of 20 bandages owned → the list asks for 15.
2. The mailbox counts too, including mail between your own characters that is still on its way.
3. Friends download the addon from the website.
