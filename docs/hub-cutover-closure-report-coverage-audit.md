# Hub cutover closure report coverage audit baseline

本文档是 #197 的仓库内覆盖审计基线，用来收束 #171 和 #172 两个历史大票据的 closure report
范围。它只核对 #171/#172 原始目标如何被 #173-#195 拆分切片覆盖、缩小或转为非目标；它不关闭
#171/#172，不修改 Project 状态，不恢复“一次性交付完整 closure report”的大范围实现方式。

## 审计范围

- 历史目标：#171 `Add Hub cutover execution closure report baseline`，当前 GitHub issue 仍 open，
  Project 状态为 `Backlog`；#172 `Add Hub cutover closure report core read model baseline`，当前
  GitHub issue 仍 open，Project 状态为 `Blocked`。
- 拆分切片：#173/#175/#177/#179/#181/#183/#185/#187/#189/#191/#193/#195，均已关闭并由
  PR #174/#176/#178/#180/#182/#184/#186/#188/#190/#192/#194/#196 合并。
- 本基线只引用脱敏 safe summary、仓库路径、字段名、issue/PR 编号和本地验证命令；不引用 token、
  Authorization/cookie、secret env、raw provider payload、raw config、raw systemd/hook/app-server
  输出、完整 prompt/transcript、完整 PR/comment body、本机私有路径或异常栈。

## 覆盖状态定义

- `covered`：当前仓库中已有代码/测试覆盖该行为或字段，并有可本地复现的验证入口。
- `covered_by_split`：原 #171/#172 验收点已经由 #173-#195 的多个小切片组合覆盖。
- `narrowed_non_goal`：原大票据中的能力被明确缩小为非目标；当前实现只保留只读 safe summary 或展示。
- `owner_decision_needed`：代码/测试/文档证据已经明确，但是否关闭、评论或重新拆票需要 Owner 决策。
- `remaining_gap`：当前仓库仍缺少最小、可独立交付的能力。本文档未发现必须由 #197 新拆出的
  `remaining_gap`。

## 拆分交付索引

| Issue | PR | 覆盖主题 | 主要仓库证据 |
| --- | --- | --- | --- |
| #173 | #174 | closure chain 最小合同，绑定 project/provider scope、operation/source、request、permit、authorization、guard、outcome 和 safe fingerprint | `elixir/lib/symphony_elixir/hub/cutover_closure_chain.ex`，`elixir/test/symphony_elixir/hub_cutover_closure_chain_test.exs` |
| #175 | #176 | open outcome 分类：`closed_succeeded`、`closed_no_side_effect`、`open_retryable`、`open_manual_attention` | `elixir/lib/symphony_elixir/hub/cutover_closure_chain.ex`，`elixir/test/symphony_elixir/hub_cutover_closure_chain_test.exs` |
| #177 | #178 | closeout、replay decision、replay request audit 的 retained reference status | `elixir/lib/symphony_elixir/hub/cutover_closure_chain.ex`，`elixir/test/symphony_elixir/hub_cutover_closure_chain_test.exs` |
| #179 | #180 | Runtime/API closure chain safe snapshot | `elixir/lib/symphony_elixir/hub/runtime.ex`，`elixir/lib/symphony_elixir_web/presenter.ex`，`elixir/test/symphony_elixir/hub_runtime_test.exs` |
| #181 | #182 | Live Dashboard closure chain 设备级和项目级展示 | `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`，`elixir/test/symphony_elixir/hub_dashboard_detail_test.exs` |
| #183 | #184 | operator conclusion、required actions、blocked-by、safe evidence references | `elixir/lib/symphony_elixir/hub/cutover_closure_conclusion.ex`，`elixir/test/symphony_elixir/hub_cutover_closure_conclusion_test.exs` |
| #185 | #186 | Runtime/API conclusion safe snapshot 和 DeviceObservability 接入 | `elixir/lib/symphony_elixir/hub/runtime.ex`，`elixir/lib/symphony_elixir/hub/device_observability.ex`，`elixir/test/symphony_elixir/hub_device_observability_test.exs` |
| #187 | #188 | Live Dashboard conclusion 展示 | `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`，`elixir/test/symphony_elixir/hub_dashboard_detail_test.exs` |
| #189 | #190 | closure report safe packet 库级 baseline | `elixir/lib/symphony_elixir/hub/cutover_closure_report_packet.ex`，`elixir/test/symphony_elixir/hub_cutover_closure_report_packet_test.exs` |
| #191 | #192 | Runtime/API packet safe snapshot 和 DeviceObservability 接入 | `elixir/lib/symphony_elixir/hub/runtime.ex`，`elixir/lib/symphony_elixir/hub/device_observability.ex`，`elixir/test/symphony_elixir/hub_runtime_test.exs` |
| #193 | #194 | Live Dashboard packet 展示 | `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`，`elixir/test/symphony_elixir/hub_dashboard_detail_test.exs` |
| #195 | #196 | dry-run fixture、runbook、Presenter/API/Dashboard 一致性验证 | `elixir/test/support/hub_cutover_closure_report_packet_dry_run_fixture.exs`，`elixir/test/symphony_elixir/hub_cutover_closure_report_packet_dry_run_test.exs`，`docs/hub-cutover-closure-report-packet-dry-run.md` |

