# Issue Tracker 集成

结论状态：SPEC 目标状态；当前项目已有实现代码（主要在 `elixir/`），但本次架构基线尚未逐项完成代码一致性审计可验证。

## 模块定位与边界

Issue Tracker 集成模块负责从外部任务系统读取 Symphony 可调度的工作，并把外部 payload 转换为稳定的内部工作项模型。

当前 SPEC 版本以 Linear-compatible 读取作为目标状态。非 Linear 适配器可以改变通信细节，但交给 orchestrator 的工作项语义必须一致。该模块不决定派发策略，不运行 agent，不管理 workspace，也不承担 ticket 写入业务。

## 核心实体

- `工作项`：从 tracker 读取并规范化后的调度单位。
- `状态集合`：配置中的活动状态和终止状态，用于候选读取、reconciliation 和 cleanup。
- `阻塞关系`：用于辅助判断工作是否暂时不能运行。
- `Tracker 配置`：连接外部系统所需的类型、范围和认证来源。
- `Tracker 错误`：认证、网络、schema、分页或 payload 异常形成的可观察错误。

## 功能清单

- 读取活动状态中的候选工作。
- 读取指定状态集合中的工作，用于启动清理。
- 按 issue ID 刷新正在运行工作的当前状态。
- 将外部 tracker payload 规范化为 Symphony 的工作项模型。
- 隔离 Linear-specific 查询构造和分页处理。
- 规范化 labels、priority、阻塞关系和时间字段等调度所需信息。
- 将 tracker 认证、请求、响应结构和 payload 异常映射为 typed errors。
- 为可选 agent-side tracker tool 提供受控认证来源，而不是让 agent 自行读取密钥。

## 业务规则

- tracker 读取失败时，模块返回错误；是否跳过本轮、保留 worker 或继续启动由 orchestrator 决定。
- 候选读取失败会阻止本轮新派发，但不应让服务崩溃。
- 运行中状态刷新失败时，应允许 worker 暂时继续运行，等待下一轮 reconciliation。
- 启动清理读取失败时，应报告 warning 并继续启动。
- 空状态集合不应触发无意义外部 API 调用。
- Linear 查询细节可能随外部 schema 漂移，因此查询构造应隔离，并围绕必须字段和类型建立验证。
- tracker writes 不是 core required API；如果提供给 agent，也属于受控 toolchain extension。

## 用户交互流程

operator 通过 `WORKFLOW.md` 配置 tracker 类型、认证来源、项目范围、活动状态和终止状态。orchestrator 在轮询、重试、reconciliation 和启动清理中调用该模块。

当 tracker API、认证、项目范围或 payload 出错时，operator 应通过 structured logs 或 status surface 看见失败类别，并通过修复 credentials、workflow 配置、网络或外部 tracker 状态恢复派发。
