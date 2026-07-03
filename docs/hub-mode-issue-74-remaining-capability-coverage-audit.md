# Hub mode Issue #74 remaining capability coverage audit baseline

本文档是 #199 的仓库内覆盖审计基线，审计对象是 #74
`Add Symphony Hub mode for device-level multi-project coordination` 的原始目标和验收标准。它把 #74
已经拆分交付的 issue、PR、代码模块、测试和文档证据归到同一张矩阵，帮助 Owner 判断 Hub mode
是否 closure-ready，以及后续哪些迁移方向应另行开票。

本审计的边界是证据整理和差距判断：#74 的关闭动作仍由 Owner 执行，#171/#172 closure report
大范围恢复、Hub Runtime/API/Dashboard 行为变更，以及 provider、dispatch、worker starter、
writeback、systemd、workspace hook、配置修改路径调用，均留在后续明确授权的工作范围内。#205 交付的
[`docs/hub-mode-issue-74-closure-decision-packet.md`](hub-mode-issue-74-closure-decision-packet.md)
把本审计的 remaining gaps 收束为 #74 closure decision packet。

## 审计范围

- 原始 epic：#74，当前仍是 Hub mode 的总目标来源。
- 已交付切片：#75/#77/#79/#87/#89/#91/#94/#97/#99/#101/#103/#105/#108/#110/#112/#114/#117/#119/#121/#123/#125/#127/#129/#131/#133/#135/#137/#140/#142/#144/#146/#148/#150/#152/#154/#156/#158/#160/#165/#167/#169/#173/#175/#177/#179/#181/#183/#185/#187/#189/#191/#193/#195/#197。
- 主要 PR 证据：#76/#78/#84/#88/#90/#92/#93/#95/#96/#98/#100/#102/#104/#106/#107/#109/#111/#113/#115/#118/#120/#122/#124/#126/#128/#130/#132/#134/#138/#139/#141/#143/#145/#147/#149/#151/#153/#155/#157/#159/#164/#166/#168/#170/#174/#176/#178/#180/#182/#184/#186/#188/#190/#192/#194/#196/#198。
- #135 的首个 PR #136 已由 #137 / PR #138 回滚；本审计把 #135 的有效 Dashboard 明细证据记为后续
  PR #139。
- #171/#172 closure report 历史大票据已经由 #197 建立局部覆盖审计，并由 Owner 关闭；本文件只把该
  结论作为 #74 的一个证据来源，不重新审计 #171/#172 全量细节。
- #199/#201/#203/#205 是 #74 关闭前的审计和决策证据链：coverage audit、provider exit residual
  decision baseline、restart/replay safe fixture baseline 和 closure decision packet。

本文件只引用 issue/PR 编号、仓库路径、字段名和本地验证命令；证据口径保持脱敏，不引用 token、
Authorization/cookie、secret env、raw provider payload、完整 prompt/transcript、完整 PR/comment body、
本机私有路径或异常栈。

## 覆盖状态定义

- `covered`：已有代码、测试或可复现文档证据足以支撑该 #74 验收点。
- `closure_ready`：证据和裁定已经足以支持 Owner 做 #74 baseline 关闭决策，但关闭动作仍由 Owner 执行。
- `partially_covered`：历史审计状态，表示已有基础能力，但还缺明确能力、迁移裁定、统一验证或持久化/restart 证明。
- `scoped_non_goal`：该能力已被拆分或裁定为当前 Hub baseline 的范围外，后续如需建设应单独开票。
- `remaining_gap`：历史审计状态，表示当时仓库仍缺少后续最小 issue 才能完成该验收点或关闭判断。
- `owner_decision_needed`：历史审计状态，表示代码、测试和文档证据已经可审查，但需要 Owner 决定关闭、降级或再拆分。

## #74 原始目标映射

#74 的一句话目标是：项目仍独立，轮询不独立；provider API 访问统一排队，agent 运行统一派发，状态统一观测。
它的验收标准可以归并为八组能力：

1. 设备级 Hub 运行模式。
2. 多项目注册与配置快照。
3. 统一 provider 请求治理。
4. 可恢复运行账本。
5. 原子派发与 agent 生命周期管理。
6. provider 写回 intent/result、去重和 unknown/manual attention 处理。
7. Hub mode 与 legacy 多实例模型的迁移边界。
8. Dashboard/API 的设备级总览和项目级明细。

