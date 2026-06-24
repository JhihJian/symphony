defmodule SymphonyElixir.TrackerContractTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Adapter, as: GitHubAdapter
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Memory

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

  test "memory native terminal check is explicit and separate from workflow terminal stages" do
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
    refute Memory.is_native_terminal?(blocked_issue)
    assert {:ok, "blocked"} = Memory.read_issue_stage(blocked_issue)
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

  test "github project-backed mapping keeps explicit unsupported stage operation boundary" do
    workflow = workflow_definition()
    tracker_config = github_tracker_config(%{}, project_number: 1)

    assert :ok = GitHubAdapter.validate_workflow_state_mapping(workflow, tracker_config)
    assert %{stage_contract: :unsupported} = GitHubAdapter.capabilities()
    assert {:error, {:stage_contract_not_implemented, :github}} = GitHubAdapter.fetch_runnable_issues("ready")
    assert {:error, {:stage_contract_not_implemented, :github}} = GitHubAdapter.read_issue_stage("1")
    assert {:error, {:stage_contract_not_implemented, :github}} = GitHubAdapter.write_issue_stage("1", "working")
    assert {:error, {:stage_contract_not_implemented, :github}} = GitHubAdapter.is_native_terminal?(%Issue{})
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

  defp github_tracker_config(overrides, opts \\ []) do
    project_number = Keyword.get(opts, :project_number)

    tracker =
      %{
        "kind" => "github",
        "provider_states" => ["Open", "Ready", "In Progress", "Done", "Closed", "Blocked"],
        "stage_states" => stage_states(overrides, opts)
      }
      |> maybe_put_project_number(project_number)

    %{"tracker" => tracker}
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
