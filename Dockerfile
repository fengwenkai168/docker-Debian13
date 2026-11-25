# 使用 Node.js 官方镜像作为基础镜像。
# NODE_VERSION=24 使用浮动的 node:24-trixie 标签，每次无缓存构建都会
# 获取 Node.js 24 系列当时的最新补丁版本，而不是固定在某个旧版本。
# trixie 是 Debian 13 的发行版代号。
# compose.yaml 同时开启 build.pull，确保每次构建先检查并拉取最新基础镜像。
ARG NODE_VERSION=24
FROM node:${NODE_VERSION}-trixie

# ARG 定义“构建时参数”，可以在 docker compose 的 build.args 中覆盖。
# 它们主要用于构建镜像，不等同于容器运行时的 environment 环境变量。

# Node 官方镜像自带一个 npm 版本，但不一定是 npm 11 的最新补丁版本。
# 这里安装 npm@11，每次全新构建都会解析 npm 11 系列当时的最新版本。
ARG NPM_VERSION=11

# 让 apt 安装软件时不弹出交互式配置界面，避免自动构建卡住。
# 这里使用 ARG，因此不会把 DEBIAN_FRONTEND 永久保留为容器运行环境变量。
ARG DEBIAN_FRONTEND=noninteractive

# 要求 pnpm 不低于 11.11，同时固定在主版本 11，不跨到 pnpm 12。
# ^11.11.0 会在每次全新构建时解析为 11.x 系列当时的最新版本。
# 当前 npm 上 pnpm 11 的最新版本是 11.29.0，满足大于 11.11 的要求。
ARG PNPM_VERSION=^11.11.0

# OpenCode 固定主版本 2，每次全新构建获取 OpenCode v2 系列的最新版本。
ARG OPENCODE_VERSION=2

# 安装 npm latest 标签对应的 DeepSeek Harness 最新稳定版。
# npm 包名为 @deepseek-ai/dsh，安装后提供 dsh 命令。
# 如果上游发布新的 latest，下一次无缓存构建会自动升级。
ARG DSH_VERSION=latest

# 安装 npm latest 标签对应的 Kimi Code CLI 最新稳定版。
# npm 包名为 @moonshot-ai/kimi-code，安装后提供 kimi 命令。
# 如果上游发布新的 latest，下一次无缓存构建会自动升级。
ARG KIMI_CODE_VERSION=latest

# Playwright npm 包版本。latest 会在每次全新构建时解析当前最新稳定版。
# Playwright 与它下载的 Chromium 浏览器版本必须匹配，因此由同一构建步骤安装。
ARG PLAYWRIGHT_VERSION=latest

