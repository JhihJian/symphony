# 0001 Repository-Owned Workflow Contract

## 状态

目标状态；当前项目已有实现代码（主要在 `elixir/`），但本次架构基线尚未逐项完成代码一致性审计可验证。

## 背景

Symphony 需要让团队把 agent prompt、tracker selection、运行设置和 workspace hooks 随仓库一起版本化。它还需要在 daemon 运行时接受 workflow 调整，避免每次修改任务策略都重启服务。

如果这些规则散落在进程启动参数、外部配置或 agent 内部逻辑中，调度服务就很难知道当前策略来自哪里，团队也难以审查一次 workflow 变更对后续运行的影响。

## 决策

使用仓库拥有的 `WORKFLOW.md` 作为 workflow contract。该文件同时承载 agent 任务说明和影响后续运行的配置。

服务按该 contract 读取、解析、校验和渲染 workflow，并监控文件变更。有效变更作用于后续派发、重试、hook 和 agent 启动；无效变更不应让服务崩溃，而是继续使用上一份可用配置并报告错误。

## 影响

- workflow policy 可以随代码版本化和审查。
- operator 可以通过编辑仓库文件调整后续运行行为。
- 配置层必须维护 last-known-good effective configuration。
- 扩展配置可以存在，但扩展方需要记录 schema、默认值、校验和热更新语义。

## 来源

- `SPEC.md` §1
- `SPEC.md` §5
- `SPEC.md` §6
