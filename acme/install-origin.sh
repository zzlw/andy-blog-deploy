#!/bin/sh
# 把 acme.sh 刚装到 /certs/live 的泛域名证复制到 Pier Traefik 已挂载的目录。
# Traefik 文件提供者会监视证书文件，复制后源站自动换上新证。
set -e

: "${PIER_CERT_DIR:=/pier-certs}"

[ -f /certs/live/fullchain.pem ] || { echo "缺少 /certs/live/fullchain.pem"; exit 1; }
[ -f /certs/live/privkey.pem ] || { echo "缺少 /certs/live/privkey.pem"; exit 1; }

mkdir -p "$PIER_CERT_DIR"
cp /certs/live/fullchain.pem "$PIER_CERT_DIR/fullchain.pem"
cp /certs/live/privkey.pem "$PIER_CERT_DIR/privkey.pem"
chmod 644 "$PIER_CERT_DIR/fullchain.pem"
chmod 640 "$PIER_CERT_DIR/privkey.pem"

echo "==> 源站证书已写入 $PIER_CERT_DIR"
