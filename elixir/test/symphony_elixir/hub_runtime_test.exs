defmodule SymphonyElixir.HubRuntimeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{
    ActivationPreflight,
    CutoverAuthorizationConsumptionGuard,
    CutoverExecutionAuthorization,
    CutoverExecutionOutcomeLedger,
    CutoverReadinessPermit,
    CutoverReplayDecision,
    HostServiceProbe,
    ProjectRegistry,
    ProviderExecutor,
    ProviderGovernance,
    RealCandidateScanExecutor,
    RealWorkerLifecycleStore,
    RealWorkerStarter,
    RealWritebackExecutor,
    Runtime,
    RuntimeLedger
  }

  alias SymphonyElixirWeb.Presenter

  test "uses the real worker lifecycle store as the default reconciliation source" do
    previous = Application.get_env(:symphony_elixir, :hub_worker_lifecycle_result_source)
    Application.delete_env(:symphony_elixir, :hub_worker_lifecycle_result_source)

    on_exit(fn ->
      restore_app_env(:hub_worker_lifecycle_result_source, previous)
    end)

    assert Runtime.worker_lifecycle_result_source() == RealWorkerLifecycleStore
  end

  test "builds Hub snapshot with ready paused and project-level config error entries" do
    root = tmp_root("hub-runtime")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "alpha"]))
      write_project!(root, "beta", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "beta"]))

      bad_dir = Path.join(root, "bad")
      File.mkdir_p!(bad_dir)

      write_workflow_file!(Path.join(bad_dir, "WORKFLOW.md"),
        tracker_kind: "github",
        tracker_api_token: "$GITHUB_TOKEN",
        tracker_owner: "JhihJian",
        tracker_repo: nil,
        workspace_root: Path.join([root, "workspaces", "bad"])
      )

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          name: Alpha
          workflow_path: alpha/WORKFLOW.md
        - project_id: beta
          name: Beta
          workflow_path: beta/WORKFLOW.md
          paused: true
        - project_id: bad
          name: Bad
          workflow_path: bad/WORKFLOW.md
      """)

      assert :ok = Runtime.validate_config(hub_path)

      runtime_name = Module.concat(__MODULE__, :ReadyPausedErrorRuntime)

      start_supervised!(
        {Runtime, name: runtime_name, config_path: hub_path},
        id: :hub_runtime_ready_paused_error
      )

      snapshot = Runtime.snapshot(runtime_name, 15_000)

      assert snapshot.running == []
      assert snapshot.retrying == []
      assert snapshot.blocked == []
      assert snapshot.hub_runtime.mode == "hub"
      assert snapshot.hub_runtime.read_only == false
      assert snapshot.hub_runtime.poll_tick_execution == true
      assert snapshot.hub_runtime.config_path == hub_path
      assert snapshot.hub_runtime.counts.project_count == 3
      assert snapshot.hub_runtime.counts.ready_project_count == 1
      assert snapshot.hub_runtime.counts.paused_project_count == 1
      assert snapshot.hub_runtime.counts.config_error_count == 1
      assert snapshot.hub_runtime.counts.active_agent_count == 0
      assert snapshot.hub_runtime.counts.provider_scope_count == 2
      assert snapshot.hub_runtime.migration_boundary.hub_takes_over_legacy_poll_loop == false

      registry_projects = Map.new(snapshot.hub_project_registry.projects, &{&1.project_id, &1})
      assert registry_projects["alpha"].status == "ready"
      assert registry_projects["beta"].status == "paused"
      assert registry_projects["bad"].status == "error"
      assert registry_projects["bad"].load_error =~ "missing tracker.repo"

      poll_projects = Map.new(snapshot.hub_poll_coordination.projects, &{&1.project_id, &1})
      assert poll_projects["alpha"].allow_poll == true
      assert poll_projects["beta"].eligibility.reason == :paused
      assert poll_projects["bad"].eligibility.reason == :config_error

      device_projects = Map.new(snapshot.hub_device_observability.projects, &{&1.project_id, &1})
      assert device_projects["alpha"].status in ["ready_to_poll", "idle"]
      assert device_projects["beta"].status == "paused"
      assert device_projects["bad"].status == "config_invalid"
    after
      File.rm_rf(root)
    end
  end

  test "Presenter exposes safe Hub fields and legacy snapshots do not grow Hub keys" do
    root = tmp_root("hub-runtime-presenter")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "alpha"]))

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      runtime_name = Module.concat(__MODULE__, :PresenterRuntime)

      start_supervised!(
        {Runtime, name: runtime_name, config_path: hub_path},
        id: :hub_runtime_presenter
      )

      payload = Presenter.state_payload(runtime_name, 100)

      assert payload.counts.running == 0
      assert payload.hub_runtime.mode == "hub"
      assert payload.hub_cutover_gate.counts.project_count == 1
      assert payload.hub_cutover_readiness_permit.counts.permit_count == 0
      assert payload.hub_cutover_execution_outcome_ledger.status == "no_outcome"
      assert payload.hub_cutover_execution_outcome_ledger.counts.outcome_count == 0
      assert payload.hub_cutover_execution_outcome_closeout.status == "no_outcome"
      assert payload.hub_cutover_execution_outcome_closeout.counts.unresolved_outcome_count == 0
      assert payload.hub_cutover_execution_outcome_closeout.auto_replay_allowed == false
      assert payload.hub_cutover_replay_decision.status == "no_replay_decision"
      assert payload.hub_cutover_replay_decision.counts.decision_count == 0
      assert payload.hub_cutover_replay_decision.auto_replay_allowed == false
      assert payload.hub_cutover_closure_chain.status == "no_request"
      assert payload.hub_cutover_closure_chain.counts.no_request_count == 1
      assert payload.hub_cutover_closure_chain.auto_replay_allowed == false
      assert payload.hub_cutover_closure_conclusion.closure_chain_status == "no_request"
      assert payload.hub_cutover_closure_conclusion.conclusion == "no_explicit_cutover_request"
      assert payload.hub_cutover_closure_conclusion.summary_code == "closure_no_request"
      assert payload.hub_cutover_closure_conclusion.required_action_codes == ["none_required"]
      assert payload.hub_cutover_closure_conclusion.pending_execution == false
      assert payload.hub_cutover_closure_conclusion.pending_retry == false
      assert payload.hub_cutover_closure_conclusion.queued_replay == false
      assert payload.hub_cutover_closure_conclusion.legacy_takeover == false
      assert payload.hub_cutover_closure_report_packet.report_status == "no_request"
      assert payload.hub_cutover_closure_report_packet.operator_conclusion == "no_explicit_cutover_request"
      assert payload.hub_cutover_closure_report_packet.required_action_codes == ["none_required"]
      assert payload.hub_cutover_closure_report_packet.boundary_flags.pending_execution == false
      assert payload.hub_cutover_closure_report_packet.boundary_flags.pending_retry == false
      assert payload.hub_cutover_closure_report_packet.boundary_flags.queued_replay == false
      assert payload.hub_cutover_closure_report_packet.boundary_flags.legacy_takeover == false
      assert payload.hub_project_registry.project_count == 1
      assert payload.hub_poll_coordination.registry.project_count == 1
      assert payload.hub_candidate_intake.counts.candidate_count == 0
      assert payload.hub_dispatch_planning.counts.planned_count == 0
      assert payload.hub_dispatch_plan_application.counts.applied_count == 0
      assert payload.hub_worker_start_handoff.counts.selected_count == 0
      assert payload.hub_device_observability.device.project_count == 1
      assert payload.hub_device_observability.cutover_execution_outcome_closeout.status == "no_outcome"
      assert payload.hub_device_observability.overview.cutover_execution_outcome_closeout.status == "no_outcome"
      assert payload.hub_device_observability.cutover_replay_decision.status == "no_replay_decision"
      assert payload.hub_device_observability.overview.cutover_replay_decision.status == "no_replay_decision"
      assert payload.hub_device_observability.cutover_closure_chain.status == "no_request"
      assert payload.hub_device_observability.overview.cutover_closure_chain.status == "no_request"
      assert payload.hub_device_observability.cutover_closure_conclusion.conclusion == "no_explicit_cutover_request"
      assert payload.hub_device_observability.overview.cutover_closure_conclusion.summary_code == "closure_no_request"
      assert payload.hub_device_observability.cutover_closure_report_packet.report_status == "no_request"
      assert payload.hub_device_observability.overview.cutover_closure_report_packet.report_status == "no_request"
      assert payload.hub_device_observability.overview.cutover_closure_report_packet.required_action_count == 1
      assert payload.hub_device_observability.overview.cutover_closure_report_packet.blocked_by_count == 0

      safe_text = inspect(payload)
      refute safe_text =~ "GITHUB_TOKEN"
      refute safe_text =~ "Authorization:"
      refute safe_text =~ "cookie"
      refute safe_text =~ "secret"
      refute safe_text =~ "raw_config"
      refute safe_text =~ "full prompt"
      refute safe_text =~ "transcript"
      refute safe_text =~ "comment body"

      slow_name = Module.concat(__MODULE__, :PresenterSlowProjection)
      slow_snapshot = runtime_name |> Runtime.snapshot(100) |> Map.delete(:hub_snapshot_contract)

      start_supervised!(
        {__MODULE__.StaticSnapshot, name: slow_name, snapshot: slow_snapshot},
        id: :hub_runtime_presenter_slow_projection
      )

      slow_payload = Presenter.state_payload(slow_name, 100)

      for key <- Map.keys(Map.delete(payload, :generated_at)) do
        assert Map.fetch!(payload, key) == Map.fetch!(slow_payload, key), "fast Presenter projection differs at #{key}"
      end

      legacy_name = Module.concat(__MODULE__, :LegacySnapshot)

      start_supervised!(
        {__MODULE__.StaticSnapshot, name: legacy_name, snapshot: legacy_snapshot()},
        id: :hub_runtime_legacy_snapshot
      )

      legacy_payload = Presenter.state_payload(legacy_name, 100)
      refute Map.has_key?(legacy_payload, :hub_runtime)
      refute Map.has_key?(legacy_payload, :hub_cutover_gate)
      refute Map.has_key?(legacy_payload, :hub_cutover_readiness_permit)
      refute Map.has_key?(legacy_payload, :hub_cutover_execution_outcome_ledger)
      refute Map.has_key?(legacy_payload, :hub_cutover_closure_chain)
      refute Map.has_key?(legacy_payload, :hub_cutover_closure_conclusion)
      refute Map.has_key?(legacy_payload, :hub_cutover_closure_report_packet)
      refute Map.has_key?(legacy_payload, :hub_project_registry)
      refute Map.has_key?(legacy_payload, :hub_poll_coordination)
      refute Map.has_key?(legacy_payload, :hub_candidate_intake)
      refute Map.has_key?(legacy_payload, :hub_dispatch_planning)
      refute Map.has_key?(legacy_payload, :hub_dispatch_plan_application)
      refute Map.has_key?(legacy_payload, :hub_worker_start_handoff)
      refute Map.has_key?(legacy_payload, :hub_worker_lifecycle_reconciliation)
      refute Map.has_key?(legacy_payload, :hub_device_observability)
    after
      File.rm_rf(root)
    end
  end

  test "four-project idle state projection stays below one second and does not grow" do
    root = tmp_root("hub-runtime-state-performance")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      for project_id <- ["alpha", "beta", "gamma", "delta"] do
        write_project!(root, project_id,
          tracker_kind: "memory",
          workspace_root: Path.join([root, "workspaces", project_id])
        )
      end

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
        - project_id: beta
          workflow_path: beta/WORKFLOW.md
        - project_id: gamma
          workflow_path: gamma/WORKFLOW.md
        - project_id: delta
          workflow_path: delta/WORKFLOW.md
      """)

      runtime_name = Module.concat(__MODULE__, :StatePerformanceRuntime)

      start_supervised!(
        {Runtime, name: runtime_name, config_path: hub_path},
        id: :hub_runtime_state_performance
      )

      measurements =
        Enum.map(1..3, fn _index ->
          :timer.tc(fn -> runtime_name |> Presenter.state_payload(1_000) |> Jason.encode!() end)
        end)

      assert measurements |> Enum.map(&elem(&1, 0)) |> Enum.max() < 1_000_000
      assert measurements |> Enum.map(fn {_duration, body} -> byte_size(body) end) |> Enum.uniq() |> length() == 1
    after
      File.rm_rf(root)
    end
  end

  test "Presenter safely degrades closure report packet nil incompatible and summary error inputs" do
    nil_packet_name = Module.concat(__MODULE__, :ClosureReportPacketNilSnapshot)

    start_supervised!(
      {__MODULE__.StaticSnapshot,
       name: nil_packet_name,
       snapshot: %{
         running: [],
         retrying: [],
         blocked: [],
         codex_totals: %{},
         rate_limits: nil,
         hub_cutover_closure_report_packet: nil
       }},
      id: :hub_runtime_closure_report_packet_nil_snapshot
    )

    nil_payload = Presenter.state_payload(nil_packet_name, 100)
    refute Map.has_key?(nil_payload, :hub_cutover_closure_report_packet)

    incompatible_packet_name = Module.concat(__MODULE__, :ClosureReportPacketIncompatibleSnapshot)

    start_supervised!(
      {__MODULE__.StaticSnapshot,
       name: incompatible_packet_name,
       snapshot: %{
         running: [],
         retrying: [],
         blocked: [],
         codex_totals: %{},
         rate_limits: nil,
         hub_cutover_closure_report_packet: :not_a_safe_packet
       }},
      id: :hub_runtime_closure_report_packet_incompatible_snapshot
    )

    incompatible_payload = Presenter.state_payload(incompatible_packet_name, 100)
    refute Map.has_key?(incompatible_payload, :hub_cutover_closure_report_packet)

    summary_error_name = Module.concat(__MODULE__, :ClosureReportPacketSummaryErrorSnapshot)

    start_supervised!(
      {__MODULE__.StaticSnapshot,
       name: summary_error_name,
       snapshot: %{
         running: [],
         retrying: [],
         blocked: [],
         codex_totals: %{},
         rate_limits: nil,
         hub_cutover_closure_report_packet: %{
           generated_at: "2026-07-01T09:00:00Z",
           summary_error: %{
             code: "summary_error",
             stack_trace: "stack trace with ghp_secret and /home/jhihjian/private/runtime.log"
           }
         }
       }},
      id: :hub_runtime_closure_report_packet_summary_error_snapshot
    )

    summary_error_payload = Presenter.state_payload(summary_error_name, 100)

    assert summary_error_payload.hub_cutover_closure_report_packet.report_status == "no_chain"
    assert summary_error_payload.hub_cutover_closure_report_packet.boundary_flags.pending_execution == false
    assert summary_error_payload.hub_cutover_closure_report_packet.boundary_flags.pending_retry == false
    assert summary_error_payload.hub_cutover_closure_report_packet.boundary_flags.queued_replay == false
    assert summary_error_payload.hub_cutover_closure_report_packet.boundary_flags.legacy_takeover == false

    safe_text =
      inspect(summary_error_payload.hub_cutover_closure_report_packet,
        limit: :infinity,
        printable_limit: :infinity
      )

    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "stack trace"
    refute safe_text =~ "/home/jhihjian/private"
  end

  test "snapshot and presenter expose execution outcome closeout summary without replay side effects" do
    root = tmp_root("hub-runtime-outcome-closeout")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "alpha"]))

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      {:ok, registry} = ProjectRegistry.load(hub_path)
      outcome = unresolved_outcome("alpha", false)
      outcome_ledger = CutoverExecutionOutcomeLedger.build(%{events: [outcome]}, now: ~U[2026-07-01 09:00:00Z])
      consumption_guard = outcome.authorization_consumption_guard

      snapshot =
        Runtime.build_snapshot(hub_path, ~U[2026-07-01 09:00:00Z], registry,
          now: ~U[2026-07-01 09:00:00Z],
          cutover_authorization_consumption_guard: %{
            generated_at: "2026-07-01T09:00:00Z",
            decisions: [consumption_guard]
          },
          cutover_execution_outcome_ledger: outcome_ledger,
          cutover_execution_outcome_closeouts: [
            outcome_closeout(outcome, "allow_explicit_retry_consideration")
          ]
        )

      assert snapshot.hub_cutover_execution_outcome_closeout.status == "resolved"
      assert snapshot.hub_cutover_execution_outcome_closeout.counts.resolved_count == 1
      assert snapshot.hub_cutover_execution_outcome_closeout.counts.allow_explicit_retry_consideration_count == 1
      assert snapshot.hub_cutover_execution_outcome_closeout.auto_replay_allowed == false
      assert snapshot.hub_runtime.cutover_execution_outcome_closeout.status == "resolved"
      assert snapshot.hub_device_observability.overview.cutover_execution_outcome_closeout.status == "resolved"
      assert snapshot.hub_cutover_replay_decision.status == "retry_consideration_allowed"
      assert snapshot.hub_cutover_replay_decision.counts.retry_consideration_allowed_count == 1
      assert snapshot.hub_cutover_replay_decision.auto_replay_allowed == false
      assert snapshot.hub_cutover_replay_request_audit.status == "no_request"
      assert snapshot.hub_cutover_replay_request_audit.counts.request_count == 0
      assert snapshot.hub_cutover_closure_chain.status == "open_manual_attention"
      assert snapshot.hub_cutover_closure_chain.counts.open_manual_attention_count == 1
      assert snapshot.hub_cutover_closure_chain.counts.closed_succeeded_count == 0
      assert snapshot.hub_cutover_closure_chain.counts.closeout_reference_status_counts.current == 1
      assert snapshot.hub_cutover_closure_chain.auto_replay_allowed == false
      assert snapshot.hub_cutover_closure_conclusion.closure_chain_status == "open_manual_attention"
      assert snapshot.hub_cutover_closure_conclusion.conclusion == "manual_attention_required"
      assert snapshot.hub_cutover_closure_conclusion.fully_closed == false
      assert snapshot.hub_cutover_closure_conclusion.operation_success == false
      assert snapshot.hub_cutover_closure_conclusion.auto_retry_allowed == false
      assert snapshot.hub_cutover_closure_conclusion.auto_replay_allowed == false
      assert snapshot.hub_cutover_closure_conclusion.pending_execution == false
      assert snapshot.hub_cutover_closure_conclusion.pending_retry == false
      assert snapshot.hub_cutover_closure_conclusion.queued_replay == false
      assert snapshot.hub_cutover_closure_report_packet.report_status == "manual_attention_required"
      assert snapshot.hub_cutover_closure_report_packet.operator_conclusion == "manual_attention_required"
      assert snapshot.hub_cutover_closure_report_packet.fully_closed == false
      assert snapshot.hub_cutover_closure_report_packet.operation_success == false
      assert snapshot.hub_cutover_closure_report_packet.boundary_flags.auto_retry_allowed == false
      assert snapshot.hub_cutover_closure_report_packet.boundary_flags.auto_replay_allowed == false
      assert snapshot.hub_cutover_closure_report_packet.boundary_flags.pending_execution == false
      assert snapshot.hub_cutover_closure_report_packet.boundary_flags.pending_retry == false
      assert snapshot.hub_cutover_closure_report_packet.boundary_flags.queued_replay == false
      assert snapshot.hub_runtime.cutover_replay_decision.status == "retry_consideration_allowed"
      assert snapshot.hub_runtime.cutover_replay_request_audit.status == "no_request"
      assert snapshot.hub_runtime.cutover_closure_chain.status == "open_manual_attention"
      assert snapshot.hub_runtime.cutover_closure_conclusion.summary_code == "closure_open_manual_attention_required"
      assert snapshot.hub_runtime.cutover_closure_report_packet.report_status == "manual_attention_required"
      assert snapshot.hub_device_observability.overview.cutover_replay_decision.status == "retry_consideration_allowed"
      assert snapshot.hub_device_observability.overview.cutover_replay_request_audit.status == "no_request"
      assert snapshot.hub_device_observability.overview.cutover_closure_chain.status == "open_manual_attention"
      assert snapshot.hub_device_observability.overview.cutover_closure_conclusion.conclusion == "manual_attention_required"
      assert snapshot.hub_device_observability.overview.cutover_closure_report_packet.report_status == "manual_attention_required"
      assert snapshot.hub_device_observability.overview.cutover_closure_report_packet.required_action_count == 1

      [project] = snapshot.hub_device_observability.projects
      assert project.cutover_execution_outcome_closeout.status == "resolved"
      assert project.cutover_execution_outcome_closeout.allow_explicit_retry_consideration == true
      assert project.detail.outcome_closeout.allow_explicit_retry_consideration == true
      assert project.cutover_replay_decision.status == "retry_consideration_allowed"
      assert project.detail.replay_decision.status == "retry_consideration_allowed"
      assert project.detail.replay_decision.requires_operator_attention == false
      assert project.cutover_replay_request_audit.status == "no_request"
      assert project.detail.replay_request_audit.status == "no_request"
      assert project.cutover_closure_chain.status == "open_manual_attention"
      assert project.cutover_closure_chain.counts.closeout_reference_status_counts.current == 1
      assert project.detail.closure_chain.status == "open_manual_attention"
      assert project.detail.closure_chain.closeout_reference_status_counts["current"] == 1
      assert project.detail.closure_chain.auto_replay_allowed == false
      assert project.cutover_closure_conclusion.conclusion == "manual_attention_required"
      assert project.detail.closure_conclusion.summary_code == "closure_open_manual_attention_required"
      assert project.detail.closure_conclusion.auto_retry_allowed == false
      assert project.detail.closure_conclusion.auto_replay_allowed == false
      assert project.cutover_closure_report_packet.report_status == "manual_attention_required"
      assert project.cutover_closure_report_packet.closure_chain_status == "open_manual_attention"
      assert project.detail.closure_report_packet.summary_code == "closure_open_manual_attention_required"
      assert project.detail.closure_report_packet.auto_retry_allowed == false
      assert project.detail.closure_report_packet.auto_replay_allowed == false

      replay_request =
        replay_request_from_snapshot(
          outcome,
          snapshot.hub_cutover_execution_outcome_closeout,
          snapshot.hub_cutover_replay_decision
        )

      snapshot_with_request =
        Runtime.build_snapshot(hub_path, ~U[2026-07-01 09:00:00Z], registry,
          now: ~U[2026-07-01 09:00:00Z],
          cutover_authorization_consumption_guard: %{
            generated_at: "2026-07-01T09:00:00Z",
            decisions: [consumption_guard]
          },
          cutover_execution_outcome_ledger: outcome_ledger,
          cutover_execution_outcome_closeouts: [
            outcome_closeout(outcome, "allow_explicit_retry_consideration")
          ],
          cutover_readiness_permit: replay_readiness_permit_summary(outcome),
          cutover_execution_authorization_ledger: replay_authorization_ledger_summary(outcome),
          cutover_replay_requests: [replay_request]
        )

      assert snapshot_with_request.hub_cutover_replay_request_audit.status == "would_allow_retry_consideration"
      assert snapshot_with_request.hub_cutover_replay_request_audit.counts.request_count == 1
      assert snapshot_with_request.hub_cutover_replay_request_audit.counts.allow_count == 1
      assert snapshot_with_request.hub_cutover_replay_request_audit.auto_replay_allowed == false
      assert snapshot_with_request.hub_cutover_closure_chain.status == "open_manual_attention"
      assert snapshot_with_request.hub_cutover_closure_chain.counts.closed_succeeded_count == 0
      assert snapshot_with_request.hub_cutover_closure_chain.counts.replay_decision_reference_status_counts.current == 1
      assert snapshot_with_request.hub_cutover_closure_chain.counts.replay_request_audit_reference_status_counts.current == 1
      assert snapshot_with_request.hub_cutover_closure_chain.auto_replay_allowed == false
      assert snapshot_with_request.hub_cutover_closure_conclusion.conclusion == "manual_attention_required"
      assert snapshot_with_request.hub_cutover_closure_conclusion.queued_replay == false
      assert snapshot_with_request.hub_cutover_closure_report_packet.report_status == "manual_attention_required"
      assert snapshot_with_request.hub_cutover_closure_report_packet.boundary_flags.queued_replay == false
      assert snapshot_with_request.hub_runtime.cutover_replay_request_audit.status == "would_allow_retry_consideration"
      assert snapshot_with_request.hub_runtime.cutover_closure_chain.auto_replay_allowed == false
      assert snapshot_with_request.hub_runtime.cutover_closure_conclusion.auto_replay_allowed == false
      assert snapshot_with_request.hub_runtime.cutover_closure_report_packet.boundary_flags.auto_replay_allowed == false
      assert snapshot_with_request.hub_device_observability.overview.cutover_replay_request_audit.allow_count == 1
      assert snapshot_with_request.hub_device_observability.overview.cutover_closure_chain.auto_replay_allowed == false
      assert snapshot_with_request.hub_device_observability.overview.cutover_closure_conclusion.queued_replay == false

      report_packet_overview =
        snapshot_with_request.hub_device_observability.overview.cutover_closure_report_packet

      assert report_packet_overview.queued_replay == false

      [project_with_request] = snapshot_with_request.hub_device_observability.projects
      assert project_with_request.cutover_replay_request_audit.status == "would_allow_retry_consideration"
      assert project_with_request.detail.replay_request_audit.status == "would_allow_retry_consideration"
      assert [audit_record] = project_with_request.cutover_replay_request_audit.requests
      assert audit_record.outcome_link_status == "not_linked"
      assert audit_record.no_side_effects == true
      assert project_with_request.cutover_closure_chain.status == "open_manual_attention"
      assert project_with_request.cutover_closure_chain.counts.replay_request_audit_reference_status_counts.current == 1
      assert project_with_request.detail.closure_chain.status == "open_manual_attention"
      assert project_with_request.detail.closure_chain.replay_request_audit_reference_status_counts["current"] == 1
      assert project_with_request.cutover_closure_report_packet.report_status == "manual_attention_required"
      assert project_with_request.detail.closure_report_packet.closure_chain.retained_reference_status_counts["replay_request_audit"]["current"] == 1

      runtime_name = Module.concat(__MODULE__, :OutcomeCloseoutPresenter)
      static_snapshot_module = Module.concat(__MODULE__, :StaticSnapshot)

      start_supervised!(
        {static_snapshot_module, name: runtime_name, snapshot: snapshot_with_request},
        id: :hub_runtime_outcome_closeout_presenter
      )

      payload = Presenter.state_payload(runtime_name, 100)
      assert payload.hub_cutover_execution_outcome_closeout.status == "resolved"
      assert payload.hub_cutover_replay_decision.status == "retry_consideration_allowed"
      assert payload.hub_cutover_replay_decision.counts.retry_consideration_allowed_count == 1
      assert payload.hub_cutover_replay_request_audit.status == "would_allow_retry_consideration"
      assert payload.hub_cutover_replay_request_audit.counts.allow_count == 1
      assert payload.hub_cutover_closure_chain.status == "open_manual_attention"
      assert payload.hub_cutover_closure_chain.counts.replay_request_audit_reference_status_counts.current == 1
      assert payload.hub_cutover_closure_chain.auto_replay_allowed == false
      assert payload.hub_cutover_closure_conclusion.conclusion == "manual_attention_required"
      assert payload.hub_cutover_closure_conclusion.pending_retry == false
      assert payload.hub_cutover_closure_report_packet.report_status == "manual_attention_required"
      assert payload.hub_cutover_closure_report_packet.boundary_flags.pending_retry == false

      payload_closeout = payload.hub_device_observability.overview.cutover_execution_outcome_closeout
      assert payload_closeout.allow_explicit_retry_consideration_count == 1
      assert payload.hub_device_observability.overview.cutover_replay_decision.retry_consideration_allowed_count == 1
      assert payload.hub_device_observability.overview.cutover_replay_request_audit.allow_count == 1

      closure_counts =
        payload.hub_device_observability.overview.cutover_closure_chain.closure_status_counts

      assert closure_counts.open_manual_attention == 1
      assert payload.hub_device_observability.overview.cutover_closure_report_packet.report_status == "manual_attention_required"
      assert payload.hub_device_observability.overview.cutover_closure_report_packet.required_action_count == 1

      safe_text =
        inspect(
          {
            payload.hub_cutover_execution_outcome_closeout,
            payload.hub_cutover_replay_decision,
            payload.hub_cutover_replay_request_audit,
            payload.hub_cutover_closure_chain,
            payload.hub_cutover_closure_conclusion,
            payload.hub_cutover_closure_report_packet,
            payload.hub_device_observability.cutover_execution_outcome_closeout,
            payload.hub_device_observability.cutover_replay_decision,
            payload.hub_device_observability.cutover_replay_request_audit,
            payload.hub_device_observability.cutover_closure_chain,
            payload.hub_device_observability.cutover_closure_conclusion,
            payload.hub_device_observability.cutover_closure_report_packet
          },
          limit: :infinity,
          printable_limit: :infinity
        )

      refute safe_text =~ "ghp_secret"
      refute safe_text =~ "raw_provider_response"
      refute safe_text =~ "/home/jhihjian/private"
    after
      File.rm_rf(root)
    end
  end

  test "Runtime closure chain snapshot counts succeeded no-side-effect retryable manual and malformed evidence" do
    root = tmp_root("hub-runtime-closure-chain-counts")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      for project_id <- ["success", "clear", "retry", "manual", "unknown", "malformed"] do
        write_project!(root, project_id, tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", project_id]))
      end

      File.write!(hub_path, """
      projects:
        - project_id: success
          workflow_path: success/WORKFLOW.md
          migration_state: hub_managed
        - project_id: clear
          workflow_path: clear/WORKFLOW.md
          migration_state: hub_managed
        - project_id: retry
          workflow_path: retry/WORKFLOW.md
          migration_state: hub_managed
        - project_id: manual
          workflow_path: manual/WORKFLOW.md
          migration_state: hub_managed
        - project_id: unknown
          workflow_path: unknown/WORKFLOW.md
          migration_state: hub_managed
        - project_id: malformed
          workflow_path: malformed/WORKFLOW.md
          migration_state: hub_managed
      """)

      {:ok, registry} = ProjectRegistry.load(hub_path)

      outcomes = [
        closure_outcome("success", "succeeded"),
        closure_outcome("clear", "not_executed",
          guard_decision: "no_authorization",
          side_effect_entered: false,
          side_effect_may_have_happened: false
        ),
        closure_outcome("retry", "retryable"),
        closure_outcome("manual", "manual_attention"),
        closure_outcome("unknown", "unknown"),
        closure_outcome("malformed", "malformed")
      ]

      snapshot =
        Runtime.build_snapshot(hub_path, ~U[2026-07-01 09:00:00Z], registry,
          now: ~U[2026-07-01 09:00:00Z],
          cutover_execution_outcome_ledger:
            CutoverExecutionOutcomeLedger.build(%{events: outcomes},
              now: ~U[2026-07-01 09:00:00Z]
            )
        )

      closure = snapshot.hub_cutover_closure_chain
      assert closure.status == "malformed"
      assert closure.counts.chain_count == 6
      assert closure.counts.closed_succeeded_count == 1
      assert closure.counts.closed_no_side_effect_count == 1
      assert closure.counts.open_retryable_count == 1
      assert closure.counts.open_manual_attention_count == 2
      assert closure.counts.malformed_count == 1
      assert closure.auto_replay_allowed == false
      assert snapshot.hub_cutover_closure_conclusion.closure_chain_status == "malformed"
      assert snapshot.hub_cutover_closure_conclusion.conclusion == "input_malformed"
      assert snapshot.hub_cutover_closure_conclusion.fully_closed == false
      assert snapshot.hub_cutover_closure_conclusion.operation_success == false
      assert "fix_malformed_chain_input" in snapshot.hub_cutover_closure_conclusion.required_action_codes
      assert "request_explicit_retry_consideration" in snapshot.hub_cutover_closure_conclusion.required_action_codes
      assert "resolve_manual_attention" in snapshot.hub_cutover_closure_conclusion.required_action_codes
      assert snapshot.hub_cutover_closure_report_packet.report_status == "malformed_input_review_required"
      assert snapshot.hub_cutover_closure_report_packet.operator_conclusion == "input_malformed"
      assert snapshot.hub_cutover_closure_report_packet.fully_closed == false
      assert snapshot.hub_cutover_closure_report_packet.operation_success == false
      assert snapshot.hub_cutover_closure_report_packet.boundary_flags.auto_retry_allowed == false
      assert snapshot.hub_cutover_closure_report_packet.boundary_flags.auto_replay_allowed == false
      assert snapshot.hub_cutover_closure_report_packet.boundary_flags.pending_execution == false
      assert snapshot.hub_cutover_closure_report_packet.boundary_flags.pending_retry == false
      assert snapshot.hub_cutover_closure_report_packet.boundary_flags.queued_replay == false
      assert snapshot.hub_runtime.cutover_closure_chain.counts.chain_count == 6
      assert snapshot.hub_runtime.cutover_closure_conclusion.summary_code == "closure_input_malformed"
      assert snapshot.hub_runtime.cutover_closure_report_packet.report_status == "malformed_input_review_required"

      closure_counts =
        snapshot.hub_device_observability.overview.cutover_closure_chain.closure_status_counts

      assert closure_counts.open_manual_attention == 2
      assert snapshot.hub_device_observability.overview.cutover_closure_conclusion.fully_closed == false
      assert snapshot.hub_device_observability.overview.cutover_closure_conclusion.operation_success == false
      assert snapshot.hub_device_observability.overview.cutover_closure_report_packet.report_status == "malformed_input_review_required"
      assert snapshot.hub_device_observability.overview.cutover_closure_report_packet.fully_closed == false
      assert snapshot.hub_device_observability.overview.cutover_closure_report_packet.operation_success == false

      projects = Map.new(snapshot.hub_device_observability.projects, &{&1.project_id, &1})
      assert projects["success"].cutover_closure_chain.status == "closed_succeeded"
      assert projects["clear"].cutover_closure_chain.status == "closed_no_side_effect"
      assert projects["retry"].cutover_closure_chain.status == "open_retryable"
      assert projects["manual"].cutover_closure_chain.status == "open_manual_attention"
      assert projects["unknown"].cutover_closure_chain.status == "open_manual_attention"
      assert projects["malformed"].cutover_closure_chain.status == "malformed"
      assert projects["success"].cutover_closure_conclusion.operation_success == true
      assert projects["clear"].cutover_closure_conclusion.conclusion == "closed_no_side_effect"
      assert projects["clear"].cutover_closure_conclusion.operation_success == false
      assert projects["clear"].cutover_closure_report_packet.report_status == "closed_no_side_effect"
      assert projects["clear"].cutover_closure_report_packet.operation_success == false
      assert projects["retry"].cutover_closure_conclusion.conclusion == "waiting_explicit_retry_consideration"
      assert projects["retry"].cutover_closure_conclusion.auto_retry_allowed == false
      assert projects["retry"].cutover_closure_conclusion.queued_replay == false
      assert projects["retry"].cutover_closure_report_packet.report_status == "retry_consideration_required"
      assert projects["retry"].cutover_closure_report_packet.auto_retry_allowed == false
      assert projects["retry"].cutover_closure_report_packet.queued_replay == false
      assert projects["manual"].detail.closure_conclusion.conclusion == "manual_attention_required"
      assert projects["manual"].detail.closure_report_packet.report_status == "manual_attention_required"

      runtime_name = Module.concat(__MODULE__, :ClosureChainCountsSnapshot)

      start_supervised!(
        {__MODULE__.StaticSnapshot, name: runtime_name, snapshot: snapshot},
        id: :hub_runtime_closure_chain_counts_snapshot
      )

      payload = Presenter.state_payload(runtime_name, 100)
      assert payload.hub_cutover_closure_chain.counts.chain_count == 6
      assert payload.hub_cutover_closure_conclusion.closure_chain_status == "malformed"
      assert payload.hub_cutover_closure_conclusion.fully_closed == false
      assert payload.hub_cutover_closure_report_packet.report_status == "malformed_input_review_required"
      assert payload.hub_cutover_closure_report_packet.fully_closed == false
      assert payload.hub_device_observability.overview.cutover_closure_chain.closure_status_counts.open_retryable == 1
      assert payload.hub_device_observability.overview.cutover_closure_conclusion.summary_code == "closure_input_malformed"
      assert payload.hub_device_observability.overview.cutover_closure_report_packet.summary_code == "closure_input_malformed"

      safe_text =
        inspect({
          payload.hub_cutover_closure_chain,
          payload.hub_cutover_closure_conclusion,
          payload.hub_cutover_closure_report_packet,
          payload.hub_device_observability.overview.cutover_closure_chain,
          payload.hub_device_observability.overview.cutover_closure_conclusion,
          payload.hub_device_observability.overview.cutover_closure_report_packet
        })

      refute safe_text =~ "ghp_secret"
      refute safe_text =~ "raw_provider_response"
      refute safe_text =~ "full prompt"
      refute safe_text =~ "/home/jhihjian/private"
    after
      File.rm_rf(root)
    end
  end

  test "Hub runtime consumes operator acknowledgement into activation plan without changing execution gates" do
    root = tmp_root("hub-runtime-activation-ack")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "alpha"]))

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_ready
      """)

      activation_probe = %{
        projects: [
          %{
            project_id: "alpha",
            status: "not_hub_managed",
            reason: "migration_state_not_hub_managed",
            probe_source: "host_service_probe",
            checked_at: "2026-06-28T09:00:00Z",
            detected_legacy_ownership: [],
            unknown_probe_results: []
          }
        ]
      }

      registry = Runtime.validate_config(hub_path)
      assert registry == :ok

      {:ok, loaded_registry} = ProjectRegistry.load(hub_path)

      base_snapshot =
        Runtime.build_snapshot(hub_path, ~U[2026-06-28 09:00:00Z], loaded_registry,
          now: ~U[2026-06-28 09:00:00Z],
          activation_probe: activation_probe,
          activation_preflight: ActivationPreflight.build(loaded_registry, now: ~U[2026-06-28 09:00:00Z], probe: activation_probe),
          provider_executor: RealWritebackExecutor,
          scheduler: %{enabled: true, status: "scheduled"}
        )

      [base_project] = base_snapshot.hub_device_observability.projects
      plan_id = base_project.activation_plan.plan_id
      assert base_project.activation_plan.status == "ack_required"

      snapshot =
        Runtime.build_snapshot(hub_path, ~U[2026-06-28 09:00:00Z], loaded_registry,
          now: ~U[2026-06-28 09:02:00Z],
          activation_probe: activation_probe,
          activation_preflight: ActivationPreflight.build(loaded_registry, now: ~U[2026-06-28 09:02:00Z], probe: activation_probe),
          provider_executor: RealWritebackExecutor,
          scheduler: %{enabled: true, status: "running"},
          operator_acknowledgements: [
            %{
              project_id: "alpha",
              plan_id: plan_id,
              source: "operator-file",
              created_at: "2026-06-28T09:01:00Z",
              acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"],
              note: "已人工确认，不触发自动迁移"
            }
          ]
        )

      [project] = snapshot.hub_device_observability.projects

      assert project.activation_plan.status == "plan_ready"
      assert project.activation_plan.operator_acknowledgement.status == "accepted"
      assert project.activation_plan.hub_owned_actions_allowed == false
      assert project.cutover_gate.decision == "blocked"
      assert "migration_state_not_hub_managed" in Enum.map(project.cutover_gate.blocking_reasons, & &1.code)
      assert snapshot.hub_cutover_gate.counts.blocked_count == 1
      assert snapshot.hub_runtime.cutover_gate.status == "blocked"
      assert snapshot.hub_runtime.operator_acknowledgements.status in ["plan_ready", "blocked"]
      assert "activation_preflight" in project.activation_plan.hub_owned_actions_remain_guarded_by

      safe_text = inspect(snapshot.hub_device_observability.activation_plan)
      refute safe_text =~ "自动迁移"
      refute safe_text =~ "GITHUB_TOKEN"
    after
      File.rm_rf(root)
    end
  end

  test "Hub snapshot and state API expose safe cutover operation dry-run audit" do
    root = tmp_root("hub-runtime-cutover-operation-audit")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "alpha"]))

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      activation_probe = %{
        projects: [
          %{
            project_id: "alpha",
            status: "safe_to_manage",
            safe_to_manage: true,
            reason: "hub_managed_no_conflict",
            probe_source: "host_service_probe",
            checked_at: "2026-06-28T09:00:00Z",
            detected_legacy_ownership: [],
            unknown_probe_results: []
          }
        ]
      }

      assert :ok = Runtime.validate_config(hub_path)
      {:ok, loaded_registry} = ProjectRegistry.load(hub_path)

      base_snapshot =
        Runtime.build_snapshot(hub_path, ~U[2026-06-28 09:00:00Z], loaded_registry,
          now: ~U[2026-06-28 09:00:00Z],
          activation_probe: activation_probe,
          activation_preflight: ActivationPreflight.build(loaded_registry, now: ~U[2026-06-28 09:00:00Z], probe: activation_probe),
          provider_executor: RealWritebackExecutor,
          scheduler: %{enabled: true, status: "scheduled"}
        )

      [base_project] = base_snapshot.hub_device_observability.projects
      plan_id = base_project.activation_plan.plan_id

      ack = %{
        project_id: "alpha",
        plan_id: plan_id,
        source: "operator-file",
        created_at: "2026-06-28T09:01:00Z",
        acknowledged_action_codes: ["confirm_hub_executor_modes"]
      }

      ready_snapshot =
        Runtime.build_snapshot(hub_path, ~U[2026-06-28 09:00:00Z], loaded_registry,
          now: ~U[2026-06-28 09:04:00Z],
          activation_probe: activation_probe,
          activation_preflight: ActivationPreflight.build(loaded_registry, now: ~U[2026-06-28 09:04:00Z], probe: activation_probe),
          provider_executor: RealWritebackExecutor,
          scheduler: %{enabled: true, status: "scheduled"},
          operator_acknowledgements: [ack]
        )

      [ready_project] = ready_snapshot.hub_device_observability.projects
      gate = ready_project.cutover_gate

      request = %{
        request_id: "cutover-dry-run-alpha",
        project_id: "alpha",
        provider_scope: %{kind: "memory", provider_scope_key: "memory:alpha"},
        requested_operations: ["writeback"],
        activation_plan_id: ready_project.activation_plan.plan_id,
        cutover_gate_decision: gate.decision,
        cutover_gate_fingerprint: gate.staged_ownership_record.record_id,
        staged_ownership_record_id: gate.staged_ownership_record.record_id,
        source: "operator-file",
        requested_at: "2026-06-28T09:03:00Z",
        operator_intent: %{action_codes: ["run_read_only_dry_run"], note: "full prompt / token should not leak"},
        safe_project_snapshot: %{
          migration_state: ready_project.migration_state,
          status: ready_project.status,
          provider_scope_key: ready_project.provider.provider_scope_key,
          config_fingerprint: ready_project.detail.config.config_fingerprint
        }
      }

      permit_snapshot =
        Runtime.build_snapshot(hub_path, ~U[2026-06-28 09:00:00Z], loaded_registry,
          now: ~U[2026-06-28 09:04:00Z],
          activation_probe: activation_probe,
          activation_preflight: ActivationPreflight.build(loaded_registry, now: ~U[2026-06-28 09:04:00Z], probe: activation_probe),
          provider_executor: RealWritebackExecutor,
          scheduler: %{enabled: true, status: "scheduled"},
          operator_acknowledgements: [ack],
          cutover_operation_requests: [request]
        )

      [operation_permit] =
        permit_snapshot.hub_device_observability.projects
        |> hd()
        |> get_in([:cutover_readiness_permit, :permits])

      authorization_request = %{
        authorization_request_id: "authorization-alpha-writeback",
        project_id: "alpha",
        provider_scope: %{kind: "memory", provider_scope_key: "memory:alpha"},
        operation: "writeback",
        cutover_operation_request_fingerprint: operation_permit.request.request_fingerprint,
        readiness_permit_fingerprint: operation_permit.permit_fingerprint,
        readiness_permit_decision: operation_permit.decision,
        activation_plan_fingerprint: operation_permit.activation_plan.fingerprint,
        operator_acknowledgement_fingerprint: operation_permit.operator_acknowledgement.fingerprint,
        cutover_gate_decision: operation_permit.cutover_gate.decision,
        cutover_gate_fingerprint: operation_permit.cutover_gate.fingerprint,
        dry_run_audit_fingerprint: operation_permit.evidence_fingerprints.dry_run_audit,
        audit_history_fingerprint: operation_permit.evidence_fingerprints.audit_history,
        evidence_fingerprints: %{runtime_modes: operation_permit.evidence_fingerprints.runtime_modes},
        executor_modes: operation_permit.executor_modes,
        skeleton_mode: operation_permit.executor_modes.skeleton_mode,
        dry_run_mode: operation_permit.executor_modes.dry_run_mode,
        unsupported_mode: operation_permit.executor_modes.unsupported_mode,
        source: "operator-file",
        requested_at: "2026-06-28T09:04:30Z",
        operator_intent: %{action_codes: ["authorize_explicit_execution"], note: "Authorization Bearer token should not leak"}
      }

      snapshot =
        Runtime.build_snapshot(hub_path, ~U[2026-06-28 09:00:00Z], loaded_registry,
          now: ~U[2026-06-28 09:04:00Z],
          activation_probe: activation_probe,
          activation_preflight: ActivationPreflight.build(loaded_registry, now: ~U[2026-06-28 09:04:00Z], probe: activation_probe),
          provider_executor: RealWritebackExecutor,
          scheduler: %{enabled: true, status: "scheduled"},
          operator_acknowledgements: [ack],
          cutover_operation_requests: [request],
          cutover_execution_authorization_requests: [authorization_request]
        )

      assert snapshot.hub_cutover_operation_audit.status == "dry_run_ready"
      assert snapshot.hub_cutover_audit_history.status == "history_ready"
      assert snapshot.hub_cutover_readiness_permit.status == "ready_for_execution_consideration"
      assert snapshot.hub_cutover_execution_authorization_ledger.status == "authorized_for_explicit_execution"
      assert snapshot.hub_runtime.cutover_operation_audit.counts.request_count == 1
      assert snapshot.hub_runtime.cutover_audit_history.counts.history_entry_count == 1
      assert snapshot.hub_runtime.cutover_readiness_permit.counts.permit_count == 1
      assert snapshot.hub_runtime.cutover_readiness_permit.counts.ready_count == 1
      assert snapshot.hub_runtime.cutover_execution_authorization_ledger.counts.record_count == 1
      assert snapshot.hub_runtime.cutover_execution_authorization_ledger.counts.authorized_count == 1
      assert snapshot.hub_runtime.cutover_authorization_consumption_guard.status == "no_consumption"
      assert snapshot.hub_runtime.cutover_authorization_consumption_guard.counts.consumption_count == 0
      assert snapshot.hub_device_observability.cutover_operation_audit.counts.dry_run_ready_count == 1
      assert snapshot.hub_device_observability.cutover_audit_history.counts.unresolved_manual_attention_count == 0
      assert snapshot.hub_device_observability.cutover_readiness_permit.counts.ready_count == 1
      assert snapshot.hub_device_observability.cutover_execution_authorization_ledger.counts.authorized_count == 1
      assert snapshot.hub_device_observability.cutover_authorization_consumption_guard.status == "no_consumption"
      [project] = snapshot.hub_device_observability.projects
      assert project.cutover_operation_audit.request.request_id == "cutover-dry-run-alpha"
      assert [%{decision: "would_allow", dry_run_only: true, operation: "writeback"}] = project.cutover_operation_audit.operation_results
      assert project.cutover_audit_history.latest_audit.request_id == "cutover-dry-run-alpha"
      assert project.cutover_audit_history.dry_run_only == true
      assert project.cutover_audit_history.no_side_effects == true
      assert [%{decision: "ready_for_execution_consideration", operation: "writeback"}] = project.cutover_readiness_permit.permits
      assert [%{status: "authorized_for_explicit_execution", operation: "writeback"}] = project.cutover_execution_authorization_ledger.records

      runtime_name = Module.concat(__MODULE__, :CutoverOperationAuditSnapshot)

      start_supervised!(
        {__MODULE__.StaticSnapshot, name: runtime_name, snapshot: snapshot},
        id: :hub_runtime_cutover_operation_audit_snapshot
      )

      payload = Presenter.state_payload(runtime_name, 100)
      assert payload.hub_cutover_operation_audit.counts.request_count == 1
      assert payload.hub_cutover_audit_history.counts.history_entry_count == 1
      assert payload.hub_cutover_readiness_permit.counts.ready_count == 1
      assert payload.hub_cutover_execution_authorization_ledger.counts.authorized_count == 1
      assert payload.hub_cutover_authorization_consumption_guard.status == "no_consumption"
      assert payload.hub_device_observability.overview.cutover_operation_audit.request_count == 1
      assert payload.hub_device_observability.overview.cutover_audit_history.history_entry_count == 1
      assert payload.hub_device_observability.overview.cutover_readiness_permit.ready_count == 1
      assert payload.hub_device_observability.overview.cutover_execution_authorization_ledger.authorized_count == 1
      assert payload.hub_device_observability.overview.cutover_authorization_consumption_guard.consumption_count == 0
      assert payload.hub_device_observability.projects |> hd() |> get_in([:cutover_audit_history, :status]) == "history_ready"
      assert payload.hub_device_observability.projects |> hd() |> get_in([:cutover_readiness_permit, :status]) == "ready_for_execution_consideration"

      assert payload.hub_device_observability.projects
             |> hd()
             |> get_in([:cutover_execution_authorization_ledger, :status]) ==
               "authorized_for_explicit_execution"

      safe_text = inspect(payload)
      refute safe_text =~ "full prompt"
      refute safe_text =~ "should not leak"
      refute safe_text =~ "Bearer token"
    after
      File.rm_rf(root)
    end
  end

  test "Hub snapshot and state API expose safe writeback executor pressure" do
    root = tmp_root("hub-runtime-writeback-summary")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "alpha"]))
      write_project!(root, "beta", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "beta"]))

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
        - project_id: beta
          workflow_path: beta/WORKFLOW.md
          migration_state: hub_managed
      """)

      runtime_ledger =
        RuntimeLedger.new(
          projects: [
            writeback_project("alpha", [
              %{
                intent_key: "alpha:memory:alpha:129:writeback:status_set:ready",
                logical_action: "status_set",
                operation_type: "status_set",
                target: %{issue_id: "129", state: "in_progress", body: "plain body should not leak"},
                replay_policy: :idempotent,
                result_status: :pending,
                provider_result_status: nil,
                provider_replayable: true,
                manual_attention: false
              },
              %{
                intent_key: "alpha:memory:alpha:129:writeback:comment_append:body",
                logical_action: "comment_append",
                operation_type: "comment_append",
                target: %{issue_id: "129", body: "append comment body should not leak"},
                replay_policy: :non_idempotent,
                result_status: :unknown,
                provider_result_status: "unknown_result",
                provider_replayable: false,
                manual_attention: true,
                manual_attention_reason: "unknown_append_comment_requires_manual_attention",
                error_summary: "Bearer ghp_secret_token"
              }
            ]),
            writeback_project("beta", [
              %{
                intent_key: "beta:memory:beta:77:writeback:label_add:bug",
                logical_action: "label_add",
                operation_type: "label_add",
                target: %{issue_id: "77", labels: ["bug"]},
                replay_policy: :idempotent,
                result_status: :succeeded,
                provider_result_status: "success",
                provider_replayable: false,
                manual_attention: false
              }
            ])
          ]
        )

      runtime_name = Module.concat(__MODULE__, :WritebackSummaryRuntime)

      runtime_opts = [
        name: runtime_name,
        config_path: hub_path,
        provider_executor: RealWritebackExecutor,
        runtime_ledger: runtime_ledger
      ]

      start_supervised!(
        {Runtime, runtime_opts},
        id: :hub_runtime_writeback_summary
      )

      snapshot = Runtime.snapshot(runtime_name, 100)

      assert snapshot.hub_runtime.provider_executor.mode == "real_writeback"
      assert "stage_writeback" in snapshot.hub_runtime.provider_executor.supported_operations
      assert "pr_create" in snapshot.hub_runtime.provider_executor.rejected_operations
      assert snapshot.hub_runtime.writeback.counts.pending == 1
      assert snapshot.hub_runtime.writeback.counts.succeeded == 1
      assert snapshot.hub_runtime.writeback.counts.unknown == 1
      assert snapshot.hub_runtime.writeback.counts.manual_attention == 1

      projects = Map.new(snapshot.hub_runtime.writeback.projects, &{&1.project_id, &1})
      assert projects["alpha"].pending_count == 1
      assert projects["alpha"].manual_attention_count == 1
      assert projects["beta"].counts.succeeded == 1
      assert [%{project_id: "alpha", error_class: "unknown_result"} | _] = snapshot.hub_runtime.writeback.recent_errors

      payload = Presenter.state_payload(runtime_name, 100)
      assert payload.hub_runtime.writeback.counts.manual_attention == 1
      assert payload.hub_dispatch_boundary.projects |> Enum.find(&(&1.project_id == "alpha")) |> get_in([:writebacks, :counts, :unknown]) == 1

      safe_text = inspect({snapshot.hub_runtime.writeback, payload})
      refute safe_text =~ "plain body should not leak"
      refute safe_text =~ "append comment body should not leak"
      refute safe_text =~ "ghp_secret_token"
      refute safe_text =~ "Bearer"
      refute safe_text =~ "Authorization:"
      refute safe_text =~ "raw_provider"
      refute safe_text =~ "full prompt"
      refute safe_text =~ "transcript"
    after
      File.rm_rf(root)
    end
  end

  test "Hub runtime exposes separate production candidate scan and writeback executors" do
    root = tmp_root("hub-runtime-split-executors")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "alpha"]))

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      activation_probe = %{
        projects: [
          %{
            project_id: "alpha",
            status: "safe_to_manage",
            safe_to_manage: true,
            reason: "hub_managed_no_conflict",
            probe_source: "host_service_probe",
            checked_at: "2026-06-30T09:00:00Z",
            detected_legacy_ownership: [],
            unknown_probe_results: []
          }
        ]
      }

      operator_acknowledgements =
        cutover_acknowledgements!(hub_path,
          provider_executor: RealCandidateScanExecutor,
          writeback_executor: RealWritebackExecutor,
          worker_start_starter: RealWorkerStarter,
          activation_probe: activation_probe,
          scheduler_enabled: true
        )

      runtime_name = Module.concat(__MODULE__, :SplitExecutorsRuntime)

      start_supervised!(
        {Runtime,
         name: runtime_name,
         config_path: hub_path,
         provider_executor: RealCandidateScanExecutor,
         writeback_executor: RealWritebackExecutor,
         worker_start_starter: RealWorkerStarter,
         activation_probe: activation_probe,
         operator_acknowledgements: operator_acknowledgements,
         scheduler_enabled: false},
        id: :hub_runtime_split_executors
      )

      snapshot = Runtime.snapshot(runtime_name, 15_000)

      assert snapshot.hub_runtime.provider_executor.mode == "real_candidate_scan"
      assert snapshot.hub_runtime.provider_executor.supported_operations == ["candidate_scan"]
      assert snapshot.hub_runtime.writeback_executor.mode == "real_writeback"
      assert "stage_writeback" in snapshot.hub_runtime.writeback_executor.supported_operations
      assert snapshot.hub_runtime.writeback.executor.mode == "real_writeback"
      assert snapshot.hub_runtime.worker_starter.mode == "real_worker_starter"

      {:ok, loaded_registry} = ProjectRegistry.load(hub_path)

      gate_snapshot =
        Runtime.build_snapshot(hub_path, ~U[2026-06-30 09:02:00Z], loaded_registry,
          now: ~U[2026-06-30 09:02:00Z],
          activation_probe: activation_probe,
          activation_preflight: ActivationPreflight.build(loaded_registry, now: ~U[2026-06-30 09:02:00Z], probe: activation_probe),
          provider_executor: RealCandidateScanExecutor,
          writeback_executor: RealWritebackExecutor,
          worker_start_starter: RealWorkerStarter,
          operator_acknowledgements: operator_acknowledgements,
          scheduler: %{enabled: true, status: "scheduled"}
        )

      [project_gate] = gate_snapshot.hub_cutover_gate.projects
      assert "poll" in project_gate.allowed_operations
      assert "writeback" in project_gate.allowed_operations

      reason_codes = Enum.map(project_gate.blocking_reasons ++ project_gate.advisory_reasons, & &1.code)
      refute "provider_executor_candidate_scan_not_real" in reason_codes
      refute "writeback_executor_not_real" in reason_codes

      payload = Presenter.state_payload(runtime_name, 100)
      assert payload.hub_runtime.provider_executor.mode == "real_candidate_scan"
      assert payload.hub_runtime.writeback_executor.mode == "real_writeback"
    after
      File.rm_rf(root)
    end
  end

  test "StatusDashboard renders Hub runtime line from live runtime snapshot" do
    root = tmp_root("hub-runtime-dashboard")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "alpha"]))
      write_project!(root, "beta", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "beta"]))

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
        - project_id: beta
          workflow_path: beta/WORKFLOW.md
          migration_state: hub_managed
      """)

      runtime_name = Module.concat(__MODULE__, :DashboardRuntime)

      start_supervised!(
        {Runtime, name: runtime_name, config_path: hub_path},
        id: :hub_runtime_dashboard
      )

      parent = self()
      dashboard_name = Module.concat(__MODULE__, :Dashboard)
      render_fun = fn content -> send(parent, {:dashboard_frame, content}) end

      dashboard_opts = [
        name: dashboard_name,
        orchestrator: runtime_name,
        mode: :hub,
        enabled: true,
        refresh_ms: 60_000,
        render_interval_ms: 0,
        render_fun: render_fun
      ]

      start_supervised!(
        {StatusDashboard, dashboard_opts},
        id: :hub_runtime_dashboard_status
      )

      send(Process.whereis(dashboard_name), :refresh)

      assert_receive {:dashboard_frame, content}, 1_000

      assert content =~ "│ Hub mode: "
      assert content =~ "2 projects"
      assert content =~ "0 config errors"
      assert content =~ "2 provider scopes"
      assert content =~ "poll tick"
    after
      File.rm_rf(root)
    end
  end

  test "StatusDashboard omits Hub runtime line for legacy snapshots" do
    runtime_name = Module.concat(__MODULE__, :DashboardLegacySnapshot)

    start_supervised!(
      {__MODULE__.StaticSnapshot, name: runtime_name, snapshot: legacy_snapshot()},
      id: :hub_runtime_dashboard_legacy_snapshot
    )

    parent = self()
    dashboard_name = Module.concat(__MODULE__, :DashboardLegacy)

    start_supervised!(
      {StatusDashboard,
       name: dashboard_name,
       orchestrator: runtime_name,
       mode: :legacy,
       enabled: true,
       refresh_ms: 60_000,
       render_interval_ms: 0,
       render_fun: fn content -> send(parent, {:dashboard_frame, content}) end},
      id: :hub_runtime_dashboard_legacy_status
    )

    send(Process.whereis(dashboard_name), :refresh)

    assert_receive {:dashboard_frame, content}, 1_000
    refute content =~ "│ Hub mode: "
  end

  test "string-key snapshots are exposed without creating atoms" do
    unknown_keys =
      Enum.map(1..200, fn index ->
        "future_unknown_key_#{System.unique_integer([:positive])}_#{index}"
      end)

    snapshot =
      Runtime.build_snapshot("/tmp/HUB.yaml", ~U[2026-06-29 00:00:00Z], %{
        projects: [],
        warnings: [],
        errors: []
      })
      |> Jason.encode!()
      |> Jason.decode!()
      |> put_in(["hub_project_registry"], unknown_registry(unknown_keys))

    runtime_name = Module.concat(__MODULE__, :StringKeyRuntime)

    start_supervised!(
      {__MODULE__.StaticSnapshot, name: runtime_name, snapshot: snapshot},
      id: :hub_runtime_string_key_snapshot
    )

    warm_runtime_name = Module.concat(__MODULE__, :StringKeyWarmRuntime)

    start_supervised!(
      {__MODULE__.StaticSnapshot, name: warm_runtime_name, snapshot: legacy_snapshot()},
      id: :hub_runtime_string_key_warm_snapshot
    )

    _warm_payload = Presenter.state_payload(warm_runtime_name, 100)
    atom_count_before = :erlang.system_info(:atom_count)

    payload = Presenter.state_payload(runtime_name, 100)
    assert payload.hub_project_registry[List.first(unknown_keys)] == "visible"
    assert :erlang.system_info(:atom_count) - atom_count_before < 50
  end

  test "invalid Hub config files produce diagnostic CLI/runtime validation errors" do
    root = tmp_root("hub-runtime-invalid")
    empty_path = Path.join(root, "HUB.yaml")

    try do
      File.mkdir_p!(root)
      File.write!(empty_path, "  \n")

      assert {:error, "Hub config must not be empty"} = Runtime.validate_config(empty_path)

      File.write!(empty_path, """
      projects:
        - project_id: dup
          workflow_path: WORKFLOW.md
        - project_id: dup
          workflow_path: WORKFLOW.md
      """)

      assert {:error, message} = Runtime.validate_config(empty_path)
      assert message =~ "Duplicate Hub project_id"
    after
      File.rm_rf(root)
    end
  end

  test "request_refresh executes a governed candidate scan tick and feeds next poll planning" do
    root = tmp_root("hub-runtime-poll-tick-success")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha",
        tracker_kind: "memory",
        workspace_root: Path.join([root, "workspaces", "alpha"]),
        poll_interval_ms: 60_000
      )

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      runtime_name = Module.concat(__MODULE__, :PollTickSuccessRuntime)

      provider_executor = success_executor(self())
      operator_acknowledgements = cutover_acknowledgements!(hub_path, provider_executor: provider_executor)

      runtime_opts = [
        name: runtime_name,
        config_path: hub_path,
        provider_executor: provider_executor,
        operator_acknowledgements: operator_acknowledgements
      ]

      start_supervised!(
        {Runtime, runtime_opts},
        id: :hub_runtime_poll_tick_success
      )

      assert %{
               operations: operations,
               poll_tick: %{status: "completed", selected_count: 1}
             } = Runtime.request_refresh(runtime_name)

      assert "hub_cutover_closure_report_packet" in operations

      assert_receive {:provider_candidate_scan, request}, 1_000
      assert request.operation_kind == :candidate_scan
      assert request.project_id == "alpha"
      assert request.provider_scope_key == "memory:alpha"

      snapshot = Runtime.snapshot(runtime_name, 100)
      assert snapshot.hub_runtime.poll_tick.status == "completed"
      assert snapshot.hub_runtime.poll_tick.result_counts == %{"success" => 1}
      assert snapshot.hub_runtime.poll_tick.candidate_intake.candidate_count == 2
      assert snapshot.hub_runtime.poll_tick.candidate_intake.eligible_count == 0
      assert snapshot.hub_runtime.poll_tick.dispatch_planning.already_planned_count == 2
      assert snapshot.hub_runtime.poll_tick.dispatch_plan_application.applied_count == 2
      assert snapshot.hub_runtime.poll_tick.worker_start_handoff.skipped_count == 2
      assert snapshot.hub_runtime.candidate_intake.candidate_count == 2
      assert snapshot.hub_runtime.candidate_intake.eligible_count == 0
      assert snapshot.hub_runtime.dispatch_planning.planned_count == 0
      assert snapshot.hub_runtime.dispatch_planning.already_planned_count == 2
      assert snapshot.hub_runtime.dispatch_planning.pending_intent_count == 2
      assert snapshot.hub_runtime.dispatch_plan_application.applied_count == 2
      assert snapshot.hub_runtime.dispatch_plan_application.pending_start_intent_count == 2
      assert snapshot.hub_runtime.worker_start_handoff.skipped_count == 2
      assert snapshot.hub_runtime.worker_start_handoff.unresolved_start_intent_count == 2

      assert snapshot.hub_candidate_intake.counts == %{
               candidate_count: 2,
               valid_candidate_count: 2,
               eligible_count: 0,
               skipped_count: 2,
               invalid_count: 0,
               project_count: 1
             }

      assert snapshot.hub_candidate_intake.skipped_reasons == %{"duplicate_active_attempt" => 2}

      assert [intake_project] = snapshot.hub_candidate_intake.projects
      assert intake_project.project_id == "alpha"
      assert intake_project.provider_scope_key == "memory:alpha"

      assert Enum.map(intake_project.candidates, & &1.issue_key) == [
               "alpha:memory:alpha:mem-1",
               "alpha:memory:alpha:mem-2"
             ]

      assert Enum.all?(intake_project.candidates, &(&1.dispatch_evaluation.eligible == false))
      assert Enum.all?(intake_project.candidates, &(&1.dispatch_evaluation.skipped_reason == "duplicate_active_attempt"))
      assert Enum.all?(intake_project.candidates, &(&1.source_poll.request_id == request.request_id))

      assert snapshot.hub_dispatch_planning.counts.planned_count == 0
      assert snapshot.hub_dispatch_planning.counts.already_planned_count == 2
      assert snapshot.hub_dispatch_planning.counts.pending_intent_count == 2
      assert snapshot.hub_dispatch_planning.skipped_reasons == %{"already_planned" => 2}
      assert length(snapshot.hub_dispatch_planning.pending_intents) == 2

      assert Enum.map(snapshot.hub_dispatch_planning.pending_intents, & &1.issue_key) == [
               "alpha:memory:alpha:mem-1",
               "alpha:memory:alpha:mem-2"
             ]

      assert Enum.all?(snapshot.hub_dispatch_planning.pending_intents, fn intent ->
               intent.source_model == "runtime_ledger" and
                 intent.safety.starts_agent == false and
                 intent.safety.creates_workspace == false and
                 intent.safety.writes_provider == false
             end)

      assert snapshot.hub_dispatch_plan_application.counts.applied_count == 2
      assert snapshot.hub_dispatch_plan_application.counts.pending_start_intent_count == 2
      assert snapshot.hub_dispatch_plan_application.reason_counts == %{}
      assert snapshot.hub_worker_start_handoff.counts.selected_count == 2
      assert snapshot.hub_worker_start_handoff.counts.skipped_count == 2
      assert snapshot.hub_worker_start_handoff.counts.unresolved_start_intent_count == 2
      assert snapshot.hub_worker_start_handoff.reason_counts == %{"cutover_gate_blocked" => 2}

      assert Enum.map(snapshot.hub_dispatch_plan_application.pending_start_intents, & &1.issue_key) == [
               "alpha:memory:alpha:mem-1",
               "alpha:memory:alpha:mem-2"
             ]

      assert Enum.all?(snapshot.hub_dispatch_plan_application.pending_start_intents, fn intent ->
               intent.runtime_identity.source_poll.request_id == request.request_id and
                 intent.runtime_identity.source_intake.candidate_key == intent.issue_key and
                 intent.start_command_summary.starts_agent in [false, "false"] and
                 intent.start_command_summary.creates_workspace in [false, "false"] and
                 intent.start_command_summary.writes_provider in [false, "false"]
             end)

      dispatch_summary = RuntimeLedger.replay(snapshot.hub_dispatch_boundary)
      assert [ledger_project] = dispatch_summary.projects
      assert length(ledger_project.active_attempts) == 2
      assert length(ledger_project.pending_start_intents) == 2
      assert Enum.all?(ledger_project.pending_start_intents, &(&1.status == :pending))

      facts_by_type = Enum.group_by(snapshot.hub_poll_coordination.facts, & &1.fact_type)
      assert [_attempt | _] = Map.fetch!(facts_by_type, :poll_attempt)
      assert [result | _] = Map.fetch!(facts_by_type, :poll_result)
      assert result.status == :success
      assert result.result_summary.issue_count == 2

      [project] = snapshot.hub_poll_coordination.projects
      assert project.allow_poll == false
      assert project.eligibility.reason == :not_due
      assert project.last_poll.status == :success
      assert project.next_due_at != nil

      assert [device_project] = snapshot.hub_device_observability.projects
      assert device_project.poll.allow_poll == false
      assert device_project.poll.last_poll["status"] == "success"
      assert [%{"status" => "success", "result_summary" => %{"issue_count" => 2, "candidates" => _candidates}}] = device_project.provider_queue.recent_results

      payload = Presenter.state_payload(runtime_name, 100)
      assert payload.hub_candidate_intake.counts.candidate_count == 2
      assert payload.hub_dispatch_planning.counts.already_planned_count == 2
      assert payload.hub_dispatch_plan_application.counts.applied_count == 2
      assert payload.hub_worker_start_handoff.counts.skipped_count == 2
      assert [%{candidates: payload_candidates}] = payload.hub_candidate_intake.projects
      assert Enum.all?(payload_candidates, &(&1.dispatch_evaluation.skipped_reason == "duplicate_active_attempt"))
    after
      File.rm_rf(root)
    end
  end

  test "request_refresh applies worker start handoff acknowledgements into runtime ledger and API state" do
    root = tmp_root("hub-runtime-start-handoff-ack")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha",
        tracker_kind: "memory",
        workspace_root: Path.join([root, "workspaces", "alpha"]),
        poll_interval_ms: 60_000
      )

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      parent = self()

      starter = fn request, _opts ->
        send(parent, {:worker_start_handoff_request, request})

        %{
          status: :ack,
          reason: :worker_ack,
          session_id: "session-#{request.start_intent_id}",
          worker_host: "worker-runtime",
          workspace_path: request.workspace_path,
          worker_identity: %{pid: "pid-#{request.start_intent_id}", raw_output: "must not leak"},
          runtime_context: %{
            project_id: request.project_id,
            issue_key: request.issue_key,
            attempt_id: request.attempt_id,
            start_intent_id: request.start_intent_id,
            current_stage: request.current_stage
          }
        }
      end

      runtime_name = Module.concat(__MODULE__, :StartHandoffAckRuntime)

      runtime_opts = [
        name: runtime_name,
        config_path: hub_path,
        provider_executor: success_executor(self()),
        worker_start_starter: starter,
        operator_acknowledgements:
          cutover_acknowledgements!(hub_path,
            provider_executor: success_executor(self()),
            worker_start_starter: starter
          )
      ]

      start_supervised!(
        {Runtime, runtime_opts},
        id: :hub_runtime_start_handoff_ack
      )

      assert %{
               poll_tick: %{
                 dispatch_plan_application: %{applied_count: 2},
                 worker_start_handoff: %{selected_count: 2, acked_count: 2, unresolved_start_intent_count: 0}
               }
             } = Runtime.request_refresh(runtime_name)

      assert_receive {:provider_candidate_scan, %{project_id: "alpha"}}, 1_000
      assert_receive {:worker_start_handoff_request, first_request}, 1_000
      assert_receive {:worker_start_handoff_request, second_request}, 1_000

      assert first_request.project_id == "alpha"
      assert first_request.provider_scope_key == "memory:alpha"
      assert first_request.issue_ref.provider_issue_id in ["mem-1", "mem-2"]
      assert first_request.source_poll.request_id != nil
      assert first_request.workflow_file_path == Path.expand(Path.join(root, "alpha/WORKFLOW.md"))
      assert first_request.tracker_file_path == Path.expand(Path.join(root, "alpha/TRACKER.yaml"))
      assert second_request.issue_ref.provider_issue_id in ["mem-1", "mem-2"]

      snapshot = Runtime.snapshot(runtime_name, 100)
      assert snapshot.hub_worker_start_handoff.counts.acked_count == 2
      assert snapshot.hub_worker_start_handoff.pending_start_intents == []
      assert snapshot.hub_worker_start_handoff.worker_lifecycle.counts.acked_count == 2
      assert length(snapshot.hub_worker_start_handoff.worker_lifecycle.workers) >= 2
      assert Enum.all?(snapshot.hub_worker_start_handoff.worker_lifecycle.workers, &(&1.start_intent_status == "acknowledged"))
      assert snapshot.hub_runtime.worker_start_handoff.acked_count == 2
      assert snapshot.hub_runtime.worker_lifecycle_reconciliation.running_count == 2
      assert snapshot.hub_worker_lifecycle_reconciliation.counts.running_count == 2

      dispatch_summary = RuntimeLedger.replay(snapshot.hub_dispatch_boundary)
      assert [ledger_project] = dispatch_summary.projects
      assert ledger_project.counts.running == 2
      assert ledger_project.pending_start_intents == []
      assert length(ledger_project.active_attempts) == 2
      assert Enum.all?(ledger_project.active_attempts, &(&1.start_intent_status == :acknowledged))

      payload = Presenter.state_payload(runtime_name, 100)
      assert payload.hub_worker_start_handoff.counts.acked_count == 2
      assert payload.hub_worker_start_handoff.counts.unresolved_start_intent_count == 0
      assert payload.hub_worker_start_handoff.worker_lifecycle.counts.acked_count == 2
      assert payload.hub_worker_start_handoff.worker_lifecycle.failure_reason_counts == %{}
      assert payload.hub_worker_lifecycle_reconciliation.counts.running_count == 2
      assert payload.hub_dispatch_boundary.projects |> hd() |> Map.get(:counts) |> Map.get(:running) == 2

      safe_text = inspect(payload.hub_worker_start_handoff)
      refute safe_text =~ "must not leak"
      refute safe_text =~ "raw_output"
    after
      File.rm_rf(root)
    end
  end

  test "request_refresh reconciles acknowledged worker lifecycle results into API state" do
    root = tmp_root("hub-runtime-worker-lifecycle")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha",
        tracker_kind: "memory",
        workspace_root: Path.join([root, "workspaces", "alpha"]),
        poll_interval_ms: 60_000
      )

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      starter = fn request, _opts ->
        %{
          status: :ack,
          reason: :worker_ack,
          session_id: "session-#{request.issue_ref.provider_issue_id}",
          worker_host: "worker-runtime",
          workspace_path: request.workspace_path
        }
      end

      lifecycle_source = fn requests, _opts ->
        Enum.map(requests, fn request ->
          if request.issue_key =~ "mem-1" do
            %{
              status: :succeeded,
              recovery_status: :released,
              reason: :stage_completed,
              project_id: request.project_id,
              issue_key: request.issue_key,
              attempt_id: request.attempt_id,
              start_intent_id: request.start_intent_id,
              workspace_lease_id: request.workspace_lease_id,
              workspace_path: request.workspace_path,
              session_id: "session-mem-1",
              worker_host: "worker-runtime",
              finished_at: "2026-06-29T10:30:00Z",
              token: "ghp_should_not_leak",
              authorization: "Bearer secret",
              raw_config: %{api_key: "sk-secret"},
              full_prompt: "full prompt should not leak",
              transcript: "complete transcript should not leak",
              comment_body: "complete comment body should not leak"
            }
          else
            %{
              status: :lost,
              reason: :heartbeat_lost,
              project_id: request.project_id,
              issue_key: request.issue_key,
              attempt_id: request.attempt_id,
              start_intent_id: request.start_intent_id,
              workspace_lease_id: request.workspace_lease_id,
              workspace_path: request.workspace_path,
              session_id: "session-mem-2",
              worker_host: "worker-runtime",
              last_activity_at: "2026-06-29T10:20:00Z",
              workspace_retained_reason: :heartbeat_lost
            }
          end
        end)
      end

      runtime_name = Module.concat(__MODULE__, :WorkerLifecycleRuntime)

      runtime_opts = [
        name: runtime_name,
        config_path: hub_path,
        provider_executor: success_executor(self()),
        worker_start_starter: starter,
        operator_acknowledgements:
          cutover_acknowledgements!(hub_path,
            provider_executor: success_executor(self()),
            worker_start_starter: starter
          ),
        worker_lifecycle_result_source: lifecycle_source
      ]

      start_supervised!(
        {Runtime, runtime_opts},
        id: :hub_runtime_worker_lifecycle
      )

      assert %{
               poll_tick: %{
                 worker_start_handoff: %{acked_count: 2},
                 worker_lifecycle_reconciliation: %{
                   selected_count: 2,
                   applied_count: 2,
                   succeeded_count: 1,
                   lost_count: 1,
                   retained_workspace_count: 1,
                   released_workspace_count: 1
                 }
               }
             } = Runtime.request_refresh(runtime_name)

      assert_receive {:provider_candidate_scan, %{project_id: "alpha"}}, 1_000

      snapshot = Runtime.snapshot(runtime_name, 100)
      assert snapshot.hub_runtime.worker_lifecycle_reconciliation.succeeded_count == 1
      assert snapshot.hub_runtime.worker_lifecycle_reconciliation.lost_count == 1
      assert snapshot.hub_worker_lifecycle_reconciliation.reason_counts == %{"heartbeat_lost" => 1, "stage_completed" => 1}

      dispatch_summary = RuntimeLedger.replay(snapshot.hub_dispatch_boundary)
      [ledger_project] = dispatch_summary.projects
      assert ledger_project.counts.released == 1
      assert ledger_project.counts.manual_attention == 1
      assert length(ledger_project.active_attempts) == 1
      assert length(ledger_project.workspace_leases) == 1
      assert ledger_project.lifecycle.counts.succeeded == 1
      assert ledger_project.lifecycle.counts.lost == 1
      assert ledger_project.lifecycle.workspace_action_counts == %{"released" => 1, "retained" => 1}

      payload = Presenter.state_payload(runtime_name, 100)
      assert payload.hub_worker_lifecycle_reconciliation.counts.succeeded_count == 1
      assert payload.hub_worker_lifecycle_reconciliation.counts.lost_count == 1
      assert payload.hub_dispatch_boundary.projects |> hd() |> Map.get(:lifecycle) |> get_in([:counts, :lost]) == 1

      [device_project] = payload.hub_device_observability.projects
      assert device_project.runtime.lifecycle.counts.lost == 1
      assert "worker_lifecycle_lost" in reason_names(device_project)
      assert "workspace_retained" in reason_names(device_project)

      safe_text = inspect(payload)
      refute safe_text =~ "ghp_should_not_leak"
      refute safe_text =~ "Bearer secret"
      refute safe_text =~ "sk-secret"
      refute safe_text =~ "full prompt"
      refute safe_text =~ "complete transcript"
      refute safe_text =~ "complete comment body"
      refute safe_text =~ "Authorization:"
      refute safe_text =~ "raw_config"
    after
      File.rm_rf(root)
    end
  end

  test "rate limited poll result backs off only the matching project scope" do
    root = tmp_root("hub-runtime-poll-tick-backoff")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "alpha"]))
      write_project!(root, "beta", tracker_kind: "gitlab", tracker_project_slug: "platform/beta", workspace_root: Path.join([root, "workspaces", "beta"]))

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
        - project_id: beta
          workflow_path: beta/WORKFLOW.md
          migration_state: hub_managed
      """)

      runtime_name = Module.concat(__MODULE__, :PollTickBackoffRuntime)

      start_supervised!(
        {Runtime,
         name: runtime_name,
         config_path: hub_path,
         provider_executor: backoff_executor(self()),
         operator_acknowledgements: cutover_acknowledgements!(hub_path, provider_executor: backoff_executor(self()))},
        id: :hub_runtime_poll_tick_backoff
      )

      assert %{poll_tick: %{selected_count: 2, result_counts: %{"rate_limited" => 1, "success" => 1}}} =
               Runtime.request_refresh(runtime_name)

      assert_receive {:rate_limited_request, "alpha"}, 1_000
      assert_receive {:successful_request, "beta"}, 1_000

      snapshot = Runtime.snapshot(runtime_name, 100)
      projects = Map.new(snapshot.hub_poll_coordination.projects, &{&1.project_id, &1})

      assert projects["alpha"].allow_poll == false
      assert projects["alpha"].eligibility.reason == :rate_limited
      assert projects["alpha"].backoff_until != nil
      assert projects["alpha"].last_poll.status == :rate_limited

      assert projects["beta"].allow_poll == false
      assert projects["beta"].eligibility.reason == :not_due
      assert projects["beta"].last_poll.status == :success

      device_projects = Map.new(snapshot.hub_device_observability.projects, &{&1.project_id, &1})
      assert device_projects["alpha"].status == "backoff"
      assert "provider_rate_limit" in reason_names(device_projects["alpha"])
      refute "provider_rate_limit" in reason_names(device_projects["beta"])
    after
      File.rm_rf(root)
    end
  end

  test "project configuration errors are not executed and do not block other due projects" do
    root = tmp_root("hub-runtime-poll-tick-config-error")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "good", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "good"]))

      bad_dir = Path.join(root, "bad")
      File.mkdir_p!(bad_dir)

      write_workflow_file!(Path.join(bad_dir, "WORKFLOW.md"),
        tracker_kind: "github",
        tracker_api_token: "$GITHUB_TOKEN",
        tracker_owner: "JhihJian",
        tracker_repo: nil,
        workspace_root: Path.join([root, "workspaces", "bad"])
      )

      File.write!(hub_path, """
      projects:
        - project_id: good
          workflow_path: good/WORKFLOW.md
          migration_state: hub_managed
        - project_id: bad
          workflow_path: bad/WORKFLOW.md
      """)

      runtime_name = Module.concat(__MODULE__, :PollTickConfigErrorRuntime)

      start_supervised!(
        {Runtime,
         name: runtime_name,
         config_path: hub_path,
         provider_executor: success_executor(self()),
         operator_acknowledgements: cutover_acknowledgements!(hub_path, provider_executor: success_executor(self()))},
        id: :hub_runtime_poll_tick_config_error
      )

      assert %{poll_tick: %{selected_count: 1}} = Runtime.request_refresh(runtime_name)
      assert_receive {:provider_candidate_scan, %{project_id: "good"}}, 1_000
      refute_receive {:provider_candidate_scan, %{project_id: "bad"}}, 100

      snapshot = Runtime.snapshot(runtime_name, 100)
      projects = Map.new(snapshot.hub_poll_coordination.projects, &{&1.project_id, &1})

      assert projects["good"].last_poll.status == :success
      assert projects["bad"].allow_poll == false
      assert projects["bad"].eligibility.reason == :config_error
      assert snapshot.hub_runtime.counts.config_error_count == 1
    after
      File.rm_rf(root)
    end
  end

  test "poll tick snapshot and API payload keep provider executor secrets out" do
    root = tmp_root("hub-runtime-poll-tick-redaction")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "alpha"]))

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      runtime_name = Module.concat(__MODULE__, :PollTickRedactionRuntime)
      provider_executor = secret_executor()
      operator_acknowledgements = cutover_acknowledgements!(hub_path, provider_executor: provider_executor)

      runtime_opts = [
        name: runtime_name,
        config_path: hub_path,
        provider_executor: provider_executor,
        operator_acknowledgements: operator_acknowledgements
      ]

      start_supervised!(
        {Runtime, runtime_opts},
        id: :hub_runtime_poll_tick_redaction
      )

      Runtime.request_refresh(runtime_name)

      payload = Presenter.state_payload(runtime_name, 100)
      safe_text = inspect(payload)

      refute safe_text =~ "ghp_supersecret"
      refute safe_text =~ "Bearer supersecret"
      refute safe_text =~ "Bearer nested"
      refute safe_text =~ "session=secret"
      refute safe_text =~ "full prompt"
      refute safe_text =~ "transcript"
      refute safe_text =~ "raw provider body"
      refute safe_text =~ "complete comment body"
      refute safe_text =~ "Authorization:"
      refute safe_text =~ "cookie"
      refute safe_text =~ "ghp_"
    after
      File.rm_rf(root)
    end
  end

  test "poll tick snapshot and API payload redact body-only provider summaries" do
    root = tmp_root("hub-runtime-body-only-redaction")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "alpha"]))

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      runtime_name = Module.concat(__MODULE__, :PollTickBodyOnlyRedactionRuntime)
      provider_executor = body_only_executor()
      operator_acknowledgements = cutover_acknowledgements!(hub_path, provider_executor: provider_executor)

      runtime_opts = [
        name: runtime_name,
        config_path: hub_path,
        provider_executor: provider_executor,
        operator_acknowledgements: operator_acknowledgements
      ]

      start_supervised!(
        {Runtime, runtime_opts},
        id: :hub_runtime_poll_tick_body_only_redaction
      )

      Runtime.request_refresh(runtime_name)

      snapshot = Runtime.snapshot(runtime_name, 100)
      payload = Presenter.state_payload(runtime_name, 100)

      safe_text =
        inspect({
          snapshot.hub_poll_coordination,
          snapshot.hub_device_observability,
          snapshot.hub_candidate_intake,
          snapshot.hub_dispatch_planning,
          payload
        })

      refute safe_text =~ "plain issue body should not leak"
      refute safe_text =~ "plain comment body should not leak"
      refute safe_text =~ "plain pull request body should not leak"
      refute safe_text =~ "plain pr body should not leak"
      refute safe_text =~ "plain raw provider body should not leak"
      refute safe_text =~ "plain full prompt body should not leak"
      refute safe_text =~ "nested atom-key candidate body should not leak"
      refute safe_text =~ "nested string-key candidate body should not leak"

      assert [result | _] = Enum.filter(snapshot.hub_poll_coordination.facts, &(&1.fact_type == :poll_result))
      assert is_binary(result.result_summary.comment_body_sha256)
      assert is_integer(result.result_summary.pull_request_body_bytes)
    after
      File.rm_rf(root)
    end
  end

  test "default provider executor returns a safe skeleton candidate scan result" do
    request =
      provider_request!(
        project_id: "alpha",
        provider_scope: %{kind: "memory", key: "memory:alpha", scope: %{namespace: "alpha"}},
        operation_kind: :candidate_scan,
        logical_key: "hub-poll:alpha:candidate_scan"
      )

    result = ProviderExecutor.execute(request)

    assert result.status == :success
    assert result.request_id == request.request_id
    assert result.operation_kind == :candidate_scan

    assert result.result_summary == %{
             boundary: "hub_provider_executor",
             executor: "default_skeleton",
             provider_io: false,
             candidate_scan: "accepted"
           }
  end

  test "real candidate scan runtime uses project-local tracker I/O without one-shot authorization" do
    root = tmp_root("hub-runtime-real-candidate-scan")
    hub_path = Path.join(root, "HUB.yaml")
    legacy_issue = %Issue{id: "legacy", identifier: "LEGACY", title: "Legacy", state: "Todo"}
    alpha_issue = %Issue{id: "alpha-1", identifier: "ALPHA-1", title: "Alpha issue", description: "full alpha issue body should not leak", state: "Todo"}
    beta_issue = %Issue{id: "beta-1", identifier: "BETA-1", title: "Beta issue", state: "Todo"}

    try do
      write_project!(root, "alpha",
        tracker_kind: "memory",
        tracker_project_slug: "legacy-global-project",
        workspace_root: Path.join([root, "workspaces", "alpha"])
      )

      write_project!(root, "beta",
        tracker_kind: "memory",
        tracker_project_slug: "legacy-global-project",
        workspace_root: Path.join([root, "workspaces", "beta"])
      )

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
        - project_id: beta
          workflow_path: beta/WORKFLOW.md
          migration_state: hub_managed
      """)

      Workflow.set_workflow_file_path(Path.join(root, "legacy/WORKFLOW.md"))
      File.mkdir_p!(Path.join(root, "legacy"))

      write_workflow_file!(Path.join(root, "legacy/WORKFLOW.md"),
        tracker_kind: "memory",
        workspace_root: Path.join([root, "workspaces", "legacy"])
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [legacy_issue])

      Application.put_env(:symphony_elixir, :memory_tracker_issues_by_project, %{
        "alpha" => [alpha_issue],
        "beta" => [beta_issue]
      })

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      runtime_name = Module.concat(__MODULE__, :RealCandidateScanRuntime)

      start_supervised!(
        {Runtime,
         name: runtime_name,
         config_path: hub_path,
         provider_executor: RealCandidateScanExecutor,
         operator_acknowledgements: cutover_acknowledgements!(hub_path, provider_executor: RealCandidateScanExecutor)},
        id: :hub_runtime_real_candidate_scan
      )

      assert %{poll_tick: %{selected_count: 2, result_counts: %{"success" => 2}}} =
               Runtime.request_refresh(runtime_name)

      assert_receive {:memory_tracker_fetch_candidate_issues, "alpha"}, 100
      assert_receive {:memory_tracker_fetch_candidate_issues, "beta"}, 100

      snapshot = Runtime.snapshot(runtime_name, 100)
      assert snapshot.hub_runtime.provider_executor.mode == "real_candidate_scan"
      assert snapshot.hub_runtime.provider_executor.provider_io == true
      assert snapshot.hub_runtime.poll_tick.candidate_intake.candidate_count == 2
      assert snapshot.hub_candidate_intake.counts.candidate_count == 2
      assert snapshot.hub_cutover_authorization_consumption_guard.status == "no_consumption"
      assert snapshot.hub_cutover_authorization_consumption_guard.counts.no_authorization_count == 0

      results =
        snapshot.hub_poll_coordination.facts
        |> Enum.filter(&(&1.fact_type == :poll_result))
        |> Map.new(&{&1.project_id, &1})

      assert results["alpha"].result_summary.executor == "real_candidate_scan"
      assert results["alpha"].result_summary.provider_io in [true, "true"]
      refute Map.has_key?(results["alpha"].result_summary, :authorization_consumption)

      payload = Presenter.state_payload(runtime_name, 100)
      safe_text = inspect(payload)
      refute safe_text =~ "LEGACY"
      refute safe_text =~ "full alpha issue body should not leak"
      refute safe_text =~ "description"
      refute safe_text =~ "GITHUB_TOKEN"
      refute safe_text =~ "ghp_"
      refute safe_text =~ "Authorization:"
      refute safe_text =~ "cookie"
      refute safe_text =~ "raw_config"
    after
      File.rm_rf(root)
    end
  end

  test "real candidate scan runtime allows provider I/O when execution authorization is not configured" do
    root = tmp_root("hub-runtime-real-candidate-no-execution-authorization")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha",
        tracker_kind: "memory",
        tracker_project_slug: "alpha",
        workspace_root: Path.join([root, "workspaces", "alpha"])
      )

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      Application.put_env(:symphony_elixir, :memory_tracker_issues_by_project, %{
        "alpha" => [%Issue{id: "alpha-1", identifier: "ALPHA-1", title: "Alpha issue", state: "Todo"}]
      })

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      runtime_name = Module.concat(__MODULE__, :RealCandidateNoAuthorizationRuntime)

      start_supervised!(
        {Runtime,
         name: runtime_name,
         config_path: hub_path,
         provider_executor: RealCandidateScanExecutor,
         operator_acknowledgements: cutover_acknowledgements!(hub_path, provider_executor: RealCandidateScanExecutor)},
        id: :hub_runtime_real_candidate_no_authorization
      )

      assert %{poll_tick: %{selected_count: 1, result_counts: %{"success" => 1}}} =
               Runtime.request_refresh(runtime_name)

      assert_receive {:memory_tracker_fetch_candidate_issues, "alpha"}, 100

      snapshot = Runtime.snapshot(runtime_name, 100)
      assert snapshot.hub_candidate_intake.counts.candidate_count == 1
      assert snapshot.hub_cutover_authorization_consumption_guard.status == "no_consumption"
      assert snapshot.hub_cutover_authorization_consumption_guard.counts.no_authorization_count == 0
      assert snapshot.hub_cutover_authorization_consumption_guard.blocked_sources == []
    after
      File.rm_rf(root)
    end
  end

  test "real candidate scan runtime consumes explicit authorization guard before provider I/O" do
    root = tmp_root("hub-runtime-real-candidate-authorization-guard")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha",
        tracker_kind: "memory",
        tracker_project_slug: "alpha",
        workspace_root: Path.join([root, "workspaces", "alpha"])
      )

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      Application.put_env(:symphony_elixir, :memory_tracker_issues_by_project, %{
        "alpha" => [%{id: "alpha-1", identifier: "ALPHA-1", title: "Alpha issue"}]
      })

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      runtime_name = Module.concat(__MODULE__, :RealCandidateAuthorizationGuardRuntime)

      start_supervised!(
        {Runtime,
         name: runtime_name,
         config_path: hub_path,
         provider_executor: RealCandidateScanExecutor,
         operator_acknowledgements: cutover_acknowledgements!(hub_path, provider_executor: RealCandidateScanExecutor),
         cutover_execution_authorization_requests: [
           %{
             authorization_request_id: "auth-alpha-writeback",
             authorization_request_fingerprint: "auth-fingerprint-alpha-writeback",
             project_id: "alpha",
             provider_scope: %{kind: "memory", provider_scope_key: "memory:alpha", scope: %{namespace: "alpha"}},
             operation: "writeback",
             source: "operator-file",
             requested_at: "2026-06-30T09:02:00Z",
             operator_intent: %{action_codes: ["authorize_explicit_execution"]}
           }
         ]},
        id: :hub_runtime_real_candidate_authorization_guard
      )

      assert %{poll_tick: %{selected_count: 1, result_counts: %{"permanent_failure" => 1}}} =
               Runtime.request_refresh(runtime_name)

      refute_receive {:memory_tracker_fetch_candidate_issues, "alpha"}, 100

      snapshot = Runtime.snapshot(runtime_name, 100)
      assert snapshot.hub_candidate_intake.counts.candidate_count == 0
      assert snapshot.hub_cutover_authorization_consumption_guard.status == "no_authorization"
      assert snapshot.hub_cutover_authorization_consumption_guard.counts.no_authorization_count == 1

      [blocked] = snapshot.hub_cutover_authorization_consumption_guard.blocked_sources
      assert blocked.project_id == "alpha"
      assert blocked.side_effect_source == "candidate_scan"
      assert blocked.reason_code == "authorization_record_operation_missing"
    after
      File.rm_rf(root)
    end
  end

  test "real candidate scan runtime classifies provider failure paths without one-shot authorization" do
    root = tmp_root("hub-runtime-real-candidate-failures")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "limited", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "limited"]))
      write_project!(root, "retry", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "retry"]))
      write_project!(root, "bad", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "bad"]))

      File.write!(hub_path, """
      projects:
        - project_id: limited
          workflow_path: limited/WORKFLOW.md
          migration_state: hub_managed
        - project_id: retry
          workflow_path: retry/WORKFLOW.md
          migration_state: hub_managed
        - project_id: bad
          workflow_path: bad/WORKFLOW.md
          migration_state: hub_managed
      """)

      Application.put_env(:symphony_elixir, :memory_tracker_issues_by_project, %{
        "limited" => {:error, {:memory_rate_limited, 60_000}},
        "retry" => {:error, {:github_api_status, 503}},
        "bad" => {:error, :missing_github_api_token}
      })

      runtime_name = Module.concat(__MODULE__, :RealCandidateFailureRuntime)

      start_supervised!(
        {Runtime,
         name: runtime_name,
         config_path: hub_path,
         provider_executor: RealCandidateScanExecutor,
         operator_acknowledgements: cutover_acknowledgements!(hub_path, provider_executor: RealCandidateScanExecutor)},
        id: :hub_runtime_real_candidate_failures
      )

      assert %{
               poll_tick: %{
                 selected_count: 3,
                 result_counts: %{
                   "permanent_failure" => 1,
                   "rate_limited" => 1,
                   "retryable_failure" => 1
                 }
               }
             } =
               Runtime.request_refresh(runtime_name)

      snapshot = Runtime.snapshot(runtime_name, 100)
      projects = Map.new(snapshot.hub_poll_coordination.projects, &{&1.project_id, &1})

      assert projects["limited"].last_poll.status == :rate_limited
      assert projects["limited"].last_poll.error_class == :rate_limited
      assert projects["retry"].last_poll.status == :retryable_failure
      assert projects["retry"].last_poll.error_class == :provider_5xx
      assert projects["bad"].last_poll.status == :permanent_failure

      device_projects = Map.new(snapshot.hub_device_observability.projects, &{&1.project_id, &1})
      assert "provider_rate_limit" in reason_names(device_projects["limited"])
      assert "provider_backoff" in reason_names(device_projects["retry"])
      assert snapshot.hub_cutover_authorization_consumption_guard.status == "no_consumption"
      assert snapshot.hub_cutover_authorization_consumption_guard.counts.no_authorization_count == 0

      unsupported =
        provider_request!(
          project_id: "limited",
          provider_scope: %{kind: "memory", key: "memory:limited", scope: %{namespace: "limited"}},
          operation_kind: :stage_writeback,
          logical_key: "hub-poll:limited:stage_writeback"
        )

      unsupported_result =
        RealCandidateScanExecutor.execute(unsupported,
          registry: Runtime.snapshot(runtime_name, 100).hub_project_registry
        )

      assert unsupported_result.status == :permanent_failure
      assert unsupported_result.error_class == :validation
      assert unsupported_result.result_summary.error == "unsupported_operation"

      safe_text = inspect(Presenter.state_payload(runtime_name, 100))
      refute safe_text =~ "github_api_status"
      refute safe_text =~ "GITHUB_TOKEN"
      refute safe_text =~ "Authorization:"
      refute safe_text =~ "cookie"
      refute safe_text =~ "raw_provider"
    after
      File.rm_rf(root)
    end
  end

  test "activation preflight blocks only conflicting hub-managed project before provider scan" do
    root = tmp_root("hub-runtime-activation-preflight")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "alpha"]))
      write_project!(root, "beta", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "beta"]))

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
        - project_id: beta
          workflow_path: beta/WORKFLOW.md
          migration_state: hub_managed
      """)

      runtime_name = Module.concat(__MODULE__, :ActivationPreflightRuntime)

      activation_probe = %{
        source: "unit-test-probe",
        projects: %{
          "alpha" => %{
            legacy_service: %{service: "symphony@alpha.service", active: true},
            provider_scope_owners: [%{provider_scope_key: "memory:alpha", owner: "legacy-poll", authorization: "Bearer secret"}],
            workspace_owners: [%{workspace_root: Path.join([root, "workspaces", "alpha"]), owner: "legacy-worker"}]
          },
          "beta" => %{legacy_service: %{service: "symphony@beta.service", active: false, enabled: false}}
        }
      }

      start_supervised!(
        {Runtime,
         name: runtime_name,
         config_path: hub_path,
         provider_executor: success_executor(self()),
         activation_probe: activation_probe,
         operator_acknowledgements:
           cutover_acknowledgements!(hub_path,
             provider_executor: success_executor(self()),
             activation_probe: activation_probe
           )},
        id: :hub_runtime_activation_preflight
      )

      assert %{poll_tick: %{selected_count: 1, result_counts: %{"success" => 1}}} =
               Runtime.request_refresh(runtime_name)

      assert_receive {:provider_candidate_scan, %{project_id: "beta"}}, 1_000
      refute_receive {:provider_candidate_scan, %{project_id: "alpha"}}, 100

      snapshot = Runtime.snapshot(runtime_name, 100)
      preflight_projects = Map.new(snapshot.hub_activation_preflight.projects, &{&1.project_id, &1})
      assert preflight_projects["alpha"].status == "blocked_conflict"
      assert preflight_projects["alpha"].blocked_operations == ["poll", "dispatch", "worker_start", "writeback"]
      assert preflight_projects["beta"].status == "safe_to_manage"

      poll_projects = Map.new(snapshot.hub_poll_coordination.projects, &{&1.project_id, &1})
      assert poll_projects["alpha"].allow_poll == false
      assert poll_projects["alpha"].eligibility.reason == :activation_preflight_blocked
      assert poll_projects["beta"].last_poll.status == :success

      device_projects = Map.new(snapshot.hub_device_observability.projects, &{&1.project_id, &1})
      assert device_projects["alpha"].status == "blocked"
      assert device_projects["alpha"].activation_preflight.status == "blocked_conflict"
      assert "activation_preflight_blocked" in reason_names(device_projects["alpha"])
      refute "activation_preflight_blocked" in reason_names(device_projects["beta"])

      payload = Presenter.state_payload(runtime_name, 100)
      payload_projects = Map.new(payload.hub_activation_preflight.projects, &{&1.project_id, &1})
      assert payload_projects["alpha"].status == "blocked_conflict"
      assert payload_projects["beta"].status == "safe_to_manage"

      safe_text =
        inspect({
          payload.hub_activation_preflight,
          payload.hub_device_observability.projects |> Enum.find(&(&1.project_id == "alpha")) |> Map.get(:activation_preflight)
        })

      refute safe_text =~ "Bearer secret"
      refute safe_text =~ Path.join([root, "workspaces", "alpha"])
    after
      File.rm_rf(root)
    end
  end

  test "activation preflight blocks dispatch application and real worker start for unresolved intents" do
    root = tmp_root("hub-runtime-activation-handoff")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha",
        tracker_kind: "memory",
        workspace_root: Path.join([root, "workspaces", "alpha"]),
        poll_interval_ms: 60_000
      )

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      parent = self()

      starter = fn request, _opts ->
        send(parent, {:unexpected_worker_start, request})

        %{
          status: :ack,
          reason: :worker_ack,
          session_id: "session-#{request.start_intent_id}",
          worker_host: "worker-runtime",
          workspace_path: request.workspace_path
        }
      end

      runtime_name = Module.concat(__MODULE__, :ActivationPreflightHandoffRuntime)

      start_supervised!(
        {Runtime,
         name: runtime_name,
         config_path: hub_path,
         provider_executor: success_executor(self()),
         worker_start_starter: starter,
         activation_probe: %{
           source: "unit-test-probe",
           projects: %{
             "alpha" => %{legacy_service: %{service: "symphony@alpha.service", active: true}}
           }
         }},
        id: :hub_runtime_activation_preflight_handoff
      )

      assert %{poll_tick: %{selected_count: 0}} = Runtime.request_refresh(runtime_name)
      refute_receive {:provider_candidate_scan, %{project_id: "alpha"}}, 100
      refute_receive {:unexpected_worker_start, _request}, 100

      snapshot = Runtime.snapshot(runtime_name, 100)
      assert snapshot.hub_candidate_intake.counts.candidate_count == 0
      assert snapshot.hub_dispatch_plan_application.counts.applied_count == 0
      assert snapshot.hub_worker_start_handoff.counts.selected_count == 0
      assert snapshot.hub_poll_coordination.projects |> hd() |> Map.get(:eligibility) |> Map.get(:reason) == :activation_preflight_blocked
    after
      File.rm_rf(root)
    end
  end

  test "host service activation probe opt-in feeds runtime preflight and API safe summary" do
    root = tmp_root("hub-runtime-host-service-probe")
    hub_path = Path.join(root, "HUB.yaml")
    legacy_config_root = Path.join(root, "legacy-config")

    try do
      alpha_workspace = Path.join([root, "workspaces", "alpha"])
      beta_workspace = Path.join([root, "workspaces", "beta"])

      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: alpha_workspace, server_port: 20_001)
      write_project!(root, "beta", tracker_kind: "memory", workspace_root: beta_workspace, server_port: 20_002)

      write_legacy_project!(legacy_config_root, "alpha",
        tracker_kind: "memory",
        workspace_root: alpha_workspace,
        server_port: 20_001
      )

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
        - project_id: beta
          workflow_path: beta/WORKFLOW.md
          migration_state: hub_managed
      """)

      runtime_name = Module.concat(__MODULE__, :HostServiceProbeRuntime)

      activation_probe =
        HostServiceProbe.build_fun(
          config_root: legacy_config_root,
          runtime_root: Path.join(root, "runtime"),
          deps: %{
            file_regular?: &File.regular?/1,
            file_dir?: &File.dir?/1,
            read_file: &File.read/1,
            systemctl_show: fn
              "symphony@alpha.service" -> {:ok, "ActiveState=active\nSubState=running\nResult=success\n"}
              "symphony@beta.service" -> {:ok, "ActiveState=inactive\nSubState=dead\nResult=success\n"}
            end,
            systemctl_enabled: fn _service -> {:ok, "disabled"} end,
            listening_ports: fn -> {:ok, [20_001]} end
          }
        )
        |> then(fn probe_fun ->
          {:ok, registry} = ProjectRegistry.load(hub_path)
          probe_fun.(registry)
        end)

      start_supervised!(
        {Runtime,
         name: runtime_name,
         config_path: hub_path,
         provider_executor: success_executor(self()),
         activation_probe: activation_probe,
         operator_acknowledgements:
           cutover_acknowledgements!(hub_path,
             provider_executor: success_executor(self()),
             activation_probe: activation_probe
           )},
        id: :hub_runtime_host_service_probe
      )

      assert %{poll_tick: %{selected_count: 1, result_counts: %{"success" => 1}}} =
               Runtime.request_refresh(runtime_name)

      assert_receive {:provider_candidate_scan, %{project_id: "beta"}}, 1_000
      refute_receive {:provider_candidate_scan, %{project_id: "alpha"}}, 100

      snapshot = Runtime.snapshot(runtime_name, 100)
      projects = Map.new(snapshot.hub_activation_preflight.projects, &{&1.project_id, &1})
      assert projects["alpha"].status == "blocked_conflict"
      assert projects["alpha"].probe_source == "host_service_probe"
      assert projects["alpha"].blocked_operations == ["poll", "dispatch", "worker_start", "writeback"]
      assert projects["beta"].status == "safe_to_manage"

      payload = Presenter.state_payload(runtime_name, 100)
      payload_projects = Map.new(payload.hub_activation_preflight.projects, &{&1.project_id, &1})
      assert payload_projects["alpha"].status == "blocked_conflict"
      assert payload_projects["beta"].status == "safe_to_manage"

      safe_text = inspect({snapshot.hub_activation_preflight, payload.hub_activation_preflight})
      refute safe_text =~ alpha_workspace
      refute safe_text =~ legacy_config_root
      refute safe_text =~ "SECRET_TOKEN"
      refute safe_text =~ "should-not-leak"
      refute safe_text =~ "ActiveState="
    after
      File.rm_rf(root)
    end
  end

  test "candidate intake marks active attempt and workspace conflicts while applying only safe candidates" do
    root = tmp_root("hub-runtime-candidate-intake-conflicts")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha",
        tracker_kind: "memory",
        workspace_root: Path.join([root, "workspaces", "alpha"]),
        max_concurrent_agents: 10
      )

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      runtime_name = Module.concat(__MODULE__, :CandidateIntakeConflictRuntime)

      start_supervised!(
        {Runtime,
         name: runtime_name,
         config_path: hub_path,
         provider_executor: conflict_executor(self(), Path.join([root, "workspaces", "alpha"])),
         runtime_ledger: active_runtime_ledger(Path.join([root, "workspaces", "alpha"])),
         operator_acknowledgements:
           cutover_acknowledgements!(hub_path,
             provider_executor: conflict_executor(self(), Path.join([root, "workspaces", "alpha"]))
           )},
        id: :hub_runtime_candidate_intake_conflicts
      )

      assert %{
               poll_tick: %{
                 selected_count: 1,
                 candidate_intake: %{candidate_count: 3, eligible_count: 0, skipped_count: 3},
                 dispatch_plan_application: %{applied_count: 1, blocked_count: 2}
               }
             } = Runtime.request_refresh(runtime_name)

      assert_receive {:provider_candidate_scan_conflicts, %{project_id: "alpha"}}, 1_000

      snapshot = Runtime.snapshot(runtime_name, 100)
      assert snapshot.hub_candidate_intake.counts.candidate_count == 3
      assert snapshot.hub_candidate_intake.counts.eligible_count == 0
      assert snapshot.hub_candidate_intake.skipped_reasons == %{"duplicate_active_attempt" => 2, "workspace_busy" => 1}
      assert snapshot.hub_dispatch_planning.counts.planned_count == 0
      assert snapshot.hub_dispatch_planning.counts.already_planned_count == 1
      assert snapshot.hub_dispatch_planning.counts.skipped_count == 3

      assert snapshot.hub_dispatch_planning.skipped_reasons == %{
               "already_planned" => 1,
               "duplicate_active_attempt" => 1,
               "workspace_busy" => 1
             }

      assert snapshot.hub_dispatch_plan_application.counts.applied_count == 1
      assert snapshot.hub_dispatch_plan_application.counts.blocked_count == 2

      assert snapshot.hub_dispatch_plan_application.reason_counts == %{
               "duplicate_active_attempt" => 1,
               "workspace_busy" => 1
             }

      [project] = snapshot.hub_candidate_intake.projects

      reasons_by_issue =
        project.candidates
        |> Map.new(&{&1.issue_ref.provider_issue_id, &1.dispatch_evaluation.skipped_reason})

      assert reasons_by_issue["mem-active"] == "duplicate_active_attempt"
      assert reasons_by_issue["mem-workspace"] == "workspace_busy"
      assert reasons_by_issue["mem-ready"] == "duplicate_active_attempt"
      refute Enum.any?(project.candidates, &(&1.dispatch_evaluation.status == "ready_for_dispatch_evaluation"))

      dispatch_summary = RuntimeLedger.replay(snapshot.hub_dispatch_boundary)
      [ledger_project] = dispatch_summary.projects
      assert length(ledger_project.active_attempts) == 3
      assert Enum.any?(ledger_project.active_attempts, &(&1.issue_key =~ "mem-ready"))
      assert [%{issue_key: ready_key, status: :pending}] = ledger_project.pending_start_intents
      assert ready_key =~ "mem-ready"

      [planning_project] = snapshot.hub_dispatch_planning.projects
      statuses_by_issue = Map.new(planning_project.outcomes, &{&1.issue_ref.provider_issue_id, &1.status})
      assert statuses_by_issue["mem-active"] == "blocked_by_active_attempt"
      assert statuses_by_issue["mem-workspace"] == "blocked_by_workspace"
      assert statuses_by_issue["mem-ready"] == "already_planned"
    after
      File.rm_rf(root)
    end
  end

  test "dispatch planning recovers previous pending intents instead of duplicating them" do
    root = tmp_root("hub-runtime-dispatch-planning-replay")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha",
        tracker_kind: "memory",
        workspace_root: Path.join([root, "workspaces", "alpha"]),
        max_concurrent_agents: 2,
        poll_interval_ms: 1
      )

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      runtime_name = Module.concat(__MODULE__, :DispatchPlanningReplayRuntime)

      start_supervised!(
        {Runtime,
         name: runtime_name,
         config_path: hub_path,
         provider_executor: success_executor(self()),
         operator_acknowledgements: cutover_acknowledgements!(hub_path, provider_executor: success_executor(self()))},
        id: :hub_runtime_dispatch_planning_replay
      )

      assert %{
               poll_tick: %{
                 dispatch_planning: %{planned_count: 0, already_planned_count: 2},
                 dispatch_plan_application: %{applied_count: 2}
               }
             } = Runtime.request_refresh(runtime_name)

      assert_receive {:provider_candidate_scan, %{project_id: "alpha"}}, 1_000

      first = Runtime.snapshot(runtime_name, 100).hub_dispatch_planning
      assert first.counts.pending_intent_count == 2
      first_application = Runtime.snapshot(runtime_name, 100).hub_dispatch_plan_application
      assert first_application.counts.applied_count == 2

      Process.sleep(5)

      assert %{
               poll_tick: %{
                 dispatch_planning: %{planned_count: 0, already_planned_count: 2},
                 dispatch_plan_application: %{already_applied_count: 2},
                 worker_start_handoff: %{skipped_count: 2}
               }
             } = Runtime.request_refresh(runtime_name)

      assert_receive {:provider_candidate_scan, %{project_id: "alpha"}}, 1_000

      second = Runtime.snapshot(runtime_name, 100).hub_dispatch_planning
      assert second.counts.pending_intent_count == 2
      assert second.counts.already_planned_count == 2
      assert Enum.map(second.pending_intents, & &1.intent_id) == Enum.map(first.pending_intents, & &1.intent_id)

      dispatch_summary = Runtime.snapshot(runtime_name, 100).hub_dispatch_boundary |> RuntimeLedger.replay()
      assert [ledger_project] = dispatch_summary.projects
      assert length(ledger_project.active_attempts) == 2
      assert length(ledger_project.pending_start_intents) == 2
      assert Enum.all?(ledger_project.pending_start_intents, &(&1.status == :pending))
    after
      File.rm_rf(root)
    end
  end

  test "dispatch planning does not plan beyond project capacity in a single tick" do
    root = tmp_root("hub-runtime-dispatch-planning-capacity")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha",
        tracker_kind: "memory",
        workspace_root: Path.join([root, "workspaces", "alpha"]),
        max_concurrent_agents: 1
      )

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      runtime_name = Module.concat(__MODULE__, :DispatchPlanningCapacityRuntime)

      start_supervised!(
        {Runtime,
         name: runtime_name,
         config_path: hub_path,
         provider_executor: success_executor(self()),
         operator_acknowledgements: cutover_acknowledgements!(hub_path, provider_executor: success_executor(self()))},
        id: :hub_runtime_dispatch_planning_capacity
      )

      assert %{
               poll_tick: %{
                 candidate_intake: %{eligible_count: 0},
                 dispatch_planning: %{planned_count: 0, already_planned_count: 1, capacity_unavailable_count: 1},
                 dispatch_plan_application: %{applied_count: 1, skipped_count: 1}
               }
             } = Runtime.request_refresh(runtime_name)

      assert_receive {:provider_candidate_scan, %{project_id: "alpha"}}, 1_000

      snapshot = Runtime.snapshot(runtime_name, 100)
      assert snapshot.hub_dispatch_planning.counts.planned_count == 0
      assert snapshot.hub_dispatch_planning.counts.already_planned_count == 1
      assert snapshot.hub_dispatch_planning.counts.capacity_unavailable_count == 1
      assert snapshot.hub_dispatch_planning.skipped_reasons == %{"already_planned" => 1, "project_capacity_full" => 1}
      assert snapshot.hub_dispatch_plan_application.counts.applied_count == 1
      assert snapshot.hub_dispatch_plan_application.counts.skipped_count == 1
      assert snapshot.hub_dispatch_plan_application.reason_counts == %{"project_capacity_full" => 1}
    after
      File.rm_rf(root)
    end
  end

  test "opt-in scheduler automatically executes a startup tick and exposes safe API summary" do
    root = tmp_root("hub-runtime-scheduler-auto")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha",
        tracker_kind: "memory",
        workspace_root: Path.join([root, "workspaces", "alpha"]),
        poll_interval_ms: 60_000
      )

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      runtime_name = Module.concat(__MODULE__, :SchedulerAutoRuntime)

      runtime_opts = [
        name: runtime_name,
        config_path: hub_path,
        scheduler_enabled: true,
        provider_executor: success_executor(self()),
        operator_acknowledgements:
          cutover_acknowledgements!(hub_path,
            provider_executor: success_executor(self()),
            scheduler_enabled: true
          )
      ]

      start_supervised!(
        {Runtime, runtime_opts},
        id: :hub_runtime_scheduler_auto
      )

      assert_receive {:provider_candidate_scan, %{project_id: "alpha"}}, 1_000

      assert eventually(fn ->
               case Runtime.snapshot(runtime_name, 1_000) do
                 %{hub_scheduler: scheduler, hub_runtime: hub_runtime} ->
                   scheduler.counts.run_count >= 1 and hub_runtime.poll_tick.status == "completed"

                 _snapshot ->
                   false
               end
             end)

      snapshot = Runtime.snapshot(runtime_name, 100)
      assert snapshot.hub_scheduler.enabled == true
      assert snapshot.hub_scheduler.status == "scheduled"
      assert snapshot.hub_scheduler.next_tick_at != nil
      assert snapshot.hub_scheduler.next_reason in ["runtime_reconciliation", "next_project_due"]
      assert [project] = snapshot.hub_scheduler.projects
      assert project.project_id == "alpha"
      assert project.pending_start_intent_count == 2
      assert snapshot.hub_scheduler.unresolved_runtime.pending_start_intent_count == 2

      payload = Presenter.state_payload(runtime_name, 100)
      assert payload.hub_scheduler.enabled == true
      assert payload.hub_runtime.scheduler.enabled == true

      safe_text = inspect(payload)
      refute safe_text =~ "GITHUB_TOKEN"
      refute safe_text =~ "Authorization:"
      refute safe_text =~ "cookie"
      refute safe_text =~ "secret"
      refute safe_text =~ "raw_config"
      refute safe_text =~ "full prompt"
      refute safe_text =~ "transcript"
      refute safe_text =~ "comment body"
    after
      File.rm_rf(root)
    end
  end

  test "scheduler coalesces manual refresh while a tick is running without duplicating ledger state" do
    root = tmp_root("hub-runtime-scheduler-coalesce")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha",
        tracker_kind: "memory",
        workspace_root: Path.join([root, "workspaces", "alpha"]),
        poll_interval_ms: 1
      )

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      runtime_name = Module.concat(__MODULE__, :SchedulerCoalesceRuntime)
      parent = self()

      runtime_opts = [
        name: runtime_name,
        config_path: hub_path,
        scheduler_enabled: true,
        provider_executor: blocking_success_executor(parent),
        operator_acknowledgements:
          cutover_acknowledgements!(hub_path,
            provider_executor: blocking_success_executor(parent),
            scheduler_enabled: true
          )
      ]

      start_supervised!(
        {Runtime, runtime_opts},
        id: :hub_runtime_scheduler_coalesce
      )

      assert_receive {:blocking_provider_started, %{project_id: "alpha"}, provider_pid}, 1_000

      reply = Runtime.request_refresh(runtime_name)
      assert reply.queued == true
      assert reply.coalesced == true
      assert reply.next_tick_at == nil
      assert reply.scheduler.status == "coalesced"
      assert reply.scheduler.counts.coalesced_count == 1

      send(provider_pid, :release_blocking_provider)
      assert_receive {:blocking_provider_released, "alpha"}, 1_000

      assert eventually(
               fn ->
                 case Runtime.snapshot(runtime_name, 1_000) do
                   %{hub_scheduler: scheduler, hub_dispatch_plan_application: application} ->
                     scheduler.counts.run_count >= 1 and application.counts.applied_count == 2

                   _snapshot ->
                     false
                 end
               end,
               100
             )

      snapshot = Runtime.snapshot(runtime_name, 100)
      assert snapshot.hub_scheduler.counts.coalesced_count == 1

      dispatch_summary = RuntimeLedger.replay(snapshot.hub_dispatch_boundary)
      assert [ledger_project] = dispatch_summary.projects
      assert length(ledger_project.active_attempts) == 2
      assert length(ledger_project.pending_start_intents) == 2
    after
      send(self(), :release_blocking_provider)
      File.rm_rf(root)
    end
  end

  test "scheduler uses default interval when every project is paused" do
    root = tmp_root("hub-runtime-scheduler-paused-idle")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha",
        tracker_kind: "memory",
        workspace_root: Path.join([root, "workspaces", "alpha"])
      )

      write_project!(root, "beta",
        tracker_kind: "memory",
        workspace_root: Path.join([root, "workspaces", "beta"])
      )

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          dispatch_enabled: false
        - project_id: beta
          workflow_path: beta/WORKFLOW.md
          dispatch_enabled: false
      """)

      runtime_name = Module.concat(__MODULE__, :SchedulerPausedIdleRuntime)

      runtime_opts = [
        name: runtime_name,
        config_path: hub_path,
        scheduler_enabled: true,
        provider_executor: success_executor(self())
      ]

      start_supervised!(
        {Runtime, runtime_opts},
        id: :hub_runtime_scheduler_paused_idle
      )

      assert eventually(fn ->
               case Runtime.snapshot(runtime_name, 1_000) do
                 %{hub_scheduler: %{status: "scheduled", counts: %{run_count: count}, next_delay_ms: 30_000}} ->
                   count >= 1

                 _snapshot ->
                   false
               end
             end)

      snapshot = Runtime.snapshot(runtime_name, 100)
      assert snapshot.hub_scheduler.next_reason == "default_interval"
      assert snapshot.hub_scheduler.next_tick_at != nil

      projects = Map.new(snapshot.hub_scheduler.projects, &{&1.project_id, &1})
      assert projects["alpha"].allow_poll == false
      assert projects["alpha"].eligibility_reason == "paused"
      assert projects["beta"].allow_poll == false
      assert projects["beta"].eligibility_reason == "paused"

      run_count = snapshot.hub_scheduler.counts.run_count
      Process.sleep(100)
      assert Runtime.snapshot(runtime_name, 100).hub_scheduler.counts.run_count == run_count
      refute_receive {:provider_candidate_scan, _request}, 100
    after
      File.rm_rf(root)
    end
  end

  test "successful idle polls reuse expensive projections while updating live poll state" do
    root = tmp_root("hub-runtime-scheduler-idle-projection-cache")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha",
        tracker_kind: "memory",
        workspace_root: Path.join([root, "workspaces", "alpha"]),
        poll_interval_ms: 1_100
      )

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      provider_executor = fn request, _opts ->
        ProviderGovernance.result(request, :success,
          result_summary: %{
            issue_count: 0,
            candidates: [],
            execution_outcome: %{
              generated_at: DateTime.utc_now(),
              outcome_id: "volatile-#{System.unique_integer([:positive])}"
            }
          }
        )
      end

      runtime_name = Module.concat(__MODULE__, :SchedulerIdleProjectionCacheRuntime)

      start_supervised!(
        {Runtime,
         name: runtime_name,
         config_path: hub_path,
         scheduler_enabled: true,
         provider_executor: provider_executor,
         operator_acknowledgements:
           cutover_acknowledgements!(hub_path,
             provider_executor: provider_executor,
             scheduler_enabled: true
           )},
        id: :hub_runtime_scheduler_idle_projection_cache
      )

      assert eventually(fn ->
               scheduler = Runtime.snapshot(runtime_name, 1_000).hub_scheduler
               scheduler.counts.run_count >= 1 and scheduler.status == "scheduled"
             end)

      first = Runtime.snapshot(runtime_name, 1_000)
      first_run_count = first.hub_scheduler.counts.run_count
      first_closure = first.hub_cutover_closure_chain
      first_candidate_intake = first.hub_candidate_intake
      first_dispatch_planning = first.hub_dispatch_planning
      first_poll_fact_count = length(first.hub_poll_coordination.facts)

      assert eventually(
               fn ->
                 scheduler = Runtime.snapshot(runtime_name, 1_000).hub_scheduler
                 scheduler.counts.run_count > first_run_count and scheduler.status == "scheduled"
               end,
               100
             )

      second = Runtime.snapshot(runtime_name, 1_000)
      assert second.hub_cutover_closure_chain == first_closure
      assert second.hub_candidate_intake == first_candidate_intake
      assert second.hub_dispatch_planning == first_dispatch_planning
      assert length(second.hub_poll_coordination.facts) > first_poll_fact_count
      assert second.hub_candidate_intake.counts.candidate_count == 0
      assert second.hub_scheduler.next_reason == "next_project_due"
      assert second.hub_scheduler.next_delay_ms >= 55_000
      assert second.hub_scheduler.next_delay_ms <= 60_000
    after
      File.rm_rf(root)
    end
  end

  test "scheduler waits for a future retry instead of entering one-second reconciliation" do
    root = tmp_root("hub-runtime-scheduler-future-retry")
    hub_path = Path.join(root, "HUB.yaml")
    due_at = DateTime.utc_now() |> DateTime.add(10, :second) |> DateTime.truncate(:second)

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "alpha"]))

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          dispatch_enabled: false
      """)

      runtime_name = Module.concat(__MODULE__, :SchedulerFutureRetryRuntime)
      runtime_ledger = retry_runtime_ledger(due_at)

      start_supervised!(
        {Runtime, name: runtime_name, config_path: hub_path, scheduler_enabled: true, runtime_ledger: runtime_ledger},
        id: :hub_runtime_scheduler_future_retry
      )

      assert eventually(fn ->
               case Runtime.snapshot(runtime_name, 1_000) do
                 %{hub_scheduler: %{status: "scheduled", next_reason: "retry_due", counts: %{run_count: count}}} -> count >= 1
                 _snapshot -> false
               end
             end)

      snapshot = Runtime.snapshot(runtime_name, 100)
      assert snapshot.hub_scheduler.next_delay_ms > 1_000
      assert snapshot.hub_scheduler.next_delay_ms <= 10_000
      assert snapshot.hub_scheduler.earliest_retry_due_at == DateTime.to_iso8601(due_at)

      run_count = snapshot.hub_scheduler.counts.run_count
      Process.sleep(100)
      assert Runtime.snapshot(runtime_name, 100).hub_scheduler.counts.run_count == run_count
      refute_receive {:provider_candidate_scan, _request}, 100
    after
      File.rm_rf(root)
    end
  end

  test "invalid retry data uses bounded error backoff and remains observable" do
    root = tmp_root("hub-runtime-scheduler-invalid-retry")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "alpha"]))

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          dispatch_enabled: false
      """)

      runtime_name = Module.concat(__MODULE__, :SchedulerInvalidRetryRuntime)
      runtime_ledger = retry_runtime_ledger("not-a-datetime")

      start_supervised!(
        {Runtime, name: runtime_name, config_path: hub_path, scheduler_enabled: true, runtime_ledger: runtime_ledger},
        id: :hub_runtime_scheduler_invalid_retry
      )

      assert eventually(fn ->
               case Runtime.snapshot(runtime_name, 1_000) do
                 %{hub_scheduler: %{status: "scheduled", next_reason: "invalid_retry_backoff", next_delay_ms: 30_000}} -> true
                 _snapshot -> false
               end
             end)

      snapshot = Runtime.snapshot(runtime_name, 100)
      assert snapshot.hub_scheduler.counts.invalid_retry_count == 1
      replay = RuntimeLedger.replay(snapshot.hub_dispatch_boundary)
      assert Enum.any?(replay.conflicts, &(&1.code == :retry_backoff_invalid_due_at))
      assert Enum.any?(replay.manual_attention, &(&1.code == :retry_backoff_invalid_due_at))
    after
      File.rm_rf(root)
    end
  end

  test "runtime reconciliation skips provider scans and reuses the cached activation probe" do
    root = tmp_root("hub-runtime-scheduler-light-reconciliation")
    hub_path = Path.join(root, "HUB.yaml")
    workspace_root = Path.join([root, "workspaces", "alpha"])
    parent = self()

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: workspace_root)

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          dispatch_enabled: false
      """)

      activation_probe = fn _registry ->
        send(parent, :host_service_probe_called)
        %{status: "ok", source: "host_service_probe", projects: %{}}
      end

      runtime_name = Module.concat(__MODULE__, :SchedulerLightReconciliationRuntime)

      start_supervised!(
        {Runtime,
         name: runtime_name,
         config_path: hub_path,
         scheduler_enabled: true,
         runtime_ledger: active_runtime_ledger(workspace_root),
         activation_probe: activation_probe,
         activation_probe_interval_ms: 30_000},
        id: :hub_runtime_scheduler_light_reconciliation
      )

      assert_receive :host_service_probe_called, 1_000

      assert eventually(
               fn ->
                 case Runtime.snapshot(runtime_name, 1_000) do
                   %{
                     hub_scheduler: %{
                       status: "scheduled",
                       counts: %{run_count: count},
                       last_tick: %{reason: "runtime_reconciliation", operations: operations}
                     }
                   } ->
                     count >= 2 and
                       operations == [
                         "hub_worker_start_handoff",
                         "hub_worker_lifecycle_reconciliation",
                         "hub_scheduler_reconciliation"
                       ]

                   _snapshot ->
                     false
                 end
               end,
               80
             )

      snapshot = Runtime.snapshot(runtime_name, 100)
      assert snapshot.hub_scheduler.counts.activation_probe_count == 1

      assert snapshot.hub_scheduler.last_tick.operations == [
               "hub_worker_start_handoff",
               "hub_worker_lifecycle_reconciliation",
               "hub_scheduler_reconciliation"
             ]

      refute_receive :host_service_probe_called, 100
      refute_receive {:provider_candidate_scan, _request}, 100
    after
      File.rm_rf(root)
    end
  end

  test "manual refresh records each activation probe execution" do
    root = tmp_root("hub-runtime-activation-probe-count")
    hub_path = Path.join(root, "HUB.yaml")
    parent = self()

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "alpha"]))

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          dispatch_enabled: false
      """)

      activation_probe = fn _registry ->
        send(parent, :activation_probe_called)
        %{status: "ok", source: "host_service_probe", projects: %{}}
      end

      runtime_name = Module.concat(__MODULE__, :ActivationProbeCountRuntime)

      start_supervised!(
        {Runtime, name: runtime_name, config_path: hub_path, activation_probe: activation_probe},
        id: :hub_runtime_activation_probe_count
      )

      assert_receive :activation_probe_called, 1_000
      assert %{poll_tick: %{status: "completed"}} = Runtime.request_refresh(runtime_name)
      assert_receive :activation_probe_called, 1_000
      assert Runtime.snapshot(runtime_name, 100).hub_scheduler.counts.activation_probe_count == 2
    after
      File.rm_rf(root)
    end
  end

  test "scheduler next tick uses provider backoff and isolates provider failures" do
    root = tmp_root("hub-runtime-scheduler-backoff")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "alpha"]))
      write_project!(root, "beta", tracker_kind: "gitlab", tracker_project_slug: "platform/beta", workspace_root: Path.join([root, "workspaces", "beta"]))

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
        - project_id: beta
          workflow_path: beta/WORKFLOW.md
          migration_state: hub_managed
      """)

      runtime_name = Module.concat(__MODULE__, :SchedulerBackoffRuntime)

      runtime_opts = [
        name: runtime_name,
        config_path: hub_path,
        scheduler_enabled: true,
        provider_executor: raising_alpha_executor(self()),
        operator_acknowledgements:
          cutover_acknowledgements!(hub_path,
            provider_executor: raising_alpha_executor(self()),
            scheduler_enabled: true
          )
      ]

      start_supervised!(
        {Runtime, runtime_opts},
        id: :hub_runtime_scheduler_backoff
      )

      assert_receive {:raising_provider_request, "alpha"}, 1_000
      assert_receive {:successful_request, "beta"}, 1_000

      assert eventually(fn ->
               case Runtime.snapshot(runtime_name, 1_000) do
                 %{hub_runtime: hub_runtime} ->
                   hub_runtime.poll_tick.result_counts == %{"retryable_failure" => 1, "success" => 1}

                 _snapshot ->
                   false
               end
             end)

      snapshot = Runtime.snapshot(runtime_name, 100)
      assert snapshot.hub_scheduler.enabled == true
      assert snapshot.hub_scheduler.next_tick_at != nil
      assert snapshot.hub_scheduler.counts.error_count == 0

      projects = Map.new(snapshot.hub_poll_coordination.projects, &{&1.project_id, &1})
      assert projects["alpha"].allow_poll == false
      assert projects["alpha"].eligibility.reason == :backoff
      assert projects["alpha"].last_poll.status == :retryable_failure
      assert projects["beta"].last_poll.status == :success

      scheduler_projects = Map.new(snapshot.hub_scheduler.projects, &{&1.project_id, &1})
      assert scheduler_projects["alpha"].backoff_until != nil

      payload = Presenter.state_payload(runtime_name, 100)
      safe_text = inspect(payload)
      refute safe_text =~ "Bearer scheduler secret"
      refute safe_text =~ "ghp_scheduler_secret"
      refute safe_text =~ "raw provider body"
    after
      File.rm_rf(root)
    end
  end

  test "disabled scheduler keeps legacy-shaped Hub refresh synchronous" do
    root = tmp_root("hub-runtime-scheduler-disabled")
    hub_path = Path.join(root, "HUB.yaml")

    try do
      write_project!(root, "alpha", tracker_kind: "memory", workspace_root: Path.join([root, "workspaces", "alpha"]))

      File.write!(hub_path, """
      projects:
        - project_id: alpha
          workflow_path: alpha/WORKFLOW.md
          migration_state: hub_managed
      """)

      runtime_name = Module.concat(__MODULE__, :SchedulerDisabledRuntime)

      start_supervised!(
        {Runtime,
         name: runtime_name,
         config_path: hub_path,
         provider_executor: success_executor(self()),
         operator_acknowledgements: cutover_acknowledgements!(hub_path, provider_executor: success_executor(self()))},
        id: :hub_runtime_scheduler_disabled
      )

      snapshot = Runtime.snapshot(runtime_name, 100)
      assert snapshot.hub_scheduler.enabled == false
      assert snapshot.hub_scheduler.status == "disabled"
      assert snapshot.hub_scheduler.queued == false
      refute_receive {:provider_candidate_scan, _request}, 100

      assert %{queued: true, coalesced: false, poll_tick: %{selected_count: 1}} = Runtime.request_refresh(runtime_name)
      assert_receive {:provider_candidate_scan, %{project_id: "alpha"}}, 1_000

      legacy_name = Module.concat(__MODULE__, :SchedulerLegacySnapshot)

      start_supervised!(
        {__MODULE__.StaticSnapshot, name: legacy_name, snapshot: legacy_snapshot()},
        id: :hub_runtime_scheduler_legacy_snapshot
      )

      legacy_payload = Presenter.state_payload(legacy_name, 100)
      refute Map.has_key?(legacy_payload, :hub_scheduler)
      refute Map.has_key?(legacy_payload, :hub_runtime)
    after
      File.rm_rf(root)
    end
  end

  defmodule StaticSnapshot do
    @moduledoc false
    use GenServer

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      snapshot = Keyword.fetch!(opts, :snapshot)
      GenServer.start_link(__MODULE__, snapshot, name: name)
    end

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  defp success_executor(parent) do
    fn request, _opts ->
      send(parent, {:provider_candidate_scan, request})

      ProviderGovernance.result(request, :success,
        result_summary: %{
          issue_count: 2,
          token: "ghp_secret_should_not_leak",
          candidates: [
            %{id: "mem-1", identifier: "MEM-1", current_stage: "ready"},
            %{"id" => "mem-2", "identifier" => "MEM-2", "current_stage" => "ready"}
          ]
        }
      )
    end
  end

  defp blocking_success_executor(parent) do
    fn request, _opts ->
      send(parent, {:blocking_provider_started, request, self()})

      receive do
        :release_blocking_provider -> :ok
      after
        2_000 -> :ok
      end

      send(parent, {:blocking_provider_released, request.project_id})

      ProviderGovernance.result(request, :success,
        result_summary: %{
          issue_count: 2,
          candidates: [
            %{id: "mem-1", identifier: "MEM-1", current_stage: "ready"},
            %{id: "mem-2", identifier: "MEM-2", current_stage: "ready"}
          ]
        }
      )
    end
  end

  defp raising_alpha_executor(parent) do
    fn request, _opts ->
      case request.project_id do
        "alpha" ->
          send(parent, {:raising_provider_request, request.project_id})
          raise "provider exploded with Bearer scheduler secret and ghp_scheduler_secret raw provider body"

        project_id ->
          send(parent, {:successful_request, project_id})
          ProviderGovernance.result(request, :success, result_summary: %{issue_count: 0})
      end
    end
  end

  defp backoff_executor(parent) do
    fn request, _opts ->
      case request.project_id do
        "alpha" ->
          send(parent, {:rate_limited_request, request.project_id})

          ProviderGovernance.result(request, :rate_limited,
            retry_after_ms: 60_000,
            error_class: :rate_limited,
            result_summary: %{message: "rate limited", authorization: "Bearer secret"}
          )

        project_id ->
          send(parent, {:successful_request, project_id})
          ProviderGovernance.result(request, :success, result_summary: %{issue_count: 0})
      end
    end
  end

  defp secret_executor do
    fn request, _opts ->
      ProviderGovernance.result(request, :success,
        result_summary: %{
          token: "ghp_supersecret",
          authorization: "Bearer supersecret",
          cookie: "session=secret",
          prompt: "full prompt should not leak",
          transcript: "complete transcript should not leak",
          raw_body: "raw provider body should not leak",
          visible_count: 1,
          candidates: [
            %{
              id: "mem-secret",
              identifier: "MEM-SECRET",
              authorization: "Bearer nested",
              comment_body: "complete comment body should not leak"
            }
          ]
        }
      )
    end
  end

  defp body_only_executor do
    fn request, _opts ->
      ProviderGovernance.result(request, :success,
        result_summary: %{
          issue_count: 2,
          body: "plain issue body should not leak",
          comment_body: "plain comment body should not leak",
          pull_request_body: "plain pull request body should not leak",
          pr_body: "plain pr body should not leak",
          raw_provider_body: "plain raw provider body should not leak",
          full_prompt: "plain full prompt body should not leak",
          candidates: [
            %{
              id: "mem-body-atom",
              identifier: "MEM-BODY-ATOM",
              body: "nested atom-key candidate body should not leak"
            },
            %{
              "id" => "mem-body-string",
              "identifier" => "MEM-BODY-STRING",
              "comment_body" => "nested string-key candidate body should not leak"
            }
          ]
        }
      )
    end
  end

  defp conflict_executor(parent, workspace_root) do
    fn request, _opts ->
      send(parent, {:provider_candidate_scan_conflicts, request})

      ProviderGovernance.result(request, :success,
        result_summary: %{
          issue_count: 3,
          candidates: [
            %{id: "mem-active", identifier: "MEM-ACTIVE", workspace_path: Path.join(workspace_root, "active")},
            %{id: "mem-workspace", identifier: "MEM-WORKSPACE", workspace_path: Path.join(workspace_root, "shared")},
            %{id: "mem-ready", identifier: "MEM-READY", workspace_path: Path.join(workspace_root, "ready")}
          ]
        }
      )
    end
  end

  defp reason_names(project) do
    project.backpressure_reasons
    |> Enum.map(& &1.reason)
    |> Enum.sort()
  end

  defp provider_request!(attrs) do
    assert {:ok, request} = ProviderGovernance.new_request(Map.new(attrs))
    request
  end

  defp unresolved_outcome(project_id, side_effect_entered?) do
    guard =
      CutoverAuthorizationConsumptionGuard.to_decision(%{
        project_id: project_id,
        provider_scope: %{kind: "github", key: "github:o/r", provider_scope_key: "github:o/r", scope: %{owner: "o", repo: "r"}},
        operation: "writeback",
        side_effect_source: "writeback_executor",
        decision: "allowed",
        allowed: true,
        authorization_record_fingerprint: "#{project_id}-record-fp",
        authorization_request_fingerprint: "#{project_id}-auth-request-fp",
        safe_evidence_fingerprints: %{
          cutover_operation_request: "#{project_id}-request-fp",
          readiness_permit: "#{project_id}-permit-fp",
          readiness_permit_decision: "ready_for_execution_consideration",
          cutover_gate: "#{project_id}-gate-fp",
          dry_run_audit: "#{project_id}-audit-fp",
          audit_history: "#{project_id}-history-fp"
        }
      })

    CutoverExecutionOutcomeLedger.fact_snapshot(%{
      project_id: project_id,
      provider_scope: %{kind: "github", key: "github:o/r", provider_scope_key: "github:o/r", scope: %{owner: "o", repo: "r"}},
      operation: "writeback",
      side_effect_source: "writeback_executor",
      status: "unknown",
      reason_code: "provider_ack_lost",
      authorization_consumption_guard: guard,
      executor_result: %{
        provider_io: side_effect_entered?,
        raw_provider_response: "full provider response with ghp_secret",
        local_path: "/home/jhihjian/private/runtime.log"
      },
      side_effect_entered: side_effect_entered?,
      side_effect_may_have_happened: side_effect_entered?,
      started_at: ~U[2026-07-01 09:00:00Z],
      completed_at: ~U[2026-07-01 09:00:00Z]
    })
  end

  defp closure_outcome(project_id, status, opts \\ []) do
    guard_decision = Keyword.get(opts, :guard_decision, "allowed")
    side_effect_entered = Keyword.get(opts, :side_effect_entered, status == "succeeded")

    guard =
      CutoverAuthorizationConsumptionGuard.to_decision(%{
        project_id: project_id,
        provider_scope: %{kind: "memory", key: "memory:#{project_id}", provider_scope_key: "memory:#{project_id}", scope: %{namespace: project_id}},
        operation: "writeback",
        side_effect_source: "writeback_executor",
        decision: guard_decision,
        allowed: guard_decision == "allowed",
        authorization_record_fingerprint: "#{project_id}-record-fp",
        authorization_request_fingerprint: "#{project_id}-auth-request-fp",
        safe_evidence_fingerprints: %{
          cutover_operation_request: "#{project_id}-request-fp",
          readiness_permit: "#{project_id}-permit-fp",
          readiness_permit_decision: "ready_for_execution_consideration",
          cutover_gate: "#{project_id}-gate-fp",
          dry_run_audit: "#{project_id}-audit-fp",
          audit_history: "#{project_id}-history-fp"
        }
      })

    CutoverExecutionOutcomeLedger.fact_snapshot(%{
      project_id: project_id,
      provider_scope: %{kind: "memory", key: "memory:#{project_id}", provider_scope_key: "memory:#{project_id}", scope: %{namespace: project_id}},
      operation: "writeback",
      side_effect_source: "writeback_executor",
      status: status,
      reason_code: "runtime_closure_#{status}",
      action_code: "inspect_runtime_closure",
      authorization_consumption_guard: guard,
      executor_result: %{
        provider_io: side_effect_entered,
        raw_provider_response: "full provider response with ghp_secret",
        full_prompt: "full prompt should not appear",
        local_path: "/home/jhihjian/private/runtime.log"
      },
      side_effect_entered: side_effect_entered,
      side_effect_may_have_happened: Keyword.get(opts, :side_effect_may_have_happened, side_effect_entered),
      started_at: ~U[2026-07-01 09:00:00Z],
      completed_at: ~U[2026-07-01 09:00:00Z]
    })
  end

  defp outcome_closeout(outcome, resolution_code) do
    %{
      project_id: outcome.project_id,
      provider_scope: outcome.provider_scope,
      operation: outcome.operation,
      side_effect_source: outcome.side_effect_source,
      replay_key: outcome.replay_key,
      outcome_fingerprint: outcome.evidence_fingerprint,
      outcome_status: outcome.status,
      side_effect_entered: outcome.side_effect_entered,
      side_effect_may_have_happened: outcome.side_effect_may_have_happened,
      cutover_operation_request_fingerprint: outcome.cutover_operation_request_fingerprint,
      authorization_record_fingerprint: outcome.authorization_record_fingerprint,
      authorization_request_fingerprint: outcome.authorization_request_fingerprint,
      readiness_permit_fingerprint: outcome.readiness_permit_fingerprint,
      readiness_permit_decision: outcome.readiness_permit_decision,
      cutover_gate_fingerprint: outcome.cutover_gate_fingerprint,
      dry_run_audit_fingerprint: outcome.dry_run_audit_fingerprint,
      audit_history_fingerprint: outcome.audit_history_fingerprint,
      consumption_guard_fingerprint: outcome.safe_evidence_fingerprints.consumption_guard,
      resolution_code: resolution_code,
      reason_code: "operator_checked_external_state",
      action_code: "record_manual_resolution",
      source: "operator_file",
      created_at: "2026-07-01T09:01:00Z",
      closed_at: "2026-07-01T09:02:00Z",
      operator_note: "operator note with raw_provider_response and ghp_secret redacted by digest"
    }
  end

  defp replay_readiness_permit_summary(outcome) do
    CutoverReadinessPermit.to_snapshot(%{
      projects: [
        %{
          project_id: outcome.project_id,
          status: "ready_for_execution_consideration",
          provider_scope: outcome.provider_scope,
          permits: [
            %{
              project_id: outcome.project_id,
              provider_scope: outcome.provider_scope,
              operation: outcome.operation,
              decision: "ready_for_execution_consideration",
              permit_fingerprint: outcome.readiness_permit_fingerprint,
              request: %{request_fingerprint: outcome.cutover_operation_request_fingerprint},
              evidence_fingerprints: %{
                dry_run_audit: outcome.dry_run_audit_fingerprint,
                audit_history: outcome.audit_history_fingerprint
              }
            }
          ]
        }
      ]
    })
  end

  defp replay_authorization_ledger_summary(outcome) do
    CutoverExecutionAuthorization.to_snapshot(%{
      projects: [
        %{
          project_id: outcome.project_id,
          status: "authorized_for_explicit_execution",
          provider_scope: outcome.provider_scope,
          records: [
            %{
              project_id: outcome.project_id,
              provider_scope: outcome.provider_scope,
              operation: outcome.operation,
              status: "authorized_for_explicit_execution",
              authorization_record_fingerprint: outcome.authorization_record_fingerprint,
              authorization_request: %{authorization_request_fingerprint: outcome.authorization_request_fingerprint},
              cutover_operation_request: %{request_fingerprint: outcome.cutover_operation_request_fingerprint},
              readiness_permit: %{
                permit_fingerprint: outcome.readiness_permit_fingerprint,
                decision: outcome.readiness_permit_decision
              },
              evidence_fingerprints: %{
                dry_run_audit: outcome.dry_run_audit_fingerprint,
                audit_history: outcome.audit_history_fingerprint
              },
              source: "operator_file",
              authorized_at: "2026-07-01T09:00:00Z"
            }
          ]
        }
      ]
    })
  end

  defp replay_request_from_snapshot(outcome, closeout_summary, replay_decision_summary) do
    closeout =
      closeout_summary.projects
      |> hd()
      |> Map.fetch!(:closeouts)
      |> hd()

    decision =
      replay_decision_summary.projects
      |> hd()
      |> Map.fetch!(:recent_decisions)
      |> hd()

    %{
      request_id: "runtime-replay-request-#{outcome.project_id}",
      project_id: outcome.project_id,
      provider_scope: outcome.provider_scope,
      operation: outcome.operation,
      side_effect_source: outcome.side_effect_source,
      replay_key: outcome.replay_key,
      outcome_fingerprint: outcome.evidence_fingerprint,
      outcome_status: outcome.status,
      outcome_side_effect: %{
        entered: outcome.side_effect_entered,
        may_have_happened: outcome.side_effect_may_have_happened
      },
      closeout_record_fingerprint: closeout.closeout_record_fingerprint,
      closeout_resolution_code: closeout.resolution_code,
      closeout_operator_request_fingerprint: closeout.operator_request_fingerprint,
      replay_decision_fingerprint: replay_decision_fingerprint(decision),
      replay_decision_status: decision.decision,
      cutover_operation_request_fingerprint: outcome.cutover_operation_request_fingerprint,
      readiness_permit_fingerprint: outcome.readiness_permit_fingerprint,
      readiness_permit_decision: outcome.readiness_permit_decision,
      authorization_record_fingerprint: outcome.authorization_record_fingerprint,
      authorization_request_fingerprint: outcome.authorization_request_fingerprint,
      consumption_guard_fingerprint: outcome.safe_evidence_fingerprints.consumption_guard,
      guard_decision: "allowed",
      cutover_gate_fingerprint: outcome.cutover_gate_fingerprint,
      dry_run_audit_fingerprint: outcome.dry_run_audit_fingerprint,
      audit_history_fingerprint: outcome.audit_history_fingerprint,
      source: "operator_file",
      requested_at: "2026-07-01T09:03:00Z",
      action_code: "request_explicit_retry_consideration",
      operator_note: "full prompt and ghp_secret must not leak"
    }
  end

  defp replay_decision_fingerprint(decision) do
    decision = CutoverReplayDecision.to_decision(decision)

    decision
    |> Map.take([
      :project_id,
      :provider_scope,
      :operation,
      :side_effect_source,
      :replay_key,
      :decision,
      :allowed,
      :outcome_fingerprint,
      :closeout_record_fingerprint,
      :authorization_record_fingerprint,
      :readiness_permit_fingerprint,
      :consumption_guard_fingerprint,
      :safe_evidence_fingerprints
    ])
    |> fingerprint()
  end

  defp fingerprint(value) do
    value
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp write_project!(root, project_id, overrides) do
    project_dir = Path.join(root, project_id)
    File.mkdir_p!(project_dir)
    write_workflow_file!(Path.join(project_dir, "WORKFLOW.md"), overrides)
  end

  defp write_legacy_project!(config_root, project_id, overrides) do
    project_dir = Path.join(config_root, project_id)
    File.mkdir_p!(project_dir)
    write_workflow_file!(Path.join(project_dir, "WORKFLOW.md"), overrides)

    File.write!(Path.join(project_dir, "env"), """
    SYMPHONY_PORT=#{Keyword.fetch!(overrides, :server_port)}
    SYMPHONY_LOGS_ROOT=#{Path.join(config_root, project_id <> "-logs")}
    SECRET_TOKEN=should-not-leak
    """)
  end

  defp writeback_project(project_id, writebacks) do
    issue_ref = memory_issue_ref(project_id, "129", "129")

    %{
      project_id: project_id,
      issues: [
        %{
          issue_ref: issue_ref,
          claim_status: :unclaimed,
          writebacks: writebacks
        }
      ]
    }
  end

  defp legacy_snapshot do
    %{
      running: [],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }
  end

  defp active_runtime_ledger(workspace_root) do
    active_ref = memory_issue_ref("alpha", "mem-active", "MEM-ACTIVE")
    shared_ref = memory_issue_ref("alpha", "mem-shared", "MEM-SHARED")
    active_key = RuntimeLedger.issue_key(active_ref)
    shared_key = RuntimeLedger.issue_key(shared_ref)

    RuntimeLedger.new(
      projects: [
        %{
          project_id: "alpha",
          issues: [
            %{
              issue_ref: active_ref,
              claim_status: :running,
              attempts: [
                %{attempt_id: "attempt-active", attempt_number: 1, status: :running, workspace_path: Path.join(workspace_root, "active")}
              ]
            },
            %{
              issue_ref: shared_ref,
              claim_status: :running,
              attempts: [
                %{attempt_id: "attempt-shared", attempt_number: 1, status: :running, workspace_path: Path.join(workspace_root, "shared")}
              ]
            }
          ],
          workspace_leases: [
            %{lease_id: "lease-active", issue_key: active_key, attempt_id: "attempt-active", workspace_path: Path.join(workspace_root, "active"), status: :active},
            %{lease_id: "lease-shared", issue_key: shared_key, attempt_id: "attempt-shared", workspace_path: Path.join(workspace_root, "shared"), status: :active}
          ]
        }
      ]
    )
  end

  defp retry_runtime_ledger(due_at) do
    issue_ref = memory_issue_ref("alpha", "mem-retry", "MEM-RETRY")

    RuntimeLedger.new(
      projects: [
        %{
          project_id: "alpha",
          issues: [
            %{
              issue_ref: issue_ref,
              claim_status: :retry_queued,
              attempts: [%{attempt_id: "attempt-retry", attempt_number: 1, status: :failed}],
              retry_backoff: %{attempt_id: "attempt-retry", due_at: due_at, error_summary: "worker start failed"}
            }
          ]
        }
      ]
    )
  end

  defp memory_issue_ref(project_id, issue_id, identifier) do
    %{
      project_id: project_id,
      tracker_kind: "memory",
      provider_scope: %{namespace: project_id},
      provider_scope_key: "memory:#{project_id}",
      provider_issue_id: issue_id,
      provider_local_id: identifier,
      identifier: identifier,
      url: "memory://#{project_id}/#{issue_id}"
    }
  end

  defp unknown_registry(unknown_keys) do
    Enum.reduce(unknown_keys, %{}, fn key, acc ->
      Map.put(acc, key, "visible")
    end)
  end

  defp cutover_acknowledgements!(hub_path, opts) do
    now = Keyword.get(opts, :now, ~U[2026-06-30 09:00:00Z])
    provider_executor = Keyword.get(opts, :provider_executor, ProviderExecutor)
    writeback_executor = Keyword.get(opts, :writeback_executor, provider_executor)
    worker_start_starter = Keyword.get(opts, :worker_start_starter)
    activation_probe = Keyword.get(opts, :activation_probe)
    scheduler_enabled? = Keyword.get(opts, :scheduler_enabled, false) == true

    {:ok, registry} = ProjectRegistry.load(hub_path)
    activation_preflight = ActivationPreflight.build(registry, now: now, probe: activation_probe)

    snapshot =
      Runtime.build_snapshot(hub_path, now, registry,
        now: now,
        activation_probe: activation_probe,
        activation_preflight: activation_preflight,
        provider_executor: provider_executor,
        writeback_executor: writeback_executor,
        worker_start_starter: worker_start_starter,
        scheduler: %{enabled: scheduler_enabled?, status: if(scheduler_enabled?, do: "scheduled", else: "disabled")}
      )

    Enum.map(snapshot.hub_device_observability.projects, fn project ->
      %{
        project_id: project.project_id,
        plan_id: project.activation_plan.plan_id,
        source: "test-operator-ack",
        created_at: "2026-06-30T09:01:00Z",
        acknowledged_action_codes: Enum.map(project.activation_plan.required_acknowledgements, & &1.code),
        note: "test acknowledgement; no automatic migration"
      }
    end)
  end

  defp tmp_root(name) do
    Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive, :monotonic])}")
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
