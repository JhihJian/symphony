defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Workflow.Definition

  @spec capabilities() :: map()
  def capabilities do
    %{
      tracker: :memory,
      stage_contract: :supported,
      fetch_runnable_issues: true,
      read_issue_stage: true,
      write_issue_stage: true,
      native_terminal: :explicit_stage_state_terminal_flag
    }
  end

  @spec validate_workflow_state_mapping(map() | Definition.t(), map()) :: Tracker.validation_result()
  def validate_workflow_state_mapping(workflow, tracker_config) do
    Tracker.validate_workflow_state_mapping_for_adapter(workflow, tracker_config)
  end

  @spec fetch_runnable_issues(Tracker.stage_id()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_runnable_issues(start_stage) when is_binary(start_stage) do
    with {:ok, state} <- provider_state_for_stage(start_stage) do
      fetch_issues_by_states([state])
    end
  end

  def fetch_runnable_issues(start_stage), do: {:error, {:invalid_stage_id, start_stage}}

  @spec read_issue_stage(Issue.t() | String.t()) :: {:ok, Tracker.stage_id()} | {:error, term()}
  def read_issue_stage(%Issue{} = issue) do
    stage_for_provider_state(issue.state)
  end

  def read_issue_stage(issue_id) when is_binary(issue_id) do
    issue_id
    |> find_issue()
    |> case do
      %Issue{} = issue -> read_issue_stage(issue)
      nil -> {:error, :issue_not_found}
    end
  end

  def read_issue_stage(issue_or_id), do: {:error, {:invalid_issue, issue_or_id}}

  @spec write_issue_stage(String.t(), Tracker.stage_id()) :: :ok | {:error, term()}
  def write_issue_stage(issue_id, stage_id) when is_binary(issue_id) and is_binary(stage_id) do
    with {:ok, provider_state} <- provider_state_for_stage(stage_id),
         :ok <- replace_issue_state(issue_id, provider_state) do
      send_event({:memory_tracker_stage_update, issue_id, stage_id, provider_state})
      :ok
    end
  end

  def write_issue_stage(issue_id, stage_id), do: {:error, {:invalid_stage_write, issue_id, stage_id}}

  @spec is_native_terminal?(Issue.t()) :: boolean() | {:error, term()}
  def is_native_terminal?(%Issue{state: state}) do
    terminal_provider_states()
    |> MapSet.member?(normalize_state(state))
  end

  def is_native_terminal?(issue), do: {:error, {:invalid_issue, issue}}

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp provider_state_for_stage(stage_id) do
    case Map.get(stage_states(), stage_id) do
      %{"state" => state} when is_binary(state) -> {:ok, state}
      _ -> {:error, {:unknown_workflow_stage, stage_id}}
    end
  end

  defp stage_for_provider_state(state) do
    normalized_state = normalize_state(state)

    stage_states()
    |> Enum.find_value(fn {stage_id, %{"state" => provider_state}} ->
      if normalize_state(provider_state) == normalized_state, do: stage_id
    end)
    |> case do
      stage_id when is_binary(stage_id) -> {:ok, stage_id}
      nil -> {:error, {:unmapped_provider_state, state}}
    end
  end

  defp replace_issue_state(issue_id, provider_state) do
    {issues, replaced?} =
      configured_issues()
      |> Enum.map_reduce(false, fn
        %Issue{id: ^issue_id} = issue, _replaced? ->
          {%Issue{issue | state: provider_state}, true}

        issue, replaced? ->
          {issue, replaced?}
      end)

    if replaced? do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
      :ok
    else
      {:error, :issue_not_found}
    end
  end

  defp find_issue(issue_id) do
    Enum.find(issue_entries(), &(&1.id == issue_id))
  end

  defp stage_states do
    Config.settings!().tracker.stage_states
  end

  defp terminal_provider_states do
    stage_states()
    |> Enum.filter(fn {_stage_id, config} -> Map.get(config, "terminal", false) == true end)
    |> Enum.map(fn {_stage_id, config} -> Map.get(config, "state") end)
    |> Enum.map(&normalize_state/1)
    |> MapSet.new()
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
