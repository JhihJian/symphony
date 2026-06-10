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
             env_path: Path.join([config_root, "project-a", "env"]),
             runtime: %{codex_total_tokens: 1234, primary_rate_limit_remaining: 42}
           }

    assert project_b.status == "failed"
    assert project_b.tracker == %{kind: "gitlab", scope: "platform/group/repo", required_labels: ["symphony"]}
    assert project_b.counts == %{running: 0, retrying: 0, blocked: 0}
    assert project_b.health.status == "unreachable"
    assert project_b.health.summary == "state API unreachable; service failed"
    assert project_b.health.error =~ "econnrefused"
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

    File.write!(env_path, "SYMPHONY_PORT=#{port}\nSYMPHONY_LOGS_ROOT=#{logs_root}\n")
    File.write!(workflow_path, workflow_contents(tracker, workspace_root))

    service = "symphony@#{name}.service"
    status_by_service = Process.get(:status_by_service, %{})
    Process.put(:status_by_service, Map.put(status_by_service, service, Keyword.get(opts, :systemd, "inactive")))

    url = "http://127.0.0.1:#{port}/api/v1/state"
    state_by_url = Process.get(:state_by_url, %{})

    state_result =
      case Keyword.fetch(opts, :http_error) do
        {:ok, reason} -> {:error, reason}
        :error -> {:ok, Keyword.get(opts, :state, %{counts: %{running: 0, retrying: 0, blocked: 0}})}
      end

    Process.put(:state_by_url, Map.put(state_by_url, url, state_result))
  end

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

  defp temporary_root(prefix) do
    root = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end
end
