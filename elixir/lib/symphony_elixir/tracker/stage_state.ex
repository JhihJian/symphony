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

    stage_states()
    |> Enum.find_value(fn {stage_id, %{"state" => mapped_provider_state}} ->
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

  @spec stage_states() :: map()
  defp stage_states do
    Config.settings!().tracker.stage_states
  end

  @spec workflow_terminal_stages() :: [String.t()]
  defp workflow_terminal_stages do
    case Config.settings!().workflow do
      %{"terminal_stages" => stages} when is_list(stages) ->
        stages
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  @spec normalize_state(term()) :: String.t()
  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
