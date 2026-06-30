defmodule SymphonyElixir.WorkflowVisualizationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workflow.Definition
  alias SymphonyElixir.Workflow.Visualization

  test "projects valid workflow stages into graph nodes, transitions and runtime counts" do
    definition = workflow_definition!()

    projection =
      Visualization.project(definition,
        tracker_config: tracker_config(),
        snapshot: %{
          running: [
            %{issue_id: "1", identifier: "APP-1", current_stage: "ready"},
            %{issue_id: "2", identifier: "APP-2", current_stage: "in_progress"}
          ],
          retrying: [%{issue_id: "3", identifier: "APP-3", current_stage: "ready"}],
          blocked: [%{issue_id: "4", identifier: "APP-4", current_stage: "blocked"}]
        }
      )

    assert projection.workflow.start_stage == "ready"
    assert projection.workflow.terminal_stages == ["done", "blocked", "protocol_blocked"]
    assert projection.missing_outcome.max_retries == 2
    assert projection.missing_outcome.on_exhausted == "protocol_blocked"
    assert projection.missing_outcome.protocol_blocked_target?

    ready = Enum.find(projection.stages, &(&1.id == "ready"))
    assert ready.start?
    refute ready.terminal?
    assert ready.reachable?
    assert ready.runtime == %{running: 1, retrying: 1, blocked: 0, total: 2}
    assert ready.tracker_state.provider_state == "Ready"
    assert ready.prompt_preview == "Pick up new work."

    blocked = Enum.find(projection.stages, &(&1.id == "blocked"))
    assert blocked.terminal?
    assert blocked.blocked?
    assert blocked.runtime.blocked == 1

    started = Enum.find(projection.transitions, &(&1.from == "ready" and &1.outcome == "started"))
    assert started.to == "in_progress"
    assert started.known_outcome?
    refute started.terminal_target?

    assert Enum.any?(projection.diagnostics, &(&1.code == :workflow_loaded))
    assert Enum.any?(projection.diagnostics, &(&1.code == :tracker_mapping_complete))
  end

  test "reports semantic warnings that are useful for operators" do
    definition =
      workflow_definition!(%{
        "start_stage" => "ready",
        "terminal_stages" => ["done", "blocked"],
        "outcomes" => ["started", "completed"],
        "missing_outcome" => %{"max_retries" => 1, "on_exhausted" => "blocked"},
        "stages" => %{
          "ready" => %{"prompt" => "Ready", "transitions" => %{"started" => "in_progress"}},
          "in_progress" => %{"prompt" => "Work", "transitions" => %{}},
          "orphan" => %{"prompt" => "Unused", "transitions" => %{"completed" => "done"}},
          "done" => %{"prompt" => "Done", "transitions" => %{}},
          "blocked" => %{"prompt" => "Blocked", "transitions" => %{}}
        }
      })

    projection = Visualization.project(definition)
    diagnostic_codes = Enum.map(projection.diagnostics, & &1.code)

    assert :non_terminal_without_transitions in diagnostic_codes
    assert :unreachable_stage in diagnostic_codes
    assert :terminal_stage_unreached in diagnostic_codes
    assert :tracker_config_unavailable in diagnostic_codes
  end

  test "summarizes incomplete tracker mappings without exposing secrets" do
    definition = workflow_definition!()

    tracker_config = %{
      "tracker" => %{
        "kind" => "github",
        "api_key" => "ghp_secret_token",
        "owner" => "acme",
        "repo" => "widget",
        "project_number" => 42,
        "stage_states" => %{
          "ready" => %{"state" => "Ready"},
          "in_progress" => %{"state" => "Doing"},
          "ghost" => %{"state" => "Ghost"}
        }
      }
    }

    projection = Visualization.project(definition, tracker_config: tracker_config)

    assert projection.tracker.kind == "github"
    assert projection.tracker.strategy == "project_v2_status"
    refute projection.tracker.coverage.complete?
    assert "done" in projection.tracker.coverage.missing_stages
    assert "ghost" in projection.tracker.coverage.unknown_stages
    assert projection.tracker.provider_hint == %{"owner" => "acme", "project_number" => 42, "repo" => "widget"}

    rendered = inspect(projection)
    refute rendered =~ "ghp_secret_token"
    refute rendered =~ "api_key"

    diagnostic_codes = Enum.map(projection.diagnostics, & &1.code)
    assert :tracker_mapping_missing_stages in diagnostic_codes
    assert :tracker_mapping_unknown_stages in diagnostic_codes
  end

  test "keeps static graph usable when snapshot is unavailable" do
    definition = workflow_definition!()

    projection = Visualization.project(definition, snapshot: :unavailable)

    refute projection.runtime.available?
    assert projection.runtime.error.code == "snapshot_unavailable"
    assert Enum.find(projection.stages, &(&1.id == "ready")).runtime.total == 0
    assert projection.transitions != []
  end

  test "summarizes snapshot timeout and unusual snapshot entries" do
    definition = workflow_definition!()

    timeout_projection = Visualization.project(definition, snapshot: :timeout)
    refute timeout_projection.runtime.available?
    assert timeout_projection.runtime.error.code == "snapshot_timeout"

    projection =
      Visualization.project(definition,
        snapshot: %{
          running: :not_a_list,
          retrying: [%{"issue_id" => "5", "issue_identifier" => "APP-5", "current_stage" => "ghost"}],
          blocked: [%{"issue_id" => "6", "identifier" => "APP-6"}, :invalid_entry]
        }
      )

    assert projection.runtime.available?

    assert [
             %{current_stage: "ghost", issue_id: "5", issue_identifier: "APP-5", status: :retrying},
             %{current_stage: nil, issue_id: "6", issue_identifier: "APP-6", status: :blocked},
             %{current_stage: nil, issue_id: nil, issue_identifier: nil, status: :blocked}
           ] = projection.runtime.unknown_stage_issues
  end

  test "handles derived tracker strategies, atom keys and non-secret provider hints" do
    definition = workflow_definition!()

    projection =
      Visualization.project(definition,
        tracker_config: %{
          tracker: %{
            kind: :memory,
            workflow_state: %{strategy: "scoped_label", label_prefix: "status::", state_name_format: "raw"},
            api_token: "secret-token"
          }
        }
      )

    assert projection.tracker.kind == "memory"
    assert projection.tracker.strategy == "scoped_label"
    assert projection.tracker.provider_hint == %{"state_label_prefix" => "status::"}
    assert Enum.find(projection.tracker.mappings, &(&1.stage == "ready")).provider_state == "status::ready"
    refute inspect(projection) =~ "secret-token"

    unknown_kind_projection =
      Visualization.project(definition,
        tracker_config: %{
          "tracker" => %{
            "kind" => 123,
            "stage_states" => %{"ready" => %{"state" => "Ready"}}
          }
        }
      )

    assert unknown_kind_projection.tracker.kind == nil
  end

  test "keeps projection stable for defensive non-string internals" do
    definition =
      workflow_definition!()
      |> put_in([Access.key!(:stages), "ready", "prompt"], String.duplicate("阶段", 130))
      |> put_in([Access.key!(:stages), "ready", "transitions", "blocked"], nil)
      |> put_in([Access.key!(:stages), "blocked", "prompt"], nil)

    projection = Visualization.project(definition)
    ready = Enum.find(projection.stages, &(&1.id == "ready"))
    blocked = Enum.find(projection.stages, &(&1.id == "blocked"))
    nil_target = Enum.find(ready.transitions, &(&1.outcome == "blocked"))

    assert String.ends_with?(ready.prompt_preview, "...")
    assert blocked.prompt_preview == ""
    refute nil_target.target_exists?
    refute nil_target.blocked_target?
    refute nil_target.protocol_blocked_target?
  end

  test "builds operator-readable error projection for invalid workflow files" do
    projection = Visualization.error_projection({:invalid_workflow_definition, "workflow.start_stage is required"})

    assert projection.error.code == "invalid_workflow_definition"
    assert projection.error.message =~ "Invalid WORKFLOW.md workflow schema"
    assert [%{severity: :error, code: :workflow_unavailable}] = projection.diagnostics
  end

  test "builds specific error codes for workflow load failures" do
    assert Visualization.error_projection({:workflow_parse_error, :bad_yaml}).error.code == "workflow_parse_error"

    assert Visualization.error_projection({:missing_workflow_file, "/tmp/WORKFLOW.md", :enoent}).error.code ==
             "missing_workflow_file"

    assert Visualization.error_projection(:workflow_front_matter_not_a_map).error.code ==
             "workflow_front_matter_not_a_map"

    assert Visualization.error_projection(:custom_failure).error.code == "_custom_failure"
  end

  defp workflow_definition!(overrides \\ %{}) do
    workflow =
      Map.merge(
        %{
          "start_stage" => "ready",
          "terminal_stages" => ["done", "blocked", "protocol_blocked"],
          "outcomes" => ["started", "completed", "blocked"],
          "missing_outcome" => %{"max_retries" => 2, "on_exhausted" => "protocol_blocked"},
          "stages" => %{
            "ready" => %{
              "prompt" => "Pick up new work.",
              "transitions" => %{"started" => "in_progress", "blocked" => "blocked"}
            },
            "in_progress" => %{
              "prompt" => "Implement the accepted scope.",
              "transitions" => %{"completed" => "done", "blocked" => "blocked"}
            },
            "done" => %{"prompt" => "Terminal done stage.", "transitions" => %{}},
            "blocked" => %{"prompt" => "Terminal blocked stage.", "transitions" => %{}},
            "protocol_blocked" => %{"prompt" => "Terminal protocol blocked stage.", "transitions" => %{}}
          }
        },
        overrides
      )

    assert {:ok, definition} = Definition.parse(workflow)
    definition
  end

  defp tracker_config do
    %{
      "tracker" => %{
        "kind" => "linear",
        "project_slug" => "team/project",
        "api_key" => "lin_secret_token",
        "stage_states" => %{
          "ready" => %{"state" => "Ready"},
          "in_progress" => %{"state" => "In Progress"},
          "done" => %{"state" => "Done", "terminal" => true},
          "blocked" => %{"state" => "Blocked", "terminal" => true},
          "protocol_blocked" => %{"state" => "Protocol Blocked", "terminal" => true}
        }
      }
    }
  end
end
