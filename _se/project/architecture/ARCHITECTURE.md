# Symphony 架构基线

来源：`SPEC.md`（草案 v1，语言无关），以及 GitHub/GitLab 官方 issue API 文档中与状态、阻塞关系和 issue 读取相关的外部依赖信息。

当前项目已有实现代码（主要在 `elixir/`）。本架构基线描述的是 SPEC 设定的目标状态，并补充 GitHub/GitLab issue 来源接入所需的架构扩展；本次同步未逐项完成实现一致性审计。凡是涉及行为、模块职责和安全规则的结论，都应理解为“架构要求或待审计的实现要求”；只有“输入来源为 SPEC、架构产物和官方 API 文档，且代码一致性尚待审计”属于本次已确认事实。

## 项目概览

Symphony 的目标是把 issue tracker 中的项目工作，稳定地交给 coding agent 执行。外部工作来源可以是 Linear、GitHub Issues 或 GitLab Issues，但进入调度器前必须先被规范化为同一种工作项语义。它不是通用工作流平台，也不是 ticket 写入系统；它的核心职责是读取可运行的工作、为每个工作准备隔离目录、启动 agent，并让 operator 能看见运行状态和失败原因。

系统边界可以用一句话概括：Symphony 负责调度、执行外壳和读取任务系统；每个 ticket 如何评论、改状态、关联 PR/MR 或交接给人，主要由仓库中的 workflow prompt 和 agent 可用工具决定。

本架构覆盖：

- 工作如何被发现、占用、运行、停止、重试和释放。
- 仓库 workflow 如何成为运行策略来源。
- 每个 issue 的 workspace 如何创建、复用和清理。
- agent 会话如何在 workspace 中启动，并把运行事件回传给调度器。
- operator 需要看到哪些健康、失败和用量信息。
- 必须守住的路径、密钥、hook 和审批边界。

本架构不覆盖：

- 具体实现语言、框架或部署拓扑。
- Linear/GitHub/GitLab 查询字段全集或 Codex app-server 协议消息格式。
- dashboard 页面布局、HTTP API 细节或测试用例清单。
- 每个配置字段、错误类别、默认值、排序细节或重试公式。

## 核心领域模型

Symphony 的核心对象围绕“一张外部 ticket 如何变成一次受控 agent 运行”组织。

`工作项` 是调度单位。它来自外部 issue tracker，提供足够的信息让系统判断是否可运行、是否被阻塞、如何识别对应 workspace，以及如何向 operator 展示当前工作。工作项的内部 ID 必须带有 tracker 类型和项目/仓库范围，避免 GitHub/GitLab 中同号 issue 在不同仓库或项目下发生冲突。

`Tracker 适配器` 是外部 issue 系统和 Symphony 调度语义之间的翻译层。Linear、GitHub 和 GitLab 的请求方式、分页、状态模型、阻塞关系和认证方式可以不同，但适配器必须输出同一种工作项模型、错误类型和能力说明。

`仓库工作流` 是项目规则入口。它由仓库拥有，包含 agent 要读到的任务说明，也包含影响后续调度和运行的设置。对 GitHub/GitLab 这类原生状态较粗的 tracker，仓库工作流还要明确状态来源和状态映射规则。它的意义不是替代代码实现，而是让团队把 workflow policy 随仓库版本化。

`调度账本` 是 orchestrator 在内存中维护的当前事实。它记录哪些工作正在运行、哪些工作已经被占用、哪些工作等待重试，以及 agent 最近上报的会话和用量信息。

`工作目录` 是 agent 的文件系统边界。每个工作项对应一个稳定目录，重试或继续执行时复用该目录；当工作进入终止状态时，系统可以清理它。

`运行尝试` 是把某个工作交给 agent 的一次执行过程。一次 ticket 可能经历多次运行尝试：正常完成一轮不等于 ticket 永久结束，失败、超时或无响应也会进入受控重试。

核心关系如下：

```text
仓库工作流 ──提供策略──> 调度器 ──派发──> 运行尝试 ──使用──> 工作目录
    │                         │                 │
    │                         │                 └──启动并观察──> coding agent
    │                         │
    └──影响后续运行            └──读取规范化工作项──> tracker 适配器 ──访问──> Linear/GitHub/GitLab
```

## 核心流程

Symphony 是一个持续运行的闭环。

启动时，服务读取仓库工作流并做调度前校验。如果配置不可用，启动应失败或停止派发新工作，并把原因暴露给 operator。启动还会根据外部任务系统中的终止状态清理遗留 workspace，避免重启后堆积过期目录。

每轮轮询先处理正在运行的工作。调度器会通过 tracker 适配器刷新这些工作的规范化状态，并处理长时间没有进展的 agent。如果某个工作已经终止，运行会被停止并清理 workspace；如果工作只是离开活动状态，运行会被停止但 workspace 会保留。

