# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Docker-Compose-based installer for a self-hosted [Outline](https://github.com/outline/outline) wiki, with a bundled OIDC server (`vicalloy/oidc-server`) replacing Slack/Google login. Attachments and avatars are stored on the local filesystem under `./data/outline/`.

## Common commands

All operations go through the `Makefile` (uses `docker-compose` or `docker compose`, autodetected):

- `make install` — generate config files from `scripts/config.sh`, start containers, then bootstrap the OIDC server (runs `make init` inside `wk-oidc-server` and loads the `oidc-server-outline-client` fixture that registers Outline as an OIDC client).
- `make start` / `make stop` / `make restart` — container lifecycle; `start` also calls `scripts/main.sh reload_nginx`.
- `make logs` — tail logs from all services.
- `make update-images` — pull latest images.
- `make clean` — `clean-docker` + `clean-conf` (removes generated `.env`, `env.*`, `docker-compose.yml`, `config/uc/fixtures/*.json`, `config/nginx`). Keeps `data/`.
- `make clean-data` — also wipes persistent volumes under `data/` (postgres, uc, outline). **Destructive.**

A standalone `cleanup_outline.sh` is provided to trigger Outline's daily cron manually via its API (token is hardcoded in that file and is the `OUTLINE_UTILS_SECRET` from `config.sh`).

## Configuration

1. Copy `scripts/config.sh.sample` → `scripts/config.sh` and edit.
2. The script auto-fills any blank `*_SECRET_KEY` / `*_ACCESS_KEY` with `openssl rand -hex N` on first run and writes them back into `scripts/config.sh`. Don't hand-edit these placeholders.
3. Notable knobs: `URL` (public URL), `HTTP_IP`/`HTTP_PORT_IP` (nginx bind), `ALLOWED_DOMAINS` (comma-separated; required when a non-admin user's email domain differs from the first admin's), `NETWORKS` / `NETWORKS_EXTERNAL` (attach to an existing Docker network, e.g. when fronted by a host/nginx proxy — see `config/sample/nginx_outline.conf`).

## Architecture / how a fresh install flows

```
Makefile
  └─ make install
       ├─ cd scripts && bash main.sh init_cfg
       │     ├─ update_config_file        # fill in *_SECRET_KEY blanks in config.sh
       │     ├─ create_docker_compose_file # render ../docker-compose.yml
       │     ├─ create_env_files           # render ../.env, env.outline, env.oidc,
       │     │                              #  env.oidc-server,
       │     │                              #  config/uc/fixtures/oidc-server-outline-client.json
       │     └─ create_apps_config         # copy nginx configs
       ├─ docker compose up -d
       ├─ bash main.sh reload_nginx        # wait for wk-nginx then `nginx -s reload`
       ├─ docker compose exec wk-oidc-server make init
       └─ docker compose exec wk-oidc-server \
            python manage.py loaddata oidc-server-outline-client
```

Service graph (all on `${NETWORKS}`):
- `wk-nginx` — single public entrypoint; routes `/` → outline, `/uc` → oidc-server, `/uc/static` → static.
- `wk-outline` — Outline app, port 3000; depends on postgres, redis, oidc-server. Writes attachments/avatars to its mounted `./data/outline` volume.
- `wk-postgres`, `wk-redis` — Outline state.
- `wk-oidc-server` — Django OIDC IdP, port 8000, served under `FORCE_SCRIPT_NAME=/uc`. Holds the user DB and a pre-seeded `outline` OIDC client.

Generated files (all in `.gitignore`): root `.env`, `env.outline`, `env.oidc`, `env.oidc-server`, `docker-compose.yml`, `config/uc/fixtures/oidc-server-outline-client.json`, and the rendered `config/nginx/*`.

## Endpoints

