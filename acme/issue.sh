#!/bin/sh
# =============================================================
# 首次签发证书（在 acme 容器内执行）：make cert-issue
# - DNS-01 验证（阿里云 DNS API）：static.jiawen.live 指向 OSS，
#   HTTP 验证打不到本机，DNS 验证不受域名解析指向限制，且支持泛域名
# - 签一张泛域名证书：BASE_DOMAIN + *.BASE_DOMAIN，
#   覆盖 blog/www/api/admin/static 全部子域
# - RSA-2048：阿里云证书上传对 RSA 兼容性最好
# - 自动化闭环：
#   * --install-cert 配置被记录 → 每次续期后自动重装到 /certs/live（nginx 用）
#   * --renew-hook 被记录   → 每次续期后自动把新证书推送到 CDN 加速域名
# =============================================================
set -e

: "${ACME_EMAIL:?请在 .env.production 中配置 ACME_EMAIL}"
: "${BASE_DOMAIN:?请在 .env.production 中配置 BASE_DOMAIN（如 jiawen.live）}"
: "${Ali_Key:?请在 .env.production.local 中配置 ALI_KEY（RAM AccessKey，需阿里云 DNS 权限）}"
: "${Ali_Secret:?请在 .env.production.local 中配置 ALI_SECRET}"

echo "==> 注册 ACME 账户（Let's Encrypt）"
acme.sh --register-account -m "$ACME_EMAIL" --server letsencrypt

echo "==> DNS-01 签发泛域名证书：$BASE_DOMAIN + *.$BASE_DOMAIN"
acme.sh --issue --server letsencrypt --keylength 2048 \
  --dns dns_ali \
  -d "$BASE_DOMAIN" -d "*.$BASE_DOMAIN" \
  --renew-hook "sh /scripts/deploy-cdn.sh"

echo "==> 安装证书到网关目录 /certs/live（续期后自动重装）"
mkdir -p /certs/live
acme.sh --install-cert -d "$BASE_DOMAIN" \
  --fullchain-file /certs/live/fullchain.pem \
  --key-file /certs/live/privkey.pem

echo "==> 推送证书到 CDN 加速域名 $STATIC_DOMAIN"
sh /scripts/deploy-cdn.sh

echo "==> 完成。执行 make prod-reload 让网关立即生效（否则最迟 6 小时内自动 reload）"
