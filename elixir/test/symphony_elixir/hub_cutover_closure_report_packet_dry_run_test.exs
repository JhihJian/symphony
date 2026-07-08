defmodule SymphonyElixir.HubCutoverClosureReportPacketDryRunTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.HubCutoverClosureReportPacketDryRunFixture, as: DryRunFixture
  alias SymphonyElixirWeb.Presenter

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
    def handle_call(:snapshot, _from, state), do: {:reply, Keyword.fetch!(state, :snapshot), state}

    def handle_call(:request_refresh, _from, state), do: {:reply, :unavailable, state}
  end

  setup do
    original_endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, original_endpoint_config)
    end)

    :ok
  end

  test "dry-run fixture builds a deterministic multi-project read-only packet from safe fields" do
    packet = DryRunFixture.closure_report_packet()
    projects = Map.new(packet.projects, &{&1.project_id, &1})

    assert DryRunFixture.fixture_version() == 1
    assert packet.report_version == 1
    assert packet.generated_at == DryRunFixture.generated_at()
    assert packet.report_status == "stale_evidence_review_required"
    assert packet.operator_conclusion == "evidence_stale_reaudit_required"
    assert packet.summary_code == "closure_evidence_stale"
    assert packet.boundary_flags.consumes_safe_snapshots_only == true
    assert packet.boundary_flags.provider_calls == false
    assert packet.boundary_flags.dispatch_calls == false
    assert packet.boundary_flags.worker_start_calls == false
    assert packet.boundary_flags.writeback_calls == false
    assert packet.boundary_flags.systemd_calls == false
    assert packet.boundary_flags.config_mutation == false
    assert packet.boundary_flags.auto_retry_allowed == false
    assert packet.boundary_flags.auto_replay_allowed == false
    assert packet.boundary_flags.queued_replay == false
    assert packet.boundary_flags.pending_execution == false
    assert packet.boundary_flags.pending_retry == false
    assert packet.boundary_flags.legacy_takeover == false

    assert_project_packet(projects, "success", "fully_closed", "github:org/success", "review_success_evidence", "success-outcome-fp")
    assert projects["success"].operation_success == true

    assert_project_packet(
      projects,
      "clear",
      "closed_no_side_effect",
      "gitlab:group/clear",
      "review_no_side_effect_evidence",
      "clear-outcome-fp"
    )

    assert projects["clear"].operation_success == false

    assert_project_packet(
      projects,
      "retry",
      "retry_consideration_required",
      "github:org/retry",
      "request_explicit_retry_consideration",
      "retry-outcome-fp"
    )

    assert projects["retry"].boundary_flags.auto_retry_allowed == false
    assert projects["retry"].boundary_flags.pending_retry == false

    assert_project_packet(
      projects,
      "unknown-manual",
      "manual_attention_required",
      "github:ops/unknown-manual",
      "resolve_manual_attention",
      "unknown-manual-outcome-fp"
    )

    assert projects["unknown-manual"].blocked_by == [
             %{code: "unknown_outcome_requires_manual_attention", closure_chain_status: "open_manual_attention"}
           ]

    assert_project_packet(
      projects,
      "stale",
      "stale_evidence_review_required",
      "gitlab:group/stale",
      "refresh_stale_evidence",
      "stale-outcome-fp"
    )

    assert projects["stale"].closure_chain_status == "stale"

    assert_project_packet(projects, "no-request", "no_request", "github:org/no-request", "none_required", "no-request-outcome-fp")
    assert_project_packet(projects, "no-chain", "no_chain", "gitlab:group/no-chain", "none_required", "no-chain-outcome-fp")

    success_text = inspect(projects["success"], limit: :infinity, printable_limit: :infinity)
    retry_text = inspect(projects["retry"], limit: :infinity, printable_limit: :infinity)

    assert success_text =~ "success-outcome-fp"
    refute success_text =~ "retry-outcome-fp"
    assert retry_text =~ "retry-outcome-fp"
    refute retry_text =~ "success-outcome-fp"

    refute_forbidden_markers!(inspect(DryRunFixture.safe_sources(), limit: :infinity, printable_limit: :infinity))
    refute_forbidden_markers!(inspect(packet, limit: :infinity, printable_limit: :infinity))
  end

  test "same dry-run fixture is consistent across Presenter API and Live Dashboard" do
    hub_name = Module.concat(__MODULE__, :DryRunHubRuntime)

    start_supervised!(
      {StaticOrchestrator, name: hub_name, snapshot: DryRunFixture.runtime_snapshot()},
      id: :hub_cutover_report_packet_dry_run_runtime
    )

    start_endpoint(orchestrator: hub_name)

    presenter_payload = Presenter.state_payload(hub_name, 100)
    api_payload = json_response(get(build_conn(), "/api/v1/state"), 200)
    {:ok, _view, html} = live(build_conn(), "/")

    api_packet = api_payload["hub_cutover_closure_report_packet"]
    api_overview = api_payload["hub_device_observability"]["overview"]["cutover_closure_report_packet"]
    presenter_overview = presenter_payload.hub_device_observability.overview.cutover_closure_report_packet

    assert api_packet["report_status"] == "stale_evidence_review_required"
    assert api_overview["report_status"] == api_packet["report_status"]
    assert presenter_overview.report_status == api_packet["report_status"]
    assert api_overview["operator_conclusion"] == api_packet["operator_conclusion"]
    assert presenter_overview.operator_conclusion == api_packet["operator_conclusion"]
    assert api_overview["summary_code"] == api_packet["summary_code"]
    assert api_overview["section_statuses"]["closure_chain"] == api_packet["device"]["section_statuses"]["closure_chain"]
    assert api_overview["safe_evidence_fingerprint"] == api_packet["device"]["closure_chain"]["safe_evidence_fingerprint"]

    packet_panel = dashboard_panel(html, "Closure Report Packet")
    assert packet_panel =~ api_overview["report_status"]
    assert packet_panel =~ "conclusion #{api_overview["operator_conclusion"]}"
    assert packet_panel =~ "sections closure_chain #{api_overview["section_statuses"]["closure_chain"]}"
    assert packet_panel =~ "evidence dry_run_fixture/stale/closure_evidence_stale"
    assert packet_panel =~ "packet=#{api_overview["safe_evidence_fingerprint"]}"
    assert packet_panel =~ "read-only true"
    assert packet_panel =~ "auto retry allowed false"
    assert packet_panel =~ "auto replay allowed false"
    assert packet_panel =~ "pending execution false"
    assert packet_panel =~ "pending retry false"
    assert packet_panel =~ "queued replay false"
    assert packet_panel =~ "legacy takeover false"
    refute packet_panel =~ "fully_closed"

    api_projects = Map.new(api_payload["hub_device_observability"]["projects"], &{&1["project_id"], &1})

    Enum.each(DryRunFixture.project_specs(), fn spec ->
      api_project = api_projects[spec.project_id]["cutover_closure_report_packet"]
      detail_project = api_projects[spec.project_id]["detail"]["closure_report_packet"]
      row = project_row(html, spec.project_id)

      assert api_project["report_status"] == spec.report_status
      assert api_project["operator_conclusion"] == spec.conclusion
      assert api_project["summary_code"] == spec.summary_code
      assert api_project["required_action_codes"] == spec.actions
      assert api_project["provider_scope"]["provider_scope_key"] == spec.provider_scope_key
      assert api_project["safe_evidence_fingerprints"]["outcome"] == "#{spec.project_id}-outcome-fp"
      assert detail_project["safe_evidence_fingerprints"]["outcome"] == "#{spec.project_id}-outcome-fp"
      assert detail_project["section_statuses"]["closure_chain"] == spec.status

      assert row =~ "report status #{api_project["report_status"]}"
      assert row =~ "conclusion #{api_project["operator_conclusion"]}"
      assert row =~ "scope #{spec.provider_scope_key}"
      assert row =~ "report action #{List.first(spec.actions)}"
      assert row =~ "report section closure_chain #{spec.status}"
      assert row =~ "report fp outcome=#{spec.project_id}-outcome-fp"

      refute_cross_project_leak!(row, spec.project_id)
    end)

    clear_row = project_row(html, "clear")
    refute clear_row =~ "operation success true"

    retry_row = project_row(html, "retry")
    refute retry_row =~ "automatic retry"
    refute retry_row =~ "queued replay true"
    refute retry_row =~ "pending retry true"
    refute retry_row =~ "pending execution true"

    no_request_row = project_row(html, "no-request")
    no_chain_row = project_row(html, "no-chain")
    refute no_request_row =~ "pending execution true"
    refute no_request_row =~ "migration queued"
    refute no_request_row =~ "legacy takeover true"
    refute no_chain_row =~ "pending retry true"
    refute no_chain_row =~ "queued replay true"
    refute no_chain_row =~ "legacy takeover true"

    refute_forbidden_markers!(inspect(api_payload, limit: :infinity, printable_limit: :infinity))
    refute_forbidden_markers!(html)
  end

  test "dry-run fixture source stays detached from execution and mutation modules" do
    source = File.read!(DryRunFixture.support_source_path())

    refute source =~ "ProviderExecutor"
    refute source =~ "DispatchPlanApplication"
    refute source =~ "RealWorkerStarter"
    refute source =~ "RealWritebackExecutor"
    refute source =~ "System.cmd"
    refute source =~ "Systemd"
    refute source =~ "WorkspaceHook"
    refute source =~ "Config.put"
    refute source =~ "legacy_takeover: true"
  end

  test "Presenter degrades legacy missing nil and summary-error-like dry-run packet inputs safely" do
    legacy_name = Module.concat(__MODULE__, :LegacyRuntime)
    legacy_snapshot = %{running: [], retrying: [], blocked: [], codex_totals: %{}, rate_limits: nil}

    start_supervised!(
      {StaticOrchestrator, name: legacy_name, snapshot: legacy_snapshot},
      id: :dry_run_legacy_runtime
    )

    legacy_payload = Presenter.state_payload(legacy_name, 100)
    refute Map.has_key?(legacy_payload, :hub_cutover_closure_report_packet)
    refute Map.has_key?(legacy_payload, :hub_device_observability)

    nil_name = Module.concat(__MODULE__, :NilPacketRuntime)

    start_supervised!(
      {StaticOrchestrator,
       name: nil_name,
       snapshot: %{
         running: [],
         retrying: [],
         blocked: [],
         codex_totals: %{},
         rate_limits: nil,
         hub_cutover_closure_report_packet: nil
       }},
      id: :dry_run_nil_packet_runtime
    )

    nil_payload = Presenter.state_payload(nil_name, 100)
    refute Map.has_key?(nil_payload, :hub_cutover_closure_report_packet)

    summary_error_name = Module.concat(__MODULE__, :SummaryErrorPacketRuntime)

    start_supervised!(
      {StaticOrchestrator,
       name: summary_error_name,
       snapshot: %{
         running: [],
         retrying: [],
         blocked: [],
         codex_totals: %{},
         rate_limits: nil,
         hub_cutover_closure_report_packet: %{
           generated_at: DryRunFixture.generated_at(),
           summary_error: %{
             code: "summary_error",
             message: "dry-run summary unavailable",
             stack_trace: "stack trace fixture ghp_secret_fixture_token /home/jhihjian/private/fixture"
           }
         }
       }},
      id: :dry_run_summary_error_packet_runtime
    )

    summary_error_payload = Presenter.state_payload(summary_error_name, 100)
    packet = summary_error_payload.hub_cutover_closure_report_packet

    assert packet.report_status == "no_chain"
    assert packet.boundary_flags.pending_execution == false
    assert packet.boundary_flags.pending_retry == false
    assert packet.boundary_flags.queued_replay == false
    assert packet.boundary_flags.legacy_takeover == false

    refute_forbidden_markers!(inspect(summary_error_payload, limit: :infinity, printable_limit: :infinity))
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

  defp assert_project_packet(projects, project_id, report_status, provider_scope_key, action, fingerprint) do
    project = Map.fetch!(projects, project_id)

    assert project.report_status == report_status
    assert project.provider_scope.provider_scope_key == provider_scope_key
    assert action in project.required_action_codes
    assert project.safe_evidence_fingerprints.outcome == fingerprint
    assert project.read_only_boundary.read_only == true
    assert project.boundary_flags.provider_calls == false
    assert project.boundary_flags.dispatch_calls == false
    assert project.boundary_flags.worker_start_calls == false
    assert project.boundary_flags.writeback_calls == false
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

  defp html_text(fragment) do
    fragment
    |> Floki.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp refute_cross_project_leak!(row, current_project_id) do
    DryRunFixture.project_specs()
    |> Enum.reject(&(&1.project_id == current_project_id))
    |> Enum.each(fn other ->
      refute row =~ other.provider_scope_key
      refute row =~ "#{other.project_id}-outcome-fp"
    end)
  end

  defp refute_forbidden_markers!(text) do
    Enum.each(DryRunFixture.forbidden_output_markers(), fn marker ->
      refute text =~ marker
    end)
  end
end
