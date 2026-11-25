# 容器运行约束

你当前运行在 Docker 容器 `docker-debian13` 内，不是宿主机。

## 回复要求

- 每次回复必须使用中文。
- 使用大白话，避免堆砌术语。
- 先讲结论，再讲原因和操作步骤。
- 涉及风险、数据丢失或宿主机操作时，必须明确提醒用户。
- 不确定的事情先检查再回答，不要猜。

## 容器限制

- 容器内没有 systemd。
- 禁止执行 `systemctl`、`service`、`reboot`、`shutdown`。
- 服务由 Supervisor 管理，查看状态使用：

```bash
supervisorctl -c /etc/supervisor/supervisord.conf status
```

- 不要尝试启动、停止或重启 Docker。
- 不要假设自己可以直接操作宿主机。
- 容器内不能代替用户升级宿主机或重建镜像。

## 长期生效的修改

需要长期生效的修改，例如 Dockerfile、compose.yaml、启动脚本、系统软件和 Supervisor 配置，属于用户在宿主机上的操作。

AI 不要直接在运行中的容器里修改这些内容后宣称完成。AI 应该：

1. 说明为什么需要重新构建镜像。
2. 给出用户在宿主机执行的完整方案和命令。
3. 明确告诉用户这是用户操作。
4. 提醒用户执行后重新构建、重新启动。
5. 等待用户操作或确认。

## 开发服务端口

开发服务优先使用空闲端口：

```text
2001-2005
```

- 容器内应用必须监听 `0.0.0.0`。
- 宿主机和容器使用同名端口映射。
- 这 5 个端口优先给 Web、API、调试服务使用。
- 不要占用已经分配给 SSH、数据库和 AI 工具的端口。

容器内部端口：

```text
22    SSH
5432  PostgreSQL
3080  DeepSeek Harness
49374 OpenCode
58627 Kimi
```

宿主机映射端口：

```text
2222  SSH
2223  PostgreSQL
2224  DeepSeek Harness
2225  OpenCode
2226  Kimi
```

## 持久化目录

以下目录在容器重建后仍然保留：

```text
/workspaces
/root/.zcode
/root/.ssh
/root/postgresql/data
/root/.dsh
/root/.kimi-code
/root/.config/opencode
/root/.local/share/opencode
/etc/ssh
```

以下位置和未挂载目录在容器重建后会丢失：

```text
/tmp
/var
```

## 数据和凭据

- 用户要求迁移或备份时，优先使用数据库导出和停止服务后的完整备份，不要直接复制正在写入的数据目录。
