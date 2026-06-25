defmodule SymphonyElixir.TrackerContractTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Adapter, as: GitHubAdapter
  alias SymphonyElixir.GitLab.Adapter, as: GitLabAdapter
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Memory
  alias SymphonyElixir.Tracker.StageState
  alias SymphonyElixir.Workflow.Definition

  defmodule FakeLinearStageClient do
    def fetch_candidate_issues, do: {:ok, []}

    def fetch_issues_by_states(states) do
      send(self(), {:linear_fetch_issues_by_states, states})
      {:ok, Enum.map(states, &issue_for_state/1)}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:linear_fetch_issue_states_by_ids, issue_ids})
      {:ok, Enum.map(issue_ids, &%Issue{id: &1, identifier: &1, title: &1, state: "In Progress"})}
    end

    def graphql(query, variables) do
      send(self(), {:linear_graphql, query, variables})

      cond do
        query =~ "states" ->
          {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "linear-state-1"}]}}}}}}

        query =~ "issueUpdate" ->
          {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end
    end

    defp issue_for_state(state) do
      %Issue{id: "linear-#{state}", identifier: "linear-#{state}", title: "Linear #{state}", state: state}
    end
  end

  defmodule FakeGitHubStageClient do
    def fetch_candidate_issues, do: {:ok, []}

    def fetch_issues_by_states(states) do
      send(self(), {:github_fetch_issues_by_states, states})
      {:ok, Enum.map(states, &issue_for_state/1)}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:github_fetch_issue_states_by_ids, issue_ids})
      {:ok, Enum.map(issue_ids, &%Issue{id: &1, identifier: &1, title: &1, state: "In Progress"})}
    end

    def read_project_issue_state(issue_id) do
      send(self(), {:github_read_project_issue_state, issue_id})
      Process.get({__MODULE__, :project_state}, {:ok, "In Progress"})
    end

    def create_comment(_issue_id, _body), do: :ok

    def update_issue_state(issue_id, state_name) do
      send(self(), {:github_update_issue_state, issue_id, state_name})
      Process.get({__MODULE__, :update_issue_state_result}, :ok)
    end

    defp issue_for_state(state) do
      %Issue{id: "github-#{state}", identifier: "github-#{state}", title: "GitHub #{state}", state: state}
    end
  end

  defmodule FakeGitLabStageClient do
    def fetch_candidate_issues, do: {:ok, []}

    def fetch_issues_by_states(states) do
      send(self(), {:gitlab_fetch_issues_by_states, states})
      Process.get({__MODULE__, :fetch_issues_by_states_result}, {:ok, Enum.map(states, &issue_for_state/1)})
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:gitlab_fetch_issue_states_by_ids, issue_ids})

      Process.get(
        {__MODULE__, :fetch_issue_states_by_ids_result},
        {:ok, Enum.map(issue_ids, &%Issue{id: &1, identifier: &1, title: &1, state: "status::implementation"})}
      )
    end

    def create_comment(_issue_id, _body), do: :ok
    def update_issue_state(_issue_id, _state_name), do: :ok

    def write_scoped_label_stage(issue_id, target_label, opts) do
      send(self(), {:gitlab_write_scoped_label_stage, issue_id, target_label, opts})
      Process.get({__MODULE__, :write_scoped_label_stage_result}, :ok)
    end

    defp issue_for_state(state) do
      %Issue{id: "gitlab-#{state}", identifier: "gitlab-#{state}", title: "GitLab #{state}", state: state}
    end
  end

  test "memory tracker implements stage-aware runnable discovery and stage read/write" do
    ready_issue = issue("issue-ready", "MEM-1", "Ready")
    working_issue = issue("issue-working", "MEM-2", "In Progress")
    done_issue = issue("issue-done", "MEM-3", "Done")

    write_stage_workflow_and_tracker!(tracker: memory_tracker_config())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [ready_issue, working_issue, done_issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    assert %{stage_contract: :supported} = Tracker.capabilities()
    assert :ok = Tracker.validate_workflow_state_mapping(Config.settings!().workflow, Config.settings!().tracker_config)

    assert {:ok, [^ready_issue]} = Tracker.fetch_runnable_issues("ready")
    assert {:ok, "ready"} = Tracker.read_issue_stage(ready_issue)
    assert {:ok, "ready"} = Tracker.read_issue_stage("issue-ready")

    assert :ok = Tracker.write_issue_stage("issue-ready", "working")
    assert_receive {:memory_tracker_stage_update, "issue-ready", "working", "In Progress"}

    assert {:ok, "working"} = Tracker.read_issue_stage("issue-ready")
    assert {:ok, [%Issue{id: "issue-ready"}, ^working_issue]} = Tracker.fetch_runnable_issues("working")
  end

  test "memory native terminal check follows workflow terminal stages" do
    done_issue = issue("issue-done", "MEM-4", "Done")
    blocked_issue = issue("issue-blocked", "MEM-5", "Blocked")

    write_stage_workflow_and_tracker!(
      tracker:
        memory_tracker_config(%{
          "done" => %{"state" => "Done", "terminal" => true},
          "blocked" => %{"state" => "Blocked", "terminal" => false}
        })
    )

    assert "blocked" in Config.settings!().workflow["terminal_stages"]
    assert Memory.is_native_terminal?(done_issue)
    assert Memory.is_native_terminal?(blocked_issue)
    assert {:ok, "blocked"} = Memory.read_issue_stage(blocked_issue)
  end

  test "memory tracker reports invalid stage contract calls explicitly" do
    unmapped_issue = issue("issue-unmapped", "MEM-6", "External")

    write_stage_workflow_and_tracker!(tracker: memory_tracker_config())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [unmapped_issue])

    assert {:error, {:invalid_stage_id, 123}} = Memory.fetch_runnable_issues(123)
    assert {:error, {:unknown_workflow_stage, "missing"}} = Memory.fetch_runnable_issues("missing")
    assert {:error, {:unknown_workflow_stage, "missing"}} = Memory.write_issue_stage("issue-unmapped", "missing")
    assert {:error, :issue_not_found} = Memory.read_issue_stage("missing-issue")
    assert {:error, :issue_not_found} = Memory.write_issue_stage("missing-issue", "ready")
    assert {:error, {:invalid_issue, 123}} = Memory.read_issue_stage(123)
    assert {:error, {:invalid_stage_write, 123, "ready"}} = Memory.write_issue_stage(123, "ready")
    assert {:error, {:invalid_issue, 123}} = Memory.is_native_terminal?(123)
    assert {:error, {:unmapped_provider_state, "External"}} = Memory.read_issue_stage(unmapped_issue)
  end

  test "stage-state helper covers adapter mapping edge cases" do
    ready_issue = issue("issue-ready", "MEM-7", "Ready")

    write_stage_workflow_and_tracker!(tracker: memory_tracker_config())

    assert %{
             tracker: :custom,
             stage_contract: :supported,
             fetch_runnable_issues: true,
             read_issue_stage: true,
             write_issue_stage: true,
             native_terminal: :workflow_terminal_stage
           } = StageState.capabilities(:custom)

    assert {:ok, [^ready_issue]} =
             StageState.fetch_runnable_issues("ready", fn ["Ready"] -> {:ok, [ready_issue]} end)

    assert {:error, :fetch_failed} =
             StageState.fetch_runnable_issues("ready", fn ["Ready"] -> {:error, :fetch_failed} end)

    assert {:error, {:invalid_stage_id, 123}} =
             StageState.fetch_runnable_issues(123, fn _states -> {:ok, []} end)

    assert {:ok, "ready"} =
             StageState.read_issue_stage("issue-ready", fn ["issue-ready"] -> {:ok, [ready_issue]} end)

    assert {:error, :issue_not_found} =
             StageState.read_issue_stage("missing", fn ["missing"] -> {:ok, []} end)

    assert {:error, :read_failed} =
             StageState.read_issue_stage("issue-ready", fn ["issue-ready"] -> {:error, :read_failed} end)

    assert {:error, {:invalid_issue, 123}} =
             StageState.read_issue_stage(123, fn _issue_ids -> {:ok, []} end)

    assert :ok =
             StageState.write_issue_stage("issue-ready", "done", fn "issue-ready", "Done" -> :ok end)

    assert {:error, :write_failed} =
             StageState.write_issue_stage("issue-ready", "done", fn "issue-ready", "Done" -> {:error, :write_failed} end)

    assert {:error, {:invalid_stage_write, 123, "done"}} =
             StageState.write_issue_stage(123, "done", fn _issue_id, _stage -> :ok end)

    assert {:error, {:invalid_stage_id, 123}} = StageState.provider_state_for_stage(123)
    assert {:ok, "ready"} = StageState.stage_for_provider_state(" ready ")
    assert {:error, {:unmapped_provider_state, 123}} = StageState.stage_for_provider_state(123)
    assert StageState.terminal_stage?("done")
    refute StageState.terminal_stage?(123)
    assert StageState.terminal_provider_state?("Done")
    refute StageState.terminal_provider_state?("External")
    refute StageState.terminal_provider_state?(123)
    assert StageState.native_terminal?(%Issue{state: "Done"})
    assert {:error, {:unmapped_provider_state, "External"}} = StageState.native_terminal?(%Issue{state: "External"})
    assert %{stage_contract: :unsupported} = Tracker.unsupported_stage_capabilities(:custom)
    assert {:error, {:stage_contract_not_implemented, :custom}} = Tracker.unsupported_stage_contract(:custom)

    write_stage_workflow_and_tracker!(
      tracker:
        memory_tracker_config(%{
          "ready" => %{"state" => "Ready", "terminal" => true}
        })
    )

    assert StageState.terminal_stage?("ready")

    legacy_workflow_path = Workflow.workflow_file_path()

    File.write!(legacy_workflow_path, """
    ---
    tracker:
      kind: memory
      stage_states:
        ready:
          state: 123
    ---
    """)

    Workflow.set_workflow_file_path(legacy_workflow_path)
    TrackerConfig.clear_tracker_file_path()

    refute StageState.terminal_stage?("ready")
    assert {:error, {:unmapped_provider_state, "Ready"}} = StageState.stage_for_provider_state("Ready")
  end

  test "mapping validation reports missing stage mappings" do
    workflow = workflow_definition()

    tracker_config =
      memory_tracker_config(
        %{
          "ready" => "Ready",
          "working" => "In Progress",
          "done" => %{"state" => "Done", "terminal" => true}
        },
        merge_default_stage_states?: false
      )

    assert {:error, {:invalid_tracker_config, message}} =
             Memory.validate_workflow_state_mapping(workflow, tracker_config)

    assert message =~ "tracker.stage_states"
    assert message =~ "missing blocked"
  end

  test "mapping validation reports provider states outside the declared provider state set" do
    workflow = workflow_definition()

    tracker_config =
      memory_tracker_config(%{
        "ready" => "Ready",
        "working" => "Doing",
        "done" => %{"state" => "Done", "terminal" => true},
        "blocked" => %{"state" => "Blocked", "terminal" => true}
      })
      |> put_in(["tracker", "provider_states"], ["Ready", "In Progress", "Done", "Blocked"])

    assert {:error, {:invalid_tracker_config, message}} =
             Memory.validate_workflow_state_mapping(workflow, tracker_config)

    assert message =~ "unknown provider states"
    assert message =~ ~s(working="Doing")
    assert message =~ "known provider states"
  end

  test "github issues-only mapping rejects multiple provider-visible stage states" do
    workflow = workflow_definition()

    tracker_config =
      github_tracker_config(%{
        "ready" => "Open",
        "working" => "In Progress",
        "done" => %{"state" => "Closed", "terminal" => true},
        "blocked" => %{"state" => "Closed", "terminal" => true}
      })

    assert {:error, {:invalid_tracker_config, message}} =
             GitHubAdapter.validate_workflow_state_mapping(workflow, tracker_config)

    assert message =~ "GitHub issues-only tracker cannot represent multiple"
    assert message =~ "tracker.project_number"
  end

  test "github issues-only accepts a single provider-visible stage state" do
    workflow = workflow_definition()

    assert :ok =
             GitHubAdapter.validate_workflow_state_mapping(
               workflow,
               github_tracker_config(%{
                 "ready" => "Open",
                 "working" => "Open",
                 "done" => %{"state" => "Open", "terminal" => true},
                 "blocked" => %{"state" => "Open", "terminal" => true}
               })
             )
  end

  test "mapping validation accepts workflow structs, atom keys, and absent provider state sets" do
    {:ok, workflow} = Definition.parse(workflow_definition())

    tracker_config = %{
      tracker: %{
        kind: :memory,
        provider_states: nil,
        stage_states: %{
          ready: "Ready",
          working: "In Progress",
          done: %{state: "Done", terminal: true},
          blocked: %{state: "Blocked", terminal: true}
        }
      }
    }

    assert :ok = Tracker.validate_workflow_state_mapping(workflow, tracker_config)
  end

  test "top-level mapping validation dispatches atom tracker kinds to provider adapters" do
    workflow = workflow_definition()

    tracker_config = %{
      tracker: %{
        kind: :github,
        provider_states: ["Open", "In Progress", "Closed"],
        stage_states: %{
          ready: "Open",
          working: "In Progress",
          done: %{state: "Closed", terminal: true},
          blocked: %{state: "Closed", terminal: true}
        }
      }
    }

    assert {:error, {:invalid_tracker_config, message}} =
             Tracker.validate_workflow_state_mapping(workflow, tracker_config)

    assert message =~ "GitHub issues-only tracker cannot represent multiple"
  end

  test "provider adapters validate mapping with normalized atom-key configs" do
    workflow = workflow_definition()

    github_config = %{
      tracker: %{
        kind: :github,
        project_number: 1,
        provider_states: ["Ready", "In Progress", "Done", "Blocked"],
        stage_states: %{
          ready: "Ready",
          working: "In Progress",
          done: %{state: "Done", terminal: true},
          blocked: %{state: "Blocked", terminal: true}
        }
      }
    }

    gitlab_config = %{
      tracker: %{
        kind: :gitlab,
        provider_states: ["Ready", "In Progress", "Done", "Blocked"],
        stage_states: %{
          ready: "Ready",
          working: "In Progress",
          done: %{state: "Done", terminal: true},
          blocked: %{state: "Blocked", terminal: true}
        }
      }
    }

    assert :ok = GitHubAdapter.validate_workflow_state_mapping(workflow, github_config)
    assert :ok = GitLabAdapter.validate_workflow_state_mapping(workflow, gitlab_config)
    assert Tracker.normalize_provider_state(42) == ""
  end

  test "linear adapter implements workflow-state stage mapping" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearStageClient)
    write_stage_workflow_and_tracker!(tracker: linear_tracker_config())

    assert %{stage_contract: :supported} = Tracker.capabilities()
    assert :ok = Tracker.validate_workflow_state_mapping(Config.settings!().workflow, Config.settings!().tracker_config)

    assert {:ok, [%Issue{id: "linear-Ready"}]} = Tracker.fetch_runnable_issues("ready")
    assert_receive {:linear_fetch_issues_by_states, ["Ready"]}

    assert {:ok, "working"} = Tracker.read_issue_stage("linear-1")
    assert_receive {:linear_fetch_issue_states_by_ids, ["linear-1"]}

    assert :ok = Tracker.write_issue_stage("linear-1", "done")
    assert_receive {:linear_graphql, lookup_query, %{issueId: "linear-1", stateName: "Done"}}
    assert lookup_query =~ "states"
    assert_receive {:linear_graphql, update_query, %{issueId: "linear-1", stateId: "linear-state-1"}}
    assert update_query =~ "issueUpdate"

    assert SymphonyElixir.Linear.Adapter.is_native_terminal?(issue("linear-2", "LIN-2", "Done"))
  end

  test "github project-backed adapter implements Project v2 Status stage mapping" do
    workflow = workflow_definition()
    tracker_config = github_tracker_config(%{}, project_number: 1)

    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubStageClient)
    write_stage_workflow_and_tracker!(tracker: tracker_config)

    assert :ok = GitHubAdapter.validate_workflow_state_mapping(workflow, tracker_config)
    assert %{stage_contract: :supported} = GitHubAdapter.capabilities()

    assert {:ok, [%Issue{id: "github-Ready"}]} = GitHubAdapter.fetch_runnable_issues("ready")
    assert_receive {:github_fetch_issues_by_states, ["Ready"]}

    assert {:ok, "working"} = GitHubAdapter.read_issue_stage("42")
    assert_receive {:github_read_project_issue_state, "42"}

    assert :ok = GitHubAdapter.write_issue_stage("42", "done")
    assert_receive {:github_update_issue_state, "42", "Done"}

    assert GitHubAdapter.is_native_terminal?(issue("42", "repo#42", "Closed"))
    assert {:ok, "done"} = GitHubAdapter.read_issue_stage(%Issue{state: "Closed"})
    assert {:ok, "done"} = GitHubAdapter.read_issue_stage(%Issue{state: "CLOSED"})
    assert {:ok, "working"} = GitHubAdapter.read_issue_stage(%Issue{state: "In Progress"})
    assert {:error, {:invalid_issue, 123}} = GitHubAdapter.read_issue_stage(123)
    assert GitHubAdapter.is_native_terminal?(%Issue{state: "CLOSED"})
    assert GitHubAdapter.is_native_terminal?(%Issue{state: "Done"})
    refute GitHubAdapter.is_native_terminal?(%Issue{state: nil})
    assert {:error, {:invalid_issue, 123}} = GitHubAdapter.is_native_terminal?(123)
  end

  test "github adapter covers issues-only invalid native terminal branch and workflow structs" do
    {:ok, workflow_struct} = Definition.parse(workflow_definition())
    tracker_config = github_tracker_config(%{"ready" => "Open"}, project_number: 1)

    assert :ok = GitHubAdapter.validate_workflow_state_mapping(workflow_struct, tracker_config)

    write_stage_workflow_and_tracker!(
      tracker:
        github_tracker_config(%{
          "ready" => "Open",
          "working" => "Open",
          "done" => %{"state" => "Open", "terminal" => true},
          "blocked" => %{"state" => "Open", "terminal" => true}
        })
    )

    assert {:error, {:stage_contract_not_supported, :github_issues_only}} = GitHubAdapter.read_issue_stage(123)
    assert {:error, {:stage_contract_not_supported, :github_issues_only}} = GitHubAdapter.is_native_terminal?(123)
  end

  test "github issues-only stage contract is unsupported for valid single-state config" do
    write_stage_workflow_and_tracker!(
      tracker:
        github_tracker_config(%{
          "ready" => "Open",
          "working" => "Open",
          "done" => %{"state" => "Open", "terminal" => true},
          "blocked" => %{"state" => "Open", "terminal" => true}
        })
    )

    assert %{stage_contract: :unsupported, reason: :github_issues_only_no_multistage_state} =
             GitHubAdapter.capabilities()

    assert {:error, {:stage_contract_not_supported, :github_issues_only}} = GitHubAdapter.fetch_runnable_issues("ready")
    assert {:error, {:stage_contract_not_supported, :github_issues_only}} = GitHubAdapter.read_issue_stage(%Issue{})
    assert {:error, {:stage_contract_not_supported, :github_issues_only}} = GitHubAdapter.read_issue_stage("42")
    assert {:error, {:stage_contract_not_supported, :github_issues_only}} = GitHubAdapter.write_issue_stage("42", "working")
  end

  test "github adapter falls back to mapped Closed provider state without terminal stage metadata" do
    TrackerConfig.clear_tracker_file_path()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "openai",
      tracker_repo: "symphony",
      tracker_project_number: 1
    )

    assert {:error, {:unmapped_provider_state, "Closed"}} = GitHubAdapter.read_issue_stage(%Issue{state: "Closed"})
  end

  test "gitlab scoped label adapter implements stage mapping and removes same-group labels" do
    Application.put_env(:symphony_elixir, :gitlab_client_module, FakeGitLabStageClient)

    write_stage_workflow_and_tracker!(
      tracker:
        gitlab_scoped_label_tracker_config(%{
          "done" => %{"state" => "status::done", "terminal" => true},
          "blocked" => %{"state" => "status::blocked", "terminal" => true}
        })
    )

    assert %{stage_contract: :supported} = GitLabAdapter.capabilities()
    assert :ok = Tracker.validate_workflow_state_mapping(Config.settings!().workflow, Config.settings!().tracker_config)

    assert {:ok, [%Issue{id: "gitlab-status::context-check"}]} = GitLabAdapter.fetch_runnable_issues("ready")
    assert_receive {:gitlab_fetch_issues_by_states, ["status::context-check"]}

    assert {:ok, "working"} = GitLabAdapter.read_issue_stage("gitlab:platform/symphony#7")
    assert_receive {:gitlab_fetch_issue_states_by_ids, ["gitlab:platform/symphony#7"]}

    assert :ok = GitLabAdapter.write_issue_stage("gitlab:platform/symphony#7", "working")

    assert_receive {:gitlab_write_scoped_label_stage, "gitlab:platform/symphony#7", "status::implementation", opts}
    refute Map.fetch!(opts, :close?)
    assert "status::context-check" in Map.fetch!(opts, :remove_labels)
    assert "status::done" in Map.fetch!(opts, :remove_labels)
    refute "status::implementation" in Map.fetch!(opts, :remove_labels)

    assert :ok = GitLabAdapter.write_issue_stage("gitlab:platform/symphony#7", "done")
    assert_receive {:gitlab_write_scoped_label_stage, "gitlab:platform/symphony#7", "status::done", done_opts}
    assert Map.fetch!(done_opts, :close?)

    conflict_issue = %Issue{
      id: "gitlab:platform/symphony#8",
      identifier: "platform/symphony#8",
      title: "Conflicting labels",
      state: "status::implementation",
      labels: ["status::context-check", "status::implementation"]
    }

    assert {:error, {:gitlab_scoped_label_conflict, ["status::context-check", "status::implementation"]}} =
             GitLabAdapter.read_issue_stage(conflict_issue)

    Process.put(
      {FakeGitLabStageClient, :fetch_issues_by_states_result},
      {:ok, [conflict_issue]}
    )

    assert {:error, {:gitlab_scoped_label_conflict, "gitlab:platform/symphony#8", ["status::context-check", "status::implementation"]}} =
             GitLabAdapter.fetch_runnable_issues("working")

    single_label_issue = %Issue{
      id: "gitlab:platform/symphony#9",
      identifier: "platform/symphony#9",
      title: "Single label",
      state: "status::implementation",
      labels: ["status::implementation"]
    }

    assert {:ok, "working"} = GitLabAdapter.read_issue_stage(single_label_issue)

    Process.put({FakeGitLabStageClient, :fetch_issues_by_states_result}, {:ok, [%{id: "not-an-issue"}]})
    assert {:ok, [%{id: "not-an-issue"}]} = GitLabAdapter.fetch_runnable_issues("working")

    Process.put(
      {FakeGitLabStageClient, :fetch_issues_by_states_result},
      {:ok,
       [
         %Issue{
           id: "gitlab:platform/symphony#10",
           identifier: "platform/symphony#10",
           title: "No labels",
           state: "status::implementation"
         }
       ]}
    )

    assert {:ok, [%Issue{id: "gitlab:platform/symphony#10"}]} = GitLabAdapter.fetch_runnable_issues("working")
  end

  test "gitlab adapter covers non-scoped and error stage branches" do
    Application.put_env(:symphony_elixir, :gitlab_client_module, FakeGitLabStageClient)
    write_stage_workflow_and_tracker!(tracker: gitlab_plain_tracker_config())

    assert :ok = GitLabAdapter.write_issue_stage("gitlab:platform/symphony#7", "working")
    assert {:error, {:invalid_stage_write, 123, "working"}} = GitLabAdapter.write_issue_stage(123, "working")
    assert {:error, {:invalid_issue, 123}} = GitLabAdapter.read_issue_stage(123)
    assert GitLabAdapter.is_native_terminal?(%Issue{state: "Done"})
    assert {:error, {:invalid_issue, 123}} = GitLabAdapter.is_native_terminal?(123)

    Process.put({FakeGitLabStageClient, :fetch_issue_states_by_ids_result}, {:ok, []})
    assert {:error, :issue_not_found} = GitLabAdapter.read_issue_stage("missing")

    Process.put({FakeGitLabStageClient, :fetch_issue_states_by_ids_result}, {:error, :boom})
    assert {:error, :boom} = GitLabAdapter.read_issue_stage("boom")

    Process.put({FakeGitLabStageClient, :fetch_issues_by_states_result}, {:error, :fetch_boom})
    assert {:error, :fetch_boom} = GitLabAdapter.fetch_runnable_issues("working")
  end

  defp write_stage_workflow_and_tracker!(opts) do
    workflow_path = Workflow.workflow_file_path()
    tracker_config_path = Path.join(Path.dirname(workflow_path), "TRACKER.yaml")

    File.write!(workflow_path, workflow_file())
    File.write!(tracker_config_path, yaml!(Keyword.fetch!(opts, :tracker)))

    Workflow.set_workflow_file_path(workflow_path)
    TrackerConfig.set_tracker_file_path(tracker_config_path)
  end

  defp issue(id, identifier, state) do
    %Issue{
      id: id,
      identifier: identifier,
      title: identifier,
      description: "Stage contract fixture",
      state: state,
      assigned_to_worker: true
    }
  end

  defp workflow_file do
    """
    ---
    workflow:
      start_stage: ready
      terminal_stages: [done, blocked]
      outcomes: [started, completed, blocked]
      missing_outcome:
        max_retries: 1
        on_exhausted: blocked
      stages:
        ready:
          prompt: Ready.
          transitions:
            started: working
            blocked: blocked
        working:
          prompt: Working.
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

  defp workflow_definition do
    %{
      "start_stage" => "ready",
      "terminal_stages" => ["done", "blocked"],
      "outcomes" => ["started", "completed", "blocked"],
      "missing_outcome" => %{"max_retries" => 1, "on_exhausted" => "blocked"},
      "stages" => %{
        "ready" => %{"prompt" => "Ready.", "transitions" => %{"started" => "working", "blocked" => "blocked"}},
        "working" => %{"prompt" => "Working.", "transitions" => %{"completed" => "done", "blocked" => "blocked"}},
        "done" => %{"prompt" => "Done.", "transitions" => %{}},
        "blocked" => %{"prompt" => "Blocked.", "transitions" => %{}}
      }
    }
  end

  defp memory_tracker_config(overrides \\ %{}, opts \\ []) do
    %{
      "tracker" => %{
        "kind" => "memory",
        "provider_states" => ["Ready", "In Progress", "Done", "Blocked"],
        "stage_states" => stage_states(overrides, opts)
      }
    }
  end

  defp linear_tracker_config(overrides \\ %{}, opts \\ []) do
    %{
      "tracker" => %{
        "kind" => "linear",
        "api_key" => "linear-token",
        "project_slug" => "project",
        "provider_states" => ["Ready", "In Progress", "Done", "Blocked"],
        "stage_states" => stage_states(overrides, opts)
      }
    }
  end

  defp github_tracker_config(overrides, opts \\ []) do
    project_number = Keyword.get(opts, :project_number)
    provider_states = Keyword.get(opts, :provider_states, ["Open", "Ready", "In Progress", "Done", "Closed", "Blocked"])

    tracker =
      %{
        "kind" => "github",
        "provider_states" => provider_states,
        "stage_states" => stage_states(overrides, opts)
      }
      |> maybe_put_project_number(project_number)

    %{"tracker" => tracker}
  end

  defp gitlab_scoped_label_tracker_config(overrides) do
    %{
      "tracker" => %{
        "kind" => "gitlab",
        "api_key" => "gitlab-token",
        "project_slug" => "platform/symphony",
        "workflow_state" => %{
          "strategy" => "scoped_label",
          "label_prefix" => "status::",
          "state_name_format" => "kebab_case",
          "close_on_terminal" => ["done"]
        },
        "stage_states" =>
          stage_states(
            Map.merge(
              %{
                "ready" => "status::context-check",
                "working" => "status::implementation",
                "done" => %{"state" => "status::done", "terminal" => true},
                "blocked" => %{"state" => "status::blocked", "terminal" => true}
              },
              overrides
            ),
            merge_default_stage_states?: false
          )
      }
    }
  end

  defp gitlab_plain_tracker_config(overrides \\ %{}, opts \\ []) do
    %{
      "tracker" => %{
        "kind" => "gitlab",
        "api_key" => "gitlab-token",
        "project_slug" => "platform/symphony",
        "provider_states" => ["Ready", "In Progress", "Done", "Blocked"],
        "stage_states" => stage_states(overrides, opts)
      }
    }
  end

  defp default_stage_states do
    %{
      "ready" => "Ready",
      "working" => "In Progress",
      "done" => %{"state" => "Done", "terminal" => true},
      "blocked" => %{"state" => "Blocked", "terminal" => true}
    }
  end

  defp stage_states(overrides, opts) do
    if Keyword.get(opts, :merge_default_stage_states?, true) do
      Map.merge(default_stage_states(), overrides)
    else
      overrides
    end
  end

  defp maybe_put_project_number(tracker, nil), do: tracker
  defp maybe_put_project_number(tracker, project_number), do: Map.put(tracker, "project_number", project_number)

  defp yaml!(term) do
    term
    |> yaml_lines(0)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp yaml_lines(map, indent) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      prefix = String.duplicate(" ", indent) <> "#{key}:"

      case value do
        nested when is_map(nested) ->
          [prefix | yaml_lines(nested, indent + 2)]

        list when is_list(list) ->
          [prefix | yaml_lines(list, indent + 2)]

        scalar ->
          [prefix <> " " <> yaml_scalar(scalar)]
      end
    end)
  end

  defp yaml_lines(list, indent) when is_list(list) do
    Enum.map(list, &(String.duplicate(" ", indent) <> "- " <> yaml_scalar(&1)))
  end

  defp yaml_scalar(true), do: "true"
  defp yaml_scalar(false), do: "false"
  defp yaml_scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp yaml_scalar(value) when is_binary(value), do: inspect(value)
end
