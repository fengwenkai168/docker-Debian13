# Docker-Debian13

自动构建的 Debian 13 开发容器镜像，内置 Node.js 24、Python、PostgreSQL 16、Playwright、常用开发工具和 AI 编程工具。

镜像地址：

```text
ghcr.io/fengwenkai168/docker-debian13:latest
```

镜像已经公开发布，**不需要登录 GHCR，也不需要输入 GitHub Token**。

## 直接用 docker-compose.yaml 部署运行

[`docker-compose.yaml`](docker-compose.yaml) 是完整的部署文件，不包含 `build` 段，也不需要本地 Dockerfile。只要宿主机安装了 Docker 和 Docker Compose，就可以直接拉取公开镜像并启动。

### 1. 准备部署文件

可以直接使用仓库根目录的 [`docker-compose.yaml`](docker-compose.yaml)，也可以从 GitHub Release 下载。

把文件放到宿主机任意目录，例如：

```text
/opt/docker-debian13/
└── docker-compose.yaml
```

### 2. 按需修改配置

密码、Token、端口和数据目录都直接写在 [`docker-compose.yaml`](docker-compose.yaml) 中，不读取 `.env`。

至少建议修改：

```yaml
ROOT_PASSWORD
OPENCODE_PASSWORD
DSH_WEB_TOKEN
DSH_WEB_PASSWORD
KIMI_CODE_PASSWORD
KIMI_CODE_TOKEN
POSTGRES_PASSWORD
```

### 3. 直接启动

```bash
cd /opt/docker-debian13
docker compose -f docker-compose.yaml up -d
```

如果当前目录只有这一个 Compose 文件，也可以直接执行：

```bash
docker compose up -d
```

不需要执行 `docker build`，也不需要登录 GHCR。Compose 会自动从公开仓库拉取镜像。

### 4. 查看运行状态

```bash
docker compose -f docker-compose.yaml ps
docker compose -f docker-compose.yaml logs -f dev
```

### 5. 更新镜像

Release 附件中的 `docker-compose.yaml` 固定到该 Release 的语义版本，不会自动跟随 `latest`。升级时先下载新 Release 的部署文件，参考其中的 `image:` 行，把你现有文件中的镜像标签改成新版本；保留已经修改过的密码、Token 和端口，然后执行：

```bash
docker compose -f docker-compose.yaml pull
docker compose -f docker-compose.yaml up -d
```

不要直接用新 Release 文件覆盖已经改过密码或端口的部署文件。如果部署文件指向 `latest`（例如仓库根目录中的版本），直接执行上面两条命令即可更新到最新镜像。

从 OpenCode Web 使用官方默认端口 4096 的版本开始，现有部署文件里的 `- "2225:49374"` 必须改成 `- "2225:4096"`；宿主机访问端口仍是 2225，只是容器内目标端口变了。漏改会导致升级后 OpenCode Web 打不开。

