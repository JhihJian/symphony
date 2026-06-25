defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.TrackerConfig
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          write_legacy_workflow_file!: 1,
          write_legacy_workflow_file!: 2,
          restore_env: 2,
          stop_default_http_server: 0
        ]

      setup do
        client_modules =
          SymphonyElixir.TestSupport.snapshot_app_env_keys([
            :linear_client_module,
            :github_client_module,
            :gitlab_client_module
          ])

        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        SymphonyElixir.TestSupport.ensure_application_started!()
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :tracker_config_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          Application.delete_env(:symphony_elixir, :e2e_tracker_double)
          SymphonyElixir.TestSupport.restore_app_env_keys(client_modules)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    unless Keyword.get(overrides, :skip_tracker_config_file, false) do
      tracker_config_path = Path.join(Path.dirname(path), "TRACKER.yaml")
      File.write!(tracker_config_path, tracker_content(overrides))
    end

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def write_legacy_workflow_file!(path, overrides \\ []) do
    workflow = legacy_workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def snapshot_app_env_keys(keys) when is_list(keys) do
    Enum.map(keys, &{&1, Application.fetch_env(:symphony_elixir, &1)})
  end

  def restore_app_env_keys(snapshots) when is_list(snapshots) do
    Enum.each(snapshots, fn
      {key, {:ok, value}} -> Application.put_env(:symphony_elixir, key, value)
      {key, :error} -> Application.delete_env(:symphony_elixir, key)
    end)
  end

  def ensure_application_started! do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Application.ensure_all_started(:symphony_elixir) do
          {:ok, _apps} -> :ok
          {:error, {:already_started, :symphony_elixir}} -> :ok
          {:error, reason} -> raise "failed to start symphony_elixir test application: #{inspect(reason)}"
        end
    end
  end

  def stop_default_http_server do
    ensure_application_started!()

    case Enum.find(supervisor_children(), fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        terminate_supervisor_child(SymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp supervisor_children do
    if Process.whereis(SymphonyElixir.Supervisor) do
      Supervisor.which_children(SymphonyElixir.Supervisor)
    else
      []
    end
  catch
    :exit, _reason -> []
  end

  defp terminate_supervisor_child(child_id) do
    if Process.whereis(SymphonyElixir.Supervisor) do
      Supervisor.terminate_child(SymphonyElixir.Supervisor, child_id)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          codex_command: "codex app-server",
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          workflow_start_stage: "ready",
          workflow_terminal_stages: ["done", "blocked", "protocol_blocked"],
          workflow_outcomes: ["started", "completed", "blocked"],
          workflow_missing_outcome_max_retries: 1,
          workflow_missing_outcome_on_exhausted: "protocol_blocked",
          workflow_stages: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    codex_command = Keyword.get(config, :codex_command)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    workflow_start_stage = Keyword.get(config, :workflow_start_stage)
    workflow_terminal_stages = Keyword.get(config, :workflow_terminal_stages)
    workflow_outcomes = Keyword.get(config, :workflow_outcomes)
    workflow_missing_outcome_max_retries = Keyword.get(config, :workflow_missing_outcome_max_retries)
    workflow_missing_outcome_on_exhausted = Keyword.get(config, :workflow_missing_outcome_on_exhausted)
    workflow_stages = Keyword.get(config, :workflow_stages) || default_workflow_stages()
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "workflow:",
        "  start_stage: #{yaml_value(workflow_start_stage)}",
        "  terminal_stages: #{yaml_value(workflow_terminal_stages)}",
        "  outcomes: #{yaml_value(workflow_outcomes)}",
        "  missing_outcome:",
        "    max_retries: #{yaml_value(workflow_missing_outcome_max_retries)}",
        "    on_exhausted: #{yaml_value(workflow_missing_outcome_on_exhausted)}",
        "  stages:",
        workflow_stages_yaml(workflow_stages),
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp legacy_workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_owner: nil,
          tracker_repo: nil,
          tracker_project_number: nil,
          tracker_project_status_field_name: "Status",
          tracker_assignee: nil,
          tracker_required_labels: [],
          tracker_state_label_prefix: nil,
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          prompt: @workflow_prompt
        ],
        overrides
      )

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(Keyword.get(config, :tracker_kind))}",
        "  endpoint: #{yaml_value(Keyword.get(config, :tracker_endpoint))}",
        "  api_key: #{yaml_value(Keyword.get(config, :tracker_api_token))}",
        "  project_slug: #{yaml_value(Keyword.get(config, :tracker_project_slug))}",
        "  owner: #{yaml_value(Keyword.get(config, :tracker_owner))}",
        "  repo: #{yaml_value(Keyword.get(config, :tracker_repo))}",
        "  project_number: #{yaml_value(Keyword.get(config, :tracker_project_number))}",
        "  project_status_field_name: #{yaml_value(Keyword.get(config, :tracker_project_status_field_name))}",
        "  assignee: #{yaml_value(Keyword.get(config, :tracker_assignee))}",
        "  required_labels: #{yaml_value(Keyword.get(config, :tracker_required_labels))}",
        "  state_label_prefix: #{yaml_value(Keyword.get(config, :tracker_state_label_prefix))}",
        "  active_states: #{yaml_value(Keyword.get(config, :tracker_active_states))}",
        "  terminal_states: #{yaml_value(Keyword.get(config, :tracker_terminal_states))}",
        "---",
        Keyword.get(config, :prompt)
      ]

    Enum.join(sections, "\n") <> "\n"
  end

  defp tracker_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_owner: nil,
          tracker_repo: nil,
          tracker_project_number: nil,
          tracker_project_status_field_name: "Status",
          tracker_assignee: nil,
          tracker_required_labels: [],
          tracker_state_label_prefix: nil,
          tracker_provider_states: [],
          tracker_workflow_state: nil,
          tracker_stage_states: nil,
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Done", "Blocked", "Protocol Blocked"]
        ],
        overrides
      )

    stage_states =
      Keyword.get(config, :tracker_stage_states) ||
        default_stage_states(config)

    [
      "tracker:",
      "  kind: #{yaml_value(Keyword.get(config, :tracker_kind))}",
      "  endpoint: #{yaml_value(Keyword.get(config, :tracker_endpoint))}",
      "  api_key: #{yaml_value(Keyword.get(config, :tracker_api_token))}",
      "  project_slug: #{yaml_value(Keyword.get(config, :tracker_project_slug))}",
      "  owner: #{yaml_value(Keyword.get(config, :tracker_owner))}",
      "  repo: #{yaml_value(Keyword.get(config, :tracker_repo))}",
      "  project_number: #{yaml_value(Keyword.get(config, :tracker_project_number))}",
      "  project_status_field_name: #{yaml_value(Keyword.get(config, :tracker_project_status_field_name))}",
      "  assignee: #{yaml_value(Keyword.get(config, :tracker_assignee))}",
      "  required_labels: #{yaml_value(Keyword.get(config, :tracker_required_labels))}",
      "  state_label_prefix: #{yaml_value(Keyword.get(config, :tracker_state_label_prefix))}",
      tracker_provider_states_yaml(Keyword.get(config, :tracker_provider_states)),
      tracker_workflow_state_yaml(Keyword.get(config, :tracker_workflow_state)),
      "  stage_states:",
      tracker_stage_states_yaml(stage_states)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp default_workflow_stages do
    %{
      "ready" => %{"prompt" => "Pick up new work.", "transitions" => %{"started" => "in_progress", "blocked" => "blocked"}},
      "in_progress" => %{"prompt" => "Implement the accepted scope.", "transitions" => %{"completed" => "done", "blocked" => "blocked"}},
      "done" => %{"prompt" => "Terminal done stage.", "transitions" => %{}},
      "blocked" => %{"prompt" => "Terminal blocked stage.", "transitions" => %{}},
      "protocol_blocked" => %{"prompt" => "Terminal protocol blocked stage.", "transitions" => %{}}
    }
  end

  defp default_stage_states(config) do
    if Keyword.get(config, :tracker_kind) == "github" and is_nil(Keyword.get(config, :tracker_project_number)) do
      github_issues_only_stage_states(config)
    else
      mapped_stage_states(
        Keyword.get(config, :tracker_active_states),
        Keyword.get(config, :tracker_terminal_states)
      )
    end
  end

  defp github_issues_only_stage_states(config) do
    running_states = state_list(Keyword.get(config, :tracker_active_states), ["Open"], "Open")
    terminal_states = state_list(Keyword.get(config, :tracker_terminal_states), ["Closed"], "Closed")
    open_state = Enum.at(running_states, 0) || "Open"
    closed_state = Enum.at(terminal_states, -1) || Enum.at(terminal_states, 0) || "Closed"

    %{
      "ready" => %{"state" => open_state},
      "in_progress" => %{"state" => open_state},
      "done" => %{"state" => closed_state, "terminal" => true},
      "blocked" => %{"state" => closed_state, "terminal" => true},
      "protocol_blocked" => %{"state" => closed_state, "terminal" => true}
    }
  end

  defp mapped_stage_states(running_states, terminal_states) do
    running_states = state_list(running_states, ["Todo", "In Progress"])
    terminal_states = state_list(terminal_states, ["Done", "Blocked", "Protocol Blocked"])

    %{
      "ready" => %{"state" => Enum.at(running_states, 0) || "Todo"},
      "in_progress" => %{"state" => Enum.at(running_states, 1) || Enum.at(running_states, 0) || "In Progress"},
      "done" => %{"state" => Enum.at(terminal_states, 0) || "Done", "terminal" => true},
      "blocked" => %{"state" => Enum.at(terminal_states, 1) || "Blocked", "terminal" => true},
      "protocol_blocked" => %{"state" => Enum.at(terminal_states, 2) || "Protocol Blocked", "terminal" => true}
    }
  end

  defp state_list(states, fallback) when is_list(states) do
    states
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> fallback
      values -> values
    end
  end

  defp state_list(_states, fallback), do: fallback

  defp state_list(states, fallback, allowed_state) when is_list(states) do
    states
    |> state_list(fallback)
    |> Enum.filter(&(String.downcase(&1) == String.downcase(allowed_state)))
    |> case do
      [] -> fallback
      values -> values
    end
  end

  defp state_list(_states, fallback, _allowed_state), do: fallback

  defp workflow_stages_yaml(stages) when is_map(stages) do
    stages
    |> Enum.map_join("\n", fn {stage, config} ->
      config = stringify_keys(config)

      [
        "    #{stage}:",
        "      prompt: #{yaml_value(Map.get(config, "prompt", ""))}",
        "      transitions: #{yaml_value(Map.get(config, "transitions", %{}))}"
      ]
      |> Enum.join("\n")
    end)
  end

  defp tracker_provider_states_yaml([]), do: nil
  defp tracker_provider_states_yaml(nil), do: nil
  defp tracker_provider_states_yaml(states), do: "  provider_states: #{yaml_value(states)}"

  defp tracker_workflow_state_yaml(nil), do: nil

  defp tracker_workflow_state_yaml(workflow_state) when is_map(workflow_state) do
    workflow_state
    |> map_to_indented_yaml(2)
    |> then(&"  workflow_state:\n#{&1}")
  end

  defp tracker_stage_states_yaml(stage_states) when is_map(stage_states) do
    stage_states
    |> Enum.map_join("\n", fn {stage, config} ->
      config = stringify_keys(config)

      [
        "    #{stage}:",
        "      state: #{yaml_value(Map.get(config, "state"))}",
        Map.has_key?(config, "terminal") && "      terminal: #{yaml_value(Map.get(config, "terminal"))}"
      ]
      |> Enum.reject(&(&1 in [nil, false]))
      |> Enum.join("\n")
    end)
  end

  defp map_to_indented_yaml(map, indent) when is_map(map) do
    spaces = String.duplicate(" ", indent)

    map
    |> stringify_keys()
    |> Enum.map_join("\n", fn {key, value} ->
      if is_map(value) do
        "#{spaces}#{key}:\n#{map_to_indented_yaml(value, indent + 2)}"
      else
        "#{spaces}#{key}: #{yaml_value(value)}"
      end
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
