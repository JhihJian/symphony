# Hub provider exit residual coverage decision baseline

本文档是 #201 的 provider exit residual coverage / decision baseline，承接 #74 的“统一
provider 请求治理 / 所有 provider 读写请求进入统一出口”目标，以及 #199 coverage audit 的
remaining gap 1。它的作用是把仓库内主要 provider 访问路径按稳定证据分类，帮助 Owner 和 reviewer
判断 provider 出口是否足以关闭、降级为 scoped non-goal，或继续拆后续迁移 issue。

本基线不迁移 legacy single-project poll loop、tracker adapter 或 writeback path；不新增 provider
I/O；不扩大 real candidate scan 或 real writeback supported operations；不接管 raw
`linear_graphql`；不调用真实 provider、dispatch、worker starter、writeback、systemd、workspace
hook 或配置修改路径；也不关闭 #74。

## 与 #74 / #199 的关系

- #74 是原始 Hub mode epic，要求 provider API 访问统一排队、统一治理、统一观测。
- #199 / PR #200 的覆盖审计把 provider exit residual coverage 标为 `remaining_gap`，因为当时缺少一份
  仓库内 inventory / decision baseline。
- 本文档补齐该 baseline。它只把“哪些路径已经 Hub-governed、哪些保留 legacy direct、哪些 raw 或
  unsupported path 必须 manual attention、哪些适合后续迁移”说清楚，不把纯文档声明写成 runtime 已治理。
- 本文档之后，#199 remaining gap 1 的工程状态应从“缺 inventory”转为“Owner 决策 / 后续 scoped
  migration 拆分”，但不代表 #74 自动关闭。

## 决策分类

- `hub_governed`：请求已经通过 `ProviderGovernance`，或明确位于 Hub governed executor / routing
  boundary 后面。
- `legacy_direct_scoped_non_goal`：当前属于 legacy 单项目兼容路径，未迁移进 Hub；在 #74 当前 baseline
  中被明确保留为兼容边界，不作为本 issue 迁移目标。
- `unsupported_manual_attention`：raw、unsupported 或不能安全确认结果的路径，必须保持 manual
  attention、provider lookup required、permanent failure 或显式人工边界，不得自动重放。
- `future_migration_candidate`：后续可单独拆 issue 的最小迁移候选；必须有触发条件和非目标。
- `non_runtime_provider_access`：Owner / 运维 / CI / auto-update / 审查 / Dashboard safe summary 类访问，
  不应误算为 Hub runtime provider 逃逸路径。

覆盖类型按下面口径阅读：

- `代码覆盖`：仓库内已有模块或入口实现该边界。
- `测试覆盖`：已有 targeted test 证明该边界或关键降级行为。
- `文档/决策覆盖`：本文档或既有 README/SPEC/DEPLOY 说明该路径的范围；它不是 runtime governance 证明。

## Provider exit inventory

