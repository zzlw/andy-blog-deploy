# 本地一键启动 / 生产部署入口
.PHONY: dev dev-build rebuild reset down prod prod-down prod-reload \
        cert-selfsigned cert-issue cert-deploy-cdn cert-renew logs clean

# 生产 compose 命令（覆盖文件 + 生产环境变量）
# .env.production（仓库内，非敏感）+ .env.production.local（服务器本地，密钥/密码，后者覆盖前者）
PROD := docker compose -f docker-compose.yml -f docker-compose.prod.yml \
        --env-file .env.production --env-file .env.production.local

# 本地开发：一键启动全部服务（热重载）
dev:
	docker compose --env-file .env.development up --build --remove-orphans

# 依赖（package.json）变更后使用：重建镜像并刷新 node_modules 匿名卷
dev-build:
	docker compose --env-file .env.development up --build --renew-anon-volumes --remove-orphans

# 彻底重建：删除所有容器 → 无缓存重建全部镜像 → 刷新匿名卷并启动
# 保留数据卷（mongo/redis/minio 数据不丢）；如需连数据一起清空请先 make clean
rebuild:
	docker compose --env-file .env.development down --remove-orphans
	docker compose --env-file .env.development build --no-cache
	docker compose --env-file .env.development up --renew-anon-volumes --remove-orphans

# 危险操作：彻底重置 = 连数据卷一起删除 → 无缓存重建全部镜像 → 启动
# 会清空 mongo/redis/minio 所有数据，相当于全新环境
reset:
	docker compose --env-file .env.development down -v --remove-orphans
	docker compose --env-file .env.development build --no-cache
	docker compose --env-file .env.development up --renew-anon-volumes --remove-orphans

down:
	docker compose --env-file .env.development down --remove-orphans

# 生产部署（服务器上执行）：业务镜像从镜像仓库拉取（CI 构建），仅 acme 本地构建
# 日常更新走 CI/CD（scripts/deploy.sh），此命令用于首次部署/改动编排后全量应用
prod:
	$(PROD) pull api web admin
	$(PROD) up -d --build

prod-down:
	$(PROD) down

# 平滑重载网关配置/证书（不中断连接）
prod-reload:
	$(PROD) exec gateway nginx -s reload

# ===================== HTTPS 证书 =====================
# 首次部署流程：make cert-selfsigned → make prod → make cert-issue → make prod-reload
# 之后 acme 容器每天自动检查、到期前自动续期，网关每 6 小时自动 reload，无需人工干预

# 生成自签占位证书：解决「无证书时 nginx 443 起不来」的冷启动问题，
# 也可用于本地模拟生产环境调试 HTTPS/HTTP3
cert-selfsigned:
	mkdir -p nginx/certs/live
	docker run --rm -v $(CURDIR)/nginx/certs/live:/out alpine/openssl req -x509 -nodes \
		-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 365 \
		-keyout /out/privkey.pem -out /out/fullchain.pem \
		-subj "/CN=self-signed-placeholder"

# 首次签发真证书（Let's Encrypt，阿里云 DNS-01 验证，泛域名）
# 签发后自动：安装到网关证书目录 + 绑定到 OSS 自定义域名
cert-issue:
	$(PROD) exec acme sh /scripts/issue.sh

# 手动把当前证书重新推送到 CDN 加速域名（正常情况续期后会自动执行）
cert-deploy-cdn:
	$(PROD) exec acme sh /scripts/deploy-cdn.sh

# 手动强制续期（正常情况不需要，daemon 会自动续）
cert-renew:
	$(PROD) exec acme acme.sh --renew-all --force
	$(PROD) exec gateway nginx -s reload

logs:
	docker compose logs -f --tail=100

# 危险操作：清空容器与数据卷（含数据库数据）
clean:
	docker compose --env-file .env.development down -v
