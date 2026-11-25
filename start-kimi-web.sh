#!/usr/bin/env bash
# Kimi Code Web 启动包装脚本。
#
# Kimi 使用持久化的 server.token 作为 bearer token。
# 本脚本在启动前把 Compose 中配置的 KIMI_CODE_TOKEN 写入：
#   $KIMI_CODE_HOME/server.token
# 因此每次容器启动都使用固定 token，浏览器可以直接访问：
#   http://任意地址:2226/#token=<KIMI_CODE_TOKEN>
# 其中 2226 是宿主机端口，容器内部仍监听 58627。
#
# token 文件位于持久化目录中，容器重建后仍然保留，
# 但每次启动仍会按 Compose 配置重新写入，确保 Compose 是唯一配置来源。

set -Eeuo pipefail

# Compose 中配置的固定 Kimi Web token。
: "${KIMI_CODE_TOKEN:?KIMI_CODE_TOKEN 环境变量不能为空}"

# Kimi 的配置、会话、登录凭据和 server.token 都放在这个目录。
export KIMI_CODE_HOME="${KIMI_CODE_HOME:-/root/.kimi-code}"
mkdir -p "$KIMI_CODE_HOME"

# Kimi 只接受权限足够私密的 token 文件。
# umask 077 加上后面的 chmod 600，确保只有 root 可读。
umask 077
printf '%s\n' "$KIMI_CODE_TOKEN" > "$KIMI_CODE_HOME/server.token"
chmod 600 "$KIMI_CODE_HOME/server.token"

# token 由 Docker Compose 固定配置。
# 在容器内手动执行 kimi web rotate-token 会在下次重启时被这里的配置覆盖；
# 需要更换 token 时，直接修改 docker-compose.yaml 的 KIMI_CODE_TOKEN。

# 监听所有容器网卡；Docker 端口映射负责宿主机 IPv4/IPv6 访问。
# --no-open：容器内没有桌面浏览器。
# KIMI_CODE_DISABLE_HOST_CHECK=1 由 Compose 传入，允许任意 IP/域名/IPv6。
# KIMI_CODE_PASSWORD 也由 Compose 传入，与 bearer token 一起保护访问。
exec "${KIMI_BIN:-/usr/local/bin/kimi}" web \
    --host 0.0.0.0 \
    --port 58627 \
    --no-open