# 在同一个 RUN 中完成系统软件安装、Node.js 全局工具安装和缓存清理。
# 这样可以避免 apt/npm 缓存被前面的镜像层保留下来，减小最终镜像体积。
RUN sed -i 's/deb.debian.org/mirrors.aliyun.com/g; s/security.debian.org/mirrors.aliyun.com/g' /etc/apt/sources.list.d/debian.sources \
    # 上面的 sed 将 Debian 官方软件源替换为阿里云镜像源。
    # 下面的 apt-get update 用于刷新软件包索引。
    && apt-get update \
    # -y：自动确认安装。
    # --no-install-recommends：只安装必要依赖，不安装推荐的额外软件。
    # 以下系统工具均使用 Debian 13 软件源中的最新可用版本。
    # Debian 稳定源可能落后于各个项目的上游最新版本，但经过发行版测试，
    # 与当前基础系统兼容，构建稳定且不需要在镜像中编译源码。
    && apt-get install -y --no-install-recommends \
        # 容器启动脚本使用的 Shell。
        bash \
        # HTTPS 证书，供下载软件包及访问 HTTPS 服务时使用。
        ca-certificates \
        # HTTP 客户端；也供 Compose 健康检查请求 OpenCode 的 /api/info 接口。
        curl \
        # 项目开发所需的 Git 版本控制工具。
        git \
        # 命令行 JSON 处理器，提供 jq 命令。
        jq \
        # 提供 sshd，允许通过宿主机的 2222 端口 SSH 登录容器。
        openssh-server \
        # 多线程 gzip 实现，提供 pigz 命令，适合压缩大文件。
        pigz \
        # 高速递归文本搜索工具，提供 rg 命令。
        ripgrep \
        # 本地/远程文件同步和增量复制工具。
        rsync \
        # 同时管理 sshd、OpenCode、DeepSeek Harness、dsh Web 代理和 Kimi Web，
        # 并负责异常重启和日志转发。
        supervisor \
        # 7-Zip 压缩/解压工具；Debian 13 的 7zip 包提供 7z、7za、7zr 命令。
        # 注意：受许可证影响，默认包不包含 RAR 解压支持。
        7zip \
    # 先把基础镜像自带的 npm 升级到 npm 11 系列的最新版本。
    # 后面的 pnpm、OpenCode、DSH 和 Kimi 都使用升级后的 npm 安装。
    && npm install --global "npm@${NPM_VERSION}" \
    # 在构建日志中明确显示最终 Node.js 和 npm 版本，
    # 便于确认没有因为基础镜像缓存而使用旧版本。
    && node --version \
    && npm --version \
    # 全局安装 pnpm 11、OpenCode v2 以及 DSH/Kimi 的 npm latest 版本。
    # 四者都安装到 Node.js 全局目录中，由 root 用户直接运行；
    # 本镜像不会创建 dsh、kimi 或其他额外的 Linux 系统用户。
    # OPENCODE_VERSION=2 时，OpenCode 实际安装包为 @opencode/cli@2。
    # OpenCode 的 postinstall 脚本会选择适合当前 CPU/系统的原生二进制文件，
    # 因此安装时不能添加 --ignore-scripts。
    && npm install --global \
        "pnpm@${PNPM_VERSION}" \
        "@opencode/cli@${OPENCODE_VERSION}" \
        "@deepseek-ai/dsh@${DSH_VERSION}" \
        "@moonshot-ai/kimi-code@${KIMI_CODE_VERSION}" \
    # 输出 pnpm 实际安装版本，确认获取到 pnpm 11 系列的最新版本。
    # 校验主版本必须为 11，次版本必须不小于 11，防止依赖解析异常时
    # 安装成 pnpm 12 或低于 11.11 的旧版本。
    && pnpm --version \
    && test "$(pnpm --version | cut -d. -f1)" = "11" \
    && test "$(pnpm --version | cut -d. -f2)" -ge 11 \
    # 在构建阶段验证 OpenCode 命令可以运行，并将版本显示在构建日志中。
    # 如果二进制文件安装失败，镜像构建会在这里直接失败。
    && opencode --version \
    # 验证 DeepSeek Harness 的 dsh 命令可以运行。
    # dsh 要求 Node.js >= 24.9.0；node:24-trixie 当前满足该要求。
    && dsh --version \
    # 验证 Kimi Code CLI 的 kimi 命令可以运行。
    # Kimi 当前要求 Node.js >= 22.19.0；Node 24 满足要求。
    # 由于使用 npm latest，上游未来提高 Node 版本要求时可能需要升级基础镜像。
    && kimi --version \
    # 输出新增系统工具的版本，便于在构建日志中确认实际安装结果。
    # 这里不会固定具体小版本，每次构建会获取 Debian 13 软件源当时的最新版本。
    && git --version \
    && rg --version \
    && jq --version \
    && curl --version | head -n 1 \
    && rsync --version | head -n 1 \
    && 7z | head -n 2 \
    && pigz --version \
    # 清理 npm 下载缓存，避免无用文件进入最终镜像。
    && npm cache clean --force \
    # 清理 apt 软件包索引；必须与 apt-get update 位于同一个 RUN 层。
    && rm -rf /var/lib/apt/lists/* \
    # openssh-server 安装时可能自动生成 host key。
    # 删除镜像内的 key，避免使用该镜像的多个容器共用同一 SSH 主机身份。
    # 容器首次启动时，docker-entrypoint.sh 会通过 ssh-keygen -A 重新生成，
    # 并保存在 Compose 挂载的 ./etc/ssh 目录中。
    && rm -f /etc/ssh/ssh_host_* \
    # /run/sshd：sshd 运行所需的目录。
    # /workspaces：默认项目工作目录，同时对应 Compose 的持久化挂载。
    && mkdir -p /run/sshd /workspaces

# ============================================================================
# 安装通用开发工具、中文 Chromium 和字体
# ============================================================================
# 全部使用 Debian 13 软件源中的最新可用版本。
# 基础 Node 镜像来自 buildpack-deps，已经包含 gcc/g++/make/wget/unzip 等，
# 这里只补充它没有的 Python、网络排障、编辑器和浏览器工具。
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        # Chromium 浏览器；中文界面依赖下面的 chromium-l10n 和 zh_CN locale。
        chromium \
        # Chromium 语言包，包含 zh-CN 和 zh-TW。
        chromium-l10n \
        # 常用 C/C++ 构建工具；gcc/g++/make 已由基础镜像提供。
        cmake \
        # dig、nslookup 等 DNS 查询工具。
        dnsutils \
        # 字体管理工具，提供 fc-list、fc-cache。
        fontconfig \
        # Noto CJK 中文字体（简体、繁体、日文、韩文）。
        fonts-noto-cjk \
        # 彩色 emoji 字体，避免网页 emoji 显示为方框。
        fonts-noto-color-emoji \
        # 处理 GitHub CLI 和 PostgreSQL 官方 apt 源的 GPG key。
        gnupg \
        # 进程和资源查看工具。
        htop \
        # ip、ss 等网络配置/查看工具。
        iproute2 \
        # ping 命令。
        iputils-ping \
        # 日志分页查看器。
        less \
        # 生成 zh_CN.UTF-8 locale，供 Chromium 界面和其他工具使用。
        locales \
        # 查看打开的文件和端口。
        lsof \
        # nc 命令，网络连通性测试。
        netcat-openbsd \
        # 查询 pkg-config 管理的编译参数。
        pkg-config \
        # Python 3 解释器和包管理基础。
        python3 \
        # pip 包管理器。
        python3-pip \
        # venv 虚拟环境支持。
        python3-venv \
        # 系统调用跟踪排障。
        strace \
        # 路由追踪。
        traceroute \
        # 提供 runuser 和 setpriv，供 PostgreSQL 以 postgres 用户安全运行。
        util-linux \
        # 终端编辑器。
        vim \
        # zip 压缩；unzip 已由基础镜像提供。
        zip \
    # 只生成简体中文 UTF-8 locale，不生成无关语言以控制镜像体积。
    && sed -i 's/^# *zh_CN\.UTF-8 UTF-8$/zh_CN.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen \
    && update-locale LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh \
    # Debian 的 pip 通常只提供 pip3，这里补充用户请求的 pip 命令。
    && ln -sf /usr/bin/pip3 /usr/local/bin/pip \
    # 删除 apt 索引，控制镜像体积。
    && rm -rf /var/lib/apt/lists/*

# 默认使用简体中文 locale。
# LANG 会影响 Chromium UI 语言，LANGUAGE 为 gettext 提供中文优先级。
ENV LANG=zh_CN.UTF-8 \
    LANGUAGE=zh_CN:zh

# ============================================================================
# 安装 GitHub CLI 和 PostgreSQL 16
# ============================================================================
# gh 使用 GitHub 官方 apt 源，避免 Debian 自带版本过旧或接口不兼容。
# PostgreSQL 16 使用 PGDG 官方 apt 源，安装服务端和配套客户端。
# PGDG 的 trixie-pgdg 当前提供 PostgreSQL 16.14 系列。
RUN mkdir -p /etc/apt/keyrings \
    # 导入 GitHub CLI 官方签名 key。
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    # 添加 GitHub CLI 官方 stable 软件源。
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    # 导入 PostgreSQL 官方 PGDG 签名 key。
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg \
    && chmod 0644 /usr/share/keyrings/postgresql.gpg \
    # 添加 Debian 13 对应的 trixie-pgdg 软件源。
    && echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    # postgresql-16 会同时安装服务端、psql、pg_dump、pg_restore 等客户端。
    # 安装时会自动创建用于运行数据库的系统用户 postgres，不能以 root 运行 PostgreSQL。
    && apt-get install -y --no-install-recommends \
        gh \
        postgresql-16 \
    && rm -rf /var/lib/apt/lists/* \
    && command -v gh \
    && command -v psql \
    # PostgreSQL 服务端二进制不加入 PATH，直接检查版本化路径。
    && test -x /usr/lib/postgresql/16/bin/postgres

# ============================================================================
# 安装 uv、Playwright 本体和 Playwright 专用 Chromium
# ============================================================================
# uv 没有 Debian 13 官方包，使用 Astral 官方安装器。
# Playwright 安装在独立目录 /opt/playwright，避免污染项目依赖；
# 同时下载与 Playwright 版本配套的 Chromium 浏览器和系统依赖。
#
# NODE_PATH 让任意工作目录中的 CommonJS 脚本可以直接 require("playwright")；
# PLAYWRIGHT_BROWSERS_PATH 固定浏览器安装位置，保证运行时能找到浏览器。
ENV NODE_PATH=/opt/playwright/node_modules \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

RUN curl -LsSf https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh \
    && apt-get update \
    # 在独立目录初始化一个 Node 项目并安装 Playwright。
    && mkdir -p /opt/playwright /ms-playwright \
    && (cd /opt/playwright \
        && npm init --yes >/dev/null \
        && npm install --omit=dev "playwright@${PLAYWRIGHT_VERSION}") \
    # 提供全局 playwright 命令，同时保留 /opt/playwright 的模块路径。
    && ln -sf /opt/playwright/node_modules/.bin/playwright /usr/local/bin/playwright \
    # 下载 Playwright 专用 Chromium，并用官方 --with-deps 补齐运行库。
    && playwright install --with-deps chromium \
    && npm cache clean --force \
    && rm -rf /var/lib/apt/lists/* \
    # 输出关键工具版本并在缺失时让构建失败。
    && python3 --version \
    && pip --version \
    && uv --version \
    # 实际创建并删除一个临时 venv，确认 python3-venv 可用。
    && python3 -m venv /tmp/venv-check \
    && /tmp/venv-check/bin/python --version \
    && rm -rf /tmp/venv-check \
    # 验证 Playwright 命令、模块和浏览器目录都存在。
    && playwright --version \
    && command -v playwright \
    && test -n "$(find /ms-playwright -mindepth 1 -maxdepth 1 -type d -print -quit)" \
    # 真正启动一次 Playwright 自带 Chromium，验证浏览器和系统依赖完整。
    # 容器以 root 运行，Playwright 的 chromiumSandbox 默认关闭，无需手工加 --no-sandbox。
    && node -e 'const { chromium } = require("playwright"); (async () => { const browser = await chromium.launch(); const page = await browser.newPage(); await page.setContent("<title>playwright-ok</title>"); if (await page.title() !== "playwright-ok") throw new Error("unexpected page title"); await browser.close(); console.log("Playwright Chromium launch OK"); })().catch((error) => { console.error(error); process.exit(1); });' \
    && gh --version \
    && psql --version \
    && /usr/lib/postgresql/16/bin/postgres --version \
    && cmake --version \
    && vim --version | head -n 1 \
    && zip -v | head -n 1 \
    && less --version | head -n 1 \
    && htop --version \
    && pkg-config --version \
    # 验证命令行工具确实存在。
    && command -v chromium \
    && command -v vim \
    && command -v zip \
    && command -v less \
    && command -v htop \
    && command -v cmake \
    && command -v pkg-config \
    && command -v ip \
    && command -v lsof \
    && command -v strace \
    && command -v dig \
    && command -v ping \
    && command -v nc \
    && command -v traceroute \
    && command -v runuser \
    && command -v setpriv \
    && command -v fc-list \
    # 验证 zh_CN locale 和中文 Noto 字体已经生效。
    && locale -a | grep -qi '^zh_CN' \
    && test -n "$(fc-list :lang=zh -f '%{family}\n' | head -n 1)"

# 复制容器初始化脚本。
# 它负责设置 root 密码、生成 SSH 配置和 host key，
# 最后通过 exec "$@" 启动下面 CMD 指定的主进程。
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# 复制 dsh Web 启动包装脚本。
# dsh 拒绝监听 0.0.0.0，因此该脚本让 dsh 只监听容器回环地址 127.0.0.1:3081，
# 真正的 0.0.0.0:3080 公开监听由 dsh-proxy 完成。
# 脚本还会从 dsh 启动日志中捕获真实随机 token，供代理转换成 Compose 中的固定 token。
COPY start-dsh-web.sh /usr/local/bin/start-dsh-web.sh

# 复制 Kimi Web 启动包装脚本。
# 它把 Compose 中的 KIMI_CODE_TOKEN 写入持久化的 server.token，
# 再以 0.0.0.0:58627 启动 Kimi Web。
COPY start-kimi-web.sh /usr/local/bin/start-kimi-web.sh

# 复制 PostgreSQL 16 初始化/启动脚本。
# 首次启动在持久化目录中 initdb，后续直接以前台方式启动 postgres，
# 以便 Supervisor 监控和自动重启。
COPY start-postgres.sh /usr/local/bin/start-postgres.sh

# 复制 DeepSeek Harness Web 反向代理。
# 代理监听 0.0.0.0:3080，把请求中的 Host 改写为 127.0.0.1:3081 并删除 Origin，
# 再转发给内部 dsh。这样任意浏览器访问 IP 或域名都无需配置 trusted-host 白名单。
# 代理同时转发 HTTP、SSE、WebSocket 和 dsh 的 /api/remote.mux 长连接。
COPY dsh-proxy.cjs /usr/local/bin/dsh-proxy.cjs

# 用自定义 Supervisor 配置替换软件包的默认配置。
# 配置中定义了 sshd、postgres、opencode serve、dsh web、dsh-proxy 和 kimi web
# 六个服务，以及日志转发和自动重启策略。
COPY supervisord.conf /etc/supervisor/supervisord.conf

# 复制全服务健康检查脚本。
# Docker 健康检查会同时验证 Supervisor 进程状态、监听端口、
# PostgreSQL 就绪状态以及 OpenCode、DSH 和 Kimi 的 HTTP 响应。
COPY healthcheck.sh /usr/local/bin/healthcheck.sh

# 将自包含的部署 compose 文件打包进镜像。
# 文件已经固定使用 GHCR 镜像地址，所有密码、端口和数据目录都直接写在文件里，
# 不读取 .env，也不需要构建时替换任何占位符。
COPY docker-compose.yaml /opt/docker-debian13/docker-compose.yaml

# 确保容器初始化、启动和健康检查脚本都具有可执行权限。
RUN chmod 0755 \
    /usr/local/bin/docker-entrypoint.sh \
    /usr/local/bin/start-dsh-web.sh \
    /usr/local/bin/start-kimi-web.sh \
    /usr/local/bin/start-postgres.sh \
    /usr/local/bin/healthcheck.sh

# 容器以 root 运行。
# 启动脚本需要修改 root 密码、写入 /etc/ssh 并启动 sshd，因此需要 root 权限。
# OpenCode 和 DeepSeek Harness 也直接以 root 身份操作 /workspaces，不另建用户。
# 注意：root 对挂载目录的写入也会影响宿主机上的对应文件，应妥善保护挂载目录。
USER root

# 设置默认工作目录。
# OpenCode 和 DeepSeek Harness 都在这个目录中运行，
# 挂载项目后可以直接操作 /workspaces 下的代码。
WORKDIR /workspaces

# 声明镜像预期提供服务的端口：
# - 22：SSH，由 Compose 映射为宿主机 2222。
# - 2001-2005：预留给开发服务，由 Compose 映射为相同宿主机端口。
# - 3080：DeepSeek Harness Web，由 Compose 映射为宿主机 2224。
# - 5432：PostgreSQL 16 的容器端口，由 Compose 映射为宿主机 2223。
# - 49374：OpenCode Web，由 Compose 映射为宿主机 2225。
# - 58627：Kimi Code Web，由 Compose 映射为宿主机 2226。
# EXPOSE 只是镜像元数据，不会自动发布端口；实际映射以 compose.yaml 的 ports 为准。
EXPOSE 22 2001-2005 3080 5432 49374 58627

# 每次启动容器时首先执行初始化脚本。
# ROOT_PASSWORD、OPENCODE_PASSWORD、KIMI_CODE_PASSWORD 等运行时配置
# 由 Compose 传入，不直接写入镜像，避免把密码或地址固定到镜像层中。
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

# 初始化脚本完成后，默认启动 supervisord。
# - -n：以前台模式运行，保证 Supervisor 退出时容器也会退出。
# - -c：指定上面复制的配置文件。
# Supervisor 再按照配置同时启动 SSH、PostgreSQL、OpenCode、DSH、dsh 代理和 Kimi：
# - /usr/sbin/sshd -D -e
# - /usr/local/bin/start-postgres.sh
#   其内部 postgres 以 postgres 系统用户运行，监听 0.0.0.0:5432
# - opencode serve --hostname 0.0.0.0 --port 49374
# - /usr/local/bin/start-dsh-web.sh
#   其内部 dsh 监听 127.0.0.1:3081，并捕获真实 token
# - node /usr/local/bin/dsh-proxy.cjs
#   对外监听 0.0.0.0:3080，改写 Host/Origin、转换固定 token 后转发到 127.0.0.1:3081
# - /usr/local/bin/start-kimi-web.sh
#   写入固定 Kimi token 后启动 Kimi Code Web，对外监听 0.0.0.0:58627
# 因而不需要在容器内安装或运行 systemd。
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