## 覆盖矩阵

| #171/#172 原始验收点 | 状态 | 证据类型 | 稳定证据引用 | 审计结论 |
| --- | --- | --- | --- | --- |
| closure chain 绑定 project/provider scope、operation/source、request、permit、authorization、guard、outcome 和 safe evidence fingerprint | `covered_by_split` | 代码 + 测试 | #173/#175/#177，PR #174/#176/#178；`CutoverClosureChain.build/2`；`hub_cutover_closure_chain_test.exs`；`hub_runtime_test.exs` | chain 只从 safe summary/fixture 组织证据，输出 `provider_scope`、`operation`、`side_effect_source`、`safe_evidence_fingerprints` 和 `safe_evidence_fingerprint`，不读取 raw provider payload。 |
| retained closeout、replay decision、replay request audit 引用状态 | `covered_by_split` | 代码 + 测试 | #177，PR #178；`cutover_closure_chain.ex`；字段 `closeout_reference_status_counts`、`replay_decision_reference_status_counts`、`replay_request_audit_reference_status_counts` | retained reference 只影响只读解释，不把 open outcome 推导为 success、resolved 或 retry allowed。 |
| `no_chain` / `no_request` safe fallback | `covered` | 代码 + 测试 | #173/#189/#195，PR #174/#190/#196；`hub_cutover_closure_report_packet_test.exs`；dry-run fixture projects `no-request`、`no-chain` | 缺失 chain 或 request 时降级为无执行含义的 safe 状态，不显示 pending execution、pending retry、queued replay 或 legacy takeover。 |
| `closed_succeeded` 与 `closed_no_side_effect` 区分 | `covered_by_split` | 代码 + 测试 | #175/#189/#195，PR #176/#190/#196；`CutoverClosureReportPacket.build/2`；`hub_runtime_test.exs`；dry-run fixture projects `success`、`clear` | `closed_succeeded` 才表示 operation success；`closed_no_side_effect` 只表示无副作用闭环。 |
| `open_retryable` 与 `open_manual_attention` 分类 | `covered_by_split` | 代码 + 测试 | #175/#183/#189/#195，PR #176/#184/#190/#196；`cutover_closure_conclusion.ex`；`hub_cutover_closure_report_packet_dry_run_test.exs` | retryable 只要求显式 retry consideration；manual/unknown 只要求 operator closeout 或人工复核，不自动 retry/replay。 |
| `stale` / `conflict` / `malformed` / `unsupported` 降级 | `covered_by_split` | 代码 + 测试 | #177/#183/#189/#195，PR #178/#184/#190/#196；`cutover_closure_chain.ex`；`cutover_closure_conclusion.ex`；`hub_runtime_test.exs` | 异常状态优先保守展示为 review required，不把不匹配证据合并到成功闭环。 |
| Runtime/API safe snapshot 接入 closure chain | `covered` | 代码 + 测试 | #179，PR #180；`Runtime.build_snapshot/4`；`Presenter.state_payload/2`；字段 `hub_cutover_closure_chain`、`hub_device_observability.overview.cutover_closure_chain` | `/api/v1/state` 暴露 chain safe snapshot，并在 legacy/missing 输入下安全降级。 |
| Runtime/API safe snapshot 接入 operator conclusion | `covered` | 代码 + 测试 | #185，PR #186；`runtime.ex`；`device_observability.ex`；字段 `hub_cutover_closure_conclusion`、`hub_device_observability.overview.cutover_closure_conclusion` | conclusion 从 chain safe snapshot 派生，不重新聚合 raw evidence。 |
| Runtime/API safe snapshot 接入 closure report packet | `covered` | 代码 + 测试 | #191，PR #192；`cutover_closure_report_packet.ex`；`runtime.ex`；`presenter.ex`；字段 `hub_cutover_closure_report_packet` | packet 在 API 顶层和 DeviceObservability overview/project/detail 中可见，仍是只读组织层。 |
| `hub_device_observability` 设备级和项目级摘要 | `covered` | 代码 + 测试 | #179/#185/#191，PR #180/#186/#192；`device_observability.ex`；`hub_device_observability_test.exs` | 设备 overview 和 projects/detail 都暴露 chain、conclusion、packet safe summary，并保持 project/provider scope 隔离。 |
| Live Dashboard 设备级和项目级 closure chain 展示 | `covered` | 代码 + 测试 | #181，PR #182；`dashboard_live.ex`；`hub_dashboard_detail_test.exs` | Dashboard 只展示 Runtime/API 已有 safe snapshot，不新增执行入口。 |
| Live Dashboard operator conclusion 展示 | `covered` | 代码 + 测试 | #187，PR #188；`dashboard_live.ex`；字段 conclusion badge、severity/attention、summary code、required action、blocked-by、safe evidence/fingerprint | Dashboard 展示 conclusion，不重新读取 request/permit/authorization/guard/outcome。 |
| Live Dashboard closure report packet 展示 | `covered` | 代码 + 测试 | #193，PR #194；`dashboard_live.ex`；字段 `Closure Report Packet`、`report status`、`report action`、`report blocked`、`report section`、`report fp` | Dashboard 展示 packet 的设备总览和项目明细，字段与 API safe summary 对齐。 |
| operator conclusion、required actions、blocked-by、section status、safe evidence references | `covered_by_split` | 代码 + 测试 | #183/#189/#191/#193/#195，PR #184/#190/#192/#194/#196；`cutover_closure_conclusion.ex`；`cutover_closure_report_packet.ex` | conclusion 和 packet 均输出 `summary_code`、`required_action_codes`、`blocked_by`、`section_statuses`、`evidence_references` 和 safe fingerprints。 |
| dry-run fixture / runbook / API 与 Dashboard 一致性验证 | `covered` | fixture + 测试 + 文档 | #195，PR #196；`hub_cutover_closure_report_packet_dry_run_fixture.exs`；`hub_cutover_closure_report_packet_dry_run_test.exs`；`docs/hub-cutover-closure-report-packet-dry-run.md` | 同一个 safe fixture 驱动 Presenter、`/api/v1/state` 和 Live Dashboard，对多 project/provider scope、状态、actions/blockers/fingerprints 做一致性断言。 |
| README、SPEC、DEPLOY、`elixir/README.md` 对只读边界、非目标和拆分关系的说明 | `covered_by_split` | 文档 + 本审计 | #195/#197，PR #196 和本 PR；`README.md`、`SPEC.md`、`DEPLOY.md`、`elixir/README.md`、本文件 | 现有文档已说明 dry-run/packet 非目标；本审计补上 #171/#172 到 #173-#195 的总覆盖矩阵入口。 |
| 不调用 provider、dispatch、worker starter、writeback、systemd、workspace hook、config mutation | `covered` | 测试 + 文档 | #195，PR #196；`hub_cutover_closure_report_packet_dry_run_test.exs` 中 `dry-run fixture source stays detached from execution and mutation modules`；字段 `provider_calls`、`dispatch_calls`、`worker_start_calls`、`writeback_calls`、`systemd_calls`、`config_mutation` | dry-run fixture 和 packet 边界断言不连接执行/变更模块。 |
| 不自动 retry/replay，不创建或消费 authorization，不接管 legacy service | `covered_by_split` | 代码 + 测试 + 文档 | #173-#195；字段 `auto_retry_allowed`、`auto_replay_allowed`、`pending_execution`、`pending_retry`、`queued_replay`、`legacy_takeover` | 所有 closure report 相关层都保持只读；retry/replay 只作为人工后续判断或引用状态，不是自动队列。 |
| 完整 #171 operator-facing execution closure report 一次性交付 | `narrowed_non_goal` | 文档 + 拆分策略 | #171/#172 历史背景；#173-#195 拆分链；`README.md`、`DEPLOY.md`、`SPEC.md` 对 “不是完整 #171 report” 的说明 | 原大范围已被缩小为 safe chain/conclusion/packet/dry-run baseline，不建议恢复为单个大票据。 |
| 自动 retry/replay、durable execution queue、一键迁移、legacy service takeover | `narrowed_non_goal` | 测试 + 文档 | #171/#172 非目标；#195 dry-run test；字段 `auto_retry_allowed: false`、`auto_replay_allowed: false`、`queued_replay: false`、`legacy_takeover: false` | 这些能力不是 closure report coverage baseline 的缺口；如未来确需建设，应单独建模、单独拆 issue。 |
| 自动关闭 #171/#172 或修改其 Project 状态 | `owner_decision_needed` | tracker 事实 + 本审计 | #171 当前 open / Backlog；#172 当前 open / Blocked；本 issue 明确非目标 | 需要 Owner 基于本审计到 #171/#172 留言或关闭；#197 不自动操作历史票据。 |

