# 0007 Multi-Tracker Adapter Contract

## 状态

目标状态；当前项目已有实现代码（主要在 `elixir/`）。代码一致性审计按模块逐项记录时，可继续补充该决策的确认状态。该决策记录 multi-tracker adapter contract 的长期边界。

## 背景

早期规范叙述以 Linear issue 读取为主；当前 Symphony 的长期边界是 scheduler/runner/tracker reader，Linear、GitHub 和 GitLab 都能作为 issue 来源。它们的原生状态、唯一标识、分页、阻塞关系和写入语义各不相同，需要由 tracker adapter 负责 provider 翻译。

如果 orchestrator 直接理解每个 provider 的 payload 或状态差异，调度核心会持续膨胀，并且每接入一个 tracker 都要修改调度不变量。更稳妥的边界是让 tracker 集成层承担 provider 翻译，orchestrator 只消费规范化后的工作项。

## 决策

Issue Tracker 集成模块必须以 `TrackerAdapter` 为边界支持 Linear、GitHub 和 GitLab。每个 adapter 负责读取外部 issue、校验 provider 配置、处理分页和认证、规范化 payload、映射状态、填充可用阻塞关系，并把 provider 错误转换为 typed errors。

Orchestrator 只能依赖规范化工作项模型：provider-scoped `id`、人类可读 `identifier`、规范化 `state`、labels、priority、blocked_by 和时间字段。它不得直接解释 GitHub `open`、GitLab `opened`、Linear state、provider labels 或 provider 原始 payload。

GitHub/GitLab 的 issue 编号只在仓库或项目内唯一，因此内部 ID、claim key、retry key 和 workspace 命名来源必须包含 provider 与 owner/repo 或 project scope。GitHub issue endpoint 默认可能返回 pull request payload，GitHub adapter 必须默认过滤。

状态映射必须显式、确定且可校验。Linear 可以默认直接使用 tracker workflow state；GitHub 默认把 `open` 映射到 effective active set、`closed` 映射到 effective terminal set；GitLab 默认把 `opened` 映射到 effective active set、`closed` 映射到 effective terminal set。若团队使用 labels、issue fields、board column 或其他机制表达细粒度工作流，配置必须声明状态来源、优先级和 fallback。Provider 原生关闭状态优先于 label/field 派生状态。

阻塞关系属于调度语义，但不是所有 provider、token 或部署都一定可读。adapter 必须声明 blocker 能力；能力不足时按 workflow 配置 fail-closed、fail-open 或 warning-only。若 workflow 启用了 blocker rule 且没有显式降级策略，默认应 fail-closed，不能把读取失败伪装成“没有 blocker”。

## 影响

- 新 tracker 接入主要新增 adapter 和配置校验，不应修改 orchestrator 状态机。
- GitHub/GitLab 的状态差异通过状态映射解决，而不是把 Linear 状态模型强加给所有 provider。
- Workspace、claim 和 retry 逻辑必须使用 provider-scoped key，避免跨仓库或跨项目冲突。
- Observability 需要展示 provider、scope、规范化状态和能力降级，便于 operator 判断是配置问题、权限问题还是外部 API 行为差异。
- Tracker writes 继续属于 agent toolchain extension；GitHub/GitLab 评论、状态修改、PR/MR metadata 关联不进入 orchestrator 核心。

## 来源

- `SPEC.md` §1
- `SPEC.md` §4.1.1
- `SPEC.md` §4.2
- `SPEC.md` §11
- [GitHub REST API issues documentation](https://docs.github.com/en/rest/issues/issues)
- [GitHub REST API issue dependencies documentation](https://docs.github.com/en/rest/issues/issue-dependencies)
- [GitLab Issues API documentation](https://docs.gitlab.com/api/issues/)
- [GitLab Issue links API documentation](https://docs.gitlab.com/api/issue_links/)