原始 #74 还要求 provider poll 不再由多个项目独立拥有、慢 provider 请求不能拖住全局调度、同一 issue
不能重复 active attempt、同一逻辑写回不能跨 attempt 产生第二个外部副作用、重启后能恢复或解释运行事实，
以及 Dashboard/API 能解释暂停、退避、限流、workspace 占用、写回未知和 manual attention 等 backpressure。

## 拆分交付索引

| 能力组 | Issue / PR | 主要仓库证据 |
| --- | --- | --- |
| 项目身份、配置快照、IssueRef | #75 / PR #76 | `elixir/lib/symphony_elixir/hub/project_registry.ex`、`elixir/lib/symphony_elixir/hub/issue_ref.ex`、`elixir/test/symphony_elixir/hub_project_registry_test.exs`、`elixir/test/symphony_elixir/hub_issue_ref_test.exs` |
| 可恢复运行账本事实模型 | #77 / PR #78 | `elixir/lib/symphony_elixir/hub/runtime_ledger.ex`、`elixir/test/symphony_elixir/hub_runtime_ledger_test.exs` |
| provider request governance baseline | #79 / PR #84 | `elixir/lib/symphony_elixir/hub/provider_governance.ex`、`elixir/test/symphony_elixir/hub_provider_governance_test.exs` |
| Hub poll coordination | #87 / PR #88，#89 / PR #90 | `elixir/lib/symphony_elixir/hub/poll_coordinator.ex`、`elixir/test/symphony_elixir/hub_poll_coordinator_test.exs` |
| Hub runtime entrypoint、poll tick、scheduler | #101 / PR #102，#103 / PR #104，#105 / PR #106/#107，#125 / PR #126 | `elixir/lib/symphony_elixir/hub/runtime.ex`、`elixir/lib/symphony_elixir/cli.ex`、`elixir/test/symphony_elixir/hub_runtime_test.exs`、`elixir/test/symphony_elixir/cli_test.exs` |
| candidate intake、dispatch planning/application、atomic boundary | #91 / PR #92/#93，#108 / PR #109，#110 / PR #111，#112 / PR #113，#114 / PR #115 | `elixir/lib/symphony_elixir/hub/dispatch_boundary.ex`、`candidate_intake.ex`、`dispatch_planning.ex`、`dispatch_plan_application.ex`、`hub_dispatch_boundary_test.exs`、`hub_candidate_intake_test.exs`、`hub_dispatch_planning_test.exs`、`hub_dispatch_plan_application_test.exs` |
| worker start handoff、real starter、lifecycle reconciliation | #117 / PR #118，#119 / PR #120，#121 / PR #122，#123 / PR #124 | `worker_start_handoff.ex`、`real_worker_starter.ex`、`worker_lifecycle_reconciliation.ex`、`hub_start_handoff_test.exs`、`hub_worker_lifecycle_reconciliation_test.exs` |
| provider tool/writeback routing、intent/result、real writeback safe subset | #94 / PR #95/#96，#97 / PR #98，#129 / PR #130 | `provider_tool_routing.ex`、`writeback_processor.ex`、`real_writeback_executor.ex`、`hub_provider_tool_routing_test.exs`、`hub_writeback_processor_test.exs`、`hub_real_writeback_executor_test.exs` |
| real candidate scan executor | #127 / PR #128 | `real_candidate_scan_executor.ex`、`provider_executor.ex`、`hub_real_candidate_scan_executor_test.exs` |
| device observability、legacy boundary、host probe、Dashboard detail | #99 / PR #100，#131 / PR #132，#133 / PR #134，#135 / PR #139 | `device_observability.ex`、`activation_preflight.ex`、`host_service_probe.ex`、`dashboard_live.ex`、`hub_device_observability_test.exs`、`hub_activation_preflight_test.exs`、`hub_host_service_probe_test.exs`、`hub_dashboard_detail_test.exs` |
| migration readiness、activation plan、cutover gate、dry-run/runbook | #140 / PR #141，#142 / PR #143，#144 / PR #145，#146 / PR #147，#148 / PR #149，#150 / PR #151 | `activation_plan.ex`、`cutover_gate.ex`、`cutover_operation_audit.ex`、`cutover_audit_history.ex`、`hub_activation_plan_test.exs`、`hub_cutover_gate_test.exs`、`hub_cutover_operation_audit_test.exs`、`hub_cutover_audit_history_test.exs` |
| readiness permit、authorization、consumption guard、execution outcome、closeout/replay | #152 / PR #153，#154 / PR #155，#156 / PR #157，#158 / PR #159，#160 / PR #164，#165 / PR #166，#167 / PR #168，#169 / PR #170 | `cutover_readiness_permit.ex`、`cutover_execution_authorization.ex`、`cutover_authorization_consumption_guard.ex`、`cutover_execution_outcome_ledger.ex`、`cutover_execution_outcome_closeout.ex`、`cutover_replay_decision.ex`、`cutover_replay_request_audit.ex`、`hub_cutover_readiness_permit_test.exs`、`hub_cutover_execution_authorization_test.exs`、`hub_cutover_execution_outcome_ledger_test.exs`、`hub_cutover_execution_outcome_closeout_test.exs`、`hub_cutover_replay_decision_test.exs`、`hub_cutover_replay_request_audit_test.exs` |
| closure chain/conclusion/report packet/dry-run/coverage audit | #173-#195 / PR #174-#196，#197 / PR #198 | `cutover_closure_chain.ex`、`cutover_closure_conclusion.ex`、`cutover_closure_report_packet.ex`、`docs/hub-cutover-closure-report-packet-dry-run.md`、`docs/hub-cutover-closure-report-coverage-audit.md` |

