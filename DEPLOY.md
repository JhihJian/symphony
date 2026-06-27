# Symphony systemd template 部署

本文档说明如何用用户级 systemd template 部署多个 Symphony 项目实例。

当前 systemd template 仍是 legacy 多实例模型：每个 `symphony@<project>.service` 是独立
进程，读取自己的 `WORKFLOW.md`、`TRACKER.yaml`、workspace、tracker scope 和 Dashboard/API
端口。Elixir 代码中新增的 Hub mode `HUB.yaml` 项目注册表只提供进程内 Hub 方向的模型加载、
身份快照和校验能力；Hub provider request governance 也只是定义未来统一 provider 出口的请求、
队列、quota/backoff/circuit 和结果分类模型。它不会让本部署方式变成单进程 Hub 调度，也不会接管
现有 poll loop、tracker fetch、写回或 dynamic tools provider 调用。

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
- 创建 `~/.config/symphony/projects/<project>/TRACKER.yaml`
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
  WORKFLOW.md   # provider-neutral workflow stages, outcomes, transitions, stage prompts
  TRACKER.yaml  # provider access, stage-state mapping, runtime/workspace/hooks/codex settings
  env           # 项目密钥、端口、日志目录
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
~/.config/symphony/projects/symphony/TRACKER.yaml
```

服务 `ExecStart` 会显式传入 tracker 配置：

```text
./bin/symphony ... --tracker-config ~/.config/symphony/projects/%i/TRACKER.yaml ~/.config/symphony/projects/%i/WORKFLOW.md
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

如果需要局域网访问，在对应 `TRACKER.yaml` 中设置：

```yaml
server:
  host: 0.0.0.0
```

然后访问：

```text
http://<host-ip>:<SYMPHONY_PORT>/
http://<host-ip>:<SYMPHONY_PORT>/workflow
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

推荐在多实例部署中使用 Dashboard 控制自动更新：打开任一运行中实例的
`http://<host>:<SYMPHONY_PORT>/admin/instances`，页面会展示当前部署 commit、GitHub
`main` 最新 commit、下一次 API 轮询时间、最近一次检查结果、速率限制信息和最近一次更新/构建/重启结果。

Dashboard 后端通过 GitHub REST API 轮询 `jhihjian/symphony` 的 `main` 分支，并使用
ETag/`If-None-Match` 条件请求降低速率限制压力。也可以通过 API 手动触发：

```bash
curl http://127.0.0.1:20000/api/v1/admin/auto-update
curl -X POST http://127.0.0.1:20000/api/v1/admin/auto-update/check
curl -X POST http://127.0.0.1:20000/api/v1/admin/auto-update/update
```

更新执行会先检查源码目录是否有本地未提交改动；有改动时会阻止更新并在 Dashboard/API
显示错误。只有 `git fetch`/fast-forward 和 `mix build` 成功后，才记录
`elixir/_build/symphony.build-revision` 并进入实例重启决策。这个标记用于区分“源码已经拉到
最新”与“当前 `bin/symphony` 已经由该 commit 成功构建”，避免上一次构建失败后下次更新被误判为
up to date。默认策略不会重启有活跃 Symphony 会话的实例，而是标记为等待空闲；失败实例不会被自动覆盖。

每个实例可在 `~/.config/symphony/projects/<project>/env` 中配置更新策略：

```bash
SYMPHONY_UPDATE_STRATEGY=idle_restart
```

安装或更新实例时也可以直接指定，未指定时会保留已有 `env` 中的值：

```bash
scripts/install-systemd-template.sh ... --update-strategy manual_restart
```

可选值：

- `idle_restart`：空闲 active 实例自动重启；运行中实例等待空闲。
- `defer_until_idle`：与 `idle_restart` 等价，强调运行中延后。
- `download_only`：只更新和构建程序，不自动重启实例。
- `manual_restart`：构建后等待人工确认重启。
- `force_restart`：显式危险操作，允许强制重启。

下面的 systemd timer 仍保留为兼容的无人值守入口；如果希望完全由 Dashboard 控制，可以不传
`--auto-update`，或对已有部署执行 `--no-auto-update` 关闭 timer。注意：Dashboard auto-update
会读取每个实例的 `SYMPHONY_UPDATE_STRATEGY`，而 legacy timer 脚本是独立入口，不会检查实例是否有
活跃 Symphony 会话。

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
3. 如果源码 commit 变化，或 `elixir/_build/symphony.build-revision` 不等于当前 commit，在 `elixir/`
   下执行 `mise exec -- mix setup` 和 `mise exec -- mix build`。
