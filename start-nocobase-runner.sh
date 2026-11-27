#!/usr/bin/env bash
# NocoBase 执行机（nocobase-runner）的 Supervisord 启动包装脚本。
#
# 镜像不预装 runner：下载接口必须带一次性注册 token，把 token 打进镜像
# 既会泄露密钥，也只能注册一台机器。runner 由使用者在容器启动后安装，
# 程序、应用 CLI 和注册状态保存在 Compose 挂载的宿主机目录中，
# 因此容器重建后本脚本能直接复用原注册，不需要重新注册。
set -Eeuo pipefail

bin=/root/.local/share/nocobase-runner/current/bin/nocobase-runner

# 全新容器还没安装：正常退出，避免 Supervisord 反复重启。
if [[ ! -x "$bin" ]]; then
    echo "nocobase-runner 未安装，跳过启动；首次注册后执行 supervisorctl start nocobase-runner。" >&2
    exit 0
fi

# 已安装但未注册（例如挂载目录为空或复制不完整）：也安静退出。
# 注册凭据位于 /root/.nocobase-runner/credentials/<app-key>.json。
if ! compgen -G '/root/.nocobase-runner/credentials/*.json' >/dev/null; then
    echo "nocobase-runner 未注册，跳过启动；完成注册后执行 supervisorctl start nocobase-runner。" >&2
    exit 0
fi

# PATH 必须包含 /usr/local/bin：OpenCode、DeepSeek Harness、Kimi 都装在那里，
# runner 依赖 PATH 检测这些编码工具。runner 自身的命令软链在 /root/.local/bin。
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.local/bin"
export NOCOBASE_RUNNER_HOME=/root/.nocobase-runner
export NOCOBASE_RUNNER_WORK_ROOT=/root/.nocobase-runner-work

# 说明本进程由服务管理器托管：runner 退出（包括自动更新的退出码 75）
# 后不再自行重试，而是交给 Supervisord 按 autorestart 策略拉起。
export NOCOBASE_RUNNER_SERVICE=1

# 本机回环永远不走代理；其余代理变量由 Compose 注入并由 Supervisord 继承。
export NO_PROXY="127.0.0.1,localhost,::1${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"

exec "$bin" service run
