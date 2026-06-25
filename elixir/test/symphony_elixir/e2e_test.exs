defmodule SymphonyElixir.E2ETest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.E2ESupport
  alias SymphonyElixir.E2ESupport.GitHubTrackerDouble
  alias SymphonyElixir.E2ESupport.GitLabTrackerDouble

  test "#45 workflow-stage acceptance baseline advances stages inside one controlled fake provider runner session" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stage-acceptance-e2e-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "fake-codex.trace")
      workspace_trace_file = Path.join(test_root, "workspace.trace")
      tracker_name = E2ESupport.unique_name("stage_acceptance_tracker_double")
      orchestrator_name = E2ESupport.unique_name("stage_acceptance_e2e_orchestrator")

      issue = %Issue{
        id: "gitlab:platform/symphony#45",
        identifier: "platform/symphony#45",
        title: "Run fake provider issue through workflow stages",
        description: "Validate context check, implementation, validation, done.",
        state: "Context Check",
        url: "https://gitlab.example.com/platform/symphony/-/issues/45",
        labels: ["symphony-test"],
        blocked_by: [],
        assigned_to_worker: true,
        created_at: ~U[2026-06-08 00:00:00Z]
      }

      File.mkdir_p!(test_root)
      write_stage_sequence_fake_codex!(codex_binary, trace_file, ["started", "implemented", "validated"])

      workflow_path = Workflow.workflow_file_path()
      tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

      File.write!(
        workflow_path,
        stage_acceptance_workflow(workspace_root, codex_binary, workspace_trace_file: workspace_trace_file)
      )

      File.write!(tracker_config_path, stage_acceptance_tracker_config("gitlab"))
      Workflow.set_workflow_file_path(workflow_path)
      TrackerConfig.set_tracker_file_path(tracker_config_path)

      Application.put_env(:symphony_elixir, :gitlab_client_module, GitLabTrackerDouble)
      Application.put_env(:symphony_elixir, :e2e_tracker_double, tracker_name)

      start_supervised!({GitLabTrackerDouble, name: tracker_name, issue: issue})

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

      workspace = Path.join(workspace_root, "platform_symphony_45")
      trace = File.read!(trace_file)
      workspace_trace = File.read!(workspace_trace_file)

      assert trace =~ "CWD:#{workspace}"
      assert_runner_session_counts(trace, 3)
      assert String.split(String.trim(workspace_trace), "\n") == ["after_create", "before_remove"]

      assert trace =~ "# Symphony Stage Turn"
      assert trace =~ "- id: context_check"
      assert trace =~ "- id: implementation"
      assert trace =~ "- id: validation"
      assert trace =~ "Inspect context for platform/symphony#45 at Context Check."
      assert trace =~ "Implement platform/symphony#45 at Implementation."
      assert trace =~ "Validate platform/symphony#45 at Validation."
      assert trace =~ "\"enum\":[\"started\",\"implemented\",\"validated\",\"failed\",\"blocked\"]"

      events = GitLabTrackerDouble.events(tracker_name)

      assert provider_write_states(events) == ["Implementation", "Validation", "Done"]
      assert {:fetch_issues_by_states, ["Context Check"]} in events
      refute {:fetch_issues_by_states, ["Implementation"]} in events
      refute {:fetch_issues_by_states, ["Validation"]} in events

      refute trace =~ "Continuation guidance:"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "#45 workflow-stage acceptance baseline returns validation failure to implementation in one runner" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stage-failure-e2e-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "fake-codex.trace")
      orchestrator_name = E2ESupport.unique_name("stage_failure_e2e_orchestrator")

      issue =
        stage_acceptance_issue(
          id: "memory-stage-failure",
          identifier: "MEM-STAGE-FAILURE",
          title: "Return validation failure to implementation"
        )

      File.mkdir_p!(test_root)
      write_stage_sequence_fake_codex!(codex_binary, trace_file, ["started", "implemented", "failed", "implemented", "validated"])
      configure_memory_stage_acceptance!(workspace_root, codex_binary, [issue])

      orchestrator = start_supervised!({Orchestrator, name: orchestrator_name})
      send(orchestrator, :run_poll_cycle)

      assert_memory_stage_updates("memory-stage-failure", [
        {"implementation", "Implementation"},
        {"validation", "Validation"},
        {"implementation", "Implementation"},
        {"validation", "Validation"},
        {"done", "Done"}
      ])

      assert_eventually(
        fn ->
          snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
          snapshot.running == [] and snapshot.retrying == [] and snapshot.blocked == []
        end,
        3_000
      )

      trace = File.read!(trace_file)
      assert_runner_session_counts(trace, 5)
      refute trace =~ "Continuation guidance:"
    after
      File.rm_rf(test_root)
    end
  end

  test "#45 workflow-stage acceptance baseline moves context_check blocked outcome to blocked terminal stage" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stage-blocked-e2e-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "fake-codex.trace")
      orchestrator_name = E2ESupport.unique_name("stage_blocked_e2e_orchestrator")

      issue =
        stage_acceptance_issue(
          id: "memory-stage-blocked",
          identifier: "MEM-STAGE-BLOCKED",
          title: "Block during context check"
        )

      File.mkdir_p!(test_root)
      write_stage_sequence_fake_codex!(codex_binary, trace_file, ["blocked"])
      configure_memory_stage_acceptance!(workspace_root, codex_binary, [issue])

      orchestrator = start_supervised!({Orchestrator, name: orchestrator_name})
      send(orchestrator, :run_poll_cycle)

      assert_memory_stage_updates("memory-stage-blocked", [{"blocked", "Blocked"}])

      assert_eventually(
        fn ->
          snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
          snapshot.running == [] and snapshot.retrying == [] and snapshot.blocked == []
        end,
        3_000
      )

      trace = File.read!(trace_file)
      assert_runner_session_counts(trace, 1)
      refute trace =~ "Continuation guidance:"
    after
      File.rm_rf(test_root)
    end
  end

  test "#45 workflow-stage acceptance baseline sends missing outcomes to protocol_blocked after retry exhaustion" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stage-protocol-blocked-e2e-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "fake-codex.trace")
      orchestrator_name = E2ESupport.unique_name("stage_protocol_blocked_e2e_orchestrator")

      issue =
        stage_acceptance_issue(
          id: "memory-stage-protocol-blocked",
          identifier: "MEM-STAGE-PROTOCOL-BLOCKED",
          title: "Exhaust missing stage outcomes"
        )

      File.mkdir_p!(test_root)
      write_stage_sequence_fake_codex!(codex_binary, trace_file, [nil, nil])
      configure_memory_stage_acceptance!(workspace_root, codex_binary, [issue])

      orchestrator = start_supervised!({Orchestrator, name: orchestrator_name})
      send(orchestrator, :run_poll_cycle)

      assert_memory_stage_updates("memory-stage-protocol-blocked", [{"protocol_blocked", "Protocol Blocked"}])

      assert_eventually(
        fn ->
          snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
          snapshot.running == [] and snapshot.retrying == [] and snapshot.blocked == []
        end,
        3_000
      )

      trace = File.read!(trace_file)
      assert_runner_session_counts(trace, 2)
      assert length(Regex.scan(~r/^OUT:\{"method":"turn\/completed"/m, trace)) == 2
      refute trace =~ "\"method\":\"item/tool/call\""
      refute trace =~ "Continuation guidance:"
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

  defp write_stage_sequence_fake_codex!(path, trace_file, outcomes) do
    turn_cases =
      outcomes
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {outcome, turn_number} ->
        stage_turn_case(turn_number, outcome)
      end)

    File.write!(path, """
    #!/bin/sh
    trace_file=#{shell_escape(trace_file)}
    printf 'CWD:%s\\n' "$(pwd -P)" >> "$trace_file"
    printf 'RUN\\n' >> "$trace_file"
    turn=0
    max_turns=#{length(outcomes)}

    emit() {
      printf '%s\\n' "$1"
      printf 'OUT:%s\\n' "$1" >> "$trace_file"
    }

    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "$trace_file"

      case "$line" in
        *'"method":"initialize"'*)
          emit '{"id":1,"result":{}}'
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/start"'*)
          emit '{"id":2,"result":{"thread":{"id":"thread-stage-loop"}}}'
          ;;
        *'"method":"turn/start"'*)
          turn=$((turn + 1))

          case "$turn" in
    #{turn_cases}
          esac

          emit '{"method":"turn/completed","params":{"usage":{"input_tokens":9,"output_tokens":4,"total_tokens":13}}}'
          ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  defp stage_turn_case(turn_number, nil) do
    """
            #{turn_number})
              emit '{"id":3,"result":{"turn":{"id":"turn-stage-#{turn_number}"}}}'
              ;;
    """
  end

  defp stage_turn_case(turn_number, outcome) do
    tool_call =
      stage_outcome_tool_call(
        100 + turn_number,
        "call-stage-#{turn_number}",
        "turn-stage-#{turn_number}",
        outcome,
        "Stage #{turn_number} submitted #{outcome}."
      )

    """
            #{turn_number})
              emit '{"id":3,"result":{"turn":{"id":"turn-stage-#{turn_number}"}}}'
              emit '#{tool_call}'
              ;;
    """
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

  defp configure_memory_stage_acceptance!(workspace_root, codex_binary, issues) do
    workflow_path = Workflow.workflow_file_path()
    tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

    File.write!(workflow_path, stage_acceptance_workflow(workspace_root, codex_binary))
    File.write!(tracker_config_path, stage_acceptance_tracker_config("memory"))
    Workflow.set_workflow_file_path(workflow_path)
    TrackerConfig.set_tracker_file_path(tracker_config_path)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
  end

  defp stage_acceptance_issue(opts) do
    %Issue{
      id: Keyword.fetch!(opts, :id),
      identifier: Keyword.fetch!(opts, :identifier),
      title: Keyword.fetch!(opts, :title),
      description: "Validate #45 workflow-stage acceptance baseline branches.",
      state: "Context Check",
      labels: ["symphony-test"],
      blocked_by: [],
      assigned_to_worker: true,
      created_at: ~U[2026-06-08 00:00:00Z]
    }
  end

  defp stage_acceptance_workflow(workspace_root, codex_binary, opts \\ []) do
    workspace_trace_file = Keyword.get(opts, :workspace_trace_file)

    """
    ---
    workflow:
      start_stage: context_check
      terminal_stages: [done, blocked, protocol_blocked]
      outcomes: [started, implemented, validated, failed, blocked]
      missing_outcome:
        max_retries: 1
        on_exhausted: protocol_blocked
      stages:
        context_check:
          prompt: Inspect context for {{ issue.identifier }} at {{ issue.state }}.
          transitions:
            started: implementation
            blocked: blocked
        implementation:
          prompt: Implement {{ issue.identifier }} at {{ issue.state }}.
          transitions:
            implemented: validation
            blocked: blocked
        validation:
          prompt: Validate {{ issue.identifier }} at {{ issue.state }}.
          transitions:
            failed: implementation
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
    #{stage_acceptance_hooks_yaml(workspace_trace_file)}
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

  defp stage_acceptance_hooks_yaml(nil), do: "  timeout_ms: 60000"

  defp stage_acceptance_hooks_yaml(workspace_trace_file) do
    """
      timeout_ms: 60000
      after_create: |
        printf '%s\\n' after_create >> #{shell_escape(workspace_trace_file)}
      before_remove: |
        printf '%s\\n' before_remove >> #{shell_escape(workspace_trace_file)}
    """
    |> String.trim_trailing()
  end

  defp stage_acceptance_tracker_config(kind) do
    """
    tracker:
      kind: #{kind}
      endpoint: https://gitlab.example.com/api/v4
      api_key: token
      project_slug: platform/symphony
      required_labels:
        - symphony-test
      provider_states:
        - Context Check
        - Implementation
        - Validation
        - Done
        - Blocked
        - Protocol Blocked
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

  defp provider_write_states(events) do
    Enum.flat_map(events, fn
      {:update_issue_state, _issue_id, state} -> [state]
      _event -> []
    end)
  end

  defp assert_memory_stage_updates(issue_id, expected_updates) do
    Enum.each(expected_updates, fn {stage_id, provider_state} ->
      assert_receive {:memory_tracker_stage_update, ^issue_id, ^stage_id, ^provider_state}, 1_000
    end)

    refute_receive {:memory_tracker_stage_update, ^issue_id, _stage_id, _provider_state}, 100
  end

  defp assert_runner_session_counts(trace, turn_count) do
    assert length(Regex.scan(~r/^RUN$/m, trace)) == 1
    assert length(Regex.scan(~r/^CWD:/m, trace)) == 1
    assert length(Regex.scan(~r/"method":"thread\/start"/, trace)) == 1
    assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == turn_count
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
