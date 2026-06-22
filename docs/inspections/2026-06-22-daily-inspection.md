# 2026-06-22 日常巡检记录

## 基本信息

- 巡检时间：2026-06-22 10:00-10:35 CST
- 仓库：`JhihJian/symphony`
- 本地管理根目录：`/data/dev/symphony`
- 基准分支：`main`

## 上次记录

- 仓库内未找到既有 `docs/inspections/` 或同类巡检记录。
- 参考了部署记忆 `/home/jhihjian/.codex/memory/deploys/DEPLOY_symphony_dokploy-local.md`，其中最近一次可用运行记录为 2026-06-18。

## GitHub 队列

- 巡检开始时发现 issue #21 处于 GitHub Project `In review`，对应 PR #25 处于 `DIRTY/CONFLICTING`。
- 已在 `fix/admin-instance-create-button` worktree 中把 PR #25 合入最新 `origin/main`，保留 #24 的新版表单布局，同时保留 #25 的“新建实例/收起表单”交互。
- 验证通过：
  - `mise exec -- mix format --check-formatted lib/symphony_elixir_web/live/admin_instances_live.ex test/symphony_elixir/admin_instance_dashboard_test.exs`
  - `mise exec -- mix test test/symphony_elixir/admin_instance_dashboard_test.exs`
  - `mise exec -- make all`
- PR #25 已合并，merge commit 为 `2b0ac22fd0da872c35ca97fd808c47d893f03339`。
- issue #21 已自动关闭，并在 Project 中进入 `Done`。
- 巡检结束时 `gh pr list --state open` 与 `gh issue list --state open` 均为空。

## 本机实例

- 当前实例：`symphony@symphony.service`
- 端口：`20000`
- workflow：`/home/jhihjian/.config/symphony/projects/symphony/WORKFLOW.md`
- API：`http://127.0.0.1:20000/api/v1/state`

巡检发现：

- systemd 服务和 API 初始状态存活，但历史日志中存在 GitHub tracker 轮询 `Req.TransportError` 的连接层错误。
- GitHub token 和当前机器到 `https://api.github.com/rate_limit` 的网络探测正常。
- 服务空闲，`running=0`、`blocked=0`、`retrying=0`。

处理：

- 在空闲状态下执行 `systemctl --user restart symphony@symphony.service`，用于清理可能残留的 Erlang/Req 连接状态。
- 重启后服务恢复为 `active (running)`，`0.0.0.0:20000` 正常监听，`/api/v1/state` 返回 `running=0`、`blocked=0`、`retrying=0`。
- 重启后未再观察到新的 `Failed to fetch from tracker`、`:closed`、`:timeout` 或 `:nxdomain` 错误。
- 重启期间服务按终态 issue 清理了 #19/#20/#21 的 workspace，清理进程随后结束。

## 文档与代码同步

本次已调整：

- `DEPLOY.md`：澄清 Dashboard auto-update 与 legacy `symphony-update.timer` 的重启策略差异。
- `_se/project/architecture/ARCHITECTURE.md`：补充 2026-06-22 有限代码/运行核对范围。
- `_se/project/architecture/modules/issue-tracker-integration.md`：说明 GitHub/GitLab adapter、client、agent-side tools 和 E2E/contract 测试已存在，同时标出仍未满足的架构目标。
- `_se/project/architecture/modules/workflow-and-configuration.md`：区分当前 schema 已支持字段与尚未落地的 `state_source`、`state_mapping`、`blocker_policy`。
- `_se/project/architecture/decisions/0004-agent-tooling-owns-tracker-writes.md`：说明当前最小写入 callback 属于 agent toolchain extension，不改变 orchestrator 核心边界。
- `_se/project/architecture/source-map.md`：补充 GitHub/GitLab 实现证据、当前配置 schema 事实、GitHub issue ID 漂移和部署安全姿态差异。

仍需后续处理的代码/架构漂移已转成 GitHub issue。

## 新建改进 Issue

本次巡检识别并计划跟踪以下改进点：

- #26 WorkflowStore 热更新应拒绝语义无效配置并保留 last-known-good。
- #27 GitHub issue internal ID 应使用 provider-scoped key。
- #28 远程 worker workspace 缺少等价 root containment 校验。
- #29 GitHub 原生 `CLOSED` 状态应优先覆盖 Project 状态。
- #30 远程访问 Admin LiveView 不应渲染实例清单和本地路径。
- #31 覆盖率门禁大量 ignore，100% 阈值不能反映真实测试风险。
- #32 落地 GitHub/GitLab blocker capability 与 `blocker_policy`。

## 下次巡检建议

- 先读取本文件和部署记忆，再检查 GitHub 队列。
- 特别关注新建改进 issue 是否已有 PR 或阻塞。
- 检查 `journalctl --user -u symphony@symphony.service` 是否再次出现 GitHub tracker `Req.TransportError`。
- 若启用 `symphony-update.timer`，注意它仍走 legacy 更新路径，会重启所有启用或运行的实例。
