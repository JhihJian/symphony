defmodule SymphonyElixir.StagePromptRendererTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.StagePromptRenderer

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
