defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.stage_states["ready"]["state"] == "Todo"
    assert config.tracker.stage_states["in_progress"]["state"] == "In Progress"
    assert config.tracker.stage_states["done"]["state"] == "Done"
    assert config.tracker.assignee == nil
    assert config.agent.max_turns == 20

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "current WORKFLOW.md file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.clear_workflow_file_path()

    assert {:ok, %{config: config, prompt: prompt, prompt_template: prompt_template}} = Workflow.load()
    assert is_map(config)

    refute Map.has_key?(config, "tracker")
    workflow = Map.fetch!(config, "workflow")
    assert workflow["start_stage"] == "ready"
    assert workflow["terminal_stages"] == ["done", "blocked", "protocol_blocked"]
    assert workflow["missing_outcome"]["on_exhausted"] == "protocol_blocked"
    assert workflow["stages"]["ready"]["prompt"] =~ "This is an unattended orchestration session."
    assert workflow["stages"]["ready"]["prompt"] =~ "### 完成摘要"
    assert prompt == ""
    assert prompt_template =~ "You are working on tracker issue"

    assert {:ok, tracker_config} = TrackerConfig.load(Path.expand("TRACKER.yaml", File.cwd!()))
    assert tracker_config["tracker"]["kind"] == "linear"
    assert is_binary(tracker_config["tracker"]["project_slug"])
    assert tracker_config["tracker"]["stage_states"]["ready"]["state"] == "Todo"

    settings = Config.settings!()
    assert settings.workflow["start_stage"] == "ready"
    assert settings.tracker.kind == "linear"
    assert settings.tracker.stage_states["in_progress"]["state"] == "In Progress"
    assert settings.workspace.root == "/data/dev/symphony/workspaces"
    assert settings.hooks.after_create =~ "git clone --depth 1 https://github.com/openai/symphony ."
    assert settings.hooks.before_remove =~ "cd elixir && mise exec -- mix workspace.before_remove"
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt_template
  end

  test "workflow-stage WORKFLOW.md and TRACKER.yaml load into runtime settings" do
    workflow_path = Workflow.workflow_file_path()
    tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

    File.write!(workflow_path, workflow_stage_file())

    File.write!(tracker_config_path, """
    tracker:
      kind: github
      api_key: token
      owner: JhihJian
      repo: symphony
      project_number: 50
      project_status_field_name: Status
      required_labels:
        - symphony
      stage_states:
        ready:
          state: Ready
        working:
          state: In Progress
        review:
          state: Human Review
        done:
          state: Done
          terminal: true
        blocked:
          state: Blocked
          terminal: true
        protocol_blocked:
          state: Protocol Blocked
          terminal: true
    """)

    Workflow.set_workflow_file_path(workflow_path)
    TrackerConfig.set_tracker_file_path(tracker_config_path)

    settings = Config.settings!()

    assert settings.workflow["start_stage"] == "ready"
    assert settings.workflow["terminal_stages"] == ["done", "blocked", "protocol_blocked"]
    assert settings.workflow["missing_outcome"] == %{"max_retries" => 2, "on_exhausted" => "protocol_blocked"}
    assert settings.workflow["stages"]["working"]["prompt"] == "Implement the accepted scope."
    assert settings.tracker.kind == "github"
    assert settings.tracker.owner == "JhihJian"
    assert settings.tracker.repo == "symphony"
    assert settings.tracker.project_number == 50
    assert settings.tracker.required_labels == ["symphony"]
    assert settings.tracker.stage_states["working"]["state"] == "In Progress"
    assert settings.tracker_config["tracker"]["stage_states"]["ready"]["state"] == "Ready"
    assert Config.workflow_prompt() == "Pick up new work."
    assert :ok = Config.validate!()

    File.write!(tracker_config_path, """
    tracker:
      kind: memory
      provider_states:
        - " Ready "
        - ""
        - In Progress
        - Human Review
        - Done
        - Blocked
        - Protocol Blocked
      stage_states:
        ready:
          state: Ready
        working:
          state: In Progress
        review:
          state: Human Review
        done:
          state: Done
          terminal: true
        blocked:
          state: Blocked
          terminal: true
        protocol_blocked:
          state: Protocol Blocked
          terminal: true
    """)

    assert Config.settings!().tracker.provider_states == [
             "Ready",
             "In Progress",
             "Human Review",
             "Done",
             "Blocked",
             "Protocol Blocked"
           ]
  end

  test "workflow-stage WORKFLOW.md defaults to sibling TRACKER.yaml when tracker path is not explicit" do
    workflow_path = Workflow.workflow_file_path()
    tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

    File.write!(workflow_path, workflow_stage_file())
    File.write!(tracker_config_path, memory_tracker_stage_config())

    Workflow.set_workflow_file_path(workflow_path)
    TrackerConfig.clear_tracker_file_path()

    assert Config.settings!().tracker.kind == "memory"
  end

  test "workflow-stage schema rejects unknown start stage" do
    File.write!(
      Workflow.workflow_file_path(),
      workflow_stage_file(%{start_stage: "missing"})
    )

    assert {:error, {:invalid_workflow_definition, message}} = Workflow.load()
    assert message =~ "workflow.start_stage"
    assert message =~ "unknown stage"
  end

  test "workflow-stage schema rejects empty terminal stages" do
    File.write!(
      Workflow.workflow_file_path(),
      workflow_stage_file(%{terminal_stages: []})
    )

    assert {:error, {:invalid_workflow_definition, message}} = Workflow.load()
    assert message =~ "workflow.terminal_stages must be a non-empty list"
  end

  test "workflow-stage schema rejects transition targets outside stages" do
    File.write!(
      Workflow.workflow_file_path(),
      workflow_stage_file(%{ready_transitions: %{accepted: "missing"}})
    )

    assert {:error, {:invalid_workflow_definition, message}} = Workflow.load()
    assert message =~ "workflow.stages.ready.transitions.accepted"
    assert message =~ "unknown stage"
  end

  test "workflow-stage schema rejects missing outcome exhausted target outside stages" do
    File.write!(
      Workflow.workflow_file_path(),
      workflow_stage_file(%{missing_outcome_on_exhausted: "missing"})
    )

    assert {:error, {:invalid_workflow_definition, message}} = Workflow.load()
    assert message =~ "workflow.missing_outcome.on_exhausted"
    assert message =~ "unknown stage"
  end

  test "workflow-stage schema rejects unknown transition outcomes" do
    File.write!(
      Workflow.workflow_file_path(),
      workflow_stage_file(%{ready_transitions: %{unknown: "working"}})
    )

    assert {:error, {:invalid_workflow_definition, message}} = Workflow.load()
    assert message =~ "workflow.stages.ready.transitions"
    assert message =~ "unknown outcome"
  end

  test "workflow-stage settings reject legacy tracker front matter with migration hint" do
    workflow_path = Workflow.workflow_file_path()
    tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

    File.write!(
      workflow_path,
      """
      ---
      tracker:
        kind: github
        active_states:
          - Ready
        terminal_states:
          - Done
      workflow:
        start_stage: ready
        terminal_stages: [done]
        outcomes: [accepted]
        missing_outcome:
          max_retries: 1
          on_exhausted: done
        stages:
          ready:
            prompt: Pick up new work.
            transitions:
              accepted: done
          done:
            prompt: Terminal stage.
            transitions: {}
      ---
      """
    )

    File.write!(tracker_config_path, memory_tracker_stage_config())
    Workflow.set_workflow_file_path(workflow_path)
    TrackerConfig.set_tracker_file_path(tracker_config_path)

    assert {:error, {:legacy_workflow_tracker_config, keys}} = Config.settings()
    assert "tracker.kind" in keys
    assert "tracker.active_states" in keys
    assert "tracker.terminal_states" in keys

    assert_raise ArgumentError, ~r/Move provider settings and stage-state mapping to TRACKER.yaml/, fn ->
      Config.settings!()
    end
  end

  test "workflow-stage settings reject missing stage-state mappings in TRACKER.yaml" do
    workflow_path = Workflow.workflow_file_path()
    tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

    File.write!(workflow_path, workflow_stage_file())

    File.write!(tracker_config_path, """
    tracker:
      kind: memory
      stage_states:
        ready:
          state: Ready
    """)

    Workflow.set_workflow_file_path(workflow_path)
    TrackerConfig.set_tracker_file_path(tracker_config_path)

    assert {:error, {:invalid_tracker_config, message}} = Config.settings()
    assert message =~ "TRACKER.yaml tracker.stage_states"
    assert message =~ "working"
    assert message =~ "done"
  end

  test "workflow-stage settings reject unknown stage-state mappings in TRACKER.yaml" do
    workflow_path = Workflow.workflow_file_path()
    tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

    File.write!(workflow_path, workflow_stage_file())

    File.write!(tracker_config_path, """
    tracker:
      kind: memory
      stage_states:
        ready:
          state: Ready
        working:
          state: In Progress
        review:
          state: Human Review
        done:
          state: Done
          terminal: true
        blocked:
          state: Blocked
          terminal: true
        typo_stage:
          state: Typo
    """)

    Workflow.set_workflow_file_path(workflow_path)
    TrackerConfig.set_tracker_file_path(tracker_config_path)

    assert {:error, {:invalid_tracker_config, message}} = Config.settings()
    assert message =~ "TRACKER.yaml tracker.stage_states"
    assert message =~ "unknown workflow stage keys"
    assert message =~ "typo_stage"

    refute message =~ "active_states"
  end

  test "workflow-state tracker config derives stage mappings for provider strategies" do
    workflow_path = Workflow.workflow_file_path()
    tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

    File.write!(workflow_path, workflow_stage_file())

    File.write!(tracker_config_path, """
    tracker:
      kind: github
      api_key: token
      owner: JhihJian
      repo: symphony
      project_number: 55
      workflow_state:
        strategy: project_v2_status
        field_name: Status
        state_options:
          ready: Context Check
          working: Implementation
          review: Validation
          done: Done
          blocked: Blocked
          protocol_blocked: Protocol Blocked
    """)

    Workflow.set_workflow_file_path(workflow_path)
    TrackerConfig.set_tracker_file_path(tracker_config_path)

    github_settings = Config.settings!()
    assert github_settings.tracker.project_status_field_name == "Status"
    assert github_settings.tracker.stage_states["ready"]["state"] == "Context Check"
    assert github_settings.tracker.stage_states["working"]["state"] == "Implementation"
    assert github_settings.tracker.stage_states["done"]["state"] == "Done"

    File.write!(tracker_config_path, """
    tracker:
      kind: gitlab
      api_key: token
      project_slug: platform/symphony
      workflow_state:
        strategy: scoped_label
        label_prefix: "status::"
        state_name_format: kebab_case
        close_on_terminal:
          - done
    """)

    gitlab_settings = Config.settings!()
    assert gitlab_settings.tracker.state_label_prefix == "status::"
    assert gitlab_settings.tracker.stage_states["ready"]["state"] == "status::ready"
    assert gitlab_settings.tracker.stage_states["protocol_blocked"]["state"] == "status::protocol-blocked"
  end

  test "orchestrator surfaces workflow-stage tracker config errors as configuration diagnostics" do
    workflow_path = Workflow.workflow_file_path()
    tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

    File.write!(workflow_path, workflow_stage_file())

    File.write!(tracker_config_path, """
    tracker:
      kind: memory
      stage_states:
        ready:
          state: Ready
        missing:
          state: Wrong
    """)

    Workflow.set_workflow_file_path(workflow_path)
    TrackerConfig.set_tracker_file_path(tracker_config_path)

    state = %Orchestrator.State{
      running: %{},
      blocked: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{},
      max_concurrent_agents: 1
    }

    log =
      capture_log(fn ->
        assert ^state = Orchestrator.maybe_dispatch_for_test(state)
      end)

    assert log =~ "Invalid TRACKER.yaml config"
    assert log =~ "unknown workflow stage keys"
    refute log =~ "Failed to fetch from tracker"
  end

  test "delivery guidance requires concise Chinese handoff summaries" do
    Workflow.clear_workflow_file_path()
    assert {:ok, %{prompt_template: prompt_template}} = Workflow.load()

    commit_skill = File.read!(Path.expand("../.codex/skills/commit/SKILL.md", File.cwd!()))
    push_skill = File.read!(Path.expand("../.codex/skills/push/SKILL.md", File.cwd!()))
    pr_template = File.read!(Path.expand("../.github/pull_request_template.md", File.cwd!()))

    assert prompt_template =~ "### 完成摘要"
    assert prompt_template =~ "详细执行过程继续保留"
    assert prompt_template =~ "详细日志不能替代完成摘要"

    assert commit_skill =~ "变更："
    assert commit_skill =~ "原因："
    assert commit_skill =~ "验证："
    assert commit_skill =~ "禁止非微小改动只有一行 commit message"

    assert push_skill =~ "## 变更说明"
    assert push_skill =~ "## 影响范围"
    assert push_skill =~ "## 风险与限制"
    assert push_skill =~ "Issue: <issue reference>"
    refute push_skill =~ "and `Linear: <issue id>`"
    refute push_skill =~ "# Linear: <issue id>"

    assert pr_template =~ "## 变更说明"
    assert pr_template =~ "## 影响范围"
    assert pr_template =~ "## 验证"
    assert pr_template =~ "## 风险与限制"
    assert pr_template =~ "Issue:"
    refute pr_template =~ "Linear: JIE-"
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "github config resolves defaults and validates required fields" do
    previous_github_token = System.get_env("GITHUB_TOKEN")
    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_github_token) end)
    System.put_env("GITHUB_TOKEN", "github-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_owner: "openai",
      tracker_repo: "symphony",
      tracker_project_number: 42
    )

    settings = Config.settings!()
    assert settings.tracker.endpoint == "https://api.github.com/graphql"
    assert settings.tracker.api_key == "github-token"
    assert settings.tracker.owner == "openai"
    assert settings.tracker.repo == "symphony"
    assert settings.tracker.project_number == 42
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_owner: "openai",
      tracker_repo: "symphony",
      tracker_project_number: nil
    )

    settings = Config.settings!()
    assert settings.tracker.project_number == nil
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: nil,
      tracker_repo: "symphony",
      tracker_project_number: 42
    )

    assert {:error, :missing_github_owner} = Config.validate!()
  end

  test "gitlab config resolves defaults and validates required fields" do
    previous_gitlab_token = System.get_env("GITLAB_TOKEN")
    previous_gitlab_assignee = System.get_env("GITLAB_ASSIGNEE")

    on_exit(fn ->
      restore_env("GITLAB_TOKEN", previous_gitlab_token)
      restore_env("GITLAB_ASSIGNEE", previous_gitlab_assignee)
    end)

    System.put_env("GITLAB_TOKEN", "gitlab-token")
    System.put_env("GITLAB_ASSIGNEE", "symphony-bot")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: nil,
      tracker_api_token: nil,
      tracker_project_slug: "platform/symphony",
      tracker_assignee: nil
    )

    settings = Config.settings!()
    assert settings.tracker.endpoint == "https://gitlab.com/api/v4"
    assert settings.tracker.api_key == "gitlab-token"
    assert settings.tracker.project_slug == "platform/symphony"
    assert settings.tracker.assignee == "symphony-bot"
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: nil,
      tracker_api_token: "gitlab-token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_gitlab_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_api_token: nil,
      tracker_project_slug: "platform/symphony"
    )

    restore_env("GITLAB_TOKEN", nil)
    assert {:error, :missing_gitlab_api_token} = Config.validate!()
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load preserves UTF-8 prompt content containing Chinese characters" do
    workflow_prompt = """
    2. 只在缺少必要权限、密钥或外部服务不可用时停止。
    3. 只在当前 workspace 内工作，不要修改 workspace 外的路径。
    """

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    assert {:ok, %{prompt: prompt}} = Workflow.load(Workflow.workflow_file_path())
    assert String.valid?(prompt)
    assert prompt =~ "必要权限"
    assert prompt =~ "当前 workspace 内工作"

    issue = %Issue{
      identifier: "GH-3",
      title: "将 Operations Dashboard 改为中文",
      description: "将 Operations Dashboard 改为中文",
      state: "Ready",
      url: "https://github.com/example/repo/issues/3",
      labels: ["enhancement", "symphony"]
    }

    rendered = PromptBuilder.build_prompt(issue)

    assert String.valid?(rendered)
    assert Jason.encode!(%{"text" => rendered})
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "unmapped provider state marks running agent stage conflict without cleanup" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      assert %{stage_conflict: conflict} = updated_state.running[issue_id]
      assert conflict.kind == :running
      assert conflict.provider_state == "Backlog"
      assert conflict.provider_stage == {:error, {:unmapped_provider_state, "Backlog"}}
      assert MapSet.member?(updated_state.claimed, issue_id)
      assert Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow-stage terminal provider stage stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stage-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-stage-terminal"
    issue_identifier = "MT-STAGE-556"
    workspace = Path.join(test_root, issue_identifier)

    try do
      workflow_path = Workflow.workflow_file_path()
      tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

      File.write!(workflow_path, workflow_stage_file(%{workspace_root: test_root}))
      File.write!(tracker_config_path, workflow_state_stage_config())
      Workflow.set_workflow_file_path(workflow_path)
      TrackerConfig.set_tracker_file_path(tracker_config_path)

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            current_stage: "working",
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Done",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow-stage canceled provider stage blocks running agent through terminal mapping" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stage-canceled-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-stage-canceled"
    issue_identifier = "MT-STAGE-559"
    workspace = Path.join(test_root, issue_identifier)

    try do
      workflow_path = Workflow.workflow_file_path()
      tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

      File.write!(
        workflow_path,
        workflow_stage_file(%{
          workspace_root: test_root
        })
      )

      File.write!(tracker_config_path, memory_tracker_stage_config_with_canceled_provider_state())
      Workflow.set_workflow_file_path(workflow_path)
      TrackerConfig.set_tracker_file_path(tracker_config_path)

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            current_stage: "working",
            workspace_path: workspace,
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Canceled",
        title: "Canceled",
        description: "Operator canceled",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      assert MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)

      assert %{
               current_stage: "protocol_blocked",
               issue: %Issue{state: "Canceled"},
               error: "provider workflow stage protocol_blocked is blocked terminal",
               recovery_artifact: %{available?: true}
             } = updated_state.blocked[issue_id]
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow-stage reconcile records provider and local stage conflicts without stopping worker" do
    workflow_path = Workflow.workflow_file_path()
    tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

    File.write!(workflow_path, workflow_stage_file())
    File.write!(tracker_config_path, memory_tracker_stage_config())
    Workflow.set_workflow_file_path(workflow_path)
    TrackerConfig.set_tracker_file_path(tracker_config_path)

    issue_id = "issue-stage-conflict"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-STAGE-557",
          issue: %Issue{id: issue_id, state: "In Progress", identifier: "MT-STAGE-557"},
          current_stage: "working",
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-STAGE-557",
      state: "Human Review",
      title: "Conflict",
      description: "Provider stage differs",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    assert %{current_stage: "working", stage_conflict: conflict} = updated_state.running[issue_id]
    assert conflict.kind == :running
    assert conflict.local_stage == "working"
    assert conflict.provider_stage == "review"
    assert conflict.provider_state == "Human Review"
    assert MapSet.member?(updated_state.claimed, issue_id)
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "reconcile stops running issue when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "issue-unlabeled"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-562",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-562",
            state: "In Progress",
            labels: ["symphony"]
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-562",
      state: "In Progress",
      title: "Opted out active issue",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "reconcile releases a blocked issue when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "blocked-unlabeled"

    state = %Orchestrator.State{
      blocked: %{
        issue_id => %{
          identifier: "MT-564",
          error: "operator input required",
          worker_host: nil
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-564",
      title: "Blocked but opted out",
      state: "In Progress",
      labels: []
    }

    updated_state = Orchestrator.reconcile_blocked_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.blocked, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
  end

  test "retry releases its claim when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "retry-unlabeled"

    state = %Orchestrator.State{
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-565",
      title: "Retry opted out",
      state: "In Progress",
      labels: []
    }

    updated_state =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, issue_id, 1, %{
        identifier: issue.identifier,
        error: "agent exited"
      })

    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
  end

  test "workflow-stage running retry keeps middle-stage issues recoverable without start-stage filter" do
    workflow_path = Workflow.workflow_file_path()
    tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

    File.write!(workflow_path, workflow_stage_file())
    File.write!(tracker_config_path, memory_tracker_stage_config())
    Workflow.set_workflow_file_path(workflow_path)
    TrackerConfig.set_tracker_file_path(tracker_config_path)

    issue_id = "issue-running-retry-working"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-RUNNING-RETRY",
      title: "Recover in-progress work",
      state: "In Progress",
      labels: []
    }

    state = %Orchestrator.State{
      max_concurrent_agents: 0,
      running: %{},
      claimed: MapSet.new([issue_id]),
      blocked: %{},
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    retry_window_start_ms = System.monotonic_time(:millisecond)

    updated_state =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, issue_id, 1, %{
        retry_kind: :running,
        identifier: issue.identifier,
        current_stage: "working",
        error: "stalled for 5000ms without codex activity",
        worker_host: "worker-a",
        workspace_path: "/workspaces/MT-RUNNING-RETRY",
        session_id: "thread-running-retry"
      })

    retry_window_end_ms = System.monotonic_time(:millisecond)

    assert MapSet.member?(updated_state.claimed, issue_id)
    refute Map.has_key?(updated_state.blocked, issue_id)

    assert %{
             attempt: 2,
             retry_kind: :running,
             identifier: "MT-RUNNING-RETRY",
             current_stage: "working",
             worker_host: "worker-a",
             workspace_path: "/workspaces/MT-RUNNING-RETRY",
             session_id: "thread-running-retry",
             due_at_ms: due_at_ms
           } = updated_state.retry_attempts[issue_id]

    assert_due_scheduled_after(due_at_ms, retry_window_start_ms, retry_window_end_ms, 20_000)
  end

  test "workflow-stage running retry releases terminal provider stages and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-running-retry-terminal-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-running-retry-terminal"
    issue_identifier = "MT-RUNNING-DONE"
    workspace = Path.join(test_root, issue_identifier)

    try do
      workflow_path = Workflow.workflow_file_path()
      tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

      File.write!(workflow_path, workflow_stage_file(%{workspace_root: test_root}))
      File.write!(tracker_config_path, workflow_state_stage_config())
      Workflow.set_workflow_file_path(workflow_path)
      TrackerConfig.set_tracker_file_path(tracker_config_path)

      File.mkdir_p!(workspace)

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Terminal during retry",
        state: "Done",
        labels: []
      }

      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new([issue_id]),
        blocked: %{},
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      updated_state =
        Orchestrator.handle_retry_issue_lookup_for_test(issue, state, issue_id, 1, %{
          retry_kind: :running,
          identifier: issue.identifier,
          current_stage: "working",
          error: "agent exited: :boom"
        })

      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Map.has_key?(updated_state.blocked, issue_id)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow-stage running retry blocks unreadable provider stages instead of orphaning claims" do
    workflow_path = Workflow.workflow_file_path()
    tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

    File.write!(workflow_path, workflow_stage_file())
    File.write!(tracker_config_path, memory_tracker_stage_config())
    Workflow.set_workflow_file_path(workflow_path)
    TrackerConfig.set_tracker_file_path(tracker_config_path)

    issue_id = "issue-running-retry-unmapped"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-RUNNING-UNMAPPED",
      title: "Unmapped retry state",
      state: "Mystery",
      labels: []
    }

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new([issue_id]),
      blocked: %{},
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    updated_state =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, issue_id, 3, %{
        retry_kind: :running,
        identifier: issue.identifier,
        current_stage: "working",
        error: "stalled for 5000ms without codex activity",
        worker_host: "worker-a",
        workspace_path: "/workspaces/MT-RUNNING-UNMAPPED",
        session_id: "thread-running-unmapped"
      })

    assert MapSet.member?(updated_state.claimed, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)

    assert %{
             identifier: "MT-RUNNING-UNMAPPED",
             current_stage: "working",
             worker_host: "worker-a",
             workspace_path: "/workspaces/MT-RUNNING-UNMAPPED",
             session_id: "thread-running-unmapped",
             retry_kind: :running,
             retry_attempt: 3,
             error: error,
             stage_conflict: %{
               kind: :running_retry,
               local_stage: "working",
               provider_stage: {:error, {:unmapped_provider_state, "Mystery"}},
               provider_state: "Mystery"
             }
           } = updated_state.blocked[issue_id]

    assert error =~ "stalled for 5000ms without codex activity"
    assert error =~ "recovery blocked"
  end

  test "workflow-stage running retry blocks provider stage conflicts instead of restarting the wrong stage" do
    workflow_path = Workflow.workflow_file_path()
    tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

    File.write!(workflow_path, workflow_stage_file())
    File.write!(tracker_config_path, memory_tracker_stage_config())
    Workflow.set_workflow_file_path(workflow_path)
    TrackerConfig.set_tracker_file_path(tracker_config_path)

    issue_id = "issue-running-retry-conflict"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-RUNNING-CONFLICT",
      title: "Conflicting retry state",
      state: "Human Review",
      labels: []
    }

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new([issue_id]),
      blocked: %{},
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    updated_state =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, issue_id, 2, %{
        retry_kind: :running,
        identifier: issue.identifier,
        current_stage: "working",
        error: "agent exited: :shutdown"
      })

    assert MapSet.member?(updated_state.claimed, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)

    assert %{
             identifier: "MT-RUNNING-CONFLICT",
             current_stage: "review",
             retry_kind: :running,
             retry_attempt: 2,
             stage_conflict: %{
               kind: :running_retry,
               local_stage: "working",
               provider_stage: "review",
               provider_state: "Human Review"
             }
           } = updated_state.blocked[issue_id]
  end

  test "normal worker exit on completion stage releases claim without active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    if is_reference(initial_state.tick_timer_ref) do
      Process.cancel_timer(initial_state.tick_timer_ref)
    end

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      current_stage: "done",
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
      |> Map.put(:tick_timer_ref, nil)
      |> Map.put(:tick_token, nil)
      |> Map.put(:next_poll_due_at_ms, nil)
      |> Map.put(:poll_check_in_progress, false)
      |> Map.put(:max_concurrent_agents, 0)
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    refute MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
  end

  test "workflow-stage normal exit on completion stage completes without continuation retry" do
    workflow_path = Workflow.workflow_file_path()
    tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

    File.write!(workflow_path, workflow_stage_file())
    File.write!(tracker_config_path, memory_tracker_stage_config())
    Workflow.set_workflow_file_path(workflow_path)
    TrackerConfig.set_tracker_file_path(tracker_config_path)

    issue_id = "issue-stage-retry-left-start"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :StageContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-STAGE-560",
      issue: %Issue{id: issue_id, identifier: "MT-STAGE-560", state: "Ready"},
      current_stage: "done",
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: issue_id,
        identifier: "MT-STAGE-560",
        title: "Moved to implementation",
        state: "In Progress",
        labels: []
      }
    ])

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)

    state = :sys.get_state(pid)

    assert MapSet.member?(state.completed, issue_id)
    refute MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    retry_window_start_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)
    retry_window_end_ms = System.monotonic_time(:millisecond)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_scheduled_after(due_at_ms, retry_window_start_ms, retry_window_end_ms, 40_000)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    retry_window_start_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)
    retry_window_end_ms = System.monotonic_time(:millisecond)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_scheduled_after(due_at_ms, retry_window_start_ms, retry_window_end_ms, 10_000)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-a"
  end

  defp assert_due_scheduled_after(due_at_ms, window_start_ms, window_end_ms, delay_ms) do
    assert due_at_ms >= window_start_ms + delay_ms
    assert due_at_ms <= window_end_ms + delay_ms
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp workflow_stage_file(overrides \\ %{}) do
    start_stage = Map.get(overrides, :start_stage, "ready")
    terminal_stages = Map.get(overrides, :terminal_stages, ["done", "blocked", "protocol_blocked"])
    ready_transitions = Map.get(overrides, :ready_transitions, %{accepted: "working"})
    missing_outcome_on_exhausted = Map.get(overrides, :missing_outcome_on_exhausted, "protocol_blocked")
    workspace_root = Map.get(overrides, :workspace_root)
    workspace_block = if is_binary(workspace_root), do: "workspace:\n  root: #{yaml_value(workspace_root)}\n", else: ""

    """
    ---
    workflow:
      start_stage: #{yaml_value(start_stage)}
      terminal_stages: #{yaml_value(terminal_stages)}
      outcomes: [accepted, needs_review, completed, blocked]
      missing_outcome:
        max_retries: 2
        on_exhausted: #{yaml_value(missing_outcome_on_exhausted)}
      stages:
        ready:
          prompt: Pick up new work.
          transitions: #{yaml_value(ready_transitions)}
        working:
          prompt: Implement the accepted scope.
          transitions:
            needs_review: review
            completed: done
            blocked: blocked
        review:
          prompt: Prepare validated work for review.
          transitions:
            completed: done
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
    #{workspace_block}
    ---
    """
  end

  defp runner_stage_workflow_file(workspace_root, codex_binary, template_repo) do
    """
    ---
    workflow:
      start_stage: ready
      terminal_stages: [done, blocked, protocol_blocked]
      outcomes: [accepted, completed, blocked]
      missing_outcome:
        max_retries: 2
        on_exhausted: protocol_blocked
      stages:
        ready:
          prompt: Pick up new work.
          transitions:
            accepted: working
            blocked: blocked
        working:
          prompt: Implement the accepted scope.
          transitions:
            completed: done
            blocked: blocked
        review:
          prompt: Prepare validated work for review.
          transitions:
            completed: done
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
      after_create: |
        cp #{Path.join(template_repo, "README.md")} README.md
    agent:
      max_concurrent_agents: 10
      max_turns: 3
    codex:
      command: #{yaml_value("#{codex_binary} app-server")}
    ---
    """
  end

  defp memory_tracker_stage_config do
    """
    tracker:
      kind: memory
      stage_states:
        ready:
          state: Ready
        working:
          state: In Progress
        review:
          state: Human Review
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

  defp workflow_state_stage_config do
    """
    tracker:
      kind: memory
      workflow_state:
        strategy: project_v2_status
        field_name: Status
        state_options:
          ready: Ready
          working: In progress
          review: Human Review
          done: Done
          blocked: Blocked
          protocol_blocked: Protocol Blocked
    """
  end

  defp memory_tracker_stage_config_with_canceled_provider_state do
    """
    tracker:
      kind: memory
      stage_states:
        ready:
          state: Ready
        working:
          state: In Progress
        review:
          state: Human Review
        done:
          state: Done
          terminal: true
        blocked:
          state: Blocked
          terminal: true
        protocol_blocked:
          state: Canceled
          terminal: true
    """
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_atom(value), do: yaml_value(Atom.to_string(value))
  defp yaml_value(value) when is_integer(value), do: to_string(value)

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder exposes same-repository GitHub issue closing reference" do
    workflow_prompt =
      "kind={{ issue.tracker_kind }} ref={{ issue.closing_reference }} instruction={{ issue.closing_instruction }}"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: nil,
      tracker_project_slug: nil,
      tracker_owner: "openai",
      tracker_repo: "symphony",
      prompt: workflow_prompt
    )

    issue = %Issue{
      identifier: "openai/symphony#3",
      title: "Link PR to GitHub issue",
      description: "PR body should close the issue on merge.",
      state: "Todo",
      url: "https://github.com/openai/symphony/issues/3",
      labels: []
    }

    prompt = PromptBuilder.render_template(Config.workflow_prompt(), issue)

    assert prompt =~ "kind=github"
    assert prompt =~ "ref=Closes #3"
    assert prompt =~ "Use `Closes #3` in the pull request description"
  end

  test "prompt builder keeps cross-repository GitHub issue references fully qualified" do
    workflow_prompt = "ref={{ issue.closing_reference }}"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: nil,
      tracker_project_slug: nil,
      tracker_owner: "openai",
      tracker_repo: "symphony",
      prompt: workflow_prompt
    )

    issue = %Issue{
      identifier: "other-org/other-repo#9",
      title: "Close an external issue",
      description: "PR body should keep repository scope.",
      state: "Todo",
      url: "https://github.com/other-org/other-repo/issues/9",
      labels: []
    }

    assert PromptBuilder.render_template(workflow_prompt, issue) == "ref=Closes other-org/other-repo#9"
  end

  test "prompt builder keeps qualified GitHub issue reference when configured scope is incomplete" do
    workflow_prompt = "ref={{ issue.closing_reference }}"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: nil,
      tracker_project_slug: nil,
      tracker_owner: nil,
      tracker_repo: nil,
      prompt: workflow_prompt
    )

    issue = %Issue{
      identifier: "openai/symphony#10",
      title: "Close issue with missing repository config in prompt",
      description: "Prompt builder should still emit a valid local closing keyword.",
      state: "Todo",
      url: "https://github.com/openai/symphony/issues/10",
      labels: []
    }

    assert PromptBuilder.render_template(workflow_prompt, issue) == "ref=Closes openai/symphony#10"
  end

  test "prompt builder preserves unparseable GitHub identifiers in closing reference" do
    workflow_prompt = "ref={{ issue.closing_reference }}"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: nil,
      tracker_project_slug: nil,
      tracker_owner: "openai",
      tracker_repo: "symphony",
      prompt: workflow_prompt
    )

    issue = %Issue{
      identifier: "openai/symphony",
      title: "Identifier without issue number",
      description: "Prompt builder should not invent an issue number.",
      state: "Todo",
      url: "https://github.com/openai/symphony/issues",
      labels: []
    }

    assert PromptBuilder.render_template(workflow_prompt, issue) == "ref=Closes openai/symphony"
  end

  test "prompt builder exposes same-project GitLab issue closing reference" do
    workflow_prompt =
      "kind={{ issue.tracker_kind }} ref={{ issue.closing_reference }} instruction={{ issue.closing_instruction }}"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: nil,
      tracker_api_token: "token",
      tracker_project_slug: "platform/symphony",
      prompt: workflow_prompt
    )

    issue = %Issue{
      identifier: "platform/symphony#7",
      title: "Link MR to GitLab issue",
      description: "MR body should close the issue on merge.",
      state: "Todo",
      url: "https://gitlab.com/platform/symphony/-/issues/7",
      labels: []
    }

    prompt = PromptBuilder.render_template(Config.workflow_prompt(), issue)

    assert prompt =~ "kind=gitlab"
    assert prompt =~ "ref=Closes #7"
    assert prompt =~ "Use `Closes #7` in the merge request description"
  end

  test "prompt builder keeps Linear issue references readable without closing semantics" do
    workflow_prompt =
      "kind={{ issue.tracker_kind }} ref={{ issue.closing_reference }} instruction={{ issue.closing_instruction }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "JIE-3",
      title: "Keep Linear reference",
      description: "Linear should not use GitHub closing keywords.",
      state: "Todo",
      url: "https://linear.app/team/issue/JIE-3",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "kind=linear"
    assert prompt =~ "ref=Linear: JIE-3"
    assert prompt =~ "preserve the Linear ticket reference"
  end

  test "prompt builder exposes fallback issue reference for generic trackers" do
    workflow_prompt =
      "kind={{ issue.tracker_kind }} ref={{ issue.closing_reference }} instruction={{ issue.closing_instruction }}"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      prompt: workflow_prompt
    )

    issue = %Issue{
      identifier: "MEM-3",
      title: "Generic issue",
      description: "Fallback trackers preserve their identifier.",
      state: "Todo",
      url: nil,
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "kind=memory"
    assert prompt =~ "ref=MEM-3"
    assert prompt =~ "preserve the issue reference"
  end

  test "prompt builder exposes unavailable closing reference when issue identifier is missing" do
    workflow_prompt = "ref={{ issue.closing_reference }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: nil,
      title: "Missing identifier",
      description: "Prompt builder should not crash.",
      state: "Todo",
      url: nil,
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) == "ref=Unavailable"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses workflow stage prompt instead of legacy default issue prompt" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt == "Pick up new work."
    refute prompt =~ "You are working on an issue."
    refute prompt =~ "Identifier: MT-777"
  end

  test "prompt builder falls back to default issue prompt for blank legacy templates" do
    write_legacy_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: [],
      tracker_terminal_states: [],
      prompt: "   \n"
    )

    prompt =
      PromptBuilder.build_prompt(%{
        "identifier" => "MT-781",
        "title" => "Render legacy fallback",
        "description" => "Default prompt body"
      })

    assert prompt =~ "You are working on an issue."
    assert prompt =~ "Identifier: MT-781"
    assert prompt =~ "Title: Render legacy fallback"
    assert prompt =~ "Default prompt body"
  end

  test "stage prompt renderer handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = SymphonyElixir.StagePromptRenderer.render(Config.settings!().workflow, "ready", issue)

    assert prompt =~ "- identifier: MT-778"
    assert prompt =~ "- title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder render_template defaults optional assigns" do
    issue = %Issue{
      identifier: "MT-779",
      title: "Render direct template",
      description: "Use render_template directly",
      state: "Todo",
      url: "https://example.org/issues/MT-779",
      labels: []
    }

    assert PromptBuilder.render_template("Ticket {{ issue.identifier }} attempt={{ attempt }}", issue) ==
             "Ticket MT-779 attempt="
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "You are working on tracker issue `MT-616`"
    assert prompt =~ "Issue context:"
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "Title: Use rich templates for WORKFLOW.md"
    assert prompt =~ "Current status: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "This is an unattended orchestration session."
    assert prompt =~ "Only stop early for a true blocker"
    assert prompt =~ "Final handoff must record completion summary"
    assert prompt =~ "Commit message for non-trivial changes"
    assert prompt =~ "Continuation context:"
    assert prompt =~ "retry attempt #2"
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"id\":101,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"symphony_stage_outcome\",\"callId\":\"call-1\",\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"arguments\":{\"outcome\":\"completed\",\"summary\":\"Done.\"}}}'
            IFS= read -r _tool_response || exit 1
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        tracker_kind: "memory",
        tracker_api_token: nil
      )

      issue = %Issue{
        id: "issue-retain-workspace",
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              printf '%s\\n' '{\"id\":101,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"symphony_stage_outcome\",\"callId\":\"call-live\",\"threadId\":\"thread-live\",\"turnId\":\"turn-live\",\"arguments\":{\"outcome\":\"completed\",\"summary\":\"Done.\"}}}'
              IFS= read -r _tool_response || exit 1
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        tracker_kind: "memory",
        tracker_api_token: nil
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner renders workflow stage prompt and captures structured outcome" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-state-route-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file=#{shell_escape(trace_file)}
      printf 'RUN\\n' >> "$trace_file"
      turn_count=0

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-route"}}}'
            ;;
          *'"method":"turn/start"'*)
            turn_count=$((turn_count + 1))

            if [ "$turn_count" -eq 1 ]; then
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-route-1"}}}'
              printf '%s\\n' '{"id":101,"method":"item/tool/call","params":{"tool":"symphony_stage_outcome","callId":"call-route","threadId":"thread-route","turnId":"turn-route-1","arguments":{"outcome":"accepted","summary":"Ready stage accepted."}}}'
            else
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-route-2"}}}'
              printf '%s\\n' '{"id":102,"method":"item/tool/call","params":{"tool":"symphony_stage_outcome","callId":"call-route-2","threadId":"thread-route","turnId":"turn-route-2","arguments":{"outcome":"completed","summary":"Working stage completed."}}}'
            fi
            ;;
          *'"result"'*)
            printf '%s\\n' '{"method":"turn/completed"}'

            if [ "$turn_count" -ge 2 ]; then
              exit 0
            fi
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workflow_path = Workflow.workflow_file_path()
      tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

      File.write!(workflow_path, runner_stage_workflow_file(workspace_root, codex_binary, template_repo))
      File.write!(tracker_config_path, workflow_state_stage_config())
      Workflow.set_workflow_file_path(workflow_path)
      TrackerConfig.set_tracker_file_path(tracker_config_path)

      issue = %Issue{
        id: "issue-route",
        identifier: "MT-249",
        title: "Run state routed workflow",
        description: "Complete from Todo",
        state: "Ready",
        url: "https://example.org/issues/MT-249",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      state_fetcher = fn [_issue_id] ->
        send(self(), :unexpected_issue_state_fetch)
        {:ok, []}
      end

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      turn_texts =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "# Symphony Stage Turn"
      assert Enum.at(turn_texts, 0) =~ "## Stage"
      assert Enum.at(turn_texts, 0) =~ "- id: ready"
      assert Enum.at(turn_texts, 0) =~ "Pick up new work."
      assert Enum.at(turn_texts, 0) =~ "## Workflow Outcomes"
      assert Enum.at(turn_texts, 0) =~ "- accepted"
      assert Enum.at(turn_texts, 0) =~ "## Current Stage Transitions"
      assert Enum.at(turn_texts, 0) =~ "- accepted -> working"
      assert Enum.at(turn_texts, 0) =~ "structured stage outcome"
      refute Enum.at(turn_texts, 0) =~ "State route: Todo -> In Progress"
      refute Enum.at(turn_texts, 0) =~ "Human Review"

      assert Enum.at(turn_texts, 1) =~ "- id: working"
      assert Enum.at(turn_texts, 1) =~ "Implement the accepted scope."
      assert Enum.at(turn_texts, 1) =~ "- completed -> done"

      assert_receive {:memory_tracker_stage_update, "issue-route", "working", "In progress"}
      assert_receive {:memory_tracker_stage_update, "issue-route", "done", "Done"}
      refute_receive :unexpected_issue_state_fetch, 100
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner does not treat direct provider status update as stage outcome" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-provider-status-not-outcome-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-provider-status"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-provider-status-1"}}}'
            printf '%s\\n' '{"id":102,"method":"item/tool/call","params":{"tool":"tracker_issue","callId":"call-provider-status","threadId":"thread-provider-status","turnId":"turn-provider-status-1","arguments":{"operation":"set_status","issueId":"issue-provider-status","state":"In Progress"}}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workflow_path = Workflow.workflow_file_path()
      tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

      File.write!(
        workflow_path,
        runner_stage_workflow_file(workspace_root, codex_binary, template_repo)
        |> String.replace("max_retries: 2", "max_retries: 0")
      )

      File.write!(tracker_config_path, memory_tracker_stage_config())
      Workflow.set_workflow_file_path(workflow_path)
      TrackerConfig.set_tracker_file_path(tracker_config_path)

      issue = %Issue{
        id: "issue-provider-status",
        identifier: "MT-250",
        title: "Do not accept provider status as outcome",
        description: "Provider tools must not drive stage transitions.",
        state: "Ready",
        url: "https://example.org/issues/MT-250",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      assert :ok =
               AgentRunner.run(issue, nil,
                 tool_executor: fn
                   "tracker_issue", %{"operation" => "set_status"} ->
                     %{"success" => true, "output" => ~s({"updated":true})}

                   tool, arguments ->
                     DynamicTool.execute(tool, arguments)
                 end
               )

      assert_receive {:memory_tracker_stage_update, "issue-provider-status", "protocol_blocked", "Protocol Blocked"}
      refute_receive {:memory_tracker_stage_update, "issue-provider-status", "working", "In Progress"}, 100
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner retries missing stage outcome then writes protocol blocked stage" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-missing-outcome-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file=#{shell_escape(trace_file)}
      printf 'RUN\\n' >> "$trace_file"
      turn_count=0

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-missing"}}}'
            ;;
          *'"method":"turn/start"'*)
            turn_count=$((turn_count + 1))
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-missing-'"$turn_count"'"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'

            if [ "$turn_count" -ge 3 ]; then
              exit 0
            fi
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workflow_path = Workflow.workflow_file_path()
      tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

      File.write!(workflow_path, runner_stage_workflow_file(workspace_root, codex_binary, template_repo))
      File.write!(tracker_config_path, memory_tracker_stage_config())
      Workflow.set_workflow_file_path(workflow_path)
      TrackerConfig.set_tracker_file_path(tracker_config_path)

      issue = %Issue{
        id: "issue-missing-outcome",
        identifier: "MT-251",
        title: "Retry missing outcome",
        description: "Missing outcome should exhaust to protocol blocked.",
        state: "Ready",
        url: "https://example.org/issues/MT-251",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      assert :ok = AgentRunner.run(issue)

      trace = File.read!(trace_file)
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 3
      assert_receive {:memory_tracker_stage_update, "issue-missing-outcome", "protocol_blocked", "Protocol Blocked"}
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner propagates turn failure without writing workflow stage" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-turn-failure-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-failure"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-failure-1"}}}'
            printf '%s\\n' '{"method":"turn/failed","params":{"reason":"boom"}}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workflow_path = Workflow.workflow_file_path()
      tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

      File.write!(workflow_path, runner_stage_workflow_file(workspace_root, codex_binary, template_repo))
      File.write!(tracker_config_path, memory_tracker_stage_config())
      Workflow.set_workflow_file_path(workflow_path)
      TrackerConfig.set_tracker_file_path(tracker_config_path)

      issue = %Issue{
        id: "issue-turn-failure",
        identifier: "MT-252",
        title: "Turn failure",
        description: "Turn failure should not transition stages.",
        state: "Ready",
        url: "https://example.org/issues/MT-252",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      assert_raise RuntimeError, ~r/turn_failed/, fn ->
        AgentRunner.run(issue)
      end

      refute_receive {:memory_tracker_stage_update, "issue-turn-failure", _stage, _state}, 100
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops after terminal stage outcome without active-state continuation" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file=#{shell_escape(trace_file)}
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"id":101,"method":"item/tool/call","params":{"tool":"symphony_stage_outcome","callId":"call-max-1","threadId":"thread-max","turnId":"turn-max-1","arguments":{"outcome":"completed","summary":"Done."}}}'
            IFS= read -r _tool_response || exit 1
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"id":102,"method":"item/tool/call","params":{"tool":"symphony_stage_outcome","callId":"call-max-2","threadId":"thread-max","turnId":"turn-max-2","arguments":{"outcome":"completed","summary":"Done."}}}'
            IFS= read -r _tool_response || exit 1
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2,
        tracker_kind: "memory",
        tracker_api_token: nil
      )

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert :ok = AgentRunner.run(issue)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 1
    after
      File.rm_rf(test_root)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --config 'model=\"gpt-5.5\"' app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--config model=\"gpt-5.5\" app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end
end
