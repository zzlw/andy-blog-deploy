#!/bin/sh
# =============================================================
# 服务器端部署脚本：更新镜像 tag → pull → 滚动更新
# 用法：sh scripts/deploy.sh <api|web|admin|all> <tag>
#   sh scripts/deploy.sh api sha-1a2b3c4   # 部署指定版本（也用于回滚）
#   sh scripts/deploy.sh all latest        # 全量更新到最新
# tag 持久化写入 .env.production.local（git 忽略）：避免弄脏仓库内的
# .env.production 导致 git pull 冲突，且手动 make prod 也保持在已部署版本
# =============================================================
set -e

SERVICE=$1
TAG=${2:-latest}
ENV_FILE=.env.production
LOCAL_ENV_FILE=.env.production.local
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file $ENV_FILE --env-file $LOCAL_ENV_FILE"

[ -f "$ENV_FILE" ] || { echo "缺少 $ENV_FILE（应随仓库提交），请检查代码目录"; exit 1; }
[ -f "$LOCAL_ENV_FILE" ] || { echo "缺少 $LOCAL_ENV_FILE，请先 cp .env.production.local.example $LOCAL_ENV_FILE 并填写密钥"; exit 1; }

case "$SERVICE" in
  api|web|admin) SERVICES=$SERVICE ;;
  all) SERVICES="api web admin" ;;
  *) echo "用法: deploy.sh <api|web|admin|all> <tag>"; exit 1 ;;
esac

# 把 tag 写进 .env.production.local（API_TAG / WEB_TAG / ADMIN_TAG），不存在则追加
for s in $SERVICES; do
  VAR=$(echo "$s" | tr '[:lower:]' '[:upper:]')_TAG
  if grep -q "^${VAR}=" "$LOCAL_ENV_FILE"; then
    sed -i.bak "s|^${VAR}=.*|${VAR}=${TAG}|" "$LOCAL_ENV_FILE" && rm -f "$LOCAL_ENV_FILE.bak"
  else
    printf '%s=%s\n' "$VAR" "$TAG" >> "$LOCAL_ENV_FILE"
  fi
done

echo "==> 拉取镜像：$SERVICES ($TAG)"
$COMPOSE pull $SERVICES

echo "==> 滚动更新：$SERVICES"
# --no-deps：只更新目标服务，不触碰 mongo/redis/gateway 等依赖
$COMPOSE up -d --no-deps $SERVICES

echo "==> 清理悬空旧镜像"
docker image prune -f >/dev/null

echo "==> 部署完成：$SERVICES -> $TAG"
$COMPOSE ps $SERVICES