## 覆盖矩阵

| #74 原始验收点 | 状态 | 证据类型 | 稳定证据引用 | 审计结论 |
| --- | --- | --- | --- | --- |
| 一台设备运行一个显式 Hub 服务，Hub 管理多个项目，项目保留独立配置和状态分区 | `covered` | 代码 + 测试 + 文档 | #75/#101/#125，PR #76/#102/#126；`project_registry.ex`、`runtime.ex`、`hub_project_registry_test.exs`、`hub_runtime_test.exs`；`README.md`、`SPEC.md`、`elixir/README.md` 的 `--hub-config` / `--hub-scheduler` 说明 | 显式 Hub entrypoint 和 scheduler 已存在；legacy 单项目启动仍保持兼容，自动接管 legacy 多实例作为迁移边界单独审计。 |
| 多项目注册、配置快照、provider-neutral IssueRef、单项目配置错误隔离 | `covered` | 代码 + 测试 | #75，PR #76；`project_registry.ex`、`issue_ref.ex`、`hub_project_registry_test.exs`、`hub_issue_ref_test.exs`；`SPEC.md` §5.7 | `HUB.yaml` registry 能生成脱敏 project snapshot 和 IssueRef，配置错误被局部化为对应 project 的 paused/error snapshot。 |
| 项目不拥有独立 provider poll loop，Hub 统一决定 due/backoff/capacity 下的 poll tick | `covered` | 代码 + 测试 | #87/#101/#105/#125，PR #88/#102/#106/#126；`poll_coordinator.ex`、`runtime.ex`、`hub_poll_coordinator_test.exs`、`hub_runtime_test.exs` | 在显式 Hub runtime 和 `--hub-scheduler` 下，candidate scan 经 Hub poll plan 和 provider governance 执行；legacy `symphony@project.service` 不会被静默迁移。 |
| Hub poll coordination 不被单个慢 provider 请求拖住全局调度 | `closure_ready` | 代码 + 测试 + 文档 + fixture | #79/#87/#105/#125/#203，PR #84/#88/#106/#126/#204；`provider_governance.ex`、`poll_coordinator.ex`、`runtime.ex`、`hub_provider_governance_test.exs`、`hub_runtime_test.exs`、`hub_runtime_ledger_restart_replay_fixture.exs` | request governance、backoff/circuit、scheduler coalescing 和 failure isolation 已覆盖；#203 证明当前 safe runtime facts 在模拟重启后可解释。真实 provider chaos、durable queue 或自动 retry/replay 是 scoped non-goal。 |
| 同一 provider 额度池请求经统一出口排队、限流观察、退避和统计 | `closure_ready` | 代码 + 测试 + 决策 | #79/#105/#127/#129/#201，PR #84/#106/#128/#130/#202；`provider_governance.ex`、`provider_executor.ex`、`real_candidate_scan_executor.ex`、`real_writeback_executor.ex`、`docs/hub-provider-exit-residual-coverage-decision-baseline.md` | Hub-owned candidate scan 和 safe writeback 子集已有 governed request/result；legacy direct provider paths、raw GraphQL escape hatch、auto-update/维护类 provider 访问已由 #201 裁定为 scoped non-goal、unsupported/manual attention、future migration candidate 或 non-runtime provider access。 |
| 统一 provider 出口覆盖 dynamic tools、PR/issue/tracker writeback，并给出 replay policy | `closure_ready` | 代码 + 测试 + 决策 | #94/#97/#129/#201，PR #95/#96/#98/#130/#202；`provider_tool_routing.ex`、`writeback_processor.ex`、`real_writeback_executor.ex`、`hub_provider_tool_routing_test.exs`、`hub_writeback_processor_test.exs`、`hub_real_writeback_executor_test.exs`、`docs/hub-provider-exit-residual-coverage-decision-baseline.md` | structured GitHub issue/PR/tracker 工具有 opt-in routing 和 safe summaries；完整 PR create、普通 append comment、raw `linear_graphql` 等不被写成 Hub-governed，按 #201 保持 manual attention 或 future migration candidate。 |
| 可恢复运行账本记录 claim、attempt、workspace、retry/backoff、session summary、writeback intent/result | `covered` | 代码 + 测试 + fixture | #77/#91/#114/#117/#119/#121/#123/#203，PR #78/#92/#93/#115/#118/#120/#122/#124；`runtime_ledger.ex`、`dispatch_boundary.ex`、`dispatch_plan_application.ex`、`worker_start_handoff.ex`、`worker_lifecycle_reconciliation.ex`、`elixir/test/support/hub_runtime_ledger_restart_replay_fixture.exs`、`hub_runtime_ledger_test.exs`、`hub_device_observability_test.exs` | ledger fact model、replay、冲突校验、生命周期事实和 #203 restart/replay safe fixture baseline 已覆盖；该 baseline 证明现有 safe fields 能在模拟重启后被 RuntimeLedger、DeviceObservability 和 `/api/v1/state` 一致解释，但不新增 durable queue 或自动执行能力。 |
| 同一 project + issue 同时最多一个 active attempt，重复 tick/webhook/ack loss 不造成双跑 | `covered` | 代码 + 测试 | #91/#112/#114/#117/#119/#121/#123，PR #92/#93/#113/#115/#118/#120/#122/#124；`dispatch_boundary.ex`、`dispatch_planning.ex`、`dispatch_plan_application.ex`、`worker_start_handoff.ex`、`worker_lifecycle_reconciliation.ex` | candidate 到 active run intent 的模型边界已有 idempotent plan/application/start/lifecycle 保护，late running after terminal 的回归由 #123 修复。 |
| claim、attempt、workspace lease、agent start command 之间形成明确派发边界 | `covered` | 代码 + 测试 | #91/#112/#114/#117/#119，PR #92/#113/#115/#118/#120；`DispatchBoundary.dispatch/3`、`WorkerStartHandoff`、`RealWorkerStarter`、`hub_dispatch_boundary_test.exs`、`hub_dispatch_plan_application_test.exs`、`hub_start_handoff_test.exs` | dispatch plan application 把 planned intent 应用为 claim、attempt、workspace lease、start intent 和 safe run context；真实 worker starter 需要显式 opt-in。 |
| agent lifecycle 完成、失败、取消、timeout、heartbeat lost、unknown/manual attention 可观察并释放或保留 workspace/capacity | `covered` | 代码 + 测试 | #121/#123，PR #122/#124；`worker_lifecycle_reconciliation.ex`、`hub_worker_lifecycle_reconciliation_test.exs` | terminal、late、duplicate、old session 和 workspace mismatch 已有测试；unknown/manual attention 会保留为可解释事实。 |
| 同一逻辑写回跨 attempt 不产生第二个 PR/comment/status 副作用 | `closure_ready` | 代码 + 测试 + 决策 | #94/#97/#129/#201，PR #95/#96/#98/#130/#202；`provider_tool_routing.ex`、`writeback_processor.ex`、`real_writeback_executor.ex`、`docs/hub-provider-exit-residual-coverage-decision-baseline.md` | workpad marker upsert、stage/status、label add 等安全子集已有 intent/result 与 replay guard；PR create 和普通 append comment 的 unknown path 保持 lookup/manual attention，不作为当前 baseline closure blocker。 |
| unknown 或非幂等写回进入 manual attention，不盲目重放 | `covered` | 代码 + 测试 | #97/#129/#160/#165/#167/#169，PR #98/#130/#164/#166/#168/#170；`writeback_processor.ex`、`cutover_execution_outcome_ledger.ex`、`cutover_execution_outcome_closeout.ex`、`cutover_replay_decision.ex` | 写回和 cutover outcome 两条链路都保留 unknown/manual attention 和 closeout/replay decision 证据，不把 unknown 解释成 success。 |
| Dashboard/API 提供设备级总览与项目级明细，解释暂停、退避、限流、队列、workspace、writeback、manual attention | `covered` | 代码 + 测试 + 文档 | #99/#101/#125/#135，PR #100/#102/#126/#139；`device_observability.ex`、`presenter.ex`、`dashboard_live.ex`、`hub_device_observability_test.exs`、`hub_dashboard_detail_test.exs` | `/api/v1/state` 和 Live Dashboard 已有 Hub overview/detail；#136 的错误变更已由 #138 回滚，#139 是有效 Dashboard 明细交付。 |
| Hub mode 与 legacy 多实例模型的迁移边界清楚，legacy 服务不被自动接管 | `covered` | 代码 + 测试 + 文档 | #99/#131/#133/#140/#142/#144/#146-#195/#197，拆分交付索引中的对应 PR；`activation_preflight.ex`、`host_service_probe.ex`、`cutover_gate.ex`、`docs/hub-cutover-closure-report-coverage-audit.md` | activation preflight、host probe、readiness、activation plan、cutover gate、dry-run/history/permit/authorization/outcome/closure report 都把 legacy takeover 保持为显式人工边界。 |
| provider cursor/ETag、quota/circuit、最近错误和暂停原因可恢复或解释 | `closure_ready` | 代码 + 测试 + 决策 + fixture | #79/#87/#105/#127/#129/#99/#201/#203，PR #84/#88/#106/#128/#130/#100/#202/#204；`provider_governance.ex`、`poll_coordinator.ex`、`device_observability.ex`、`docs/hub-provider-exit-residual-coverage-decision-baseline.md` | quota/backoff/circuit、poll result 和 provider scope state 已可观察；adapter-wide cursor/ETag 持久化迁移属于 future migration candidate 或 legacy scoped non-goal，不阻塞当前 Hub baseline closure。 |
| 自动 retry/replay、durable execution queue、一键迁移、legacy service takeover | `scoped_non_goal` | 决策 + 文档 + 测试 | #74 非目标后续拆分；#140-#197；`DEPLOY.md`、`SPEC.md`、`docs/hub-cutover-closure-report-packet-dry-run.md` | 当前 Hub baseline 明确保持 operator-controlled dry-run / authorization / closeout / replay decision；这些自动化能力如果要做，应作为新的大能力另行立项。 |
| 一次性恢复 #171/#172 完整 operator-facing closure report 大范围 | `scoped_non_goal` | 文档 + Owner 决策 | #197，PR #198；`docs/hub-cutover-closure-report-coverage-audit.md`；#171/#172 已关闭 | #171/#172 已由 closure chain/conclusion/packet/dry-run 小切片收束，当前 #74 审计只引用其结果。 |
| #74 是否可以关闭、降级或继续拆最小 gap | `closure_ready` | 本审计 + closure packet | #74；#199/#201/#203/#205；本文件；`docs/hub-mode-issue-74-closure-decision-packet.md` | 证据已聚合并由 #205 closure decision packet 收束；Owner 可以后续评论/关闭 #74，或把 future migration candidates 另行开票。 |

