defmodule SymphonyElixir.StagePromptRendererTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.StagePromptRenderer
  alias SymphonyElixir.Workflow.Definition

  test "renders system stage prompt with stage issue outcomes transitions and protocol" do
    workflow = workflow()

    issue = %Issue{
      identifier: "MT-52",
      title: "Add stage prompt renderer",
      description: "Capture stage outcomes through a structured channel.",
      state: "Ready",
      url: "https://example.org/issues/MT-52",
      labels: ["symphony"]
    }

    prompt =
      StagePromptRenderer.render(
        workflow,
        "ready",
        issue,
        attempt: 2
      )

    assert prompt =~ "# Symphony Stage Turn"
    assert prompt =~ "## Stage"
    assert prompt =~ "- id: ready"
    assert prompt =~ "- name: ready"
    assert prompt =~ "## Issue"
    assert prompt =~ "- identifier: MT-52"
    assert prompt =~ "- title: Add stage prompt renderer"
    assert prompt =~ "Capture stage outcomes through a structured channel."
    assert prompt =~ "## Stage Prompt"
    assert prompt =~ "Pick up issue MT-52 on attempt 2."
    assert prompt =~ "## Workflow Outcomes"
    assert prompt =~ "- started"
    assert prompt =~ "- needs_review"
    assert prompt =~ "## Current Stage Transitions"
    assert prompt =~ "- blocked -> blocked"
    assert prompt =~ "- started -> in_progress"
    assert prompt =~ "## Stage Completion Protocol"
    assert prompt =~ "structured stage outcome"
    assert prompt =~ "Do not rely on final natural-language prose"
    assert prompt =~ "Do not represent stage completion by directly setting the provider or tracker status"
    assert prompt =~ "## Missing Outcome Policy"
    assert prompt =~ "retry up to 3 time(s)"
    assert prompt =~ "fallback stage is `blocked`"
    refute prompt =~ "State route: Todo -> In Progress"
    refute prompt =~ "Human Review"
  end

  test "resolves current stage from provider state mapping" do
    assert {:ok, "in_progress"} =
             StagePromptRenderer.stage_for_issue(
               workflow(),
               %Issue{state: "In Progress"},
               tracker_config()
             )
  end

  test "renders defaults for terminal stage and sparse issue context" do
    prompt =
      StagePromptRenderer.render(
        %{
          start_stage: :ready,
          terminal_stages: [:done],
          outcomes: [],
          stages: %{
            ready: %{
              name: :ready,
              prompt: "   ",
              transitions: %{}
            }
          }
        },
        " ready ",
        %{
          "identifier" => nil,
          "tracker_kind" => :memory,
          "title" => "",
          "state" => 123,
          "labels" => :not_a_list,
          "url" => nil,
          "description" => nil
        }
      )

    assert prompt =~ "- id: ready"
    assert prompt =~ "- tracker: memory"
    assert prompt =~ "- title: Unavailable"
    assert prompt =~ "- current_status: 123"
    assert prompt =~ "- labels: []"
    assert prompt =~ "No description provided."
    assert prompt =~ "No stage prompt provided."
    assert prompt =~ "## Workflow Outcomes\n\n- none"
    assert prompt =~ "## Current Stage Transitions\n\n- none"
    assert prompt =~ "This is a terminal stage"
    assert prompt =~ "protocol error for later retry handling"
  end

  test "resolves stages from workflow state when tracker mapping is absent or unmatched" do
    workflow = workflow()

    assert {:ok, "ready"} =
             StagePromptRenderer.stage_for_issue(
               workflow,
               %{"state" => "READY"},
               %{"tracker" => %{"stage_states" => %{"other" => %{"state" => "Other"}}}}
             )

    assert {:ok, "ready"} =
             StagePromptRenderer.stage_for_issue(
               workflow,
               %{"state" => "Ready"},
               %{"tracker" => %{"stage_states" => %{"broken" => []}}}
             )

    assert {:ok, "in_progress"} =
             StagePromptRenderer.stage_for_issue(
               workflow,
               %{state: " in_progress "}
             )

    assert {:error, {:unknown_workflow_stage_for_issue_state, "Waiting"}} =
             StagePromptRenderer.stage_for_issue(workflow, %{state: "Waiting"})
  end

  test "falls back to start stage when issue state is absent" do
    assert {:ok, "ready"} = StagePromptRenderer.stage_for_issue(workflow(), %{})
    assert {:ok, "ready"} = StagePromptRenderer.stage_for_issue(workflow(), :not_an_issue)
  end

  test "render_for_issue propagates unknown stage errors" do
    assert {:error, {:unknown_workflow_stage_for_issue_state, "Waiting"}} =
             StagePromptRenderer.render_for_issue(workflow(), %{state: "Waiting"})
  end

  test "current_for_issue renders workflow definition from current workflow" do
    File.write!(Workflow.workflow_file_path(), workflow_file())

    File.write!(
      Path.join(Path.dirname(Workflow.workflow_file_path()), "TRACKER.yaml"),
      tracker_file()
    )

    assert {:ok, prompt} =
             StagePromptRenderer.current_for_issue(
               %Issue{
                 identifier: "MT-53",
                 title: "Use current workflow",
                 description: "",
                 state: "Ready",
                 url: "",
                 labels: []
               },
               tracker_config: tracker_config()
             )

    assert prompt =~ "- id: ready"
    assert prompt =~ "Pick up issue MT-53"
  end

  test "current_for_issue reports workflow load errors" do
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-stage-workflow.md"))

    assert {:error, {:missing_workflow_file, _path, :enoent}} =
             StagePromptRenderer.current_for_issue(%Issue{state: "Ready"})
  end

  test "current_for_issue rejects legacy prompt-only workflow configs" do
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    write_legacy_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: [],
      tracker_terminal_states: []
    )

    assert {:error, :workflow_stage_config_unavailable} =
             StagePromptRenderer.current_for_issue(%Issue{state: "Ready"})
  end

  test "current_for_issue renders configured workflow stage prompt" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ignored legacy prompt body")

    assert {:ok, prompt} = StagePromptRenderer.current_for_issue(%Issue{state: "Todo"})
    assert prompt =~ "# Symphony Stage Turn"
    assert prompt =~ "- id: ready"
    assert prompt =~ "Pick up new work."
  end

  test "raises for invalid stage ids" do
    assert_raise ArgumentError, ~r/stage_id must be a non-empty string/, fn ->
      StagePromptRenderer.render(workflow(), "   ", %{})
    end

    assert_raise ArgumentError, ~r/stage_id must be a non-empty string/, fn ->
      StagePromptRenderer.render(workflow(), nil, %{})
    end
  end

  test "renders definition structs" do
    assert {:ok, definition} = Definition.parse(workflow())

    assert StagePromptRenderer.render(definition, "done", %{state: "Done"}) =~
             "This is a terminal stage"
  end

  defp workflow do
    %{
      "start_stage" => "ready",
      "terminal_stages" => ["done", "blocked"],
      "outcomes" => ["started", "needs_review", "blocked"],
      "missing_outcome" => %{"max_retries" => 3, "on_exhausted" => "blocked"},
      "stages" => %{
        "ready" => %{
          "prompt" => "Pick up issue {{ issue.identifier }} on attempt {{ attempt }}.",
          "transitions" => %{"started" => "in_progress", "blocked" => "blocked"}
        },
        "in_progress" => %{
          "prompt" => "Implement the accepted scope.",
          "transitions" => %{"needs_review" => "done", "blocked" => "blocked"}
        },
        "done" => %{"prompt" => "Terminal completion stage.", "transitions" => %{}},
        "blocked" => %{"prompt" => "Terminal blocked stage.", "transitions" => %{}}
      }
    }
  end

  defp workflow_file do
    """
    ---
    workflow:
      start_stage: ready
      terminal_stages: [done, blocked]
      outcomes: [started, blocked]
      missing_outcome:
        max_retries: 3
        on_exhausted: blocked
      stages:
        ready:
          prompt: Pick up issue {{ issue.identifier }}.
          transitions:
            started: in_progress
            blocked: blocked
        in_progress:
          prompt: Implement the accepted scope.
          transitions:
            blocked: blocked
        done:
          prompt: Terminal completion stage.
          transitions: {}
        blocked:
          prompt: Terminal blocked stage.
          transitions: {}
    ---
    """
  end

  defp tracker_file do
    """
    tracker:
      kind: memory
      stage_states:
        ready:
          state: Ready
        in_progress:
          state: In Progress
        done:
          state: Done
          terminal: true
        blocked:
          state: Blocked
          terminal: true
    """
  end

  defp tracker_config do
    %{
      "tracker" => %{
        "stage_states" => %{
          "ready" => %{"state" => "Ready"},
          "in_progress" => %{"state" => "In Progress"},
          "done" => %{"state" => "Done"},
          "blocked" => %{"state" => "Blocked"}
        }
      }
    }
  end
end
