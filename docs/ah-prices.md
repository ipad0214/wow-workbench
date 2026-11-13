# Auction house prices (branch `feat/ah-prices`)

Plan approved on 2026-11-13 (buy-or-craft comparison included). Implemented, checked with real
data and deployed to jupiter on 2026-11-13 (from the branch).

## Context
The planner already lists the items no character can craft as "AH / Handwerker" in "Kaufen"
(`buildPlan` in `site/index.html`, group `AH`), together with drops and cloth (`X`, `C`). It shows
no prices.

Since the Forever launch (2026-11-04), Blizzard's Game Data API seems to serve Forever auction data.
It isn't officially documented, so this comes from a forum post dated 2026-11-06:
- Host `https://eu.api.blizzard.com`, namespace `dynamic-forever-eu`.
- `GET /data/wow/ruleset/{ruleset}/auctions/` → house index `{auctions:[{key,name,id}]}`.
  Rulesets 1, 2, 3 and 15; each lists houses 110–121 and 123–125, five each for Alliance, Horde and
  Blackwater.
- `GET /data/wow/ruleset/{ruleset}/auctions/{house}` → `auctions[]` (`item.id`, `buyout`,
  `quantity`) plus `GET …/{house}/commodities` → `unit_price`, `quantity`.
- Known problems: every ruleset returns the same houses; houses 112/115/118 have no `auctions`; a
  busy house is about 9 MB.
- Auth: OAuth client credentials (`https://oauth.battle.net/token`). The token can only read
  public game data; it gives no access to accounts and has no write rights.
- There is **no per-item endpoint**, only a snapshot of a whole house, which Blizzard refreshes
  about once an hour.

Decided with the user:
- Prices are fetched "live" when an item is selected, meaning the server re-checks whether its
  copy is still current (see 2).
- One API key for the whole site, kept **only in `.env` on jupiter**. No credentials dialog.
- Only Alliance and Horde houses; Blackwater is ignored.
- A row shows the **cheapest house of the character's faction** (with its name), and hovering shows
  every Alliance/Horde house.
- Fallback: without the API (no key, error, page changed), everything works as today, just without prices.

## 0. Spike (needs the key first)
You create a client at develop.battle.net and put `BNET_CLIENT_ID` / `BNET_CLIENT_SECRET` into
the `.env` on jupiter, plus a local `.env.dev` for testing (git-ignored). Then I query the house
index and one house by hand to check:
- How the houses map to factions (`key`/`name`), and which ruleset to use.
- Whether `Last-Modified` / `If-Modified-Since` is supported.
- Whether the item ids match our classic ids. Sample: Thoriumbarren 12359.

If anything differs from the forum post, I'll update this plan before writing code.

## 1. API: price cache (`api/ah.mjs` + `api/server.mjs`)
- `api/ah.mjs`, pure functions so they can be tested:
  - `cheapest(houseJson, commoditiesJson)` → `Map(itemId → {unit, qty})`, where `unit` is the
    lowest buyout per unit (`buyout/quantity` or `unit_price`) and `qty` is the total number
    on offer. Auctions without a buyout are skipped.
  - `factionOf(houseIndexEntry)` → `"A" | "H" | null` (Blackwater → null, skipped).
- `server.mjs`:
  - New SQLite table `ah_price(house INTEGER, item INTEGER, unit INTEGER, qty INTEGER,
    PRIMARY KEY(house,item))` and `ah_house(id, faction, name, last_modified, checked_at,
    updated_at)`. The prices survive a restart.
  - Token cache (24 h, renewed 5 min early).
  - `ensureFresh()`: for each of the 10 houses whose `checked_at` is older than 5 minutes, send a
    conditional GET (`If-Modified-Since`). A 304 only updates `checked_at`; a 200 replaces that
    house's rows in one transaction. It's single-flight, so parallel clicks share one refresh, and
    it fetches at most 2 houses at once. The limit is 20 MB per response, with a 20 s timeout.
  - `GET /api/prices?ids=1,2,3` (behind the same identity/group check, at most 300 ids, integers
    only) → calls `ensureFresh()` with a 10 s limit, then answers even if the refresh is still
    running or failed, using what's in the cache:
    `{houses:[{id,faction,name,updatedAt}], prices:{"12359":{"110":[1611,240],…}}}`.
  - Status codes: 503 `{error:"no-key"}` when there's no key, 502 when nothing is cached and
    Blizzard fails. Otherwise 200, also with partly stale data, so `updatedAt` shows the age.
- Env: `BNET_CLIENT_ID`, `BNET_CLIENT_SECRET`, `BNET_REGION=eu`, `BNET_RULESET` (from the spike).
  Add them to `docker-compose.yml` (wow-api) and `.env.example`.
- Network unchanged: wow-api already reaches the internet through `wow-egress`.

## 2. "Live" when an item is selected
`select(i)` → `renderPlan()` collects the plan's item ids (buy rows plus the crafted items for the
comparison in 3) → `fetch /api/prices?ids=…`. The server re-checks the houses on every request
(at most every 5 minutes, and a 304 costs almost nothing), so a click always shows the newest
snapshot Blizzard has. The shopping list does the same with its own ids. Prices are cached in the
browser for 1 minute, so switching back and forth doesn't fetch again.