## remaining gap closure decisions

### 1. provider exit residual coverage and decision audit

状态：`closure_ready`

#74 原始验收要求“所有 provider 读写请求进入统一治理层”。当前 Hub-owned candidate scan、safe writeback 子集、
structured provider tool routing 已有代码和测试；legacy single-project poll/writeback、raw GraphQL 工具、
auto-update 或维护类 provider 访问仍保持兼容直连或未归入同一覆盖决策。

#201 建立了首份最小、可审查的 inventory / decision baseline：
[`docs/hub-provider-exit-residual-coverage-decision-baseline.md`](hub-provider-exit-residual-coverage-decision-baseline.md)。
该 baseline 明确区分哪些路径已经 Hub-governed、哪些路径按当前 baseline 保留 legacy direct、
哪些 raw/unsupported path 必须 manual attention / provider lookup / permanent failure，以及哪些路径属于
后续最小迁移候选。所有 legacy 路径的行为迁移仍应由后续独立 issue 承担；当前 #74 baseline closure
不再被该 residual gap 阻塞。

收束结论：

- `hub_governed`：Hub-owned candidate scan、Hub poll coordination、structured opt-in provider tools、
  writeback processor、real writeback safe subset 和 Hub `/refresh` 入口已有代码/测试证据。
- `legacy_direct_scoped_non_goal`：legacy single-project poll/reconciliation/stage writeback、dynamic tool
  默认直连、tracker adapters、GitHub Project/status adapter 和 legacy Dashboard `/refresh` 保持兼容边界。