如果部署了 NocoBase 执行机，升级前请确认现有部署文件包含[“持久化目录”](#持久化目录)中新增的三个 runner 目录。缺少挂载时容器重建会丢失执行机注册，只能用新的 token 重新安装；详见[“NocoBase 执行机”](#nocobase-执行机nocobase-runner)。

## 服务与端口

| 服务 | 宿主机端口 | 登录方式 |
|---|---:|---|
| SSH | 2222 | 用户 `root`，密码 `ROOT_PASSWORD` |
| 开发服务预留 | 2001-2005 | 项目自行监听 `0.0.0.0` |
| DeepSeek Harness Web | 2224 | 直接打开 `http://地址:2224/`，输入 `DSH_WEB_PASSWORD` 或 `DSH_WEB_TOKEN`；也兼容旧的 `?token=...` 链接 |
| PostgreSQL 16 | 2223 | 用户 `postgres`，密码 `postgres-123456`，数据库 `postgres` |
| OpenCode Web | 2225 | 用户 `opencode`，密码 `OPENCODE_PASSWORD` |
| Kimi Code Web | 2226 | `http://地址:2226/#token=kimi-token-123456`，另需 `KIMI_CODE_PASSWORD` |

DeepSeek Harness 直接打开端口会显示代理登录页，登录成功后使用签名 Cookie，浏览器地址栏不再显示 token。旧的 `http://地址:2224/?token=...` 链接仍然可用。

所有端口都支持：

- `127.0.0.1:端口`
- 局域网/公网 IPv4:端口
- 域名:端口
- IPv6 地址:端口

域名需要解析到宿主机，防火墙需要放行对应端口。Docker 宿主机需要启用 IPv6 才能通过 IPv6 访问。

容器健康检查会验证 Supervisor 中的六个内置服务、关键监听端口、PostgreSQL 就绪状态，以及 OpenCode、DSH 和 Kimi 的 HTTP 响应。已注册 NocoBase 执行机时，还会要求 `nocobase-runner` 处于 RUNNING。`docker compose ps` 显示 `unhealthy` 时，需要查看 `supervisorctl status` 和容器日志；Docker 不会因为 `unhealthy` 自动重启容器。

## 配置方式

部署配置全部直接写在 [`docker-compose.yaml`](docker-compose.yaml) 中，不使用 `.env`。

需要修改密码、Token、端口或数据目录时，直接编辑该文件，然后执行：

```bash
docker compose -f docker-compose.yaml up -d
```

主要变量：

```yaml
ROOT_PASSWORD
OPENCODE_PASSWORD
DSH_WEB_TOKEN
DSH_WEB_PASSWORD
KIMI_CODE_TOKEN
KIMI_CODE_PASSWORD
POSTGRES_USER
POSTGRES_PASSWORD
```

默认密码只适合本地测试。公网部署前必须全部修改，并使用防火墙限制来源。

## AI 约束文件

镜像内置默认约束模板：

```text
/opt/docker-debian13/AGENTS.md
```

容器每次启动时，如果宿主机挂载目录中还没有约束文件：

```text
./workspaces/AGENTS.md
```

启动脚本会自动复制一份模板进去。

特点：

- 只在目标文件不存在时复制
- 不会覆盖用户已经修改过的 `AGENTS.md`
- OpenCode、DeepSeek Harness、Kimi 等 AI 会把它作为项目级约束读取
- 可以按项目需要继续修改宿主机上的 `./workspaces/AGENTS.md`
- 约束内容包括容器限制、中文回复要求、长期修改由用户在宿主机操作、开发端口范围和数据目录说明

## 持久化目录

默认数据直接保存在部署文件旁边的目录：

| 宿主机目录 | 内容 |
|---|---|
| `./workspaces` | 项目代码和开发产物 |
| `./root/.zcode` | ZCode 配置、会话、技能和工具链 |
| `./root/.agents` | OpenCode、DSH、Kimi、ZCode 共用技能目录和 skills CLI 账本 |
| `./root/.ssh` | SSH 客户端配置 |
| `./root/postgresql/data` | PostgreSQL 16 数据 |
| `./root/.dsh` | DeepSeek Harness 配置和会话 |
| `./root/.kimi-code` | Kimi Code 配置、凭据、会话和 token |
| `./root/.config/opencode` | OpenCode 配置 |
| `./root/.local/share/opencode` | OpenCode 数据和会话 |
| `./root/.local/share/nocobase-runner` | NocoBase 执行机程序（运行时安装） |
| `./root/.local/share/nb-studio` | NocoBase 应用 CLI（运行时安装） |
| `./root/.nocobase-runner` | 执行机注册密钥、配置、日志和 run 记录 |
| `./etc/ssh` | SSH 服务端配置和 host key |

`.nocobase-runner` 中的注册密钥可以直接代表这台执行机，必须按敏感数据保管，不能提交到仓库或公开分享。

### 迁移数据

不要直接复制正在运行中的部署目录。PostgreSQL 和会话型服务可能仍在写入，复制出来的文件可能前后不一致，导致数据库无法启动或需要恢复。

推荐先单独备份数据库：

```bash
docker compose -f docker-compose.yaml exec -T dev \
  pg_dump -U postgres -d postgres -Fc > postgres.dump
```

恢复时，在目标环境的空数据库中执行：

```bash
docker compose -f docker-compose.yaml exec -T dev \
  pg_restore -U postgres -d postgres --clean --if-exists < postgres.dump
```

`--clean --if-exists` 会删除目标库中的同名对象，只应在用于恢复的空库或确认可覆盖的库上执行。

如果要连同 DSH、Kimi、OpenCode、共用技能和项目文件一起迁移，必须先停止整个服务，确认 PostgreSQL 已完成正常关闭，再复制整个部署目录：

```bash
docker compose -f docker-compose.yaml stop
docker compose -f docker-compose.yaml logs --tail=100 dev | grep -F "database system is shut down"
```

看到 `database system is shut down` 后再使用 `rsync -a` 等方式复制。部署目录中包含 SSH host key、登录凭据和 Token，复制件必须按敏感数据保管。

## NocoBase 执行机（nocobase-runner）

镜像**不预装** runner：服务端下载接口必须带一次性注册 token，构建阶段无法安全获取；把 token 打进镜像还会泄露密钥，而且一个 token 只能注册一台机器。镜像负责启动包装、Supervisor 托管和持久化目录；完成一次注册后，容器重启或升级镜像都会自动上线。

### 首次安装

在 NocoBase 的 Runtimes/Agents 页面添加执行机，复制命令，在容器内执行时追加 `--no-service`：

```bash
curl -fsSL <应用地址>/api/agents/dist/installScript \
  | sh -s -- --runner --server <应用地址> --token <注册token> --no-service
supervisorctl start nocobase-runner
```

- 容器内没有 systemd，`nocobase-runner service install` 会失败，所以用 `--no-service` 跳过安装服务，由 Supervisor 托管。
- 第一条命令只安装和注册，不启动；第二条命令由 Supervisor 启动。
- 如果直接执行了不带 `--no-service` 的官方命令，注册通常已经成功，只是最后装服务那步报错；此时直接 `supervisorctl start nocobase-runner`，不要用同一个 token 反复重试。
- token 是一次性凭证，不要写入仓库、镜像或报告。

### 状态与排障

```bash
nocobase-runner status
supervisorctl status nocobase-runner
```

- `EXITED` 且未注册：正常，说明还没安装。
- `RUNNING` 且 `status` 显示 online：正常。
- 启动失败时查看 `nocobase-runner logs` 和 `docker compose logs`。
- healthcheck 报 `nocobase-runner 已注册但未运行`：执行 `supervisorctl start nocobase-runner`，并检查日志。

### 升级与持久化

- runner 程序、应用 CLI、注册密钥分别位于上表三个目录；容器重建不会丢，不需要重新注册。
- runner 默认自动更新：新版本写入挂载目录，退出码 75 由 Supervisor 重新拉起。
- 手动更新：`nocobase-runner update --check` 或 `nocobase-runner update`。
- 代理：在 compose 中设置 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY`，Supervisor 会继承。
- 从旧版本升级：如果不想迁移旧注册，在重建后按“首次安装”用新 token 重装，并在 Runtimes 页面删除旧的离线记录。
- 如果三个挂载没有加入部署文件，entrypoint 会打印警告；此时重建容器会丢失注册。

### 安全

执行机以 root 运行，agent 拥有完整权限，可以读写真实 home 和 `/workspaces`，**不是沙箱**。应部署在虚拟机或隔离环境，并按最小暴露面配置防火墙；`./root/.nocobase-runner` 按密钥保管。

## 当前工具版本

下面表格由 GitHub Actions 每次成功构建后自动刷新，显示发布镜像中实际安装的版本。

<!-- versions:start -->
| 工具 | 版本 |
| --- | --- |
| Debian | `13.8` |
| Node.js | `v24.22.3` |
| npm | `11.21.3` |
| pnpm | `11.29.0` |
| OpenCode | `opencode v2.4.2` |
| DeepSeek Harness | `0.2.2-rc.5` |
| Kimi Code CLI | `2.8.1` |
| Python | `Python 3.13.5` |
| pip | `pip 25.1.1 from /usr/lib/python3/dist-packages/pip (python 3.13)` |
| venv | `随 Python 3.13` |
| uv | `uv 0.13.10 (x86_64-unknown-linux-gnu)` |
| Git | `git version 2.47.3` |
| curl | `curl 8.14.1 (x86_64-pc-linux-gnu) libcurl/8.14.1 OpenSSL/3.5.9 zlib/1.3.1 brotli/1.1.0 zstd/1.5.7 libidn2/2.3.8 libpsl/0.21.2 libssh2/1.11.1 nghttp2/1.64.0 nghttp3/1.8.0 librtmp/2.3 OpenLDAP/2.6.10` |
| wget | `GNU Wget 1.25.0 在 linux-gnu 上编译。` |
| GitHub CLI | `gh version 2.106.0 (2026-11-25)` |
| GitLab CLI | `glab 1.133.0 (093bdd1b8)` |
| Gitea CLI | `gt version 2.0.0 (2026-11-18)` |
| Gitee CLI | `gitee version v0.3.4 (10deff7)` |
| GCC / G++ | `gcc (Debian 14.2.0-19) 14.2.0` |
| make | `GNU Make 4.4.1` |
| CMake | `cmake version 3.31.6` |
| pkg-config | `1.8.1` |
| jq | `jq-1.7` |
| ripgrep | `ripgrep 14.1.1` |
| rsync | `rsync  version 3.5.0  protocol version 32` |
| 7-Zip | `25.01+dfsg-1~deb13u2` |
| pigz | `pigz 2.8` |
| zip | `3.0-15+deb13u1` |
| unzip | `UnZip 6.00 of 20 April 2009, by Debian. Original by Info-ZIP.` |
| Vim | `VIM - Vi IMproved 9.1 (2024 Jan 02, 编译于 Nov 04 2026 22:12:34)` |
| less | `less 668 (GNU regular expressions)` |
| htop | `htop 3.4.1` |
| Noto CJK | `1:20240730+repack1-1` |
| Fontconfig | `fontconfig version 2.15.0` |
| Playwright | `Version 1.65.1` |
| iproute2 | `ip utility, iproute2-6.15.0, libbpf 1.5.0` |
| lsof | `4.99.4+dfsg-2` |
| strace | `strace -- version 6.13` |
| dnsutils | `DiG 9.20.30-1~deb13u1-Debian` |
| iputils-ping | `ping from iputils 20240905` |
| netcat-openbsd | `1.229-1` |
| traceroute | `1:2.1.6-1` |
| OpenSSH Server | `1:10.0p1-7+deb13u4` |
| Supervisor | `4.2.5` |
| PostgreSQL | `psql (PostgreSQL) 16.16 (Debian 16.16-1.pgdg13+1)` |
<!-- versions:end -->

## 内置环境

### 运行时与 AI 工具

- Debian 13
- Node.js 24
- npm 11
- pnpm 11
- OpenCode v2
- DeepSeek Harness
- Kimi Code CLI
- NocoBase 执行机（可选，运行时安装，镜像不预装）

### 开发工具

- Git、curl、wget
- Python 3、pip、venv、uv
- gcc、g++、make、CMake、pkg-config
- jq、ripgrep
- rsync、7-Zip、pigz、zip、unzip
- Vim、less、htop
- GitHub CLI `gh`
- GitLab CLI `glab`
- Gitea CLI `gt`
- Gitee CLI `gitee`
- Noto CJK 中文字体和彩色 Emoji 字体
- Playwright 包和 Playwright 专用 Chromium 浏览器

### Playwright

Playwright 本体和它管理的 Chromium 浏览器已经内置，浏览器文件位于：

```text
/ms-playwright
```

版本检查：

```bash
playwright --version
```

项目目录中可以直接通过 CommonJS 引用 Playwright：

```javascript
const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.goto('https://example.com');
  await page.screenshot({ path: '/workspaces/example.png', fullPage: true });
  await browser.close();
})();
```

运行：

```bash
node your-playwright-script.js
```

说明：

- `/usr/local/bin/playwright` 是 Playwright CLI
- `/opt/playwright/node_modules` 通过 `NODE_PATH` 提供给项目脚本使用
- Playwright 使用自己下载的 Chromium，不依赖系统浏览器；镜像不再安装 `/usr/bin/chromium`
- 容器以 root 运行，Playwright 默认关闭 Chromium sandbox
- AI 编程工具可以直接执行 `playwright` 命令或运行上述脚本

### 网络与排障

- iproute2（`ip`、`ss`）
- lsof、strace
- dig、nslookup
- ping、nc、traceroute

### 数据库

- PostgreSQL 16 服务端和客户端
- 首次启动自动 `initdb`
- 数据目录持久化
- 由 Supervisor 自动启动和异常重启

PostgreSQL 的 `POSTGRES_USER` 和 `POSTGRES_PASSWORD` 只在首次初始化数据目录时生效。数据库已经初始化后，修改 Compose 中的密码不会自动修改数据库密码，需要执行 `ALTER ROLE`。

### PostgreSQL 连接方式

PostgreSQL 使用原生 TCP 协议，不是 HTTP。容器内部仍监听 5432，宿主机映射端口为 **2223**，因此外部连接使用 2223。

本机：

```bash
PGPASSWORD='postgres-123456' psql \
  -h 127.0.0.1 -p 2223 \
  -U postgres -d postgres \
  -c 'select version();'
