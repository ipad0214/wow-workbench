# crafting-site — "Forever Werkbank"

Static page served by nginx on **jupiter** at <https://wow.kuckelsberg.de>, behind a Keycloak
login (realm `kuckelsberg`, any realm user).

```
Internet → nginx-proxy (TLS) → wow-auth (oauth2-proxy :4180) → wow-web (nginx :80)
                                    └── OIDC → auth.kuckelsberg.de/realms/kuckelsberg
```

| Path | Purpose |
|---|---|
| `site/index.html` | The page — edit this |
| `nginx/default.conf` | nginx server block (gzip, security headers, `/healthz`) |
| `Dockerfile` | `nginx:1.29-alpine` + conf + `site/`, built on jupiter as `crafting-site:local` |
| `docker-compose.yml` | `wow-web` + `wow-auth`, network `nginx-proxy` |
| `.env.example` | Secrets template; the real `.env` lives only on jupiter (`/home/luna/srv/crafting-site/.env`, chmod 600) |
| `deploy.sh` | rsync to jupiter (without `.env`/`docs/`) + `docker compose up -d --build` |

## Update the page

Edit `site/index.html`, then run `./deploy.sh`. HTML is served with `Cache-Control: no-cache`, so a reload is enough.

## One-time setup (already done 2026-11-13)

1. Keycloak → realm `kuckelsberg` → Clients → Create: client ID `wow`, client authentication on,
   standard flow only, redirect URI `https://wow.kuckelsberg.de/oauth2/callback`, web origin
   `https://wow.kuckelsberg.de`, Advanced → PKCE `S256`, dedicated scope → mapper *Audience*
   (`wow`, access token).
2. On jupiter, `.env` contains `WOW_CLIENT_SECRET` (Credentials tab) and `WOW_COOKIE_SECRET`
   (`openssl rand -base64 32 | head -c 32`).
3. `/mnt/raid/services/nginx-proxy/vhost.d/wow.kuckelsberg.de` raises the proxy buffers
   (otherwise the login callback returns 502 "upstream sent too big header"; see the ADR from
   2026-10-21). nginx-proxy picks up a new vhost.d file only after `docker restart wow-auth`.

No DNS change was needed, because the `*.kuckelsberg.de` wildcard points to the home IP.

## Restrict access later

Create a group in Keycloak, add a *Group Membership* mapper to the `wow` client, and set
`OAUTH2_PROXY_ALLOWED_GROUPS=<group>` on `wow-auth`.
