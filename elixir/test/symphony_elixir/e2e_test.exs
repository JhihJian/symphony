defmodule SymphonyElixir.E2ETest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.E2ESupport
  alias SymphonyElixir.E2ESupport.GitHubTrackerDouble
  alias SymphonyElixir.E2ESupport.GitLabTrackerDouble

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