| 路径 / 入口 | 决策分类 | 覆盖类型 | 稳定证据 | 决策说明 |
| --- | --- | --- | --- | --- |
| Hub provider request model、queue、priority、fairness、quota/backoff/circuit、result classification | `hub_governed` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `elixir/lib/symphony_elixir/hub/provider_governance.ex`；`elixir/test/symphony_elixir/hub_provider_governance_test.exs`；`elixir/README.md` 的 `ProviderGovernance` 段落；#79 / PR #84 | 这是 Hub provider 出口的基础 contract。它本身不做 provider I/O，也不改变 legacy 单项目路径。 |
| Hub poll coordination 生成 candidate scan plan 和 governed request | `hub_governed` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `elixir/lib/symphony_elixir/hub/poll_coordinator.ex`；`elixir/test/symphony_elixir/hub_poll_coordinator_test.exs`；`elixir/lib/symphony_elixir/hub/runtime.ex`；`elixir/test/symphony_elixir/hub_runtime_test.exs`；#87/#101/#105/#125 | 显式 Hub runtime / scheduler 下，due project 的 candidate scan 进入 `ProviderGovernance` request；legacy `symphony@project.service` 不会被静默迁移。 |
| Hub runtime manual refresh / scheduler tick 中的 Hub-owned candidate scan 执行 | `hub_governed` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `elixir/lib/symphony_elixir/hub/runtime.ex`；`elixir/test/symphony_elixir/hub_runtime_test.exs`；`elixir/README.md` 的 `--hub-provider-executor` 说明 | `Runtime.request_refresh/1` 或 scheduler 只在 Hub mode 内执行 Hub-owned tick。被选中的 provider request 通过 injectable provider executor 返回 governed result。 |
| 默认 Hub provider executor skeleton | `hub_governed` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `elixir/lib/symphony_elixir/hub/provider_executor.ex`；`elixir/test/symphony_elixir/hub_runtime_test.exs` | 默认 executor 接受 governed request 并返回 safe result，不访问 provider；它是安全 skeleton，不是 legacy direct 调用。 |
| real candidate scan executor 的 `candidate_scan` read 子集 | `hub_governed` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `elixir/lib/symphony_elixir/hub/real_candidate_scan_executor.ex`；`elixir/test/symphony_elixir/hub_real_candidate_scan_executor_test.exs`；#127 / PR #128 | 显式 `real-candidate-scan` 下只支持 `candidate_scan`。它按 request 的 `project_id` / provider scope 回查 Hub registry，加载项目自己的 `WORKFLOW.md` / `TRACKER.yaml`，通过 tracker read adapter 读取候选并返回 safe candidate summary。 |
| real candidate scan executor 的非 `candidate_scan` operation、未知 provider、scope mismatch、cutover/authorization/replay block | `unsupported_manual_attention` | 代码覆盖 + 测试覆盖 | `real_candidate_scan_executor.ex`；`hub_real_candidate_scan_executor_test.exs` 的 unsupported operation、unsupported provider、scope mismatch、cutover gate、authorization guard、unresolved outcome replay block 测试 | 这些路径不会绕过治理层去直接访问 provider；结果是 governed permanent failure、unknown result、blocked 或 no-side-effect outcome，不自动重放。 |
| Hub candidate intake / dispatch planning / dispatch plan application 对 candidate result 的后续处理 | `hub_governed` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `candidate_intake.ex`、`dispatch_planning.ex`、`dispatch_plan_application.ex`；对应 `hub_candidate_intake_test.exs`、`hub_dispatch_planning_test.exs`、`hub_dispatch_plan_application_test.exs` | 这些模块消费 governed candidate summaries，做可观察 precheck / intent application；它们不新增 provider I/O。 |
| structured dynamic provider tool routing：`github_issue`、`github_pr`、`tracker_issue` 在显式 Hub routing context 下 | `hub_governed` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `elixir/lib/symphony_elixir/hub/provider_tool_routing.ex`；`elixir/lib/symphony_elixir/codex/dynamic_tool.ex`；`elixir/test/symphony_elixir/hub_provider_tool_routing_test.exs`；#94 / PR #95/#96 | 只有 caller 显式传入 `hub_provider_routing` 时，structured tool 才构建 `ProviderGovernance` request，并把 safe `providerGovernance` summary 加进 tool payload。 |
| structured dynamic provider tools 默认路径，无 Hub routing context | `legacy_direct_scoped_non_goal` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `dynamic_tool.ex` 的 `maybe_execute_provider_tool/5`；`hub_provider_tool_routing_test.exs` 的 “only when explicitly enabled” 测试；`elixir/README.md` provider tool routing 段落 | 当前默认保留兼容直连。它不是本 issue 的迁移目标，也不能被写成 runtime 已 Hub-governed。 |
| Hub writeback intent/result processing、dedupe、unknown/manual attention/replay decision | `hub_governed` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `elixir/lib/symphony_elixir/hub/writeback_processor.ex`；`elixir/test/symphony_elixir/hub_writeback_processor_test.exs`；#97 / PR #98 | 这是 model/read-decision boundary：把 routed writeback summary 归一为 safe ledger fact，并决定 completed、retry、lookup required、manual attention 或 conflict；它不做 provider I/O。 |
| real writeback executor 的 safe subset：stage/status write、GitHub workpad marker upsert、GitHub label add | `hub_governed` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `elixir/lib/symphony_elixir/hub/real_writeback_executor.ex`；`elixir/test/symphony_elixir/hub_real_writeback_executor_test.exs`；#129 / PR #130 | 显式 `real-writeback` 下，executor 先通过 activation preflight、cutover gate、authorization consumption guard、replay decision 和 `WritebackProcessor.decide/3`，再按 Hub registry 加载项目本地配置并执行窄写回子集。 |
| real writeback executor 的 PR create、普通 append comment、dynamic_tool_provider_call、candidate_scan 或 unsupported operation | `unsupported_manual_attention` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `real_writeback_executor.ex` 的 `rejected_operations/0`、`validate_operation_kind/1`、`execute_project_local_writeback/5`；`hub_real_writeback_executor_test.exs`；`hub_writeback_processor_test.exs` | PR create 和普通 append comment 的 unknown path 不可盲目重放：PR create 需要 provider lookup，append comment 进入 manual attention；unsupported operation 返回 governed non-success result。 |
| legacy single-project tracker poll / dispatch candidate read | `legacy_direct_scoped_non_goal` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `elixir/lib/symphony_elixir/orchestrator.ex` 的 `fetch_dispatch_candidates/0`；`elixir/lib/symphony_elixir/tracker.ex`；`elixir/test/symphony_elixir/e2e_test.exs`；`tracker_contract_test.exs`；`SPEC.md` compatibility boundary | legacy `Orchestrator` 仍按单项目配置通过 `Tracker.fetch_runnable_issues/1` 读取 provider。它是兼容路径，本 issue 不迁移。 |
| legacy running / blocked reconciliation provider reads | `legacy_direct_scoped_non_goal` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `orchestrator.ex` 的 `reconcile_running_issues/1`、`reconcile_blocked_issues/1`、`Tracker.fetch_issue_states_by_ids/1`、`Tracker.read_issue_stage/1`；`orchestrator_status_test.exs`、`tracker_contract_test.exs` | 这些 reads 用于 legacy 单项目恢复和冲突解释，当前不进入 Hub queue。若未来迁移，需要单独处理 restart/replay 语义。 |
| legacy workflow-stage writeback / stage transition writes | `legacy_direct_scoped_non_goal` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `elixir/lib/symphony_elixir/agent_runner.ex` 的 `write_issue_stage/2`；`Tracker.write_issue_stage/2`；`e2e_test.exs`；`tracker_contract_test.exs` | stage outcome 由 runner 内部 channel 决定，provider-visible state 仍由 legacy adapter 写入用于观测；本 issue 不迁移这条写路径。 |
| GitHub/GitLab/Linear/Memory tracker adapters | `legacy_direct_scoped_non_goal` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `github/adapter.ex`、`gitlab/adapter.ex`、`linear/adapter.ex`、`tracker/memory.ex`；`tracker_contract_test.exs`；`provider_contract_e2e_test.exs` | adapters 是保留兼容边界：legacy runtime 直接用它们，Hub real executors 也只在 governed request 之后按项目本地 config 使用它们。adapter 存在本身不表示 Hub 已接管所有 provider I/O。 |
| raw Linear GraphQL dynamic tool `linear_graphql` | `unsupported_manual_attention` | 代码覆盖 + 测试覆盖 + 文档/决策覆盖 | `elixir/lib/symphony_elixir/codex/dynamic_tool.ex` 的 `execute_linear_graphql/2`；`elixir/test/symphony_elixir/dynamic_tool_test.exs`；`elixir/README.md` 的 raw `linear_graphql` 段落 | 该工具接受任意 GraphQL document / variables，无法安全推断 replay policy、operation kind 或 scope validation。当前保持 raw escape hatch，不纳入自动 replay 或 Hub writeback。 |
| GitHub PR / issue 审查类 reads：PR lookup、reviews、review comments、checks、issue details、comments | `non_runtime_provider_access` | 代码覆盖 + 测试覆盖 + 文档/决策覆盖 | `elixir/lib/symphony_elixir/pull_request.ex`、`github/pull_request.ex`、`dynamic_tool.ex`；`pull_request_test.exs`、`dynamic_tool_test.exs`、`hub_provider_tool_routing_test.exs` | 这些多用于 worker/审查工具或人工复核。显式 Hub routing context 下可得到 governed request summary；默认仍是兼容直连。它们不应被误算为 Hub runtime poll/writeback 逃逸路径。 |
| GitHub Project/status 查询与 stage-state adapter 读写 | `legacy_direct_scoped_non_goal` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `github/adapter.ex`、`github/client.ex`；`tracker_contract_test.exs`；`SPEC.md` stage-state contract | GitHub Project v2 status 用作 provider-visible workflow state。legacy adapter 继续直接读写；Hub real writeback safe subset 只在 governed writeback request 之后调用项目本地写路径。 |
| auto-update GitHub branch/head polling 和本地 update/restart 管理面 | `non_runtime_provider_access` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `elixir/lib/symphony_elixir/auto_update.ex`；`elixir/test/symphony_elixir/auto_update_test.exs`；`SPEC.md` §13.7；`DEPLOY.md` auto-update / systemd template 说明 | 这是部署/运维控制面，不是 Hub runtime provider queue。它可用 conditional request / ETag / rate-limit summary 观测 upstream，但不参与 issue poll、candidate scan、worker dispatch 或 writeback governance。 |
| Dashboard/API `/refresh` 在 legacy runtime 下触发的手动刷新 | `legacy_direct_scoped_non_goal` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `observability_api_controller.ex`、`presenter.ex`、`orchestrator.ex` 的 `request_refresh/1`；`app_server_test.exs`、`orchestrator_status_test.exs` | legacy `/refresh` 是手动触发当前单项目 orchestrator poll/reconcile 的控制入口，仍走 legacy tracker adapter；它不是 Hub provider exit 已治理证明。 |
| Dashboard/API `/refresh` 在 Hub runtime 下触发的 Hub refresh | `hub_governed` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `presenter.ex`、`hub/runtime.ex` 的 `request_refresh/1` / manual refresh；`hub_runtime_test.exs` | Hub `/refresh` 本身是控制入口；被选中的 candidate scan request 仍通过 `ProviderGovernance` 和 configured Hub executor 执行。scheduler coalescing 避免重复 tick，不新增 provider path。 |
| migration readiness、activation plan、cutover gate、operation dry-run、audit history、permit、authorization、outcome、closeout、replay、closure report packet | `non_runtime_provider_access` | 代码覆盖 + 测试覆盖 + 文档覆盖 | `device_observability.ex`、`cutover_*` modules、`presenter.ex`、`dashboard_live.ex`；`hub_cutover_*_test.exs`；`docs/hub-cutover-closure-report-packet-dry-run.md`、`docs/hub-cutover-closure-report-coverage-audit.md` | 这些是 safe summary / dry-run / read-only decision surfaces。它们不调用 provider、dispatch、worker starter、writeback、systemd 或 config mutation，也不表示迁移已排队。 |

