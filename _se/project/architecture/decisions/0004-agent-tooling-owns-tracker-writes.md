# 0004 Agent Tooling Owns Tracker Writes

## 状态

目标状态；当前项目已有实现代码（主要在 `elixir/`），但本次架构基线尚未逐项完成代码一致性审计可验证。

## 背景

Symphony 需要从 issue tracker 读取工作并运行 agent，但 ticket 更新、评论、PR metadata 和 handoff 规则通常由团队 workflow 决定。如果 orchestrator 内置这些写入规则，就会把通用调度服务变成团队特定业务系统。

## 决策

Orchestrator 不要求一等 tracker write APIs。ticket mutations 通常由 coding agent 根据 workflow prompt 和可用工具完成。

如果实现 tracker 写入或 raw tracker access 工具，它属于 agent toolchain extension，而不是 orchestrator 核心业务逻辑。workflow-specific success 可以表示到达某个交接状态，不等于 tracker 的终止状态。

## 影响

- orchestrator 保持 scheduler/runner/tracker reader 边界。
- 团队特定写入规则留在 workflow prompt 和 agent tooling 中。
- observability 需要展示 run outcome，但不能假设固定的“完成状态”。
- 可选 tracker tool 必须有清晰权限范围和安全策略。

## 来源

- `SPEC.md` §1
- `SPEC.md` §10.5
- `SPEC.md` §11.5