## 关键 safe summary 字段

审计时优先检查以下字段，而不是 raw evidence：

- API 顶层：`hub_cutover_closure_chain`、`hub_cutover_closure_conclusion`、
  `hub_cutover_closure_report_packet`。
- DeviceObservability：`hub_device_observability.cutover_closure_chain`、
  `hub_device_observability.cutover_closure_conclusion`、
  `hub_device_observability.cutover_closure_report_packet`。
- Overview：`hub_device_observability.overview.cutover_closure_chain`、
  `hub_device_observability.overview.cutover_closure_conclusion`、
  `hub_device_observability.overview.cutover_closure_report_packet`。
- Project/detail：`hub_device_observability.projects[*].cutover_closure_chain`、
  `hub_device_observability.projects[*].cutover_closure_conclusion`、
  `hub_device_observability.projects[*].cutover_closure_report_packet`、
  `hub_device_observability.projects[*].detail.closure_chain`、
  `hub_device_observability.projects[*].detail.closure_conclusion`、
  `hub_device_observability.projects[*].detail.closure_report_packet`。
- Packet/conclusion 字段：`report_status`、`operator_conclusion`、`summary_code`,
  `required_action_codes`、`blocked_by`、`section_statuses`、`provider_scope`,
  `evidence_references`、`safe_evidence_fingerprint`、`safe_evidence_fingerprints`,
  `read_only`、`no_side_effects`、`actions_are_advisory`、`auto_retry_allowed`,
  `auto_replay_allowed`、`pending_execution`、`pending_retry`、`queued_replay`,
  `legacy_takeover`。

