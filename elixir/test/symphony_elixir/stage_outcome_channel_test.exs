defmodule SymphonyElixir.StageOutcomeChannelTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.StageOutcomeChannel

  test "accepts one legal outcome and exposes its target transition" do
    capture = StageOutcomeChannel.new("ready", ["started", "blocked"], %{"started" => "in_progress"})

    try do
      {_capture, response} = StageOutcomeChannel.execute(capture, %{"outcome" => "started", "summary" => "Ready to work."})

      assert response["success"] == true
      assert Jason.decode!(response["output"])["target_stage"] == "in_progress"

      assert {:ok,
              %{
                outcome: "started",
                target_stage: "in_progress",
                submissions: [%{"outcome" => "started"}]
              }} = StageOutcomeChannel.validate(capture)
    after
      StageOutcomeChannel.stop(capture)
    end
  end

  test "unknown outcome is recorded as a protocol error" do
    capture = StageOutcomeChannel.new("ready", ["started", "blocked"], %{"started" => "in_progress"})

    try do
      {_capture, response} = StageOutcomeChannel.execute(capture, %{"outcome" => "approved"})

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["reason"] == "unknown_outcome"

      assert {:error,
              {:stage_outcome_protocol_error, :missing_outcome,
               %{
                 invalid_outcomes: ["approved"],
                 allowed_outcomes: ["started"]
               }}} = StageOutcomeChannel.validate(capture)
    after
      StageOutcomeChannel.stop(capture)
    end
  end

  test "completed turn with missing outcome is a protocol error" do
    capture = StageOutcomeChannel.new("ready", ["started", "blocked"], %{"started" => "in_progress"})

    try do
      assert {:error,
              {:stage_outcome_protocol_error, :missing_outcome,
               %{
                 stage_id: "ready",
                 allowed_outcomes: ["started"],
                 submissions: []
               }}} = StageOutcomeChannel.validate(capture)
    after
      StageOutcomeChannel.stop(capture)
    end
  end

  test "workflow outcome without current transition is a protocol error" do
    capture = StageOutcomeChannel.new("ready", ["started", "blocked"], %{"started" => "in_progress"})

    try do
      {_capture, response} = StageOutcomeChannel.execute(capture, %{"outcome" => "blocked"})

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["reason"] == "outcome_without_transition"

      assert {:error,
              {:stage_outcome_protocol_error, :outcome_without_transition,
               %{
                 invalid_outcomes: ["blocked"],
                 allowed_outcomes: ["started"],
                 workflow_outcomes: ["started", "blocked"]
               }}} = StageOutcomeChannel.validate(capture)
    after
      StageOutcomeChannel.stop(capture)
    end
  end

  test "terminal stage without transitions does not require an outcome" do
    capture = StageOutcomeChannel.new("done", ["completed", "blocked"], %{})

    try do
      assert {:ok, %{outcome: nil, target_stage: nil, submissions: []}} = StageOutcomeChannel.validate(capture)
    after
      StageOutcomeChannel.stop(capture)
    end
  end

  test "tool metadata exposes runner internal outcome schema" do
    spec = StageOutcomeChannel.tool_spec(["accepted", "blocked"])

    assert StageOutcomeChannel.tool_name() == "symphony_stage_outcome"
    assert spec["name"] == "symphony_stage_outcome"
    assert get_in(spec, ["inputSchema", "required"]) == ["outcome"]
    assert get_in(spec, ["inputSchema", "properties", "outcome", "enum"]) == ["accepted", "blocked"]
  end

  test "blank or non-map arguments are recorded as missing outcome submissions" do
    capture = StageOutcomeChannel.new("ready", [:started], %{started: :in_progress})

    try do
      {_capture, blank_response} = StageOutcomeChannel.execute(capture, %{outcome: " ", summary: " "})
      {_capture, non_map_response} = StageOutcomeChannel.execute(capture, "not a map")

      assert Jason.decode!(blank_response["output"])["error"]["reason"] == "missing_outcome"
      assert Jason.decode!(non_map_response["output"])["error"]["reason"] == "missing_outcome"

      assert {:error,
              {:stage_outcome_protocol_error, :missing_outcome,
               %{
                 invalid_outcomes: [nil, nil],
                 submissions: [
                   %{"outcome" => nil, "summary" => nil},
                   %{"outcome" => nil, "summary" => nil}
                 ]
               }}} = StageOutcomeChannel.validate(capture)
    after
      StageOutcomeChannel.stop(capture)
    end
  end

  test "multiple valid submissions are protocol errors" do
    capture = StageOutcomeChannel.new("ready", ["started"], %{"started" => "in_progress"})

    try do
      StageOutcomeChannel.execute(capture, %{"outcome" => "started"})
      StageOutcomeChannel.execute(capture, %{"outcome" => "started"})

      assert {:error,
              {:stage_outcome_protocol_error, :multiple_outcomes,
               %{
                 invalid_outcomes: [],
                 submissions: [%{"outcome" => "started"}, %{"outcome" => "started"}]
               }}} = StageOutcomeChannel.validate(capture)
    after
      StageOutcomeChannel.stop(capture)
    end
  end

  test "stop tolerates already stopped or invalid captures" do
    capture = StageOutcomeChannel.new("ready", ["started"], %{"started" => "in_progress"})
    recorder = capture.recorder

    Agent.stop(recorder)

    assert StageOutcomeChannel.validate(capture) ==
             {:error,
              {:stage_outcome_protocol_error, :missing_outcome,
               %{
                 stage_id: "ready",
                 workflow_outcomes: ["started"],
                 allowed_outcomes: ["started"],
                 submissions: [],
                 invalid_outcomes: []
               }}}

    assert :ok = StageOutcomeChannel.stop(capture)
    assert :ok = StageOutcomeChannel.stop(nil)
  end

  test "stop catches exits from non-agent recorder processes" do
    recorder =
      spawn(fn ->
        Process.sleep(:infinity)
      end)

    try do
      assert :ok = StageOutcomeChannel.stop(%{recorder: recorder})
    after
      if Process.alive?(recorder), do: Process.exit(recorder, :kill)
    end
  end
end
