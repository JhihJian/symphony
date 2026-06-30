defmodule SymphonyElixir.StageOutcomeChannel do
  @moduledoc """
  Runner-internal structured outcome channel for workflow stages.
  """

  @tool_name "symphony_stage_outcome"
  @description """
  Submit the workflow stage outcome for this Symphony runner turn.
  This tool is runner-internal and drives stage transitions.
  """

  @type capture :: %{
          required(:stage_id) => String.t(),
          required(:outcomes) => [String.t()],
          required(:transitions) => %{String.t() => String.t()},
          required(:recorder) => pid(),
          required(:submissions) => [map()]
        }

  @type validation_result ::
          {:ok, %{outcome: String.t() | nil, target_stage: String.t() | nil, submissions: [map()]}}
          | {:error, {:stage_outcome_protocol_error, atom(), map()}}

  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @spec tool_spec([String.t()]) :: map()
  def tool_spec(outcomes) when is_list(outcomes) do
    %{
      "name" => @tool_name,
      "description" => @description,
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["outcome"],
        "properties" => %{
          "outcome" => %{
            "type" => "string",
            "enum" => outcomes,
            "description" => "Workflow outcome selected for the current stage turn."
          },
          "summary" => %{
            "type" => "string",
            "description" => "Short factual summary of the completed stage work."
          }
        }
      }
    }
  end

  @spec new(String.t(), [String.t()], %{String.t() => String.t()}) :: capture()
  def new(stage_id, outcomes, transitions) when is_binary(stage_id) and is_list(outcomes) and is_map(transitions) do
    {:ok, recorder} = Agent.start_link(fn -> [] end)

    %{
      stage_id: stage_id,
      outcomes: Enum.map(outcomes, &to_string/1),
      transitions: normalize_string_map(transitions),
      recorder: recorder,
      submissions: []
    }
  end

  @spec execute(capture(), term()) :: {capture(), map()}
  def execute(%{outcomes: outcomes, transitions: transitions, recorder: recorder} = capture, arguments) do
    outcome = outcome_argument(arguments)
    summary = summary_argument(arguments)
    submitted_at = DateTime.utc_now() |> DateTime.to_iso8601()

    submission = %{
      "outcome" => outcome,
      "summary" => summary,
      "submitted_at" => submitted_at
    }

    Agent.update(recorder, &(&1 ++ [submission]))
    updated_capture = %{capture | submissions: submissions(capture)}

    cond do
      is_nil(outcome) ->
        {updated_capture, failure(:missing_outcome, "Stage outcome submission requires a non-empty `outcome`.")}

      not Map.has_key?(transitions, outcome) ->
        if outcome in outcomes do
          {updated_capture, failure(:outcome_without_transition, "Stage outcome `#{outcome}` has no transition from the current stage.")}
        else
          {updated_capture, failure(:unknown_outcome, "Unknown workflow outcome `#{outcome}`.")}
        end

      true ->
        target_stage = Map.fetch!(transitions, outcome)

        {updated_capture,
         success(%{
           "outcome" => outcome,
           "target_stage" => target_stage,
           "message" => "Stage outcome accepted."
         })}
    end
  end

  @spec validate(capture()) :: validation_result()
  def validate(%{stage_id: stage_id, outcomes: outcomes, transitions: transitions} = capture) do
    submissions = submissions(capture)

    if map_size(transitions) == 0 and submissions == [] do
      {:ok, %{outcome: nil, target_stage: nil, submissions: []}}
    else
      valid_submissions =
        Enum.filter(submissions, fn %{"outcome" => outcome} ->
          is_binary(outcome) and Map.has_key?(transitions, outcome)
        end)

      case valid_submissions do
        [%{"outcome" => outcome} | []] ->
          {:ok, %{outcome: outcome, target_stage: Map.fetch!(transitions, outcome), submissions: submissions}}

        [] ->
          reason =
            if Enum.any?(submissions, &outcome_without_transition?(&1, outcomes, transitions)) do
              :outcome_without_transition
            else
              :missing_outcome
            end

          protocol_error(reason, stage_id, outcomes, transitions, submissions)

        _multiple ->
          protocol_error(:multiple_outcomes, stage_id, outcomes, transitions, submissions)
      end
    end
  end

  @spec stop(capture() | nil) :: :ok
  def stop(%{recorder: recorder}) when is_pid(recorder) do
    if Process.alive?(recorder) do
      Agent.stop(recorder, :normal, 1_000)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  def stop(_capture), do: :ok

  defp submissions(%{recorder: recorder}) when is_pid(recorder) do
    if Process.alive?(recorder) do
      Agent.get(recorder, & &1)
    else
      []
    end
  end

  defp protocol_error(reason, stage_id, outcomes, transitions, submissions) do
    invalid_outcomes =
      submissions
      |> Enum.map(&Map.get(&1, "outcome"))
      |> Enum.reject(fn outcome -> is_binary(outcome) and Map.has_key?(transitions, outcome) end)

    {:error,
     {:stage_outcome_protocol_error, reason,
      %{
        stage_id: stage_id,
        workflow_outcomes: outcomes,
        allowed_outcomes: Map.keys(transitions) |> Enum.sort(),
        submissions: submissions,
        invalid_outcomes: invalid_outcomes
      }}}
  end

  defp outcome_without_transition?(%{"outcome" => outcome}, outcomes, transitions) when is_binary(outcome) do
    outcome in outcomes and not Map.has_key?(transitions, outcome)
  end

  defp outcome_without_transition?(_submission, _outcomes, _transitions), do: false

  defp outcome_argument(arguments) when is_map(arguments) do
    arguments
    |> Map.get("outcome", Map.get(arguments, :outcome))
    |> normalize_optional_string()
  end

  defp outcome_argument(_arguments), do: nil

  defp summary_argument(arguments) when is_map(arguments) do
    arguments
    |> Map.get("summary", Map.get(arguments, :summary))
    |> normalize_optional_string()
  end

  defp summary_argument(_arguments), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp normalize_string_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp success(payload) do
    %{
      "success" => true,
      "output" => Jason.encode!(payload, pretty: true)
    }
  end

  defp failure(reason, message) do
    %{
      "success" => false,
      "output" =>
        Jason.encode!(
          %{
            "error" => %{
              "reason" => reason,
              "message" => message
            }
          },
          pretty: true
        )
    }
  end
end
