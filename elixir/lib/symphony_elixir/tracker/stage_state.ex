defmodule SymphonyElixir.Tracker.StageState do
  @moduledoc """
  Shared stage-state mapping helpers for provider adapters.

  The helpers consume the normalized `tracker.stage_states` map from
  `TRACKER.yaml`. Providers still own their concrete reads and writes; this
  module only translates between provider-visible state names and workflow
  stage ids.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker

  @spec capabilities(atom()) :: map()
  def capabilities(kind) when is_atom(kind) do
    %{
      tracker: kind,
      stage_contract: :supported,
      fetch_runnable_issues: true,
      read_issue_stage: true,
      write_issue_stage: true,
      native_terminal: :workflow_terminal_stage
    }
  end

  @spec fetch_runnable_issues(Tracker.stage_id(), ([String.t()] -> {:ok, [Issue.t()]} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_runnable_issues(start_stage, fetch_issues_by_states)
      when is_binary(start_stage) and is_function(fetch_issues_by_states, 1) do
    with {:ok, provider_state} <- provider_state_for_stage(start_stage) do
      fetch_issues_by_states.([provider_state])
    end
  end

  def fetch_runnable_issues(start_stage, _fetch_issues_by_states), do: {:error, {:invalid_stage_id, start_stage}}

  @spec read_issue_stage(Issue.t() | String.t(), ([String.t()] -> {:ok, [Issue.t()]} | {:error, term()})) ::
          {:ok, Tracker.stage_id()} | {:error, term()}
  def read_issue_stage(%Issue{} = issue, _fetch_issue_states_by_ids) do
    stage_for_provider_state(issue.state)
  end

  def read_issue_stage(issue_id, fetch_issue_states_by_ids)
      when is_binary(issue_id) and is_function(fetch_issue_states_by_ids, 1) do
    case fetch_issue_states_by_ids.([issue_id]) do
      {:ok, [%Issue{} = issue | _]} -> read_issue_stage(issue, fetch_issue_states_by_ids)
      {:ok, []} -> {:error, :issue_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def read_issue_stage(issue_or_id, _fetch_issue_states_by_ids), do: {:error, {:invalid_issue, issue_or_id}}

  @spec write_issue_stage(
          String.t(),
          Tracker.stage_id(),
          (String.t(), String.t() -> :ok | {:error, term()})
        ) :: :ok | {:error, term()}
  def write_issue_stage(issue_id, stage_id, update_issue_state)
      when is_binary(issue_id) and is_binary(stage_id) and is_function(update_issue_state, 2) do
    with {:ok, provider_state} <- provider_state_for_stage(stage_id) do
      update_issue_state.(issue_id, provider_state)
    end
  end

  def write_issue_stage(issue_id, stage_id, _update_issue_state), do: {:error, {:invalid_stage_write, issue_id, stage_id}}

  @spec native_terminal?(Issue.t()) :: boolean() | {:error, term()}
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def native_terminal?(%Issue{} = issue) do
    case stage_for_provider_state(issue.state) do
      {:ok, stage_id} -> terminal_stage?(stage_id)
      {:error, reason} -> {:error, reason}
    end
  end

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def native_terminal?(issue), do: {:error, {:invalid_issue, issue}}

  @spec provider_state_for_stage(Tracker.stage_id()) :: {:ok, String.t()} | {:error, term()}
  def provider_state_for_stage(stage_id) when is_binary(stage_id) do
    case Map.get(stage_states(), stage_id) do
      %{"state" => state} when is_binary(state) -> {:ok, state}
      _ -> {:error, {:unknown_workflow_stage, stage_id}}
    end
  end

  def provider_state_for_stage(stage_id), do: {:error, {:invalid_stage_id, stage_id}}

  @spec stage_for_provider_state(term()) :: {:ok, Tracker.stage_id()} | {:error, term()}
  def stage_for_provider_state(provider_state) when is_binary(provider_state) do
    normalized_state = normalize_state(provider_state)
    states = stage_states()

    states
    |> ordered_stage_ids()
    |> Enum.find_value(fn stage_id ->
      mapped_provider_state = states |> Map.fetch!(stage_id) |> Map.fetch!("state")

      if normalize_state(mapped_provider_state) == normalized_state, do: stage_id
    end)
    |> case do
      stage_id when is_binary(stage_id) -> {:ok, stage_id}
      nil -> {:error, {:unmapped_provider_state, provider_state}}
    end
  end

  def stage_for_provider_state(provider_state), do: {:error, {:unmapped_provider_state, provider_state}}

  @spec terminal_stage?(Tracker.stage_id()) :: boolean()
  def terminal_stage?(stage_id) when is_binary(stage_id) do
    stage_id in workflow_terminal_stages() or
      stage_states()
      |> Map.get(stage_id, %{})
      |> Map.get("terminal", false)
  end

  def terminal_stage?(_stage_id), do: false

  @spec terminal_provider_state?(term()) :: boolean()
  def terminal_provider_state?(provider_state) when is_binary(provider_state) do
    case stage_for_provider_state(provider_state) do
      {:ok, stage_id} -> terminal_stage?(stage_id)
      {:error, _reason} -> false
    end
  end

  def terminal_provider_state?(_provider_state), do: false

  @spec completion_stage?(Tracker.stage_id()) :: boolean()
  def completion_stage?(stage_id) when is_binary(stage_id) do
    normalized_stage = normalize_state(stage_id)

    terminal_stage?(stage_id) and
      completion_stage_name?(normalized_stage) and
      not blocked_stage_name?(normalized_stage)
  end

  def completion_stage?(_stage_id), do: false

  @spec completion_provider_state?(term()) :: boolean()
  def completion_provider_state?(provider_state) when is_binary(provider_state) do
    case stage_for_provider_state(provider_state) do
      {:ok, stage_id} -> completion_stage?(stage_id)
      {:error, _reason} -> false
    end
  end

  def completion_provider_state?(_provider_state), do: false

  @spec workflow_provider_state?(term()) :: boolean()
  def workflow_provider_state?(provider_state) when is_binary(provider_state) do
    match?({:ok, _stage_id}, stage_for_provider_state(provider_state))
  end

  def workflow_provider_state?(_provider_state), do: false

  @spec start_provider_states() :: [String.t()]
  def start_provider_states do
    start_stage = Config.settings!().workflow |> Map.fetch!("start_stage")

    stage_states()
    |> provider_states_for_stage_ids([start_stage])
  end

  @spec terminal_provider_states() :: [String.t()]
  def terminal_provider_states do
    states = stage_states()
    configured_terminal_stages = workflow_terminal_stages()

    terminal_stage_ids =
      configured_terminal_stages ++
        (states
         |> ordered_stage_ids()
         |> Enum.filter(fn stage_id ->
           stage_id not in configured_terminal_stages and
             states
             |> Map.get(stage_id, %{})
             |> Map.get("terminal", false)
         end))

    terminal_stage_ids
    |> Enum.uniq()
    |> provider_states_for_stage_ids(states)
  end

  @spec non_terminal_provider_states() :: [String.t()]
  def non_terminal_provider_states do
    states = stage_states()

    states
    |> ordered_stage_ids()
    |> Enum.reject(&terminal_stage?/1)
    |> provider_states_for_stage_ids(states)
  end

  @spec all_provider_states() :: [String.t()]
  def all_provider_states do
    states = stage_states()

    states
    |> ordered_stage_ids()
    |> provider_states_for_stage_ids(states)
  end

  @spec stage_states() :: map()
  defp stage_states do
    Config.settings!().tracker.stage_states
  end

  @spec workflow_terminal_stages() :: [String.t()]
  defp workflow_terminal_stages do
    Config.settings!().workflow
    |> Map.fetch!("terminal_stages")
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp ordered_stage_ids(stage_states) when is_map(stage_states) do
    workflow = Config.settings!().workflow
    start_stage = Map.fetch!(workflow, "start_stage")
    stages = Map.fetch!(workflow, "stages")
    stage_names = Map.keys(stages)
    outcomes = Map.get(workflow, "outcomes", [])

    {ordered, visited} = walk_stage_graph([start_stage], [], [], stages, outcomes, stage_names)

    remaining =
      stage_names
      |> Enum.reject(&(&1 in visited))
      |> Enum.sort()

    ordered ++ remaining
  end

  defp walk_stage_graph([], visited, ordered, _stages, _outcomes, _stage_names) do
    {Enum.reverse(ordered), visited}
  end

  defp walk_stage_graph([stage_id | rest], visited, ordered, stages, outcomes, stage_names) do
    if stage_id in visited do
      walk_stage_graph(rest, visited, ordered, stages, outcomes, stage_names)
    else
      visited = [stage_id | visited]
      transitions = stages |> Map.get(stage_id, %{}) |> Map.get("transitions", %{})

      ordered_targets =
        outcomes
        |> Enum.map(&Map.get(transitions, &1))
        |> Enum.reject(&is_nil/1)

      unordered_targets =
        transitions
        |> Map.values()
        |> Enum.reject(&(&1 in ordered_targets))
        |> Enum.sort()

      targets =
        (ordered_targets ++ unordered_targets)
        |> Enum.filter(&(&1 in stage_names))
        |> Enum.reject(&(&1 in visited))

      walk_stage_graph(rest ++ targets, visited, [stage_id | ordered], stages, outcomes, stage_names)
    end
  end

  defp provider_states_for_stage_ids(stage_ids, stage_states) when is_list(stage_ids) and is_map(stage_states) do
    provider_states_for_stage_ids(stage_states, stage_ids)
  end

  defp provider_states_for_stage_ids(stage_states, stage_ids) when is_map(stage_states) and is_list(stage_ids) do
    stage_ids
    |> Enum.map(fn stage_id ->
      stage_states
      |> Map.fetch!(stage_id)
      |> Map.fetch!("state")
    end)
    |> normalize_provider_states()
  end

  defp normalize_provider_states(states) when is_list(states) do
    states
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @spec normalize_state(term()) :: String.t()
  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp completion_stage_name?(stage_id) do
    stage_id in ["done", "complete", "completed", "merged", "closed", "resolved", "delivered"] or
      String.contains?(stage_id, ["done", "complete", "merged", "resolved", "delivered"])
  end

  defp blocked_stage_name?(stage_id) do
    String.contains?(stage_id, [
      "blocked",
      "protocol",
      "rework",
      "review",
      "fail",
      "error",
      "cancel",
      "duplicate",
      "invalid"
    ])
  end
end
