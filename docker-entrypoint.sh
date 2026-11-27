#!/usr/bin/env bash
# 上面的 shebang 指定使用 Bash 执行本脚本。
# Dockerfile 的 ENTRYPOINT 会在每次容器启动时运行此脚本。

# 设置严格的 Shell 错误处理：
# -E（errtrace）：错误陷阱可继承到函数和子 Shell。
# -e（errexit）：未处理的命令失败时立即退出，避免带着错误配置继续启动。
# -u（nounset）：读取未定义变量时立即报错。
# -o pipefail：管道中任意命令失败，整个管道都视为失败。
set -Eeuo pipefail

# “:”是 Bash 空命令，这里利用 ${变量:?错误信息} 检查必填环境变量。
# 如果变量未设置或内容为空，脚本会打印对应错误并退出。
# ROOT_PASSWORD 用于 SSH root 登录；OPENCODE_PASSWORD 用于 Web 访问认证。
# DeepSeek Harness 的可选公开地址 DSH_PUBLIC_URL 由 start-dsh-web.sh 处理，
# 它只控制登录链接的显示，不影响任意 IP/域名访问。
: "${ROOT_PASSWORD:?ROOT_PASSWORD 环境变量不能为空}"
: "${OPENCODE_PASSWORD:?OPENCODE_PASSWORD 环境变量不能为空}"

# chpasswd 从标准输入读取“用户名:密码”并更新 /etc/shadow。
# 使用 printf 而不是 echo，可以更稳定地处理密码文本和换行。
# 密码只写入命令管道，不会输出到容器日志。
printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd

# 创建运行所需目录；-p 表示目录已存在时不报错，并自动创建缺失的父目录。
# /run/sshd：sshd 运行所需目录。
# /etc/ssh/sshd_config.d：存放自定义 SSH 服务端配置。
# /root/.config/opencode：OpenCode 配置目录。
# /root/.local/share/opencode：OpenCode 会话、项目和集成数据目录。
# /root/.dsh：DeepSeek Harness 的唯一数据根目录，包括 profiles、设置和凭据。
# /root/.kimi-code：Kimi Code 的配置、登录凭据、会话、日志和 server.token。
# /root/.agents：OpenCode、DSH、Kimi、ZCode 共用技能目录和 skills CLI 账本。
# 所有服务仍然以 root 运行，不会创建 dsh、kimi 或其他额外 Linux 用户。
mkdir -p \
    /run/sshd \
    /etc/ssh/sshd_config.d \
    /root/.config/opencode \
    /root/.local/share/opencode \
    /root/.dsh \
    /root/.kimi-code \
    /root/.agents

# 容器以 root 运行，而 /workspaces 通常由宿主机用户（例如 uid 1000）创建后挂载进来。
# Git 会把这种“属主不是当前用户”的仓库判定为可疑所有权并直接拒绝读取，
# 导致 OpenCode 的变更审查、快照和 /undo 等依赖 git 的功能失效。
# 这里在系统级配置中信任 /workspaces 下的仓库；--replace-all 避免反复启动后配置项累积。
# 如果项目挂载在 /workspaces 之外，需要把路径改成对应目录，或用 '*' 信任所有仓库。
git config --system --replace-all safe.directory '/workspaces/*'

# 镜像内置默认 AI 约束文件。
# /workspaces 通常是宿主机 bind mount；如果宿主机目录里还没有 AGENTS.md，
# 就把镜像模板复制进去，让 OpenCode、DSH、Kimi 等 AI 启动后能读取。
# 只在目标不存在时复制，绝不覆盖用户已有的约束文件。
agents_template="/opt/docker-debian13/AGENTS.md"
agents_target="/workspaces/AGENTS.md"
if [[ -s "$agents_template" && ! -e "$agents_target" ]]; then
    install -m 0644 "$agents_template" "$agents_target"
    echo "已写入默认 AI 约束文件：$agents_target"