- `unsupported_manual_attention`：unsupported provider operation、PR create、普通 append comment、raw
  `linear_graphql` 等不得自动 replay。
- `future_migration_candidate`：legacy tracker read/reconciliation、structured read-only PR/issue/Project
  status 查询、raw `linear_graphql` 的结构化替代子集可后续单独开票。
- `non_runtime_provider_access`：auto-update、Dashboard safe summaries、cutover dry-run/closure packet 和
  审查类读取不参与 Hub runtime provider queue 覆盖判断。

### 2. restart/replay acceptance fixture for #74 runtime facts

状态：`covered`

`RuntimeLedger`、dispatch/start/lifecycle/writeback facts 已有模型和 targeted tests；#74 原始验收还要求
Hub 重启后能恢复或解释 claim、workspace 使用状态、run attempt、retry、provider cursor、writeback 和 manual
attention。#203 已补上固定 safe fixture baseline：
`elixir/test/support/hub_runtime_ledger_restart_replay_fixture.exs` 构造脱敏多 project runtime facts，
`hub_runtime_ledger_test.exs` 验证 snapshot reload / `RuntimeLedger.replay` 后 active attempt、completed
attempt、retry/backoff、workspace retained/released、writeback replay-safe、provider lookup、unknown/manual
attention 和 conflict 降级都可解释；`hub_device_observability_test.exs` 验证同一份 restored ledger 进入
`Runtime.build_snapshot/4`、DeviceObservability 和 Presenter `/api/v1/state` 后关键状态一致。

