# 来源映射

记录关键架构结论与输入资料的对应关系。当前项目已有实现代码（主要在 `elixir/`），但本次迁入的架构基线主要依据 `SPEC.md`，尚未逐项完成代码一致性审计；因此行为性结论以 SPEC 目标状态、合理推断或待确认为主。

| 结论 | 来源 | 状态 |
|---|---|---|
| 当前目录用于本次架构生成的输入是 `SPEC.md`，项目中存在实现代码，本次尚未逐项完成代码一致性审计。 | 本次目录扫描：`rg --files`；[SPEC.md](../../../SPEC.md) | 已确认 |
| Symphony 的目标是把 issue tracker 中的项目工作交给 coding agent，并提供可重复、可观察的 daemon workflow。 | [SPEC.md](../../../SPEC.md) §1, §2.1 | 目标状态 |
| Symphony 的核心边界是 scheduler/runner/tracker reader，不是一等 ticket 写入系统或通用 workflow engine。 | [SPEC.md](../../../SPEC.md) §1, §2.2, §11.5 | 目标状态 |
| 成功的 run 可以结束在 workflow 定义的 handoff 状态，不必是 tracker terminal state。 | [SPEC.md](../../../SPEC.md) §1, §11.5 | 目标状态 |
| 顶层架构按 workflow/config、orchestrator、tracker、workspace、agent runner、observability 划分模块。 | [SPEC.md](../../../SPEC.md) §3.1, §3.2 | 合理推断 |
| 外部依赖包括 issue tracker API、本地文件系统、可选 workspace population tooling、coding-agent executable 和 host authentication。 | [SPEC.md](../../../SPEC.md) §3.3 | 目标状态 |
| 工作项来自 tracker payload，并作为调度、prompt 和 observability 的共同对象。 | [SPEC.md](../../../SPEC.md) §4.1.1 | 目标状态 |
| 仓库工作流由配置和 prompt 模板组成，是项目规则进入 Symphony 的入口。 | [SPEC.md](../../../SPEC.md) §4.1.2, §5 | 目标状态 |
| 运行设置由 workflow 配置、默认策略和显式环境变量引用形成，环境变量不会全局覆盖 YAML 配置。 | [SPEC.md](../../../SPEC.md) §4.1.3, §6.1 | 目标状态 |
| workflow 变更必须支持运行时 reload；无效 reload 使用上一份可用配置并报告错误。 | [SPEC.md](../../../SPEC.md) §6.2 | 目标状态 |
| prompt 渲染使用 strict variable/filter checking；渲染失败只影响对应运行尝试。 | [SPEC.md](../../../SPEC.md) §5.4, §12.2, §12.4 | 目标状态 |
| orchestrator 是唯一修改调度状态的组件，worker outcome 通过它转换为状态变化。 | [SPEC.md](../../../SPEC.md) §7 | 目标状态 |
| 调度状态为内存中的单一权威；进程重启不恢复 running sessions、retry timers 或 live worker state。 | [SPEC.md](../../../SPEC.md) §4.1.8, §14.3 | 目标状态 |
| 每轮派发前先 reconciliation 正在运行的 issue，处理 terminal、non-active 和 stalled sessions。 | [SPEC.md](../../../SPEC.md) §7.3, §8.1, §8.5 | 目标状态 |
| candidate issue 必须仍处于活动状态、未 running/claimed、有并发名额，并满足 blocker 规则。 | [SPEC.md](../../../SPEC.md) §8.2, §8.3 | 目标状态 |
| dispatch 使用稳定优先级排序，但排序字段细节属于模块/source-map 层，不进入顶层架构。 | [SPEC.md](../../../SPEC.md) §8.2 | 目标状态 |
| worker 正常退出后仍可能安排 continuation retry，因为一次正常结束不代表 issue 永久完成。 | [SPEC.md](../../../SPEC.md) §7.1, §8.4, §16.6 | 目标状态 |
| failure retry 使用受配置上限约束的退避；具体公式属于实现细节，不进入顶层架构。 | [SPEC.md](../../../SPEC.md) §8.4 | 目标状态 |
| workspace path 由 workspace root 和 sanitized issue identifier 形成，并跨 run 复用。 | [SPEC.md](../../../SPEC.md) §4.1.4, §4.2, §9.1, §9.2 | 目标状态 |
| agent 启动前必须验证 cwd 是当前 issue workspace，且 workspace path 仍位于 workspace root 内。 | [SPEC.md](../../../SPEC.md) §9.5, §10.1, §15.2 | 目标状态 |
| workspace lifecycle hooks 围绕创建、运行前、运行后和删除前执行；失败语义因 hook 阶段不同而不同。 | [SPEC.md](../../../SPEC.md) §5.3.4, §9.4 | 目标状态 |
| 除目录创建外的 workspace population/synchronization 是 implementation-defined。 | [SPEC.md](../../../SPEC.md) §9.3 | 待确认 |
| Agent Runner 包装 workspace、prompt 和 app-server client；任一错误会使 worker attempt 失败并交给 orchestrator。 | [SPEC.md](../../../SPEC.md) §10.7 | 目标状态 |
| Codex app-server protocol 的 source of truth 是目标 Codex 版本文档或 generated schema，而不是 Symphony SPEC。 | [SPEC.md](../../../SPEC.md) §10 | 目标状态 |
| continuation turns 在同一 live thread 上继续，不重新发送原始任务 prompt。 | [SPEC.md](../../../SPEC.md) §7.1, §10.2, §10.3 | 目标状态 |
| approval、sandbox、operator confirmation 和 user-input 策略由实现记录，但不得无限期 stalled。 | [SPEC.md](../../../SPEC.md) §10.5, §15.1 | 待确认 |
| 当前 SPEC 目标要求 Linear-compatible tracker 读取操作：候选读取、按状态读取和按 ID 刷新。 | [SPEC.md](../../../SPEC.md) §11.1 | 目标状态 |
| Linear-specific 查询、分页、认证和 payload normalization 应被隔离，防止外部 schema 漂移污染调度核心。 | [SPEC.md](../../../SPEC.md) §11.2, §11.3, §11.4 | 合理推断 |
| ticket mutations 通常由 agent prompt/tooling 完成；可选 `linear_graphql` 属于 agent toolchain。 | [SPEC.md](../../../SPEC.md) §10.5, §11.5, §18.2 | 目标状态 |
| structured logs 至少要让 operator 看见 startup、validation 和 dispatch failures。 | [SPEC.md](../../../SPEC.md) §13.1, §13.2 | 目标状态 |
| runtime snapshot、human-readable status surface 和 HTTP server 是可选观测/控制扩展，不影响 correctness。 | [SPEC.md](../../../SPEC.md) §13.3, §13.4, §13.7 | 目标状态 |
| observability failure 不应 crash orchestrator。 | [SPEC.md](../../../SPEC.md) §14.1, §14.2 | 目标状态 |
| restart recovery 依赖 startup terminal cleanup、fresh polling 和 redispatching eligible work。 | [SPEC.md](../../../SPEC.md) §8.6, §14.3 | 目标状态 |
| filesystem safety、secret handling、hook timeout 和 harness hardening 是安全模型组成部分。 | [SPEC.md](../../../SPEC.md) §15.2, §15.3, §15.4, §15.5 | 目标状态 |
| 具体 deployment hardening、网络限制、OS/container/VM 隔离、凭据范围和 tracker scope 需要实现或部署记录。 | [SPEC.md](../../../SPEC.md) §15.1, §15.5 | 待确认 |
| SSH worker 是 optional extension；如果实现，central orchestrator 仍是调度单一权威。 | [SPEC.md](../../../SPEC.md) Appendix A | 目标状态 |
| 是否实现 HTTP server、`linear_graphql` tool、SSH worker、持久化 retry/session metadata 或非 Linear tracker adapter 尚未从当前目录确认。 | [SPEC.md](../../../SPEC.md) §13.7, §18.2, Appendix A | 待确认 |
