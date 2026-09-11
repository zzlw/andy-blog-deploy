# 本地一键启动 / 生产部署入口
.PHONY: dev dev-build rebuild reset down prod prod-down \
        cert-issue cert-deploy-cdn cert-renew logs clean

# 生产：Pier 栈。CDN 续期用独立 acme compose，不要和业务栈混 up。
PROD := docker compose -f docker-compose.pier.yml \
        --env-file .env.production --env-file .env.production.local
ACME := docker compose -f docker-compose.acme.yml \
        --env-file .env.production --env-file .env.production.local

# 关闭 BuildKit，改用传统构建器。
# 原因：BuildKit 构建前需在线拉取 docker/dockerfile:1 前端镜像，
# 部分镜像加速源（如阿里云）对该镜像返回 403，导致 `make dev` 直接失败。
# 本项目 Dockerfile 未使用 BuildKit 专属语法，传统构建器完全等价。
DEV_BUILD := DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0

# 本地开发：一键启动全部服务（热重载）
dev:
	$(DEV_BUILD) docker compose --env-file .env.development up --build --remove-orphans

# 依赖（package.json）变更后使用：重建镜像并刷新 node_modules 匿名卷
dev-build:
	$(DEV_BUILD) docker compose --env-file .env.development up --build --renew-anon-volumes --remove-orphans

# 彻底重建：删除所有容器 → 无缓存重建全部镜像 → 刷新匿名卷并启动
# 保留数据卷（mongo/redis/minio 数据不丢）；如需连数据一起清空请先 make clean
rebuild:
	docker compose --env-file .env.development down --remove-orphans
	$(DEV_BUILD) docker compose --env-file .env.development build --no-cache
	$(DEV_BUILD) docker compose --env-file .env.development up --renew-anon-volumes --remove-orphans

# 危险操作：彻底重置 = 连数据卷一起删除 → 无缓存重建全部镜像 → 启动
# 会清空 mongo/redis/minio 所有数据，相当于全新环境
reset:
	docker compose --env-file .env.development down -v --remove-orphans
	$(DEV_BUILD) docker compose --env-file .env.development build --no-cache
	$(DEV_BUILD) docker compose --env-file .env.development up --renew-anon-volumes --remove-orphans

down:
	docker compose --env-file .env.development down --remove-orphans

# 生产部署（服务器上执行）：业务镜像从镜像仓库拉取（CI 构建）
# 日常更新走 CI/CD（scripts/deploy.sh）。acme 只负责 CDN，单独拉起。
prod:
	$(PROD) pull api web admin
	$(PROD) up -d

prod-down:
	$(PROD) down

# ===================== CDN 证书（源站由 Traefik HTTP-01 管理）=====================
cert-issue:
	$(ACME) run --rm --no-deps acme sh /scripts/issue.sh

# 手动把当前证书重新推送到 CDN 加速域名（正常情况续期后会自动执行）
cert-deploy-cdn:
	$(ACME) run --rm --no-deps acme sh /scripts/deploy-cdn.sh

# 手动强制续期（正常情况不需要，daemon 会自动续）
cert-renew:
	$(ACME) run --rm --no-deps acme acme.sh --cron

logs:
	docker compose logs -f --tail=100

# 危险操作：清空容器与数据卷（含数据库数据）
clean:
	docker compose --env-file .env.development down -v
