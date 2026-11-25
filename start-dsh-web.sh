#!/usr/bin/env bash
# DeepSeek Harness Web 启动包装脚本。
# Supervisor 在容器启动后调用此脚本，由它启动 dsh 本体。
#
# 公开访问结构：
#   浏览器任意 IP/域名:2224（宿主机端口）
#     -> Docker 映射到容器 3080
#     -> dsh-proxy 监听容器 0.0.0.0:3080
#     -> 改写 Host、转换固定 token 后转发到 dsh 127.0.0.1:3081
#
# dsh 拒绝监听 0.0.0.0，并且每次启动都会生成一个随机临时 token。
# 本脚本把随机 token 从启动日志中捕获到 /run/dsh-web-token，
# 再由 dsh-proxy 把 Compose 中配置的固定 DSH_WEB_TOKEN 自动转换成该随机 token。
# 因此浏览器始终使用固定的 ?token=<DSH_WEB_TOKEN> 登录，不需要每次查看日志。

set -Eeuo pipefail

# Compose 中配置的固定登录 token。
# 浏览器登录地址为：
#   http://任意地址:2224/?token=<DSH_WEB_TOKEN>
: "${DSH_WEB_TOKEN:?DSH_WEB_TOKEN 环境变量不能为空}"

# DSH_PUBLIC_URL 只影响 dsh 启动日志中打印的登录 URL，不控制访问地址。
# 宿主机端口为 2224，容器内部的 dsh-proxy 仍监听 3080。
export DSH_PUBLIC_URL="${DSH_PUBLIC_URL:-http://localhost:2224}"

case "$DSH_PUBLIC_URL" in
    http://*|https://*)
        ;;
    *)
        echo "错误：DSH_PUBLIC_URL 必须以 http:// 或 https:// 开头。" >&2
        exit 1
        ;;
esac

# 所有 DeepSeek Harness 数据放在 root 的持久化目录中。
export DSH_HOME="${DSH_HOME:-/root/.dsh}"
mkdir -p "$DSH_HOME"

# DSH_WEB_TOKEN 是用户固定 token；DSH_TOKEN_FILE 保存 dsh 本次进程的真实随机 token。
# DSH_LOG_FIFO 用于在转发日志的同时捕获真实 token。
# 三个变量都允许测试时通过环境覆盖，默认值与代理脚本保持一致。
token_file="${DSH_TOKEN_FILE:-/run/dsh-web-token}"
log_fifo="${DSH_LOG_FIFO:-/run/dsh-web-log.fifo}"
dsh_bin="${DSH_BIN:-/usr/local/bin/dsh}"

# 每次启动先删除旧 token，避免 dsh 尚未启动时代理误用上次进程的 token。
rm -f "$token_file" "$log_fifo"

# 创建命名管道，让 dsh 输出可以被逐行读取。
mkdir -p "$(dirname "$token_file")" "$(dirname "$log_fifo")"
mkfifo -m 600 "$log_fifo"

# token 文件只允许 root 读取。
umask 077

# 后台日志处理器：
# - 把 dsh 的每行日志继续输出给 Supervisor/Docker；
# - 从包含 token=... 的启动日志中提取 dsh 真实随机 token；
# - 写入 /run/dsh-web-token，供 dsh-proxy 在登录请求时转换使用。
parse_dsh_logs() {
    local line actual_token
    while IFS= read -r line; do
        if [[ "$line" =~ token=([A-Za-z0-9_=-]+) ]]; then
            actual_token="${BASH_REMATCH[1]}"
            printf '%s\n' "$actual_token" > "$token_file"
        fi
        printf '%s\n' "$line"
    done < "$log_fifo"
}

# 先启动读取端，避免 dsh 写日志时因为管道没有读者而阻塞。
parse_dsh_logs &
parser_pid=$!

# 启动 dsh。stdout 和 stderr 都进入命名管道，
# 由上面的处理器同时完成日志转发和 token 捕获。
"$dsh_bin" web \
    --no-open \
    --host 127.0.0.1 \
    --port 3081 \
    --public-url "$DSH_PUBLIC_URL" \
    >"$log_fifo" 2>&1 &
dsh_pid=$!

# 等待 dsh 退出，并保留它的退出码给 Supervisor 判断是否需要重启。
set +e
wait "$dsh_pid"
dsh_status=$?
set -e

# dsh 退出后关闭并清理日志处理进程。
# 不无限等待 parser，避免 dsh 创建的子进程仍持有管道导致包装脚本卡住。
kill "$parser_pid" 2>/dev/null || true
wait "$parser_pid" 2>/dev/null || true
rm -f "$log_fifo"

# token 是临时内存凭证，dsh 退出后立即删除，防止代理使用过期 token。
rm -f "$token_file"

exit "$dsh_status"
