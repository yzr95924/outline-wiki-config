# outline_wiki_config

几分钟内部署一个自托管的 [Outline](https://github.com/outline/outline) Wiki 实例。

## 特性

1. 一套简单的 `make` + `bash` 脚本，生成所有需要的配置文件
2. `docker-compose.yml` 一键启动整套服务
3. 自带 [OIDC server](https://github.com/vicalloy/oidc-server) 管理用户，**不需要通过 Slack / Google 登录**
4. 附件 / 头像直接存到本机 `./data/outline/` 目录，无需额外对象存储

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

## 升级 Outline 版本

只需改版本号，再走一遍 make 流程。数据不丢（都在 `./data/`，bind mount，`clean-conf` 不碰它）。

1. 改 `scripts/config.sh` 里的版本号：

    ```bash
    OUTLINE_VERSION=1.9.2   # 改成目标版本
    ```

2. 重新渲染并重启：

    ```bash
    make clean-conf && make install
    ```

3. 验证：

    ```bash
    docker compose ps wk-outline   # IMAGE 列应为新版本，STATUS 为 Up (healthy)
    ```

    再用浏览器打开 Outline 入口，确认能访问、能登录。

`make clean-conf && make install` 做了什么：

- 从 `config.sh` 重新渲染所有配置（含 `.env`——版本号在这里才真正生效）
- `docker compose up -d` 拉取新镜像，**只重建 `wk-outline`**（postgres / redis / oidc-server / nginx 配置没变，持续在线不重建）
- reload nginx（重建容器会换内网 IP，不 reload 会 502——见下文「已知陷阱」第 7 条）
- 重新注册 OIDC client（幂等，不影响用户数据）

> ⚠️ **不要**用 `make update-images` + `docker compose up -d wk-outline`：`docker compose` 读的是渲染产物 `.env`，光改 `config.sh` 不重新渲染，`.env` 里的版本号不变，**镜像升不上去**；手动 `up` 还不 reload nginx，会 **502**。
>
> 只动了版本号、想跳过全量重渲染：直接改 `.env` 里的 `OUTLINE_VERSION`，再跑 `make update-images && make restart`（`make restart` 自带 `reload_nginx`，不会 502）。

## 配置说明：`scripts/config.sh`

| 变量 | 说明 |
| --- | --- |
| `URL` | 对外可访问的 Outline URL，**不要带端口号**（除非端口不是 80/443） |
| `HTTP_IP` / `HTTP_PORT_IP` | nginx 监听的 IP 和端口（用户访问这里） |
| `ALLOWED_DOMAINS` | 允许登录的邮箱域名（逗号分隔）。**新增用户邮箱的域名与首个管理员不同时必须设置** |
| `OUTLINE_VERSION` | Outline 镜像版本号 |
| `*_SECRET_KEY` / `*_ACCESS_KEY` | 各种密钥，`make install` 第一次跑会自动生成，**不要手填** |

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
| `make clean-data` | ⚠️ 删除所有数据卷（postgres、uc、outline），**不可恢复** |

## 维护工具

仓库根目录还有几个独立的维护脚本，不通过 Makefile 入口。

### `cleanup_outline.sh`

手动触发 Outline 自带的 daily cron（清理过期 session、孤立 api key 等）：

```bash
./cleanup_outline.sh
# 内部：curl -X POST "${URL}/api/cron.daily?token=${OUTLINE_UTILS_SECRET}"
```

**注意**：Outline 的 daily cron 在 `FILE_STORAGE=local`（本项目默认）路径下并不会清理磁盘上的孤儿附件，所以光跑它不够，需要配合下面的 `cleanup_orphans.sh`。

### `cleanup_orphans.sh`

清理"DB 里有附件记录 / 磁盘上有文件，但没有任何文档实际引用"的孤立附件。Outline 的 daily cron 在 local 存储模式下不会回收这类对象，长期运行会越积越多。

#### 检测出的三类孤儿

| 类别 | 含义 | 典型场景 |
| --- | --- | --- |
| **C1** `deleted_doc` | attachment 的 `documentId` 在 documents 表中找不到，**且**没有任何文档引用 | 文档被硬删除且图片没在其他地方复用 |
| **C2** `unreferenced` | attachment 和文件都在磁盘上，但没有被任何文档或历史版本引用 | 用户上传了图片但从未插入到正文；或被编辑时删掉 |
| **C3** `missing_file` | attachment 在 DB 中，但磁盘文件已丢失 | 手动删除过文件；container 重建丢失了挂载；或同步脚本 bug |

C1/C2 同时删除 DB 行 + 磁盘目录；C3 只删 DB 行（文件已经没了）。

#### 两阶段工作流

```bash
# 第 1 步：扫描，生成候选清单 .orphans_report.tsv
./cleanup_orphans.sh scan

# 第 2 步：查看清单 + URL（在浏览器里打开核实图片）
./cleanup_orphans.sh show

# 第 3 步（可选）：手动编辑清单，把不想删的行从 delete 改成 keep
vim .orphans_report.tsv

# 第 4 步：执行删除（会要求输入 yes 确认）
./cleanup_orphans.sh clean
# 非交互模式（脚本里调用）：
YES=1 ./cleanup_orphans.sh clean
```

每个候选都会附带形如 `${URL}/api/attachments.redirect?id=<attachment-id>` 的 URL，浏览器打开可以预览这张图是否真的没有用。

#### 报告文件格式

`.orphans_report.tsv`（**pipe `|` 分隔**，不是 tab。gitignored）：

```
CATEGORY|ATTACHMENT_ID|DB_SIZE|DISK_SIZE|DISK|DISK_PATH|DOC_TITLE|ACTION
C2_unreferenced|d32c1cba-...|19710|19710|yes|/root/.../d32c1cba-...|bazel|delete
C3_missing_file|3877b32b-...|1266236|0|no||Lakehouse|delete
```

**为什么用 `|` 而不是 tab**：`do_clean` 用 bash 的 `read IFS='|'` 解析每行；如果用 tab，bash 会把连续的 IFS 空白合并成一个分隔符——C3 行的 `disk_path` 是空的，会变成 `...|no|<tab><tab>|doc|delete`，中间的空字段被吞掉、`ACTION` 整列错位、整行被静默跳过（没有任何 warning）。`|` 不是空白字符，empty field 保留。

每行末尾的 `ACTION` 列是 `clean` 阶段唯一看的字段：`delete` 才会被处理，`keep` 跳过。把某行改成 `keep` 后无需重新跑 `scan`，直接 `clean` 即可。

#### 集成到定期任务

建议把 `cleanup_orphans.sh` 加进周维护（仅 `scan + show` 输出人工 review，`clean` 留作按需手动跑）。如果想全自动，可以加一个 `--older-than 7d` 之类的保护（避免清理掉最近上传还没来得及插入的图片），目前脚本里尚未实现，需要的话可以再加。

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
     |             +-----------------+
     |             | wk-postgres:5432|
     |             +-----------------+
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
├── cleanup_outline.sh                      # 手动触发 Outline daily cron
├── cleanup_orphans.sh                      # 扫描/清理孤立附件（见"维护工具"）
├── scripts/
│   ├── config.sh                           # 用户配置（需手写，从 .sample 复制）
│   ├── main.sh                             # 渲染入口
│   ├── utils.sh                            # sed helper
│   └── templates/                          # 配置文件模板源
│       ├── docker-compose.yml
│       ├── .env, env.outline, env.oidc, env.oidc-server
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
create_env_files          # .env, env.outline, env.oidc, env.oidc-server, fixture
  ↓
create_apps_config        # nginx 配置复制
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

## 已知陷阱 / 升级注意

1. **ddnsto 客户端对外是 HTTPS，本机 nginx 是 HTTP**：`scripts/templates/config/nginx/include/proxy.conf` 必须把 `X-Forwarded-Proto` 写死为 `https`。如果换穿透方案（比如 frp、cloudflared）需要重新评估该写什么。

2. **FORCE_HTTPS 必须保持 false**：ddnsto 已经在外层处理了 SSL。如果改成 `true`，Outline 会把内部 redirect 强制走 https，触发重定向循环。

3. **`URL` 不要带端口号**：之前带 `:443` 引起 OIDC state/cookie 不一致，浏览器里会看到 `?notice=auth-error`。

4. **`docker-compose.yml` 的 `version: "3"` 字段是 obsolete**：Docker compose v2 会忽略它但会打 warning，可以删掉。

5. **`logging: driver: none`**：默认关闭容器日志收集，`docker logs` 拿不到东西。调试时建议临时给 `wk-outline` 和 `wk-oidc-server` 加 `json-file` logging。

6. **Outline 镜像升级可能影响 OIDC plugin 行为**：Outline 1.8.x 用了 `app.proxy = true` + `IsUrl` 校验，新版本可能改了默认值，升级后请走一遍完整 OIDC 流程验证。

7. **重建容器后 nginx 可能 502（upstream IP 缓存）**：`wk-nginx` 的 worker 在启动时解析一次 `wk-outline` 等上游容器名并固化在进程里，之后不再重新解析。只要 `wk-outline` 被重建（升级、`docker compose up -d` 重建等），Docker 会给它分配新的内网 IP，而 nginx 还在打旧 IP → 502；特征是访问极快返回（几毫秒，说明根本没连上 upstream）。判别：在 nginx 容器里 `curl http://wk-outline:3000/` 是 200（curl 现场重新解析 DNS），但走 `http://<URL>` 是 502。`make install`/`start`/`restart` 都已经 `reload_nginx`，所以走 make 流程没事；凡是手动 `docker compose up -d wk-outline` 或重建过 outline 的，都要补一句：

    ```bash
    docker compose exec wk-nginx nginx -s reload
    ```
