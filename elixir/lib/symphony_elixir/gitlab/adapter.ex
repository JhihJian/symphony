defmodule SymphonyElixir.GitLab.Adapter do
  @moduledoc """
  GitLab-backed tracker adapter using project issues.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitLab.Client
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.StageState
  alias SymphonyElixir.Workflow.Definition

  @spec capabilities() :: map()
  def capabilities, do: StageState.capabilities(:gitlab)

  @spec validate_workflow_state_mapping(map() | Definition.t(), map()) :: Tracker.validation_result()
  def validate_workflow_state_mapping(workflow, tracker_config) do
    with :ok <- Tracker.validate_workflow_state_mapping_for_adapter(workflow, tracker_config) do
      validate_scoped_label_strategy(tracker_config)
    end
  end

  @spec fetch_runnable_issues(Tracker.stage_id()) :: {:ok, [term()]} | {:error, term()}
  def fetch_runnable_issues(start_stage) do
    with {:ok, issues} <- StageState.fetch_runnable_issues(start_stage, &fetch_issues_by_states/1) do
      reject_scoped_label_conflicts(issues)
    end
  end

  @spec read_issue_stage(term()) :: {:ok, Tracker.stage_id()} | {:error, term()}
  def read_issue_stage(%Issue{} = issue) do
    with :ok <- reject_scoped_label_conflict(issue) do
      StageState.read_issue_stage(issue, &fetch_issue_states_by_ids/1)
    end
  end

  def read_issue_stage(issue_id) when is_binary(issue_id) do
    case fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{} = issue | _]} -> read_issue_stage(issue)
      {:ok, []} -> {:error, :issue_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def read_issue_stage(issue_or_id), do: StageState.read_issue_stage(issue_or_id, &fetch_issue_states_by_ids/1)

  @spec write_issue_stage(String.t(), Tracker.stage_id()) :: :ok | {:error, term()}
  def write_issue_stage(issue_id, stage_id) when is_binary(issue_id) and is_binary(stage_id) do
    if scoped_label_strategy?() do
      with {:ok, provider_state} <- StageState.provider_state_for_stage(stage_id),
           :ok <-
             client_module().write_scoped_label_stage(
               issue_id,
               provider_state,
               scoped_label_write_options(stage_id)
             ) do
        :ok
      end
    else
      StageState.write_issue_stage(issue_id, stage_id, &update_issue_state/2)
    end
  end

  def write_issue_stage(issue_id, stage_id), do: {:error, {:invalid_stage_write, issue_id, stage_id}}

  @spec is_native_terminal?(term()) :: boolean() | {:error, term()}
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_native_terminal?(%Issue{} = issue), do: StageState.native_terminal?(issue)

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_native_terminal?(issue), do: StageState.native_terminal?(issue)

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body), do: client_module().create_comment(issue_id, body)

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name), do: client_module().update_issue_state(issue_id, state_name)

  defp client_module do
    Application.get_env(:symphony_elixir, :gitlab_client_module, Client)
  end

  defp validate_scoped_label_strategy(tracker_config) do
    tracker = tracker_payload(tracker_config)
    workflow_state = workflow_state_config(tracker)

    cond do
      Map.get(workflow_state, "strategy") != "scoped_label" ->
        :ok

      not is_binary(Map.get(workflow_state, "label_prefix")) ->
        {:error, {:invalid_tracker_config, "TRACKER.yaml tracker.workflow_state.strategy=scoped_label requires workflow_state.label_prefix"}}

      true ->
        :ok
    end
  end

  defp scoped_label_write_options(stage_id) do
    %{
      close?: stage_id in close_on_terminal_stages(),
      remove_labels: scoped_state_labels_except(stage_id)
    }
  end

  defp close_on_terminal_stages do
    Config.settings!().tracker_config
    |> tracker_payload()
    |> workflow_state_config()
    |> Map.get("close_on_terminal", [])
    |> Enum.filter(&is_binary/1)
  end

  defp scoped_state_labels_except(stage_id) do
    Config.settings!().tracker.stage_states
    |> Enum.reject(fn {mapped_stage_id, _config} -> mapped_stage_id == stage_id end)
    |> Enum.map(fn {_mapped_stage_id, config} -> Map.get(config, "state") end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp reject_scoped_label_conflict(%Issue{labels: labels}) when is_list(labels) do
    if scoped_label_strategy?() do
      configured_labels = MapSet.new(scoped_state_labels_except(nil), &normalize_label/1)

      matches =
        labels
        |> Enum.filter(&(is_binary(&1) and MapSet.member?(configured_labels, normalize_label(&1))))
        |> Enum.uniq_by(&normalize_label/1)

      case matches do
        [_single] -> :ok
        [] -> :ok
        conflicts -> {:error, {:gitlab_scoped_label_conflict, Enum.sort(conflicts)}}
      end
    else
      :ok
    end
  end

  defp reject_scoped_label_conflicts(issues) when is_list(issues) do
    Enum.reduce_while(issues, {:ok, issues}, fn
      %Issue{} = issue, {:ok, _issues} ->
        case reject_scoped_label_conflict(issue) do
          :ok -> {:cont, {:ok, issues}}
          {:error, {:gitlab_scoped_label_conflict, labels}} -> {:halt, {:error, {:gitlab_scoped_label_conflict, issue.id, labels}}}
        end

      _issue, {:ok, _issues} ->
        {:cont, {:ok, issues}}
    end)
  end

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  defp tracker_payload(config) when is_map(config) do
    config
    |> normalize_keys()
    |> then(&Map.get(&1, "tracker", &1))
  end

  defp workflow_state_config(tracker) when is_map(tracker) do
    case Map.get(tracker, "workflow_state") do
      workflow_state when is_map(workflow_state) -> normalize_keys(workflow_state)
      _other -> %{}
    end
  end

  defp scoped_label_strategy? do
    Config.settings!().tracker_config
    |> tracker_payload()
    |> workflow_state_config()
    |> Map.get("strategy")
    |> Kernel.==("scoped_label")
  end

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