- Outline UI: `http://<URL>` (default `http://127.0.0.1:8888`).
- OIDC admin (add users): `<URL>/uc/admin/auth/user/`. New users must have an email; if the email domain differs from the first admin's, add it to `ALLOWED_DOMAINS` in `scripts/config.sh` and re-run `make install` (or just edit `env.outline` and restart outline).
- OIDC authorize: `<URL>/uc/oauth/authorize/` (internal value used by Outline's `OIDC_AUTH_URI`).
- Cleanup cron: `cleanup_outline.sh` (manual cron trigger).

## Key scripts

- `scripts/main.sh` — orchestrator; exposes `init_cfg` and `reload_nginx`. Runs whatever arguments it receives (last line: `$*`), so `bash main.sh init_cfg` is the standard entrypoint and `bash main.sh reload_nginx` is the nginx hook.
- `scripts/utils.sh` — `env_replace`, `env_add`, `env_delete`, `env_tmpl_replace` (uses `${KEY}` template syntax), `rm_block` (matches `##BEGIN NAME` / `##END` blocks). On macOS requires `gsed` from `brew install gnu-sed`; aliases `docker-compose` → `docker compose` if the legacy binary is missing.
- `scripts/templates/` — every generated file's source of truth.

## Development loop

There is no build/test step — this repo is pure orchestration. Typical change cycle:

1. Edit a template under `scripts/templates/` or `scripts/config.sh`.
2. `make clean-conf && make install` to regenerate and restart.
3. `make logs` to observe.

To iterate on a single service without losing state: `make restart` (re-runs `init_cfg` and `reload_nginx`) or just `docker compose restart <svc>`.

## Troubleshooting

### New-device / incognito login returns 502 Bad Gateway or `notice=auth-error`

OIDC login flow: browser → Outline `/auth/oidc.callback` → Outline exchanges
the auth code at the oidc-server token endpoint (`OIDC_TOKEN_URI`, internal via
`wk-nginx`) → sets session cookie and redirects. Outline applies a ~10s request
timeout on the callback, so a slow token exchange surfaces as a 502 on the
callback (`upstream prematurely closed connection while reading response
header from upstream` in the nginx log). Outline's backend exchange can still
succeed (a `users.signin` event is logged) — the browser just never receives
the redirect. Existing sessions bypass OIDC entirely, so **only fresh logins
(new device / incognito) are affected** — a strong tell.

Root cause observed here: **RSA signing-key accumulation.** `make install`
runs `creatersakey` unconditionally inside `wk-oidc-server`, so every install
adds an `oidc_provider.RSAKey` row. `oidc_provider`'s `get_client_alg_keys`
re-imports *every* RSA key (`importKey`, ~0.4s each, **uncached**) on every
token request, so token-exchange time ≈ key_count × 0.4s. With ~28 keys that
reached ~11s > the ~10s callback timeout → 502 on every new-device login. The
Makefile dedupes to a single key (`dedupe_rsakeys`, best-effort, keeps the
oldest) both after `make init` and on every `make start` / `make restart`, so
Ctrl-C'd or manual `creatersakey` leftovers self-heal on the next start; if the
symptom ever returns, check and trim the key count:

    docker compose exec wk-oidc-server python manage.py shell -c \
      "from oidc_provider.models import RSAKey; k=RSAKey.objects.order_by('id').first(); print('before',RSAKey.objects.count()); k and RSAKey.objects.exclude(id=k.id).delete(); print('after',RSAKey.objects.count())"

Confirm the diagnosis from the nginx access log: a healthy
`POST /uc/oauth/token/` completes in well under 1s; a broken one takes ~10s.
Outline-side the error is `invalid_grant` / `Expired OAuth state`; oidc-server
logs `Bad Request: /uc/oauth/token/`.

### nginx access logs

`wk-nginx` uses the `json-file` driver with per-request timing in the log
format (previously `driver: none`, which discarded all access/error logs and
made any 502 invisible). `docker logs wk-nginx` shows the full request
sequence with `rt=`/`urt=` timing, including Outline's server-side calls to
`/uc/oauth/token/` and `/uc/oauth/userinfo/` — use it to attribute any
gateway error.
