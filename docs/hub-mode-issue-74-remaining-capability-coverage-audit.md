# Hub mode Issue #74 remaining capability coverage audit baseline

本文档是 #199 的仓库内覆盖审计基线，审计对象是 #74
`Add Symphony Hub mode for device-level multi-project coordination` 的原始目标和验收标准。它把 #74
已经拆分交付的 issue、PR、代码模块、测试和文档证据归到同一张矩阵，帮助 Owner 判断 Hub mode
后续还需要哪些最小切片。

本审计的边界是证据整理和差距判断：#74 关闭决策、#171/#172 closure report 大范围恢复、
Hub Runtime/API/Dashboard 行为变更，以及 provider、dispatch、worker starter、writeback、systemd、
workspace hook、配置修改路径调用，均留在后续明确授权的工作范围内。

## 审计范围

- 原始 epic：#74，当前仍是 Hub mode 的总目标来源。
- 已交付切片：#75/#77/#79/#87/#89/#91/#94/#97/#99/#101/#103/#105/#108/#110/#112/#114/#117/#119/#121/#123/#125/#127/#129/#131/#133/#135/#137/#140/#142/#144/#146/#148/#150/#152/#154/#156/#158/#160/#165/#167/#169/#173/#175/#177/#179/#181/#183/#185/#187/#189/#191/#193/#195/#197。
- 主要 PR 证据：#76/#78/#84/#88/#90/#92/#93/#95/#96/#98/#100/#102/#104/#106/#107/#109/#111/#113/#115/#118/#120/#122/#124/#126/#128/#130/#132/#134/#138/#139/#141/#143/#145/#147/#149/#151/#153/#155/#157/#159/#164/#166/#168/#170/#174/#176/#178/#180/#182/#184/#186/#188/#190/#192/#194/#196/#198。
- #135 的首个 PR #136 已由 #137 / PR #138 回滚；本审计把 #135 的有效 Dashboard 明细证据记为后续
  PR #139。
- #171/#172 closure report 历史大票据已经由 #197 建立局部覆盖审计，并由 Owner 关闭；本文件只把该
  结论作为 #74 的一个证据来源，不重新审计 #171/#172 全量细节。

本文件只引用 issue/PR 编号、仓库路径、字段名和本地验证命令；证据口径保持脱敏，不引用 token、
Authorization/cookie、secret env、raw provider payload、完整 prompt/transcript、完整 PR/comment body、
本机私有路径或异常栈。

## 覆盖状态定义

