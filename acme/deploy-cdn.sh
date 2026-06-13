#!/bin/sh
# =============================================================
# 把当前证书推送到阿里云 CDN 加速域名（替换控制台手动上传）
# - 首次由 issue.sh 调用；之后作为 acme.sh 的 renew-hook 在每次续期后自动执行
# - 直接读 acme.sh 内部证书目录（而非 /certs/live），保证拿到的一定是最新证书
# - 调用 CDN API SetCdnDomainSSLCertificate（CertType=upload），HTTPS 在
#   CDN 边缘节点终结，证书必须配在 CDN 加速域名上（OSS 源站绑定无效）
# - 所需 RAM 权限：cdn:SetCdnDomainSSLCertificate（或 AliyunCDNFullAccess）
# =============================================================
set -e

: "${BASE_DOMAIN:?缺少 BASE_DOMAIN}"
: "${STATIC_DOMAIN:?缺少 STATIC_DOMAIN（如 static.jiawen.live）}"
: "${Ali_Key:?缺少 ALI_KEY}"
: "${Ali_Secret:?缺少 ALI_SECRET}"

# acme.sh 证书目录：RSA 在 <domain>/，ECC 在 <domain>_ecc/
CERT_HOME="${LE_CONFIG_HOME:-/acme.sh}"
CERT_DIR="$CERT_HOME/$BASE_DOMAIN"
[ -f "$CERT_DIR/fullchain.cer" ] || CERT_DIR="$CERT_HOME/${BASE_DOMAIN}_ecc"
[ -f "$CERT_DIR/fullchain.cer" ] || { echo "未找到证书，请先执行 make cert-issue"; exit 1; }

# 证书名带时间戳，避免与历史证书重名（CertNameAlreadyExists）
CERT_NAME="acme-${BASE_DOMAIN}-$(date +%Y%m%d%H%M%S)"

echo "==> 推送证书到 CDN 加速域名 ${STATIC_DOMAIN}（CertName: ${CERT_NAME}）"
aliyun cdn SetCdnDomainSSLCertificate \
  --access-key-id "$Ali_Key" \
  --access-key-secret "$Ali_Secret" \
  --region cn-hangzhou \
  --DomainName "$STATIC_DOMAIN" \
  --CertName "$CERT_NAME" \
  --CertType upload \
  --SSLProtocol on \
  --SSLPub "$(cat "$CERT_DIR/fullchain.cer")" \
  --SSLPri "$(cat "$CERT_DIR/$BASE_DOMAIN.key")"

echo "==> CDN 证书配置完成：https://${STATIC_DOMAIN} 可用（边缘节点生效约需数分钟）"
