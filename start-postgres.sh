#!/usr/bin/env bash
# PostgreSQL 16 初始化与前台启动脚本。
#
# 设计目标：
# 1. 数据目录挂载在宿主机，容器重建后数据库仍在。
# 2. 首次启动自动运行 initdb，不需要进入容器手动建库。
# 3. PostgreSQL 不允许以 root 运行，因此服务进程使用安装包创建的 postgres 用户。
# 4. 以前台方式运行 postgres，由 Supervisor 监控、转发日志和自动重启。
#
# 说明：
# - POSTGRES_USER 和 POSTGRES_PASSWORD 只在首次初始化数据目录时生效。
# - 数据目录已经存在后，修改 Compose 中的密码不会自动修改数据库密码。
#   需要进入容器执行 ALTER ROLE，或删除数据目录重新初始化。
# - 默认数据库是 postgres，默认端口 5432。

set -Eeuo pipefail

# Compose 必须提供数据库超级用户密码。
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD 环境变量不能为空}"

# 默认创建 postgres 超级用户；可以通过 Compose 覆盖。
postgres_user="${POSTGRES_USER:-postgres}"

# 数据目录使用独立的持久化挂载路径，避免依赖 Debian 默认 cluster 路径。
pgdata="${PGDATA:-/var/lib/postgresql/data}"

# PostgreSQL 16 的服务端和 initdb 位于版本化目录，不在默认 PATH 中。
pg_bin="/usr/lib/postgresql/16/bin"

# 安装 postgresql-16 后应自动创建 postgres 系统用户。
if ! id postgres >/dev/null 2>&1; then
    echo "错误：系统中不存在 postgres 用户，请检查 postgresql-16 安装。" >&2
    exit 1
fi

if [[ ! -x "$pg_bin/initdb" || ! -x "$pg_bin/postgres" ]]; then
    echo "错误：未找到 PostgreSQL 16 的 initdb/postgres 二进制。" >&2
    exit 1
fi

# 在每个启动周期内幂等地添加远程 HBA 规则。
#
# initdb 默认只在 pg_hba.conf 中生成 127.0.0.1/32 和 ::1/128 的 host 规则，
# 即使 listen_addresses=* 已经监听所有网卡，来自宿主机、Docker 网关、
# 局域网、域名解析地址或 IPv6 的连接仍会因为“no pg_hba.conf entry”被拒绝。
#
# 这里使用固定标记维护一个受管配置块：
# - 每次启动先删除旧块，避免重复追加；
# - 保留用户自行添加在块外的规则；
# - 远程连接必须使用 SCRAM 密码认证，不能匿名访问。
configure_pg_hba() {
    local hba_file="$pgdata/pg_hba.conf"
    local temporary_file

    if [[ ! -s "$hba_file" ]]; then
        echo "错误：PostgreSQL 配置文件不存在或为空：$hba_file" >&2
        exit 1
    fi

    # 把允许外部网段访问的规则放在同一 PG DATA 目录，
    # 避免 /tmp 与数据目录不在同一文件系统时 mv 跨盘。
    temporary_file="$(mktemp "$pgdata/.pg_hba.conf.XXXXXX")"

    # 删除上一次由本脚本管理的块，保留其他所有自定义规则。
    awk '
        $0 == "# BEGIN docker-debian13 remote access" { skipping = 1; next }
        $0 == "# END docker-debian13 remote access"   { skipping = 0; next }
        skipping != 1 { print }
    ' "$hba_file" > "$temporary_file"

    cat >> "$temporary_file" <<'EOF'
# BEGIN docker-debian13 remote access
# 允许任意 IPv4 来源连接，但必须通过 SCRAM 密码认证。
host all all 0.0.0.0/0 scram-sha-256
# 允许任意 IPv6 来源连接，但必须通过 SCRAM 密码认证。
host all all ::/0 scram-sha-256
# END docker-debian13 remote access
EOF

    # pg_hba.conf 必须由 postgres 用户拥有，且不能向组和其他用户开放。
    chown postgres:postgres "$temporary_file"
    chmod 600 "$temporary_file"
    mv -f "$temporary_file" "$hba_file"

    echo "已更新 pg_hba.conf：允许远程 IPv4/IPv6 使用 SCRAM 密码认证。"
}