之后调度器读取候选工作，并在并发名额允许时派发。被派发的工作会先进入占用状态，防止同一个 issue 被重复启动。候选工作必须仍处于活动状态，不能已经运行或等待重试，也不能被仍未结束的依赖阻塞。GitHub/GitLab 适配器必须在此之前过滤或降级 provider 特有差异，例如 GitHub issue endpoint 中混入的 pull request、GitLab 项目内 issue 编号和标签驱动的工作流列。

一次运行尝试由 agent runner 执行。它准备 workspace，渲染 prompt，在该 workspace 中启动 coding agent，并把 agent 的关键事件回传给调度器。agent 完成一轮后，系统会重新检查 issue 状态；如果仍需要继续，可以在同一工作上下文中继续下一轮或安排后续检查。

失败、超时、无响应或 worker 异常退出都不会静默消失。调度器会记录可观察的失败原因，并把该工作放入受控重试路径。服务重启不会恢复内存中的运行、计时器或会话，只依靠 issue tracker 当前状态和保留的 workspace 重新发现可运行工作。

仓库工作流变更应被运行时重新读取。有效变更影响后续轮询、派发、hook、workspace 和 agent 启动；无效变更不能让服务崩溃，服务继续使用上一份可用配置并报告错误。

## 安全与权限

Symphony 的最低安全底线是：一个 agent 只能在当前 issue 的 workspace 内行动。这个边界不等同于完整沙箱，但它是所有实现都要先守住的基础规则。

必须长期成立的安全规则：

- agent 进程的工作目录必须是当前 issue 对应的 workspace。
- workspace 路径必须位于配置的 workspace root 之内，路径规范化后仍不能逃逸。
- workspace 目录名必须由 issue 标识安全转换而来，不能直接信任外部字符串。
- 密钥只能通过受控配置或显式环境变量引用进入运行时，日志不能打印密钥值。
- workflow hooks 来自仓库配置，视为受信脚本，但必须有超时和可见错误。
- approval、sandbox、工具调用和人工输入策略由实现记录，不能让运行无限期等待。

部署层还需要根据风险选择更严格的控制，例如专用系统用户、受限网络、容器或虚拟机隔离、较小的工具权限和较窄的 tracker 访问范围。这些是 deployment-specific 决策，不能从当前 SPEC 推断为已实现。

## 模块边界

- [Workflow 与配置](modules/workflow-and-configuration.md)：把仓库工作流转换为可校验、可热更新的运行策略。
- [Orchestrator](modules/orchestrator.md)：维护唯一调度账本，决定派发、停止、重试和释放。
- [Issue Tracker 集成](modules/issue-tracker-integration.md)：通过 tracker 适配器读取 Linear/GitHub/GitLab，并输出稳定的工作项模型。
- [Workspace 管理](modules/workspace-management.md)：负责 workspace 命名、路径安全、创建复用、hook 和清理。
- [Agent Runner 集成](modules/agent-runner-integration.md)：在 workspace 中启动 coding agent，管理会话并转发运行事件。
- [Observability 与运维](modules/observability-and-operations.md)：提供日志、快照、状态界面和 operator 可见错误。

依赖方向以 orchestrator 为中心：orchestrator 调用配置、tracker、workspace、agent runner 和 observability；下游模块返回事实、结果和事件，不反向修改调度账本。observability 只能观察系统，不能成为调度正确性的前提。

## 不变量

- 同一时间，一个工作项最多只能有一个运行尝试被占用。
- 调度账本只能由 orchestrator 统一修改。
- 每次派发新工作前，必须先处理正在运行工作的最新状态。
- 工作是否还能运行，以 issue tracker 中的当前状态为准。
- 调度器只依赖规范化工作项状态，不直接解释 Linear/GitHub/GitLab 原生 payload。
- tracker 适配器必须让 issue ID 和 workspace 命名来源具备 provider 与项目/仓库范围，不能只使用 GitHub/GitLab 的本地 issue 编号。
- 一次 agent 正常完成不代表 ticket 已经结束。
- 失败、超时、无响应和配置错误必须对 operator 可见。
- 重启不恢复内存中的运行、重试计时器或 live session。
- 仓库工作流是运行策略来源；无效热更新不能破坏正在运行的服务。
- workspace 路径安全检查必须在 agent 启动前完成。
- ticket 写入属于 workflow 和 agent 工具边界，不进入 orchestrator 核心逻辑；GitHub/GitLab 评论、状态修改、PR/MR 关联也遵守同一边界。
- Codex app-server 协议以目标 Codex 版本为准，Symphony 只定义自己的编排责任。
- 状态界面、dashboard 和 HTTP API 是观察或操作入口，不是正确性来源。

## 相关文件

- [术语表](glossary.md)
- [来源映射](source-map.md)
- [架构决策](decisions/README.md)
- [原始 SPEC](../../../SPEC.md)
