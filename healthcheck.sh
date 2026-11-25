#!/usr/bin/env bash
# 容器健康检查。
#
# 检查范围：
# - Supervisor 管理的六个服务都处于 RUNNING；
# - sshd、PostgreSQL、OpenCode、DSH、DSH 代理和 Kimi 的实际监听端口；
# - PostgreSQL 可以接受连接；
# - OpenCode 的认证接口正常；
# - DSH 已捕获真实 token，代理可以完成登录跳转；
# - Kimi Web 能返回非 5xx 响应。
#
# 该脚本只做只读探测，不修改任何服务状态。任何一项失败都会以非零码退出，
# 由 Docker 将容器标记为 unhealthy；Docker 不会因此自动重启容器。

set -Eeuo pipefail

fail() {
    printf 'unhealthy: %s\n' "$*" >&2
    exit 1
}

# 1. Supervisor 状态。supervisorctl 使用容器内的 Unix Socket。
if ! supervisor_output="$(timeout 3 supervisorctl \
    -c /etc/supervisor/supervisord.conf status 2>&1)"; then
    fail "无法读取 Supervisor 状态：$supervisor_output"
fi

for program in sshd postgres opencode dsh dsh-proxy kimi; do
    program_line="$(grep -E "^${program}[[:space:]]" <<< "$supervisor_output" || true)"
    if [[ -z "$program_line" ]]; then
        fail "Supervisor 中找不到服务：$program"
    fi
    if [[ ! "$program_line" =~ [[:space:]]RUNNING[[:space:]] ]]; then
        fail "服务 $program 未处于 RUNNING：$program_line"
    fi
done

# 2. 监听端口。仅连接本地回环地址，不发送业务数据。
check_port() {
    local name="$1"
    local port="$2"
    if ! timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
        fail "$name 未监听 127.0.0.1:${port}"
    fi
}

check_port "sshd" 22
check_port "PostgreSQL" 5432
check_port "OpenCode" 49374
check_port "DSH" 3081
check_port "DSH 代理" 3080
check_port "Kimi Web" 58627

# 3. sshd 必须返回 SSH 协议 banner，而不仅是端口可连接。
ssh_banner="$(timeout 3 bash -c '
    exec 3<>/dev/tcp/127.0.0.1/22
    IFS= read -r -t 2 line <&3
    printf "%s" "$line"
' 2>/dev/null || true)"
if [[ "$ssh_banner" != SSH-* ]]; then
    fail "sshd 没有返回有效的 SSH banner"
fi

# 4. PostgreSQL 就绪检查。pg_isready 只判断是否接受连接，不进行密码认证。
pg_isready_bin="/usr/lib/postgresql/16/bin/pg_isready"
if [[ ! -x "$pg_isready_bin" ]]; then
    fail "找不到 pg_isready：$pg_isready_bin"
fi
if ! timeout 5 "$pg_isready_bin" \
    -h 127.0.0.1 \
    -p 5432 \
    -U "${POSTGRES_USER:-postgres}" \
    -d postgres \
    -t 3 >/dev/null 2>&1; then
    fail "PostgreSQL 未就绪"
fi

# 5. HTTP 状态检查。只要求服务能返回符合预期的 HTTP 状态码。
check_http_status() {
    local name="$1"
    local url="$2"
    local allowed_pattern="$3"
    shift 3

    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
        --max-time 5 "$@" "$url" 2>/dev/null || true)"

    if [[ ! "$code" =~ $allowed_pattern ]]; then
        fail "$name 返回了异常 HTTP 状态：${code:-000}"
    fi
}

# OpenCode 使用 Basic Auth；2xx 才代表接口可用。
check_http_status "OpenCode" \
    "http://127.0.0.1:49374/api/info" \
    '^2[0-9][0-9]$' \
    -u "opencode:${OPENCODE_PASSWORD:-}"

# DSH 启动后会生成真实 token；文件为空说明代理无法完成固定 token 转换。
if [[ ! -s /run/dsh-web-token ]]; then
    fail "DSH 尚未生成真实 token"
fi

# 一次带固定 token 的请求会经过代理转换，状态码不应是 5xx。
check_http_status "DSH 代理" \
    "http://127.0.0.1:3080/" \
    '^[123][0-9][0-9]$' \
    --get \
    --data-urlencode "token=${DSH_WEB_TOKEN:-}"

# Kimi 根路径可能返回登录页或重定向，1xx-4xx 都表示 Web 服务有响应。
check_http_status "Kimi Web" \
    "http://127.0.0.1:58627/" \
    '^[1-4][0-9][0-9]$'

printf 'healthy: all services are reachable\n'
