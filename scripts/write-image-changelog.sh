#!/usr/bin/env bash
# 生成本次镜像构建的 Markdown 更新日志。
#
# 用法：
#   scripts/write-image-changelog.sh <本地镜像名> <输出文件>
#
# 示例：
#   scripts/write-image-changelog.sh \
#     docker-debian13:latest image-changelog.md
#
# 说明：
# - 通过 --entrypoint /bin/bash 绕过镜像入口脚本，不启动任何常驻服务。
# - 只执行各工具的版本命令，不需要 root 密码、OpenCode 密码或 Kimi 密码。
# - GitHub Actions 会把输出写入 Job Summary、Artifact 和 GitHub Release。

# 严格模式：任何命令失败立即退出，避免发布不完整的更新日志。
set -Eeuo pipefail

# 第一个参数是 Docker 本地镜像名，第二个参数是 Markdown 输出路径。
image="${1:?用法: $0 <本地镜像名> <输出文件>}"
output="${2:?用法: $0 <本地镜像名> <输出文件>}"

# 确认镜像存在，提前给出清晰错误。
if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "错误：本地镜像不存在：$image" >&2
    exit 1
fi

# 获取镜像 ID，便于把更新日志和具体镜像层关联起来。
image_id="$(docker image inspect --format '{{.Id}}' "$image")"

# 这些环境变量在 GitHub Actions 中自动存在。
# 本地手动运行时使用默认值，脚本仍然可用。
repository="${GITHUB_REPOSITORY:-local/repository}"
commit="${GITHUB_SHA:-unknown}"
server_url="${GITHUB_SERVER_URL:-https://github.com}"
ref_name="${GITHUB_REF_NAME:-unknown}"
run_number="${GITHUB_RUN_NUMBER:-0}"
run_attempt="${GITHUB_RUN_ATTEMPT:-0}"
image_name="${IMAGE_NAME:-local/image}"
image_version="${APP_VERSION:-}"
built_at="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

output_dir="$(dirname "$output")"
output_base="$(basename "$output")"
if [[ ! -d "$output_dir" ]]; then
    echo "错误：输出目录不存在：$output_dir" >&2
    exit 1
fi

# 先把版本表和最终文档写到临时文件，全部验证成功后再替换目标文件。
versions_file="$(mktemp "${TMPDIR:-/tmp}/docker-debian13-versions.XXXXXX")"
output_tmp="$(mktemp "$output_dir/.${output_base}.XXXXXX")"
cleanup() {
    rm -f "$versions_file" "$output_tmp"
}
trap cleanup EXIT

# 把采集脚本通过 stdin 交给容器内的 Bash。
# 使用带引号的 heredoc，确保反引号、$ 和引号原样传入容器，
# 不会在宿主机或容器内层被当成命令替换执行。
if ! docker run --rm -i --entrypoint /bin/bash "$image" -s > "$versions_file" <<'VERSION_COLLECTOR'
set -Eeuo pipefail

fail() {
    printf '版本收集失败：%s\n' "$*" >&2
    exit 1
}

# 执行一个版本命令，要求它返回 0 且至少输出一行非空文本。
# 第一个参数是表格标签，其余参数是要执行的命令。
row() {
    local label="$1"
    shift
    local version_output

    if ! version_output="$("$@" 2>&1)"; then
        fail "$label：命令执行失败（$*）"
    fi

    # 去掉 Windows 换行，并只取第一行作为版本值。
    version_output="${version_output//$'\r'/}"
    version_output="${version_output%%$'\n'*}"

    if [[ -z "${version_output//[[:space:]]/}" ]]; then
        fail "$label：版本输出为空"
    fi

    # 竖线和反引号会破坏 Markdown 表格或代码格式，直接视为异常输出。
    if [[ "$version_output" == *'|'* || "$version_output" == *'`'* ]]; then
        fail "$label：版本输出包含不支持的 Markdown 字符：$version_output"
    fi

    printf '| %s | `%s` |\n' "$label" "$version_output"
}

