# Plan: crafting-site ("Forever Werkbank") on jupiter at $WOW_HOST behind Keycloak

## Context

`luna/srv/crafting-site/crafting-site.html` is one static HTML page (~220 KB, "Forever Werkbank").
Its only external dependency is Google Fonts. It should be served by an **nginx container** on
jupiter at `https://$WOW_HOST`, and only after a Keycloak login with your existing user
in realm `<realm>` (any realm user may enter).

What I found on jupiter (read-only):
- `$WOW_HOST` already resolves to the home IP through the IONOS wildcard, so **no DNS change** is needed.
- `nginx-proxy` and `acme-companion` handle vhosts and TLS automatically via `VIRTUAL_HOST`/`LETSENCRYPT_HOST`, on the external network `nginx-proxy`.
- Proven pattern: `/home/luna/srv/spoolman/docker-compose.yml`, which is an app container plus an `oauth2-proxy` in front of it (keycloak-oidc, PKCE S256, `--trusted-proxy-ip=172.20.0.0/16`). `/home/luna/srv/luna-docs/` uses the same pattern with `v7.15.5`.
- Known pitfall (ADR 2026-10-21): after login, the oauth2-proxy session cookie is too large for nginx-proxy's default buffer and gives a 502 on the callback. The fix is a per-vhost file in `/mnt/raid/services/nginx-proxy/vhost.d/<host>`, followed by a container restart.
- The Keycloak admin user has 2FA, and the bootstrap admin from `.env` no longer works. So **you create the Keycloak client in the admin UI yourself** (about 2 minutes, steps below). I can't do it through `kcadm`.

## Architecture

```
Internet → nginx-proxy (TLS, $WOW_HOST) → wow-auth (oauth2-proxy :4180) → wow-web (nginx :80)
                                                        └── OIDC → $OIDC_ISSUER_URL
```
`wow-web` gets no `VIRTUAL_HOST`, so it can only be reached inside the `nginx-proxy` network.

## Files (local in `luna/srv/crafting-site/`, deployed to `jupiter:/home/luna/srv/crafting-site/`)

| File | Contents |
|---|---|
| `site/index.html` | `crafting-site.html` moved here (it remains the single source) |
| `nginx/default.conf` | `listen 80`, `root /usr/share/nginx/html`, `try_files $uri /index.html`, gzip, `server_tokens off`, security headers (`X-Content-Type-Options`, `Referrer-Policy`, `X-Frame-Options SAMEORIGIN`), `no-cache` for HTML, `/healthz` → 200 |
| `Dockerfile` | `FROM nginx:1.29-alpine` (pinned), copies the conf and `site/`, `HEALTHCHECK wget /healthz` |
| `docker-compose.yml` | `wow-web` (build `.`, image `crafting-site:local`, network `nginx-proxy`) + `wow-auth` (`oauth2-proxy:v7.15.5`, env like spoolman: `CLIENT_ID=wow`, `UPSTREAMS=http://wow-web:80`, `REDIRECT_URL=https://$WOW_HOST/oauth2/callback`, `EMAIL_DOMAINS=*`, `VIRTUAL_HOST/LETSENCRYPT_HOST=$WOW_HOST`, `VIRTUAL_PORT=4180`, `NETWORK_ACCESS=external`, `depends_on` wow-web healthy) |
| `.env.example` | `WOW_CLIENT_SECRET=change-me`, `WOW_COOKIE_SECRET=change-me`; the real `.env` exists only on jupiter (chmod 600) |
| `.gitignore` | `.env` |
| `deploy.sh` | `rsync` (without `.env`) to jupiter → `docker compose up -d --build` → status check |
| `README.md` | Setup, Keycloak client, deploy, how to update the HTML |
| `docs/plan.md` | Copy of this plan (global rule: plans live in the project folder) |

The image is built **on jupiter** (no registry, same approach as `luna-portal:local`).

## Steps

1. **Local:** create the files above, then `docker build` and `docker run`, and test with `curl localhost:8080/` and `/healthz`.
2. **You, in Keycloak** (`https://$AUTH_HOST/admin` → realm `<realm>` → Clients → Create):
   - Client ID `wow`, OpenID Connect, **Client authentication ON**, Standard flow only
   - Valid redirect URIs `https://$WOW_HOST/oauth2/callback`, Web origins `https://$WOW_HOST`
   - Advanced → PKCE method `S256`
   - Client scopes → `wow-dedicated` → Add mapper "Audience", included client audience `wow`, add to access token (same as client `docs`)
   - Send me the secret from the Credentials tab, **or** put it into `.env` on jupiter yourself (I'll create the file with a placeholder)
3. **jupiter:** create `/home/luna/srv/crafting-site/` and `.env` (cookie secret generated with `openssl rand -base64 32 | head -c 32`), then add `vhost.d/$WOW_HOST` with `proxy_buffer_size 16k; proxy_buffers 8 16k; proxy_busy_buffers_size 32k;`.
4. **Deploy:** `./deploy.sh` (rsync + `docker compose up -d --build`), then restart `wow-auth` so nginx-proxy picks up the vhost.d file.
5. **Docs:** add an ADR entry to `luna-ai-plugin/docs/decisions.md`, add the service to `docs/hosts.md`, and if there is a finding, add a case via `/luna:case`.

## Verification

- Local: `curl -I localhost:8080/` → 200, `text/html`; `/healthz` → 200.
- jupiter: `docker ps` shows `wow-web` healthy and `wow-auth` up; `docker exec wow-auth wget -qO- http://wow-web/healthz`.
- External: `curl -I https://$WOW_HOST` → valid Let's Encrypt certificate, `302` → `$OIDC_ISSUER_URL/...`.
- `curl https://$WOW_HOST/index.html` without a cookie → **no** page content (redirect only).
- Browser (you): login → callback without a 502 → Werkbank page loads, fonts included.

## Side note

`runner-luna-design-system` on jupiter is currently in a restart loop (exit 127). It's unrelated to this task, and I'll only mention it.
