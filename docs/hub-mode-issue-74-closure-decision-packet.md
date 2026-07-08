# Hub mode Issue #74 closure decision packet

本文档是 #205 交付的 #74 epic closure decision packet，用于帮助 Owner 对
`Add Symphony Hub mode for device-level multi-project coordination` 做关闭判断。它不是
#171/#172 的大范围 closure report，也不是 #199、#201、#203 的局部审计替代品；它只把这些审计与
fixture baseline 的结论收束成一个 #74 关闭决策入口。

## 结论

#74 当前 Hub baseline 已达到 `closure_ready`：仓库内已有足够代码、测试、fixture 和文档证据支撑
“显式 Hub mode 的可审查基线”。Owner 后续可以引用本文档和下列证据评论或关闭 #74；关闭动作仍由
Owner 执行。

该结论只覆盖当前 Hub baseline：

- 显式 Hub runtime / scheduler。
- 多项目注册、配置快照和 provider-neutral IssueRef。
- Hub-owned candidate scan、provider governance、poll coordination 和 safe writeback 子集。
- runtime ledger、dispatch boundary、worker handoff/lifecycle、writeback intent/result 和设备级观测。
- migration/cutover dry-run、只读 decision surfaces、Dashboard/API 明细和 restart/replay safe fixture。

该结论不覆盖 legacy single-project runtime 全量迁移、raw provider escape hatch 迁移、durable execution
queue、自动 retry/replay、一键迁移或 legacy service takeover。

## 关联证据

| 证据 | 作用 |
| --- | --- |
| #74 | Hub mode epic，定义设备级多项目协调目标。 |
| #199 / PR #200 | 新增 [`docs/hub-mode-issue-74-remaining-capability-coverage-audit.md`](hub-mode-issue-74-remaining-capability-coverage-audit.md)，把 #74 原始目标映射到已交付 issue/PR/代码/测试/文档，并列出 remaining gaps。 |
| #201 / PR #202 | 新增 [`docs/hub-provider-exit-residual-coverage-decision-baseline.md`](hub-provider-exit-residual-coverage-decision-baseline.md)，把 provider exit residual 分成 `hub_governed`、`legacy_direct_scoped_non_goal`、`unsupported_manual_attention`、`future_migration_candidate` 和 `non_runtime_provider_access`。 |
| #203 / PR #204 | 新增 `elixir/test/support/hub_runtime_ledger_restart_replay_fixture.exs`，并通过 `hub_runtime_ledger_test.exs`、`hub_device_observability_test.exs` 证明脱敏 Hub runtime facts 在模拟重启后能被 RuntimeLedger、DeviceObservability 和 `/api/v1/state` 一致解释。 |
| #205 | 本 closure decision packet，把 #199 remaining gaps 的处理结论写入仓库。 |

## 八组能力 closure 状态

| #74 能力组 | 当前状态 | 结论 |
| --- | --- | --- |
| 设备级 Hub 运行模式 | `covered` | 显式 Hub entrypoint、runtime snapshot、manual refresh 和 scheduler baseline 已交付；legacy `symphony@project.service` 不会被静默接管。 |
| 多项目注册与配置快照 | `covered` | `HUB.yaml` registry、project snapshot、IssueRef 和单项目配置错误隔离已有代码和测试。 |
| 统一 provider 请求治理 | `closure_ready` | Hub-owned candidate scan、provider governance、poll coordination、structured opt-in routing 和 safe writeback 子集已有代码/测试；legacy direct、raw GraphQL、unsupported writeback 和 non-runtime access 已由 #201 裁定，不阻塞当前 baseline closure。 |
| 可恢复运行账本 | `covered` | RuntimeLedger、dispatch/start/lifecycle/writeback facts 和 #203 restart/replay safe fixture 已证明当前 safe fields 可在模拟重启后解释。 |
| 原子派发与 agent 生命周期管理 | `covered` | candidate intake、dispatch planning/application、start handoff、real starter opt-in、lifecycle reconciliation 和 workspace/capacity 解释已有 targeted tests。 |
| provider 写回 intent/result、去重和 unknown/manual attention | `closure_ready` | safe subset 的 intent/result、dedupe、lookup/manual-attention 和 replay guard 已覆盖；PR create、普通 append comment、raw GraphQL 等非幂等或 unsupported path 继续保持 manual attention / future migration candidate。 |
| Hub mode 与 legacy 多实例模型的迁移边界 | `covered` | activation preflight、host probe、readiness、cutover gate、dry-run/history/permit/authorization/outcome/closeout/replay decision 和 closure report packet 都保持 operator-controlled 边界。 |
| Dashboard/API 设备级总览和项目级明细 | `covered` | `/api/v1/state` 和 Live Dashboard 已展示 Hub overview/detail、provider pressure、workspace、writeback、manual attention、cutover decision 和 closure packet safe summaries。 |

