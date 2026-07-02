# Hub cutover closure report packet dry-run runbook

本文档记录一个仓库内可复现的 Hub cutover closure report packet dry-run 基线。它用于证明
closure report packet 如何从脱敏 safe fixture 进入 Presenter、`/api/v1/state` 和 Live Dashboard，
并确认该路径仍然只是只读报告。

## 本地验证入口

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/hub_cutover_closure_report_packet_dry_run_test.exs
```

该测试加载版本化 fixture：

```text
SymphonyElixir.HubCutoverClosureReportPacketDryRunFixture
```

当前 fixture version 为 `1`，生成时间固定为 `2026-07-02T09:00:00Z`。fixture 只构造
`hub_cutover_closure_chain`、`hub_cutover_closure_conclusion`、`hub_cutover_closure_report_packet`
和 `hub_device_observability` 所需的 safe summary 字段，不读取或重新聚合原始 cutover request、
permit、authorization、guard、outcome、closeout、replay decision 或 replay request audit 证据。

## 覆盖场景

fixture 覆盖多个 project/provider scope，项目之间的 provider scope、required action、blocked-by、
safe evidence fingerprint/reference 必须保持隔离：

- `success` / `github:org/success`：`closed_succeeded`，Dashboard/API 显示 `fully_closed`。
- `clear` / `gitlab:group/clear`：`closed_no_side_effect`，不显示为 operation success。
- `retry` / `github:org/retry`：`open_retryable`，只显示需要显式 retry consideration。
- `unknown-manual` / `github:ops/unknown-manual`：`open_manual_attention`，显示人工处理。
- `stale` / `gitlab:group/stale`：异常阻断状态，显示 stale evidence review。
- `no-request` / `github:org/no-request`：安全降级为 `no_request`。
- `no-chain` / `gitlab:group/no-chain`：安全降级为 `no_chain`。

## 预期观察字段

`/api/v1/state` 应暴露以下只读字段：

- `hub_cutover_closure_report_packet`
- `hub_device_observability.cutover_closure_report_packet`
- `hub_device_observability.overview.cutover_closure_report_packet`
- `hub_device_observability.projects[*].cutover_closure_report_packet`
- `hub_device_observability.projects[*].detail.closure_report_packet`

重点检查字段包括：

- `report_status`
- `operator_conclusion`
- `summary_code`
- `required_action_codes`
- `blocked_by`
- `section_statuses`
- `provider_scope`
- `evidence_references`
- `safe_evidence_fingerprint` / `safe_evidence_fingerprints`
- `read_only`、`no_side_effects`、`actions_are_advisory`
- `auto_retry_allowed`、`auto_replay_allowed`、`pending_execution`、`pending_retry`、
  `queued_replay`、`legacy_takeover`

Live Dashboard 应在 Hub 设备总览和 Hub 项目明细中显示同一批 safe packet 字段。Dashboard 展示可以有
文案映射，例如项目行会显示 `report status ...`、`report action ...`、`report blocked ...`、
`report section ...`、`scope ...` 和 `report fp ...`，但语义必须与 API safe summary 对齐。

## 安全边界

此 dry-run baseline 不执行任何 Hub cutover 操作。它不得：

- 调用 provider。
- 创建或消费 authorization。
- 调用 dispatch mutation。
- 启动 worker。
- 执行 writeback。
- 操作 systemd。
- 调用 workspace hook。
- 修改 runtime、workflow、tracker 或 Hub 配置。
- 自动 retry/replay。
- 创建 durable execution queue。
- 一键迁移。
- 接管 legacy service。

输出必须保持脱敏，不应包含凭据、授权头或 cookie 值、secret env、原始配置、原始 provider payload、
原始 systemd/hook/app-server 输出、完整 prompt/transcript、完整 PR/comment body、本机私有路径或异常栈。

## 与历史拆分的关系

#171 曾尝试一次性交付完整 Hub cutover execution closure report，#172 作为 first split 仍然过大。
#173/#175/#177/#179/#181/#183/#185/#187/#189/#191/#193 已经逐片交付 closure chain、open outcome、
closeout/replay reference、Runtime/API、Dashboard、operator conclusion、report packet 和 Dashboard
packet 展示。

本 dry-run baseline 建在这些已完成切片之上，只补充稳定、可复现的 evidence 路径和一致性验证。它不恢复
#171/#172 的大范围实现方式，也不表示 #171 或 #172 已自动关闭。
