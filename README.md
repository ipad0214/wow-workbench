# crafting-site — "Forever Werkbank"

Crafting planner for WoW Classic professions, served on **jupiter** at `https://$WOW_HOST`
behind a Keycloak login. Every account has its own characters and shopping list, stored on the
server.

```
Internet → nginx-proxy (TLS) → wow-auth (oauth2-proxy, group /gamers) ─┐   network nginx-proxy
                                                                         │
                         ┌─────────── network wow-internal (internal) ───┘
                         ▼
                      wow-web (nginx :80) ── /api/* ──► wow-api (Node 24 :3000) ── data/werkbank.db
                                                            │
                                         network wow-egress └──► WoW Forever armory, Battle.net API (HTTPS)
```

| Path | Purpose |
|---|---|
| `site/index.html` | The app (data + UI in one file) |
| `nginx/default.conf` | Static files, `/api/` → wow-api, gzip, security headers, `/healthz` |
| `api/server.mjs` | Per-account storage: `GET /api/me`, `GET/PUT /api/state`; armory lookup `GET /api/armory`; AH prices `GET /api/prices`. `node:http` + `node:sqlite`, no npm dependencies |
| `api/armory.mjs`, `api/ah.mjs`, `api/test/` | Armory page parser, AH price cache, and their tests (`node --test "api/test/*.test.mjs"`, Node ≥ 22.5 for `node:sqlite`) |
| `docker-compose.yml` | `wow-api`, `wow-web`, `wow-auth` |
| `docker-compose.dev.yml`, `dev/` | Local development with a fake login (see below) |
| `.env.example` | Secrets template; the real `.env` lives only on jupiter (chmod 600) |
| `deploy.sh` | rsync to jupiter (never `.env` or `data/`) + `docker compose up -d --build` |

## Access: Keycloak groups

Realm from `OIDC_ISSUER_URL`, client `wow`. Only members of group **`/gamers`** get in (`OAUTH2_PROXY_ALLOWED_GROUPS`,
checked again in the API via `REQUIRED_GROUP`). The groups reach oauth2-proxy through the shared
client scope `groups` (Group Membership mapper, claim `groups`, full path on).

The other sites behind Keycloak on jupiter (docs, Spoolman) only let in `/luna/portal-users`, so a friend who is
only in `/gamers` sees nothing but the Werkbank.

**Adding a friend:** Keycloak admin → the realm → Users → Add user (username, email) →
Credentials: temporary password → Groups: join `gamers`. Done; their characters start empty.

## Data

- One row per Keycloak user id (`sub`) in `data/werkbank.db` on jupiter (`/home/luna/srv/crafting-site/data/`).
- The API writes a daily copy to `data/backup/werkbank-YYYY-MM-DD.db` (keeps 14). That protects against
  app bugs, **not** against losing the disk; an off-host backup is still open.
- Characters stored only in the browser before multi-user are moved into the account on the first
  login in that browser, once, and then removed from the browser.
- Two devices at the same time: last write wins; switching back to a tab reloads the current state.

## Armory (WoW Forever)

A character with a **surname** is linked to the WoW Forever armory. Forever characters are found by
first name + surname (`…/forever/eu/armory/character/ulfrik-weißbart`), there is no realm; the
first name alone gives 404.

- `GET /api/armory?name=Ulfrik&surname=Weißbart` → `wow-api` loads the armory page and reads the
  state the page embeds (`characterProfileInitialState`): level, class, race, professions with
  skill points. Responses: 200, 404 (character not found), 400 (invalid name), 502 (armory unreachable
  or the page changed).
- This is the website's state, **not an official API**. If Blizzard changes the page, the lookup
  returns 502 and characters can still be edited by hand. The parser is `api/armory.mjs`; its test
  fixture is a trimmed copy of a real page.
- Lookups are cached for 10 minutes per character, at most 2 run at once. The page refreshes
  characters whose last sync is older than 6 hours, one after another, when it loads; the card has an
  "Aktualisieren" button.
- What the skills are used for: skill chips on the character card, the crafter with the highest
  skill gets the recipe, the plan and the recipe list show missing points, filter
  "jetzt herstellbar". Characters without armory data count as able to craft.
- Base URL can be changed with `ARMORY_BASE` on wow-api (default: German page, EU region).

## AH prices (WoW Forever)

The plan and the "Kaufen" section of the shopping list show auction house prices for the items no
character can craft, drops and cloth (not vendor goods). Each row shows the **cheapest house of the
row's character's faction** (race → Alliance/Horde; without a race the majority of the account's
characters), hovering shows every Alliance and Horde house; Blackwater is ignored. The plan also
compares buying with crafting ("AH 2g 10s · Material 1g 40s" per item; farmed materials count at AH
price, vendor goods have no price and are named).

- Source: Blizzard's Game Data API, namespace `dynamic-forever-eu`, auction data per ruleset
  (`/data/wow/ruleset/{ruleset}/auctions/{house}` + `/commodities`). **Not officially documented**;
  details and open checks in `docs/ah-prices.md`.
- Blizzard only serves whole snapshots of a house (no per-item lookup, refreshed about hourly).
  `wow-api` keeps the cheapest price per item and house in `data/ah-cache.db` (a cache, not in the
  backups) and re-checks a house at most every 5 minutes, when someone opens an item; unchanged
  snapshots cost one `304`. Parallel requests share one refresh.
- Key: a Battle.net API client (develop.battle.net → API Access → Create Client, any redirect URL,
  e.g. `https://$WOW_HOST`). Put `BNET_CLIENT_ID` and `BNET_CLIENT_SECRET` into `.env` on jupiter; it
  only reads public game data. Without a key, or when Blizzard is unreachable, `/api/prices` answers
  503/502 and the page simply shows no prices ("AH-Preise nicht verfügbar").

## Security note

wow-api trusts the `X-Forwarded-User` / `X-Forwarded-Groups` headers. oauth2-proxy strips
client-supplied copies and injects its own, and only wow-auth can reach wow-web/wow-api (network
`wow-internal` is internal and has no other members). **Never** put wow-web on another network.
wow-api is also in `wow-egress`, a network of its own for the armory lookups and AH prices; **no other container may
join `wow-egress`**, otherwise it could reach wow-api directly and fake the user headers.

## Update the app

Edit, then run `./deploy.sh`. HTML is served with `Cache-Control: no-cache`, so a reload is enough.

## Local development

```bash
# .env.example only supplies placeholders; wow-auth isn't started in dev
docker compose --env-file .env.example -f docker-compose.yml -f docker-compose.dev.yml up -d --build wow-dev
open http://localhost:8089          # logged in as "dev"
# switch user in the browser console: document.cookie = "devuser=friend"
```
Data goes to `data-dev/` (git-ignored).

## One-time setup (done 2026-11-13)

1. Keycloak client `wow`: client authentication on, standard flow, redirect URI
   `https://$WOW_HOST/oauth2/callback`, web origin `https://$WOW_HOST`, valid post
   logout redirect URI `https://$WOW_HOST/*`, audience mapper `wow`, default client scope `groups`.
2. `.env` on jupiter (template `.env.example`): `WOW_HOST`, `LETSENCRYPT_EMAIL`, `OIDC_ISSUER_URL`,
   `AUTH_HOST`, `WOW_CLIENT_SECRET` (Credentials tab), `WOW_COOKIE_SECRET`
   (`openssl rand -base64 32 | head -c 32`).
3. `/mnt/raid/services/nginx-proxy/vhost.d/$WOW_HOST` raises the proxy buffers (otherwise the
   login callback returns 502). nginx-proxy picks up a new vhost.d file only after `docker restart wow-auth`.
