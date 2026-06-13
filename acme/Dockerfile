# acme.sh 官方镜像 + 阿里云 CLI（用于把证书自动推送到 CDN 加速域名）
FROM neilpang/acme.sh:3.1.0

# aliyun CLI 静态二进制（纯 Go，alpine 可直接运行），按构建平台选择架构
ARG TARGETARCH
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      arm64) CLI_URL="https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-arm64.tgz" ;; \
      *)     CLI_URL="https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz" ;; \
    esac; \
    curl -fsSL "$CLI_URL" | tar -xz -C /usr/local/bin aliyun; \
    aliyun version
