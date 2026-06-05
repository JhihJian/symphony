# Observability 与运维

结论状态：SPEC 目标状态；当前项目已有实现代码（主要在 `elixir/`），但本次架构基线尚未逐项完成代码一致性审计可验证。

## 模块定位与边界

Observability 与运维模块负责让 operator 在不 attach debugger 的情况下理解 Symphony 是否健康、正在处理什么、哪里失败、是否需要干预。

它可以提供结构化日志、运行快照、可选状态界面和可选 HTTP/API 扩展。它不参与调度正确性，不替代 orchestrator 调度账本，也不能让 dashboard 状态成为系统正确运行的前提。

## 核心实体

- `结构化日志`：记录动作、结果、工作项上下文、会话上下文和简短失败原因。
- `运行快照`：从 orchestrator 状态派生的只读运行、重试、用量和限流视图。
- `状态界面`：可选的人类可读运行视图。
- `运维入口`：可选的只读调试接口和即时刷新触发。
- `失败信号`：配置、tracker、workspace、hook、agent 和观测 sink 的 operator 可见错误。
- `Tracker 可见性`：展示 provider、scope、规范化状态、原生状态摘要、状态映射结果和 adapter 能力降级。

## 功能清单

- 输出启动、配置校验、候选读取、派发、workspace、hook、agent、重试和 reconciliation 日志。
- 为工作相关日志附加稳定的 issue 上下文。
- 为 tracker 相关日志附加 provider kind、provider scope、provider-scoped issue ID 和规范化状态。
- 为 agent session 生命周期日志附加稳定的 session 上下文。
- 控制日志体量，避免记录大型 raw payload 或 secret。
- 在日志 sink 失败时尽可能保持服务运行，并通过其他可用通道报告。
- 聚合 agent 用量和运行时长，避免重复计算。
- 跟踪最近的限流信息，供 operator 判断是否需要干预。
- 可选提供同步运行快照。
- 可选提供人类可读状态界面或 HTTP 扩展。
- 可选提供即时 refresh 触发，用于加快一次 poll 与 reconciliation。
- 暴露状态映射错误、GitHub pull request payload 过滤、GitLab project scope 冲突、阻塞关系能力缺失等 tracker adapter 诊断。

## 业务规则

- startup、validation 和 dispatch failures 必须对 operator 可见。
- tracker provider、scope、规范化状态和状态映射来源必须能在日志或状态界面中追踪，避免 operator 只看见一个脱离外部系统上下文的 issue 编号。
- GitHub/GitLab adapter 的能力降级必须可见，例如 blocker 读取失败、只能本地过滤状态、跨项目链接无权限或 API schema 不匹配。
- 状态界面只能从 orchestrator state 和 metrics 绘制，不能驱动 orchestrator logic。
- humanized agent event summary 如果实现，只能作为展示文本，不能成为状态判断依据。
- token 和 runtime 统计需要避免把重复上报或不同形态的 usage payload 当成累计事实。
- dashboard、snapshot、HTTP API 或日志 sink 失败不应 crash orchestrator。
- 可选 HTTP 扩展属于 observability/control surface，不是 conformance 所需核心。
- refresh 触发只请求一次 best-effort 轮询，不得绕过配置校验、并发限制或 issue eligibility。

## 用户交互流程

operator 通过 logs、状态界面或可选 API 观察 service health、running sessions、retry delays、token usage、rate limits 和 recent failures。遇到失败时，operator 可以修复 `WORKFLOW.md`、tracker credentials、provider scope、状态映射、issue state、workspace filesystem、hook scripts、Codex executable 或部署安全策略。

如果实现了 HTTP/API 扩展，operator 可以读取整体状态、查看单个 issue 的调试信息，并请求一次即时刷新。该入口只是运维辅助，不改变调度模型。
