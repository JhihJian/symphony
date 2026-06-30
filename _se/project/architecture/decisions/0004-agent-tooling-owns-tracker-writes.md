# 0004 Agent Tooling Owns Tracker Writes

## 状态

目标状态。2026-06-22 巡检确认当前 Elixir `Tracker` 契约包含 `create_comment/2` 和 `update_issue_state/2`，并由 agent-side dynamic tools 调用；这些写入接口应被视为受控 agent toolchain extension，而不是 orchestrator 核心业务写入流程。

## 背景

Symphony 需要从 issue tracker 读取工作并运行 agent，但 ticket 更新、评论、PR/MR metadata 和 handoff 规则通常由团队 workflow 决定。如果 orchestrator 内置这些写入规则，就会把通用调度服务变成团队特定业务系统。

## 决策

Orchestrator 不要求把 tracker write APIs 作为调度核心能力。ticket mutations 通常由 coding agent 根据 workflow prompt 和可用工具完成。

如果实现 tracker 写入或 raw tracker access 工具，它属于 agent toolchain extension，而不是 orchestrator 核心业务逻辑。当前 Elixir 实现把最小评论/状态写入放在 `Tracker` callback 中，供 `tracker_issue`、`github_issue` 等 dynamic tool 复用；这不改变 orchestrator 的读/调度边界。该规则同时适用于 Linear、GitHub 和 GitLab：评论、状态变更、PR/MR 关联、label 调整或 handoff 元数据都不能成为 orchestrator 核心写入流程。workflow-specific success 可以表示到达某个交接状态，不等于 tracker 的终止状态。

## 影响

- orchestrator 保持 scheduler/runner/tracker reader 边界。
- 团队特定写入规则留在 workflow prompt 和 agent tooling 中。
- observability 需要展示 run outcome，但不能假设固定的“完成状态”。
- 可选 tracker tool 必须有清晰权限范围和安全策略，包括 GitHub/GitLab token scope、repository/project 范围和是否允许跨项目链接操作。

## 来源

- `SPEC.md` §1
- `SPEC.md` §10.5
- `SPEC.md` §11.5
- [0007 Multi-Tracker Adapter Contract](0007-multi-tracker-adapter-contract.md)