fi

# Compose 将宿主机 ./etc/ssh 挂载到容器 /etc/ssh。
# 首次使用时挂载目录可能为空，从而遮住镜像中原有的 sshd_config。
# -s 用于检查文件存在且大小大于 0；只有配置缺失或为空时才写入最小配置，
# 已存在的自定义主配置不会被覆盖。
if [[ ! -s /etc/ssh/sshd_config ]]; then
    # 使用带引号的 heredoc 分隔符 'EOF'，确保内容中的 $ 等字符不会被 Shell 展开。
    cat > /etc/ssh/sshd_config <<'EOF'
# 加载 sshd_config.d 目录下所有 .conf 文件，包括下面的 00-zcode.conf。
Include /etc/ssh/sshd_config.d/*.conf

# 启用内置 SFTP 子系统，支持 SSH 文件传输，不依赖外部 sftp-server 路径。
Subsystem sftp internal-sftp
EOF
fi

# 每次启动都重新生成项目专用的 SSH 配置，确保当前镜像的登录策略生效。
# 文件名以 00 开头，使其在主配置 Include 时较早加载。
# OpenSSH 对多数选项采用“首次获得的值”，因此该文件可覆盖后续发行版默认值。
cat > /etc/ssh/sshd_config.d/00-zcode.conf <<'EOF'
# 允许直接使用 root 账号通过 SSH 登录。
PermitRootLogin yes

# 允许使用密码认证；密码由上面的 chpasswd 设置。
PasswordAuthentication yes

# 禁用键盘交互认证，统一使用明确的密码认证方式。
KbdInteractiveAuthentication no

# 使用 Linux PAM 完成账号和会话相关认证流程。
UsePAM yes

# 允许 TCP 端口转发，便于通过 SSH 隧道访问容器或远端开发服务。
AllowTcpForwarding yes

# 不对客户端来源执行反向 DNS 查询，减少 DNS 异常导致的 SSH 登录延迟。
UseDNS no
EOF

# 生成默认路径下所有“缺失的”SSH host key。
# 已存在的 key 不会被替换，因此持久化挂载中的主机指纹可跨容器重建保持不变。
# Dockerfile 构建阶段已删除镜像自带的 key，避免不同容器共用同一主机身份。
ssh-keygen -A

# 恢复 NocoBase 执行机在 /root/.local/bin 下的命令软链。
# runner 的程序、应用 CLI 和注册状态由 Compose 挂载持久化，但 /root/.local/bin
# 本身在镜像临时层中；容器重建后这里不会覆盖已有文件，只补齐缺失的软链。
mkdir -p /root/.local/bin
for entry in \
    "nocobase-runner:/root/.local/share/nocobase-runner" \
    "nb-studio:/root/.local/share/nb-studio"; do
    name="${entry%%:*}"
    prefix="${entry#*:}"
    if [[ -x "$prefix/current/bin/$name" ]]; then
        ln -sfn "$prefix/current/bin/$name" "/root/.local/bin/$name"
    fi
done

# 如果检测到 runner 数据但不在持久化挂载中，明确告警。
# 此时容器仍可使用，但重建容器会丢失执行机注册，需要重新生成一次性 token。
if [[ -d /root/.nocobase-runner ]] && ! mountpoint -q /root/.nocobase-runner; then
    echo "警告：/root/.nocobase-runner 未挂载到宿主机，重建容器会丢失 NocoBase 执行机注册。" >&2
fi

# "$@" 是 Docker 传给 ENTRYPOINT 的全部参数，默认来自 Dockerfile 的 CMD。
# exec 用目标进程替换当前 Bash 进程，使 supervisord 成为容器主进程，
# 从而能直接接收 docker stop 发送的 SIGTERM 等信号并正确停止子服务。
# 如果运行时覆盖了 CMD，这里也会执行覆盖后的命令。
exec "$@"