## 关键判断

1. Hub-owned candidate scan 没有记录到 legacy direct：Hub poll coordination 创建 `candidate_scan`
   `ProviderGovernance` request；默认 skeleton 不做 provider I/O；real candidate scan 只在显式 executor
   mode 下处理 `candidate_scan`，并把 unsupported / blocked / unknown path 转成 governed result。
2. structured provider tools 不是默认全量迁移：只有显式 `hub_provider_routing` context 时才进入
   `ProviderToolRouting`；默认 direct tool path 是兼容边界。
3. real writeback 是安全子集，不是完整 writeback takeover：stage/status write、workpad marker upsert、
   GitHub label add 有 governed executor；PR create、普通 append comment、raw GraphQL 和 unsupported
   operations 保持 manual attention、lookup required 或 permanent failure。
4. legacy single-project runtime 仍是 scoped non-goal：poll、running/blocked reconciliation、stage
   writes、adapter 读写保持兼容直连，不因本文档变成 Hub-governed。
5. auto-update、Dashboard safe summaries、cutover dry-run、closure report packet、PR/issue 审查类读取不能被当成
   Hub runtime 逃逸：它们属于非 runtime provider access 或只读 safe summary，不参与 Hub scheduler 的
   provider queue 覆盖判断。

## 后续最小迁移候选