# PostgreSQL 默认使用 /var/run/postgresql 作为 Unix Socket 目录。
# /run 可能在容器启动后才由 tmpfs 挂载，因此每次启动都确保目录存在。
install -d -m 2775 -o postgres -g postgres /var/run/postgresql

# 数据目录不存在时创建；已存在时只修正顶层目录权限，避免对大数据库做递归 chown。
if [[ ! -d "$pgdata" ]]; then
    install -d -m 700 -o postgres -g postgres "$pgdata"
fi
chown postgres:postgres "$pgdata"
chmod 700 "$pgdata"

# 是否已经初始化，以 PG_VERSION 文件为判断依据。
if [[ ! -s "$pgdata/PG_VERSION" ]]; then
    # 非空目录但没有 PG_VERSION，通常是挂载错了或上传了不完整数据。
    # 直接中止，避免 initdb 覆盖或留下半初始化状态。
    if [[ -n "$(find "$pgdata" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        echo "错误：数据目录 $pgdata 非空，但不存在 PG_VERSION。" >&2
        echo "请使用空目录，或恢复正确的 PostgreSQL 数据目录。" >&2
        exit 1
    fi

    echo "检测到空数据目录，开始初始化 PostgreSQL 16..."

    # 通过临时密码文件传递密码，避免密码出现在进程命令行和 docker ps 中。
    # 必须先由 root 写入，再把文件所有者改为 postgres。
    # 不能先 chown 再写：部分宿主机启用 fs.protected_regular=2 时，
    # root 向 /tmp 中属于 postgres 的 sticky 临时文件写入会报“权限不够”。
    password_file="$(mktemp /tmp/postgres-password.XXXXXX)"
    cleanup_password_file() {
        rm -f "$password_file"
    }
    trap cleanup_password_file EXIT

    printf '%s\n' "$POSTGRES_PASSWORD" > "$password_file"
    chown postgres:postgres "$password_file"
    chmod 600 "$password_file"

    # 以 postgres 用户运行 initdb：
    # - UTF8：统一数据库编码。
    # - C.UTF-8：使用稳定的 UTF-8 locale，不依赖额外 locale 数据。
    # - 本地 Unix Socket 使用 trust，方便容器内部管理。
    # - 远程 TCP 使用 scram-sha-256，要求密码认证。
    # - --username 指定数据库超级用户，默认 postgres。
    runuser -u postgres -- "$pg_bin/initdb" \
        --pgdata="$pgdata" \
        --encoding=UTF8 \
        --locale=C.UTF-8 \
        --auth-local=trust \
        --auth-host=scram-sha-256 \
        --username="$postgres_user" \
        --pwfile="$password_file"

    echo "PostgreSQL 16 数据目录初始化完成。"
fi

# 新数据目录和已有数据目录都执行。
# 这样升级脚本后，不需要删除旧数据卷才能修复远程连接。
configure_pg_hba

# 删除首次初始化可能残留的临时文件（正常情况下 trap 已删除）。
trap - EXIT
rm -f /tmp/postgres-password.*

echo "启动 PostgreSQL 16：data=$pgdata user=$postgres_user port=5432"

# 以 postgres 用户的数字 UID/GID 前台启动数据库：
# - listen_addresses=*：监听容器所有 IPv4/IPv6 网卡。
# - port=5432：容器内部端口，与 Dockerfile EXPOSE 和 Compose 目标端口一致；
#   宿主机通过 2223:5432 映射访问。
# - setpriv 直接替换当前进程，Supervisor 可以准确管理和停止 postgres 进程。
postgres_uid="$(id -u postgres)"
postgres_gid="$(id -g postgres)"
exec setpriv \
    --reuid="$postgres_uid" \
    --regid="$postgres_gid" \
    --init-groups \
    -- "$pg_bin/postgres" \
    -D "$pgdata" \
    -c "listen_addresses=*" \
    -c "port=5432"