- `covered`：已有代码、测试或可复现文档证据足以支撑该 #74 验收点。
- `partially_covered`：已有基础能力，但还缺明确能力、迁移裁定、统一验证或持久化/restart 证明。
- `scoped_non_goal`：该能力已被拆分或裁定为当前 Hub baseline 的范围外，后续如需建设应单独开票。
- `remaining_gap`：当前仓库仍缺少后续最小 issue 才能完成该验收点或关闭判断。
- `owner_decision_needed`：代码、测试和文档证据已经可审查，但需要 Owner 决定关闭、降级或再拆分。

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
| Hub poll coordination 不被单个慢 provider 请求拖住全局调度 | `partially_covered` | 代码 + 测试 + 文档 | #79/#87/#105/#125，PR #84/#88/#106/#126；`provider_governance.ex`、`poll_coordinator.ex`、`runtime.ex`、`hub_provider_governance_test.exs`、`hub_runtime_test.exs` | 已有 request governance、backoff/circuit、scheduler coalescing 和 failure isolation；还缺一份 #74 级别的统一 dry-run/fixture 证明慢 provider 或 pending request 不会让设备级状态不可解释。 |
| 同一 provider 额度池请求经统一出口排队、限流观察、退避和统计 | `partially_covered` | 代码 + 测试 | #79/#105/#127/#129，PR #84/#106/#128/#130；`provider_governance.ex`、`provider_executor.ex`、`real_candidate_scan_executor.ex`、`real_writeback_executor.ex`、`hub_provider_governance_test.exs`、`hub_real_candidate_scan_executor_test.exs`、`hub_real_writeback_executor_test.exs` | Hub-owned candidate scan 和 safe writeback 子集已有 governed request/result；legacy direct provider paths、raw GraphQL escape hatch、auto-update/维护类 provider 访问仍需要 Owner 明确为 scoped legacy 或后续迁移对象。 |
| 统一 provider 出口覆盖 dynamic tools、PR/issue/tracker writeback，并给出 replay policy | `partially_covered` | 代码 + 测试 | #94/#97/#129，PR #95/#96/#98/#130；`provider_tool_routing.ex`、`writeback_processor.ex`、`real_writeback_executor.ex`、`hub_provider_tool_routing_test.exs`、`hub_writeback_processor_test.exs`、`hub_real_writeback_executor_test.exs` | structured GitHub issue/PR/tracker 工具已有 opt-in routing 和 safe summaries；完整 PR create、普通 append comment、raw `linear_graphql` 等归入 provider exit residual decision。 |
| 可恢复运行账本记录 claim、attempt、workspace、retry/backoff、session summary、writeback intent/result | `partially_covered` | 代码 + 测试 | #77/#91/#114/#117/#119/#121/#123，PR #78/#92/#93/#115/#118/#120/#122/#124；`runtime_ledger.ex`、`dispatch_boundary.ex`、`dispatch_plan_application.ex`、`worker_start_handoff.ex`、`worker_lifecycle_reconciliation.ex` | ledger fact model、replay、冲突校验和生命周期事实已覆盖；#74 原始“重启后能恢复或解释”的最终判断还缺一个可复现的 restart/replay acceptance fixture 或持久化输入基线。 |
| 同一 project + issue 同时最多一个 active attempt，重复 tick/webhook/ack loss 不造成双跑 | `covered` | 代码 + 测试 | #91/#112/#114/#117/#119/#121/#123，PR #92/#93/#113/#115/#118/#120/#122/#124；`dispatch_boundary.ex`、`dispatch_planning.ex`、`dispatch_plan_application.ex`、`worker_start_handoff.ex`、`worker_lifecycle_reconciliation.ex` | candidate 到 active run intent 的模型边界已有 idempotent plan/application/start/lifecycle 保护，late running after terminal 的回归由 #123 修复。 |
| claim、attempt、workspace lease、agent start command 之间形成明确派发边界 | `covered` | 代码 + 测试 | #91/#112/#114/#117/#119，PR #92/#113/#115/#118/#120；`DispatchBoundary.dispatch/3`、`WorkerStartHandoff`、`RealWorkerStarter`、`hub_dispatch_boundary_test.exs`、`hub_dispatch_plan_application_test.exs`、`hub_start_handoff_test.exs` | dispatch plan application 把 planned intent 应用为 claim、attempt、workspace lease、start intent 和 safe run context；真实 worker starter 需要显式 opt-in。 |
| agent lifecycle 完成、失败、取消、timeout、heartbeat lost、unknown/manual attention 可观察并释放或保留 workspace/capacity | `covered` | 代码 + 测试 | #121/#123，PR #122/#124；`worker_lifecycle_reconciliation.ex`、`hub_worker_lifecycle_reconciliation_test.exs` | terminal、late、duplicate、old session 和 workspace mismatch 已有测试；unknown/manual attention 会保留为可解释事实。 |
| 同一逻辑写回跨 attempt 不产生第二个 PR/comment/status 副作用 | `partially_covered` | 代码 + 测试 | #94/#97/#129，PR #95/#96/#98/#130；`provider_tool_routing.ex`、`writeback_processor.ex`、`real_writeback_executor.ex` | workpad marker upsert、stage/status、label add 等安全子集已有 intent/result 与 replay guard；PR create 和普通 append comment 的 unknown path 被保守挡住或要求 lookup/manual attention，尚未迁移成完整 Hub real writeback 能力。 |
| unknown 或非幂等写回进入 manual attention，不盲目重放 | `covered` | 代码 + 测试 | #97/#129/#160/#165/#167/#169，PR #98/#130/#164/#166/#168/#170；`writeback_processor.ex`、`cutover_execution_outcome_ledger.ex`、`cutover_execution_outcome_closeout.ex`、`cutover_replay_decision.ex` | 写回和 cutover outcome 两条链路都保留 unknown/manual attention 和 closeout/replay decision 证据，不把 unknown 解释成 success。 |
| Dashboard/API 提供设备级总览与项目级明细，解释暂停、退避、限流、队列、workspace、writeback、manual attention | `covered` | 代码 + 测试 + 文档 | #99/#101/#125/#135，PR #100/#102/#126/#139；`device_observability.ex`、`presenter.ex`、`dashboard_live.ex`、`hub_device_observability_test.exs`、`hub_dashboard_detail_test.exs` | `/api/v1/state` 和 Live Dashboard 已有 Hub overview/detail；#136 的错误变更已由 #138 回滚，#139 是有效 Dashboard 明细交付。 |
| Hub mode 与 legacy 多实例模型的迁移边界清楚，legacy 服务不被自动接管 | `covered` | 代码 + 测试 + 文档 | #99/#131/#133/#140/#142/#144/#146-#195/#197，拆分交付索引中的对应 PR；`activation_preflight.ex`、`host_service_probe.ex`、`cutover_gate.ex`、`docs/hub-cutover-closure-report-coverage-audit.md` | activation preflight、host probe、readiness、activation plan、cutover gate、dry-run/history/permit/authorization/outcome/closure report 都把 legacy takeover 保持为显式人工边界。 |
| provider cursor/ETag、quota/circuit、最近错误和暂停原因可恢复或解释 | `partially_covered` | 代码 + 测试 | #79/#87/#105/#127/#129/#99，PR #84/#88/#106/#128/#130/#100；`provider_governance.ex`、`poll_coordinator.ex`、`device_observability.ex` | quota/backoff/circuit、poll result 和 provider scope state 已可观察；cursor/ETag 与所有 provider adapter 的持久恢复口径仍分散，适合纳入 provider exit residual audit。 |
| 自动 retry/replay、durable execution queue、一键迁移、legacy service takeover | `scoped_non_goal` | 决策 + 文档 + 测试 | #74 非目标后续拆分；#140-#197；`DEPLOY.md`、`SPEC.md`、`docs/hub-cutover-closure-report-packet-dry-run.md` | 当前 Hub baseline 明确保持 operator-controlled dry-run / authorization / closeout / replay decision；这些自动化能力如果要做，应作为新的大能力另行立项。 |
| 一次性恢复 #171/#172 完整 operator-facing closure report 大范围 | `scoped_non_goal` | 文档 + Owner 决策 | #197，PR #198；`docs/hub-cutover-closure-report-coverage-audit.md`；#171/#172 已关闭 | #171/#172 已由 closure chain/conclusion/packet/dry-run 小切片收束，当前 #74 审计只引用其结果。 |
| #74 是否可以关闭、降级或继续拆最小 gap | `owner_decision_needed` | 本审计 + tracker 事实 | #74 仍是 epic；本文件；#199 | 证据已聚合到本矩阵，但 `partially_covered` 和 `remaining_gap` 仍需要 Owner 裁定优先级。 |

