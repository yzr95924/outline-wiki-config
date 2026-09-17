# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 约定

- **知识一律留在仓库里。** 项目知识、排查笔记、各种"记忆"都写到**本文件**(或其他
  纳入版本控制的文档),不要写进 Claude 的外部 `~/.claude` memory 目录,这样所有
  内容都跟着 git repo 一起走。

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

A standalone `cleanup_outline.sh` is provided to trigger Outline's daily cron manually via its API. It carries no token: it reads `URL` + `UTILS_SECRET` from the rendered `env.outline` (or `OUTLINE_URL` / `OUTLINE_UTILS_SECRET` env overrides).

## Configuration

1. Copy `scripts/config.sh.sample` → `scripts/config.sh` and edit.
2. The script auto-fills any blank `*_SECRET_KEY` / `*_ACCESS_KEY` with `openssl rand -hex N` on first run and writes them back into `scripts/config.sh`. Don't hand-edit these placeholders.
3. Notable knobs: `URL` (public URL), `HTTP_IP`/`HTTP_PORT_IP` (nginx bind), `ALLOWED_DOMAINS` (legacy — still rendered into `env.outline` but Outline 1.10.x no longer reads it; domain allowlisting now lives in Outline team settings), `NETWORKS` / `NETWORKS_EXTERNAL` (attach to an existing Docker network, e.g. when fronted by a host/nginx proxy — see `config/sample/nginx_outline.conf`).

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
- OIDC admin (add users): `<URL>/uc/admin/auth/user/`. **Every user must have a unique email** — Outline keys identity by email, and the bundled IdP sends no `email_verified` claim: an account reusing an existing member's email either silently signs into that member's Outline account (if it has logged in before, via its `user_authentications` binding) or fails login with "Your email address has not been verified" (new binding, `userProvisioner` rejects unverified email matching an existing user). Domain doesn't matter on Outline 1.10.x: the allowlist moved to team settings (`team_domains` table, empty = all domains allowed) and the `ALLOWED_DOMAINS` env is no longer read. Regular wiki members don't need Django `is_superuser` — only the one account used for `/uc/admin` should keep it.
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

## 排查

### 不要在 Outline 设置里配置"允许的域名"(Allowed Domains)

自带的 oidc-server 不发 `email_verified` claim(`oidc_provider_settings.userinfo` 只设置
name / preferred_username,claims 里的空值会被清掉)。Outline 的 `userProvisioner` 规定:
邮箱未验证时,只要"邮箱匹配到已有用户"或"团队配置了 allowedDomains"就拒绝登录。已有
`user_authentications` 绑定的老用户走早返回路径不受影响,但**一旦在 Outline
Settings → Members 里配了 Allowed Domains,所有新用户的 OIDC 登录都会报
"Your email address has not been verified"**。目前 `team_domains` 为空 = 放行所有域名,
保持为空即可(唯一邮箱才是真正的准入控制)。要修就得给 IdP 补
`claims["email_verified"] = True`(文件在镜像里,需挂载覆盖)。

### 登出 Outline 后刷新又自动登录

Outline 的 logout(`POST /api/auth.delete`)本身是成功的(events 表有 `users.signout`),
但 IdP 与 Outline 同域挂载在 `/uc`,Django 的 `sessionid` cookie 不随 Outline 登出失效;
下次点登录时 `/uc/oauth/authorize` 静默通过,几秒内又被登回来(events 里 `users.signout`
后面紧跟一条 `users.signin`,service=oidc —— 这是强判别特征)。

根因:Outline 1.10.x 的 OIDC 插件在**手动配置模式**(同时设置了 `OIDC_AUTH_URI` /
`OIDC_TOKEN_URI` / `OIDC_USERINFO_URI`)下不做 discovery,`logoutURL` 只读环境变量
`OIDC_LOGOUT_URI`;不配时 `/auth/oidc.logout` 直接 `redirect("/")`,永远不会调 IdP 的
`end-session` 端点(`/uc/oauth/end-session`,继承 Django `LogoutView`,会杀掉 session)。

