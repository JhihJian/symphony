defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps =
      deps(%{
        file_regular?: fn _path ->
          send(parent, :file_checked)
          true
        end,
        set_workflow_file_path: fn _path ->
          send(parent, :workflow_set)
          :ok
        end,
        set_tracker_config_file_path: fn _path ->
          send(parent, :tracker_config_set)
          :ok
        end,
        set_logs_root: fn _path ->
          send(parent, :logs_root_set)
          :ok
        end,
        set_server_port_override: fn _port ->
          send(parent, :port_set)
          :ok
        end,
        ensure_all_started: fn ->
          send(parent, :started)
          {:ok, [:symphony_elixir]}
        end
      })

    assert {:error, banner} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :tracker_config_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "defaults to WORKFLOW.md when workflow path is missing" do
    deps =
      deps(%{
        file_regular?: fn path -> Path.basename(path) == "WORKFLOW.md" end,
        set_workflow_file_path: fn _path -> :ok end,
        set_tracker_config_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      })

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps =
      deps(%{
        file_regular?: fn path ->
          send(parent, {:workflow_checked, path})
          path == expanded_path
        end,
        set_workflow_file_path: fn path ->
          send(parent, {:workflow_set, path})
          :ok
        end,
        set_tracker_config_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      })

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps =
      deps(%{
        file_regular?: fn _path -> true end,
        set_workflow_file_path: fn _path -> :ok end,
        set_tracker_config_file_path: fn _path -> :ok end,
        set_logs_root: fn path ->
          send(parent, {:logs_root, path})
          :ok
        end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      })

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "accepts --tracker-config and passes an expanded tracker config path to runtime deps" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    tracker_config_path = "tmp/custom/TRACKER.yaml"
    expanded_workflow_path = Path.expand(workflow_path)
    expanded_tracker_config_path = Path.expand(tracker_config_path)

    deps =
      deps(%{
        file_regular?: fn path ->
          send(parent, {:checked, path})
          path in [expanded_workflow_path, expanded_tracker_config_path]
        end,
        set_workflow_file_path: fn path ->
          send(parent, {:workflow_set, path})
          :ok
        end,
        set_tracker_config_file_path: fn path ->
          send(parent, {:tracker_config_set, path})
          :ok
        end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      })

    assert :ok = CLI.evaluate([@ack_flag, "--tracker-config", tracker_config_path, workflow_path], deps)
    assert_received {:checked, ^expanded_workflow_path}
    assert_received {:checked, ^expanded_tracker_config_path}
    assert_received {:workflow_set, ^expanded_workflow_path}
    assert_received {:tracker_config_set, ^expanded_tracker_config_path}
  end

  test "returns not found when explicit tracker config file does not exist" do
    workflow_path = Path.expand("WORKFLOW.md")
    tracker_config_path = Path.expand("TRACKER.yaml")

    deps =
      deps(%{
        file_regular?: fn
          ^workflow_path -> true
          ^tracker_config_path -> false
        end,
        set_workflow_file_path: fn _path -> :ok end,
        set_tracker_config_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      })

    assert {:error, message} = CLI.evaluate([@ack_flag, "--tracker-config", "TRACKER.yaml", "WORKFLOW.md"], deps)
    assert message == "Tracker config file not found: #{tracker_config_path}"
  end

  test "returns not found when workflow file does not exist" do
    deps =
      deps(%{
        file_regular?: fn _path -> false end,
        set_workflow_file_path: fn _path -> :ok end,
        set_tracker_config_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      })

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps =
      deps(%{
        file_regular?: fn _path -> true end,
        set_workflow_file_path: fn _path -> :ok end,
        set_tracker_config_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:error, :boom} end
      })

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps =
      deps(%{
        file_regular?: fn _path -> true end,
        set_workflow_file_path: fn _path -> :ok end,
        set_tracker_config_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      })

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
  end

  test "legacy tracker config can still use default WORKFLOW.md path" do
    workflow_path = Path.expand("WORKFLOW.md")
    tracker_config_path = Path.expand("TRACKER.yaml")

    deps =
      deps(%{
        file_regular?: fn path -> path in [workflow_path, tracker_config_path] end,
        set_workflow_file_path: fn path ->
          send(self(), {:workflow_set, path})
          :ok
        end,
        set_tracker_config_file_path: fn path ->
          send(self(), {:tracker_config_set, path})
          :ok
        end
      })

    assert :ok = CLI.evaluate([@ack_flag, "--tracker-config", "TRACKER.yaml"], deps)
    assert_received {:workflow_set, ^workflow_path}
    assert_received {:tracker_config_set, ^tracker_config_path}
  end

  test "accepts --hub-config and starts without setting workflow or tracker config" do
    parent = self()
    hub_config_path = "tmp/hub/HUB.yaml"
    expanded_hub_config_path = Path.expand(hub_config_path)

    deps =
      deps(%{
        file_regular?: fn path ->
          send(parent, {:checked, path})
          path == expanded_hub_config_path
        end,
        set_workflow_file_path: fn path ->
          send(parent, {:workflow_set, path})
          :ok
        end,
        set_tracker_config_file_path: fn path ->
          send(parent, {:tracker_config_set, path})
          :ok
        end,
        set_hub_config_path: fn path ->
          send(parent, {:hub_config_set, path})
          :ok
        end,
        set_hub_scheduler_enabled: fn enabled? ->
          send(parent, {:hub_scheduler_set, enabled?})
          :ok
        end,
        set_hub_provider_executor: fn executor ->
          send(parent, {:hub_provider_executor_set, executor})
          :ok
        end,
        set_hub_activation_probe: fn opts ->
          send(parent, {:hub_activation_probe_set, opts})
          :ok
        end,
        validate_hub_config: fn path ->
          send(parent, {:hub_config_validated, path})
          :ok
        end,
        ensure_all_started: fn ->
          send(parent, :started)
          {:ok, [:symphony_elixir]}
        end
      })

    assert :ok = CLI.evaluate([@ack_flag, "--hub-config", hub_config_path], deps)
    assert_received {:checked, ^expanded_hub_config_path}
    assert_received {:hub_config_validated, ^expanded_hub_config_path}
    assert_received {:hub_config_set, ^expanded_hub_config_path}
    assert_received {:hub_scheduler_set, false}
    assert_received :started
    refute_received {:hub_provider_executor_set, _executor}
    refute_received {:hub_activation_probe_set, _opts}
    refute_received {:workflow_set, _path}
    refute_received {:tracker_config_set, _path}
  end

  test "accepts explicit hub scheduler opt-in only for hub mode" do
    parent = self()
    hub_config_path = "tmp/hub/HUB.yaml"
    expanded_hub_config_path = Path.expand(hub_config_path)

    deps =
      deps(%{
        file_regular?: fn path -> path == expanded_hub_config_path end,
        set_hub_config_path: fn _path -> :ok end,
        validate_hub_config: fn _path -> :ok end,
        set_hub_scheduler_enabled: fn enabled? ->
          send(parent, {:hub_scheduler_set, enabled?})
          :ok
        end
      })

    assert :ok = CLI.evaluate([@ack_flag, "--hub-config", hub_config_path, "--hub-scheduler"], deps)
    assert_received {:hub_scheduler_set, true}

    legacy_deps =
      deps(%{
        file_regular?: fn _path -> true end,
        set_hub_scheduler_enabled: fn enabled? ->
          send(parent, {:legacy_scheduler_set, enabled?})
          :ok
        end
      })

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], legacy_deps)
    refute_received {:legacy_scheduler_set, _enabled?}
  end

  test "accepts explicit hub host-service activation probe opt-in only for hub mode" do
    parent = self()
    hub_config_path = "tmp/hub/HUB.yaml"
    expanded_hub_config_path = Path.expand(hub_config_path)

    deps =
      deps(%{
        file_regular?: fn path -> path == expanded_hub_config_path end,
        set_hub_config_path: fn _path -> :ok end,
        validate_hub_config: fn _path -> :ok end,
        set_hub_activation_probe: fn opts ->
          send(parent, {:hub_activation_probe_set, opts})
          :ok
        end
      })

    assert :ok = CLI.evaluate([@ack_flag, "--hub-config", hub_config_path, "--hub-activation-probe", "host-service"], deps)
    assert_received {:hub_activation_probe_set, []}

    legacy_deps =
      deps(%{
        file_regular?: fn _path -> true end,
        set_hub_activation_probe: fn opts ->
          send(parent, {:legacy_hub_activation_probe_set, opts})
          :ok
        end
      })

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], legacy_deps)
    refute_received {:legacy_hub_activation_probe_set, _opts}
  end

  test "rejects unsupported hub activation probe mode" do
    deps = deps(%{})

    assert {:error, message} =
             CLI.evaluate([@ack_flag, "--hub-config", "HUB.yaml", "--hub-activation-probe", "auto-migrate"], deps)

    assert message =~ "Unsupported --hub-activation-probe"
    assert message =~ "host-service"
  end

  test "accepts explicit real hub provider candidate scan executor opt-in" do
    parent = self()
    hub_config_path = "tmp/hub/HUB.yaml"
    expanded_hub_config_path = Path.expand(hub_config_path)

    deps =
      deps(%{
        file_regular?: fn path -> path == expanded_hub_config_path end,
        set_hub_provider_executor: fn executor ->
          send(parent, {:hub_provider_executor_set, executor})
          :ok
        end,
        set_hub_config_path: fn _path -> :ok end,
        validate_hub_config: fn _path -> :ok end
      })

    assert :ok = CLI.evaluate([@ack_flag, "--hub-config", hub_config_path, "--hub-provider-executor", "real-candidate-scan"], deps)
    assert_received {:hub_provider_executor_set, SymphonyElixir.Hub.RealCandidateScanExecutor}

    legacy_deps =
      deps(%{
        file_regular?: fn _path -> true end,
        set_hub_provider_executor: fn executor ->
          send(parent, {:legacy_hub_provider_executor_set, executor})
          :ok
        end
      })

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], legacy_deps)
    refute_received {:legacy_hub_provider_executor_set, _executor}
  end

  test "accepts explicit real hub provider writeback executor opt-in" do
    parent = self()
    hub_config_path = "tmp/hub/HUB.yaml"
    expanded_hub_config_path = Path.expand(hub_config_path)

    deps =
      deps(%{
        file_regular?: fn path -> path == expanded_hub_config_path end,
        set_hub_provider_executor: fn executor ->
          send(parent, {:hub_provider_executor_set, executor})
          :ok
        end,
        set_hub_config_path: fn _path -> :ok end,
        validate_hub_config: fn _path -> :ok end
      })

    assert :ok = CLI.evaluate([@ack_flag, "--hub-config", hub_config_path, "--hub-provider-executor", "real-writeback"], deps)
    assert_received {:hub_provider_executor_set, SymphonyElixir.Hub.RealWritebackExecutor}
  end

  test "accepts explicit real hub worker starter opt-in" do
    parent = self()
    hub_config_path = "tmp/hub/HUB.yaml"
    expanded_hub_config_path = Path.expand(hub_config_path)

    deps =
      deps(%{
        file_regular?: fn path -> path == expanded_hub_config_path end,
        set_hub_worker_starter: fn starter ->
          send(parent, {:hub_worker_starter_set, starter})
          :ok
        end,
        set_hub_config_path: fn _path -> :ok end,
        validate_hub_config: fn _path -> :ok end
      })

    assert :ok = CLI.evaluate([@ack_flag, "--hub-config", hub_config_path, "--hub-worker-starter", "real"], deps)
    assert_received {:hub_worker_starter_set, SymphonyElixir.Hub.RealWorkerStarter}
  end

  test "rejects blank and missing hub config paths" do
    deps = deps(%{})

    assert {:error, "Hub config path must not be blank"} =
             CLI.evaluate([@ack_flag, "--hub-config", "   "], deps)

    assert {:error, message} = CLI.evaluate([@ack_flag, "--hub-config"], deps)
    assert message =~ "Usage: symphony"
  end

  test "rejects hub config with workflow positional path" do
    deps = deps(%{})

    assert {:error, message} =
             CLI.evaluate([@ack_flag, "--hub-config", "HUB.yaml", "WORKFLOW.md"], deps)

    assert message =~ "Do not pass a WORKFLOW.md path with --hub-config"
    assert message =~ "Usage: symphony"
  end

  defp deps(overrides) do
    Map.merge(
      %{
        file_regular?: fn _path -> true end,
        set_workflow_file_path: fn _path -> :ok end,
        set_tracker_config_file_path: fn _path -> :ok end,
        set_hub_config_path: fn _path -> :ok end,
        set_hub_provider_executor: fn _executor -> :ok end,
        set_hub_activation_probe: fn _opts -> :ok end,
        set_hub_scheduler_enabled: fn _enabled? -> :ok end,
        validate_hub_config: fn _path -> :ok end,
        set_hub_worker_starter: fn _starter -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      },
      overrides
    )
  end
end
