# Armory import for characters (branch `feat/armory`)

Plan as approved on 2026-11-13, with the small deviations noted inline.

## Context
Characters in the Werkbank are entered by hand (name, race, class, ticked professions), without skill
levels. The WoW Forever armory has the real data: on
`worldofwarcraft.blizzard.com/de-de/forever/eu/armory/character/<name>-<surname>` the page embeds
`var characterProfileInitialState = {...}` with class, race, level and every profession with
`skillPoints`/`maxSkillPoints` (verified for Ulfrik Weißbart: Mining 96/150, Blacksmithing 71/150, ...).

Findings that shape the plan:
- The key is **first name + surname** (Forever surnames, there is no realm). Name alone → 404, unknown
  character → 500.
- No CORS header → the browser can't fetch it; `wow-api` must.
- `wow-api` sits only in `wow-internal` (`internal: true`) → no internet access today.
- Not an official API: it's the website's embedded state. Can break if Blizzard changes the page,
  so manual entry stays as the fallback.

Decided with the user: name + surname fields; skills are used on the character card, in the
crafter check in the plan, to pick the best crafter, and for a "jetzt herstellbar" filter.

## Prerequisite
Builds on multi-user (PR #3, `feat/shopping-list` → `main`); `feat/armory` branches from `feat/shopping-list`.

## 1. API: `GET /api/armory?name=…&surname=…` (`api/server.mjs`)
- Behind the same identity/group check as the other routes.
- Validate: `name` and `surname` match `^\p{L}{2,24}$`u (otherwise 400).
- Slug = `${name}-${surname}`.toLocaleLowerCase("de"); URL from env `ARMORY_BASE`
  (default `https://worldofwarcraft.blizzard.com/de-de/forever/eu/armory/character/`) + `encodeURIComponent(slug)`.
- `fetch` with `AbortSignal.timeout(8000)`, plain browser-like User-Agent with no personal details, reject >3 MB.
- Extract `characterProfileInitialState` with a regex → `JSON.parse` → map to a small object:
  `{ name, surname, level, cls, race, skills: {"Bergbau":[96,150], …} }`
  (the link to the armory page is built in the frontend from name + surname).
  Mapping by **ids**, not localized names: class ids (1 Krieger … 11 Druide), race ids (1 Mensch … 8 Troll),
  profession ids (171 Alchemie, 164 Schmiedekunst, 333 Verzauberkunst, 202 Ingenieurskunst,
  165 Lederverarbeitung, 197 Schneiderei, 186 Bergbau, 182 Kräuterkunde, 393 Kürschnerei,
  185 Kochkunst, 129 Erste Hilfe, 356 Angeln). Unknown ids are skipped and logged (callback `onUnknown` of `parseArmory`).
- Responses: 200 data · 404 "Charakter nicht gefunden" (Blizzard 404/500) · 502 "Arsenal nicht lesbar"
  (fetch error, timeout, state block missing / JSON broken).
- In-memory cache per slug for 10 min (also absorbs double clicks); at most 2 armory fetches at once.
- Split the parser into `api/armory.mjs` (pure function `parseArmory(html)`) so it can be tested;
  copy it in `api/Dockerfile`.

## 2. API: extend the stored character (`validate()` in `api/server.mjs`)
New optional fields per character: `surname` (str ≤24), `level` (int 0–80), `skills` (object, ≤12
entries, key = profession from the known list, value `[skill 0–450, max 0–450]`), `syncedAt` (ISO str ≤30).
Old characters without them stay valid.

## 3. Network (`docker-compose.yml`, README)
- New network `wow-egress` (normal bridge, **only** `wow-api` is a member) for outbound HTTPS.
- Header-trust boundary is preserved: no other container joins `wow-egress`; comment in compose and
  update the "Security note" in the README accordingly.
- Dev: `docker-compose.dev.yml` needs no change (wow-api inherits the network).

## 4. Frontend (`site/index.html`)
- **Editor:** fields Name + Nachname, button "Aus Arsenal laden" → fills race, class, profession
  checkboxes and shows level + skills; errors shown inline in `#cErr`. Saving without an armory hit still works
  (manual fallback, as today).
- **Character card:** "Stufe 18 Mensch Paladin", chips with skill (`Bergbau 96/150`), line
  "Arsenal: vor 2 Std · Aktualisieren" + link to the armory page. Characters without a surname look as today.
- **Auto-refresh:** after `loadAccount()`, characters with a surname and `syncedAt` older than 6 h are
  refreshed one after another in the background, then `save()`.
- **Best crafter:** `crafterFor(prof)` → the character with that profession and the highest known skill
  (unknown skill ranks below a known one). `pickRecipe`, `buildPlan` and `renderList` benefit
  automatically because they all go through `crafterFor`.
- **Crafter check:** new `skillGap(char, r)` → `null` (ok/unknown) or missing points.
  Plan banner: "Ulfrik stellt das Item her (Schmiedekunst 71/90 – fehlen 19 Punkte)" in warn style;
  in the recipe list the "who" column is warn-colored when the skill is too low; craft steps in the
  character cards get the same hint.
- **Filter "jetzt herstellbar":** new checkbox next to "nur meine Berufe": recipe kept if a character has
  the profession and skill ≥ `r.skill`. Characters with unknown skill (manual) count as able, so the
  filter doesn't hide everything for hand-made characters.
- Presets stay as they are (no surname → no armory).

## 5. Docs
- README: armory section (what is fetched, from where, the cache, that it's the website's
  state and can break), new network in the diagram.
- Copy of this plan to `docs/armory.md`.

## Verification
1. `node --test api/` – `parseArmory` against a trimmed fixture (only the state block of Ulfrik's page,
   `api/test/fixtures/ulfrik.html`): class/race/level/skills correct; broken HTML → error.
2. Local dev stack (`docker compose --env-file .env.example -f docker-compose.yml -f docker-compose.dev.yml up -d --build wow-dev`):
   - `curl localhost:8089/api/armory?name=Ulfrik&surname=Weißbart` → real data (proves egress);
     `…name=Xyzzy&surname=Nobody` → 404; `name=a<b` → 400.
   - Browser (localhost:8089): add Ulfrik Weißbart via the editor → card shows skills; an item from
     Schmiedekunst above 71 shows the skill gap; "jetzt herstellbar" filter; reload keeps the data (PUT validation).
   - Manual character without a surname still works; old stored state loads without errors.
3. `docker exec wow-dev` cannot reach the internet / `wow-api` is not reachable from any container outside
   `wow-internal` (check `docker network inspect wow-egress` lists only wow-api).

## Commit & PR
Commits on `feat/armory`, push, PR → `main` (memory: GitHub wow-workbench, branch + PR). Deploy only
after the merge, from main (deploy.sh ships the working tree).
