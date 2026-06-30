# Issues 来源兼容实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use summ:executing-plans to implement this plan task-by-task.

**Goal:** 让 Elixir 实现的 tracker 来源兼容 GitHub Issues 和 GitLab Issues。

**Architecture:** 保持 `SymphonyElixir.Tracker` 作为唯一调度边界，新增 GitLab adapter/client，并让 GitHub adapter 支持不依赖 Projects v2 的 issues-only 模式。Orchestrator 继续只消费 `SymphonyElixir.Linear.Issue` 这类规范化工作项，不直接理解 provider payload。

**Tech Stack:** Elixir/OTP、Req、Ecto Changeset、ExUnit。

---

## 任务

1. 在 `test/symphony_elixir/extensions_test.exs` 增加 GitLab adapter 委托测试，并扩展 tracker adapter 选择测试。
2. 在 `test/symphony_elixir/core_test.exs` 增加 GitLab 默认 endpoint、env token、必填 project scope 和 GitHub `project_number` 可选的配置测试。
3. 新增 `test/symphony_elixir/gitlab_client_test.exs`，覆盖 GitLab issue payload 规范化、候选过滤、指定状态读取、按 ID 刷新、评论和状态更新请求。
4. 修改 `lib/symphony_elixir/tracker.ex`，支持 `tracker.kind: gitlab`。
5. 新增 `lib/symphony_elixir/gitlab/adapter.ex` 与 `lib/symphony_elixir/gitlab/client.ex`，实现项目级 GitLab Issues API。
6. 修改 `lib/symphony_elixir/github/client.ex`，允许 `project_number` 为空时直接用 GitHub issue 原生状态读取和更新。
7. 修改 `lib/symphony_elixir/config/schema.ex` 与 `lib/symphony_elixir/config.ex`，补齐 GitLab 默认 endpoint、env var 和语义校验。
8. 修改 `lib/symphony_elixir/status_dashboard.ex`、`elixir/README.md` 和必要架构文档，使配置说明与实现一致。
9. 运行目标测试、`mix specs.check`、`mix format --check-formatted`；能承受时再运行更大测试集合。
