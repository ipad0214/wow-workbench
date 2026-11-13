# crafting-site — "Forever Werkbank"

Crafting planner for WoW Classic professions, served on **jupiter** at <https://wow.kuckelsberg.de>
behind a Keycloak login. Every account has its own characters and shopping list, stored on the
server.

```
Internet → nginx-proxy (TLS) → wow-auth (oauth2-proxy, group /gamers) ─┐   network nginx-proxy
                                                                         │
                         ┌─────────── network wow-internal (internal) ───┘
                         ▼
                      wow-web (nginx :80) ── /api/* ──► wow-api (Node 24 :3000) ── data/werkbank.db
```

| Path | Purpose |
|---|---|
| `site/index.html` | The app (data + UI in one file) |
| `nginx/default.conf` | Static files, `/api/` → wow-api, gzip, security headers, `/healthz` |
| `api/server.mjs` | Per-account storage: `GET /api/me`, `GET/PUT /api/state`. `node:http` + `node:sqlite`, no npm dependencies |
| `docker-compose.yml` | `wow-api`, `wow-web`, `wow-auth` |
| `docker-compose.dev.yml`, `dev/` | Local development with a fake login (see below) |
| `.env.example` | Secrets template; the real `.env` lives only on jupiter (chmod 600) |
| `deploy.sh` | rsync to jupiter (never `.env` or `data/`) + `docker compose up -d --build` |

## Access: Keycloak groups

Realm `kuckelsberg`, client `wow`. Only members of group **`/gamers`** get in (`OAUTH2_PROXY_ALLOWED_GROUPS`,
checked again in the API via `REQUIRED_GROUP`). The groups reach oauth2-proxy through the shared
client scope `groups` (Group Membership mapper, claim `groups`, full path on).

docs.kuckelsberg.de and spoolman.kuckelsberg.de only let in `/luna/portal-users`, so a friend who is
only in `/gamers` sees nothing but the Werkbank.

**Adding a friend:** Keycloak admin → realm `kuckelsberg` → Users → Add user (username, email) →
Credentials: temporary password → Groups: join `gamers`. Done; their characters start empty.

## Data

- One row per Keycloak user id (`sub`) in `data/werkbank.db` on jupiter (`/home/luna/srv/crafting-site/data/`).
- The API writes a daily copy to `data/backup/werkbank-YYYY-MM-DD.db` (keeps 14). That protects against
  app bugs, **not** against losing the disk; an off-host backup is still open.
- Characters stored only in the browser before multi-user are moved into the account on the first
  login in that browser, once, and then removed from the browser.
- Two devices at the same time: last write wins; switching back to a tab reloads the current state.

## Security note

wow-api trusts the `X-Forwarded-User` / `X-Forwarded-Groups` headers. oauth2-proxy strips
client-supplied copies and injects its own, and only wow-auth can reach wow-web/wow-api (network
`wow-internal` is internal and has no other members). **Never** put wow-web or wow-api on another
network.

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
   `https://wow.kuckelsberg.de/oauth2/callback`, web origin `https://wow.kuckelsberg.de`, valid post
   logout redirect URI `https://wow.kuckelsberg.de/*`, audience mapper `wow`, default client scope `groups`.
2. `.env` on jupiter: `WOW_CLIENT_SECRET` (Credentials tab), `WOW_COOKIE_SECRET`
   (`openssl rand -base64 32 | head -c 32`).
3. `/mnt/raid/services/nginx-proxy/vhost.d/wow.kuckelsberg.de` raises the proxy buffers (otherwise the
   login callback returns 502). nginx-proxy picks up a new vhost.d file only after `docker restart wow-auth`.
