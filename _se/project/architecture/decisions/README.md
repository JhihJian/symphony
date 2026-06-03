# 架构决策

本目录保存从 `SPEC.md` 抽取出的长期架构取舍。当前项目已有实现代码（主要在 `elixir/`），但本次架构基线尚未逐项完成代码一致性审计，因此这些决策描述 SPEC 目标状态；具体实现是否满足仍待代码或运行环境确认。

| 决策 | 状态 | 来源 |
|---|---|---|
| [0001 Repository-Owned Workflow Contract](0001-repository-owned-workflow-contract.md) | 目标状态 | `SPEC.md` §1, §5, §6 |
| [0002 In-Memory Orchestrator State](0002-in-memory-orchestrator-state.md) | 目标状态 | `SPEC.md` §7, §14.3 |
| [0003 Per-Issue Workspace Isolation](0003-per-issue-workspace-isolation.md) | 目标状态 | `SPEC.md` §8.6, §9, §15.2 |
| [0004 Agent Tooling Owns Tracker Writes](0004-agent-tooling-owns-tracker-writes.md) | 目标状态 | `SPEC.md` §1, §11.5 |
| [0005 Codex App-Server Is Protocol Boundary](0005-codex-app-server-is-protocol-boundary.md) | 目标状态 | `SPEC.md` §10 |
| [0006 Documented Safety Posture Is Required](0006-documented-safety-posture-is-required.md) | 目标状态，具体策略待确认 | `SPEC.md` §10.5, §15 |