## #199 remaining gaps 处理结论

### 1. provider exit residual

状态：`closure_ready`

#201 已完成 provider exit residual 的 inventory / decision baseline。处理结论如下：

| 分类 | 结论 |
| --- | --- |
| `hub_governed` | Hub provider request model、Hub poll coordination、Hub runtime candidate scan、default executor skeleton、real candidate scan read 子集、candidate intake/dispatch 后续处理、显式 Hub routing context 下的 structured provider tools、writeback intent/result processor、real writeback safe subset、Hub `/refresh` 入口，已经有 Hub-governed 代码/测试/文档证据。 |
| `legacy_direct_scoped_non_goal` | structured dynamic provider tools 默认直连、legacy single-project tracker poll / reconciliation、legacy workflow-stage writeback、provider adapters、GitHub Project/status adapter、legacy Dashboard `/refresh` 等保持兼容边界。它们不是当前 #74 baseline closure blocker，也不能写成已经 Hub-governed。 |
| `unsupported_manual_attention` | real candidate scan unsupported operation、real writeback PR create / 普通 append comment / unsupported operation、raw `linear_graphql` 等继续要求 provider lookup、manual attention、permanent failure 或显式人工边界，不允许自动 replay。 |
| `future_migration_candidate` | legacy tracker read/reconciliation、structured read-only PR/issue/Project status 查询、raw `linear_graphql` 的结构化替代子集，可后续单独开票迁移。 |
| `non_runtime_provider_access` | auto-update、Dashboard safe summaries、cutover dry-run / closure report packet、PR/issue 审查类读取等不参与 Hub runtime provider queue 覆盖判断。 |

因此，provider exit residual 不再是未解释的 remaining gap。它被收束为：当前 Hub-owned path 已覆盖；
legacy direct/raw/provider maintenance 路径按 #201 分类为 scoped non-goal、unsupported/manual-attention、
future migration candidate 或 non-runtime provider access。

### 2. restart/replay fixture

状态：`covered`

#203 已提供 restart/replay safe fixture baseline：同一份脱敏多项目 RuntimeLedger facts 经过 snapshot
reload / `RuntimeLedger.replay` 后，可以被 DeviceObservability 和 Presenter `/api/v1/state` 一致解释。
覆盖范围包括 active attempt、completed attempt、retry/backoff、workspace retained/released、
writeback replay-safe、provider lookup、unknown/manual attention 和 conflict 降级。

该结论仍不表示已实现 database、WAL、durable execution queue、自动 retry/replay、真实 provider 调用、
dispatch、worker starter、writeback executor、systemd、workspace hook、配置修改或 legacy service
takeover。

### 3. closure packet

状态：`closure_ready`

本文件交付 #199 remaining gap 3：提供仓库内短小、可审查、只读的 #74 closure decision packet。它的边界是
整理和裁定现有证据，不关闭 #74，不改变 Project 状态，不创建 follow-up issue，不新增 runtime/API/
Dashboard/provider/dispatch/worker/writeback/systemd/workspace hook/config 行为。

## Owner 关闭 #74 时应引用

Owner 后续评论或关闭 #74 时，建议引用：

