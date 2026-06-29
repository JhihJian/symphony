defmodule SymphonyElixir.HubRuntimeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{ProviderExecutor, ProviderGovernance, Runtime, RuntimeLedger}
  alias SymphonyElixirWeb.Presenter

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

      snapshot = Runtime.snapshot(runtime_name, 100)

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
      """)

      runtime_name = Module.concat(__MODULE__, :PresenterRuntime)

      start_supervised!(
        {Runtime, name: runtime_name, config_path: hub_path},
        id: :hub_runtime_presenter
      )

      payload = Presenter.state_payload(runtime_name, 100)

      assert payload.counts.running == 0
      assert payload.hub_runtime.mode == "hub"
      assert payload.hub_project_registry.project_count == 1
      assert payload.hub_poll_coordination.registry.project_count == 1
      assert payload.hub_candidate_intake.counts.candidate_count == 0
      assert payload.hub_dispatch_planning.counts.planned_count == 0
      assert payload.hub_dispatch_plan_application.counts.applied_count == 0
      assert payload.hub_device_observability.device.project_count == 1

      safe_text = inspect(payload)
      refute safe_text =~ "GITHUB_TOKEN"
      refute safe_text =~ "authorization"
      refute safe_text =~ "cookie"
      refute safe_text =~ "secret"
      refute safe_text =~ "raw_config"
      refute safe_text =~ "full prompt"
      refute safe_text =~ "transcript"
      refute safe_text =~ "comment body"

      legacy_name = Module.concat(__MODULE__, :LegacySnapshot)

      start_supervised!(
        {__MODULE__.StaticSnapshot, name: legacy_name, snapshot: legacy_snapshot()},
        id: :hub_runtime_legacy_snapshot
      )

      legacy_payload = Presenter.state_payload(legacy_name, 100)
      refute Map.has_key?(legacy_payload, :hub_runtime)
      refute Map.has_key?(legacy_payload, :hub_project_registry)
      refute Map.has_key?(legacy_payload, :hub_poll_coordination)
      refute Map.has_key?(legacy_payload, :hub_candidate_intake)
      refute Map.has_key?(legacy_payload, :hub_dispatch_planning)
      refute Map.has_key?(legacy_payload, :hub_dispatch_plan_application)
      refute Map.has_key?(legacy_payload, :hub_device_observability)
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
        - project_id: beta
          workflow_path: beta/WORKFLOW.md
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
      """)

      runtime_name = Module.concat(__MODULE__, :PollTickSuccessRuntime)

      start_supervised!(
        {Runtime, name: runtime_name, config_path: hub_path, provider_executor: success_executor(self())},
        id: :hub_runtime_poll_tick_success
      )

      assert %{poll_tick: %{status: "completed", selected_count: 1}} = Runtime.request_refresh(runtime_name)

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
      assert snapshot.hub_runtime.candidate_intake.candidate_count == 2
      assert snapshot.hub_runtime.candidate_intake.eligible_count == 0
      assert snapshot.hub_runtime.dispatch_planning.planned_count == 0
      assert snapshot.hub_runtime.dispatch_planning.already_planned_count == 2
      assert snapshot.hub_runtime.dispatch_planning.pending_intent_count == 2
      assert snapshot.hub_runtime.dispatch_plan_application.applied_count == 2
      assert snapshot.hub_runtime.dispatch_plan_application.pending_start_intent_count == 2

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
      assert [%{candidates: payload_candidates}] = payload.hub_candidate_intake.projects
      assert Enum.all?(payload_candidates, &(&1.dispatch_evaluation.skipped_reason == "duplicate_active_attempt"))
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
        - project_id: beta
          workflow_path: beta/WORKFLOW.md
      """)

      runtime_name = Module.concat(__MODULE__, :PollTickBackoffRuntime)

      start_supervised!(
        {Runtime, name: runtime_name, config_path: hub_path, provider_executor: backoff_executor(self())},
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
        - project_id: bad
          workflow_path: bad/WORKFLOW.md
      """)

      runtime_name = Module.concat(__MODULE__, :PollTickConfigErrorRuntime)

      start_supervised!(
        {Runtime, name: runtime_name, config_path: hub_path, provider_executor: success_executor(self())},
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
      """)

      runtime_name = Module.concat(__MODULE__, :PollTickRedactionRuntime)

      start_supervised!(
        {Runtime, name: runtime_name, config_path: hub_path, provider_executor: secret_executor()},
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
      refute safe_text =~ "authorization"
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
      """)

      runtime_name = Module.concat(__MODULE__, :PollTickBodyOnlyRedactionRuntime)

      start_supervised!(
        {Runtime, name: runtime_name, config_path: hub_path, provider_executor: body_only_executor()},
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
      """)

      runtime_name = Module.concat(__MODULE__, :CandidateIntakeConflictRuntime)

      start_supervised!(
        {Runtime,
         name: runtime_name,
         config_path: hub_path,
         provider_executor: conflict_executor(self(), Path.join([root, "workspaces", "alpha"])),
         runtime_ledger: active_runtime_ledger(Path.join([root, "workspaces", "alpha"]))},
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
      assert [%{issue_key: ready_key}] = ledger_project.pending_start_intents
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
      """)

      runtime_name = Module.concat(__MODULE__, :DispatchPlanningReplayRuntime)

      start_supervised!(
        {Runtime, name: runtime_name, config_path: hub_path, provider_executor: success_executor(self())},
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
                 dispatch_plan_application: %{already_applied_count: 2}
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
      """)

      runtime_name = Module.concat(__MODULE__, :DispatchPlanningCapacityRuntime)

      start_supervised!(
        {Runtime, name: runtime_name, config_path: hub_path, provider_executor: success_executor(self())},
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

  defp write_project!(root, project_id, overrides) do
    project_dir = Path.join(root, project_id)
    File.mkdir_p!(project_dir)
    write_workflow_file!(Path.join(project_dir, "WORKFLOW.md"), overrides)
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

  defp tmp_root(name) do
    Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive, :monotonic])}")
  end
end
