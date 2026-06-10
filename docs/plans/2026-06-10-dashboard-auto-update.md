# Dashboard Auto Update Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use summ:executing-plans to implement this plan task-by-task.

**Goal:** 为多实例 Dashboard 增加由 GitHub API 轮询驱动的 Symphony `main` 自动更新控制面。

**Architecture:** 复用现有 `InstanceRegistry` 发现本机实例，新增 `AutoUpdate` GenServer 维护轮询、更新状态和单飞更新锁。Web API/LiveView 通过 Endpoint 可配置模块调用，更新执行用依赖注入封装 `git`、GitHub API、构建脚本和 `systemctl --user`，便于测试并避免失败时重启实例。

**Tech Stack:** Elixir/OTP GenServer、Phoenix Controller/LiveView、Req/GitHub API、systemd user service、ExUnit。

---

### Task 1: 后端状态与轮询

**Files:**
- Create: `elixir/lib/symphony_elixir/auto_update.ex`
- Test: `elixir/test/symphony_elixir/auto_update_test.exs`

**Steps:**
1. 写失败测试覆盖 GitHub ETag 轮询、远端 SHA 差异、API 失败状态保留。
2. 实现 `AutoUpdate` 状态快照、手动检查和依赖注入。
3. 运行 `mix test test/symphony_elixir/auto_update_test.exs`。

### Task 2: 更新执行与重启决策

**Files:**
- Modify: `elixir/lib/symphony_elixir/auto_update.ex`
- Test: `elixir/test/symphony_elixir/auto_update_test.exs`

**Steps:**
1. 写失败测试覆盖本地改动阻止、构建失败不重启、空闲/运行中/停止/失败实例决策。
2. 实现单飞更新锁和每实例策略决策。
3. 运行 `mix test test/symphony_elixir/auto_update_test.exs`。

### Task 3: API 与 Dashboard

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/controllers/admin_instance_controller.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/admin_instances_live.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Test: `elixir/test/symphony_elixir/admin_instance_dashboard_test.exs`

**Steps:**
1. 写失败测试覆盖更新状态 API、手动检查/更新 API、Dashboard 文案与按钮。
2. 实现路由、控制器动作和 LiveView 事件。
3. 运行相关测试。

### Task 4: 应用集成与文档

**Files:**
- Modify: `elixir/lib/symphony_elixir.ex`
- Modify: `elixir/README.md`
- Modify: `DEPLOY.md`

**Steps:**
1. 将 `AutoUpdate` 加入监督树，支持配置禁用/注入。
2. 记录 Dashboard 控制更新能力和最小权限说明。
3. 运行 `mix format --check-formatted`、`mix specs.check`、目标测试与脚本 `bash -n`。
