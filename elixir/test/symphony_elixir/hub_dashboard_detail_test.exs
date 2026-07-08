defmodule SymphonyElixir.HubDashboardDetailTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Hub.{CutoverClosureChain, DeviceObservability}

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule StaticOrchestrator do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    original_endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, original_endpoint_config)
    end)

    :ok
  end

  test "dashboard renders Hub device overview and project detail when Hub summary exists" do
    hub_name = Module.concat(__MODULE__, :HubDashboardRuntime)

    start_supervised!(
      {StaticOrchestrator, name: hub_name, snapshot: hub_snapshot()},
      id: :hub_dashboard_runtime
    )

    start_endpoint(orchestrator: hub_name)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "当前工作队列"
    assert html =~ "Hub 活跃尝试"
    assert html =~ "pending start 0 · workspace lease 1"
    assert html =~ "Hub 仍在收敛"
    assert html =~ "普通运行中会话为 0"
    assert html =~ "attempt 1 · lease 1 · lifecycle 1"
    assert html =~ ~s(href="#hub-project-alpha")
    assert html =~ "Hub 项目焦点"
    assert html =~ "下一步：resolve_writeback_manual_attention"
    assert html =~ ~s(href="#hub-project-gamma")
    assert html =~ ~s(id="hub-project-alpha")
    assert html =~ ~s(href="#running-sessions")
    assert html =~ ~s(href="#blocked-sessions")
    assert html =~ ~s(href="#retry-queue")
    assert_order(html, "当前工作队列", "Hub 项目焦点")
    assert_order(html, "Hub 项目焦点", "当前上下文")
    assert_order(html, "当前工作队列", "Hub 设备总览")
    assert_order(html, "Hub 项目焦点", "Hub 设备总览")
    refute html =~ "速率限制"

    assert html =~ "Hub 设备总览"
    assert html =~ "Hub 项目明细"
    assert html =~ "Migration Readiness"
    assert html =~ "Activation Plan / Ack"
    assert html =~ "Cutover Audit"
    assert html =~ "Execution Permit"
    assert html =~ "Execution Authorization"
    assert html =~ "Replay Decision"
    assert html =~ "Replay Request"
    assert html =~ "Closure Chain"
    assert html =~ "Closure Conclusion"
    assert html =~ "Closure Report Packet"
    assert html =~ "scheduler scheduled"
    assert html =~ "runtime_reconciliation"
    assert html =~ "provider_failure"
    assert html =~ "alpha"
    assert html =~ "ready"
    assert html =~ "closure closed_succeeded"
    assert html =~ "conclusion closed_succeeded"
    assert html =~ "gamma"
    assert html =~ "manual attention"
    assert html =~ "unknown_manual_attention"
    assert html =~ "plan unknown_manual_attention"
    assert html =~ "ack missing"
    assert html =~ "audit no_request"
    assert html =~ "permit no_request"
    assert html =~ "auth no_ready_permit"
    assert html =~ "replay blocked_unresolved_outcome"
    assert html =~ "replay request no_request"
    assert html =~ "closure open_manual_attention"
    assert html =~ "manual_attention_required"
    assert html =~ "summary closure_open_manual_attention_required"
    assert html =~ "actions resolve_manual_attention"
    assert html =~ "blocked manual_attention_required/open_manual_attention"
    assert html =~ "report manual_attention_required"
    assert html =~ "report status fully_closed"
    assert html =~ "report status manual_attention_required"
    assert html =~ "report action resolve_manual_attention"
    assert html =~ "report blocked manual_attention_required/open_manual_attention"
    assert html =~ "report section closure_chain open_manual_attention"
    assert html =~ "scope github:o/alpha"
    assert html =~ "scope github:g/gamma"
    assert html =~ "closeout refs current"
    assert html =~ "replay decision refs current"
    assert html =~ "request audit refs current"
    assert html =~ "replay reason matching_closeout_missing"
    assert html =~ "closure reason closeout_reference_current"
    assert html =~ "closure action record_cutover_replay_request_audit"
    assert html =~ "closure fp outcome=gamma-outcome-fp"
    assert html =~ "conclusion fp outcome=gamma-outcome-fp"
    assert html =~ "report fp outcome=gamma-outcome-fp"
    assert html =~ "auto replay allowed false"
    assert html =~ "auto retry allowed false"
    assert html =~ "pending execution false"
    assert html =~ "pending retry false"
    assert html =~ "queued replay false"
    assert html =~ "legacy takeover false"
    assert html =~ "ack resolve_writeback_manual_attention"
    assert html =~ "action resolve_writeback_manual_attention"
    assert html =~ "writeback pending"

    packet_panel = dashboard_panel(html, "Closure Report Packet")
    assert packet_panel =~ "manual_attention_required"
    refute packet_panel =~ "fully_closed"

    alpha_row = project_row(html, "alpha")
    assert alpha_row =~ "scope github:o/alpha"
    assert alpha_row =~ "report fp outcome=alpha-outcome-fp"
    refute alpha_row =~ "github:g/gamma"
    refute alpha_row =~ "gamma-outcome-fp"

    gamma_row = project_row(html, "gamma")
    assert gamma_row =~ "scope github:g/gamma"
    assert gamma_row =~ "report fp outcome=gamma-outcome-fp"
    refute gamma_row =~ "github:o/alpha"
    refute gamma_row =~ "alpha-outcome-fp"

    refute html =~ "ghp_secret"
    refute html =~ "Bearer"
    refute html =~ "raw systemd output"
    refute html =~ "raw provider payload"
    refute html =~ "complete transcript"
    refute html =~ "complete comment body"
    refute html =~ "/home/jhihjian/private"
    refute html =~ "queued replay true"
    refute html =~ "automatic retry"
    refute html =~ "migration queued"
  end

  test "dashboard renders closure report packet matrix conservatively without leaking raw fields" do
    hub_name = Module.concat(__MODULE__, :HubDashboardReportPacketMatrix)

    start_supervised!(
      {StaticOrchestrator, name: hub_name, snapshot: report_packet_matrix_snapshot()},
      id: :hub_dashboard_report_packet_matrix
    )

    start_endpoint(orchestrator: hub_name)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Closure Report Packet"

    packet_panel = dashboard_panel(html, "Closure Report Packet")
    assert packet_panel =~ "malformed_input_review_required"
    assert packet_panel =~ "conclusion input_malformed"
    assert packet_panel =~ "actions fix_malformed_chain_input, request_explicit_retry_consideration, resolve_manual_attention"
    assert packet_panel =~ "blocked malformed_report/malformed"
    assert packet_panel =~ "sections closure_chain malformed"
    assert packet_panel =~ "evidence device/malformed/closure_input_malformed"
    assert packet_panel =~ "packet=device-report-fp"
    assert packet_panel =~ "read-only true"
    assert packet_panel =~ "no side effects true"
    assert packet_panel =~ "auto retry allowed false"
    assert packet_panel =~ "auto replay allowed false"
    assert packet_panel =~ "pending execution false"
    assert packet_panel =~ "pending retry false"
    assert packet_panel =~ "queued replay false"
    assert packet_panel =~ "legacy takeover false"
    refute packet_panel =~ "fully_closed"

    assert_project_report(
      html,
      "success",
      [
        "report status fully_closed",
        "scope github:o/success",
        "report fp outcome=success-report-outcome-fp"
      ],
      ["github:o/retry", "retry-report-outcome-fp"]
    )

    assert_project_report(
      html,
      "clear",
      [
        "report status closed_no_side_effect",
        "report action clear_review",
        "report read-only true",
        "auto retry allowed false"
      ],
      ["operation success true"]
    )

    assert_project_report(
      html,
      "retry",
      [
        "report status retry_consideration_required",
        "report action request_explicit_retry_consideration",
        "report pending execution false",
        "pending retry false",
        "queued replay false"
      ],
      ["automatic retry", "queued replay true"]
    )

    assert_project_report(
      html,
      "manual",
      [
        "report status manual_attention_required",
        "report blocked manual_blocker/open_manual_attention"
      ],
      []
    )

    assert_project_report(
      html,
      "stale",
      [
        "report status stale_evidence_review_required",
        "report section closure_chain stale"
      ],
      []
    )

    assert_project_report(
      html,
      "conflict",
      [
        "report status conflict_review_required",
        "report section closure_chain conflict"
      ],
      []
    )

    assert_project_report(
      html,
      "malformed",
      [
        "report status malformed_input_review_required",
        "report action fix_malformed_chain_input"
      ],
      []
    )

    assert_project_report(
      html,
      "unsupported",
      [
        "report status unsupported_report_slice",
        "report action unsupported_review"
      ],
      []
    )

    assert_project_report(
      html,
      "no-request",
      [
        "report status no_request",
        "report pending execution false"
      ],
      ["pending execution true", "migration queued", "legacy takeover true"]
    )

    assert_project_report(
      html,
      "no-chain",
      [
        "report status no_chain",
        "report pending execution false"
      ],
      ["pending retry true", "queued replay true", "legacy takeover true"]
    )

    refute html =~ "ghp_secret"
    refute html =~ "sk-secret"
    refute html =~ "Authorization:"
    refute html =~ "session=secret"
    refute html =~ "raw provider payload"
    refute html =~ "raw config"
    refute html =~ "raw systemd output"
    refute html =~ "raw hook output"
    refute html =~ "full prompt"
    refute html =~ "complete transcript"
    refute html =~ "complete PR body"
    refute html =~ "complete comment body"
    refute html =~ "/home/jhihjian/private"
    refute html =~ "stack trace"
  end

  test "dashboard closure report packet display degrades for missing incompatible and summary error shapes" do
    hub_name = Module.concat(__MODULE__, :HubDashboardReportPacketDegraded)

    start_supervised!(
      {StaticOrchestrator, name: hub_name, snapshot: degraded_report_packet_snapshot()},
      id: :hub_dashboard_report_packet_degraded
    )

    start_endpoint(orchestrator: hub_name)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Closure Report Packet"
    packet_panel = dashboard_panel(html, "Closure Report Packet")
    assert packet_panel =~ "no_chain"
    assert packet_panel =~ "read-only true"
    assert packet_panel =~ "no side effects true"
    assert packet_panel =~ "auto retry allowed false"
    assert packet_panel =~ "auto replay allowed false"
    assert packet_panel =~ "pending execution false"
    assert packet_panel =~ "pending retry false"
    assert packet_panel =~ "queued replay false"
    assert packet_panel =~ "legacy takeover false"

    refute html =~ "ghp_secret"
    refute html =~ "Authorization:"
    refute html =~ "session=secret"
    refute html =~ "raw provider payload"
    refute html =~ "raw config"
    refute html =~ "raw systemd output"
    refute html =~ "full prompt"
    refute html =~ "complete transcript"
    refute html =~ "complete PR body"
    refute html =~ "/home/jhihjian/private"
    refute html =~ "stack trace"
    refute html =~ "pending execution true"
    refute html =~ "pending retry true"
    refute html =~ "queued replay true"
    refute html =~ "legacy takeover true"
    refute html =~ "automatic retry"
    refute html =~ "migration queued"
  end

  test "dashboard omits Hub detail for legacy snapshots" do
    legacy_name = Module.concat(__MODULE__, :LegacyDashboardRuntime)

    start_supervised!(
      {StaticOrchestrator, name: legacy_name, snapshot: legacy_snapshot()},
      id: :legacy_dashboard_runtime
    )

    start_endpoint(orchestrator: legacy_name)

    {:ok, _view, legacy_html} = live(build_conn(), "/")
    refute legacy_html =~ "Hub 设备总览"
    refute legacy_html =~ "Hub 项目明细"
    refute legacy_html =~ "Hub-managed"
  end

  test "state API returns Hub overview and detail without raw sensitive material" do
    hub_name = Module.concat(__MODULE__, :HubApiRuntime)

    start_supervised!(
      {StaticOrchestrator, name: hub_name, snapshot: hub_snapshot()},
      id: :hub_api_runtime
    )

    start_endpoint(orchestrator: hub_name)

    payload = json_response(get(build_conn(), "/api/v1/state"), 200)
    hub = payload["hub_device_observability"]

    assert hub["overview"]["scheduler"]["status"] == "scheduled"
    assert hub["overview"]["provider_governance"]["recent_failure_count"] == 1
    assert hub["overview"]["writeback"]["manual_attention_count"] == 1
    assert hub["migration_readiness"]["status"] == "blocked"
    assert hub["migration_readiness"]["counts"]["decisions"]["unknown_manual_attention"] == 2
    assert hub["activation_plan"]["status"] == "blocked"
    assert hub["activation_plan"]["counts"]["acknowledgement_statuses"]["missing"] == 2
    assert hub["cutover_operation_audit"]["status"] == "no_request"
    assert hub["cutover_operation_audit"]["counts"]["request_count"] == 0
    assert hub["cutover_operation_audit"]["counts"]["no_request_count"] == 2
    assert hub["cutover_readiness_permit"]["status"] == "no_request"
    assert hub["cutover_readiness_permit"]["counts"]["permit_count"] == 0
    assert hub["cutover_readiness_permit"]["counts"]["no_request_count"] == 2
    assert hub["cutover_execution_authorization_ledger"]["status"] == "no_ready_permit"
    assert hub["cutover_execution_authorization_ledger"]["counts"]["authorization_request_count"] == 0
    assert hub["cutover_execution_authorization_ledger"]["counts"]["record_count"] == 0
    assert hub["cutover_authorization_consumption_guard"]["status"] == "no_consumption"
    assert hub["cutover_authorization_consumption_guard"]["counts"]["consumption_count"] == 0
    assert hub["cutover_replay_decision"]["status"] == "blocked_unresolved_outcome"
    assert hub["cutover_replay_decision"]["counts"]["unresolved_outcome_blocked_count"] == 1
    assert hub["overview"]["cutover_replay_decision"]["status"] == "blocked_unresolved_outcome"
    assert hub["overview"]["cutover_replay_decision"]["unresolved_outcome_blocked_count"] == 1
    assert hub["overview"]["cutover_replay_decision"]["no_unresolved_outcome_count"] == 1
    assert hub["cutover_replay_request_audit"]["status"] == "no_request"
    assert hub["cutover_replay_request_audit"]["counts"]["request_count"] == 0
    assert hub["overview"]["cutover_replay_request_audit"]["status"] == "no_request"
    assert hub["overview"]["cutover_replay_request_audit"]["request_count"] == 0
    assert hub["overview"]["cutover_replay_request_audit"]["no_request_count"] == 2
    assert hub["cutover_closure_chain"]["status"] == "open_manual_attention"
    assert hub["cutover_closure_chain"]["counts"]["closed_succeeded_count"] == 1
    assert hub["cutover_closure_chain"]["counts"]["open_manual_attention_count"] == 1
    assert hub["overview"]["cutover_closure_chain"]["status"] == "open_manual_attention"
    assert hub["overview"]["cutover_closure_chain"]["closure_status_counts"]["closed_succeeded"] == 1
    assert hub["overview"]["cutover_closure_chain"]["closure_status_counts"]["open_manual_attention"] == 1
    assert hub["overview"]["cutover_closure_chain"]["closeout_reference_status_counts"]["current"] == 1
    assert hub["overview"]["cutover_closure_chain"]["replay_decision_reference_status_counts"]["current"] == 1
    assert hub["overview"]["cutover_closure_chain"]["replay_request_audit_reference_status_counts"]["current"] == 1
    assert hub["overview"]["cutover_closure_chain"]["read_only"] == true
    assert hub["overview"]["cutover_closure_chain"]["no_side_effects"] == true
    assert hub["overview"]["cutover_closure_chain"]["auto_replay_allowed"] == false
    assert hub["cutover_closure_conclusion"]["conclusion"] == "manual_attention_required"
    assert hub["cutover_closure_conclusion"]["summary_code"] == "closure_open_manual_attention_required"
    assert hub["cutover_closure_conclusion"]["fully_closed"] == false
    assert hub["cutover_closure_conclusion"]["operation_success"] == false
    assert hub["cutover_closure_conclusion"]["auto_retry_allowed"] == false
    assert hub["cutover_closure_conclusion"]["auto_replay_allowed"] == false
    assert hub["overview"]["cutover_closure_conclusion"]["conclusion"] == "manual_attention_required"
    assert hub["overview"]["cutover_closure_conclusion"]["severity"] == "warning"
    assert hub["overview"]["cutover_closure_conclusion"]["attention_level"] == "manual_attention"
    assert hub["overview"]["cutover_closure_conclusion"]["summary_code"] == "closure_open_manual_attention_required"
    assert "resolve_manual_attention" in hub["overview"]["cutover_closure_conclusion"]["required_action_codes"]
    assert hub["overview"]["cutover_closure_conclusion"]["blocked_by"] != []
    assert hub["overview"]["cutover_closure_conclusion"]["evidence_references"] != []
    assert hub["overview"]["cutover_closure_conclusion"]["read_only"] == true
    assert hub["overview"]["cutover_closure_conclusion"]["no_side_effects"] == true
    assert hub["overview"]["cutover_closure_conclusion"]["auto_retry_allowed"] == false
    assert hub["overview"]["cutover_closure_conclusion"]["auto_replay_allowed"] == false
    assert hub["overview"]["cutover_closure_conclusion"]["pending_execution"] == false
    assert hub["overview"]["cutover_closure_conclusion"]["pending_retry"] == false
    assert hub["overview"]["cutover_closure_conclusion"]["queued_replay"] == false
    assert hub["overview"]["cutover_closure_conclusion"]["legacy_takeover"] == false

    projects = Map.new(hub["projects"], &{&1["project_id"], &1})
    assert projects["alpha"]["detail"]["candidate_intake"]["counts"]["candidate_count"] == 1
    assert projects["alpha"]["cutover_operation_audit"]["status"] == "no_request"
    assert projects["alpha"]["cutover_operation_audit"]["request"] == nil
    assert projects["alpha"]["cutover_readiness_permit"]["status"] == "no_request"
    assert projects["alpha"]["cutover_readiness_permit"]["permits"] == []
    assert projects["alpha"]["cutover_execution_authorization_ledger"]["status"] == "no_ready_permit"
    assert projects["alpha"]["cutover_execution_authorization_ledger"]["records"] == []
    assert projects["alpha"]["cutover_authorization_consumption_guard"] == nil
    assert projects["alpha"]["cutover_replay_decision"]["status"] == "no_unresolved_outcome"
    assert projects["alpha"]["cutover_replay_request_audit"]["status"] == "no_request"
    assert projects["alpha"]["cutover_closure_chain"]["status"] == "closed_succeeded"
    assert projects["alpha"]["detail"]["closure_chain"]["safe_evidence_fingerprints"]["outcome"] == "alpha-outcome-fp"
    assert projects["alpha"]["cutover_closure_conclusion"]["conclusion"] == "closed_succeeded"
    assert projects["alpha"]["cutover_closure_conclusion"]["operation_success"] == true
    assert projects["alpha"]["detail"]["closure_conclusion"]["summary_code"] == "closure_closed_succeeded"
    assert projects["alpha"]["detail"]["closure_conclusion"]["safe_evidence_fingerprints"]["outcome"] == "alpha-outcome-fp"
    assert projects["alpha"]["cutover_closure_report_packet"]["report_status"] == "fully_closed"
    assert projects["alpha"]["cutover_closure_report_packet"]["provider_scope"]["provider_scope_key"] == "github:o/alpha"
    assert projects["alpha"]["detail"]["closure_report_packet"]["safe_evidence_fingerprints"]["outcome"] == "alpha-outcome-fp"
    assert projects["alpha"]["detail"]["replay_request_audit"]["counts"]["request_count"] == 0
    assert projects["gamma"]["detail"]["writeback"]["counts"]["manual_attention"] == 1
    assert projects["gamma"]["cutover_replay_decision"]["status"] == "blocked_unresolved_outcome"
    assert projects["gamma"]["detail"]["replay_decision"]["blocked_replay"] != []
    assert projects["gamma"]["cutover_replay_request_audit"]["status"] == "no_request"
    assert projects["gamma"]["detail"]["replay_request_audit"]["auto_replay_allowed"] == false
    assert projects["gamma"]["cutover_closure_chain"]["status"] == "open_manual_attention"
    assert projects["gamma"]["detail"]["closure_chain"]["safe_evidence_fingerprints"]["outcome"] == "gamma-outcome-fp"
    assert projects["gamma"]["cutover_closure_conclusion"]["conclusion"] == "manual_attention_required"
    assert projects["gamma"]["cutover_closure_conclusion"]["operation_success"] == false
    assert projects["gamma"]["cutover_closure_conclusion"]["auto_retry_allowed"] == false
    assert projects["gamma"]["cutover_closure_conclusion"]["auto_replay_allowed"] == false
    assert projects["gamma"]["detail"]["closure_conclusion"]["summary_code"] == "closure_open_manual_attention_required"
    assert projects["gamma"]["detail"]["closure_conclusion"]["safe_evidence_fingerprints"]["outcome"] == "gamma-outcome-fp"
    assert projects["gamma"]["cutover_closure_report_packet"]["report_status"] == "manual_attention_required"
    assert projects["gamma"]["cutover_closure_report_packet"]["provider_scope"]["provider_scope_key"] == "github:g/gamma"
    assert projects["gamma"]["detail"]["closure_report_packet"]["safe_evidence_fingerprints"]["outcome"] == "gamma-outcome-fp"
    assert projects["gamma"]["detail"]["closure_conclusion"]["queued_replay"] == false
    assert projects["gamma"]["detail"]["closure_conclusion"]["pending_execution"] == false
    assert projects["gamma"]["detail"]["closure_conclusion"]["pending_retry"] == false
    assert projects["gamma"]["detail"]["closure_conclusion"]["legacy_takeover"] == false
    assert projects["gamma"]["detail"]["closure_chain"]["closeout_reference_status_counts"]["current"] == 1
    assert projects["gamma"]["detail"]["closure_chain"]["replay_decision_reference_status_counts"]["current"] == 1
    assert projects["gamma"]["detail"]["closure_chain"]["replay_request_audit_reference_status_counts"]["current"] == 1
    assert projects["gamma"]["detail"]["closure_chain"]["auto_replay_allowed"] == false
    assert projects["gamma"]["migration_readiness"]["decision"] == "unknown_manual_attention"
    assert projects["gamma"]["activation_plan"]["status"] == "unknown_manual_attention"
    assert projects["gamma"]["activation_plan"]["operator_acknowledgement"]["status"] == "missing"
    assert projects["gamma"]["migration_readiness"]["activation_plan"]["plan_id"] == projects["gamma"]["activation_plan"]["plan_id"]
    assert Enum.any?(projects["gamma"]["migration_readiness"]["blocking_reasons"], &(&1["code"] == "writeback_unknown"))
    assert Enum.any?(projects["gamma"]["migration_readiness"]["required_operator_actions"], &(&1["code"] == "resolve_writeback_manual_attention"))
    assert Enum.any?(projects["gamma"]["activation_plan"]["required_acknowledgements"], &(&1["code"] == "resolve_writeback_manual_attention"))
    refute projects["alpha"]["detail"]["closure_chain"]["safe_evidence_fingerprints"]["outcome"] == "gamma-outcome-fp"
    refute projects["alpha"]["detail"]["closure_conclusion"]["safe_evidence_fingerprints"]["outcome"] == "gamma-outcome-fp"
    refute projects["alpha"]["detail"]["closure_report_packet"]["safe_evidence_fingerprints"]["outcome"] == "gamma-outcome-fp"
    refute projects["alpha"]["cutover_closure_report_packet"]["provider_scope"]["provider_scope_key"] == "github:g/gamma"

    safe_text = inspect(payload)
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "Authorization"
    refute safe_text =~ "raw systemd output"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "raw provider response"
    refute safe_text =~ "queued replay"
    refute safe_text =~ "automatic retry"
  end

  defp start_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp dashboard_panel(html, label) do
    html
    |> Floki.parse_document!()
    |> Floki.find("article")
    |> Enum.find(fn panel ->
      panel
      |> Floki.find(".metric-label")
      |> html_text() == label
    end)
    |> case do
      nil -> flunk("expected dashboard panel #{label}")
      panel -> html_text(panel)
    end
  end

  defp project_row(html, project_id) do
    html
    |> Floki.parse_document!()
    |> Floki.find("tr")
    |> Enum.find(fn row ->
      row
      |> Floki.find(".issue-id")
      |> html_text() == project_id
    end)
    |> case do
      nil -> flunk("expected project row #{project_id}")
      row -> html_text(row)
    end
  end

  defp assert_project_report(html, project_id, included, excluded) do
    row = project_row(html, project_id)

    Enum.each(included, fn expected ->
      assert row =~ expected
    end)

    Enum.each(excluded, fn forbidden ->
      refute row =~ forbidden
    end)
  end

  defp html_text(fragment) do
    fragment
    |> Floki.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp assert_order(html, first, second) do
    first_match = :binary.match(html, first)
    second_match = :binary.match(html, second)

    assert first_match != :nomatch
    assert second_match != :nomatch
    assert elem(first_match, 0) < elem(second_match, 0)
  end

  defp hub_snapshot do
    %{
      running: [],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil,
      hub_device_observability:
        DeviceObservability.build(
          %{
            registry: registry(),
            poll_coordination: poll_coordination(),
            runtime_ledger: runtime_ledger(),
            scheduler: %{
              enabled: true,
              status: "scheduled",
              queued: true,
              next_tick_at: "2026-06-28T09:00:01Z",
              next_reason: "runtime_reconciliation"
            },
            candidate_intake: candidate_intake(),
            provider_queue: provider_queue(),
            cutover_replay_decision: replay_decision_summary(),
            cutover_closure_chain: closure_chain_summary()
          },
          now: ~U[2026-06-28 09:00:00Z]
        )
    }
  end

  defp report_packet_matrix_snapshot do
    base = hub_snapshot()
    [template | _rest] = base.hub_device_observability.projects

    project_packets = [
      report_packet_project("success", "fully_closed", "closed_succeeded", "closed_succeeded", "success_review"),
      report_packet_project("clear", "closed_no_side_effect", "closed_no_side_effect", "closed_no_side_effect", "clear_review"),
      report_packet_project(
        "retry",
        "retry_consideration_required",
        "open_retryable",
        "waiting_explicit_retry_consideration",
        "request_explicit_retry_consideration"
      ),
      report_packet_project(
        "manual",
        "manual_attention_required",
        "open_manual_attention",
        "manual_attention_required",
        "resolve_manual_attention",
        blocker_code: "manual_blocker"
      ),
      report_packet_project("stale", "stale_evidence_review_required", "stale", "evidence_stale_reaudit_required", "reaudit_stale_evidence"),
      report_packet_project("conflict", "conflict_review_required", "conflict", "evidence_conflict_reaudit_required", "resolve_conflict"),
      report_packet_project("malformed", "malformed_input_review_required", "malformed", "input_malformed", "fix_malformed_chain_input"),
      report_packet_project("unsupported", "unsupported_report_slice", "unsupported", "unsupported_closure_report_slice", "unsupported_review"),
      report_packet_project("no-request", "no_request", "no_request", "no_explicit_cutover_request", "none_required"),
      report_packet_project("no-chain", "no_chain", "no_chain", "no_explicit_closure_chain", "none_required")
    ]

    projects =
      Enum.map(project_packets, fn packet ->
        report_packet_dashboard_project(template, packet)
      end)

    overview_packet = %{
      version: 1,
      report_version: 1,
      generated_at: "2026-06-28T09:00:00Z",
      report_status: "malformed_input_review_required",
      closure_chain_status: "malformed",
      operator_conclusion: "input_malformed",
      severity: "error",
      attention_level: "audit_required",
      summary_code: "closure_input_malformed",
      required_action_codes: [
        "fix_malformed_chain_input",
        "request_explicit_retry_consideration",
        "resolve_manual_attention"
      ],
      required_action_count: 3,
      blocked_by: [
        %{
          code: "malformed_report",
          closure_chain_status: "malformed",
          raw_provider_payload: "raw provider payload"
        }
      ],
      blocked_by_count: 1,
      evidence_references: [
        %{
          type: "device",
          closure_chain_status: "malformed",
          summary_code: "closure_input_malformed",
          safe_evidence_fingerprints: %{outcome: "device-report-outcome-fp"},
          raw_provider_payload: "raw provider payload"
        }
      ],
      evidence_reference_count: 1,
      safe_evidence_fingerprint: "device-report-fp",
      closure_chain: %{
        status: "malformed",
        closure_status_counts: %{
          closed_succeeded: 1,
          closed_no_side_effect: 1,
          open_retryable: 1,
          open_manual_attention: 1,
          stale: 1,
          conflict: 1,
          malformed: 1,
          unsupported: 1,
          no_request: 1,
          no_chain: 1
        },
        safe_evidence_fingerprints: %{outcome: "device-report-outcome-fp"},
        safe_evidence_fingerprint: "device-chain-fp",
        read_only: true
      },
      section_statuses: %{closure_chain: "malformed", operator_conclusion: "input_malformed"},
      fully_closed: false,
      operation_success: false,
      read_only: true,
      no_side_effects: true,
      actions_are_advisory: true,
      auto_retry_allowed: false,
      auto_replay_allowed: false,
      queued_replay: false,
      pending_execution: false,
      pending_retry: false,
      legacy_takeover: false,
      summary_error: %{stack_trace: "stack trace with ghp_secret and /home/jhihjian/private"},
      provider_scope: %{token: "ghp_secret"},
      raw_provider_payload: "raw provider payload",
      raw_config: "raw config",
      raw_systemd_output: "raw systemd output",
      prompt: "full prompt",
      transcript: "complete transcript",
      pr_body: "complete PR body",
      comment_body: "complete comment body",
      authorization: "Authorization: Bearer sk-secret",
      cookie: "session=secret"
    }

    report_packet =
      overview_packet
      |> Map.put(:device, overview_packet)
      |> Map.put(:projects, project_packets)

    base
    |> Map.put(:hub_cutover_closure_report_packet, report_packet)
    |> put_in([:hub_device_observability, :cutover_closure_report_packet], report_packet)
    |> put_in([:hub_device_observability, :overview, :cutover_closure_report_packet], overview_packet)
    |> put_in([:hub_device_observability, :projects], projects)
  end

  defp degraded_report_packet_snapshot do
    base = hub_snapshot()

    projects =
      base.hub_device_observability.projects
      |> Enum.map(fn project ->
        project
        |> Map.put(:cutover_closure_report_packet, :not_a_safe_packet)
        |> update_in([:detail], fn detail ->
          Map.put(detail, :closure_report_packet, %{
            summary_error: %{
              stack_trace: "stack trace with ghp_secret Authorization: Bearer token /home/jhihjian/private"
            },
            raw_provider_payload: "raw provider payload",
            raw_config: "raw config",
            raw_systemd_output: "raw systemd output",
            prompt: "full prompt",
            transcript: "complete transcript",
            pr_body: "complete PR body",
            pending_execution: true,
            pending_retry: true,
            queued_replay: true,
            legacy_takeover: true
          })
        end)
      end)

    overview_packet = %{
      version: 1,
      report_version: 1,
      generated_at: "2026-06-28T09:00:00Z",
      report_status: "no_chain",
      closure_chain_status: "no_chain",
      operator_conclusion: "no_explicit_closure_chain",
      severity: "none",
      attention_level: "none",
      summary_code: "closure_no_chain",
      required_action_codes: ["none_required"],
      required_action_count: 1,
      blocked_by: [],
      blocked_by_count: 0,
      evidence_references: [],
      evidence_reference_count: 0,
      closure_chain: %{status: "no_chain", closure_status_counts: %{no_chain: 1}},
      section_statuses: %{closure_chain: "no_chain", operator_conclusion: "no_explicit_closure_chain"},
      fully_closed: false,
      operation_success: false,
      read_only: true,
      no_side_effects: true,
      actions_are_advisory: true,
      auto_retry_allowed: false,
      auto_replay_allowed: false,
      queued_replay: false,
      pending_execution: true,
      pending_retry: true,
      legacy_takeover: true,
      summary_error: %{
        stack_trace: "stack trace with ghp_secret Authorization: Bearer token /home/jhihjian/private"
      },
      raw_provider_payload: "raw provider payload",
      raw_config: "raw config",
      raw_systemd_output: "raw systemd output",
      prompt: "full prompt",
      transcript: "complete transcript",
      pr_body: "complete PR body",
      cookie: "session=secret"
    }

    report_packet =
      overview_packet
      |> Map.put(:device, overview_packet)
      |> Map.put(:projects, [])

    base
    |> Map.put(:hub_cutover_closure_report_packet, report_packet)
    |> put_in([:hub_device_observability, :cutover_closure_report_packet], report_packet)
    |> put_in([:hub_device_observability, :overview, :cutover_closure_report_packet], overview_packet)
    |> put_in([:hub_device_observability, :projects], projects)
  end

  defp report_packet_project(project_id, report_status, chain_status, conclusion, action_code, opts \\ []) do
    provider_scope = closure_provider_scope(project_id)
    blocker_code = Keyword.get(opts, :blocker_code, "#{project_id}_blocker")
    safe_fingerprint = "#{project_id}-report-outcome-fp"

    %{
      project_id: project_id,
      provider_scope: provider_scope,
      report_status: report_status,
      closure_chain_status: chain_status,
      operator_conclusion: conclusion,
      severity: report_packet_severity(chain_status),
      attention_level: report_packet_attention(chain_status),
      summary_code: "closure_#{chain_status}",
      required_action_codes: [action_code],
      required_action_count: 1,
      blocked_by: [%{code: blocker_code, closure_chain_status: chain_status}],
      blocked_by_count: 1,
      evidence_references: [
        %{
          type: "project",
          closure_chain_status: chain_status,
          summary_code: "closure_#{chain_status}",
          safe_evidence_fingerprints: %{outcome: safe_fingerprint},
          raw_provider_payload: "raw provider payload"
        }
      ],
      evidence_reference_count: 1,
      safe_evidence_fingerprints: %{outcome: safe_fingerprint},
      safe_evidence_fingerprint: "#{project_id}-packet-fp",
      closure_chain: %{
        status: chain_status,
        closure_status_counts: %{chain_status => 1},
        safe_evidence_fingerprints: %{outcome: safe_fingerprint},
        safe_evidence_fingerprint: "#{project_id}-chain-fp",
        read_only: true
      },
      section_statuses: %{closure_chain: chain_status, operator_conclusion: conclusion},
      fully_closed: report_status in ["fully_closed", "closed_no_side_effect"],
      operation_success: report_status == "fully_closed",
      read_only: true,
      no_side_effects: true,
      actions_are_advisory: true,
      auto_retry_allowed: false,
      auto_replay_allowed: false,
      queued_replay: false,
      pending_execution: false,
      pending_retry: false,
      legacy_takeover: false,
      raw_provider_payload: "raw provider payload",
      raw_config: "raw config",
      raw_systemd_output: "raw systemd output",
      raw_hook_output: "raw hook output",
      prompt: "full prompt",
      transcript: "complete transcript",
      pr_body: "complete PR body",
      comment_body: "complete comment body",
      local_path: "/home/jhihjian/private/#{project_id}",
      authorization: "Authorization: Bearer sk-secret",
      cookie: "session=secret"
    }
  end

  defp report_packet_dashboard_project(template, packet) do
    project_id = packet.project_id

    template
    |> Map.put(:project_id, project_id)
    |> Map.put(:name, String.capitalize(String.replace(project_id, "-", " ")))
    |> Map.put(:cutover_closure_report_packet, packet)
    |> update_in([:detail], fn detail ->
      detail
      |> put_in([:identity, :provider_scope_key], packet.provider_scope.provider_scope_key)
      |> put_in([:config, :config_fingerprint], "#{project_id}-config-fingerprint")
      |> Map.put(:closure_report_packet, Map.drop(packet, [:project_id]))
    end)
  end

  defp report_packet_severity(status) when status in ["conflict", "malformed"], do: "error"
  defp report_packet_severity(status) when status in ["open_retryable", "open_manual_attention", "stale", "unsupported"], do: "warning"
  defp report_packet_severity("closed_no_side_effect"), do: "notice"
  defp report_packet_severity("closed_succeeded"), do: "info"
  defp report_packet_severity(_status), do: "none"

  defp report_packet_attention("open_retryable"), do: "retry_consideration"
  defp report_packet_attention("open_manual_attention"), do: "manual_attention"
  defp report_packet_attention(status) when status in ["conflict", "malformed", "stale"], do: "audit_required"
  defp report_packet_attention(_status), do: "review"

  defp legacy_snapshot do
    %{
      running: [],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }
  end

  defp registry do
    %{
      projects: [
        %{
          project_id: "alpha",
          name: "Alpha",
          dispatch_enabled: true,
          paused: false,
          status: :ready,
          tracker_summary: %{
            kind: "github",
            provider_scope_key: "github:o/r",
            provider_scope: %{owner: "o", repo: "r", token: "ghp_secret"},
            required_labels: ["symphony"]
          },
          runtime_summary: %{
            workspace_root: "/workspaces/alpha",
            max_concurrent_agents: 2,
            max_concurrent_agents_by_state: %{},
            polling_interval_ms: 30_000,
            server_port: nil
          },
          fingerprint: "alpha-fingerprint",
          loaded_at: ~U[2026-06-28 08:55:00Z],
          load_error: nil
        },
        %{
          project_id: "gamma",
          name: "Gamma",
          dispatch_enabled: true,
          paused: false,
          status: :ready,
          tracker_summary: %{
            kind: "github",
            provider_scope_key: "github:o/r",
            provider_scope: %{owner: "o", repo: "r"},
            required_labels: ["symphony"]
          },
          runtime_summary: %{
            workspace_root: "/workspaces/gamma",
            max_concurrent_agents: 1,
            max_concurrent_agents_by_state: %{},
            polling_interval_ms: 30_000,
            server_port: nil
          },
          fingerprint: "gamma-fingerprint",
          loaded_at: ~U[2026-06-28 08:55:00Z],
          load_error: nil
        }
      ],
      warnings: [],
      errors: []
    }
  end

  defp poll_coordination do
    %{
      projects: [
        %{
          project_id: "alpha",
          allow_poll: true,
          eligibility: %{reason: "ready", message: nil},
          provider_scope_key: "github:o/r",
          tracker_identity: %{kind: "github", provider_scope_key: "github:o/r"}
        },
        %{
          project_id: "gamma",
          allow_poll: false,
          eligibility: %{reason: "manual_attention", message: "writeback requires manual attention"},
          provider_scope_key: "github:o/r",
          tracker_identity: %{kind: "github", provider_scope_key: "github:o/r"}
        }
      ],
      provider_queue: provider_queue()
    }
  end

  defp provider_queue do
    %{
      pending_count: 1,
      running_count: 0,
      provider_scopes: [
        %{
          provider_scope_key: "github:o/r",
          pending_count: 1,
          running_count: 0,
          state: %{quota: %{remaining: 0}, backoff_until: "2026-06-28T09:05:00Z", circuit_state: "closed"}
        }
      ],
      pending: [%{project_id: "gamma", provider_scope_key: "github:o/r", operation_kind: "candidate_scan"}],
      running: [],
      recent_results: [
        %{
          project_id: "gamma",
          provider_scope_key: "github:o/r",
          operation_kind: "candidate_scan",
          status: "retryable_failure",
          error_class: "provider_failure",
          raw_provider_response: "raw provider response"
        }
      ],
      backpressure: [%{project_id: "gamma", provider_scope_key: "github:o/r", reason: "rate_limited"}]
    }
  end

  defp candidate_intake do
    %{
      status: "completed",
      projects: [
        %{
          project_id: "alpha",
          provider_kind: "github",
          provider_scope_key: "github:o/r",
          counts: %{candidate_count: 1, eligible_count: 1},
          candidates: [%{issue_key: "alpha:github:o/r:1", prompt: "full prompt"}],
          invalid_candidates: []
        }
      ]
    }
  end

  defp runtime_ledger do
    %{
      projects: [
        %{
          project_id: "alpha",
          counts: %{running: 1},
          active_attempts: [%{issue_key: "alpha:github:o/r:1", attempt_id: "attempt-1", status: :running}],
          pending_start_intents: [],
          workspace_leases: [%{issue_key: "alpha:github:o/r:1", attempt_id: "attempt-1", status: :active, systemd_output: "raw systemd output"}],
          retry_backoff: [],
          blocked_candidates: [],
          writebacks: %{counts: %{pending: 0, succeeded: 0, failed: 0, unknown: 0, manual_attention: 0}},
          lifecycle: %{counts: %{running: 1}},
          conflicts: [],
          manual_attention: []
        },
        %{
          project_id: "gamma",
          counts: %{manual_attention: 1},
          active_attempts: [],
          pending_start_intents: [],
          workspace_leases: [],
          retry_backoff: [],
          blocked_candidates: [],
          writebacks: %{
            counts: %{pending: 0, succeeded: 0, failed: 0, unknown: 1, manual_attention: 1},
            unknown: [%{intent_key: "gamma-writeback", result_status: "unknown", replay_policy: "non_idempotent", target: %{body: "Authorization: Bearer ghp_secret"}}],
            manual_attention: [%{intent_key: "gamma-writeback", manual_attention_reason: "unknown_non_idempotent_writeback"}]
          },
          lifecycle: %{counts: %{unknown: 1, manual_attention: 1}},
          conflicts: [],
          manual_attention: [%{code: "writeback_unknown_manual_attention"}]
        }
      ]
    }
  end

  defp replay_decision_summary do
    %{
      version: 1,
      generated_at: "2026-06-28T09:00:00Z",
      recent_decisions: [
        %{
          project_id: "alpha",
          provider_scope: %{kind: "github", key: "github:o/r", provider_scope_key: "github:o/r", scope: %{owner: "o", repo: "r"}},
          operation: "poll",
          side_effect_source: "candidate_scan",
          replay_key: "alpha-poll-replay",
          decision: "no_unresolved_outcome",
          allowed: true,
          reason_code: "no_matching_unresolved_outcome",
          evaluated_at: "2026-06-28T09:00:00Z",
          no_side_effects: true,
          auto_replay_allowed: false
        },
        %{
          project_id: "gamma",
          provider_scope: %{kind: "github", key: "github:o/r", provider_scope_key: "github:o/r", scope: %{owner: "o", repo: "r"}},
          operation: "writeback",
          side_effect_source: "writeback_executor",
          replay_key: "gamma-writeback-replay",
          outcome_replay_key: "gamma-writeback-replay",
          outcome_fingerprint: "gamma-outcome-fp",
          outcome_status: "unknown",
          decision: "blocked_unresolved_outcome",
          allowed: false,
          reason_code: "matching_closeout_missing",
          action_code: "record_execution_outcome_closeout",
          authorization_record_fingerprint: "gamma-auth-record-fp",
          readiness_permit_fingerprint: "gamma-permit-fp",
          consumption_guard_fingerprint: "gamma-consumption-fp",
          safe_evidence_fingerprints: %{
            authorization_record: "gamma-auth-record-fp",
            readiness_permit: "gamma-permit-fp",
            consumption_guard: "gamma-consumption-fp"
          },
          evaluated_at: "2026-06-28T09:00:00Z",
          no_side_effects: true,
          auto_replay_allowed: false
        }
      ],
      no_side_effects: true,
      auto_replay_allowed: false
    }
  end

  defp closure_chain_summary do
    CutoverClosureChain.build(
      %{
        closure_chains: [
          closure_chain("alpha", "succeeded"),
          closure_chain("gamma", "unknown", retained_references?: true)
        ]
      },
      now: ~U[2026-06-28 09:00:00Z]
    )
  end

  defp closure_chain(project_id, status, opts \\ []) do
    provider_scope = closure_provider_scope(project_id)

    base = %{
      project_id: project_id,
      provider_scope: provider_scope,
      operation: "writeback",
      side_effect_source: "writeback_executor",
      attempt_fingerprint: "#{project_id}-attempt-fp",
      replay_key: "#{project_id}-replay-key",
      request: %{request_fingerprint: "#{project_id}-request-fp"},
      readiness_permit: %{
        permit_fingerprint: "#{project_id}-permit-fp",
        decision: "ready_for_execution_consideration"
      },
      authorization: %{
        status: "authorized_for_explicit_execution",
        authorization_record_fingerprint: "#{project_id}-record-fp",
        authorization_request_fingerprint: "#{project_id}-auth-request-fp"
      },
      consumption_guard: %{
        project_id: project_id,
        provider_scope: provider_scope,
        operation: "writeback",
        side_effect_source: "writeback_executor",
        decision: "allowed",
        allowed: true,
        decision_fingerprint: "#{project_id}-guard-fp"
      },
      outcome: closure_outcome(project_id, provider_scope, status)
    }

    if Keyword.get(opts, :retained_references?, false) do
      Map.merge(base, retained_closure_references(project_id, provider_scope))
    else
      base
    end
  end

  defp closure_outcome(project_id, provider_scope, status) do
    %{
      project_id: project_id,
      provider_scope: provider_scope,
      operation: "writeback",
      side_effect_source: "writeback_executor",
      status: status,
      attempt_fingerprint: "#{project_id}-attempt-fp",
      replay_key: "#{project_id}-replay-key",
      cutover_operation_request_fingerprint: "#{project_id}-request-fp",
      readiness_permit_fingerprint: "#{project_id}-permit-fp",
      readiness_permit_decision: "ready_for_execution_consideration",
      authorization_record_fingerprint: "#{project_id}-record-fp",
      authorization_request_fingerprint: "#{project_id}-auth-request-fp",
      evidence_fingerprint: "#{project_id}-outcome-fp",
      safe_evidence_fingerprints: %{
        outcome: "#{project_id}-outcome-fp",
        cutover_operation_request: "#{project_id}-request-fp",
        readiness_permit: "#{project_id}-permit-fp",
        readiness_permit_decision: "ready_for_execution_consideration",
        authorization_record: "#{project_id}-record-fp",
        authorization_request: "#{project_id}-auth-request-fp",
        consumption_guard: "#{project_id}-guard-fp"
      },
      side_effect_entered: status in ["succeeded", "unknown"],
      side_effect_may_have_happened: status in ["succeeded", "unknown"],
      generated_at: "2026-06-28T09:00:00Z"
    }
  end

  defp retained_closure_references(project_id, provider_scope) do
    evidence = closure_outcome(project_id, provider_scope, "unknown").safe_evidence_fingerprints

    %{
      closeout: %{
        project_id: project_id,
        provider_scope: provider_scope,
        operation: "writeback",
        side_effect_source: "writeback_executor",
        replay_key: "#{project_id}-replay-key",
        status: "resolved",
        resolution_code: "allow_explicit_retry_consideration",
        closeout_record_fingerprint: "#{project_id}-closeout-fp",
        outcome_fingerprint: "#{project_id}-outcome-fp",
        outcome_status: "unknown",
        side_effect_entered: true,
        side_effect_may_have_happened: true,
        safe_evidence_fingerprints: evidence,
        reason_code: "closeout_reference_current",
        action_code: "evaluate_cutover_replay_decision",
        operator_request_fingerprint: "#{project_id}-operator-request-fp"
      },
      replay_decision: %{
        project_id: project_id,
        provider_scope: provider_scope,
        operation: "writeback",
        side_effect_source: "writeback_executor",
        replay_key: "#{project_id}-replay-key",
        decision: "retry_consideration_allowed",
        allowed: true,
        replay_decision_fingerprint: "#{project_id}-replay-decision-fp",
        outcome_fingerprint: "#{project_id}-outcome-fp",
        outcome_status: "unknown",
        closeout_record_fingerprint: "#{project_id}-closeout-fp",
        closeout_resolution_code: "allow_explicit_retry_consideration",
        side_effect_entered: true,
        side_effect_may_have_happened: true,
        safe_evidence_fingerprints: evidence,
        reason_code: "replay_decision_reference_current",
        action_code: "record_cutover_replay_request_audit",
        no_side_effects: true,
        auto_replay_allowed: false
      },
      replay_request_audit: %{
        project_id: project_id,
        provider_scope: provider_scope,
        operation: "writeback",
        side_effect_source: "writeback_executor",
        replay_key: "#{project_id}-replay-key",
        status: "would_allow_retry_consideration",
        outcome_link_status: "outcome_still_pending",
        request_fingerprint: "#{project_id}-replay-request-fp",
        audit_record_fingerprint: "#{project_id}-replay-audit-fp",
        outcome_fingerprint: "#{project_id}-outcome-fp",
        outcome_status: "unknown",
        closeout_record_fingerprint: "#{project_id}-closeout-fp",
        closeout_resolution_code: "allow_explicit_retry_consideration",
        replay_decision_fingerprint: "#{project_id}-replay-decision-fp",
        replay_decision_status: "retry_consideration_allowed",
        side_effect_entered: true,
        side_effect_may_have_happened: true,
        safe_evidence_fingerprints: evidence,
        reason_code: "replay_request_audit_reference_current",
        action_code: "wait_for_explicit_retry_operator_decision",
        no_side_effects: true,
        auto_replay_allowed: false
      }
    }
  end

  defp closure_provider_scope(project_id) do
    %{
      kind: "github",
      key: closure_provider_scope_key(project_id),
      provider_scope_key: closure_provider_scope_key(project_id),
      scope: %{owner: closure_provider_owner(project_id), repo: project_id}
    }
  end

  defp closure_provider_scope_key("gamma"), do: "github:g/gamma"
  defp closure_provider_scope_key(project_id), do: "github:o/#{project_id}"

  defp closure_provider_owner("gamma"), do: "g"
  defp closure_provider_owner(_project_id), do: "o"
end