该基线只加载脱敏 fixture，验证 replay summary、DeviceObservability 和 Dashboard/API safe fields 的一致性；
数据库、WAL、durable execution queue、自动 retry/replay、真实 provider 调用、dispatch、worker starter、
writeback executor、systemd、workspace hook、配置修改和 legacy service takeover 仍是非目标。

### 3. #74 owner closure packet after remaining gaps are triaged

状态：`closure_ready`

本审计说明 #74 的 Hub baseline 已有拆分证据；#201 已补齐 provider exit residual inventory /
decision baseline，#203 已补齐 restart/replay safe fixture baseline，#205 已新增
[`docs/hub-mode-issue-74-closure-decision-packet.md`](hub-mode-issue-74-closure-decision-packet.md)。
Owner 可以基于该 packet 决定评论/关闭 #74，或把 future migration candidates 拆为新的最小 follow-up。

## 可选 future migration candidates

这些候选只用于后续迁移规划，不在本审计或 #205 中创建、投递或实现。

### 候选 1：legacy single-project tracker read/reconciliation 迁移裁定

分类：`future_migration_candidate`

目标：在 Owner 明确要继续收敛 legacy provider reads 时，单独设计 legacy `fetch_runnable_issues`、
running/blocked `fetch_issue_states_by_ids` 和 `read_issue_stage` 到 Hub-governed read boundary 的迁移，
或明确长期保持 legacy scoped non-goal。

非目标：不接管 legacy writeback，不改变 `AgentRunner` stage loop，不自动迁移
`symphony@project.service`，不新增 durable queue 或跨进程 lock。

