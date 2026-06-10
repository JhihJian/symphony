# Symphony systemd template 部署

本文档说明如何用用户级 systemd template 部署多个 Symphony 项目实例。

## 快速安装

推荐直接使用远程安装脚本创建或更新项目实例。脚本会先把 Symphony `main` 分支 clone 或更新到 `~/.codex/symphony`，再从这份 clone 安装 systemd 服务：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jhihjian/symphony/main/scripts/install-systemd-template.sh)" -- \
  --project symphony \
  --owner jhihjian \
  --repo symphony \
  --project-number 3 \
  --port 20000 \
  --token "$GITHUB_TOKEN" \
  --auto-update
```

如果已经 clone 了仓库，也可以在仓库内运行：

```bash
scripts/install-systemd-template.sh \
  --project symphony \
  --owner jhihjian \
  --repo symphony \
  --project-number 3 \
  --port 20000 \
  --token "$GITHUB_TOKEN" \
  --auto-update
```

脚本会完成：

- 安装或更新 `~/.config/systemd/user/symphony@.service`
- 创建 `~/.config/symphony/projects/<project>/env`
- 创建 `~/.config/symphony/projects/<project>/WORKFLOW.md`
- 创建 `~/.codex/symphony/projects/<project>/logs`
- 创建 `~/.codex/symphony/projects/<project>/workspaces`
- clone 或更新 `https://github.com/jhihjian/symphony` 的 `main` 分支到 `~/.codex/symphony`
- 使用 `~/.codex/symphony/elixir` 作为 Symphony 程序目录
- 如果 `~/.codex/symphony/elixir/bin/symphony` 不存在，自动在 `~/.codex/symphony/elixir` 下执行 `mix setup` 和 `mix build`
- 执行 `systemctl --user daemon-reload`
- 默认启用并启动 `symphony@<project>.service`
- 如果传了 `--auto-update`，安装并启用 `symphony-update.timer`

如果没有传 `--port`，新项目会从 `20000` 开始查找下一个未被现有项目配置使用的端口；更新已有项目时会保留该项目原来的端口。
如果更新已有项目时没有传 `--token`，脚本会保留该项目现有 `env` 文件里的 `GITHUB_TOKEN`。
如果不希望脚本自动构建二进制，可以传 `--skip-build`。
如果不希望自动更新，去掉 `--auto-update`；如果之前启用过，可以传 `--no-auto-update` 关闭。
如果只想生成文件、不执行 `systemctl --user`，可以传 `--no-systemd`。

## 目录约定

安装脚本不假设用户已经手动 clone 仓库。默认情况下，它会使用下面的源码目录：

```text
~/.codex/symphony/
  elixir/
  scripts/
  projects/
```

其中 `projects/` 是运行目录，更新脚本会忽略它，不会因为日志或 workspace 文件导致自动更新失败。

如果需要让 systemd 使用另一份源码，可以显式传入：

```bash
scripts/install-systemd-template.sh ... --source-root /path/to/symphony
```

如果需要使用 fork 或非 `main` 分支：

```bash
scripts/install-systemd-template.sh ... \
  --source-repo-url https://github.com/<owner>/symphony \
  --source-branch main
```

每个受管项目使用独立配置目录：

```text
~/.config/symphony/projects/<project>/
  WORKFLOW.md  # 项目 tracker、workspace、prompt 配置
  env          # 项目密钥、端口、日志目录
```

每个受管项目使用独立运行目录：

```text
~/.codex/symphony/projects/<project>/
  logs/
  workspaces/
```

## systemd template

用户级 template unit 位于：

```text
~/.config/systemd/user/symphony@.service
```

实例名就是项目名。例如 `symphony@symphony.service` 会读取：

```text
~/.config/symphony/projects/symphony/env
~/.config/symphony/projects/symphony/WORKFLOW.md
```

服务命令形态：

```bash
systemctl --user start symphony@<project>.service
systemctl --user status symphony@<project>.service --no-pager
journalctl --user -u symphony@<project>.service -f
```

## 端口规划

Dashboard/API 端口从 `20000` 开始递增：

```text
symphony   20000
project-a  20001
project-b  20002
```

每个项目的端口写在该项目的 `env` 文件中：

```bash
SYMPHONY_PORT=20000
SYMPHONY_LOGS_ROOT=$HOME/.codex/symphony/projects/symphony/logs
```

如果需要局域网访问，在对应 `WORKFLOW.md` front matter 中设置：

```yaml
server:
  host: 0.0.0.0
```

然后访问：

```text
http://<host-ip>:<SYMPHONY_PORT>/
```

## 新增项目示例

下面示例新增 `project-a`。如果 `20000` 已被当前项目使用，脚本会自动选择 `20001`：

```bash
scripts/install-systemd-template.sh \
  --project project-a \
  --owner <owner> \
  --repo <repo> \
  --project-number <github-project-v2-number> \
  --token "$GITHUB_TOKEN"
```

如果只想生成配置、不立即启动：

```bash
scripts/install-systemd-template.sh \
  --project project-a \
  --owner <owner> \
  --repo <repo> \
  --project-number <github-project-v2-number> \
  --no-start
```

## 自动更新

安装时加上 `--auto-update` 会创建并启用用户级 timer：

```text
~/.config/systemd/user/symphony-update.service
~/.config/systemd/user/symphony-update.timer
```

