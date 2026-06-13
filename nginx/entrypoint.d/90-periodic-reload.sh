#!/bin/sh
# 周期 reload：acme.sh 自动续期写入新证书后，无需人工干预即可生效。
# 放在 /docker-entrypoint.d/ 由官方 entrypoint 执行，不覆盖 command，
# 否则会跳过 20-envsubst-on-templates.sh 的模板渲染。
(while :; do sleep 6h; nginx -s reload 2>/dev/null || true; done) &