4. 构建成功后写入 `elixir/_build/symphony.build-revision`。
5. 重启所有已启用或正在运行的 `symphony@*.service` 实例；该 legacy 路径不执行 Dashboard 的
   `idle_restart`/`manual_restart`/`download_only` 等 per-instance 策略判断。

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
tracker: ~/.config/symphony/projects/symphony/TRACKER.yaml
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

## 旧配置迁移到两文件布局

如果已有实例仍使用旧单文件 `WORKFLOW.md` front matter 存放 provider、tracker 和 runtime 字段，先使用迁移 task 拆分，再重载 systemd template。以下步骤以当前 `symphony@symphony.service` 为例，命令会备份原文件并保留现有 `env` token：

```bash
project=symphony
config_dir="$HOME/.config/symphony/projects/$project"
backup_dir="$config_dir/backup-$(date +%Y%m%d%H%M%S)"

systemctl --user stop "symphony@$project.service"
mkdir -p "$backup_dir"
cp "$config_dir/WORKFLOW.md" "$backup_dir/WORKFLOW.md"
[ -f "$config_dir/TRACKER.yaml" ] && cp "$config_dir/TRACKER.yaml" "$backup_dir/TRACKER.yaml"

cd ~/.codex/symphony/elixir
mise exec -- mix workflow.split_tracker_config \
  --workflow "$config_dir/WORKFLOW.md" \
  --workflow-out "$config_dir/WORKFLOW.md.next" \
  --tracker-out "$config_dir/TRACKER.yaml.next" \
  --force

mv "$config_dir/WORKFLOW.md.next" "$config_dir/WORKFLOW.md"
mv "$config_dir/TRACKER.yaml.next" "$config_dir/TRACKER.yaml"

systemctl --user daemon-reload
systemctl --user start "symphony@$project.service"
journalctl --user -u "symphony@$project.service" --since "5 minutes ago" --no-pager
curl -sS "http://127.0.0.1:20000/api/v1/state"
```

迁移后检查点：

- `WORKFLOW.md` 只保留 provider-neutral `workflow` stages，不包含 `tracker:`。
- `TRACKER.yaml` 包含 `tracker.kind`、owner/repo/project number、`workflow_state.strategy: project_v2_status`、`field_name: Status`、`state_options`、`required_labels`，并保留 `server`、`workspace`、`hooks`、`agent`、`codex`、`polling`、`observability`、`worker` 等 runtime 字段。
- `systemctl --user status symphony@symphony.service --no-pager` 显示 active/running。
- `journalctl` 没有 `Invalid WORKFLOW.md`、`Invalid TRACKER.yaml`、`missing_tracker_config_file`。
- `/api/v1/state` 返回 JSON，且包含 `counts`。

如果启动失败，可以回滚备份：

```bash
systemctl --user stop "symphony@$project.service"
cp "$backup_dir/WORKFLOW.md" "$config_dir/WORKFLOW.md"
[ -f "$backup_dir/TRACKER.yaml" ] && cp "$backup_dir/TRACKER.yaml" "$config_dir/TRACKER.yaml"
systemctl --user daemon-reload
systemctl --user start "symphony@$project.service"
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
- `/workflow` 是当前实例的只读 workflow-stage 配置可视化页面，读取该实例的 `WORKFLOW.md`
  和 `TRACKER.yaml`，展示阶段图、transition、missing outcome fallback、tracker 映射覆盖和可用的
  `current_stage` 运行态分布；页面不展示 token、`api_key` 或 env secret 原始值。
- `/admin/instances` 从 `~/.config/symphony/projects` 发现已登记实例，聚合 systemd user service 状态和各实例 `/api/v1/state`。
- 每个 `symphony@<project>.service` 仍然独立拥有自己的 `WORKFLOW.md`、`TRACKER.yaml`、环境变量、日志目录、workspace root、端口和内存调度账本。
- 停止、失败或 API 不可达的实例会显示为该实例自己的健康状态，不会影响其他实例展示。
- 管理面可以请求 `start`、`stop`、`restart`，失败时 API 返回可读错误；issue 派发、重试、reconciliation 和 workspace 隔离仍由对应实例内部 `Orchestrator` 负责。

管理 API 示例：

```bash
curl http://127.0.0.1:20000/api/v1/admin/instances
curl -X POST http://127.0.0.1:20000/api/v1/admin/instances/project-a/restart
```
