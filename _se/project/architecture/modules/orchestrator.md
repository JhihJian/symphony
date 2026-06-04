# Orchestrator

结论状态：SPEC 目标状态；当前项目已有实现代码（主要在 `elixir/`），但本次架构基线尚未逐项完成代码一致性审计可验证。

## 模块定位与边界

Orchestrator 是 Symphony 的调度核心。它维护唯一的内存调度账本，并把外部状态、worker 结果和重试计时转换为明确的调度动作。

Orchestrator 不解析 workflow 文件，不直接写 ticket，不实现 tracker API，不管理文件系统细节，不解释 Codex 协议，也不提供 dashboard 状态本身。它调用这些模块，接收它们返回的事实和事件，然后统一修改调度账本。Linear、GitHub、GitLab 的差异必须在 tracker 适配器和配置层处理完毕，不能泄漏为 orchestrator 分支逻辑。

## 核心实体

- `调度账本`：记录 running、claimed、retrying、完成记录、会话摘要和用量累计的内存状态。
- `工作占用`：防止同一 issue 被重复派发的内部保留状态。
- `运行尝试`：一次 worker 对一个 issue 的执行。
- `重试计划`：失败、继续检查或名额不足时安排的后续尝试。
- `运行快照`：供日志、状态界面或监控读取的只读状态视图。

## 功能清单

- 启动时初始化调度账本，并安排第一轮轮询。
- 每轮先 reconciliation 正在运行的工作，再派发新的候选工作。
- 根据当前配置和运行状态判断并发容量。
- 从 tracker 适配器返回的规范化候选集中选择仍可运行且未被占用的工作。
- 在启动 worker 前建立 claim，避免重复派发。
- 接收 agent runner 的会话事件，更新最近事件、用量和限流摘要。
- 处理 worker 正常结束、异常结束、取消、超时和无响应。
- 为失败或需要继续检查的工作安排后续尝试。
- 在 tracker 状态变化后停止不再应运行的 worker，并决定是否清理 workspace。
- 向 observability 模块发布状态变化和失败原因。

## 业务规则

- Orchestrator 是唯一可以修改调度账本的组件。
- 启动 worker 前必须确认 issue 未在运行、未被占用、仍处于活动范围内，并且没有违反阻塞规则。
- Orchestrator 只比较规范化调度状态和配置中的 active/terminal sets；不得直接解释 GitHub `open`、GitLab `opened`、Linear workflow state 或 provider label。
- Claim、running 和 retry map 的 key 必须使用 tracker 适配器提供的 provider-scoped issue ID。
- 新工作派发前必须先处理正在运行工作的 tracker 状态和 agent 活性。
- 外部 tracker 的当前状态决定一个工作是否还应运行；本地 completed 记录只用于 bookkeeping。
- 正常完成一轮 worker 不代表 issue 永久结束，仍可能需要继续检查或继续运行。
- worker failure、prompt failure、hook failure、agent timeout 和 stall 都进入可观察的失败与重试路径。
- retry 到期后必须重新确认 issue 仍在候选集中；如果已经消失或不再符合条件，应释放 claim。
- tracker refresh 失败时不应贸然停止正在运行的 worker，而应报告错误并等待下一轮重试。
- 进程重启后不恢复 live session、running map 或 retry timer；恢复依赖 tracker 当前状态和保留 workspace。

## 用户交互流程

operator 通常不直接编辑调度账本，而是通过两类外部动作影响 orchestrator。

编辑 `WORKFLOW.md` 会改变后续轮询节奏、活动和终止状态、并发、重试、workspace、hook 和 agent 启动策略。修改 tracker issue 状态会在 reconciliation 中生效：终止状态停止运行并触发 workspace 清理，非活动状态停止运行但保留 workspace，活动状态则使 issue 保持或重新进入候选集合。

如果实现了手动刷新接口，它只能触发一次即时 poll 与 reconciliation，不能绕过调度规则或修改正确性模型。
