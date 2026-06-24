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
end
