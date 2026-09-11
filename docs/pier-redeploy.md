# 用 Pier 重新部署 andy-blog 技术方案

| 项 | 内容 |
| --- | --- |
| 状态 | **已切流。** 公网入口是 Pier Traefik；旧 Nginx 仅作回滚备用 |
| 日期 | 2026-09-11 |
| 范围 | 阿里云北京 ECS 上的生产栈 `jiawen.live` |
| 目标 | 用 [Pier](https://github.com/joveptesg/Pier) 接管编排与反代，业务镜像与数据不变 |
| 访问 | SSH 为主，阿里云 CLI 做快照 / 安全组 / 探活 |
| CLI | `aliyun configure` 配置集 `default`（账号 `1646741456677329`）。不要用 `account-b`（那是 `tzjii.com`） |

本文只写方案，不包含已执行的变更。落地前须完成 [待确认事项](#10-待确认事项)。

## 0. 施工决定（2026-09-11）

不搁置。证书、安全组、Pier **同一轮做完**，不拆成「先灭火、以后再迁」。

单次顺序（停机只发生在装 Pier 那一段）：

1. SSH 探活 `182.92.104.98`（compose / 卷 / 内存 / 本机证书）。
2. 系统盘快照 + `mongodump`。
3. 源站续期（离开 9 月 21 日）并 `deploy-cdn.sh` 推 `static.jiawen.live`。成功前不拆 `acme`。
4. 收紧安全组：删 `0.0.0.0/0` 全协议/全端口/3389；保留 80/443；22 与随后的 8443 收窄。
5. 窗口外预置 Pier 二进制、预拉 `traefik` / 业务镜像。
6. 维护窗口：`make prod-down` → 装 Pier（`PIER_SKIP_RAILPACK=1`）→ 部署 compose → 面板只绑 `jiawen.live` / `www` / `api` / `admin` → HTTP-01 出证 → 业务验收。
7. 当天改 `deploy.sh` 只打 Pier stacks 目录。`acme` 改独立 timer，继续喂 CDN。

失败：8 分钟出不了 Let’s Encrypt 证，停 Pier、`make prod` 回切。源站与 CDN 若已在窗口前续好，回切后站点仍有有效证。

### 2026-09-11 已执行

| 项 | 结果 |
| --- | --- |
| 快照 | `s-2zeeer1bat1e7120zxf1` 完成 |
| Mongo 备份 | `/root/backups/andy-blog-20260911/andy-blog.archive.gz` |
| 安全组 | 已删全端口 catch-all；保留 22/80/443 公网；8443 仅 `202.182.127.219/32` |
| 卷名 | 已确认 `andy-blog_mongo-data` / `andy-blog_redis-data` |
| Pier 安装 | 已换 Ubuntu 24.04（GLIBC 2.39）。`PIER_SKIP_RAILPACK=1` 装好，`pier-traefik` 占 80/443 |
| 权威 DNS | 已改回阿里云 `dns3/dns4.hichina.com`；`ai.jiawen.live` 仍 NS 委派 Cloudflare |
| 源站证书 | Traefik HTTP-01，Let’s Encrypt，有效至 2026-12-10（分域名各一张） |
| CDN 证书 | `static.jiawen.live` RSA 泛域名，有效至 2026-12-10 |
| 域名路由 | Pier 域名 API 因 `port_allocations` 为空失败；已手写 `/opt/pier/data/traefik/dynamic/andy-blog.yml`（仓库备份 `pier/traefik-andy-blog.yml`） |
| 发布路径 | `scripts/deploy.sh` / `make prod` 已改打 `docker-compose.pier.yml`，不再拉起 gateway |
| 面板域名 | `https://pier.jiawen.live`（Let’s Encrypt）；`:8443` 仍只对出口 IP 开放 |

---

## 1. 背景与目标

当前仓库 `andy-blog-deploy` 用 Docker Compose 在单机上跑整站：Nginx 网关按域名分发，acme.sh + 阿里云 DNS-01 签泛域名证书，GitHub Actions SSH 到机器执行 `scripts/deploy.sh` 做滚动更新。

Pier 是轻量自建 PaaS（Coolify / Vercel 替代）：单二进制 + Traefik，面板管理 Compose / 镜像 / 域名 / HTTPS。目标不是重写博客，而是把**控制面**从「仓库里的 compose + Makefile + 手写 Nginx」换成 Pier，并保留：

- 现有 ACR 镜像与 tag 发布
- Mongo / Redis 数据
- 域名与 OSS / CDN
- Cloudflare Workers 上的 `andy-blog-ai`

不在范围内：另开 ECS、用 Railpack 在服务器上从源码构建、把静态 CDN 迁进 Pier。

---

## 2. 现状盘点

### 2.1 生产机（阿里云 CLI `default`，2026-09-11 第二轮核对）

第一轮误把 `account-b` 名下 `182.92.130.100` 写成了本站机器。本站解析与 CDN 都在 `default`。

| 项 | 值 |
| --- | --- |
| 实例 | `i-2ze4bt3yt4dmclut6px4`（`ecs.e-c1m1.large`） |
| 规格 | 2 vCPU / **2 GB** / 系统盘 40 GB ESSD Entry（无快照） |
| 系统 | Ubuntu **22.04** |
| 地域 / 可用区 | `cn-beijing` / `cn-beijing-h` |
| 公网 | `182.92.104.98`（固定带宽 3 Mbps，包年包月至 2027-06-11） |
| 内网 | `172.18.191.236` |
| VPC / 交换机 | `vpc-2zexp1jhu77w4vsm1vrsg` / `vsw-2zej1shzryndgtge3m6gu` |
| 安全组 | `sg-2ze4y70q3im14cju1p1g`（入方向 `0.0.0.0/0` 放行全部协议/端口，含 22、3389） |

账号内北京地域目前只有这一台 ECS。本机已装 `aliyun` 3.4.2。没有 `~/.ssh/config`，线上 SSH 目前走 GitHub Secrets。落地前必须先打通本机 SSH 到 **`182.92.104.98`**。

现网盘点缺口（SSH 前无法关闭）：容器是否真在这台机、卷名、磁盘占用、本机证书是否也过期。

### 2.2 现网拓扑

```
公网 80/443/udp443
        │
   gateway (nginx 1.27)
   HTTP/1.1 + HTTP/2 + HTTP/3
   HSTS 6 个月 · 泛域名证书
        │
   ┌────┼────────┐
   │    │        │
  web  admin    api
  :3000 :80     :3000
                 │
            mongo · redis
                 │
              命名卷
     andy-blog_mongo-data
     andy-blog_redis-data

旁路：acme 容器（DNS-01 泛域名 + 续期后推 CDN）
旁路：static.jiawen.live → OSS + 阿里云 CDN（不进本机 80）
旁路：ai.jiawen.live → Cloudflare Workers
```

| 服务 | 镜像 / 来源 | 职责 |
| --- | --- | --- |
| `gateway` | `nginx:1.27-alpine` | 按域名反代、TLS、HTTP/3 |
| `web` | ACR `andy-blog-web` | Nuxt SSR |
| `admin` | ACR `andy-blog-admin` | 后台 SPA |
| `api` | ACR `andy-blog-api` | NestJS |
| `mongo` | `mongo:7` | 主库 |
| `redis` | `redis:7-alpine` | 缓存 |
| `acme` | 本仓库 `./acme` | 泛域名签发、续期、推 CDN |

Compose 项目名：`COMPOSE_PROJECT_NAME=andy-blog`。生产命令：

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml \
  --env-file .env.production --env-file .env.production.local \
  up -d
```

日常发布：应用仓库 CI 推 ACR → 本仓库 `repository_dispatch` → SSH → `scripts/deploy.sh <api|web|admin|all> <tag>`。

### 2.3 域名与证书

| 主机名 | 指向 | 证书来源 |
| --- | --- | --- |
| `jiawen.live` / `www.jiawen.live` | `182.92.104.98` | 泛域名 `jiawen.live` + `*.jiawen.live`（本机 Nginx，SSH 后核到期日） |
| `api.jiawen.live` | 同上 | 同上 |
| `admin.jiawen.live` | 同上 | 同上 |
| `static.jiawen.live` | OSS + CDN | **CDN 上这张证书已于 2026-09-09 过期**（`acme-jiawen.live-20260611075111`，签发 2026-06-11，此后未再推送） |
| `ai.jiawen.live` | NS 委派 Cloudflare | 不在本机，不进 Pier |
| `tzj` / `tzj-admin` / `tzj-api` | `39.106.53.211` | 同 zone 另一套站，不要绑进 Pier |
| `_acme-challenge` | TXT | 现网 DNS-01 残留，Pier HTTP-01 用不到 |

证书用 **DNS-01**，不是 HTTP-01。原因写在 `acme/issue.sh`：`static.jiawen.live` 不指向本机。Nginx 已下发 HSTS（`max-age=15768000`）和 `Alt-Svc: h3=":443"`。

**不要**把「acme 容器会自动续期并推 CDN」当成已成立的基线。CDN 侧已过期且 `CertUpdateTime` 停在 2026-06-11，说明续期链路至少对 CDN 是断的。迁 Pier 之前必须先修或重建这条链路。

API 上传限制：`client_max_body_size 20m`。

---

## 3. 目标架构

```
公网 80/443 (TCP)
        │
   Traefik（Pier 拉起）
   HTTP-01 Let's Encrypt
        │
   ┌────┼────────┐
   │    │        │
  web  admin    api     ← 仍用 ACR 镜像
                 │
            mongo · redis
                 │
         原命名卷（external）

Pier systemd  :8443
  管理 Compose / 日志 / 域名
  不编译业务代码

CDN / OSS / AI Worker 保持原样
CDN 证书改为独立续期，不再挂在 compose 的 acme 服务上
```

Pier 安装形态（官方 `install.sh`）：

| 项 | 值 |
| --- | --- |
| 用户 | `pier`（加入 `docker` 组） |
| 目录 | `/opt/pier`，数据 `/opt/pier/data` |
| 进程 | systemd `pier.service` |
| 面板 | 默认 `:8443` |
| 反代 | Traefik 容器占 80/443 |
| 数据库 | Pier 自带 SQLite，与博客 Mongo 无关 |

安装参数：**预编译 `pier-linux-amd64`**，并设 `PIER_SKIP_RAILPACK=1`。禁止在 2 GB 机器上 `cargo build` 或启用 Railpack（官方要求 ≥ 4 GB）。

---

## 4. 关键约束（已对照 Pier 源码）

Pier `crates/pier-core/src/proxy/config.rs` 里的 Traefik 静态配置由程序生成，文件头写明 **do not edit manually**：

- 入口只有 `web :80`、`websecure :443`（TCP）。
- ACME 只有 `certificatesResolvers.letsencrypt`，且 **仅 `httpChallenge`**。
- 没有 DNS-01、没有 `alidns`、没有 HTTP/3 / QUIC、没有自定义证书文件 provider。
- 80 上配置了整入口跳转到 HTTPS；Traefik 会拦截 `/.well-known/acme-challenge`，HTTP-01 仍可用。

因此本方案**不以「失败再改 Traefik DNS-01」为正式回退路径**。手改 `/opt/pier/data/traefik/traefik.yml` 可能被 Pier 下次写配置覆盖。若 HTTP-01 在国内机房失败，回退是：**停 Pier Traefik，恢复旧 Nginx + 已有证书**。

`static.jiawen.live` 不能走 HTTP-01，必须在拆掉 `acme` 容器之前，先有独立的 CDN 证书续期。

---

## 5. 方案选型

| 方案 | 做法 | 结论 |
| --- | --- | --- |
| A. 同机切换 | 现有 ECS 装 Pier，Traefik 替换 Nginx，Compose 进 Pier | **采用** |
| B. 另开 ECS | 新机器装 Pier，搬数据，切 DNS | 账号里没有第二台；多一份费用；2 GB 站点没必要 |
| C. 只装 Pier、Nginx 不动 | Pier 不占 80/443 | 自动 HTTPS 用不上，收益接近零 |
| D. Railpack 源码构建 | 服务器上编 Nuxt / Nest | 2 GB 会 OOM，否决 |

发布路径：

| 方案 | 做法 | 结论 |
| --- | --- | --- |
| 构建仍在 GitHub Actions + 推 ACR | 不改应用仓库主流程 | **必须保留** |
| 过渡：SSH `deploy.sh` 改 Pier compose | 切流后短期内仍用 Actions SSH | **过渡期采用** |
| 目标：Actions 推完镜像后通知 Pier Redeploy | 少一次手写 compose up | 稳定后再切 |
| Pier Git 源码构建 | 服务器编译 | 否决 |

---

## 6. 详细设计

### 6.1 Compose 怎么进 Pier

新增 `docker-compose.pier.yml`（名称可在实现时微调），由现有 `docker-compose.yml` 改出，**不含** `gateway` / `acme`。

硬性要求：

1. `web` / `admin` / `api` 加入内部网 `blog`。**不要**在 YAML 里写官方文档里的 `pier-traefik`——源码里的网络名是 `pier-net`。Pier 部署后会把带 `pier.service.id` 的容器挂到 `pier-net`；纯粘贴的 Compose 若没有该 label，要在面板里绑域名，并确认容器已进 `pier-net`。
2. Traefik **没有** Docker provider，只有 file provider（`/opt/pier/data/traefik/dynamic/`）。Compose 上的 `traefik.*` label **不会被自动读取**。域名必须在 Pier 面板为 `web` / `api` / `admin` 绑定，由 Pier 写动态路由。
3. `mongo` / `redis` 不暴露端口、不进 Traefik、不绑公网域名。
4. 命名卷声明为 **external**，名字写死现网卷：

   ```yaml
   volumes:
     mongo-data:
       external: true
       name: andy-blog_mongo-data
     redis-data:
       external: true
       name: andy-blog_redis-data
   ```

5. 镜像继续走 ACR VPC：

   `crpi-cqk2pxumsxjesw50-vpc.cn-beijing.personal.cr.aliyuncs.com/andy-blog/...`

6. 密钥不进仓库。Pier UI 的 env override 或服务器本地 env 文件均可，须与现有 `.env.production.local` 对齐。
7. 在 Pier → Registries 登记 ACR，或保证 `pier` 用户能读现有 `docker login`（`install.sh` 会处理 `/root/.docker/config.json` 的 ACL）。

结构示例（实现时以仓库文件为准）。下面 **没有** Traefik label，避免误以为 label 会生效：

```yaml
services:
  web:
    image: ${REGISTRY}/andy-blog-web:${WEB_TAG}
    environment:
      NUXT_PUBLIC_API_BASE: ${API_BASE_URL}
      NUXT_API_BASE_INTERNAL: http://api:3000
    networks: [blog]
    # 域名在 Pier 面板绑定：jiawen.live、www.jiawen.live → 容器端口 3000
  api:
    image: ${REGISTRY}/andy-blog-api:${API_TAG}
    networks: [blog]
    # 面板绑定 api.jiawen.live → 端口 3000；上传上限 20MB 须在 Pier/Traefik 侧单独配
  admin:
    image: ${REGISTRY}/andy-blog-admin:${ADMIN_TAG}
    networks: [blog]
    # 面板绑定 admin.jiawen.live → 端口 80

  mongo:
    image: mongo:7
    volumes: [mongo-data:/data/db]
    networks: [blog]
    healthcheck:
      test: ["CMD-SHELL", "mongosh --quiet --eval \"db.runCommand('ping').ok\" || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 12
  redis:
    image: redis:7-alpine
    volumes: [redis-data:/data]
    networks: [blog]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 12

volumes:
  mongo-data:
    external: true
    name: andy-blog_mongo-data
  redis-data:
    external: true
    name: andy-blog_redis-data

networks:
  blog:
    driver: bridge
```

YAML 被 Pier 写到 `/opt/pier/data/stacks/<栈名>/docker-compose.yml`。仓库里的 `docker-compose.pier.yml` 只是源稿；日常发布必须改这一份，或只调 Pier Redeploy，禁止两处各改。

Pier UI 若提供「带卷删除 / down -v」，**禁止使用**。数据卷只许 `external` 复用，不许让 Pier 新建或删卷。

`docker-compose.prod.yml` 先留着，作为回滚编排，不要在切流当天删除。

### 6.2 切流时必须整栈停旧

2 GB 不能新旧两套并跑。更关键的是：Pier 会按 YAML `up` 出一套新的 `api` / `web` / `admin` / `mongo` / `redis`。若旧容器还占着同名卷，不是启动失败，就是打出第二套进程后内存打满。

正确顺序：

1. 备份。
2. `make prod-down`（或等价：停掉整个 `andy-blog` 项目，**含 mongo/redis**）。
3. 确认容器已停、卷还在：`docker volume ls | grep andy-blog`。
4. Pier 部署新栈，external 卷挂回同一份数据。
5. Mongo 会有数分钟不可用。个人博客可接受；不要试图「只停 gateway、留下 mongo」。

### 6.3 HTTPS

| 证书 | 切流后 |
| --- | --- |
| `jiawen.live` `www` `api` `admin` | Traefik HTTP-01，每条 Host 规则向 Let's Encrypt 申请 |
| `static.jiawen.live` | **不进 Pier**。推荐：把现有 `acme` 镜像改成宿主机 systemd timer / cron（仍用 `acme/issue.sh` + `deploy-cdn.sh`，只不再占用 compose 的 80/443）。备选：阿里云 SSL 控制台手动上传。拆 compose 内 `acme` 服务之前，这条路径必须已演练成功。 |

HSTS 已在浏览器缓存最多 6 个月。切流后若 Traefik 还在用默认自签证书，用户**不能**退回 HTTP，只会看到证书错误，直到 Let's Encrypt 签发成功。维护窗口必须包含「证书签发成功」这一条验收，不能只看容器 `Up`。

Let's Encrypt 失败时不要狂点重试（每主机名每周失败次数有限额）。超限则回切 Nginx，用磁盘上已有的 `nginx/certs`。

HTTP/3：Pier Traefik 未开 QUIC。现网 `Alt-Svc` 缓存最多 24 小时，部分浏览器可能先试 h3 再回落 TCP。可接受；不要为此阻塞方案。

### 6.4 控制面安全

- 安全组：`80/tcp`、`443/tcp` 对公网；`8443/tcp` **只放行操作者出口 IP**，禁止 `0.0.0.0/0`。若开启 Traefik dashboard，源码会再占 **8080**，同样禁止对公网开放。
- 装完立刻打开 `/setup` 建管理员。
- 面板可先用 `http://182.92.104.98:8443`；稳定后再考虑 `pier.jiawen.live`。现网安全组已是全端口对公网，**只加一条 8443 白名单不够**，必须先删掉 `0.0.0.0/0` 的全端口/全协议入站，再按 22（收窄）+ 80 + 443 + 8443（收窄）重写。
- 国内拉 `pier.team` / GitHub Release 可能失败：本机下载二进制并校验 sha256，再 `scp` 上去。

### 6.5 资源

粗算常驻：Mongo 400–700 MB + Redis 30–80 + API 150–300 + Nuxt 150–300 + Admin 20–40 + Traefik 50–100 + Pier 20–40 + 系统 200–300，接近 2 GB。

约束：

- 禁止 Railpack / BuildKit 业务构建。
- 切流时禁止 Nginx 与 Traefik 同时占 80/443。
- 允许 install.sh 加约 4 GB swap（可用 `PIER_SKIP_SWAP=1` 关掉；建议保留）。
- 40 GB 盘要盯镜像层，发布后 `docker image prune`。
- 拉三个业务镜像时内存会抖，维护窗口不要并行 `pull` 无关镜像。

### 6.6 CI/CD 衔接

切流当天必须改发布路径，避免 Actions 仍对旧 compose 做 `up`、Pier 又管同一套容器。

过渡（推荐先做）：

1. `scripts/deploy.sh` 改为对 Pier compose 文件 `pull` + `up -d --no-deps`。
2. 工作流仍 SSH 到同一台机。
3. 生产 YAML 的唯一位置定为 `/opt/pier/data/stacks/<栈名>/docker-compose.yml`。`deploy.sh` 应对该文件 `pull` + `up`，或只调 Pier Redeploy。仓库里的 `docker-compose.pier.yml` 只作源稿同步。

目标态：Actions 推完 ACR 后调 Pier Redeploy / webhook，SSH 脚本降级为应急。

同一时间只允许一条路径改生产栈。

### 6.7 保留与废弃

| 保留 | 废弃（切流成功并观察 7 天后） |
| --- | --- |
| ACR 与三个应用仓库 CI | `gateway` 服务 |
| `.env.production*` | compose 内 `acme` 服务（证书职责先迁走） |
| Mongo / Redis 卷 | 仅 Nginx 使用的 `nginx/templates`（回滚期内先留） |
| OSS / CDN / AI Worker | 以 `make prod` 为日常入口 |
| `docker-compose.prod.yml`（回滚用） |  |

---

## 7. 落地步骤

### 阶段 0 — 探活（只读）

1. 本机 SSH 登录 **`182.92.104.98`**（不是 `182.92.130.100`）。
2. `docker compose ps`、卷名、磁盘、内存、`ss -lntp` 看 80/443；核对本机 `nginx/certs` 是否也过期。
3. 阿里云 CLI：先收紧安全组（现网全端口开放）；80/443 对公网保留，供 HTTP-01。
4. 从 ECS 测 `github.com`、`pier.team`、Let's Encrypt 目录、ACR VPC 地址，决定二进制怎么运上去。
5. CDN 证书已过期：先修续期并推送，再谈拆 `acme`。
6. 打第一份 ECS 快照（当前 0 份）。

### 阶段 1 — 备份

1. 阿里云 CLI 打 ECS 系统盘快照（现网快照数为 0）。
2. `mongodump`；必要时再 `docker run --rm -v andy-blog_mongo-data:/data ...` 打一份卷归档。
3. 拷贝 `/opt/andy-blog/.env.production.local`、`nginx/certs`、acme.sh 账户目录。

### 阶段 2 — 仓库改动（先合代码，不切流）

1. 新增 `docker-compose.pier.yml`（§6.1）。
2. 写独立 CDN 续期脚本/cron 说明，或改 `acme` 为可脱离 compose 运行。
3. 准备 `deploy.sh` 的 Pier 分支（先不改默认路径）。
4. 保留 `docker-compose.prod.yml`。

### 阶段 3 — 维护窗口：停旧栈 → 装 Pier → 部署（预计 20–40 分钟）

Pier 的 `deploy_traefik` 会把 `pier-traefik` 容器绑到宿主机 **80/443**。与现网 Nginx **不能共存**。本阶段与切流合并。

准备工作（窗口外可做）：二进制已 scp 到机器并 `sha256sum` 通过；安全组已放行 `8443`（源 IP 收窄）；CDN 独立续期已演练；快照与 mongodump 已完成。

窗口内：

1. `cd /opt/andy-blog && make prod-down`。确认卷在、80/443 空闲。
2. `PIER_SKIP_RAILPACK=1 sudo bash install.sh --binary ./pier-linux-amd64`
3. 打开 `/setup` 建管理员；Settings 里填 ACME 邮箱（`ACME_EMAIL`）。
4. 登记 ACR。确认 Docker 网络 `pier-net` 存在。
5. 在 Pier 创建 Compose 栈，粘贴 `docker-compose.pier.yml`，部署。
6. 为 `web` / `api` / `admin` 绑定域名与容器端口；确认三容器已加入 `pier-net`。
7. 等待 Let's Encrypt：`curl -vI https://jiawen.live` 须为 LE 证书。超时（建议 8 分钟）未出证则按 §8 回滚，不要连点重试。
8. 业务验收：前台、后台登录、发文、OSS 图、AI webhook、上传（大于数 MB 的图）。

### 阶段 4 — 收尾

1. 切换 `deploy.sh` / Actions，只改 `/opt/pier/data/stacks/<栈名>/` 或只调 Pier Redeploy。
2. `8443` 保持收窄；观察 7 天。
3. 7 天后视情况清理旧 gateway/acme 镜像。
4. 另一次提交更新 README 生产入口。

---

## 8. 回滚

快照是最后手段。应用层：

```bash
sudo systemctl stop pier
# 停掉 Pier 拉起的 Traefik，释放 80/443（以实际容器名为准）
docker ps --filter name=traefik

cd /opt/andy-blog
make prod
```

前提：`andy-blog_mongo-data` / `andy-blog_redis-data` 未被删除；`nginx/certs` 仍在。DNS 不用改。

回滚后 CDN 仍用切流前的证书，直到独立续期或重新拉起 `acme`。

---

## 9. 风险

| 风险 | 影响 | 处理 |
| --- | --- | --- |
| 2 GB 内存 | 切流或 pull 时 OOM | 禁 Railpack；整栈停旧；保留 swap |
| HTTP-01 失败 | HTTPS 中断；HSTS 无法降级 | 回切 Nginx；不手改 Traefik |
| LE 频率限制 | 当天无法再签 | 回切，改日再试 |
| Pier 覆盖 traefik.yml | 手改 DNS-01 丢失 | 不把手改当方案 |
| 卷名被新建 | 空库 | YAML 写死 external + 现网卷名 |
| 新旧双栈 | 打满内存 / 写坏卷 | 必须 `prod-down` 后再 up |
| 拆 acme 后 CDN 证书过期 | `static.jiawen.live` HTTPS 挂 | **CDN 证书已过期**；先修续期，再拆容器 |
| 安全组全端口开放 | Pier `:8443` 装完即对公网 | 安装前先改 SG，不能只「再加一条白名单」 |
| 同 zone 的 `tzj-*` | 误绑进 Traefik / 误签证书 | Pier 只绑 blog/www/api/admin |
| 无快照 | 回滚只剩应用层 | 窗口前至少一份系统盘快照 |
| 丢失 `client_max_body_size 20m` | 上传失败 | Traefik buffering 中间件 |
| Actions 仍跑旧脚本 | 两套编排打架 | 切流当天改 CD |
| 面板 8443 暴露 | 被扫 | 安全组收窄 |
| Pier 项目很新（约 13 star） | 行为变、文档不全 | 业务仍是自己的镜像；随时回切 Nginx |
| 国内拉 GitHub | 安装失败 | 本机下载 + scp |
| 丢 HTTP/3 | QUIC 协商短暂失败 | 可接受 |

---

## 10. 待确认事项

1. **SSH**：本机用哪把钥匙、哪个用户登录 **`182.92.104.98`**（`id_ed25519` / 另给；`tzj_deploy` 更像另一套站）。
2. **维护窗口**：接受 15–30 分钟整站不可用（含 Mongo）。2 GB 做不到无中断蓝绿。
3. **发布**：过渡期继续 GitHub Actions SSH，还是切流后立刻改 Pier Redeploy。
4. **面板**：先 `IP:8443` 还是一并做 `pier.jiawen.live`。
5. **安装窗口**：Pier 源码在启动时就会 `deploy_traefik` 并绑定宿主机 `80/443`。**不能**在旧 Nginx 还在时先装 Pier。安装与切流必须同一维护窗口。
6. **先修 CDN 还是先迁 Pier**：建议先修 `static.jiawen.live` 证书，再开维护窗口。
7. **安全组**：是否同意在装 Pier 前改成最小端口集（会动 22 的来源 IP）。

---

## 11. 验收标准

切流成功当且仅当全部满足：

- `https://jiawen.live`、`www`、`api`、`admin` 证书为 Let's Encrypt，浏览器无告警。
- 前台可浏览文章；后台可登录；上传图片走 OSS 且前台能显示。
- AI 浮窗 / webhook 仍可用（若生产已启用）。
- `https://static.jiawen.live` 证书未过期，续期路径可独立跑通（允许先演练、未到续期日）。
- `docker volume inspect andy-blog_mongo-data` 仍被新 mongo 使用，不是新空卷。
- `8443` 非全网开放。
- 回滚演练过一次命令（至少在文档里由操作者口头复述，窗口内准备好）。

---

## 12. 参考

- Pier 仓库：<https://github.com/joveptesg/Pier>
- 安装：<https://github.com/joveptesg/Pier/blob/main/INSTALL.md>
- Compose 模板说明：<https://pier.team/services/docker-compose>
- Traefik 静态配置生成：`crates/pier-core/src/proxy/config.rs`（仅 HTTP-01）
- 本仓库：`README.zh-CN.md`、`docker-compose.yml`、`docker-compose.prod.yml`、`scripts/deploy.sh`、`acme/issue.sh`
