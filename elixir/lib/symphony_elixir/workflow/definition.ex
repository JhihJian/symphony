defmodule SymphonyElixir.Workflow.Definition do
  @moduledoc false

  defstruct [
    :start_stage,
    :terminal_stages,
    :outcomes,
    :missing_outcome,
    :stages
  ]

  @type stage :: %{
          required(String.t()) => %{
            required(String.t()) => String.t() | %{String.t() => String.t()}
          }
        }

  @type t :: %__MODULE__{
          start_stage: String.t(),
          terminal_stages: [String.t()],
          outcomes: [String.t()],
          missing_outcome: %{String.t() => non_neg_integer() | String.t()},
          stages: stage()
        }

  @spec parse_config(map()) :: {:ok, t()} | {:error, {:invalid_workflow_definition, String.t()}}
  def parse_config(config) when is_map(config) do
    config
    |> normalize_keys()
    |> workflow_payload()
    |> parse()
  end

  @spec parse(term()) :: {:ok, t()} | {:error, {:invalid_workflow_definition, String.t()}}
  def parse(workflow) when is_map(workflow) do
    workflow = normalize_keys(workflow)

    {stages, stage_errors} = parse_stages(Map.get(workflow, "stages"))
    {terminal_stages, terminal_errors} = string_list_field(workflow, "terminal_stages")
    {outcomes, outcome_errors} = string_list_field(workflow, "outcomes")
    {missing_outcome, missing_errors} = parse_missing_outcome(Map.get(workflow, "missing_outcome"))

    start_stage = string_value(Map.get(workflow, "start_stage"))

    errors =
      []
      |> require_string(start_stage, "workflow.start_stage")
      |> require_non_empty_list(terminal_stages, "workflow.terminal_stages")
      |> require_non_empty_list(outcomes, "workflow.outcomes")
      |> Kernel.++(stage_errors)
      |> Kernel.++(terminal_errors)
      |> Kernel.++(outcome_errors)
      |> Kernel.++(missing_errors)
      |> Kernel.++(membership_errors(start_stage, terminal_stages, missing_outcome, stages))
      |> Kernel.++(transition_errors(stages, outcomes))

    case errors do
      [] ->
        {:ok,
         %__MODULE__{
           start_stage: start_stage,
           terminal_stages: terminal_stages,
           outcomes: outcomes,
           missing_outcome: missing_outcome,
           stages: stages
         }}

      _ ->
        {:error, {:invalid_workflow_definition, Enum.join(errors, ", ")}}
    end
  end

  def parse(_workflow) do
    {:error, {:invalid_workflow_definition, "workflow must be a map"}}
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = definition) do
    %{
      "start_stage" => definition.start_stage,
      "terminal_stages" => definition.terminal_stages,
      "outcomes" => definition.outcomes,
      "missing_outcome" => definition.missing_outcome,
      "stages" => definition.stages
    }
  end

  defp workflow_payload(%{"workflow" => workflow}) when is_map(workflow), do: workflow

  defp workflow_payload(config) do
    if Enum.any?(["start_stage", "terminal_stages", "outcomes", "missing_outcome", "stages"], &Map.has_key?(config, &1)) do
      config
    else
      nil
    end
  end

  defp parse_stages(stages) when is_map(stages) and map_size(stages) > 0 do
    Enum.reduce(stages, {%{}, []}, fn {raw_stage_name, raw_stage}, {parsed, errors} ->
      stage_name = raw_stage_name |> to_string() |> String.trim()

      cond do
        stage_name == "" ->
          {parsed, ["workflow.stages contains a blank stage name" | errors]}

        not is_map(raw_stage) ->
          {parsed, ["workflow.stages.#{stage_name} must be a map" | errors]}

        true ->
          {stage, stage_errors} = parse_stage(stage_name, raw_stage)
          {Map.put(parsed, stage_name, stage), stage_errors ++ errors}
      end
    end)
    |> then(fn {parsed, errors} -> {parsed, Enum.reverse(errors)} end)
  end

  defp parse_stages(_stages), do: {%{}, ["workflow.stages must be a non-empty map"]}

  defp parse_stage(stage_name, raw_stage) do
    raw_stage = normalize_keys(raw_stage)
    prompt = Map.get(raw_stage, "prompt")
    {transitions, transition_errors} = parse_transitions(stage_name, Map.get(raw_stage, "transitions", %{}))

    errors =
      []
      |> require_binary(prompt, "workflow.stages.#{stage_name}.prompt")
      |> Kernel.++(transition_errors)

    {%{"prompt" => prompt || "", "transitions" => transitions}, errors}
  end

  defp parse_transitions(_stage_name, nil), do: {%{}, []}
  defp parse_transitions(_stage_name, transitions) when transitions == %{}, do: {%{}, []}

  defp parse_transitions(stage_name, transitions) when is_map(transitions) do
    Enum.reduce(transitions, {%{}, []}, fn {raw_outcome, raw_target}, {parsed, errors} ->
      outcome = raw_outcome |> to_string() |> String.trim()
      target = string_value(raw_target)

      cond do
        outcome == "" ->
          {parsed, ["workflow.stages.#{stage_name}.transitions contains a blank outcome" | errors]}

        is_nil(target) ->
          {parsed, ["workflow.stages.#{stage_name}.transitions.#{outcome} must target a stage string" | errors]}

        true ->
          {Map.put(parsed, outcome, target), errors}
      end
    end)
    |> then(fn {parsed, errors} -> {parsed, Enum.reverse(errors)} end)
  end

  defp parse_transitions(stage_name, _transitions) do
    {%{}, ["workflow.stages.#{stage_name}.transitions must be a map"]}
  end

  defp parse_missing_outcome(missing_outcome) when is_map(missing_outcome) do
    missing_outcome = normalize_keys(missing_outcome)
    max_retries = Map.get(missing_outcome, "max_retries")
    on_exhausted = string_value(Map.get(missing_outcome, "on_exhausted"))

    errors =
      []
      |> require_non_negative_integer(max_retries, "workflow.missing_outcome.max_retries")
      |> require_string(on_exhausted, "workflow.missing_outcome.on_exhausted")

    {%{"max_retries" => max_retries, "on_exhausted" => on_exhausted}, errors}
  end

  defp parse_missing_outcome(_missing_outcome) do
    {%{"max_retries" => nil, "on_exhausted" => nil}, ["workflow.missing_outcome must be a map"]}
  end

  defp string_list_field(map, field) do
    case Map.get(map, field) do
      values when is_list(values) ->
        {parsed, errors} =
          values
          |> Enum.with_index()
          |> Enum.reduce({[], []}, fn {raw_value, index}, {parsed, errors} ->
            case string_value(raw_value) do
              nil -> {parsed, ["workflow.#{field}[#{index}] must be a non-blank string" | errors]}
              value -> {[value | parsed], errors}
            end
          end)

        {Enum.reverse(parsed), Enum.reverse(errors)}

      _value ->
        {[], ["workflow.#{field} must be a list of strings"]}
    end
  end

  defp membership_errors(start_stage, terminal_stages, missing_outcome, stages) do
    stage_names = Map.keys(stages)
    stage_name_set = MapSet.new(stage_names)

    []
    |> maybe_unknown_stage(start_stage, stage_name_set, "workflow.start_stage")
    |> Kernel.++(unknown_stages(terminal_stages, stage_name_set, "workflow.terminal_stages"))
    |> maybe_unknown_stage(Map.get(missing_outcome, "on_exhausted"), stage_name_set, "workflow.missing_outcome.on_exhausted")
  end

  defp transition_errors(stages, outcomes) do
    stage_name_set = Map.keys(stages) |> MapSet.new()
    outcome_set = MapSet.new(outcomes)

    Enum.flat_map(stages, fn {stage_name, %{"transitions" => transitions}} ->
      Enum.flat_map(transitions, fn {outcome, target} ->
        []
        |> maybe_unknown_outcome(outcome, outcome_set, "workflow.stages.#{stage_name}.transitions")
        |> maybe_unknown_stage(target, stage_name_set, "workflow.stages.#{stage_name}.transitions.#{outcome}")
      end)
    end)
  end

  defp require_binary(errors, value, _path) when is_binary(value), do: errors
  defp require_binary(errors, _value, path), do: ["#{path} must be a string" | errors]

  defp require_string(errors, nil, path), do: ["#{path} is required" | errors]
  defp require_string(errors, _value, _path), do: errors

  defp require_non_empty_list(errors, values, _path) when is_list(values) and values != [], do: errors
  defp require_non_empty_list(errors, _values, path), do: ["#{path} must be a non-empty list" | errors]

  defp require_non_negative_integer(errors, value, _path) when is_integer(value) and value >= 0, do: errors

  defp require_non_negative_integer(errors, _value, path) do
    ["#{path} must be a non-negative integer" | errors]
  end

  defp maybe_unknown_stage(errors, nil, _stage_name_set, _path), do: errors

  defp maybe_unknown_stage(errors, stage, stage_name_set, path) do
    if MapSet.member?(stage_name_set, stage) do
      errors
    else
      ["#{path} references unknown stage #{inspect(stage)}" | errors]
    end
  end

  defp unknown_stages(stages, stage_name_set, path) do
    Enum.flat_map(stages, fn stage ->
      if MapSet.member?(stage_name_set, stage), do: [], else: ["#{path} references unknown stage #{inspect(stage)}"]
    end)
  end

  defp maybe_unknown_outcome(errors, outcome, outcome_set, path) do
    if MapSet.member?(outcome_set, outcome) do
      errors
    else
      ["#{path} references unknown outcome #{inspect(outcome)}" | errors]
    end
  end

  defp string_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_value(_value), do: nil

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)
end