默认每天运行一次，并带 `RandomizedDelaySec=30m`。更新动作由 `~/.codex/symphony` 中的脚本执行：

```bash
~/.codex/symphony/scripts/update-systemd-template.sh
```

它会执行：

1. 检查 Symphony 源码仓库是否有本地未提交改动；运行目录 `projects/` 会被忽略。
2. 在源码仓库执行 `git pull --ff-only`；如果不能 fast-forward，停止更新。
3. 有新提交时，在 `elixir/` 下执行 `mise exec -- mix setup` 和 `mise exec -- mix build`。
4. 重启所有已启用或正在运行的 `symphony@*.service` 实例。

查看自动更新计划：

```bash
systemctl --user list-timers symphony-update.timer --no-pager
```

查看自动更新日志：

```bash
journalctl --user -u symphony-update.service --no-pager
```

立刻触发一次自动更新：

```bash
systemctl --user start symphony-update.service
```

修改自动更新频率，例如每天 04:30：

```bash
scripts/install-systemd-template.sh \
  --project symphony \
  --owner jhihjian \
  --repo symphony \
  --project-number 3 \
  --auto-update \
  --update-calendar '*-*-* 04:30:00'
```

关闭自动更新：

```bash
scripts/install-systemd-template.sh \
  --project symphony \
  --owner jhihjian \
  --repo symphony \
  --project-number 3 \
  --no-auto-update
```

## 卸载项目

默认卸载只停止并禁用服务，保留配置、token、日志和 workspaces：

```bash
scripts/uninstall-systemd-template.sh --project project-a
```

如果确认要删除项目配置：

```bash
scripts/uninstall-systemd-template.sh --project project-a --purge-config
```

如果确认要删除日志和 workspaces：

```bash
scripts/uninstall-systemd-template.sh --project project-a --purge-runtime
```

完全删除该项目实例：

```bash
scripts/uninstall-systemd-template.sh --project project-a --purge-all
```

如果最后一个实例已经删除，并且也想删除 template unit：

```bash
scripts/uninstall-systemd-template.sh --project project-a --purge-all --remove-template
```

如果最后一个实例已经删除，并且也想删除自动更新 timer：

```bash
scripts/uninstall-systemd-template.sh --project project-a --purge-all --remove-auto-update
```

## 当前项目实例

当前 `symphony` 项目实例：

```text
service: symphony@symphony.service
port: 20000
workflow: ~/.config/symphony/projects/symphony/WORKFLOW.md
env: ~/.config/symphony/projects/symphony/env
logs: ~/.codex/symphony/projects/symphony/logs
workspaces: ~/.codex/symphony/projects/symphony/workspaces
```

管理命令：

```bash
systemctl --user status symphony@symphony.service --no-pager
journalctl --user -u symphony@symphony.service -f
systemctl --user restart symphony@symphony.service
systemctl --user stop symphony@symphony.service
```

## 更新 Symphony 程序

推荐直接使用 clone 到 `~/.codex/symphony` 的更新脚本：

```bash
~/.codex/symphony/scripts/update-systemd-template.sh
```

只更新和构建，不重启实例：

```bash
~/.codex/symphony/scripts/update-systemd-template.sh --no-restart
```

更新后只重启某个项目实例：

```bash
~/.codex/symphony/scripts/update-systemd-template.sh --project symphony
```

等价的手动步骤是到 `~/.codex/symphony` 更新程序代码并重建：

```bash
cd ~/.codex/symphony
git pull
cd elixir
mise exec -- mix setup
mise exec -- mix build
```

然后重启需要使用新程序的 template 实例：

```bash
systemctl --user restart symphony@symphony.service
```

## 检查状态

列出所有 Symphony 实例：

```bash
systemctl --user list-units 'symphony@*.service' --no-pager
```

检查端口监听：

```bash
ss -ltnp | rg ':20000|:20001|:20002'
```

检查 API：

```bash
curl http://127.0.0.1:20000/api/v1/state
```

如果启用了局域网访问：

```bash
curl http://<host-ip>:20000/api/v1/state
```

## 多实例管理 Dashboard

任意启用了 `server.port` 或通过 `--port` 启动的 Symphony 实例，都会在同一个 Phoenix
服务里提供多实例管理入口：

```text
http://127.0.0.1:<port>/admin/instances
http://127.0.0.1:<port>/api/v1/admin/instances
```

这个页面是 operator 管理面，不是多租户 orchestrator：

- `/` 是当前进程的单实例执行 Dashboard，展示该实例内部 orchestrator 的运行、重试、阻塞和 token 状态。
- `/admin/instances` 从 `~/.config/symphony/projects` 发现已登记实例，聚合 systemd user service 状态和各实例 `/api/v1/state`。
- 每个 `symphony@<project>.service` 仍然独立拥有自己的 `WORKFLOW.md`、环境变量、日志目录、workspace root、端口和内存调度账本。
- 停止、失败或 API 不可达的实例会显示为该实例自己的健康状态，不会影响其他实例展示。
- 管理面可以请求 `start`、`stop`、`restart`，失败时 API 返回可读错误；issue 派发、重试、reconciliation 和 workspace 隔离仍由对应实例内部 `Orchestrator` 负责。

管理 API 示例：

```bash
curl http://127.0.0.1:20000/api/v1/admin/instances
curl -X POST http://127.0.0.1:20000/api/v1/admin/instances/project-a/restart
```