### 候选 1：legacy single-project tracker read/reconciliation 迁移裁定

分类：`future_migration_candidate`

目标：在 Owner 明确要收敛 legacy runtime provider reads 时，单独设计一个迁移切片，把 legacy
`fetch_runnable_issues`、running/blocked `fetch_issue_states_by_ids` 和 `read_issue_stage` 的 provider
read 统一映射到 Hub-governed read boundary 或明确保持 legacy scoped non-goal。

非目标：不接管 legacy writeback，不改变 `AgentRunner` stage loop，不自动迁移 `symphony@project.service`，
不新增 durable queue 或跨进程 lock。

验收重点：同一 project/provider scope 的 poll、manual refresh、running reconciliation backoff 和错误分类可观察；
legacy 未启用 Hub 时行为不变；迁移路径不得调用真实 provider 作为测试前提。

为什么单独拆分：这会改变 legacy runtime 的 provider read ownership，风险和验证范围超过本决策基线。

### 候选 2：structured read-only PR / issue / Project status 查询的 Hub-governed routing 扩展

分类：`future_migration_candidate`

目标：把 PR lookup、review/comment/check read、GitHub issue detail/comment read、Project/status read
整理成更明确的 Hub-governed structured read 子集，让审查类工具在 opt-in Hub routing 下拥有统一
backoff/circuit/result summaries。

