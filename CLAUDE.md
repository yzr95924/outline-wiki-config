# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Docker-Compose-based installer for a self-hosted [Outline](https://github.com/outline/outline) wiki, with a bundled OIDC server (`vicalloy/oidc-server`) replacing Slack/Google login. Outline 0.72.0+ supports local file storage, in which case MinIO is optional.

## Common commands

All operations go through the `Makefile` (uses `docker-compose` or `docker compose`, autodetected):

- `make install` — generate config files from `scripts/config.sh`, start containers, then bootstrap the OIDC server (runs `make init` inside `wk-oidc-server` and loads the `oidc-server-outline-client` fixture that registers Outline as an OIDC client).
- `make start` / `make stop` / `make restart` — container lifecycle; `start` also calls `scripts/main.sh reload_nginx`.
- `make logs` — tail logs from all services.
- `make update-images` — pull latest images.
- `make clean` — `clean-docker` + `clean-conf` (removes generated `.env`, `env.*`, `docker-compose.yml`, `config/uc/fixtures/*.json`, `config/nginx`). Keeps `data/`.
- `make clean-data` — also wipes persistent volumes under `data/` (postgres, minio, uc, outline, certs). **Destructive.**

A standalone `cleanup_outline.sh` is provided to trigger Outline's daily cron manually via its API (token is hardcoded in that file and is the `OUTLINE_UTILS_SECRET` from `config.sh`).

## Configuration

1. Copy `scripts/config.sh.sample` → `scripts/config.sh` and edit.
2. The script auto-fills any blank `*_SECRET_KEY` / `*_ACCESS_KEY` with `openssl rand -hex N` on first run and writes them back into `scripts/config.sh`. Don't hand-edit these placeholders.
3. Notable knobs: `URL` (public URL), `HTTP_IP`/`HTTP_PORT_IP` (nginx bind), `FILE_STORAGE` (`s3`|`local`), `ALLOWED_DOMAINS` (comma-separated; required when a non-admin user's email domain differs from the first admin's), `NETWORKS` / `NETWORKS_EXTERNAL` (attach to an existing Docker network, e.g. when fronted by a host/nginx proxy — see `config/sample/nginx_outline.conf`).
4. Note: `OIDC_CLIENT_SECRET` is intentionally seeded from `MINIO_SECRET_KEY` (commented "do not fix this bug" for backward compatibility with older versions). Same value is written into the OIDC client fixture and the OIDC env file.

## Architecture / how a fresh install flows

```
Makefile
  └─ make install
       ├─ cd scripts && bash main.sh init_cfg
       │     ├─ update_config_file        # fill in *_SECRET_KEY blanks in config.sh
       │     ├─ create_docker_compose_file # render ../docker-compose.yml
       │     ├─ create_env_files           # render ../.env, env.outline, env.oidc,
       │     │                              #  env.oidc-server, env.minio (if s3),
       │     │                              #  config/uc/fixtures/oidc-server-outline-client.json
       │     └─ create_apps_config         # copy nginx configs; if FILE_STORAGE != s3,
       │                                    #  rm_block "MINIO" strips out the minio
       │                                    #  service + locations via `##BEGIN MINIO`/`##END`
       ├─ docker compose up -d
       ├─ bash main.sh reload_nginx        # wait for wk-nginx then `nginx -s reload`
       ├─ docker compose exec wk-oidc-server make init
       └─ docker compose exec wk-oidc-server \
            python manage.py loaddata oidc-server-outline-client
```

Service graph (all on `${NETWORKS}`):
- `wk-nginx` — single public entrypoint; routes `/` → outline, `/uc` → oidc-server, `/uc/static` → static, and `/outline-bucket` → minio (the last only when `FILE_STORAGE=s3`).
- `wk-outline` — Outline app, port 3000; depends on postgres, redis, (minio).
- `wk-postgres`, `wk-redis` — Outline state.
- `wk-minio` + `wk-createbuckets` — S3-compatible object store and one-shot bucket creator (only when `FILE_STORAGE=s3`).
- `wk-oidc-server` — Django OIDC IdP, port 8000, served under `FORCE_SCRIPT_NAME=/uc`. Holds the user DB and a pre-seeded `outline` OIDC client.

Generated files (all in `.gitignore`): root `.env`, `env.outline`, `env.oidc`, `env.oidc-server`, `env.minio`, `docker-compose.yml`, `config/uc/fixtures/oidc-server-outline-client.json`, and the rendered `config/nginx/*`.

## Endpoints

- Outline UI: `http://<URL>` (default `http://127.0.0.1:8888`).
- OIDC admin (add users): `<URL>/uc/admin/auth/user/`. New users must have an email; if the email domain differs from the first admin's, add it to `ALLOWED_DOMAINS` in `scripts/config.sh` and re-run `make install` (or just edit `env.outline` and restart outline).
- OIDC authorize: `<URL>/uc/oauth/authorize/` (internal value used by Outline's `OIDC_AUTH_URI`).
- Cleanup cron: `cleanup_outline.sh` (manual cron trigger).

## Key scripts

- `scripts/main.sh` — orchestrator; exposes `init_cfg` and `reload_nginx`. Runs whatever arguments it receives (last line: `$*`), so `bash main.sh init_cfg` is the standard entrypoint and `bash main.sh reload_nginx` is the nginx hook.
- `scripts/utils.sh` — `env_replace`, `env_add`, `env_delete`, `env_tmpl_replace` (uses `${KEY}` template syntax), `rm_block` (matches `##BEGIN NAME` / `##END` blocks). On macOS requires `gsed` from `brew install gnu-sed`; aliases `docker-compose` → `docker compose` if the legacy binary is missing.
- `scripts/templates/` — every generated file's source of truth. `##BEGIN MINIO` / `##END` markers delimit the optional MinIO segments; `init_cfg` strips them when `FILE_STORAGE != s3`.

## Development loop

There is no build/test step — this repo is pure orchestration. Typical change cycle:

1. Edit a template under `scripts/templates/` or `scripts/config.sh`.
2. `make clean-conf && make install` to regenerate and restart.
3. `make logs` to observe.

To iterate on a single service without losing state: `make restart` (re-runs `init_cfg` and `reload_nginx`) or just `docker compose restart <svc>`.
