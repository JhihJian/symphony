defmodule SymphonyElixir.StagePromptRenderer do
  @moduledoc """
  Renders the system-owned prompt wrapper for workflow stage turns.
  """

  alias SymphonyElixir.{Config, PromptBuilder, Workflow}
  alias SymphonyElixir.Workflow.Definition

  @type stage_context :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:prompt) => String.t(),
          required(:transitions) => %{String.t() => String.t()}
        }

  @spec render(Definition.t() | map(), String.t(), map(), keyword()) :: String.t()
  def render(workflow, stage_id, issue, opts \\ []) do
    workflow = workflow_map(workflow)
    stage_id = normalize_required_string(stage_id, "stage_id")
    stage = stage_context!(workflow, stage_id)

    stage_prompt =
      stage.prompt
      |> PromptBuilder.render_template(issue, opts)
      |> String.trim()

    [
      "# Symphony Stage Turn",
      "",
      "## Stage",
      "",
      "- id: #{stage.id}",
      "- name: #{stage.name}",
      "",
      "## Issue",
      "",
      issue_context(issue),
      "",
      "## Stage Prompt",
      "",
      blank_fallback(stage_prompt, "No stage prompt provided."),
      "",
      "## Workflow Outcomes",
      "",
      bullet_list(Map.get(workflow, "outcomes", [])),
      "",
      "## Current Stage Transitions",
      "",
      transition_list(stage.transitions),
      "",
      "## Stage Completion Protocol",
      "",
      completion_protocol(stage.transitions),
      "",
      "## Missing Outcome Policy",
      "",
      missing_outcome_policy(Map.get(workflow, "missing_outcome", %{}))
    ]
    |> Enum.join("\n")
  end

  @spec stage_for_issue(Definition.t() | map(), map(), map() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def stage_for_issue(workflow, issue, tracker_config \\ nil) do
    workflow = workflow_map(workflow)
    issue_state = issue_state(issue)

    cond do
      not is_binary(issue_state) or String.trim(issue_state) == "" ->
        {:ok, Map.fetch!(workflow, "start_stage")}

      is_map(tracker_config) ->
        stage_id_from_tracker_state(issue_state, tracker_config)
        |> case do
          {:ok, stage_id} -> {:ok, stage_id}
          :error -> stage_id_from_workflow_state(issue_state, workflow)
        end

      true ->
        stage_id_from_workflow_state(issue_state, workflow)
    end
  end

  @spec render_for_issue(Definition.t() | map(), map(), map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def render_for_issue(workflow, issue, tracker_config \\ nil, opts \\ []) do
    with {:ok, stage_id} <- stage_for_issue(workflow, issue, tracker_config) do
      {:ok, render(workflow, stage_id, issue, opts)}
    end
  end

  @spec current_for_issue(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def current_for_issue(issue, opts \\ []) do
    case Workflow.current() do
      {:ok, %{workflow: %Definition{} = workflow}} ->
        tracker_config = Keyword.get(opts, :tracker_config, Config.settings!().tracker_config)
        render_for_issue(workflow, issue, tracker_config, opts)

      {:ok, _workflow} ->
        {:error, :workflow_stage_config_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp workflow_map(%Definition{} = workflow), do: Definition.to_map(workflow)
  defp workflow_map(workflow) when is_map(workflow), do: normalize_keys(workflow)

  defp stage_context!(workflow, stage_id) do
    stages = Map.fetch!(workflow, "stages")
    stage = Map.fetch!(stages, stage_id)

    %{
      id: stage_id,
      name: Map.get(stage, "name", stage_id),
      prompt: Map.get(stage, "prompt", ""),
      transitions: Map.get(stage, "transitions", %{})
    }
  end

  defp issue_context(issue) do
    issue =
      issue
      |> PromptBuilder.template_issue()
      |> normalize_keys()

    [
      "- identifier: #{display_value(Map.get(issue, "identifier"))}",
      "- tracker: #{display_value(Map.get(issue, "tracker_kind"))}",
      "- title: #{display_value(Map.get(issue, "title"))}",
      "- current_status: #{display_value(Map.get(issue, "state"))}",
      "- labels: #{display_list(Map.get(issue, "labels", []))}",
      "- url: #{display_value(Map.get(issue, "url"))}",
      "",
      "Description:",
      "",
      description_text(Map.get(issue, "description"))
    ]
    |> Enum.join("\n")
  end

  defp completion_protocol(transitions) when map_size(transitions) == 0 do
    """
    This is a terminal stage. Complete the turn without submitting a stage outcome.
    """
    |> String.trim()
  end

  defp completion_protocol(transitions) do
    allowed_outcomes =
      transitions
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map_join(", ", &"`#{&1}`")

    """
    Before ending a successful non-terminal stage turn, submit exactly one structured stage outcome through the runner-provided stage outcome channel.
    The submitted outcome must be one of: #{allowed_outcomes}.
    Do not represent stage completion by directly setting the provider or tracker status; provider status tools are ordinary tracker operations and are not accepted as the stage result.
    Do not rely on final natural-language prose to communicate the stage outcome.
    """
    |> String.trim()
  end

  defp missing_outcome_policy(%{"max_retries" => max_retries, "on_exhausted" => on_exhausted}) do
    "If a turn completes without one valid structured stage outcome, the runner records a protocol error. It may retry up to #{max_retries} time(s); after retries are exhausted, the configured fallback stage is `#{on_exhausted}`."
  end

  defp missing_outcome_policy(_missing_outcome) do
    "If a turn completes without one valid structured stage outcome, the runner records a protocol error for later retry handling."
  end

  defp transition_list(transitions) when map_size(transitions) == 0, do: "- none"

  defp transition_list(transitions) do
    transitions
    |> Enum.sort_by(fn {outcome, _target} -> outcome end)
    |> Enum.map_join("\n", fn {outcome, target} -> "- #{outcome} -> #{target}" end)
  end

  defp bullet_list([]), do: "- none"
  defp bullet_list(values) when is_list(values), do: Enum.map_join(values, "\n", &"- #{&1}")

  defp blank_fallback(value, fallback) when is_binary(value) do
    if String.trim(value) == "", do: fallback, else: value
  end

  defp description_text(value) when is_binary(value) do
    if String.trim(value) == "", do: "No description provided.", else: value
  end

  defp description_text(_value), do: "No description provided."

  defp display_value(value) when is_binary(value) do
    if String.trim(value) == "", do: "Unavailable", else: value
  end

  defp display_value(nil), do: "Unavailable"
  defp display_value(value), do: to_string(value)

  defp display_list(values) when is_list(values) do
    case Enum.map(values, &display_value/1) do
      [] -> "[]"
      rendered -> Enum.join(rendered, ", ")
    end
  end

  defp display_list(_values), do: "[]"

  defp stage_id_from_tracker_state(issue_state, tracker_config) do
    stage_states =
      tracker_config
      |> normalize_keys()
      |> then(&Map.get(&1, "tracker", &1))
      |> Map.get("stage_states", %{})

    normalized_issue_state = normalize_state(issue_state)

    Enum.find_value(stage_states, :error, fn {stage_id, stage_config} ->
      case stage_config do
        %{"state" => provider_state} when is_binary(provider_state) ->
          if normalize_state(provider_state) == normalized_issue_state, do: {:ok, stage_id}, else: false

        _ ->
          false
      end
    end)
  end

  defp stage_id_from_workflow_state(issue_state, workflow) do
    normalized_issue_state = normalize_state(issue_state)

    workflow
    |> Map.get("stages", %{})
    |> Map.keys()
    |> Enum.find_value(fn stage_id ->
      if normalize_state(stage_id) == normalized_issue_state, do: {:ok, stage_id}, else: false
    end)
    |> case do
      {:ok, stage_id} -> {:ok, stage_id}
      nil -> {:error, {:unknown_workflow_stage_for_issue_state, issue_state}}
    end
  end

  defp issue_state(%_{} = issue), do: issue |> Map.from_struct() |> Map.get(:state)
  defp issue_state(%{} = issue), do: Map.get(issue, :state) || Map.get(issue, "state")
  defp issue_state(_issue), do: nil

  defp normalize_required_string(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> raise ArgumentError, "#{field} must be a non-empty string"
      trimmed -> trimmed
    end
  end

  defp normalize_required_string(_value, field), do: raise(ArgumentError, "#{field} must be a non-empty string")

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(value), do: value |> to_string() |> normalize_state()

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
