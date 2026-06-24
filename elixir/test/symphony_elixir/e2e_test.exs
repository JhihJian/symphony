defmodule SymphonyElixir.E2ETest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.E2ESupport
  alias SymphonyElixir.E2ESupport.GitHubTrackerDouble
  alias SymphonyElixir.E2ESupport.GitLabTrackerDouble

  test "memory tracker advances workflow stages inside one runner session" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-memory-stage-loop-e2e-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "fake-codex.trace")
      orchestrator_name = E2ESupport.unique_name("memory_stage_loop_e2e_orchestrator")

      issue = %Issue{
        id: "memory-stage-1",
        identifier: "MEM-STAGE-1",
        title: "Run memory issue through workflow stages",
        description: "Validate context check, implementation, validation, done.",
        state: "Context Check",
        labels: ["symphony-test"],
        blocked_by: [],
        assigned_to_worker: true,
        created_at: ~U[2026-06-08 00:00:00Z]
      }

      File.mkdir_p!(test_root)
      write_stage_loop_fake_codex!(codex_binary, trace_file)

      workflow_path = Workflow.workflow_file_path()
      tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

      File.write!(workflow_path, memory_stage_loop_workflow(workspace_root, codex_binary))
      File.write!(tracker_config_path, memory_stage_loop_tracker_config())
      Workflow.set_workflow_file_path(workflow_path)
      TrackerConfig.set_tracker_file_path(tracker_config_path)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator = start_supervised!({Orchestrator, name: orchestrator_name})
      send(orchestrator, :run_poll_cycle)

      assert_receive {:memory_tracker_stage_update, "memory-stage-1", "implementation", "Implementation"}, 1_000
      assert_receive {:memory_tracker_stage_update, "memory-stage-1", "validation", "Validation"}, 1_000
      assert_receive {:memory_tracker_stage_update, "memory-stage-1", "done", "Done"}, 1_000

      workspace = Path.join(workspace_root, "MEM-STAGE-1")
      trace = File.read!(trace_file)

      assert trace =~ "CWD:#{workspace}"
      assert length(Regex.scan(~r/^RUN$/m, trace)) == 1
      assert length(Regex.scan(~r/"method":"thread\/start"/, trace)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 3

      assert trace =~ "- id: context_check"
      assert trace =~ "- id: implementation"
      assert trace =~ "- id: validation"

      refute trace =~ "Continuation guidance:"
      assert_eventually(fn -> !File.exists?(workspace) end, 3_000)
    after
      File.rm_rf(test_root)
    end
  end

  test "memory tracker dispatches through orchestrator and exposes generic tracker tool writes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-memory-e2e-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "fake-codex.trace")
      orchestrator_name = E2ESupport.unique_name("memory_e2e_orchestrator")

      issue = %Issue{
        id: "memory-1",
        identifier: "MEM-1",
        title: "Run memory issue through e2e",
        description: "Validate deterministic local e2e.",
        state: "Todo",
        labels: ["symphony-test"],
        blocked_by: [],
        assigned_to_worker: true,
        created_at: ~U[2026-06-08 00:00:00Z]
      }

      File.mkdir_p!(test_root)

      write_fake_codex!(codex_binary, trace_file, "tracker_issue", %{
        "operation" => "set_status",
        "issueId" => "memory-1",
        "state" => "Done"
      })

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_required_labels: ["symphony-test"],
        tracker_active_states: ["Todo"],
        tracker_terminal_states: ["Done"],
        poll_interval_ms: 30_000,
        workspace_root: workspace_root,
        max_concurrent_agents: 1,
        max_turns: 1,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never",
        codex_turn_timeout_ms: 5_000,
        codex_stall_timeout_ms: 0,
        observability_enabled: false,
        prompt: "Complete {{ issue.identifier }} with generic tracker tooling."
      )

      orchestrator = start_supervised!({Orchestrator, name: orchestrator_name})
      send(orchestrator, :run_poll_cycle)

      assert_receive {:memory_tracker_state_update, "memory-1", "Done"}, 1_000

      workspace = Path.join(workspace_root, "MEM-1")
      trace = File.read!(trace_file)
      assert trace =~ "CWD:#{workspace}"
      assert trace =~ "\"name\":\"tracker_issue\""
    after
      File.rm_rf(test_root)
    end
  end

  test "GitHub issues-only tracker runs through orchestrator, Codex dynamic tools, workspace, and terminal state" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-github-e2e-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "fake-codex.trace")
      tracker_name = E2ESupport.unique_name("github_tracker_double")
      orchestrator_name = E2ESupport.unique_name("github_e2e_orchestrator")

      issue = %Issue{
        id: "42",
        identifier: "openai/symphony#42",
        title: "Run GitHub issue through e2e",
        description: "Validate tracker compatibility through the whole scheduler path.",
        state: "Todo",
        url: "https://github.com/openai/symphony/issues/42",
        labels: ["symphony-test"],
        blocked_by: [],
        assigned_to_worker: true,
        created_at: ~U[2026-06-08 00:00:00Z]
      }

      File.mkdir_p!(test_root)

      write_fake_codex!(codex_binary, trace_file, "github_issue", %{
        "operation" => "set_status",
        "issueId" => "42",
        "state" => "Done"
      })

      Application.put_env(:symphony_elixir, :github_client_module, GitHubTrackerDouble)
      Application.put_env(:symphony_elixir, :e2e_tracker_double, tracker_name)

      start_supervised!({GitHubTrackerDouble, name: tracker_name, issue: issue})

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_endpoint: "https://api.github.com/graphql",
        tracker_api_token: "github-token",
        tracker_owner: "openai",
        tracker_repo: "symphony",
        tracker_project_number: nil,
        tracker_required_labels: ["symphony-test"],
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Done", "Closed"],
        poll_interval_ms: 30_000,
        workspace_root: workspace_root,
        max_concurrent_agents: 1,
        max_turns: 1,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never",
        codex_turn_timeout_ms: 5_000,
        codex_stall_timeout_ms: 0,
        observability_enabled: false,
        prompt: "Complete {{ issue.identifier }} with GitHub issue tooling."
      )

      orchestrator = start_supervised!({Orchestrator, name: orchestrator_name})
      send(orchestrator, :run_poll_cycle)

      assert_eventually(fn ->
        GitHubTrackerDouble.issue(tracker_name).state == "Done"
      end)

      assert_eventually(
        fn ->
          snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
          snapshot.running == [] and snapshot.retrying == [] and snapshot.blocked == []
        end,
        3_000
      )

      workspace = Path.join(workspace_root, "openai_symphony_42")
      trace = File.read!(trace_file)
      assert trace =~ "CWD:#{workspace}"
      assert trace =~ "\"method\":\"turn/start\""
      refute File.exists?(workspace)

      assert {:update_issue_state, "42", "Done"} in GitHubTrackerDouble.events(tracker_name)
    after
      File.rm_rf(test_root)
    end
  end

  test "GitLab tracker runs through orchestrator, generic tracker tools, workspace, and terminal state" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-gitlab-e2e-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "fake-codex.trace")
      tracker_name = E2ESupport.unique_name("gitlab_tracker_double")
      orchestrator_name = E2ESupport.unique_name("gitlab_e2e_orchestrator")

      issue = %Issue{
        id: "gitlab:platform/symphony#7",
        identifier: "platform/symphony#7",
        title: "Run GitLab issue through e2e",
        description: "Validate GitLab tracker compatibility through the scheduler path.",
        state: "Todo",
        url: "https://gitlab.example.com/platform/symphony/-/issues/7",
        labels: ["symphony-test"],
        blocked_by: [],
        assigned_to_worker: true,
        created_at: ~U[2026-06-08 00:00:00Z]
      }

      File.mkdir_p!(test_root)

      write_fake_codex!(codex_binary, trace_file, "tracker_issue", %{
        "operation" => "set_status",
        "issueId" => "gitlab:platform/symphony#7",
        "state" => "Done"
      })

      Application.put_env(:symphony_elixir, :gitlab_client_module, GitLabTrackerDouble)
      Application.put_env(:symphony_elixir, :e2e_tracker_double, tracker_name)

      start_supervised!({GitLabTrackerDouble, name: tracker_name, issue: issue})

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "gitlab",
        tracker_endpoint: "https://gitlab.example.com/api/v4",
        tracker_api_token: "gitlab-token",
        tracker_project_slug: "platform/symphony",
        tracker_required_labels: ["symphony-test"],
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Done", "Closed"],
        poll_interval_ms: 30_000,
        workspace_root: workspace_root,
        max_concurrent_agents: 1,
        max_turns: 1,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never",
        codex_turn_timeout_ms: 5_000,
        codex_stall_timeout_ms: 0,
        observability_enabled: false,
        prompt: "Complete {{ issue.identifier }} with generic tracker tooling."
      )

      orchestrator = start_supervised!({Orchestrator, name: orchestrator_name})
      send(orchestrator, :run_poll_cycle)

      assert_eventually(fn ->
        GitLabTrackerDouble.issue(tracker_name).state == "Done"
      end)

      assert_eventually(
        fn ->
          snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
          snapshot.running == [] and snapshot.retrying == [] and snapshot.blocked == []
        end,
        3_000
      )

      workspace = Path.join(workspace_root, "platform_symphony_7")
      trace = File.read!(trace_file)
      assert trace =~ "CWD:#{workspace}"
      assert trace =~ "\"method\":\"turn/start\""
      refute File.exists?(workspace)

      assert {:update_issue_state, "gitlab:platform/symphony#7", "Done"} in GitLabTrackerDouble.events(tracker_name)
    after
      File.rm_rf(test_root)
    end
  end

  defp write_fake_codex!(path, trace_file, tool_name, arguments) do
    tool_call =
      Jason.encode!(%{
        "id" => 101,
        "method" => "item/tool/call",
        "params" => %{
          "name" => tool_name,
          "callId" => "call-e2e",
          "threadId" => "thread-e2e",
          "turnId" => "turn-e2e",
          "arguments" => arguments
        }
      })

    File.write!(path, """
    #!/bin/sh
    trace_file=#{shell_escape(trace_file)}
    printf 'CWD:%s\\n' "$(pwd -P)" >> "$trace_file"
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf '%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          ;;
        3)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-e2e"}}}'
          ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-e2e"}}}'
          printf '%s\\n' '#{tool_call}'
          ;;
        5)
          printf '%s\\n' '{"method":"turn/completed","params":{"usage":{"input_tokens":9,"output_tokens":4,"total_tokens":13}}}'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  defp write_stage_loop_fake_codex!(path, trace_file) do
    started_tool_call =
      stage_outcome_tool_call(101, "call-context", "turn-stage-1", "started", "Context check complete.")

    implemented_tool_call =
      stage_outcome_tool_call(102, "call-implementation", "turn-stage-2", "implemented", "Implementation complete.")

    validated_tool_call =
      stage_outcome_tool_call(103, "call-validation", "turn-stage-3", "validated", "Validation complete.")

    File.write!(path, """
    #!/bin/sh
    trace_file=#{shell_escape(trace_file)}
    printf 'CWD:%s\\n' "$(pwd -P)" >> "$trace_file"
    printf 'RUN\\n' >> "$trace_file"
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf '%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          ;;
        3)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-stage-loop"}}}'
          ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-stage-1"}}}'
          printf '%s\\n' '#{started_tool_call}'
          ;;
        5)
          printf '%s\\n' '{"method":"turn/completed","params":{"usage":{"input_tokens":9,"output_tokens":4,"total_tokens":13}}}'
          ;;
        6)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-stage-2"}}}'
          printf '%s\\n' '#{implemented_tool_call}'
          ;;
        7)
          printf '%s\\n' '{"method":"turn/completed","params":{"usage":{"input_tokens":8,"output_tokens":5,"total_tokens":13}}}'
          ;;
        8)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-stage-3"}}}'
          printf '%s\\n' '#{validated_tool_call}'
          ;;
        9)
          printf '%s\\n' '{"method":"turn/completed","params":{"usage":{"input_tokens":7,"output_tokens":6,"total_tokens":13}}}'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  defp stage_outcome_tool_call(id, call_id, turn_id, outcome, summary) do
    Jason.encode!(%{
      "id" => id,
      "method" => "item/tool/call",
      "params" => %{
        "tool" => "symphony_stage_outcome",
        "callId" => call_id,
        "threadId" => "thread-stage-loop",
        "turnId" => turn_id,
        "arguments" => %{"outcome" => outcome, "summary" => summary}
      }
    })
  end

  defp memory_stage_loop_workflow(workspace_root, codex_binary) do
    """
    ---
    workflow:
      start_stage: context_check
      terminal_stages: [done, blocked, protocol_blocked]
      outcomes: [started, implemented, validated, blocked]
      missing_outcome:
        max_retries: 1
        on_exhausted: protocol_blocked
      stages:
        context_check:
          prompt: Inspect context for {{ issue.identifier }}.
          transitions:
            started: implementation
            blocked: blocked
        implementation:
          prompt: Implement the accepted change.
          transitions:
            implemented: validation
            blocked: blocked
        validation:
          prompt: Validate the change.
          transitions:
            validated: done
            blocked: blocked
        done:
          prompt: Terminal completion stage.
          transitions: {}
        blocked:
          prompt: Terminal blocked stage.
          transitions: {}
        protocol_blocked:
          prompt: Terminal protocol blocked stage.
          transitions: {}
    workspace:
      root: #{yaml_value(workspace_root)}
    hooks:
      timeout_ms: 60000
    agent:
      max_concurrent_agents: 1
      max_turns: 5
    codex:
      command: #{yaml_value("#{codex_binary} app-server")}
      approval_policy: never
      turn_timeout_ms: 5000
      stall_timeout_ms: 0
    observability:
      dashboard_enabled: false
    ---
    """
  end

  defp memory_stage_loop_tracker_config do
    """
    tracker:
      kind: memory
      required_labels:
        - symphony-test
      stage_states:
        context_check:
          state: Context Check
        implementation:
          state: Implementation
        validation:
          state: Validation
        done:
          state: Done
          terminal: true
        blocked:
          state: Blocked
          terminal: true
        protocol_blocked:
          state: Protocol Blocked
          terminal: true
    """
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp assert_eventually(fun, timeout_ms \\ 1_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition did not become true before timeout")
      else
        Process.sleep(10)
        do_assert_eventually(fun, deadline)
      end
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
