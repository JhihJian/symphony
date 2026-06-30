# Agent Runner 集成

结论状态：SPEC 目标状态；当前项目已有实现代码（主要在 `elixir/`），但本次架构基线尚未逐项完成代码一致性审计可验证。

## 模块定位与边界

Agent Runner 集成模块负责把一个已派发的 issue 转换成实际的 coding agent 会话。它在对应 workspace 中启动 agent，发送任务说明，处理会话更新，并把结果和事件上报给 orchestrator。

该模块不决定 issue 是否可派发，不维护 retry queue，不判断 ticket 业务上是否完成，也不内置 ticket 写入规则。Codex app-server 的消息格式、传输 framing 和方法名以目标 Codex 版本为准；Symphony 只规定 workspace、prompt、continuation、超时和观测边界。

## 核心实体

- `运行尝试`：worker 对某个 issue 的一次执行上下文。
- `Agent 会话`：Codex app-server 进程、thread、turn 和最近事件的运行时记录。
- `任务说明`：由 workflow 模板、规范化 issue 信息、tracker provider/scope 和 attempt 信息渲染出的 prompt。
- `Continuation`：同一工作上下文中的后续 agent turn。
- `运行策略`：approval、sandbox、用户输入和可用工具的实现记录。

## 功能清单

- 为运行尝试请求 workspace 创建或复用。
- 在 agent 启动前执行运行前 hook。
- 使用严格模板渲染 issue prompt。
- 在 prompt context 中提供规范化工作项，并保留足够 provider 上下文，例如 tracker kind、provider scope、issue URL、provider-scoped identifier 和可用的原生状态摘要。
- 在当前 issue 的 workspace 中启动配置好的 Codex app-server。
- 按目标 Codex app-server 协议创建或恢复 agent thread。
- 第一次 turn 发送完整任务说明，后续 continuation 复用同一工作上下文。
- 从目标协议中提取可稳定关联日志和快照的会话身份。
- 处理 app-server stream，直到 turn 成功、失败、取消、超时或进程退出。
- 将会话开始、进展、失败、用量和限流等结构化事件上报给 orchestrator。
- 在运行结束时停止会话，并执行 best-effort 运行后 hook。
- 将 prompt、workspace、agent、协议和超时错误映射为可观察的 worker failure。

## 业务规则

- agent 进程工作目录必须是当前 issue 的 workspace。
- prompt 渲染失败立即使当前运行尝试失败，并交给 orchestrator 的重试逻辑。
- target Codex protocol 是协议形状的权威来源；SPEC 中的描述不能替代目标版本 schema。
- approval、sandbox、动态工具和用户输入策略由实现记录，但不得让运行无限期等待。
- unsupported dynamic tool call 应被明确拒绝或返回失败，避免会话卡住。
- 可选 tracker 工具属于 agent toolchain，不属于 orchestrator 业务写入逻辑。GitHub/GitLab 工具如果启用，必须继承当前 issue 的 provider scope 和凭据限制，不能默认获得组织级或 group 级写入范围。
- app-server 诊断输出应与协议流分离，除非目标协议另有要求。
- 各类超时、取消和进程退出必须形成 operator 可见的失败原因。

## 用户交互流程

orchestrator 派发 issue 后，Agent Runner 准备 workspace、执行运行前 hook、渲染 prompt、启动 Codex app-server，并把 stream 中的关键事件回传给 orchestrator。

agent 完成一轮后，worker 会按 SPEC 目标状态重新检查 issue 状态：如果 issue 仍需处理且仍在运行限制内，可以继续同一会话上下文；否则结束 worker，由 orchestrator 决定释放、重试或安排后续检查。

当 agent 请求审批、工具调用或人工输入时，Agent Runner 只能按实现记录的策略处理。operator 可以通过 workflow 配置、tracker 状态或外部控制渠道影响后续行为，但 worker 不允许无限等待。