row 'Debian' cat /etc/debian_version
row 'Node.js' node --version
row 'npm' npm --version
row 'pnpm' pnpm --version
row 'OpenCode' opencode --version
row 'DeepSeek Harness' dsh --version
row 'Kimi Code CLI' kimi --version
row 'Python' python3 --version
row 'pip' pip --version
row 'venv' python3 -c 'import sys; print("随 Python %d.%d" % (sys.version_info.major, sys.version_info.minor))'
row 'uv' uv --version
row 'Git' git --version
row 'curl' curl --version
row 'wget' wget --version
row 'GitHub CLI' gh --version
row 'GCC / G++' gcc --version
row 'make' make --version
row 'CMake' cmake --version
row 'pkg-config' pkg-config --version
row 'jq' jq --version
row 'ripgrep' rg --version
row 'rsync' rsync --version
row '7-Zip' dpkg-query -W '-f=${Version}' 7zip
row 'pigz' pigz --version
row 'zip' dpkg-query -W '-f=${Version}' zip
row 'unzip' unzip -v
row 'Vim' vim --version
row 'less' less --version
row 'htop' htop --version
row 'Chromium' chromium --version
row 'Chromium 中文语言包' dpkg-query -W '-f=${Version}' chromium-l10n
row 'Noto CJK' dpkg-query -W '-f=${Version}' fonts-noto-cjk
row 'Fontconfig' fc-list --version
printf '| Playwright 系统依赖 | `latest install-deps` |\n'
row 'iproute2' ip -V
row 'lsof' dpkg-query -W '-f=${Version}' lsof
row 'strace' strace -V
row 'dnsutils' dig -v
row 'iputils-ping' ping -V
row 'netcat-openbsd' dpkg-query -W '-f=${Version}' netcat-openbsd
row 'traceroute' dpkg-query -W '-f=${Version}' traceroute
row 'OpenSSH Server' dpkg-query -W '-f=${Version}' openssh-server
row 'Supervisor' supervisord --version
row 'PostgreSQL' psql --version
VERSION_COLLECTOR
then
    echo "错误：镜像内版本收集失败，未生成更新日志。" >&2
    exit 1
fi

# 版本表固定为 44 行；新增或删除工具时必须同步更新这个值。
expected_version_rows=44
actual_version_rows="$(grep -c '^| ' "$versions_file" || true)"
if [[ "$actual_version_rows" -ne "$expected_version_rows" ]]; then
    echo "错误：版本表应有 ${expected_version_rows} 行，实际为 ${actual_version_rows} 行。" >&2
    exit 1
fi

# 每一行都必须是完整的 Markdown 表格行，并且版本值非空、带反引号。
if grep -Evq '^\| [^|]+ \| `[^`]+` \|$' "$versions_file"; then
    echo "错误：版本表包含空值或格式不正确的行：" >&2
    grep -Ev '^\| [^|]+ \| `[^`]+` \|$' "$versions_file" >&2
    exit 1
fi

# 先输出构建背景，再写入已经验证过的版本表。
{
    echo "# 容器镜像构建"
    echo
    echo "本镜像由 GitHub Actions 自动构建，以下为本次构建实际安装的版本。"
    echo
    echo "## 构建信息"
    echo
    echo "| 字段 | 内容 |"
    echo "| --- | --- |"
    echo "| 构建时间 | \`$built_at\` |"
    # APP_VERSION 由 GitHub Actions 计算并通过环境变量传入。
    # 本地手动运行时可能为空，此时省略这一行。
    if [[ -n "$image_version" ]]; then
        echo "| 镜像版本 | \`$image_version\` |"
    fi
    echo "| 仓库 | \`$repository\` |"
    echo "| 分支 / ref | \`$ref_name\` |"
    echo "| 提交 | [\`$commit\`]($server_url/$repository/commit/$commit) |"
    echo "| Actions 运行 | #$run_number（第 $run_attempt 次尝试） |"
    echo "| 本地镜像 | \`$image\` |"
    echo "| 镜像 ID | \`$image_id\` |"
    echo
    echo "## 实际安装版本"
    echo
    echo "| 工具 | 版本 |"
    echo "| --- | --- |"
    cat "$versions_file"

    echo
    echo "## 部署"
    echo
    echo "镜像内部包含部署模板：\`/opt/docker-debian13/docker-compose.yaml\`，其中镜像标签为 \`latest\`。"
    echo "本次 GitHub Release 附带的 \`docker-compose.yaml\` 已固定到本次构建的版本标签。"
    echo
    echo "从镜像导出最新模板："
    echo
    echo '```bash'
    echo "docker run --rm --entrypoint cat $image_name:latest \\"
    echo "  /opt/docker-debian13/docker-compose.yaml > docker-compose.yaml"
    echo "docker compose -f docker-compose.yaml up -d"
    echo '```'
    echo
    echo "持久化数据默认写到部署文件旁边的 \`./workspaces\`、\`./root\` 和 \`./etc/ssh\`。"
    echo "要更改宿主机路径，直接编辑部署文件中的 volume 挂载路径。"
    echo
    echo "## 拉取镜像"
    echo
    echo '```bash'
    if [[ -n "$image_version" ]]; then
        echo "docker pull $image_name:$image_version"
    else
        echo "docker pull $image_name:latest"
    fi
    echo '```'
    echo
    available_tags="\`latest\`"
    if [[ -n "$image_version" ]]; then
        available_tags+="、\`${image_version}\`"
    fi
    echo "可用标签：${available_tags}。"
} > "$output_tmp"

# 校验通过后再替换目标文件，避免失败时留下半截更新日志。
chmod 0644 "$output_tmp"
mv -f "$output_tmp" "$output"

# 在控制台也打印一份，方便本地运行和 Actions 日志查看。
cat "$output"
