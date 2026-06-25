defmodule Mix.Tasks.Workflow.SplitTrackerConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Workflow.SplitTrackerConfig
  alias SymphonyElixir.TrackerConfig
  alias SymphonyElixir.Workflow

  setup do
    Mix.Task.reenable("workflow.split_tracker_config")
    :ok
  end

  test "splits legacy prompt-only workflow into provider-neutral workflow and TRACKER.yaml" do
    in_temp_project(fn ->
      File.write!("WORKFLOW.md", legacy_prompt_workflow())

      output =
        capture_io(fn ->
          SplitTrackerConfig.run(["--workflow", "WORKFLOW.md"])
        end)

      assert output =~ "Wrote provider-neutral workflow: WORKFLOW.md.migrated"
      assert output =~ "Wrote tracker/runtime config: ./TRACKER.yaml"

      assert {:ok, loaded_workflow} = Workflow.load("WORKFLOW.md.migrated")
      assert loaded_workflow.workflow.start_stage == "ready"
      refute Map.has_key?(loaded_workflow.config, "tracker")
      refute loaded_workflow.prompt =~ "Original implementation prompt"
      assert loaded_workflow.config["workflow"]["stages"]["in_progress"]["prompt"] =~ "Original implementation prompt"

      assert {:ok, tracker_config} = TrackerConfig.load("TRACKER.yaml")
      assert tracker_config["tracker"]["kind"] == "github"
      assert tracker_config["tracker"]["api_key"] == "$GITHUB_TOKEN"
      assert tracker_config["tracker"]["owner"] == "JhihJian"
      assert tracker_config["tracker"]["repo"] == "symphony"
      assert tracker_config["tracker"]["project_number"] == 3
      assert tracker_config["tracker"]["workflow_state"]["field_name"] == "Status"
      assert tracker_config["tracker"]["required_labels"] == ["symphony", "urgent"]
      assert tracker_config["tracker"]["stage_states"]["ready"]["state"] == "Ready"
      assert tracker_config["tracker"]["stage_states"]["in_progress"]["state"] == "In Progress"
      assert tracker_config["tracker"]["stage_states"]["done"]["terminal"] == true
      assert tracker_config["server"]["host"] == "0.0.0.0"
      assert tracker_config["workspace"]["root"] == "/tmp/symphony-workspaces"
      assert tracker_config["hooks"]["after_create"] =~ "git clone --depth 1"
      assert tracker_config["agent"]["max_concurrent_agents"] == 2
      assert tracker_config["codex"]["turn_sandbox_policy"]["networkAccess"] == true
      assert tracker_config["polling"]["interval_ms"] == 30_000
      assert tracker_config["observability"]["refresh_ms"] == 1_000
      assert tracker_config["worker"]["ssh_hosts"] == ["worker-a"]
    end)
  end

  test "splits workflow-stage front matter without carrying provider fields into WORKFLOW.md" do
    in_temp_project(fn ->
      File.write!("WORKFLOW.md", mixed_workflow_stage_config())

      SplitTrackerConfig.run([
        "--workflow",
        "WORKFLOW.md",
        "--workflow-out",
        "WORKFLOW.next.md",
        "--tracker-out",
        "TRACKER.next.yaml"
      ])

      assert {:ok, loaded_workflow} = Workflow.load("WORKFLOW.next.md")
      refute Map.has_key?(loaded_workflow.config, "tracker")
      assert loaded_workflow.config["workflow"]["stages"]["ready"]["prompt"] == "Pick up work."

      assert {:ok, tracker_config} = TrackerConfig.load("TRACKER.next.yaml")
      assert tracker_config["tracker"]["kind"] == "memory"
      assert tracker_config["tracker"]["stage_states"]["ready"]["state"] == "Ready"
      assert tracker_config["tracker"]["stage_states"]["done"]["terminal"] == true
      assert tracker_config["hooks"]["timeout_ms"] == 120_000
    end)
  end

  test "refuses to overwrite outputs unless force is set" do
    in_temp_project(fn ->
      File.write!("WORKFLOW.md", legacy_prompt_workflow())
      File.write!("TRACKER.yaml", "existing: true\n")

      assert_raise Mix.Error, ~r/Refusing to overwrite \.\/TRACKER.yaml/, fn ->
        SplitTrackerConfig.run(["--workflow", "WORKFLOW.md"])
      end

      SplitTrackerConfig.run(["--workflow", "WORKFLOW.md", "--force"])

      assert {:ok, tracker_config} = TrackerConfig.load("TRACKER.yaml")
      assert tracker_config["tracker"]["kind"] == "github"
    end)
  end

  test "prints help and validates CLI options" do
    output = capture_io(fn -> SplitTrackerConfig.run(["--help"]) end)
    assert output =~ "mix workflow.split_tracker_config --workflow /path/to/WORKFLOW.md"

    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      SplitTrackerConfig.run(["--wat"])
    end

    assert_raise Mix.Error, ~r/Missing required option --workflow/, fn ->
      SplitTrackerConfig.run([])
    end
  end

  test "reports read, parse, schema and output directory errors" do
    in_temp_project(fn ->
      assert_raise Mix.Error, ~r/Unable to read missing.md/, fn ->
        SplitTrackerConfig.run(["--workflow", "missing.md"])
      end

      File.write!("WORKFLOW.md", "---\n- item\n---\n")

      assert_raise Mix.Error, ~r/front matter must decode to a map/, fn ->
        SplitTrackerConfig.run(["--workflow", "WORKFLOW.md"])
      end

      File.write!("WORKFLOW.md", "---\ntracker: [\n---\n")

      assert_raise Mix.Error, ~r/Failed to parse WORKFLOW.md front matter/, fn ->
        SplitTrackerConfig.run(["--workflow", "WORKFLOW.md"])
      end

      File.write!("WORKFLOW.md", invalid_workflow_stage_config())

      assert_raise Mix.Error, ~r/Cannot split WORKFLOW.md without a valid workflow-stage definition/, fn ->
        SplitTrackerConfig.run(["--workflow", "WORKFLOW.md"])
      end

      File.write!("WORKFLOW.md", legacy_prompt_workflow())
      File.write!("not-a-dir", "file\n")

      assert_raise Mix.Error, ~r/Unable to create output directory/, fn ->
        SplitTrackerConfig.run(["--workflow", "WORKFLOW.md", "--workflow-out", "not-a-dir/WORKFLOW.md"])
      end
    end)
  end

  test "builds default workflow from a body-only workflow" do
    in_temp_project(fn ->
      File.write!("WORKFLOW.md", "Body-only prompt.\n")

      SplitTrackerConfig.run(["--workflow", "WORKFLOW.md"])

      assert {:ok, loaded_workflow} = Workflow.load("WORKFLOW.md.migrated")
      assert loaded_workflow.config["workflow"]["stages"]["in_progress"]["prompt"] == "Body-only prompt."

      assert {:ok, tracker_config} = TrackerConfig.load("TRACKER.yaml")
      assert tracker_config == %{}
    end)
  end

  test "uses fallback implementation prompt when legacy body is empty" do
    in_temp_project(fn ->
      File.write!("WORKFLOW.md", empty_prompt_legacy_workflow())

      SplitTrackerConfig.run(["--workflow", "WORKFLOW.md"])

      assert {:ok, loaded_workflow} = Workflow.load("WORKFLOW.md.migrated")

      assert loaded_workflow.config["workflow"]["stages"]["in_progress"]["prompt"] ==
               "Implement and validate the accepted scope for the current issue."
    end)
  end

  test "handles unclosed front matter and YAML emitter edge cases" do
    in_temp_project(fn ->
      File.write!("WORKFLOW.md", unclosed_front_matter_workflow())

      SplitTrackerConfig.run(["--workflow", "WORKFLOW.md"])

      assert {:ok, loaded_workflow} = Workflow.load("WORKFLOW.md.migrated")

      assert loaded_workflow.config["workflow"]["stages"]["in_progress"]["prompt"] ==
               "Implement and validate the accepted scope for the current issue."

      assert {:ok, tracker_config} = TrackerConfig.load("TRACKER.yaml")
      assert tracker_config["tracker"]["stage_states"]["ready"]["state"] == "Ready"
      assert tracker_config["tracker"]["stage_states"]["in_progress"]["state"] == "In Progress"
      assert tracker_config["tracker"]["stage_states"]["done"]["state"] == "Done"
      assert tracker_config["codex"]["servers"] == []
      assert tracker_config["codex"]["maybe_null"] == nil
      assert tracker_config["codex"]["quoted"] == "has: colon"
      assert tracker_config["codex"]["blank"] == ""
      assert tracker_config["codex"]["numeric"] == 7
      assert tracker_config["codex"]["floaty"] == 1.5
      refute Map.has_key?(tracker_config, "worker")
    end)
  end

  test "preserves explicit stage_states and workflow_state-derived mappings" do
    in_temp_project(fn ->
      File.write!("WORKFLOW.stage.md", explicit_stage_states_workflow())
      SplitTrackerConfig.run(["--workflow", "WORKFLOW.stage.md"])

      assert {:ok, tracker_config} = TrackerConfig.load("TRACKER.yaml")
      assert tracker_config["tracker"]["stage_states"]["ready"]["state"] == "Queued"
      assert tracker_config["tracker"]["stage_states"]["done"]["state"] == "Finished"

      File.write!("WORKFLOW.workflow-state.md", workflow_state_options_workflow())

      SplitTrackerConfig.run([
        "--workflow",
        "WORKFLOW.workflow-state.md",
        "--workflow-out",
        "WORKFLOW.workflow-state.next.md",
        "--tracker-out",
        "TRACKER.workflow-state.yaml"
      ])

      assert {:ok, tracker_config} = TrackerConfig.load("TRACKER.workflow-state.yaml")
      assert tracker_config["tracker"]["workflow_state"]["state_options"]["ready"] == "Ready"
      assert tracker_config["tracker"]["stage_states"]["ready"]["state"] == "Ready"
      assert tracker_config["tracker"]["stage_states"]["done"]["state"] == "Done"
    end)
  end

  defp in_temp_project(fun) do
    root = Path.join(System.tmp_dir!(), "workflow-split-tracker-config-test-#{System.unique_integer([:positive, :monotonic])}")
    original_cwd = File.cwd!()

    File.rm_rf!(root)
    File.mkdir_p!(root)

    try do
      File.cd!(root, fun)
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end

  defp legacy_prompt_workflow do
    """
    ---
    tracker:
      kind: github
      api_key: $GITHUB_TOKEN
      owner: JhihJian
      repo: symphony
      project_number: 3
      project_status_field_name: Status
      assignee: jhihjian
      empty_note: ""
      nullable_note:
      required_labels:
        - symphony
        - urgent
      active_states:
        - Ready
        - In Progress
      terminal_states:
        - Done
        - Blocked
    polling:
      interval_ms: 30000
    server:
      host: 0.0.0.0
    workspace:
      root: /tmp/symphony-workspaces
    hooks:
      timeout_ms: 300000
      after_create: |
        git clone --depth 1 https://github.com/JhihJian/symphony .
        cd elixir && mix deps.get
    agent:
      max_concurrent_agents: 2
    codex:
      command: codex app-server
      risky_arg: "- starts-with-dash"
      turn_sandbox_policy:
        type: workspaceWrite
        networkAccess: true
      servers:
        - name: local
          command: null
    observability:
      refresh_ms: 1000
    worker:
      ssh_hosts:
        - worker-a
    ---
    Original implementation prompt.
    """
  end

  defp empty_prompt_legacy_workflow do
    """
    ---
    tracker:
      kind: memory
      active_states:
        - 1
      terminal_states:
        - Done
    ---
    """
  end

  defp unclosed_front_matter_workflow do
    """
    ---
    tracker:
      kind: memory
      active_states:
        - ""
        -
      terminal_states: done
      project_status_field_name: ""
    worker:
      nested: {}
    codex:
      servers: []
      maybe_null:
      quoted: "has: colon"
      blank: ""
      numeric: 7
      floaty: 1.5
    """
  end

  defp mixed_workflow_stage_config do
    """
    ---
    tracker:
      kind: memory
      active_states:
        - Ready
      terminal_states:
        - Done
    hooks:
      timeout_ms: 120000
    workflow:
      start_stage: ready
      terminal_stages:
        - done
      outcomes:
        - started
      missing_outcome:
        max_retries: 1
        on_exhausted: done
      stages:
        ready:
          prompt: Pick up work.
          transitions:
            started: done
        done:
          prompt: Done.
          transitions: {}
    ---
    Legacy body should not be copied.
    """
  end

  defp invalid_workflow_stage_config do
    """
    ---
    workflow:
      start_stage: missing
      terminal_stages:
        - done
      outcomes:
        - started
      missing_outcome:
        max_retries: 1
        on_exhausted: done
      stages:
        ready:
          prompt: Ready.
          transitions:
            started: done
        done:
          prompt: Done.
          transitions: {}
    ---
    """
  end

  defp explicit_stage_states_workflow do
    """
    ---
    tracker:
      kind: memory
      stage_states:
        ready:
          state: Queued
        done:
          state: Finished
          terminal: true
    workflow:
      start_stage: ready
      terminal_stages:
        - done
      outcomes:
        - started
      missing_outcome:
        max_retries: 1
        on_exhausted: done
      stages:
        ready:
          prompt: Ready.
          transitions:
            started: done
        done:
          prompt: Done.
          transitions: {}
    ---
    """
  end

  defp workflow_state_options_workflow do
    """
    ---
    tracker:
      kind: memory
      workflow_state:
        strategy: project_v2_status
        state_options:
          ready: Ready
          done: Done
    workflow:
      start_stage: ready
      terminal_stages:
        - done
      outcomes:
        - started
      missing_outcome:
        max_retries: 1
        on_exhausted: done
      stages:
        ready:
          prompt: Ready.
          transitions:
            started: done
        done:
          prompt: Done.
          transitions: {}
    ---
    """
  end
end
