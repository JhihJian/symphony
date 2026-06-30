defmodule SymphonyElixir.InstanceRegistryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.InstanceRegistry

  test "discovers configured instances and isolates unreachable state APIs" do
    root = temporary_root("instance-registry-discovery")
    config_root = Path.join(root, "config")
    runtime_root = Path.join(root, "runtime")

    write_instance!(config_root, runtime_root, "project-a",
      port: 20_001,
      systemd: "active",
      state: %{
        counts: %{running: 2, retrying: 1, blocked: 0},
        rate_limits: %{"primary" => %{"remaining" => 42}},
        codex_totals: %{total_tokens: 1234}
      }
    )

    write_instance!(config_root, runtime_root, "project-b",
      port: 20_002,
      systemd: "failed",
      enabled: "disabled",
      strategy: "manual_restart",
      http_error: :econnrefused,
      tracker: %{kind: "gitlab", project_slug: "platform/group/repo"}
    )

    opts = registry_opts(config_root)

    assert {:ok, instances} = InstanceRegistry.list_instances(opts)
    assert Enum.map(instances, & &1.name) == ["project-a", "project-b"]

    assert [project_a, project_b] = instances

    assert project_a == %{
             name: "project-a",
             service: "symphony@project-a.service",
             status: "running",
             systemd: %{active: "active", enabled: "enabled", sub: "running", failed: false},
             port: 20_001,
             dashboard_url: "http://127.0.0.1:20001/",
             api_url: "http://127.0.0.1:20001/api/v1/state",
             tracker: %{kind: "github", scope: "acme/project-a", required_labels: ["symphony"]},
             counts: %{running: 2, retrying: 1, blocked: 0},
             health: %{
               status: "reachable",
               summary: "state API reachable; service running",
               error: nil
             },
             workspace_root: Path.join([runtime_root, "project-a", "workspaces"]),
             logs_root: Path.join([runtime_root, "project-a", "logs"]),
             config_path: Path.join([config_root, "project-a", "WORKFLOW.md"]),
             tracker_config_path: nil,
             env_path: Path.join([config_root, "project-a", "env"]),
             runtime: %{codex_total_tokens: 1234, primary_rate_limit_remaining: 42},
             strategy: "idle_restart"
           }

    assert project_b.status == "failed"
    assert project_b.systemd == %{active: "failed", enabled: "disabled", sub: "failed", failed: true}
    assert project_b.strategy == "manual_restart"
    assert project_b.tracker == %{kind: "gitlab", scope: "platform/group/repo", required_labels: ["symphony"]}
    assert project_b.counts == %{running: 0, retrying: 0, blocked: 0}
    assert project_b.health.status == "unreachable"
    assert project_b.health.summary == "state API unreachable; service failed"
    assert project_b.health.error =~ "econnrefused"
  end

  test "discovers systemd template services even before config exists" do
    root = temporary_root("instance-registry-systemd-discovery")
    config_root = Path.join(root, "config")
    File.mkdir_p!(config_root)

    owner = self()

    deps = %{
      list_services: fn -> {:ok, ["symphony@orphan.service", "not-symphony.service"]} end,
      systemctl_status: fn "symphony@orphan.service" -> {:ok, "active"} end,
      systemctl_show: fn "symphony@orphan.service" -> {:ok, %{active: "active", sub: "running", failed: false}} end,
      systemctl_enabled: fn "symphony@orphan.service" -> {:ok, "enabled"} end,
      http_get_state: fn _url ->
        send(owner, :unexpected_http_call)
        {:error, :missing_dashboard_url}
      end,
      systemctl_action: fn _action, _service -> :ok end
    }

    assert {:ok, [instance]} = InstanceRegistry.list_instances(config_root: config_root, deps: deps)
    assert instance.name == "orphan"
    assert instance.service == "symphony@orphan.service"
    assert instance.status == "running"
    assert instance.systemd == %{active: "active", enabled: "enabled", sub: "running", failed: false}
    assert instance.config_path == Path.join([config_root, "orphan", "WORKFLOW.md"])
    assert instance.tracker_config_path == nil
    assert instance.port == nil
    assert instance.dashboard_url == nil
    assert instance.counts == %{running: 0, retrying: 0, blocked: 0}
    refute_received :unexpected_http_call
  end

  test "discovers workflow-stage instances from sibling TRACKER.yaml" do
    root = temporary_root("instance-registry-two-file-discovery")
    config_root = Path.join(root, "config")
    runtime_root = Path.join(root, "runtime")

    write_stage_instance!(config_root, runtime_root, "project-stage", port: 20_003)

    assert {:ok, [instance]} = InstanceRegistry.list_instances(registry_opts(config_root))

    assert instance.name == "project-stage"
    assert instance.tracker == %{kind: "github", scope: "acme/project-stage", required_labels: ["symphony", "triage"]}
    assert instance.workspace_root == Path.join([runtime_root, "project-stage", "workspaces"])
    assert instance.tracker_config_path == Path.join([config_root, "project-stage", "TRACKER.yaml"])
    assert instance.dashboard_url == "http://127.0.0.1:20003/"
  end

  test "install script smoke writes WORKFLOW.md, TRACKER.yaml and tracker-aware unit" do
    root = temporary_root("instance-registry-install-script-smoke")
    source_root = Path.join(root, "source")
    origin_root = Path.join(root, "origin.git")
    config_root = Path.join(root, "config")
    runtime_root = Path.join(root, "runtime")
    home = Path.join(root, "home")

    File.mkdir_p!(Path.join(source_root, "elixir/bin"))
    File.mkdir_p!(Path.join(source_root, "scripts"))
    File.mkdir_p!(home)
    File.write!(Path.join([source_root, "elixir", "bin", "symphony"]), "#!/bin/sh\n")
    File.write!(Path.join([source_root, "scripts", "update-systemd-template.sh"]), "#!/bin/sh\n")
    File.chmod!(Path.join([source_root, "elixir", "bin", "symphony"]), 0o755)
    File.chmod!(Path.join([source_root, "scripts", "update-systemd-template.sh"]), 0o755)
    System.cmd("git", ["-C", source_root, "init", "-b", "main"], stderr_to_stdout: true)
    System.cmd("git", ["-C", source_root, "config", "user.name", "Test User"], stderr_to_stdout: true)
    System.cmd("git", ["-C", source_root, "config", "user.email", "test@example.com"], stderr_to_stdout: true)
    System.cmd("git", ["-C", source_root, "add", "."], stderr_to_stdout: true)
    System.cmd("git", ["-C", source_root, "commit", "-m", "initial"], stderr_to_stdout: true)
    System.cmd("git", ["init", "--bare", origin_root], stderr_to_stdout: true)
    System.cmd("git", ["-C", source_root, "remote", "add", "origin", origin_root], stderr_to_stdout: true)
    System.cmd("git", ["-C", source_root, "push", "-u", "origin", "main"], stderr_to_stdout: true)

    install_script = Path.expand("../../../scripts/install-systemd-template.sh", __DIR__)

    {output, 0} =
      System.cmd(
        install_script,
        [
          "--project",
          "project-a",
          "--owner",
          "acme",
          "--repo",
          "project-a",
          "--project-number",
          "14",
          "--token",
          "test-token",
          "--port",
          "20042",
          "--config-root",
          config_root,
          "--runtime-root",
          runtime_root,
          "--source-root",
          source_root,
          "--stage-state",
          "ready=Ready",
          "--stage-state",
          "in_progress=Implementation",
          "--stage-state",
          "human_review=Review",
          "--stage-state",
          "rework=Rework",
          "--stage-state",
          "merging=Merging",
          "--terminal-stage-state",
          "done=Done",
          "--terminal-stage-state",
          "blocked=Blocked",
          "--terminal-stage-state",
          "protocol_blocked=Protocol Blocked",
          "--label",
          "symphony",
          "--label",
          "triage",
          "--no-systemd",
          "--no-start",
          "--skip-build"
        ],
        env: [{"HOME", home}, {"GITHUB_TOKEN", "env-token"}],
        stderr_to_stdout: true
      )

    workflow_path = Path.join([config_root, "project-a", "WORKFLOW.md"])
    tracker_config_path = Path.join([config_root, "project-a", "TRACKER.yaml"])
    unit_path = Path.join([home, ".config", "systemd", "user", "symphony@.service"])

    assert output =~ "Installed Symphony project instance: project-a"
    assert output =~ workflow_path
    assert output =~ tracker_config_path

    assert File.exists?(workflow_path)
    assert File.exists?(tracker_config_path)
    assert File.exists?(unit_path)

    workflow = File.read!(workflow_path)
    refute workflow =~ "tracker:"
    refute workflow =~ "Project v2"
    assert workflow =~ "tracker issue"

    assert {:ok, tracker_config} = TrackerConfig.load(tracker_config_path)
    assert tracker_config["tracker"]["kind"] == "github"
    assert tracker_config["tracker"]["api_key"] == "$GITHUB_TOKEN"
    assert tracker_config["tracker"]["owner"] == "acme"
    assert tracker_config["tracker"]["repo"] == "project-a"
    assert tracker_config["tracker"]["project_number"] == 14
    assert tracker_config["tracker"]["workflow_state"]["strategy"] == "project_v2_status"
    assert tracker_config["tracker"]["workflow_state"]["field_name"] == "Status"
    assert tracker_config["tracker"]["required_labels"] == ["symphony", "triage"]
    assert tracker_config["tracker"]["stage_states"]["in_progress"]["state"] == "Implementation"
    assert tracker_config["tracker"]["stage_states"]["done"]["terminal"] == true
    assert tracker_config["server"]["host"] == "0.0.0.0"
    assert tracker_config["workspace"]["root"] == Path.join([runtime_root, "project-a", "workspaces"])
    assert tracker_config["hooks"]["after_create"] =~ "git clone --depth 1 https://github.com/acme/project-a ."
    assert tracker_config["agent"]["max_concurrent_agents"] == 2
    assert tracker_config["codex"]["turn_sandbox_policy"]["networkAccess"] == true

    unit = File.read!(unit_path)
    assert unit =~ "--tracker-config #{config_root}/%i/TRACKER.yaml #{config_root}/%i/WORKFLOW.md"
  end

  test "two-file discovery ignores invalid tracker stage mappings" do
    root = temporary_root("instance-registry-invalid-stage-mapping")
    config_root = Path.join(root, "config")
    runtime_root = Path.join(root, "runtime")

    write_stage_instance!(config_root, runtime_root, "project-stage", port: 20_003)

    File.write!(Path.join([config_root, "project-stage", "TRACKER.yaml"]), """
    tracker:
      kind: memory
      stage_states:
        ready:
          state: Ready
    server:
      host: 127.0.0.1
    workspace:
      root: #{Path.join([runtime_root, "project-stage", "workspaces"])}
    """)

    assert {:ok, [instance]} = InstanceRegistry.list_instances(registry_opts(config_root))

    assert instance.tracker == %{kind: nil, scope: nil, required_labels: []}
    assert instance.workspace_root == nil
    assert instance.tracker_config_path == Path.join([config_root, "project-stage", "TRACKER.yaml"])
  end

  test "lifecycle actions call systemd user services and surface failures" do
    root = temporary_root("instance-registry-actions")
    config_root = Path.join(root, "config")
    runtime_root = Path.join(root, "runtime")
    write_instance!(config_root, runtime_root, "project-a", port: 20_001)

    owner = self()

    deps = %{
      systemctl_status: fn _service -> {:ok, "inactive"} end,
      http_get_state: fn _url -> {:error, :offline} end,
      systemctl_action: fn action, service ->
        send(owner, {:systemctl_action, action, service})
        :ok
      end
    }

    opts = [config_root: config_root, deps: deps]

    assert {:ok, %{action: "start", service: "symphony@project-a.service"}} =
             InstanceRegistry.start_instance("project-a", opts)

    assert_receive {:systemctl_action, "start", "symphony@project-a.service"}

    assert {:ok, %{action: "stop", service: "symphony@project-a.service"}} =
             InstanceRegistry.stop_instance("project-a", opts)

    assert_receive {:systemctl_action, "stop", "symphony@project-a.service"}

    assert {:ok, %{action: "restart", service: "symphony@project-a.service"}} =
             InstanceRegistry.restart_instance("project-a", opts)

    assert_receive {:systemctl_action, "restart", "symphony@project-a.service"}
  end

  test "create instance delegates to install script with allocated port and redacts output" do
    root = temporary_root("instance-registry-create")
    config_root = Path.join(root, "config")
    runtime_root = Path.join(root, "runtime")
    source_root = Path.join(root, "source")
    install_script = Path.join([source_root, "scripts", "install-systemd-template.sh"])
    File.mkdir_p!(Path.dirname(install_script))
    File.write!(install_script, "#!/bin/sh\n")

    write_instance!(config_root, runtime_root, "project-a", port: 20_000)

    owner = self()

    deps = %{
      list_services: fn -> {:ok, []} end,
      listening_ports: fn -> {:ok, [20_001]} end,
      run_install_script: fn ^install_script, args, env ->
        send(owner, {:install_script, args, env})
        write_instance!(config_root, runtime_root, "project-b", port: 20_002)
        {:ok, "Installed\nGITHUB_TOKEN=plain-secret\nraw plain-secret\n"}
      end,
      systemctl_status: fn _service -> {:ok, "inactive"} end,
      systemctl_show: fn _service -> {:ok, %{active: "inactive", sub: "dead", failed: false}} end,
      systemctl_enabled: fn _service -> {:ok, "disabled"} end,
      http_get_state: fn _url -> {:error, :offline} end,
      systemctl_action: fn _action, _service -> :ok end
    }

    opts = [
      config_root: config_root,
      runtime_root: runtime_root,
      source_root: source_root,
      install_script: install_script,
      deps: deps
    ]

    params = %{
      "project" => "project-b",
      "tracker_kind" => "github",
      "owner" => "acme",
      "repo" => "project-b",
      "project_number" => "14",
      "token" => "plain-secret",
      "port" => "",
      "start" => "false",
      "auto_update" => "true",
      "update_strategy" => "manual_restart"
    }

    assert {:ok, %{instance: instance, output: output}} = InstanceRegistry.create_instance(params, opts)
    assert instance.name == "project-b"
    assert instance.port == 20_002
    assert output == "Installed\nGITHUB_TOKEN=[REDACTED]\nraw [REDACTED]\n"

    assert_receive {:install_script, args, [{"GITHUB_TOKEN", "plain-secret"}]}
    assert "--project" in args
    assert Enum.slice(args, Enum.find_index(args, &(&1 == "--project")), 2) == ["--project", "project-b"]
    assert Enum.slice(args, Enum.find_index(args, &(&1 == "--port")), 2) == ["--port", "20002"]
    assert "--no-start" in args
    assert "--auto-update" in args
    assert Enum.slice(args, Enum.find_index(args, &(&1 == "--update-strategy")), 2) == ["--update-strategy", "manual_restart"]
  end

  test "create instance rejects unsafe input, duplicate names and used ports" do
    root = temporary_root("instance-registry-create-errors")
    config_root = Path.join(root, "config")
    runtime_root = Path.join(root, "runtime")
    source_root = Path.join(root, "source")
    install_script = Path.join([source_root, "scripts", "install-systemd-template.sh"])
    File.mkdir_p!(Path.dirname(install_script))
    File.write!(install_script, "#!/bin/sh\n")
    write_instance!(config_root, runtime_root, "project-a", port: 20_001)

    owner = self()

    deps = %{
      list_services: fn -> {:ok, ["symphony@project-a.service"]} end,
      listening_ports: fn -> {:ok, [20_002]} end,
      run_install_script: fn _script, _args, _env ->
        send(owner, :unexpected_install)
        {:ok, ""}
      end
    }

    opts = [
      config_root: config_root,
      runtime_root: runtime_root,
      source_root: source_root,
      install_script: install_script,
      deps: deps
    ]

    base = %{
      "project" => "project-b",
      "tracker_kind" => "github",
      "owner" => "acme",
      "repo" => "project-b",
      "project_number" => "14",
      "token_env" => "",
      "port" => "20003"
    }

    assert {:error, %{code: "invalid_instance_name"}} =
             InstanceRegistry.create_instance(%{base | "project" => "../bad"}, opts)

    assert {:error, %{code: "instance_exists"}} =
             InstanceRegistry.create_instance(%{base | "project" => "project-a"}, opts)

    assert {:error, %{code: "port_in_use"}} =
             InstanceRegistry.create_instance(%{base | "port" => "20001"}, opts)

    assert {:error, %{code: "port_in_use"}} =
             InstanceRegistry.create_instance(%{base | "port" => "20002"}, opts)

    assert {:error, %{code: "unsupported_tracker_kind"}} =
             InstanceRegistry.create_instance(%{base | "tracker_kind" => "linear"}, opts)

    refute_received :unexpected_install
  end

  test "reads recent logs with token redaction and controls update timer" do
    owner = self()

    deps = %{
      journalctl_logs: fn service, lines ->
        send(owner, {:journalctl_logs, service, lines})
        {:ok, "boot\nGITHUB_TOKEN=ghp_secret\n--token ghp_secret\n"}
      end,
      systemctl_status: fn service ->
        send(owner, {:systemctl_status, service})
        {:ok, "inactive"}
      end,
      systemctl_show: fn
        "symphony-update.timer" ->
          {:ok,
           %{
             active: "active",
             sub: "waiting",
             next_run: "Wed 2026-06-17 10:00:00 CST",
             last_trigger: "Wed 2026-06-17 09:00:00 CST"
           }}

        "symphony-update.service" ->
          {:ok, %{active: "inactive", sub: "dead", failed: false}}
      end,
      systemctl_enabled: fn service ->
        send(owner, {:systemctl_enabled, service})
        {:ok, "enabled"}
      end,
      systemctl_action: fn action, service ->
        send(owner, {:systemctl_action, action, service})
        :ok
      end
    }

    opts = [deps: deps]

    assert {:ok, %{service: "symphony@project-a.service", logs: logs}} =
             InstanceRegistry.latest_logs("project-a", Keyword.put(opts, :lines, 20))

    assert logs =~ "GITHUB_TOKEN=[REDACTED]"
    assert logs =~ "--token [REDACTED]"
    refute logs =~ "ghp_secret"
    assert_receive {:journalctl_logs, "symphony@project-a.service", 20}

    assert InstanceRegistry.update_timer_status(opts) == %{
             timer: "symphony-update.timer",
             service: "symphony-update.service",
             active: "active",
             sub: "waiting",
             enabled: "enabled",
             next_run: "Wed 2026-06-17 10:00:00 CST",
             last_trigger: "Wed 2026-06-17 09:00:00 CST",
             service_active: "inactive",
             service_sub: "dead"
           }

    assert {:ok, %{action: "enable --now", service: "symphony-update.timer"}} =
             InstanceRegistry.enable_update_timer(opts)

    assert_receive {:systemctl_action, "enable --now", "symphony-update.timer"}

    assert {:ok, %{action: "disable --now", service: "symphony-update.timer"}} =
             InstanceRegistry.disable_update_timer(opts)

    assert_receive {:systemctl_action, "disable --now", "symphony-update.timer"}

    assert {:ok, %{action: "start", service: "symphony-update.service"}} =
             InstanceRegistry.trigger_update_service(opts)

    assert_receive {:systemctl_action, "start", "symphony-update.service"}
  end

  test "lifecycle rejects unsafe names and returns readable systemctl errors" do
    root = temporary_root("instance-registry-action-errors")
    config_root = Path.join(root, "config")
    runtime_root = Path.join(root, "runtime")
    write_instance!(config_root, runtime_root, "project-a", port: 20_001)

    owner = self()

    deps = %{
      systemctl_status: fn _service -> {:ok, "inactive"} end,
      http_get_state: fn _url -> {:error, :offline} end,
      systemctl_action: fn _action, _service ->
        send(owner, :unexpected_systemctl_call)
        {:error, %{exit_status: 1, output: "Unit not found"}}
      end
    }

    opts = [config_root: config_root, deps: deps]

    assert {:error, %{code: "invalid_instance_name", message: message}} =
             InstanceRegistry.start_instance("../project-a", opts)

    assert message =~ "letters, numbers"
    refute_received :unexpected_systemctl_call

    assert {:error, %{code: "systemctl_failed", message: message}} =
             InstanceRegistry.restart_instance("project-a", opts)

    assert message =~ "Failed to restart symphony@project-a.service"
    assert message =~ "Unit not found"
  end

  defp registry_opts(config_root) do
    state_by_url = Process.get(:state_by_url, %{})
    status_by_service = Process.get(:status_by_service, %{})

    [
      config_root: config_root,
      deps: %{
        systemctl_status: fn service -> Map.fetch(status_by_service, service) end,
        systemctl_show: fn service -> Map.fetch(show_by_service(), service) end,
        systemctl_enabled: fn service -> Map.fetch(enabled_by_service(), service) end,
        list_services: fn -> {:ok, Map.keys(status_by_service)} end,
        http_get_state: fn url -> Map.fetch!(state_by_url, url) end,
        systemctl_action: fn _action, _service -> :ok end
      }
    ]
  end

  defp write_instance!(config_root, runtime_root, name, opts) do
    project_config_root = Path.join(config_root, name)
    project_runtime_root = Path.join(runtime_root, name)
    workflow_path = Path.join(project_config_root, "WORKFLOW.md")
    env_path = Path.join(project_config_root, "env")
    logs_root = Path.join(project_runtime_root, "logs")
    workspace_root = Path.join(project_runtime_root, "workspaces")
    port = Keyword.fetch!(opts, :port)
    tracker = Keyword.get(opts, :tracker, %{kind: "github", owner: "acme", repo: name})

    File.mkdir_p!(project_config_root)
    File.mkdir_p!(logs_root)
    File.mkdir_p!(workspace_root)

    strategy = Keyword.get(opts, :strategy, "idle_restart")

    File.write!(
      env_path,
      "SYMPHONY_PORT=#{port}\nSYMPHONY_LOGS_ROOT=#{logs_root}\nSYMPHONY_UPDATE_STRATEGY=#{strategy}\n"
    )

    File.write!(workflow_path, workflow_contents(tracker, workspace_root))

    service = "symphony@#{name}.service"
    status_by_service = Process.get(:status_by_service, %{})
    Process.put(:status_by_service, Map.put(status_by_service, service, Keyword.get(opts, :systemd, "inactive")))

    enabled_by_service = enabled_by_service()
    Process.put(:enabled_by_service, Map.put(enabled_by_service, service, Keyword.get(opts, :enabled, "enabled")))

    show_by_service = show_by_service()

    systemd_status = Keyword.get(opts, :systemd, "inactive")
    default_sub = if systemd_status == "active", do: "running", else: systemd_status

    Process.put(
      :show_by_service,
      Map.put(show_by_service, service, %{
        active: systemd_status,
        sub: Keyword.get(opts, :sub, default_sub),
        failed: systemd_status == "failed"
      })
    )

    url = "http://127.0.0.1:#{port}/api/v1/state"
    state_by_url = Process.get(:state_by_url, %{})

    state_result =
      case Keyword.fetch(opts, :http_error) do
        {:ok, reason} -> {:error, reason}
        :error -> {:ok, Keyword.get(opts, :state, %{counts: %{running: 0, retrying: 0, blocked: 0}})}
      end

    Process.put(:state_by_url, Map.put(state_by_url, url, state_result))
  end

  defp write_stage_instance!(config_root, runtime_root, name, opts) do
    project_config_root = Path.join(config_root, name)
    project_runtime_root = Path.join(runtime_root, name)
    workflow_path = Path.join(project_config_root, "WORKFLOW.md")
    tracker_config_path = Path.join(project_config_root, "TRACKER.yaml")
    env_path = Path.join(project_config_root, "env")
    logs_root = Path.join(project_runtime_root, "logs")
    workspace_root = Path.join(project_runtime_root, "workspaces")
    port = Keyword.fetch!(opts, :port)

    File.mkdir_p!(project_config_root)
    File.mkdir_p!(logs_root)
    File.mkdir_p!(workspace_root)

    File.write!(
      env_path,
      "SYMPHONY_PORT=#{port}\nSYMPHONY_LOGS_ROOT=#{logs_root}\nSYMPHONY_UPDATE_STRATEGY=idle_restart\n"
    )

    File.write!(workflow_path, stage_workflow_contents())
    File.write!(tracker_config_path, stage_tracker_contents(name, workspace_root))

    service = "symphony@#{name}.service"
    Process.put(:status_by_service, Map.put(Process.get(:status_by_service, %{}), service, "active"))
    Process.put(:enabled_by_service, Map.put(enabled_by_service(), service, "enabled"))
    Process.put(:show_by_service, Map.put(show_by_service(), service, %{active: "active", sub: "running", failed: false}))

    url = "http://127.0.0.1:#{port}/api/v1/state"
    state_by_url = Process.get(:state_by_url, %{})
    Process.put(:state_by_url, Map.put(state_by_url, url, {:ok, %{counts: %{running: 0, retrying: 0, blocked: 0}}}))
  end

  defp enabled_by_service, do: Process.get(:enabled_by_service, %{})
  defp show_by_service, do: Process.get(:show_by_service, %{})

  defp workflow_contents(%{kind: "github"} = tracker, workspace_root) do
    """
    ---
    tracker:
      kind: github
      owner: #{Map.fetch!(tracker, :owner)}
      repo: #{Map.fetch!(tracker, :repo)}
      required_labels:
        - symphony
    server:
      host: 127.0.0.1
    workspace:
      root: #{workspace_root}
    ---
    Prompt
    """
  end

  defp workflow_contents(%{kind: "gitlab"} = tracker, workspace_root) do
    """
    ---
    tracker:
      kind: gitlab
      project_slug: #{Map.fetch!(tracker, :project_slug)}
      required_labels:
        - symphony
    server:
      host: 127.0.0.1
    workspace:
      root: #{workspace_root}
    ---
    Prompt
    """
  end

  defp stage_workflow_contents do
    """
    ---
    workflow:
      start_stage: ready
      terminal_stages: [done, blocked]
      outcomes: [started, completed, blocked]
      missing_outcome:
        max_retries: 3
        on_exhausted: blocked
      stages:
        ready:
          prompt: Ready.
          transitions:
            started: working
            blocked: blocked
        working:
          prompt: Work.
          transitions:
            completed: done
            blocked: blocked
        done:
          prompt: Done.
          transitions: {}
        blocked:
          prompt: Blocked.
          transitions: {}
    ---
    """
  end

  defp stage_tracker_contents(name, workspace_root) do
    """
    tracker:
      kind: github
      owner: acme
      repo: #{name}
      project_number: 14
      required_labels:
        - symphony
        - triage
      stage_states:
        ready:
          state: Ready
        working:
          state: In Progress
        done:
          state: Done
          terminal: true
        blocked:
          state: Blocked
          terminal: true
    server:
      host: 127.0.0.1
    workspace:
      root: #{workspace_root}
    """
  end

  defp temporary_root(prefix) do
    root = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end
end