## 3. Frontend (`site/index.html`)
- **Faction** from race: Mensch/Zwerg/Nachtelf/Gnom → Alliance, Orc/Untoter/Tauren/Troll → Horde.
  A row's character decides the faction. With no character ("Niemand") or no race, the user's
  characters decide it (majority); with no characters at all, the cheapest of both factions is used.
- **"Kaufen" rows** (`AH`, `X`, `C`; not `V`, since vendor prices aren't AH prices):
  `12× Thoriumbarren · 16s 11c · 1g 93s 32c` plus the house name in small print. Hovering shows a
  tooltip with every Alliance/Horde house: price per unit, quantity on offer, and how old the data is.
  If the item isn't on offer, the row shows "nicht im AH".
- **Total** at the bottom of "Kaufen" in the plan and in the shopping list ("≈ 14g 20s im AH";
  items not on offer don't count, which a note says).
- **Buy or craft**: for each crafted item in the plan, one line:
  "AH: 2g 10s · Material: 1g 40s". The material cost is the total of its buy rows, plus the
  farmed materials at AH price as their value.
- **Gold format** `Xg Ys Zc` with the WoW colors (gold/silver/copper).
- **Status line** at the top of the plan: "AH-Preise: Stand vor 23 Min". With a 503 or an error,
  there are no prices and no error message, just a small grey note "AH-Preise nicht verfügbar".

## 4. Tests & verification
1. `node --test api/`: `cheapest()` on a small synthetic house file (auctions with and without
   buyout, stacks, commodities) and `factionOf()`.
2. Local dev with a real key: `curl 'localhost:8089/api/prices?ids=12359,2589'` gives prices for 10
   houses; a second call within 5 minutes doesn't reach Blizzard (log); `ids=abc` gives 400; without
   a key it gives 503 and the UI shows no prices and no error.
3. Browser: pick an item where no character has the profession → the "Kaufen" row has a price, the
   hover lists all houses, and there's a total; the Horde character picks the Horde price.
4. `docker network inspect wow-egress` still lists only wow-api.

## 5. Docs
README: an "AH-Preise" section (source, that it's undocumented and can break, the cache, env
variables, how to create the Battle.net client). Fill in the spike results here.

## Commit & PR
Branch `feat/ah-prices` from `main`, push, PR → `main`. Deploy only after the merge, from main.

## Implementation notes
- Deviations: the cache lives in its own `data/ah-cache.db` (rebuildable, kept out of the daily
  backups); the response limit is 20 MB; a failed house index is retried after 5 minutes at the
  earliest, so a broken API isn't hit on every click. Rows show `à <unit> = <total>`; vendor goods
  and items without an AH price are named next to the material cost instead of being guessed.
- Assumptions the spike must confirm: `buyout` is the price of the whole stack (divided by
  `quantity`); house names contain "Alliance"/"Horde" (also "Allianz"); `Last-Modified` is sent.
  If a name doesn't match, `factionOf()` in `api/ah.mjs` is the one place to change.
- Verified without a key: `node --test "api/test/*.test.mjs"` (11 pass, fake Blizzard for the
  cache), dev stack `/api/prices` → 503 `no-key` / 400 for bad ids, and a Playwright run with
  faked `/api/prices`: prices, hover, totals, comparison, Horde/Alliance choice, the off state,
  dark mode and 390 px width without horizontal scroll.

## Spike results (2026-11-13, real key)
- Houses (ruleset 1, locale de_DE): Alliance 110, 111, 119, 123 ("Auktionshaus der Allianz"),
  Horde 113, 114, 120, 124 ("Auktionshaus der Horde"); Blackwater skipped. `factionOf()` matches.
- Item ids match ours (Thoriumbarren 12359 ≈ 18–19s in 110/111/113), so `buyout` is the stack price
  and dividing by `quantity` is right. `Last-Modified` is sent; re-checks are conditional GETs.
- All houses of a faction have the same name, and prices differ a lot between them (Thorium about
  19s in 110/111, 99s in 119/123 with little supply). Decided with the user: **keep the cheapest
  house of the faction**, no fixed "own" house; the hover shows all of them.

## Realm types (2026-11-13)
- Houses are **not** per city: in Forever the three capitals of a faction share one auction house.
  There is one house per realm type ("ruleset") and faction. Rulesets: 1 PvP, 2 Normal,
  3 Rollenspiel, 15 RP-PvP. Every ruleset path lists all 15 houses with the same data, and a
  house's own `ruleset` field only repeats the request path, so the API doesn't say which house is
  which realm type.
- The houses form 5 groups (Alliance/Horde/Blackwater): 110/113/116 and 111/114/117 are large
  (about 100k listings), 119/120/121 and 123/124/125 small (10–16k), 112/115/118 empty.
- The armory names a character's realm type (`ruleset.rulesetId`); it's stored per character
  (`realm`) and is the default for the dropdown "Realm" in the header. The choice is saved per
  account (`realm` in the state). Prices come from the house of the chosen realm type.
- Realm type and faction leave exactly one correct price, so there is no popup with other houses
  any more (decided with the user). An account without a saved realm type takes the one of its
  armory characters once and saves it; without armory data the default is Normal (not saved).
- `REALM_HOUSES` in `site/index.html` assigns the groups. **Unverified:** Normal = 111 group,
  PvP = 110 group, Rollenspiel = 119 group, RP-PvP = 123 group. Check in-game: compare the lowest
  price of one item with the page (switch the dropdown), and swap the groups in that one constant if
  they differ.
