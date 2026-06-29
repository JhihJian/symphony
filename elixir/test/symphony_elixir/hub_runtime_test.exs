defmodule SymphonyElixir.HubRuntimeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.Runtime
  alias SymphonyElixirWeb.Presenter

  test "builds read-only Hub snapshot with ready paused and project-level config error entries" do
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
      assert snapshot.hub_runtime.read_only == true
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
      assert content =~ "read-only"
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

  defp unknown_registry(unknown_keys) do
    Enum.reduce(unknown_keys, %{}, fn key, acc ->
      Map.put(acc, key, "visible")
    end)
  end

  defp tmp_root(name) do
    Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive, :monotonic])}")
  end
end
