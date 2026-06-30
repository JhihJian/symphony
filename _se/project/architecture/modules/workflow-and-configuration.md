# Workflow 与配置

结论状态：SPEC 目标状态。2026-06-22 巡检确认当前 Elixir schema 已支持 tracker kind、endpoint、scope、required labels、active/terminal states、GitHub project 字段等基础配置；`state_source`、`state_mapping`、`blocker_policy` 仍是架构目标，尚未作为独立 schema 字段落地。

## 模块定位与边界

Workflow 与配置模块负责把仓库中的 `WORKFLOW.md` 转换为 Symphony 后续运行可使用的策略。它是项目规则进入服务的入口，也是动态调整后续运行行为的边界。对 GitHub/GitLab 接入而言，它还负责把 provider scope、状态来源和状态映射表达成可校验的运行策略。

该模块只负责文件定位、读取、解析、类型化、校验和热更新。它不选择 issue，不访问 tracker，不创建 workspace，不启动 agent，也不解释 Codex app-server 协议。和 agent 相关的配置在这里形成有效设置，具体启动和协议行为由 Agent Runner 处理。

## 核心实体

- `工作流文件`：仓库拥有的 Markdown 文件，承载运行设置和 agent 任务说明。
- `Prompt 模板`：从 Markdown 正文得到的任务说明模板，用于每个 issue 的 agent 输入。
- `运行设置`：从工作流配置、默认策略和显式环境变量引用得到的类型化视图。
- `Tracker Source 设置`：tracker kind、endpoint、认证来源、provider scope、状态来源、状态映射和能力要求。
- `配置校验结果`：调度前判断是否可以继续派发新工作的依据。
- `上一份可用配置`：热更新失败时继续运行所需的有效配置快照。

## 功能清单

- 按运行时指定路径或默认位置定位 workflow 文件。
- 解析可选 front matter 和 Markdown 正文，并拒绝结构不符合契约的配置。
- 将缺失的可选设置补齐为实现定义的有效值。
- 只解析配置中显式声明的环境变量引用，不让环境变量全局覆盖仓库配置。
- 对本地路径做必要规范化，并避免把命令或 URI 当作路径改写。
- 生成严格模板，确保未知变量或未知过滤器在渲染时暴露为错误。
- 监控 workflow 文件变更，并在无需重启的情况下重新读取和应用。
- 为 orchestrator 提供调度前校验结果，覆盖 tracker、workspace、hook、并发、重试和 agent 启动所需的最低配置。
- 校验 Linear、GitHub、GitLab 各自必需的 scope 和认证来源，例如 Linear project、GitHub owner/repo、GitLab project/group。
- 校验 GitHub/GitLab 的状态来源和状态映射，确保规范化调度状态能和 active/terminal states 做确定性比较。
- 记录 tracker adapter 能力要求，例如是否必须读取 blockers、是否允许 provider-side 过滤降级为本地过滤。

## Tracker 配置契约

`tracker.kind` 至少支持 `linear`、`github` 和 `gitlab`。配置层输出给 tracker adapter 的 typed view 应包含：

- `kind`、`endpoint`、认证引用和 provider scope。
- `active_states`、`terminal_states` 和状态比较所需的规范化规则。
- `state_source` 或等价设置，用于说明规范化状态来自 provider native state、label、issue field、board column 还是 provider adapter 默认映射。
- `state_mapping`，用于把 provider 原生状态或标签/字段值映射为 Symphony 的规范化调度状态。
- `blocker_policy`，用于定义阻塞关系不可读时是阻止派发、允许派发但告警，还是把 blocker 视为空。

Provider-specific 最小 scope：

- Linear：project 或等价查询范围；默认 endpoint 可以来自 Linear GraphQL endpoint；认证默认环境变量可以是 `LINEAR_API_KEY`。
- GitHub：`owner` 和 `repo`；默认 endpoint 可以来自 GitHub REST API；认证默认环境变量可以是 `GITHUB_TOKEN` 或实现记录的 GitHub App token 引用。
- GitLab：project path/id；group scope 是可选扩展；默认 endpoint 可以来自 GitLab REST API base URL；认证默认环境变量可以是 `GITLAB_TOKEN`。

默认状态映射：

- Linear：直接使用 Linear workflow state 作为规范化调度状态。
- GitHub：`open` 映射为活动候选状态，`closed` 映射为终止状态；更细状态必须由 label、issue field 或配置规则派生。
- GitLab：`opened` 映射为活动候选状态，`closed` 映射为终止状态；更细状态必须由 label、board 或配置规则派生。

GitHub/GitLab 默认映射生成的活动和终止状态名必须进入 effective `active_states` 和 `terminal_states`。实现可以选择 `open`/`closed`、`opened`/`closed` 或更项目化的命名，但配置层必须保证 orchestrator 拿到的是可比较的规范化状态集合。

`blocker_policy` 的默认值应偏保守：当 workflow 启用了 blocker rule，而 provider adapter 不能确认 blockers 时，配置校验应阻止新派发或要求 operator 显式选择 warning-only/fail-open。

配置层不需要把 GitHub/GitLab 所有 API 参数暴露为核心 schema。筛选字段、排序、分页模式和 provider-specific 查询优化应停留在 adapter 或 provider extension 中；只有会影响调度语义、权限范围或安全边界的字段才进入核心 typed view。

## 业务规则

- workflow 文件缺失、读取失败、front matter 解析失败或结构错误，都必须形成 operator 可见的配置错误。
- 启动阶段配置不可用时，不应进入正常调度。
- 运行中配置变更无效时，不得让服务崩溃；后续运行继续使用上一份可用配置。
- 读取和解析 workflow 的错误会阻止新的派发，但不应阻止 orchestrator 继续处理已运行工作的 reconciliation。
- prompt 渲染错误只影响对应运行尝试，不应静默退回到不受仓库控制的任务说明。
- unknown 配置扩展可以被忽略以保持前向兼容，但扩展本身需要记录 schema、默认值、校验和是否支持热更新。
- 热更新影响未来行为；SPEC 不要求自动重启已经运行中的 agent 会话。
- `tracker.kind` 至少覆盖 `linear`、`github` 和 `gitlab`。每种 provider 的默认 endpoint、规范认证变量和必填 scope 必须由配置层类型化，而不是散落在适配器调用点。
- 对 GitHub/GitLab，若使用 labels、issue fields 或 board 约定表达 workflow state，配置必须声明状态来源、匹配规则、优先级和 fallback；缺失或冲突的规则应阻止新派发。
- 原生关闭状态和 terminal states 的关系必须可校验。即使 label/field 仍显示活动状态，GitHub `closed` 和 GitLab `closed` 也必须能被映射为终止或不可运行状态。

## 用户交互流程

operator 通过编辑 `WORKFLOW.md` 调整任务说明、tracker 范围、状态映射、活动和终止状态、workspace 位置、hook、并发、重试和 agent 启动策略。服务检测到变更后重新加载：有效变更作用于后续 tick、retry、hook 和 agent launch；无效变更被记录，服务继续使用上一份可用配置。

启动服务时，operator 可以传入显式 workflow 路径；未传入时使用默认位置。路径缺失或配置不满足派发前置条件时，应得到清晰的启动或运行时错误。