## remaining gap

### 1. provider exit residual coverage and decision audit

状态：`remaining_gap`

#74 原始验收要求“所有 provider 读写请求进入统一治理层”。当前 Hub-owned candidate scan、safe writeback 子集、
structured provider tool routing 已有代码和测试；legacy single-project poll/writeback、raw GraphQL 工具、
auto-update 或维护类 provider 访问仍保持兼容直连或未归入同一覆盖决策。

首个切片的范围是一份最小、可审查的 inventory / decision baseline：哪些路径已经 Hub-governed，
哪些路径按当前 baseline 明确保留 legacy direct，哪些路径属于后续最小迁移候选。所有 legacy 路径的
行为迁移应由后续独立 issue 承担。

### 2. restart/replay acceptance fixture for #74 runtime facts

状态：`remaining_gap`

`RuntimeLedger`、dispatch/start/lifecycle/writeback facts 已有模型和 targeted tests；#74 原始验收还要求
Hub 重启后能恢复或解释 claim、workspace 使用状态、run attempt、retry、provider cursor、writeback 和 manual
attention。当前证据分散在多个模块测试中，缺少一个固定 safe fixture / runbook 证明这些事实能作为
#74 级别的 restart/replay 证据链一起复核。

首个切片可以只加载脱敏 fixture，验证 replay summary、DeviceObservability 和 Dashboard/API safe fields
的一致性；数据库、WAL、durable execution queue 和自动 retry 属于后续独立能力。

### 3. #74 owner closure packet after remaining gaps are triaged

状态：`owner_decision_needed`

