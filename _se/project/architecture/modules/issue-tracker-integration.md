# Issue Tracker 集成

结论状态：SPEC 目标状态，并补充 GitHub/GitLab issue 来源接入的架构扩展。2026-06-22 巡检确认当前 Elixir 实现已包含 GitHub/GitLab adapter、client、agent-side tracker tools 和相关 E2E/contract 测试；provider-scoped GitHub issue ID、blocker capability/policy、以及部分状态映射规则仍是架构目标或待修复漂移。

## 模块定位与边界

Issue Tracker 集成模块负责从外部任务系统读取 Symphony 可调度的工作，并把外部 payload 转换为稳定的内部工作项模型。它的核心是 `TrackerAdapter` 契约，而不是某一个 provider 的 API 形状。

当前 SPEC 版本以 Linear-compatible 读取作为原始目标状态；架构扩展要求同一边界完整支持 GitHub Issues 和 GitLab Issues。Linear、GitHub 和 GitLab 适配器可以改变通信细节、认证方式、分页策略、状态来源和阻塞关系读取方式，但交给 orchestrator 的工作项语义必须一致。该模块不决定派发策略，不运行 agent，不管理 workspace，也不承担 ticket 写入业务。

## 核心实体

- `工作项`：从 tracker 读取并规范化后的调度单位。
- `Tracker Adapter`：按 provider 实现候选读取、状态刷新、终止集合读取、payload 规范化、能力声明和错误映射的边界对象。
- `Provider Scope`：限定 issue 唯一性和 API 访问范围的外部位置，例如 Linear project、GitHub owner/repo、GitLab project 或 group。
- `Provider Native State`：外部系统原生状态。Linear 通常是团队定义的 workflow state；GitHub REST issue 原生状态是 `open`/`closed`；GitLab issue 原生状态是 `opened`/`closed`。
- `规范化调度状态`：orchestrator 使用的 `issue.state`。它由适配器根据 provider native state、labels、字段或配置映射得到，不等同于所有 provider 的原生状态。
- `状态集合`：配置中的活动状态和终止状态，用于候选读取、reconciliation 和 cleanup，比较对象是规范化调度状态。
- `阻塞关系`：用于辅助判断工作是否暂时不能运行。
- `Tracker 配置`：连接外部系统所需的类型、范围和认证来源。
- `Tracker 错误`：认证、网络、schema、分页或 payload 异常形成的可观察错误。
- `能力说明`：适配器暴露其是否支持阻塞关系、provider-side 过滤、批量刷新、跨项目链接、状态字段等能力；缺失能力必须可观察，不能伪装成完整数据。

## 功能清单

- 读取活动状态中的候选工作。
- 读取指定状态集合中的工作，用于启动清理。
- 按 issue ID 刷新正在运行工作的当前状态。
- 将外部 tracker payload 规范化为 Symphony 的工作项模型。
- 隔离 provider-specific 查询构造、分页处理和 API schema 漂移。
- 根据配置把 provider native state、labels 或可用字段映射为规范化调度状态。
- 规范化 labels、priority、阻塞关系和时间字段等调度所需信息。
- 将 tracker 认证、请求、响应结构和 payload 异常映射为 typed errors。
- 为可选 agent-side tracker tool 提供受控认证来源，而不是让 agent 自行读取密钥。
- 为 operator 暴露 provider scope、状态映射、能力缺失和过滤降级的错误或 warning。

## 适配器契约

每个 tracker 适配器必须提供同一组调度能力：

- 校验 provider 类型、endpoint、scope、认证来源、状态映射和能力要求。
- 根据活动状态策略读取候选工作，或在 provider 不能按目标状态精确过滤时读取较粗集合后本地过滤。
- 根据终止状态策略读取可清理工作；如果 provider 只能按原生关闭状态查询，必须明确记录映射和降级。
- 按 provider-scoped issue ID 刷新正在运行工作。
- 输出稳定的内部工作项模型，其中 `id` 是 provider-scoped 内部 key，`identifier` 是人类可读且尽量 provider-scoped 的展示 key。
- 将 provider 原始错误归类为认证、权限、范围、限流、网络、schema、payload、能力不支持或 not found/gone。

`issue.state` 是规范化调度状态。对于 Linear，它通常直接来自 Linear workflow state；对于 GitHub/GitLab，最低可用映射是原生打开状态进入默认活动状态、原生关闭状态进入默认终止状态。默认状态名可以由实现定义，但必须落入配置层输出的 `active_states` 或 `terminal_states`，不能生成一个调度器无法比较的临时状态。如果团队使用 label、issue field、board column 或其他机制表达工作流阶段，配置必须给出确定性来源、优先级和 fallback。多个状态来源冲突时，provider 原生关闭状态优先使工作终止。