- 本文档：[`docs/hub-mode-issue-74-closure-decision-packet.md`](hub-mode-issue-74-closure-decision-packet.md)。
- #199 coverage audit：[`docs/hub-mode-issue-74-remaining-capability-coverage-audit.md`](hub-mode-issue-74-remaining-capability-coverage-audit.md)。
- #201 provider exit decision baseline：[`docs/hub-provider-exit-residual-coverage-decision-baseline.md`](hub-provider-exit-residual-coverage-decision-baseline.md)。
- #203 restart/replay safe fixture：`elixir/test/support/hub_runtime_ledger_restart_replay_fixture.exs` 以及 `hub_runtime_ledger_test.exs`、`hub_device_observability_test.exs`。
- 关键 issue/PR：#199 / PR #200、#201 / PR #202、#203 / PR #204、#205。

建议评论口径：

> #74 当前显式 Hub mode baseline 已 closure-ready。Hub-owned runtime、provider governance、dispatch、
> worker lifecycle、writeback safe subset、device observability、migration/cutover dry-run、Dashboard/API
> detail 和 restart/replay safe fixture 已有仓库内证据；legacy direct/raw/provider maintenance residual 已按
> #201 分类为 scoped non-goal、unsupported/manual-attention、future migration candidate 或 non-runtime
> provider access。后续迁移可以单独开票，不阻塞当前 #74 baseline closure。

## 关闭 #74 时不能声称

关闭 #74 不应声称：

- legacy single-project runtime、tracker adapter、poll loop、stage writeback 或 dynamic tool 默认直连已迁移到 Hub。
- raw `linear_graphql` 已被 Hub-governed 或可自动 replay。
- PR create、普通 append comment、unsupported provider operation 已成为完整 Hub real writeback 能力。
- 已实现 database/WAL、durable execution queue、自动 retry/replay、跨进程 lock、一键迁移或 legacy service takeover。
- cutover dry-run、closeout、replay decision、replay request audit、closure chain 或 closure report packet 会自动调用 provider、dispatch、worker starter、writeback、systemd、workspace hook 或配置修改路径。
- 本 issue 已创建或投递任何 follow-up issue。

## 可选 follow-up 候选

这些候选只用于后续迁移规划，不是 #74 当前 baseline closure blocker。

### 候选 1：legacy single-project tracker read/reconciliation 迁移裁定

目标：在 Owner 明确要继续收敛 legacy provider reads 时，单独设计 legacy `fetch_runnable_issues`、
running/blocked `fetch_issue_states_by_ids` 和 `read_issue_stage` 到 Hub-governed read boundary 的迁移，
或明确长期保持 legacy scoped non-goal。

非目标：不接管 legacy writeback，不改变 `AgentRunner` stage loop，不自动迁移
`symphony@project.service`，不新增 durable queue 或跨进程 lock。

不是 blocker 的原因：当前 #74 baseline 的目标是显式 Hub mode；legacy runtime 兼容直连已由 #201 明确为
`legacy_direct_scoped_non_goal`。

### 候选 2：structured read-only PR / issue / Project status 查询的 Hub-governed routing 扩展

目标：把 PR lookup、review/comment/check read、GitHub issue detail/comment read、Project/status read
整理成 opt-in Hub-governed structured read 子集，提供统一 backoff/circuit/result summaries。

非目标：不迁移 PR create、普通 append comment、raw GraphQL、stage writeback；不改变 dynamic tool 默认直连行为。

不是 blocker 的原因：这些路径主要是审查、人工复核或兼容读取；当前 Hub runtime poll/writeback baseline
已有 governed candidate scan 和 safe writeback 子集。

### 候选 3：raw `linear_graphql` 的结构化替代子集

目标：为 Linear 常用 issue/stage/comment 操作定义结构化工具或 operation schema，让可识别子集进入
`ProviderGovernance`，同时保留 raw `linear_graphql` 作为 escape hatch。

非目标：不禁止 raw GraphQL，不自动 replay 任意 mutation，不推断任意 GraphQL document 的幂等性。

不是 blocker 的原因：任意 GraphQL document 无法安全静态判断副作用、scope 和 replay policy；当前 #74
baseline 只需要把它裁定为 unsupported/manual-attention 或后续结构化迁移候选。
