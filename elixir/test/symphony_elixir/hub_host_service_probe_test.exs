defmodule SymphonyElixir.HubHostServiceProbeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{ActivationPreflight, HostServiceProbe}

  test "maps active and enabled legacy services to activation preflight blockers" do
    root = tmp_root("host-service-probe-services")

    try do
      registry =
        registry([
          project("alpha", migration_state: "hub_managed"),
          project("beta", migration_state: "hub_managed", scope_key: "memory:beta", workspace_root: Path.join(root, "workspaces/beta"), port: 20_002)
        ])

      probe =
        HostServiceProbe.build(registry,
          config_root: Path.join(root, "config"),
          runtime_root: Path.join(root, "runtime"),
          deps:
            deps(%{
              systemctl_show: fn
                "symphony@alpha.service" -> {:ok, "ActiveState=active\nSubState=running\nResult=success\n"}
                "symphony@beta.service" -> {:ok, "ActiveState=inactive\nSubState=dead\nResult=success\n"}
              end,
              systemctl_enabled: fn
                "symphony@alpha.service" -> {:ok, "disabled"}
                "symphony@beta.service" -> {:ok, "enabled"}
              end
            })
        )

      summary = ActivationPreflight.build(registry, probe: probe, now: ~U[2026-06-30 03:00:00Z])
      projects = Map.new(summary.projects, &{&1.project_id, &1})

      assert projects["alpha"].status == "blocked_conflict"
      assert projects["beta"].status == "blocked_conflict"
      assert projects["alpha"].blocked_operations == ["poll", "dispatch", "worker_start", "writeback"]
      assert projects["beta"].blocked_operations == ["poll", "dispatch", "worker_start", "writeback"]

      alpha_sources = Enum.map(projects["alpha"].detected_legacy_ownership, & &1.source)
      beta_reasons = Enum.map(projects["beta"].detected_legacy_ownership, & &1.reason)
      assert "legacy_service" in alpha_sources
      assert "legacy_service_enabled" in beta_reasons
      refute ActivationPreflight.safe_to_manage?(summary, "alpha", :poll)
      refute ActivationPreflight.safe_to_manage?(summary, "beta", :writeback)
    after
      File.rm_rf(root)
    end
  end

  test "legacy config conflicts are isolated to matching hub project" do
    root = tmp_root("host-service-probe-config")
    config_root = Path.join(root, "config")
    runtime_root = Path.join(root, "runtime")
    alpha_workspace = Path.join(root, "legacy-alpha-workspaces")
    beta_workspace = Path.join(root, "hub-beta-workspaces")

    try do
      write_legacy_project!(config_root, "alpha",
        tracker_kind: "memory",
        workspace_root: alpha_workspace,
        server_port: 20_001,
        logs_root: Path.join(root, "runtime/alpha/logs")
      )

      write_legacy_project!(config_root, "other",
        tracker_kind: "memory",
        workspace_root: Path.join(root, "other-workspaces"),
        server_port: 20_099,
        logs_root: Path.join(root, "runtime/other/logs")
      )

      registry =
        registry([
          project("alpha", migration_state: "hub_managed", workspace_root: alpha_workspace, port: 20_001),
          project("beta", migration_state: "hub_managed", scope_key: "memory:beta", workspace_root: beta_workspace, port: 20_002)
        ])

      probe =
        HostServiceProbe.build(registry,
          config_root: config_root,
          runtime_root: runtime_root,
          deps: deps(%{listening_ports: fn -> {:ok, [20_001]} end})
        )

      safe_probe_text = inspect(probe)
      refute safe_probe_text =~ alpha_workspace
      refute safe_probe_text =~ Path.join(root, "runtime/alpha/logs")
      assert safe_probe_text =~ "sha256"

      summary = ActivationPreflight.build(registry, probe: probe)
      projects = Map.new(summary.projects, &{&1.project_id, &1})

      assert projects["alpha"].status == "blocked_conflict"
      assert projects["beta"].status == "safe_to_manage"

      alpha_sources = Enum.map(projects["alpha"].detected_legacy_ownership, & &1.source)
      assert "provider_scope_owner" in alpha_sources
      assert "workspace_owner" in alpha_sources
      assert "runtime_path_owner" in alpha_sources
      assert "log_path_owner" in alpha_sources
      assert "state_path_owner" in alpha_sources
      assert "dashboard_port_owner" in alpha_sources

      refute ActivationPreflight.safe_to_manage?(summary, "alpha", :dispatch)
      assert ActivationPreflight.safe_to_manage?(summary, "beta", :dispatch)
    after
      File.rm_rf(root)
    end
  end

  test "inactive disabled legacy config can remain as hub-managed project config" do
    root = tmp_root("host-service-probe-hub-owned-config")
    config_root = Path.join(root, "config")
    runtime_root = Path.join(root, "runtime")
    alpha_workspace = Path.join(root, "workspaces/alpha")

    try do
      write_legacy_project!(config_root, "alpha",
        tracker_kind: "memory",
        workspace_root: alpha_workspace,
        server_port: 20_001,
        logs_root: Path.join(root, "runtime/alpha/logs")
      )

      registry =
        registry([
          project("alpha", migration_state: "hub_managed", workspace_root: alpha_workspace, port: 20_001)
        ])

      probe =
        HostServiceProbe.build(registry,
          config_root: config_root,
          runtime_root: runtime_root,
          deps:
            deps(%{
              systemctl_show: fn "symphony@alpha.service" ->
                {:ok, "ActiveState=inactive\nSubState=dead\nResult=success\n"}
              end,
              systemctl_enabled: fn "symphony@alpha.service" -> {:ok, "disabled"} end,
              listening_ports: fn -> {:ok, []} end
            })
        )

      summary = ActivationPreflight.build(registry, probe: probe)
      alpha = Enum.find(summary.projects, &(&1.project_id == "alpha"))

      assert alpha.status == "safe_to_manage"
      assert alpha.detected_legacy_ownership == []
      assert ActivationPreflight.safe_to_manage?(summary, "alpha", :poll)
      assert ActivationPreflight.safe_to_manage?(summary, "alpha", :writeback)
    after
      File.rm_rf(root)
    end
  end

  test "not-found legacy template is treated as inactive disabled ownership" do
    root = tmp_root("host-service-probe-not-found-template")

    try do
      registry =
        registry([
          project("alpha", migration_state: "hub_managed", workspace_root: Path.join(root, "workspaces/alpha"), port: 20_001)
        ])

      probe =
        HostServiceProbe.build(registry,
          config_root: Path.join(root, "config"),
          runtime_root: Path.join(root, "runtime"),
          deps:
            deps(%{
              systemctl_show: fn "symphony@alpha.service" ->
                {:ok, "Result=success\nLoadState=not-found\nActiveState=inactive\nSubState=dead\n"}
              end,
              systemctl_enabled: fn "symphony@alpha.service" -> {:ok, "not-found"} end,
              listening_ports: fn -> {:ok, []} end
            })
        )

      service = probe.projects["alpha"].legacy_service
      assert service.active == false
      assert service.enabled == "disabled"
      assert service.status == "inactive"

      summary = ActivationPreflight.build(registry, probe: probe)
      alpha = Enum.find(summary.projects, &(&1.project_id == "alpha"))

      assert alpha.status == "safe_to_manage"
      assert alpha.detected_legacy_ownership == []
      assert ActivationPreflight.safe_to_manage?(summary, "alpha", :poll)
    after
      File.rm_rf(root)
    end
  end

  test "probe failures become per-project unknown manual attention without leaking sensitive evidence" do
    root = tmp_root("host-service-probe-failures")
    config_root = Path.join(root, "config")
    alpha_dir = Path.join(config_root, "alpha")
    File.mkdir_p!(alpha_dir)

    File.write!(Path.join(alpha_dir, "env"), """
    SYMPHONY_PORT=20001
    SYMPHONY_LOGS_ROOT=#{Path.join(root, "logs/alpha")}
    GITHUB_TOKEN=ghp_secret
    AUTHORIZATION=Bearer secret
    """)

    registry =
      registry([
        project("alpha", migration_state: "hub_managed", workspace_root: Path.join(root, "workspaces/alpha"), port: 20_001),
        project("beta", migration_state: "hub_managed", scope_key: "memory:beta", workspace_root: Path.join(root, "workspaces/beta"), port: 20_002)
      ])

    probe =
      HostServiceProbe.build(registry,
        config_root: config_root,
        runtime_root: Path.join(root, "runtime"),
        deps:
          deps(%{
            read_file: fn path ->
              if String.ends_with?(path, "/env"), do: {:error, :eacces}, else: File.read(path)
            end,
            systemctl_show: fn _service -> {:ok, "ActiveState=raw systemctl output with ghp_secret\nResult=success\n"} end,
            systemctl_enabled: fn _service -> {:ok, "enabled with Bearer secret"} end,
            listening_ports: fn -> {:error, "ss failed with Bearer secret"} end
          })
      )

    summary = ActivationPreflight.build(registry, probe: probe)
    projects = Map.new(summary.projects, &{&1.project_id, &1})

    assert projects["alpha"].status == "unknown_manual_attention"
    assert projects["beta"].status == "unknown_manual_attention"
    assert projects["alpha"].blocked_operations == ["poll", "dispatch", "worker_start", "writeback"]
    assert projects["beta"].blocked_operations == ["poll", "dispatch", "worker_start", "writeback"]
    assert projects["alpha"].unknown_probe_results != []
    assert projects["beta"].unknown_probe_results != []

    safe_text = inspect({probe, summary})
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "Bearer secret"
    refute safe_text =~ "AUTHORIZATION"
    refute safe_text =~ Path.join(root, "logs/alpha")
    refute safe_text =~ "raw systemctl output"
    refute safe_text =~ "ss failed"

    File.rm_rf(root)
  end

  defp write_legacy_project!(config_root, project_id, opts) do
    project_dir = Path.join(config_root, project_id)
    File.mkdir_p!(project_dir)
    write_workflow_file!(Path.join(project_dir, "WORKFLOW.md"), opts)

    File.write!(Path.join(project_dir, "env"), """
    SYMPHONY_PORT=#{Keyword.fetch!(opts, :server_port)}
    SYMPHONY_LOGS_ROOT=#{Keyword.fetch!(opts, :logs_root)}
    SECRET_TOKEN=should-not-leak
    """)
  end

  defp registry(projects), do: %{projects: projects, warnings: [], errors: []}

  defp project(project_id, opts) do
    scope_key = Keyword.get(opts, :scope_key, "memory:#{project_id}")
    migration_state = Keyword.get(opts, :migration_state, "hub_ready")
    workspace_root = Keyword.get(opts, :workspace_root, "/private/workspaces/#{project_id}")
    port = Keyword.get(opts, :port, 20_001)

    %{
      project_id: project_id,
      name: String.capitalize(project_id),
      migration_state: migration_state,
      dispatch_enabled: true,
      paused: false,
      status: :ready,
      tracker_summary: %{
        kind: "memory",
        provider_scope_key: scope_key,
        provider_scope: %{namespace: project_id},
        required_labels: []
      },
      runtime_summary: %{
        workspace_root: workspace_root,
        runtime_state_path: "/private/state/#{project_id}.json",
        log_path: "/private/logs/#{project_id}.log",
        max_concurrent_agents: 2,
        max_concurrent_agents_by_state: %{},
        polling_interval_ms: 30_000,
        server_port: port
      },
      fingerprint: "#{project_id}-fp",
      loaded_at: ~U[2026-06-30 02:59:00Z],
      load_error: nil
    }
  end

  defp deps(overrides) do
    Map.merge(
      %{
        file_regular?: &File.regular?/1,
        file_dir?: &File.dir?/1,
        read_file: &File.read/1,
        systemctl_show: fn _service -> {:ok, "ActiveState=inactive\nSubState=dead\nResult=success\n"} end,
        systemctl_enabled: fn _service -> {:ok, "disabled"} end,
        listening_ports: fn -> {:ok, []} end
      },
      overrides
    )
  end

  defp tmp_root(name) do
    Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive, :monotonic])}")
  end
end
