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
# 切流后入口是 Pier Traefik。禁止再打带 gateway 的旧 compose，否则会和 80/443 抢端口。
PIER_COMPOSE=docker-compose.pier.yml
if [ ! -f "$PIER_COMPOSE" ]; then
  echo "缺少 $PIER_COMPOSE，拒绝部署以免拉起旧 Nginx 网关"
  exit 1
fi
COMPOSE="docker compose -f $PIER_COMPOSE --env-file $ENV_FILE --env-file $LOCAL_ENV_FILE"

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
# --no-deps：只更新目标服务，不触碰 mongo/redis
$COMPOSE up -d --no-deps $SERVICES

# Pier 面板里的栈 YAML 已展开成固定镜像 tag，同步一下避免下次从面板 Redeploy 打回旧版本
PIER_STACK_YML=/opt/pier/data/stacks/andy-blog/docker-compose.yml
if [ -f "$PIER_STACK_YML" ]; then
  for s in $SERVICES; do
    sed -i "s|andy-blog-${s}:[^[:space:]]*|andy-blog-${s}:${TAG}|" "$PIER_STACK_YML"
  done
fi

echo "==> 清理悬空旧镜像"
docker image prune -f >/dev/null

echo "==> 部署完成：$SERVICES -> $TAG"
$COMPOSE ps $SERVICES
