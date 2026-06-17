# outline_wiki_config

几分钟内部署一个自托管的 [Outline](https://github.com/outline/outline) Wiki 实例。

## 特性

1. 一套简单的 `make` + `bash` 脚本，生成所有需要的配置文件
2. `docker-compose.yml` 一键启动整套服务
3. 自带 [OIDC server](https://github.com/vicalloy/oidc-server) 管理用户，**不需要通过 Slack / Google 登录**
4. 支持本地文件系统存储（Outline 0.72.0+，无需 MinIO）

## 快速开始

```bash
git clone https://github.com/yzr95924/outline_wiki_config.git
cd outline_wiki_config
cp scripts/config.sh.sample scripts/config.sh
# 编辑 config.sh：至少修改 URL、HTTP_IP、HTTP_PORT_IP
vim scripts/config.sh
make install
```

`make install` 会：

1. 根据 `scripts/config.sh` 渲染所有环境变量文件、nginx 配置和 OIDC client fixture
2. 启动 `wk-redis` / `wk-postgres` / `wk-outline` / `wk-oidc-server` / `wk-nginx` 等容器
3. 在 OIDC server 数据库里注册 Outline 的 OIDC client（含 `client_id=050984`、6 种 `response_types`、`_redirect_uris`）
4. 创建超级用户

启动后：

- Outline Wiki 入口：http://127.0.0.1:8888
- OIDC 用户管理后台：http://127.0.0.1:8888/uc/admin/auth/user/（添加新用户、修改密码等）
- OIDC 登录页：http://127.0.0.1:8888/uc/accounts/login/

## 配置说明：`scripts/config.sh`

| 变量 | 说明 |
| --- | --- |
| `URL` | 对外可访问的 Outline URL，**不要带端口号**（除非端口不是 80/443） |
| `HTTP_IP` / `HTTP_PORT_IP` | nginx 监听的 IP 和端口（用户访问这里） |
| `FILE_STORAGE` | `s3`（MinIO）或 `local`（本地文件系统）。Outline 0.72.0+ 才支持 `local` |
| `ALLOWED_DOMAINS` | 允许登录的邮箱域名（逗号分隔）。**新增用户邮箱的域名与首个管理员不同时必须设置** |
| `OUTLINE_VERSION` | Outline 镜像版本号 |
| `*_SECRET_KEY` / `*_ACCESS_KEY` | 各种密钥，`make install` 第一次跑会自动生成，**不要手填** |

注意：`OIDC_CLIENT_SECRET` 永远等于 `MINIO_SECRET_KEY`（项目维护者为了兼容老版本故意保留的行为，详见 `scripts/main.sh:11` 的注释）。

## Makefile 目标

| 目标 | 作用 |
| --- | --- |
| `make install` | 全量安装：生成配置 + 启动容器 + 注册 OIDC client + reload nginx |
| `make start` | 启动所有容器 |
| `make stop` | 停止所有容器 |
| `make restart` | 重启 |
| `make logs` | tail 所有容器日志 |
| `make update-images` | 拉取最新镜像 |
| `make repair-oidc-client` | 强制把 OIDC client 的 `_redirect_uris` 和 `response_types` 写成正确值（**见下面的故障排查**） |
| `make clean` | `clean-docker` + `clean-conf`（删除生成的所有配置文件，**保留 data/**） |
| `make clean-conf` | 只删除生成的配置文件 |
| `make clean-data` | ⚠️ 删除所有数据卷（postgres、minio、uc、outline、certs），**不可恢复** |

## 架构

```
+----------+   http://127.0.0.1:8888
|  Browser |
+----------+
     |
     v
+----------+      +-----------------+      +-----------+
| wk-nginx | ---> | wk-outline:3000 | <--- | wk-redis  |
| :80      |      | (Outline)       |      +-----------+
+----------+      +--------+--------+
     |                    |
     |                    v
     |             +-----------------+      +-----------+
     |             | wk-postgres:5432| <--- | wk-minio  |  (only if FILE_STORAGE=s3)
     |             +-----------------+      +-----------+
     |
     +----> /uc/*  --> wk-oidc-server:8000
                              |
                              v
                        +---------------+
                        | SQLite (db)   |
                        | (OIDC users,  |
                        |  OIDC clients)|
                        +---------------+
```

所有容器在同一个 Docker network（`${NETWORKS}`，默认 `outline-wiki-net`）里。

### 关键文件

```
.
├── Makefile                                # 所有操作的入口
├── docker-compose.yml                      # 由 gen-conf 渲染（git ignored）
├── scripts/
│   ├── config.sh                           # 用户配置（需手写，从 .sample 复制）
│   ├── main.sh                             # 渲染入口
│   ├── utils.sh                            # sed helper
│   └── templates/                          # 配置文件模板源
│       ├── docker-compose.yml
│       ├── .env, env.outline, env.oidc, env.oidc-server, env.minio
│       ├── config/nginx/                   # nginx default.conf + include/proxy.conf
│       └── oidc-server-outline-client.json # OIDC client 注册 fixture
└── config/                                 # 渲染后产物（git ignored）
    ├── nginx/
    └── uc/fixtures/
```

`init_cfg` 流程（`scripts/main.sh`）：

```
update_config_file        # 填 *_SECRET_KEY 占位符
  ↓
create_docker_compose_file
  ↓
create_env_files          # .env, env.outline, env.oidc, env.oidc-server, env.minio(if s3), fixture
  ↓
create_apps_config        # nginx 配置复制；FILE_STORAGE != s3 时 rm_block "MINIO" 去掉 MinIO 段
```

## 故障排查与修复

下面列出常见问题、原因和修复命令。按出现概率从高到低排序。

### 1. `/auth/oidc` 返回 500（最常见）

**症状**：浏览器访问 `https://your-domain/auth/oidc` 后看到 500 错误页面，URL 最终变成 `https://your-domain/?notice=auth-error`。

**原因**：Outline 端的 OIDC callback 流程在 OAuth state 阶段或 token 交换阶段失败。常见三大根因：

#### 1a. secure cookie 错误（Outline 不能写 secure cookie）

**真正报错**（在 Outline 容器日志里能看到）：

```
Error: Cannot send secure cookie over unencrypted connection
    at Cookies.set (.../cookies/index.js:126:11)
    at StateStore.store (.../passport.js:126:23)
```

**根因**：Outline 部署在内网 nginx 后面，外层（ddnsto / frp / cloudflared / etc.）是 HTTPS，到本机 nginx 是 HTTP。nginx 默认用 `proxy_set_header X-Forwarded-Proto $scheme;` 传 `http`，Outline 看到非 HTTPS 就拒绝设 secure cookie。

**修复**：`scripts/templates/config/nginx/include/proxy.conf` 里把

```nginx
proxy_set_header X-Forwarded-Proto $scheme;
```

改成（写死为 `https`，因为外层是 HTTPS）：

```nginx
proxy_set_header X-Forwarded-Proto https;
```

然后：

```bash
docker compose exec wk-nginx nginx -s reload
```

#### 1b. OIDC client 的 `_redirect_uris` 被截断

**症状**：OIDC server 日志 / 浏览器 console 里能看到 `redirect_uri` 不匹配。

**根因**：`django-oidc-provider 0.7.0` 的 `Client._redirect_uris` 字段用下划线前缀 + Python `property` 暴露。Django 的 `loaddata` 看到这个字段名会走 m2m 处理路径，触发 property setter，setter 用 `'\n'.join(value)` 写入，可能把 URI 截断（例如 `https://x/auth/oidc.callback` 变成 `https://x/auth`）。

**修复**：

```bash
# 一键修复：直接用 ORM 写 _redirect_uris 和 response_types
make repair-oidc-client
```

这条命令读取 `config/uc/fixtures/oidc-server-outline-client.json` 里的 `_redirect_uris` 和 `client_secret`，用 `Client.objects.update_or_create(...)` 写入（绕开 fixture loader 的 m2m 路径），并把 `response_types` 关联上 6 种响应类型。

如果问题反复出现（比如 `make install` 之后又出错了），检查 `Makefile install` 目标里 `$(MAKE) repair-oidc-client` 这一行是否还在。

#### 1c. `response_type=code` 不在 client 的 response_type_values 里

**症状**：OIDC server 返回 `?error=invalid_request&error_description=The request is otherwise malformed` 给 callback。

**根因**：DB 里的 `Client.response_types` m2m 关联只有部分 PK（例如只关联了 `code id_token token`），不包含 `code`。Outline 发起 `response_type=code` 时 OIDC server 拒绝。

**修复**：同 1b，跑 `make repair-oidc-client`。验证：

```bash
docker compose exec wk-oidc-server python manage.py shell -c "from oidc_provider.models import Client; c=Client.objects.get(client_id='050984'); print(list(c.response_type_values()))"
```

应当输出 6 个值，包含 `code`。

### 2. `wk-outline` 容器启动失败（Restarting 循环）

**症状**：

```bash
docker compose ps wk-outline
# NAME                          STATUS                       PORTS
# outline_wiki_config-wk-...   Restarting (1) 30 seconds ago
```

**日志**（`docker logs outline_wiki_config-wk-outline-1`）：

```
error This project's package.json defines "packageManager": "yarn@4.11.0".
However the current global version of Yarn is 1.22.22.
```

**根因**：Outline 1.x+ 的 `package.json` 声明 `yarn@4.x`，需要 corepack 启用。`docker-compose.yml` 里显式 `command: sh -c "yarn db:migrate ... && yarn start"` 触发了这个检查。

**修复**：`scripts/templates/docker-compose.yml` 和 `docker-compose.yml` 里 `wk-outline` 服务的 `command:` 行注释掉（用 image 默认 entrypoint）：

```yaml
wk-outline:
    image: outlinewiki/outline:${OUTLINE_VERSION}
    # command: sh -c "yarn db:migrate --env production-ssl-disabled && yarn start"
    environment:
      ...
```

然后 `docker compose up -d wk-outline` 重建容器。

### 3. `make install` 卡在 `waiting nginx`

**症状**：

```
nginx: [emerg] host not found in upstream "wk-outline" in /etc/nginx/conf.d/default.conf:9
waiting nginx
```

**根因 A**：`wk-outline` 还没启动（通常是问题 2 的连锁反应），nginx `proxy_pass http://wk-outline:3000` 找不到 upstream。

**根因 B**：`scripts/main.sh` 里 `reload_nginx` 调 `docker-compose` v1 命令，但你只有 `docker compose` v2。

**修复**：

- 根因 A：先解决问题 2
- 根因 B：升级到本项目当前 commit（`scripts/main.sh` 的 `reload_nginx` 已经改成 `type -P` 自动检测 v1/v2 + `--env-file .env` 解决 v2 `exec` 不读 `.env` 的问题）

### 4. `docker logs` 看不到容器日志

**症状**：

```
Error response from daemon: configured logging driver does not support reading
```

**根因**：`scripts/templates/docker-compose.yml` 默认所有服务 `logging: driver: none`，Docker 不收集 stdout/stderr，所以 `docker logs` 拉不出来。

**临时方案**（调试用）：手动给 `wk-outline` 加 json-file logging：

```yaml
wk-outline:
    ...
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "1"
```

然后 `docker compose up -d wk-outline` 重建。

**永久方案**：把这个 logging 块也加到 `scripts/templates/docker-compose.yml` 里。注意每次 `make clean-conf && make install` 渲染后会用模板覆盖，记得保留。

### 5. 登录后跳到 `?notice=auth-error`

**症状**：用户已经能登录，但某次重新打开 Outline 时跳到 `https://your-domain/?notice=auth-error`。

**根因**：浏览器里残留了旧的 OIDC session / state cookie（OIDC server 端数据已经变了，旧 cookie 触发的流程会失败）。

**修复**：清浏览器 cookie，特别是 `your-domain` 和 `your-domain/uc` 两个域下的 cookie，然后重新访问 `https://your-domain/auth/oidc`。

## FAQ

**Q：新增了用户，但用户登录不了 Outline？**

- 用户必须有邮箱
- 如果邮箱域名与第一个管理员的域名不同，把这个域名加到 `scripts/config.sh` 的 `ALLOWED_DOMAINS`，然后 `make install`

**Q：怎么改 OIDC superuser 密码？**

```bash
docker compose exec wk-oidc-server python manage.py changepassword <username>
```

**Q：怎么把 MinIO 切到 local 存储？**

`scripts/config.sh` 里 `FILE_STORAGE=local`，然后 `make clean-conf && make install`。MinIO 段会被自动从 `docker-compose.yml` 和 nginx 配置里删掉（`rm_block "MINIO"` 流程）。

**Q：升级 Outline 版本？**

1. 改 `scripts/config.sh` 里的 `OUTLINE_VERSION`
2. `make update-images`
3. `docker compose up -d wk-outline`（应用新 image）
4. `make repair-oidc-client`（保险，确保 OIDC client 状态对）

## 已知陷阱 / 升级注意

1. **ddnsto 客户端对外是 HTTPS，本机 nginx 是 HTTP**：`scripts/templates/config/nginx/include/proxy.conf` 必须把 `X-Forwarded-Proto` 写死为 `https`。如果换穿透方案（比如 frp、cloudflared）需要重新评估该写什么。

2. **FORCE_HTTPS 必须保持 false**：ddnsto 已经在外层处理了 SSL。如果改成 `true`，Outline 会把内部 redirect 强制走 https，触发重定向循环。

3. **`URL` 不要带端口号**：之前带 `:443` 引起 OIDC state/cookie 不一致，浏览器里会看到 `?notice=auth-error`。

4. **`docker-compose.yml` 的 `version: "3"` 字段是 obsolete**：Docker compose v2 会忽略它但会打 warning，可以删掉。

5. **`logging: driver: none`**：默认关闭容器日志收集，`docker logs` 拿不到东西。调试时建议临时给 `wk-outline` 和 `wk-oidc-server` 加 `json-file` logging。

6. **Outline 镜像升级可能影响 OIDC plugin 行为**：Outline 1.8.x 用了 `app.proxy = true` + `IsUrl` 校验，新版本可能改了默认值，升级后请走一遍完整 OIDC 流程验证。

7. **`OIDC_CLIENT_SECRET == MINIO_SECRET_KEY`**：`scripts/main.sh:11` 注释说"do not fix this bug for backward compatibility"。新部署没历史包袱的话，可以把 `OIDC_CLIENT_SECRET` 改成独立生成。
