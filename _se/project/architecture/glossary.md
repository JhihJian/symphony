# 术语表

当前项目已有实现代码（主要在 `elixir/`），但本次架构基线尚未逐项完成代码一致性审计，以下术语来自 `SPEC.md` 并按架构文档用途降噪整理。

| 术语 | 含义 | 状态 | 来源 |
|---|---|---|---|
| Symphony | 长期运行的 coding-agent orchestration service，读取 issue、准备 workspace 并启动 agent。 | 目标状态 | `SPEC.md` §1, §3.1 |
| Issue / 工作项 | 从 tracker payload 规范化出的调度单位。 | 目标状态 | `SPEC.md` §4.1.1 |
| Issue ID | tracker 内部稳定 ID，用于查询和内部 map key。 | 目标状态 | `SPEC.md` §4.2 |
| Issue Identifier | 人类可读 ticket key，用于日志、标题和 workspace 命名来源。 | 目标状态 | `SPEC.md` §4.2 |
| Workflow / 仓库工作流 | 仓库拥有的运行契约，包含 agent 任务说明和运行设置。 | 目标状态 | `SPEC.md` §5 |
| Prompt 模板 | workflow Markdown 正文形成的 agent 任务说明模板。 | 目标状态 | `SPEC.md` §5.4, §12 |
| Service Config / 运行设置 | 从 workflow 配置、默认策略和显式环境变量引用派生出的类型化设置。 | 目标状态 | `SPEC.md` §4.1.3, §6 |
| Orchestrator / 调度器 | 拥有轮询、占用、运行、重试和 reconciliation 状态的协调组件。 | 目标状态 | `SPEC.md` §3.1, §7 |
| 调度账本 | orchestrator 维护的唯一内存调度状态。 | 目标状态 | `SPEC.md` §4.1.8, §7 |
| Claim / 工作占用 | 防止同一 issue 被重复派发的内部保留状态。 | 目标状态 | `SPEC.md` §7.1 |
| Run Attempt / 运行尝试 | 某个 issue 的一次 worker/agent 执行过程。 | 目标状态 | `SPEC.md` §4.1.5, §7.2 |
| Retry Entry / 重试项 | 等待后续尝试的 issue retry 记录。 | 目标状态 | `SPEC.md` §4.1.7, §8.4 |
| Reconciliation | 每轮派发前刷新运行中 issue 状态并处理终止、非活动和 stall 的过程。 | 目标状态 | `SPEC.md` §7.3, §8.5 |
| Workspace / 工作目录 | 分配给 issue 的文件系统目录，是 agent 的工作边界。 | 目标状态 | `SPEC.md` §4.1.4, §9 |
| Workspace Key | 从 issue identifier 转换出的安全目录名。 | 目标状态 | `SPEC.md` §4.2, §9.5 |
| Hook / 生命周期脚本 | workflow 中定义、围绕 workspace 创建、运行和删除执行的脚本。 | 目标状态 | `SPEC.md` §5.3.4, §9.4 |
| Agent Runner | 包装 workspace、prompt 和 Codex app-server client 的执行模块。 | 目标状态 | `SPEC.md` §3.1, §10.7 |
| Agent 会话 | coding-agent app-server 进程、thread、turn 和最近事件的运行时记录。 | 目标状态 | `SPEC.md` §4.1.6, §10 |
| Continuation | 同一工作上下文中对 agent thread 的后续继续执行。 | 目标状态 | `SPEC.md` §7.1, §10.3 |
| Linear Adapter | 当前 SPEC 目标中的 Linear-compatible tracker 读取适配器。 | 目标状态 | `SPEC.md` §11 |
| Tracker Writes | ticket 状态转换、评论和 PR metadata 等写入动作。 | 目标状态 | `SPEC.md` §1, §11.5 |
| Handoff State | workflow 定义的成功交接状态，不必等同于 tracker 终止状态。 | 目标状态 | `SPEC.md` §1, §11.5 |
| Status Surface | 可选的人类可读运行状态界面。 | 目标状态 | `SPEC.md` §3.1, §13.4 |
| Runtime Snapshot | 可选的同步监控视图，读取运行、重试、用量和限流摘要。 | 目标状态 | `SPEC.md` §13.3 |
| Harness Hardening | approval、sandbox、OS/container/VM、网络和凭据范围等部署安全控制。 | 待确认 | `SPEC.md` §15 |
