# andy-blog-deploy

[English](./README.md) | [简体中文](./README.zh-CN.md)

**andy-blog** 全栈个人博客（[jiawen.live](https://jiawen.live)）的 Docker Compose 部署编排仓库。本地仍用 Compose 一键拉起；生产入口是 Pier Traefik，日常发布由 GitHub Actions 滚动更新镜像。

## 架构

```mermaid
flowchart TD
    Internet(["公网"]) --> TR

    subgraph Server ["单台服务器（Pier + Docker）"]
        TR["pier-traefik · Let's Encrypt HTTP-01"]
        TR --> |"jiawen.live / www"| WEB["web · andy-blog-nuxt (SSR)"]
        TR --> |"admin.jiawen.live"| ADMIN["admin · andy-blog-admin (SPA)"]
        TR --> |"api.jiawen.live"| API["api · andy-blog-koa (NestJS)"]
        WEB --> |"SSR 容器内取数"| API
        ADMIN --> API
        API --> MONGO[("mongo 7")]
        API --> REDIS[("redis 7")]
        ACME["acme timer · DNS-01"] -.-> |"只推 CDN 证"| CDN["static.jiawen.live"]
    end

    API -.-> |"内容变更 Webhook (HMAC)"| AI(["andy-blog-ai · Cloudflare Workers"])
```

### 服务一览

| 服务      | 镜像 / 来源                            | 职责                                                       |
| --------- | -------------------------------------- | ---------------------------------------------------------- |
| `pier-traefik` | Pier 安装的 Traefik                  | 生产入口。按域名反代、Let's Encrypt HTTP-01。旧 `gateway` 仅作回滚。 |
| `web`     | [`andy-blog-nuxt`](https://github.com/zzlw/andy-blog-nuxt)   | 博客前台 SSR（Nuxt）。              |
| `admin`   | [`andy-blog-admin`](https://github.com/zzlw/andy-blog-admin) | 后台管理 SPA（React + Ant Design）。|
| `api`     | [`andy-blog-koa`](https://github.com/zzlw/andy-blog-koa)     | REST API（NestJS）— CMS 核心。      |
| `mongo`   | `mongo:7`                              | 主数据库。                                                 |
| `redis`   | `redis:7-alpine`                       | 缓存 / 会话。                                              |
| `acme`    | `./acme`（acme.sh + 阿里云 CLI）       | **只给 CDN** 做 DNS‑01 续期（systemd timer）。源站证由 Traefik 签发。 |
| `minio`   | `minio/minio`（仅开发）                | 本地 S3 兼容对象存储（开发环境替代阿里云 OSS / R2）。      |

可选的边缘 AI 服务 [`andy-blog-ai`](https://github.com/zzlw/andy-blog-ai) **不在**本 compose 栈内（它跑在 Cloudflare Workers 上），API 只是向它推送内容变更的 webhook。

## Compose 分层

拓扑拆成三个文件，让同一套定义同时服务开发与生产：

| 文件                          | 何时生效              | 作用                                                          |
| ----------------------------- | --------------------- | ------------------------------------------------------------- |
| `docker-compose.yml`          | 始终                  | 环境无关的服务拓扑。                                          |
| `docker-compose.override.yml` | 开发（自动叠加）      | 源码 bind‑mount + 热重载、本地 MinIO、暴露调试端口。          |
| `docker-compose.prod.yml`     | 生产（显式 `-f` 指定）| `restart: always`、`gateway` 与 `acme` 服务、不直接暴露端口。  |

## 配置

环境变量同样分层，**密钥永不进仓库**：

| 文件                            | 是否提交 | 内容                                                       |
| ------------------------------- | -------- | ---------------------------------------------------------- |
| `.env.development`              | ✅ 是     | 非敏感开发默认值（指向本地 MinIO 容器）。                  |
| `.env.production`               | ✅ 是     | 非敏感生产配置（域名、镜像仓库、站点信息）。              |
| `.env.production.local`         | ❌ 否（已忽略） | 全部密钥 — 只存服务器，`chmod 600`。               |
| `.env.production.local.example` | ✅ 是     | 上面那个文件的模板。                                       |

仓库配有 `gitleaks` GitHub Action，对每次 push/PR（含完整历史）扫描，防止凭证被提交。

## 快速开始（本地开发）

需要 Docker + Docker Compose。应用仓库（`andy-blog-koa`、`andy-blog-nuxt`、`andy-blog-admin`）需与本仓库平级放置（`../andy-blog-*`），因为开发态从本地源码构建。

```bash
make dev          # 构建并热重载启动全部服务
make dev-build    # 同上，但在依赖变更后刷新镜像/匿名卷
make down         # 停止
make clean        # 停止并删除数据卷（mongo / redis / minio）
```

开发端口：

| 地址                       | 服务                |
| ------------------------- | ------------------- |
| http://localhost:3001     | 博客前台（web）      |
| http://localhost:3002     | 后台管理            |
| http://localhost:3000     | API                 |
| http://localhost:9001     | MinIO 控制台        |
| `localhost:27017 / :16379`| MongoDB / Redis     |

## 生产部署

### 服务器初始化（一次性）

```bash
git clone https://github.com/zzlw/andy-blog-deploy /opt/andy-blog
cd /opt/andy-blog
cp .env.production.local.example .env.production.local   # 填入真实密钥
chmod 600 .env.production.local
docker login <你的镜像仓库>

# 生产编排是 docker-compose.pier.yml，由 Pier 管入口。
# 不要对旧的 docker-compose.prod.yml 做 up（会和 Traefik 抢 80/443）。
make prod
```

源站 HTTPS 由 Pier Traefik（HTTP-01）自动续。CDN `static.jiawen.live` 仍用 acme.sh DNS-01，由宿主机 `andy-blog-acme-cdn.timer` 每天检查。

不要在 Pier 面板对 `andy-blog` 点整栈 Redeploy / From Git。日常发布走下面的 CI。

### 日常部署（CI/CD）

应用仓库在各自 CI 里构建并推送镜像，随后向本仓库发起 `repository_dispatch`。[`Deploy`](.github/workflows/deploy.yml) 工作流 SSH 到服务器、执行 `git pull`，再通过 [`scripts/deploy.sh`](scripts/deploy.sh) 做滚动更新：

```bash
sh scripts/deploy.sh api sha-1a2b3c4   # 部署指定版本（也用于回滚）
sh scripts/deploy.sh all latest        # 全部更新到 latest
```

部署的 tag 会持久化写入 `.env.production.local`，因此直接 `make prod` 始终保持在当前已部署版本。

部署工作流所需的 GitHub Secrets：`SSH_HOST`、`SSH_USER`、`SSH_KEY`。

## HTTPS / 证书

源站（`jiawen.live` / `www` / `api` / `admin` / `pier`）由 Traefik Let's Encrypt **HTTP-01** 续期。

CDN `static.jiawen.live` 仍走 [acme.sh](https://github.com/acmesh-official/acme.sh) **阿里云 DNS‑01** 泛域名证书，续期后只推 CDN，不再安装到 Nginx。

```bash
make cert-issue        # 首次签发 CDN 用泛域名证
make cert-renew        # 跑一遍 acme.sh --cron
make cert-deploy-cdn   # 把当前证书重新推送到 CDN 域名
```

## Make 命令

| 命令              | 说明                                              |
| ----------------- | ------------------------------------------------- |
| `dev` / `dev-build` | 启动开发栈（热重载）。                          |
| `rebuild`         | 重建容器 + 无缓存重建（保留数据卷）。            |
| `reset`           | ⚠️ 重建**并清空**所有数据卷。                     |
| `down` / `clean`  | 停止 / 停止并删除数据卷。                         |
| `prod` / `prod-down` | 启动 / 停止 Pier 生产栈（`docker-compose.pier.yml`）。 |
| `prod-reload`     | 回滚到 Nginx 后才有意义；当前入口是 Traefik。   |
| `cert-*`          | 证书签发 / 续期 / 推送 CDN。                      |
| `logs`            | 跟踪全部服务日志。                                |

## 关联仓库

- [andy-blog-koa](https://github.com/zzlw/andy-blog-koa) — REST API（NestJS），CMS 核心
- [andy-blog-nuxt](https://github.com/zzlw/andy-blog-nuxt) — 博客前台 SSR
- [andy-blog-admin](https://github.com/zzlw/andy-blog-admin) — 后台管理 SPA
- [andy-blog-ai](https://github.com/zzlw/andy-blog-ai) — 边缘 AI 助手（Cloudflare Workers，RAG + Agent）

## 许可证

[MIT](./LICENSE) © Gavin