```

局域网 IP：

```bash
PGPASSWORD='postgres-123456' psql \
  -h 192.168.9.108 -p 2223 \
  -U postgres -d postgres \
  -c 'select version();'
```

域名：

```bash
PGPASSWORD='postgres-123456' psql \
  -h db.example.com -p 2223 \
  -U postgres -d postgres \
  -c 'select version();'
```

IPv6：

```bash
PGPASSWORD='postgres-123456' psql \
  -h 2001:db8::10 -p 2223 \
  -U postgres -d postgres \
  -c 'select version();'
```

域名只需要通过 DNS 的 A 或 AAAA 记录解析到宿主机 IP。PostgreSQL 本身只检查连接来源 IP，不检查域名，因此不需要在 `pg_hba.conf` 中写域名。

启动脚本会自动维护以下远程认证规则：

```text
host all all 0.0.0.0/0 scram-sha-256
host all all ::/0      scram-sha-256
```

规则位于 `pg_hba.conf` 的受管注释块中，每次启动自动重建，不会重复追加：

```text
# BEGIN docker-debian13 remote access
# END docker-debian13 remote access
```

注意：

- 远程连接必须提供正确密码
- 域名能解析、宿主机防火墙放行 2223，才能从外部连接
- 当前 PostgreSQL 没有配置 TLS，域名直连是普通 PostgreSQL TCP 连接，不是 HTTPS
- 如只需要允许固定网段，请修改 [`start-postgres.sh`](start-postgres.sh) 中受管的 CIDR 规则
- 不要把弱密码的 2223 直接暴露到公网

## 本地构建

仓库根目录的 [`compose.yaml`](compose.yaml) 用于构建镜像：

```bash
docker compose -f compose.yaml up -d --build
```

[`docker-compose.yaml`](docker-compose.yaml) 用于部署 GitHub 构建好的镜像。

### 构建下载源

- 本地构建默认使用阿里云 Debian 源
- GitHub Actions 自动使用 `deb.debian.org`，避免海外 Runner 访问国内源过慢
- 可以手动覆盖：
  ```bash
  APT_MIRROR=deb.debian.org docker compose -f compose.yaml build dev
  ```

### npm 源

构建阶段始终使用 npm 官方源，确保安装当时的最新版本。所有 npm、pnpm、Playwright 安装完成后，镜像会把运行时默认 npm 源切换为国内加速源：

```text
https://registry.npmmirror.com/
```

容器内检查：

```bash
npm config get registry
```

## GitHub Actions 自动构建

工作流文件：[`.github/workflows/build-image.yml`](.github/workflows/build-image.yml)

触发方式：

- 推送到 `main` 或 `master`
- 每月 1 日和 15 日 UTC 02:00 定时构建，约每两周一次
- 在 Actions 页面手动触发

每次构建都会：

1. 拉取最新 `node:24-trixie`
2. 禁用 Docker 构建缓存
3. 使用 `deb.debian.org` 加快海外 Runner 的 apt 下载
4. 安装当时最新的 npm、pnpm、OpenCode、DSH、Kimi 和其他工具
5. 构建并推送 GHCR 镜像
6. 生成实际安装版本清单
7. 创建 GitHub Release
8. 更新本 README 的更新日志并提交回默认分支

如果默认分支启用了分支保护，需要允许 GitHub Actions Bot 直接推送，或者把最后一步改成自动创建 Pull Request，否则镜像和 Release 会成功，但 README 提交会失败。

镜像标签：

```text
ghcr.io/fengwenkai168/docker-debian13:latest
ghcr.io/fengwenkai168/docker-debian13:v0.0.1
```

语义版本从 `v0.0.1` 开始，每次成功构建自动递增 patch：

```text
v0.0.1 → v0.0.2 → v0.0.3 → ...
```

GitHub Release 也使用同一个语义版本。Release 附带的 `docker-compose.yaml` 会固定到本次构建的 `$IMAGE_NAME:$APP_VERSION`，下载旧 Release 后部署的仍然是该版本的镜像。仓库根目录的部署文件仍使用 `latest`，适合持续跟进最新构建。

## 安全说明

- 容器内可登录的 Linux 用户只有 `root`。
- PostgreSQL 使用系统服务用户 `postgres` 运行，但该用户不能用于 SSH 登录。
- OpenCode 的用户名固定为 `opencode`，这是 OpenCode 的 HTTP Basic Auth 用户名，不是 Linux 用户。
- Playwright 使用的 Chromium 在 root 下默认关闭 sandbox，只用于可信的自动化任务，不要用它浏览不可信网页。
- PostgreSQL 宿主机 2223（容器 5432）、SSH 2222、OpenCode 2225（容器 4096）、Kimi 2226（容器 58627）、DSH 2224（容器 3080）默认监听所有网卡，公网部署必须修改默认密码并限制防火墙。
- PostgreSQL 默认允许任意 IPv4/IPv6 来源使用 SCRAM 密码认证；如果不需要远程数据库访问，请收紧 `pg_hba.conf` 规则或关闭宿主机 2223 映射。
- DeepSeek Harness 的登录密码/Token 和 Kimi 的 Token 都是长期凭证，不要在公开场所泄露。
- 不要在不可信网络中直接暴露 AI 工具端口，它们可以执行命令并访问 root 权限下的文件。
- 镜像默认把 `/workspaces/*` 加入 git 的 `safe.directory`，让容器内的 root 能读取宿主机用户挂载的仓库，否则 OpenCode 的变更审查、快照和 `/undo` 会失效。代价是 root 会信任这些目录中的 git 配置和钩子，所以只应挂载可信代码。
- NocoBase 执行机（可选）以 root 运行，agent 拥有完整权限，可读写真实 home 和 `/workspaces`，不是安全沙箱；建议部署在虚拟机或隔离环境。注册密钥保存在 `./root/.nocobase-runner`，必须按敏感数据保管。

## 更新日志

每次 GitHub Actions 成功构建后，会自动在下面写入一条实际版本清单。完整历史也可以在同一次构建的 GitHub Release 和 Actions Artifact 中查看。

<!-- changelog:start -->
<details>
<summary><strong>v0.0.11</strong> · 2026-11-27 09:57:08 UTC</summary>

| 字段 | 内容 |
| --- | --- |
| 构建时间 | `2026-11-27 09:57:08 UTC` |
| 镜像版本 | `v0.0.11` |
| 仓库 | `fengwenkai168/docker-Debian13` |
| 分支 / ref | `main` |
| 提交 | [`fcc9fd36261c071ea3447369e56590496cb40ae9`](https://github.com/fengwenkai168/docker-Debian13/commit/fcc9fd36261c071ea3447369e56590496cb40ae9) |
| Actions 运行 | #13（第 1 次尝试） |
| 本地镜像 | `docker-debian13:latest` |
| 镜像 ID | `sha256:fa9d5142c0f4324a3df22105b24832ced54243c31a60b0b58f90880de6c28306` |

| 工具 | 版本 |
| --- | --- |
| Debian | `13.8` |
| Node.js | `v24.22.3` |
| npm | `11.21.3` |
| pnpm | `11.29.0` |
| OpenCode | `opencode v2.4.2` |
| DeepSeek Harness | `0.2.2-rc.5` |
| Kimi Code CLI | `2.8.1` |
| Python | `Python 3.13.5` |
| pip | `pip 25.1.1 from /usr/lib/python3/dist-packages/pip (python 3.13)` |
| venv | `随 Python 3.13` |
| uv | `uv 0.13.10 (x86_64-unknown-linux-gnu)` |
| Git | `git version 2.47.3` |
| curl | `curl 8.14.1 (x86_64-pc-linux-gnu) libcurl/8.14.1 OpenSSL/3.5.9 zlib/1.3.1 brotli/1.1.0 zstd/1.5.7 libidn2/2.3.8 libpsl/0.21.2 libssh2/1.11.1 nghttp2/1.64.0 nghttp3/1.8.0 librtmp/2.3 OpenLDAP/2.6.10` |
| wget | `GNU Wget 1.25.0 在 linux-gnu 上编译。` |
| GitHub CLI | `gh version 2.106.0 (2026-11-25)` |
| GitLab CLI | `glab 1.133.0 (093bdd1b8)` |
| Gitea CLI | `gt version 2.0.0 (2026-11-18)` |
| Gitee CLI | `gitee version v0.3.4 (10deff7)` |
| GCC / G++ | `gcc (Debian 14.2.0-19) 14.2.0` |
| make | `GNU Make 4.4.1` |
| CMake | `cmake version 3.31.6` |
| pkg-config | `1.8.1` |
| jq | `jq-1.7` |
| ripgrep | `ripgrep 14.1.1` |
| rsync | `rsync  version 3.5.0  protocol version 32` |
| 7-Zip | `25.01+dfsg-1~deb13u2` |
| pigz | `pigz 2.8` |
| zip | `3.0-15+deb13u1` |
| unzip | `UnZip 6.00 of 20 April 2009, by Debian. Original by Info-ZIP.` |
| Vim | `VIM - Vi IMproved 9.1 (2024 Jan 02, 编译于 Nov 04 2026 22:12:34)` |
| less | `less 668 (GNU regular expressions)` |
| htop | `htop 3.4.1` |
| Noto CJK | `1:20240730+repack1-1` |
| Fontconfig | `fontconfig version 2.15.0` |
| Playwright | `Version 1.65.1` |
| iproute2 | `ip utility, iproute2-6.15.0, libbpf 1.5.0` |
| lsof | `4.99.4+dfsg-2` |
| strace | `strace -- version 6.13` |
| dnsutils | `DiG 9.20.30-1~deb13u1-Debian` |
| iputils-ping | `ping from iputils 20240905` |
| netcat-openbsd | `1.229-1` |
| traceroute | `1:2.1.6-1` |
| OpenSSH Server | `1:10.0p1-7+deb13u4` |
| Supervisor | `4.2.5` |
| PostgreSQL | `psql (PostgreSQL) 16.16 (Debian 16.16-1.pgdg13+1)` |

</details>

<details>
<summary><strong>v0.0.10</strong> · 2026-11-27 09:13:47 UTC</summary>

| 字段 | 内容 |
| --- | --- |
| 构建时间 | `2026-11-27 09:13:47 UTC` |
| 镜像版本 | `v0.0.10` |
| 仓库 | `fengwenkai168/docker-Debian13` |
| 分支 / ref | `main` |
| 提交 | [`8821cec6aff9c236b8ffbf9e4b63bb6e1afdfcfb`](https://github.com/fengwenkai168/docker-Debian13/commit/8821cec6aff9c236b8ffbf9e4b63bb6e1afdfcfb) |
| Actions 运行 | #12（第 1 次尝试） |
| 本地镜像 | `docker-debian13:latest` |
| 镜像 ID | `sha256:aabd715c36d352145f14032eeba39729c11261a883d74238899229e1fce7b1d0` |

| 工具 | 版本 |
| --- | --- |
| Debian | `13.8` |
| Node.js | `v24.22.3` |
| npm | `11.21.3` |
| pnpm | `11.29.0` |
| OpenCode | `opencode v2.4.2` |
| DeepSeek Harness | `0.2.2-rc.5` |
| Kimi Code CLI | `2.8.1` |
| Python | `Python 3.13.5` |
| pip | `pip 25.1.1 from /usr/lib/python3/dist-packages/pip (python 3.13)` |
| venv | `随 Python 3.13` |
| uv | `uv 0.13.10 (x86_64-unknown-linux-gnu)` |
| Git | `git version 2.47.3` |
| curl | `curl 8.14.1 (x86_64-pc-linux-gnu) libcurl/8.14.1 OpenSSL/3.5.9 zlib/1.3.1 brotli/1.1.0 zstd/1.5.7 libidn2/2.3.8 libpsl/0.21.2 libssh2/1.11.1 nghttp2/1.64.0 nghttp3/1.8.0 librtmp/2.3 OpenLDAP/2.6.10` |
| wget | `GNU Wget 1.25.0 在 linux-gnu 上编译。` |
| GitHub CLI | `gh version 2.106.0 (2026-11-25)` |
| GitLab CLI | `glab 1.133.0 (093bdd1b8)` |
| Gitea CLI | `gt version 2.0.0 (2026-11-18)` |
| Gitee CLI | `gitee version v0.3.4 (10deff7)` |
| GCC / G++ | `gcc (Debian 14.2.0-19) 14.2.0` |
| make | `GNU Make 4.4.1` |
| CMake | `cmake version 3.31.6` |
| pkg-config | `1.8.1` |
| jq | `jq-1.7` |
| ripgrep | `ripgrep 14.1.1` |
| rsync | `rsync  version 3.5.0  protocol version 32` |
| 7-Zip | `25.01+dfsg-1~deb13u2` |
| pigz | `pigz 2.8` |
| zip | `3.0-15+deb13u1` |
| unzip | `UnZip 6.00 of 20 April 2009, by Debian. Original by Info-ZIP.` |
| Vim | `VIM - Vi IMproved 9.1 (2024 Jan 02, 编译于 Nov 04 2026 22:12:34)` |
| less | `less 668 (GNU regular expressions)` |
| htop | `htop 3.4.1` |
| Noto CJK | `1:20240730+repack1-1` |
| Fontconfig | `fontconfig version 2.15.0` |
| Playwright | `Version 1.65.1` |
| iproute2 | `ip utility, iproute2-6.15.0, libbpf 1.5.0` |
| lsof | `4.99.4+dfsg-2` |
| strace | `strace -- version 6.13` |
| dnsutils | `DiG 9.20.30-1~deb13u1-Debian` |
| iputils-ping | `ping from iputils 20240905` |
| netcat-openbsd | `1.229-1` |
| traceroute | `1:2.1.6-1` |
| OpenSSH Server | `1:10.0p1-7+deb13u4` |
| Supervisor | `4.2.5` |
| PostgreSQL | `psql (PostgreSQL) 16.16 (Debian 16.16-1.pgdg13+1)` |

</details>

<details>
<summary><strong>v0.0.9</strong> · 2026-11-27 06:38:04 UTC</summary>

| 字段 | 内容 |
| --- | --- |
| 构建时间 | `2026-11-27 06:38:04 UTC` |
| 镜像版本 | `v0.0.9` |
| 仓库 | `fengwenkai168/docker-Debian13` |
| 分支 / ref | `main` |
| 提交 | [`f91c23e586f0aa9df88a8da15ce24d851eb1233d`](https://github.com/fengwenkai168/docker-Debian13/commit/f91c23e586f0aa9df88a8da15ce24d851eb1233d) |
| Actions 运行 | #11（第 1 次尝试） |
| 本地镜像 | `docker-debian13:latest` |
| 镜像 ID | `sha256:77ec8a8e69eb18c0de9de61be6d33660c6a84cddf79663af6fa8a5f1cc08c4b7` |

| 工具 | 版本 |
| --- | --- |
| Debian | `13.8` |
| Node.js | `v24.22.3` |
| npm | `11.21.3` |
| pnpm | `11.29.0` |
| OpenCode | `opencode v2.4.2` |
| DeepSeek Harness | `0.2.2-rc.5` |
| Kimi Code CLI | `2.8.1` |
| Python | `Python 3.13.5` |
| pip | `pip 25.1.1 from /usr/lib/python3/dist-packages/pip (python 3.13)` |
| venv | `随 Python 3.13` |
| uv | `uv 0.13.10 (x86_64-unknown-linux-gnu)` |
| Git | `git version 2.47.3` |
| curl | `curl 8.14.1 (x86_64-pc-linux-gnu) libcurl/8.14.1 OpenSSL/3.5.9 zlib/1.3.1 brotli/1.1.0 zstd/1.5.7 libidn2/2.3.8 libpsl/0.21.2 libssh2/1.11.1 nghttp2/1.64.0 nghttp3/1.8.0 librtmp/2.3 OpenLDAP/2.6.10` |
| wget | `GNU Wget 1.25.0 在 linux-gnu 上编译。` |
| GitHub CLI | `gh version 2.106.0 (2026-11-25)` |
| GitLab CLI | `glab 1.133.0 (093bdd1b8)` |
| Gitea CLI | `gt version 2.0.0 (2026-11-18)` |
| Gitee CLI | `gitee version v0.3.4 (10deff7)` |
| GCC / G++ | `gcc (Debian 14.2.0-19) 14.2.0` |
| make | `GNU Make 4.4.1` |
| CMake | `cmake version 3.31.6` |
| pkg-config | `1.8.1` |
| jq | `jq-1.7` |
| ripgrep | `ripgrep 14.1.1` |
| rsync | `rsync  version 3.5.0  protocol version 32` |
| 7-Zip | `25.01+dfsg-1~deb13u2` |
| pigz | `pigz 2.8` |
| zip | `3.0-15+deb13u1` |
| unzip | `UnZip 6.00 of 20 April 2009, by Debian. Original by Info-ZIP.` |
| Vim | `VIM - Vi IMproved 9.1 (2024 Jan 02, 编译于 Nov 04 2026 22:12:34)` |
| less | `less 668 (GNU regular expressions)` |
| htop | `htop 3.4.1` |
| Noto CJK | `1:20240730+repack1-1` |
| Fontconfig | `fontconfig version 2.15.0` |
| Playwright | `Version 1.65.1` |
| iproute2 | `ip utility, iproute2-6.15.0, libbpf 1.5.0` |
| lsof | `4.99.4+dfsg-2` |
| strace | `strace -- version 6.13` |
| dnsutils | `DiG 9.20.30-1~deb13u1-Debian` |
| iputils-ping | `ping from iputils 20240905` |
| netcat-openbsd | `1.229-1` |
| traceroute | `1:2.1.6-1` |
| OpenSSH Server | `1:10.0p1-7+deb13u4` |
| Supervisor | `4.2.5` |
| PostgreSQL | `psql (PostgreSQL) 16.16 (Debian 16.16-1.pgdg13+1)` |

</details>

<details>
<summary><strong>v0.0.8</strong> · 2026-11-25 14:49:15 UTC</summary>

| 字段 | 内容 |
| --- | --- |
| 构建时间 | `2026-11-25 14:49:15 UTC` |
| 镜像版本 | `v0.0.8` |
| 仓库 | `fengwenkai168/docker-Debian13` |
| 分支 / ref | `main` |
| 提交 | [`b761a1beeb4be8bb20ae306601f3d8460a70729c`](https://github.com/fengwenkai168/docker-Debian13/commit/b761a1beeb4be8bb20ae306601f3d8460a70729c) |
| Actions 运行 | #10（第 1 次尝试） |
| 本地镜像 | `docker-debian13:latest` |
| 镜像 ID | `sha256:d1aeecc70752638987a84e13da702e6a35a3370d3d22610eeaff001653a8547c` |

| 工具 | 版本 |
| --- | --- |
| Debian | `13.8` |
| Node.js | `v24.22.3` |
| npm | `11.21.3` |
| pnpm | `11.29.0` |
| OpenCode | `opencode v2.4.1` |
| DeepSeek Harness | `0.2.2-rc.5` |
| Kimi Code CLI | `2.8.0` |
| Python | `Python 3.13.5` |
| pip | `pip 25.1.1 from /usr/lib/python3/dist-packages/pip (python 3.13)` |
| venv | `随 Python 3.13` |
| uv | `uv 0.13.10 (x86_64-unknown-linux-gnu)` |
| Git | `git version 2.47.3` |
| curl | `curl 8.14.1 (x86_64-pc-linux-gnu) libcurl/8.14.1 OpenSSL/3.5.9 zlib/1.3.1 brotli/1.1.0 zstd/1.5.7 libidn2/2.3.8 libpsl/0.21.2 libssh2/1.11.1 nghttp2/1.64.0 nghttp3/1.8.0 librtmp/2.3 OpenLDAP/2.6.10` |
| wget | `GNU Wget 1.25.0 在 linux-gnu 上编译。` |
| GitHub CLI | `gh version 2.105.0 (2026-11-17)` |
| GCC / G++ | `gcc (Debian 14.2.0-19) 14.2.0` |
| make | `GNU Make 4.4.1` |
| CMake | `cmake version 3.31.6` |
| pkg-config | `1.8.1` |
| jq | `jq-1.7` |
| ripgrep | `ripgrep 14.1.1` |
| rsync | `rsync  version 3.5.0  protocol version 32` |
| 7-Zip | `25.01+dfsg-1~deb13u2` |
| pigz | `pigz 2.8` |
| zip | `3.0-15+deb13u1` |
| unzip | `UnZip 6.00 of 20 April 2009, by Debian. Original by Info-ZIP.` |
| Vim | `VIM - Vi IMproved 9.1 (2024 Jan 02, 编译于 Nov 04 2026 22:12:34)` |
| less | `less 668 (GNU regular expressions)` |
| htop | `htop 3.4.1` |
| Noto CJK | `1:20240730+repack1-1` |
| Fontconfig | `fontconfig version 2.15.0` |
| Playwright | `Version 1.65.1` |
| iproute2 | `ip utility, iproute2-6.15.0, libbpf 1.5.0` |
| lsof | `4.99.4+dfsg-2` |
| strace | `strace -- version 6.13` |
| dnsutils | `DiG 9.20.30-1~deb13u1-Debian` |
| iputils-ping | `ping from iputils 20240905` |
| netcat-openbsd | `1.229-1` |
| traceroute | `1:2.1.6-1` |
| OpenSSH Server | `1:10.0p1-7+deb13u4` |
| Supervisor | `4.2.5` |
| PostgreSQL | `psql (PostgreSQL) 16.16 (Debian 16.16-1.pgdg13+1)` |

</details>

<details>
<summary><strong>v0.0.7</strong> · 2026-11-25 14:36:55 UTC</summary>

| 字段 | 内容 |
| --- | --- |
| 构建时间 | `2026-11-25 14:36:55 UTC` |
| 镜像版本 | `v0.0.7` |
| 仓库 | `fengwenkai168/docker-Debian13` |
| 分支 / ref | `main` |
| 提交 | [`998b3f762e1f9a17de4c13b23a5664365b1fa666`](https://github.com/fengwenkai168/docker-Debian13/commit/998b3f762e1f9a17de4c13b23a5664365b1fa666) |
| Actions 运行 | #9（第 1 次尝试） |
| 本地镜像 | `docker-debian13:latest` |
| 镜像 ID | `sha256:d802c118d197aff39b4f4c28eec61fd63fbce76590055aa95f60092d20800e98` |

| 工具 | 版本 |
| --- | --- |
| Debian | `13.8` |
| Node.js | `v24.22.3` |
| npm | `11.21.3` |
| pnpm | `11.29.0` |
| OpenCode | `opencode v2.4.1` |
| DeepSeek Harness | `0.2.2-rc.5` |
| Kimi Code CLI | `2.8.0` |
| Python | `Python 3.13.5` |
| pip | `pip 25.1.1 from /usr/lib/python3/dist-packages/pip (python 3.13)` |
| venv | `随 Python 3.13` |
| uv | `uv 0.13.10 (x86_64-unknown-linux-gnu)` |
| Git | `git version 2.47.3` |
| curl | `curl 8.14.1 (x86_64-pc-linux-gnu) libcurl/8.14.1 OpenSSL/3.5.9 zlib/1.3.1 brotli/1.1.0 zstd/1.5.7 libidn2/2.3.8 libpsl/0.21.2 libssh2/1.11.1 nghttp2/1.64.0 nghttp3/1.8.0 librtmp/2.3 OpenLDAP/2.6.10` |
| wget | `GNU Wget 1.25.0 在 linux-gnu 上编译。` |
| GitHub CLI | `gh version 2.105.0 (2026-11-17)` |
| GCC / G++ | `gcc (Debian 14.2.0-19) 14.2.0` |
| make | `GNU Make 4.4.1` |
| CMake | `cmake version 3.31.6` |
| pkg-config | `1.8.1` |
| jq | `jq-1.7` |
| ripgrep | `ripgrep 14.1.1` |
| rsync | `rsync  version 3.5.0  protocol version 32` |
| 7-Zip | `25.01+dfsg-1~deb13u2` |
| pigz | `pigz 2.8` |
| zip | `3.0-15+deb13u1` |
| unzip | `UnZip 6.00 of 20 April 2009, by Debian. Original by Info-ZIP.` |
| Vim | `VIM - Vi IMproved 9.1 (2024 Jan 02, 编译于 Nov 04 2026 22:12:34)` |
| less | `less 668 (GNU regular expressions)` |
| htop | `htop 3.4.1` |
| Noto CJK | `1:20240730+repack1-1` |
| Fontconfig | `fontconfig version 2.15.0` |
| Playwright | `Version 1.65.1` |
| iproute2 | `ip utility, iproute2-6.15.0, libbpf 1.5.0` |
| lsof | `4.99.4+dfsg-2` |
| strace | `strace -- version 6.13` |
| dnsutils | `DiG 9.20.30-1~deb13u1-Debian` |
| iputils-ping | `ping from iputils 20240905` |
| netcat-openbsd | `1.229-1` |
| traceroute | `1:2.1.6-1` |
| OpenSSH Server | `1:10.0p1-7+deb13u4` |
| Supervisor | `4.2.5` |
| PostgreSQL | `psql (PostgreSQL) 16.16 (Debian 16.16-1.pgdg13+1)` |

</details>

<details>
<summary><strong>v0.0.6</strong> · 2026-11-25 14:27:45 UTC</summary>

| 字段 | 内容 |
| --- | --- |
| 构建时间 | `2026-11-25 14:27:45 UTC` |
| 镜像版本 | `v0.0.6` |
| 仓库 | `fengwenkai168/docker-Debian13` |
| 分支 / ref | `main` |
| 提交 | [`d3d80da872b01d60f7200f580a9cc8b3cfd0ebfd`](https://github.com/fengwenkai168/docker-Debian13/commit/d3d80da872b01d60f7200f580a9cc8b3cfd0ebfd) |
| Actions 运行 | #8（第 1 次尝试） |
| 本地镜像 | `docker-debian13:latest` |
| 镜像 ID | `sha256:91cfd67dbf09bf8b9972aa02c0f207243cbd339f21a1e8a92b5fa69031b5d6c6` |

| 工具 | 版本 |
| --- | --- |
| Debian | `13.8` |
| Node.js | `v24.22.3` |
| npm | `11.21.3` |
| pnpm | `11.29.0` |
| OpenCode | `opencode v2.4.1` |
| DeepSeek Harness | `0.2.2-rc.5` |
| Kimi Code CLI | `2.8.0` |
| Python | `Python 3.13.5` |
| pip | `pip 25.1.1 from /usr/lib/python3/dist-packages/pip (python 3.13)` |
| venv | `随 Python 3.13` |
| uv | `uv 0.13.10 (x86_64-unknown-linux-gnu)` |
| Git | `git version 2.47.3` |
| curl | `curl 8.14.1 (x86_64-pc-linux-gnu) libcurl/8.14.1 OpenSSL/3.5.9 zlib/1.3.1 brotli/1.1.0 zstd/1.5.7 libidn2/2.3.8 libpsl/0.21.2 libssh2/1.11.1 nghttp2/1.64.0 nghttp3/1.8.0 librtmp/2.3 OpenLDAP/2.6.10` |
| wget | `GNU Wget 1.25.0 在 linux-gnu 上编译。` |
| GitHub CLI | `gh version 2.105.0 (2026-11-17)` |
| GCC / G++ | `gcc (Debian 14.2.0-19) 14.2.0` |
| make | `GNU Make 4.4.1` |
| CMake | `cmake version 3.31.6` |
| pkg-config | `1.8.1` |
| jq | `jq-1.7` |
| ripgrep | `ripgrep 14.1.1` |
| rsync | `rsync  version 3.5.0  protocol version 32` |
| 7-Zip | `25.01+dfsg-1~deb13u2` |
| pigz | `pigz 2.8` |
| zip | `3.0-15+deb13u1` |
| unzip | `UnZip 6.00 of 20 April 2009, by Debian. Original by Info-ZIP.` |
| Vim | `VIM - Vi IMproved 9.1 (2024 Jan 02, 编译于 Nov 04 2026 22:12:34)` |
| less | `less 668 (GNU regular expressions)` |
| htop | `htop 3.4.1` |
| Noto CJK | `1:20240730+repack1-1` |
| Fontconfig | `fontconfig version 2.15.0` |
| Playwright | `Version 1.65.1` |
| iproute2 | `ip utility, iproute2-6.15.0, libbpf 1.5.0` |
| lsof | `4.99.4+dfsg-2` |
| strace | `strace -- version 6.13` |
| dnsutils | `DiG 9.20.30-1~deb13u1-Debian` |
| iputils-ping | `ping from iputils 20240905` |
| netcat-openbsd | `1.229-1` |
| traceroute | `1:2.1.6-1` |
| OpenSSH Server | `1:10.0p1-7+deb13u4` |
| Supervisor | `4.2.5` |
| PostgreSQL | `psql (PostgreSQL) 16.16 (Debian 16.16-1.pgdg13+1)` |

</details>

<details>
<summary><strong>v0.0.5</strong> · 2026-11-25 10:22:52 UTC</summary>

| 字段 | 内容 |
| --- | --- |
| 构建时间 | `2026-11-25 10:22:52 UTC` |
| 镜像版本 | `v0.0.5` |
| 仓库 | `fengwenkai168/docker-Debian13` |
| 分支 / ref | `main` |
| 提交 | [`f5f613cba8a6cbb3c817998cfd82f07352cd99d5`](https://github.com/fengwenkai168/docker-Debian13/commit/f5f613cba8a6cbb3c817998cfd82f07352cd99d5) |
| Actions 运行 | #7（第 1 次尝试） |
| 本地镜像 | `docker-debian13:latest` |
| 镜像 ID | `sha256:1385331beeb0d1d8723125737c110d072817935bfd47610de49d5e07663d6eba` |

| 工具 | 版本 |
| --- | --- |
| Debian | `13.8` |
| Node.js | `v24.22.3` |
| npm | `11.21.3` |
| pnpm | `11.29.0` |
| OpenCode | `opencode v2.4.1` |
| DeepSeek Harness | `0.2.2-rc.5` |
| Kimi Code CLI | `2.7.3` |
| Python | `Python 3.13.5` |
| pip | `pip 25.1.1 from /usr/lib/python3/dist-packages/pip (python 3.13)` |
| venv | `随 Python 3.13` |
| uv | `uv 0.13.10 (x86_64-unknown-linux-gnu)` |
| Git | `git version 2.47.3` |
| curl | `curl 8.14.1 (x86_64-pc-linux-gnu) libcurl/8.14.1 OpenSSL/3.5.9 zlib/1.3.1 brotli/1.1.0 zstd/1.5.7 libidn2/2.3.8 libpsl/0.21.2 libssh2/1.11.1 nghttp2/1.64.0 nghttp3/1.8.0 librtmp/2.3 OpenLDAP/2.6.10` |
| wget | `GNU Wget 1.25.0 在 linux-gnu 上编译。` |
| GitHub CLI | `gh version 2.105.0 (2026-11-17)` |
| GCC / G++ | `gcc (Debian 14.2.0-19) 14.2.0` |
| make | `GNU Make 4.4.1` |
| CMake | `cmake version 3.31.6` |
| pkg-config | `1.8.1` |
| jq | `jq-1.7` |
| ripgrep | `ripgrep 14.1.1` |
| rsync | `rsync  version 3.5.0  protocol version 32` |
| 7-Zip | `25.01+dfsg-1~deb13u2` |
| pigz | `pigz 2.8` |
| zip | `3.0-15+deb13u1` |
| unzip | `UnZip 6.00 of 20 April 2009, by Debian. Original by Info-ZIP.` |
| Vim | `VIM - Vi IMproved 9.1 (2024 Jan 02, 编译于 Nov 04 2026 22:12:34)` |
| less | `less 668 (GNU regular expressions)` |
| htop | `htop 3.4.1` |
| Noto CJK | `1:20240730+repack1-1` |
| Fontconfig | `fontconfig version 2.15.0` |
| Playwright | `Version 1.65.1` |
| iproute2 | `ip utility, iproute2-6.15.0, libbpf 1.5.0` |
| lsof | `4.99.4+dfsg-2` |
| strace | `strace -- version 6.13` |
| dnsutils | `DiG 9.20.30-1~deb13u1-Debian` |
| iputils-ping | `ping from iputils 20240905` |
| netcat-openbsd | `1.229-1` |
| traceroute | `1:2.1.6-1` |
| OpenSSH Server | `1:10.0p1-7+deb13u4` |
| Supervisor | `4.2.5` |
| PostgreSQL | `psql (PostgreSQL) 16.16 (Debian 16.16-1.pgdg13+1)` |

</details>

<details>
<summary><strong>v0.0.4</strong> · 2026-11-25 09:50:42 UTC</summary>

| 字段 | 内容 |
| --- | --- |
| 构建时间 | `2026-11-25 09:50:42 UTC` |
| 镜像版本 | `v0.0.4` |
| 仓库 | `fengwenkai168/docker-Debian13` |
| 分支 / ref | `main` |
| 提交 | [`7b21e387b70dedc5856055fb518077eb8cf190b6`](https://github.com/fengwenkai168/docker-Debian13/commit/7b21e387b70dedc5856055fb518077eb8cf190b6) |
| Actions 运行 | #6（第 1 次尝试） |
| 本地镜像 | `docker-debian13:latest` |
| 镜像 ID | `sha256:cccfcf3c38fcfe6d978f6708b48f5ad128f34649b6aad3780330bab285de8e53` |

| 工具 | 版本 |
| --- | --- |
| Debian | `13.8` |
| Node.js | `v24.22.3` |
| npm | `11.21.3` |
| pnpm | `11.29.0` |
| OpenCode | `opencode v2.4.1` |
| DeepSeek Harness | `0.2.2-rc.5` |
| Kimi Code CLI | `2.7.3` |
| Python | `Python 3.13.5` |
| pip | `pip 25.1.1 from /usr/lib/python3/dist-packages/pip (python 3.13)` |
| venv | `随 Python 3.13` |
| uv | `uv 0.13.10 (x86_64-unknown-linux-gnu)` |
| Git | `git version 2.47.3` |
| curl | `curl 8.14.1 (x86_64-pc-linux-gnu) libcurl/8.14.1 OpenSSL/3.5.9 zlib/1.3.1 brotli/1.1.0 zstd/1.5.7 libidn2/2.3.8 libpsl/0.21.2 libssh2/1.11.1 nghttp2/1.64.0 nghttp3/1.8.0 librtmp/2.3 OpenLDAP/2.6.10` |
| wget | `GNU Wget 1.25.0 在 linux-gnu 上编译。` |
| GitHub CLI | `gh version 2.105.0 (2026-11-17)` |
| GCC / G++ | `gcc (Debian 14.2.0-19) 14.2.0` |
| make | `GNU Make 4.4.1` |
| CMake | `cmake version 3.31.6` |
| pkg-config | `1.8.1` |
| jq | `jq-1.7` |
| ripgrep | `ripgrep 14.1.1` |
| rsync | `rsync  version 3.5.0  protocol version 32` |
| 7-Zip | `25.01+dfsg-1~deb13u2` |
| pigz | `pigz 2.8` |
| zip | `3.0-15+deb13u1` |
| unzip | `UnZip 6.00 of 20 April 2009, by Debian. Original by Info-ZIP.` |
| Vim | `VIM - Vi IMproved 9.1 (2024 Jan 02, 编译于 Nov 04 2026 22:12:34)` |
| less | `less 668 (GNU regular expressions)` |
| htop | `htop 3.4.1` |
| Noto CJK | `1:20240730+repack1-1` |
| Fontconfig | `fontconfig version 2.15.0` |
| Playwright | `Version 1.65.1` |
| iproute2 | `ip utility, iproute2-6.15.0, libbpf 1.5.0` |
| lsof | `4.99.4+dfsg-2` |
| strace | `strace -- version 6.13` |
| dnsutils | `DiG 9.20.30-1~deb13u1-Debian` |
| iputils-ping | `ping from iputils 20240905` |
| netcat-openbsd | `1.229-1` |
| traceroute | `1:2.1.6-1` |
| OpenSSH Server | `1:10.0p1-7+deb13u4` |
| Supervisor | `4.2.5` |
| PostgreSQL | `psql (PostgreSQL) 16.16 (Debian 16.16-1.pgdg13+1)` |

</details>

<details>
<summary><strong>v0.0.3</strong> · 2026-11-25 09:33:50 UTC</summary>

| 字段 | 内容 |
| --- | --- |
| 构建时间 | `2026-11-25 09:33:50 UTC` |
| 镜像版本 | `v0.0.3` |
| 仓库 | `fengwenkai168/docker-Debian13` |
| 分支 / ref | `main` |
| 提交 | [`fa92e1a792243fc8b41cf6a6edac03b9c378cb28`](https://github.com/fengwenkai168/docker-Debian13/commit/fa92e1a792243fc8b41cf6a6edac03b9c378cb28) |
| Actions 运行 | #5（第 1 次尝试） |
| 本地镜像 | `docker-debian13:latest` |
| 镜像 ID | `sha256:e82f4180d8f971f63ddebf9eb98652532668ebccc27ca245035dd3745560a146` |

| 工具 | 版本 |
| --- | --- |
| Debian | `13.8` |
| Node.js | `v24.22.3` |
| npm | `11.21.3` |
| pnpm | `11.29.0` |
| OpenCode | `opencode v2.4.1` |
| DeepSeek Harness | `0.2.2-rc.5` |
| Kimi Code CLI | `2.7.3` |
| Python | `Python 3.13.5` |
| pip | `pip 25.1.1 from /usr/lib/python3/dist-packages/pip (python 3.13)` |
| venv | `随 Python 3.13` |
| uv | `uv 0.13.10 (x86_64-unknown-linux-gnu)` |
| Git | `git version 2.47.3` |
| curl | `curl 8.14.1 (x86_64-pc-linux-gnu) libcurl/8.14.1 OpenSSL/3.5.9 zlib/1.3.1 brotli/1.1.0 zstd/1.5.7 libidn2/2.3.8 libpsl/0.21.2 libssh2/1.11.1 nghttp2/1.64.0 nghttp3/1.8.0 librtmp/2.3 OpenLDAP/2.6.10` |
| wget | `GNU Wget 1.25.0 在 linux-gnu 上编译。` |
| GitHub CLI | `gh version 2.105.0 (2026-11-17)` |
| GCC / G++ | `gcc (Debian 14.2.0-19) 14.2.0` |
| make | `GNU Make 4.4.1` |
| CMake | `cmake version 3.31.6` |
| pkg-config | `1.8.1` |
| jq | `jq-1.7` |
| ripgrep | `ripgrep 14.1.1` |
| rsync | `rsync  version 3.5.0  protocol version 32` |
| 7-Zip | `25.01+dfsg-1~deb13u2` |
| pigz | `pigz 2.8` |
| zip | `3.0-15+deb13u1` |
| unzip | `UnZip 6.00 of 20 April 2009, by Debian. Original by Info-ZIP.` |
| Vim | `VIM - Vi IMproved 9.1 (2024 Jan 02, 编译于 Nov 04 2026 22:12:34)` |
| less | `less 668 (GNU regular expressions)` |
| htop | `htop 3.4.1` |
| Chromium | `Chromium 156.0.8078.108 built on Debian GNU/Linux 13 (trixie)` |
| Chromium 中文语言包 | `156.0.8078.108-1~deb13u1` |
| Noto CJK | `1:20240730+repack1-1` |
| Fontconfig | `fontconfig version 2.15.0` |
| Playwright | `Version 1.65.1` |
| iproute2 | `ip utility, iproute2-6.15.0, libbpf 1.5.0` |
| lsof | `4.99.4+dfsg-2` |
| strace | `strace -- version 6.13` |
| dnsutils | `DiG 9.20.30-1~deb13u1-Debian` |
| iputils-ping | `ping from iputils 20240905` |
| netcat-openbsd | `1.229-1` |
| traceroute | `1:2.1.6-1` |
| OpenSSH Server | `1:10.0p1-7+deb13u4` |
| Supervisor | `4.2.5` |
| PostgreSQL | `psql (PostgreSQL) 16.16 (Debian 16.16-1.pgdg13+1)` |

</details>
<!-- changelog:end -->