已修(2026-09):`scripts/templates/env.oidc` 增加占位、`scripts/main.sh` 注入
`OIDC_LOGOUT_URI=${URL}/uc/oauth/end-session`;fixture(`templates/oidc-server-outline-client.json`)
的 `_post_logout_redirect_uris` 设为 `${URL}`,否则 end-session 杀完 session 会落到 Django
自己的登录页而不是跳回 Outline(线上 client `050984` 已同步改)。验证:

    curl -s -o /dev/null -w '%{redirect_url}\n' -H 'Host: <URL>' \
      'http://127.0.0.1:8888/auth/oidc.logout'
    # 应 302 到 /uc/oauth/end-session?client_id=...&post_logout_redirect_uri=...

注意:修复前已登录的浏览器没有 `id_token_hint` 储备(`LogoutTokenStore` 只在 logoutURL
存在时才持久化),修复后**第一次**登出会落到 Django 登录页(session 仍被正确杀掉);
再次登录之后的登出就会正常跳回 Outline 登录页。

### 新设备 / 无痕窗口登录报 502 Bad Gateway 或 `notice=auth-error`

OIDC 登录流程:浏览器 → Outline `/auth/oidc.callback` → Outline 到 oidc-server 的
token 端点换 code(`OIDC_TOKEN_URI`,走内网 `wk-nginx`)→ 写 session cookie 并跳转。
Outline 对回调有约 10 秒的请求超时,所以**换 token 慢**就会在回调上表现为 502
(nginx 日志:`upstream prematurely closed connection while reading response header
from upstream`)。Outline 后端那次交换其实仍可能成功(会记一条 `users.signin` 事件),
只是浏览器始终没收到跳转响应。已有 session 的设备不走 OIDC,所以**只有全新登录
(新设备 / 无痕窗口)才中招** —— 这是强判别特征。

这里的根因:**RSA 签名密钥累积。** `make install` 会在 `wk-oidc-server` 里无条件执行
`creatersakey`,每次安装都新增一个 `oidc_provider.RSAKey`。而 oidc_provider 的
`get_client_alg_keys` 每次换 token 都会把**所有** RSA key 重新 `importKey` 一次(每个
约 0.4 秒,且**不缓存**),因此换 token 耗时 ≈ key 数 × 0.4s。累积到约 28 个 key 时
达到约 11 秒,超过回调的 10 秒超时 → 每次新设备登录都 502。Makefile 现在会在
`make init` 之后、以及每次 `make start` / `make restart` 时用 `dedupe_rsakeys`
(best-effort,保留最旧的那个)把 key 收敛到 1 个,所以 Ctrl-C 或手动 `creatersakey`
留下的多余 key 下次启动会自动修回。若症状复发,检查并裁剪 key 数量:

    docker compose exec wk-oidc-server python manage.py shell -c \
      "from oidc_provider.models import RSAKey; k=RSAKey.objects.order_by('id').first(); print('before',RSAKey.objects.count()); k and RSAKey.objects.exclude(id=k.id).delete(); print('after',RSAKey.objects.count())"

从 nginx 访问日志确认:健康的 `POST /uc/oauth/token/` 在 1 秒内完成,出问题的约 10 秒。
Outline 侧报错是 `invalid_grant` / `Expired OAuth state`;oidc-server 记
`Bad Request: /uc/oauth/token/`。

### nginx 访问日志(默认关闭 —— 排查时再开)

`wk-nginx` 以 `logging: driver: none` 运行,避免访问日志刷屏,所以平时
`docker logs wk-nginx` 是空的(容器内的日志文件又软链到了 stdout/stderr,也没法用
`docker exec` 读取)。这会导致任何 502 / 网关错误在开日志前完全看不到 —— 排查这类
问题时**第一步就是把日志打开**。方法:把 `wk-nginx` 服务的 driver 改成 `json-file`
(`docker-compose.yml` 和 `scripts/templates/docker-compose.yml` 两份都改),重建容器
(`docker compose up -d wk-nginx` —— reload 不够,日志驱动在容器创建时定型),之后
`docker logs wk-nginx` 就能看到完整请求序列和单请求耗时(`rt=` / `urt=`),包括
Outline 后端对 `/uc/oauth/token/` 和 `/uc/oauth/userinfo/` 的调用。
`config/nginx/default.conf` 里已经定义好 `log_format timed`,所以只需翻转 docker 这边
的驱动即可。排查完记得改回 `none`。