## Provider 规则

### Linear

Linear adapter 延续原始 SPEC 目标：通过 Linear-compatible 查询读取候选、终止集合和按 ID 刷新，并把 Linear state 作为默认规范化调度状态。Linear-specific 查询、分页、认证和 payload validation 必须留在适配器内部。

### GitHub

GitHub adapter 以 repository scope 为最小稳定边界。GitHub issue number 只在 repository 内唯一，因此内部 `id` 和 workspace 命名来源必须包含 GitHub provider、owner/repo 和 issue number 或 node id。

GitHub REST issue endpoint 的原生状态是 `open`、`closed` 或查询时的 `all`，关闭时可带 `state_reason`。候选读取的默认映射应把 `open` 视为活动，把 `closed` 视为终止；如果配置使用 labels 或 GitHub issue fields 形成更细的工作流状态，adapter 必须先排除原生 `closed` 后再应用这些状态映射。

GitHub REST issue endpoint 可能返回 pull request，因为 GitHub REST API 把 pull request 也视为 issue。GitHub adapter 必须默认排除带 `pull_request` 标记的 payload，除非未来明确引入“PR 作为工作项”的扩展。

GitHub issue dependencies API 可以读取某个 issue 被哪些 issue 阻塞以及它正在阻塞哪些 issue。adapter 可以用该能力填充 `blocked_by`；如果 token 权限、仓库设置或 API 可用性不足，应报告能力降级，并按配置选择失败或把 blockers 视为空。

### GitLab

GitLab adapter 以 project scope 为最小稳定边界，也可以由实现扩展到 group scope。GitLab `iid` 只在 project 内唯一，因此内部 `id` 和 workspace 命名来源必须包含 GitLab provider、project path/id 和 issue iid，不能只使用 `#123`。

GitLab Issues API 的原生状态是 `opened`、`closed` 或查询时的 `all`。候选读取的默认映射应把 `opened` 视为活动，把 `closed` 视为终止；如果团队用 labels 或 issue board 约定表达 workflow 阶段，adapter 必须通过配置把 label 集合映射为规范化调度状态，并定义多个标签同时命中时的优先级。

GitLab issue links API 支持 `relates_to`、`blocks` 和 `is_blocked_by` 关系。adapter 可以用该能力填充 `blocked_by`；跨项目关系、权限不足或版本能力差异必须作为能力降级或 typed error 暴露。

## 业务规则

- tracker 读取失败时，模块返回错误；是否跳过本轮、保留 worker 或继续启动由 orchestrator 决定。
- 候选读取失败会阻止本轮新派发，但不应让服务崩溃。
- 运行中状态刷新失败时，应允许 worker 暂时继续运行，等待下一轮 reconciliation。
- 启动清理读取失败时，应报告 warning 并继续启动。
- 空状态集合不应触发无意义外部 API 调用。
- Provider 查询细节可能随外部 schema 漂移，因此查询构造应隔离，并围绕必须字段和类型建立验证。
- Provider 原生状态和规范化调度状态必须分层；orchestrator 不能直接解释 `open`、`opened`、`closed`、Linear state 或 provider-specific label。
- 对 GitHub/GitLab，provider 原生关闭状态必须优先于 label/field 派生的活动状态，避免已关闭 issue 被重新派发。
- 对 GitHub/GitLab，issue 编号必须带 repository/project scope 才能进入内部 key、claim map、retry map 和 workspace key。
- 阻塞关系是可调度语义的一部分，但 provider 能力可能缺失。能力缺失时必须按 workflow 配置选择 fail-closed、fail-open 或 warning-only；如果 workflow 使用 blocker rule 且没有显式降级策略，默认应阻止新派发并报告配置或能力错误，而不是把“没有读到 blockers”伪装成“确认没有 blockers”。
- tracker writes 不是 core required API；如果提供给 agent，也属于受控 toolchain extension。

## 用户交互流程

operator 通过 `WORKFLOW.md` 配置 tracker 类型、认证来源、项目/仓库范围、状态来源、活动状态和终止状态。orchestrator 在轮询、重试、reconciliation 和启动清理中调用该模块。

当 tracker API、认证、项目范围或 payload 出错时，operator 应通过 structured logs 或 status surface 看见失败类别，并通过修复 credentials、workflow 配置、网络或外部 tracker 状态恢复派发。