## 本地验证入口

推荐使用以下 targeted tests 复核本审计引用的代码路径：

```bash
cd elixir
mise exec -- mix test \
  test/symphony_elixir/hub_cutover_closure_chain_test.exs \
  test/symphony_elixir/hub_cutover_closure_conclusion_test.exs \
  test/symphony_elixir/hub_cutover_closure_report_packet_test.exs \
  test/symphony_elixir/hub_cutover_closure_report_packet_dry_run_test.exs \
  test/symphony_elixir/hub_device_observability_test.exs \
  test/symphony_elixir/hub_dashboard_detail_test.exs \
  test/symphony_elixir/hub_runtime_test.exs
```

只需复核 dry-run 一致性时，可运行：

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/hub_cutover_closure_report_packet_dry_run_test.exs
```

文档链接和 issue/PR 引用可用：

```bash
git diff --check
rg -n "#17[123579]|#18[13579]|#19[1356]|hub-cutover-closure-report" README.md SPEC.md DEPLOY.md elixir/README.md docs
```

## 收束建议

#171 可以由后续 Owner 作为“已由 #173-#195 拆分切片覆盖/取代，并把自动 retry/replay、durable
execution queue、一键迁移、legacy service takeover 等能力明确缩小为非目标”来评论并关闭。本文档未发现
必须从 #171 再拆出的最小 `remaining_gap` issue。

#172 可以由后续 Owner 作为“core read model 已由 closure chain、operator conclusion、report packet、
Runtime/API、DeviceObservability、Dashboard 和 dry-run fixture/runbook 覆盖”来评论并关闭，或至少解除
“大范围 read model 模糊阻塞”的阻塞理由。本文档未发现必须保留 #172 `Blocked` 状态的代码/测试缺口。

建议写入 #171/#172 的 comment 要点：

- #171/#172 的一次性交付范围已被 #173/#175/#177/#179/#181/#183/#185/#187/#189/#191/#193/#195
  拆成小切片并合并，对应 PR 为 #174/#176/#178/#180/#182/#184/#186/#188/#190/#192/#194/#196。
- 已覆盖 closure chain、status semantics、Runtime/API safe snapshot、DeviceObservability、Live
  Dashboard、operator conclusion/report packet、dry-run fixture/runbook 和只读副作用边界。
- 当前剩余不是代码缺口，而是 Owner 对历史大票据的收束决策；若未来要建设自动 retry/replay、durable
  execution queue、一键迁移或 legacy takeover，应作为新的明确能力单独拆票，不应恢复 #171/#172 的大范围。

## 交叉引用

- Dry-run runbook：[`docs/hub-cutover-closure-report-packet-dry-run.md`](hub-cutover-closure-report-packet-dry-run.md)
- 项目说明：[`README.md`](../README.md)
- 行为规范：[`SPEC.md`](../SPEC.md)
- 部署说明：[`DEPLOY.md`](../DEPLOY.md)
- Elixir 实现说明：[`elixir/README.md`](../elixir/README.md)