不是 blocker 的原因：当前 #74 baseline 的目标是显式 Hub mode；legacy runtime 兼容直连已由 #201 明确为
`legacy_direct_scoped_non_goal`。

### 候选 2：structured read-only PR / issue / Project status 查询的 Hub-governed routing 扩展

分类：`future_migration_candidate`

目标：把 PR lookup、review/comment/check read、GitHub issue detail/comment read、Project/status read
整理成 opt-in Hub-governed structured read 子集，提供统一 backoff/circuit/result summaries。

非目标：不迁移 PR create、普通 append comment、raw GraphQL、stage writeback；不改变 dynamic tool 默认直连行为。

不是 blocker 的原因：这些路径主要是审查、人工复核或兼容读取；当前 Hub runtime poll/writeback baseline
已有 governed candidate scan 和 safe writeback 子集。

### 候选 3：raw `linear_graphql` 的结构化替代子集

分类：`future_migration_candidate`

目标：为 Linear 常用 issue/stage/comment 操作定义结构化工具或 operation schema，让可识别子集进入
`ProviderGovernance`，同时保留 raw `linear_graphql` 作为 escape hatch。

非目标：不禁止 raw GraphQL，不自动 replay 任意 mutation，不推断任意 GraphQL document 的幂等性。

不是 blocker 的原因：任意 GraphQL document 无法安全静态判断副作用、scope 和 replay policy；当前 #74
baseline 只需要把它裁定为 unsupported/manual-attention 或后续结构化迁移候选。

## 本地验证入口

本审计自身是文档基线。建议验证：

```bash
git diff --check
rg -n "#74|Issue #74|remaining capability coverage|closure decision|covered|closure_ready|scoped_non_goal|future_migration_candidate|remaining_gap" README.md SPEC.md DEPLOY.md elixir/README.md docs elixir/docs
```

如需复核引用的 Hub 行为证据，可按能力运行对应 targeted tests，例如：

```bash
cd elixir
mise exec -- mix test \
  test/symphony_elixir/hub_project_registry_test.exs \
  test/symphony_elixir/hub_runtime_ledger_test.exs \
  test/symphony_elixir/hub_provider_governance_test.exs \
  test/symphony_elixir/hub_poll_coordinator_test.exs \
  test/symphony_elixir/hub_runtime_test.exs \
  test/symphony_elixir/hub_dispatch_boundary_test.exs \
  test/symphony_elixir/hub_writeback_processor_test.exs \
  test/symphony_elixir/hub_device_observability_test.exs \
  test/symphony_elixir/hub_dashboard_detail_test.exs \
  test/symphony_elixir/hub_cutover_closure_report_packet_dry_run_test.exs
```

#203 restart/replay safe fixture baseline 的最小复核入口：

```bash
cd elixir
mix test test/symphony_elixir/hub_runtime_ledger_test.exs
mix test test/symphony_elixir/hub_device_observability_test.exs
```

## 交叉引用

- #74 epic：https://github.com/JhihJian/symphony/issues/74
- #199 audit issue：https://github.com/JhihJian/symphony/issues/199
- #201 provider exit decision baseline issue：https://github.com/JhihJian/symphony/issues/201
- #203 restart/replay safe fixture baseline issue：https://github.com/JhihJian/symphony/issues/203
- #205 closure decision packet issue：https://github.com/JhihJian/symphony/issues/205
- #74 closure decision packet：[`docs/hub-mode-issue-74-closure-decision-packet.md`](hub-mode-issue-74-closure-decision-packet.md)
- provider exit decision baseline：[`docs/hub-provider-exit-residual-coverage-decision-baseline.md`](hub-provider-exit-residual-coverage-decision-baseline.md)
- #171/#172 closure report 覆盖审计：[`docs/hub-cutover-closure-report-coverage-audit.md`](hub-cutover-closure-report-coverage-audit.md)
- closure report packet dry-run runbook：[`docs/hub-cutover-closure-report-packet-dry-run.md`](hub-cutover-closure-report-packet-dry-run.md)
- 项目说明：[`README.md`](../README.md)
- 行为规范：[`SPEC.md`](../SPEC.md)
- 部署说明：[`DEPLOY.md`](../DEPLOY.md)
- Elixir 实现说明：[`elixir/README.md`](../elixir/README.md)