非目标：不迁移 PR create、普通 append comment、raw GraphQL、stage writeback；不改变 dynamic tool 默认直连行为。

验收重点：read-only operations 有稳定 operation kind、scope key、logical key 和 redacted result summary；
provider 失败进入 governed retry/rate-limit/permanent failure；不保存完整评论、review body 或 raw payload。

为什么单独拆分：这类 reads 跨 `DynamicTool`、`PullRequest`、`GitHub.Client` 和 provider adapters，需要独立测试矩阵。

### 候选 3：raw `linear_graphql` 的结构化替代子集

分类：`future_migration_candidate`

目标：为 Linear 常用 issue/stage/comment 操作定义结构化工具或 operation schema，让可识别子集进入
`ProviderGovernance`；raw `linear_graphql` 继续保留为 escape hatch。

非目标：不禁止 raw GraphQL，不自动 replay 任意 mutation，不推断任意 GraphQL document 的幂等性。

验收重点：结构化子集能解析 provider scope、operation kind、replay policy、lookup/manual attention
规则和 redacted result summary；unknown mutation 不自动重放。

为什么单独拆分：任意 GraphQL document 无法安全静态判断副作用和幂等性，需要先定义小而明确的操作模型。

## 验证入口

本 issue 不改 Elixir runtime 行为，现有测试足以作为代码证据。文档变更建议验证：

```bash
git diff --check
rg -n "provider exit|ProviderGovernance|hub_governed|legacy_direct_scoped_non_goal|unsupported_manual_attention|future_migration_candidate|non_runtime_provider_access" README.md SPEC.md DEPLOY.md elixir/README.md docs elixir/docs
```

如果 reviewer 要复核 Hub-owned 关键路径，可运行已有 targeted tests：

```bash
cd elixir
mise exec -- mix test \
  test/symphony_elixir/hub_provider_governance_test.exs \
  test/symphony_elixir/hub_poll_coordinator_test.exs \
  test/symphony_elixir/hub_runtime_test.exs \
  test/symphony_elixir/hub_real_candidate_scan_executor_test.exs \
  test/symphony_elixir/hub_provider_tool_routing_test.exs \
  test/symphony_elixir/hub_writeback_processor_test.exs \
  test/symphony_elixir/hub_real_writeback_executor_test.exs \
  test/symphony_elixir/dynamic_tool_test.exs \
  test/symphony_elixir/tracker_contract_test.exs \
  test/symphony_elixir/auto_update_test.exs \
  test/symphony_elixir/pull_request_test.exs
```

## 交叉引用

- #74 epic：https://github.com/JhihJian/symphony/issues/74
- #199 coverage audit issue：https://github.com/JhihJian/symphony/issues/199
- #201 baseline issue：https://github.com/JhihJian/symphony/issues/201
- #74 remaining capability audit：[`docs/hub-mode-issue-74-remaining-capability-coverage-audit.md`](hub-mode-issue-74-remaining-capability-coverage-audit.md)
- closure report coverage audit：[`docs/hub-cutover-closure-report-coverage-audit.md`](hub-cutover-closure-report-coverage-audit.md)
- closure report packet dry-run：[`docs/hub-cutover-closure-report-packet-dry-run.md`](hub-cutover-closure-report-packet-dry-run.md)
