# Multi-Instance Dashboard Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use summ:executing-plans to implement this plan task-by-task.

**Goal:** 增加一个薄的多实例管理 Dashboard/API，用于集中观察 systemd template 部署的多个独立 Symphony 实例并触发基础生命周期操作。

**Architecture:** 新增 `SymphonyElixir.InstanceRegistry` 从实例配置目录读取 `WORKFLOW.md` 与 `env`，聚合 systemd user service 状态和每个实例 `/api/v1/state`。Phoenix 在现有单实例 Dashboard 旁提供 `/admin/instances` 和 `/api/v1/admin/instances*`，只做管理面展示与启停转发，不改变 `Orchestrator` 调度模型。

**Tech Stack:** Elixir/Phoenix/LiveView、Req、systemctl user service、ExUnit + Phoenix.ConnTest/LiveViewTest。

---

### Task 1: 实例发现与聚合测试

**Files:**
- Create: `elixir/test/symphony_elixir/instance_registry_test.exs`
- Create: `elixir/lib/symphony_elixir/instance_registry.ex`

**Step 1: Write failing tests**
- 构造临时 `config_root`，包含 `project-a` 与 `project-b` 子目录。
- 为每个实例写入 `WORKFLOW.md` 与 `env`，覆盖 tracker、server、workspace 与 logs 信息。
- 注入 fake deps：`systemctl` 返回 running/failed/stopped，`http_get` 返回 state payload 或不可达错误。
- 断言 `list_instances/1` 返回实例名称、service、dashboard/api URL、tracker scope、workspace/logs 摘要、运行/重试/阻塞计数与健康摘要。
- 断言一个实例不可达不会影响另一个实例。

**Step 2: Verify RED**
Run: `mix test test/symphony_elixir/instance_registry_test.exs`
Expected: FAIL because `SymphonyElixir.InstanceRegistry` is undefined.

**Step 3: Minimal implementation**
- 实现配置目录遍历，仅读取一级子目录。
- 使用既有 `Workflow.load/1` 与 `Config.Schema.parse/1` 解析摘要。
- 读取 env 中 `SYMPHONY_PORT` 与 `SYMPHONY_LOGS_ROOT`。
- systemd 状态映射为 `running | stopped | failed | unknown`。
- 独立捕获 HTTP/state 错误，转成 `health.status = unreachable`。

**Step 4: Verify GREEN**
Run: `mix test test/symphony_elixir/instance_registry_test.exs`
Expected: PASS.

### Task 2: 生命周期操作测试与实现

**Files:**
- Modify: `elixir/test/symphony_elixir/instance_registry_test.exs`
- Modify: `elixir/lib/symphony_elixir/instance_registry.ex`

**Step 1: Write failing tests**
- `start_instance/2`、`stop_instance/2`、`restart_instance/2` 调用 fake `systemctl --user <action> symphony@<name>.service`。
- 非法实例名返回 operator 可读错误，不调用 systemctl。
- systemctl 失败返回 `{:error, %{code: "systemctl_failed", message: ...}}`。

**Step 2: Verify RED**
Run: `mix test test/symphony_elixir/instance_registry_test.exs`
Expected: FAIL because lifecycle functions are missing.

**Step 3: Minimal implementation**
- 白名单校验实例名 `[A-Za-z0-9_.-]+`。
- 封装 systemctl action，保留 stderr/stdout 摘要。
- 返回 JSON/API 友好的 map 错误。

**Step 4: Verify GREEN**
Run: `mix test test/symphony_elixir/instance_registry_test.exs`
Expected: PASS.

### Task 3: 管理 API 与 Dashboard

**Files:**
- Create: `elixir/lib/symphony_elixir_web/controllers/admin_instance_controller.ex`
- Create: `elixir/lib/symphony_elixir_web/live/admin_instances_live.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Modify: `elixir/priv/static/dashboard.css`
- Create/modify tests in `elixir/test/symphony_elixir/admin_instance_dashboard_test.exs`

**Step 1: Write failing tests**
- `GET /api/v1/admin/instances` 返回实例列表 JSON。
- `POST /api/v1/admin/instances/:name/start|stop|restart` 返回 202 或可读错误。
- `GET /admin/instances` LiveView 渲染多实例表格、状态、计数、Dashboard/API 链接和日志入口。

**Step 2: Verify RED**
Run: `mix test test/symphony_elixir/admin_instance_dashboard_test.exs`
Expected: FAIL because routes/controllers/liveview are missing.

**Step 3: Minimal implementation**
- Controller 从 endpoint config 读取 `:instance_registry` 和 `:instance_registry_opts`，默认使用真实 registry。
- LiveView 使用同一 registry 渲染静态/可刷新总览与 lifecycle 表单。
- Router 保留 `/` 单实例 Dashboard，新增 `/admin/instances`。

**Step 4: Verify GREEN**
Run: `mix test test/symphony_elixir/admin_instance_dashboard_test.exs`
Expected: PASS.

### Task 4: 文档更新

**Files:**
- Modify: `DEPLOY.md`
- Modify: `elixir/README.md`

**Steps:**
- 说明管理 Dashboard 是 operator control plane，不是多租户 orchestrator。
- 记录配置发现目录、systemd 状态、state API 聚合、不可达隔离。
- 记录 URL 和 lifecycle 操作失败处理方式。

### Task 5: Full validation and PR

**Commands:**
- `mix format --check-formatted`
- `mix specs.check`
- Targeted tests for new files.
- `make all` before commit/PR.
- `mix pr_body.check --file /tmp/pr_body.md` before PR creation.

**Commit:**
- Conventional Chinese commit with `变更/原因/验证` sections.

**PR:**
- Use `.github/pull_request_template.md` with `Issue: Closes #6`.