本审计说明 #74 的大部分能力已有拆分证据，但 provider exit 残余覆盖和 restart/replay 统一证据仍需处理或
明确降级。Owner 应在这些 gap 有结论后，决定 #74 是关闭、保持 epic 打开，还是拆成新的最小 follow-up。

## 后续最小 issue 建议

### 建议 1：Add Hub provider exit residual coverage decision baseline

目标：建立一份仓库内 provider exit inventory，把 Hub-owned governed paths、legacy direct paths、
unsupported/raw escape hatches 和后续迁移候选分开列清，并补一个只读验证命令或测试引用证明 Hub-owned
真实入口没有绕过 ProviderGovernance。

非目标：不迁移 legacy poll loop，不新增 provider I/O，不改 dynamic tool 行为，不接管 auto-update 或维护路径，
不扩大 real writeback supported operations。

验收重点：

- 覆盖 GitHub/GitLab/Linear/Memory candidate scan、structured tools、real writeback safe subset、
  raw `linear_graphql`、legacy single-project tracker path、auto-update/维护路径。
- 每项标注 `hub_governed`、`legacy_direct_scoped_non_goal`、`unsupported_manual_attention` 或
  `future_migration_candidate`。
- 引用模块、测试和文档路径；不泄露 provider payload、token 或完整 comment/PR body。

更安全的原因：它先做出口事实和范围裁定，把“迁移所有 provider 调用”留给后续按路径拆分的 issue。

### 建议 2：Add Hub runtime ledger restart/replay safe fixture baseline

目标：用固定脱敏 fixture 复现 Hub runtime ledger facts 在 restart/replay 场景下如何解释 claim、attempt、
workspace lease、retry/backoff、writeback unknown/manual attention 和 lifecycle unknown，并验证
DeviceObservability / `/api/v1/state` 输出一致。

非目标：不引入数据库、WAL、durable execution queue、自动 retry/replay、真实 provider 调用、worker start、
workspace hook 或 legacy service migration。

验收重点：

- fixture 覆盖 running attempt、released workspace、lost/unknown lifecycle、retry/backoff、writeback
  unknown/manual attention、conflict/orphan 降级。
- targeted test 证明 replay summary 不会创建第二个 active attempt、不会释放错误 workspace、不会把 unknown
  写回解释为 success。
- README/SPEC/DEPLOY/`elixir/README.md` 只补验证入口或边界链接。

更安全的原因：它只补 #74 restart/recovery 证据链，运行时执行入口和持久队列继续保持现有边界。

### 建议 3：Add Hub mode #74 closure decision packet

目标：在建议 1 和建议 2 有结论后，生成一个短小的 #74 closure decision packet，列出 remaining gaps 的处理结果、
Owner 可选决策、关闭评论要点和后续 issue 链接。

非目标：不关闭 #74，不改变 Project 状态，不新增 Hub runtime 行为，不重新打开 #171/#172。

验收重点：

- packet 引用本审计、provider exit decision、restart/replay fixture 证据。
- 明确哪些 `partially_covered` 已转为 `covered`、`scoped_non_goal` 或新的 issue。
- 给出 Owner 评论要点和关闭/保持打开的判断条件。

更安全的原因：它把最终 Owner 决策和工程实现拆开，让 #74 epic 保持审计和决策入口，大范围执行能力转入独立 issue。

## 本地验证入口

本审计自身是文档基线。建议验证：

```bash
git diff --check
rg -n "#74|Issue #74|remaining capability coverage|covered|partially_covered|remaining_gap" README.md SPEC.md DEPLOY.md elixir/README.md docs elixir/docs
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

## 交叉引用

- #74 epic：https://github.com/JhihJian/symphony/issues/74
- #199 audit issue：https://github.com/JhihJian/symphony/issues/199
- #171/#172 closure report 覆盖审计：[`docs/hub-cutover-closure-report-coverage-audit.md`](hub-cutover-closure-report-coverage-audit.md)
- closure report packet dry-run runbook：[`docs/hub-cutover-closure-report-packet-dry-run.md`](hub-cutover-closure-report-packet-dry-run.md)
- 项目说明：[`README.md`](../README.md)
- 行为规范：[`SPEC.md`](../SPEC.md)
- 部署说明：[`DEPLOY.md`](../DEPLOY.md)
- Elixir 实现说明：[`elixir/README.md`](../elixir/README.md)
