defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub-backed tracker adapter using repository issues plus Projects v2 status.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Workflow.Definition

  @spec capabilities() :: map()
  def capabilities, do: Tracker.unsupported_stage_capabilities(:github)

  @spec validate_workflow_state_mapping(map() | Definition.t(), map()) :: Tracker.validation_result()
  def validate_workflow_state_mapping(workflow, tracker_config) do
    with :ok <- Tracker.validate_workflow_state_mapping_for_adapter(workflow, tracker_config) do
      validate_project_backed_stage_states(tracker_config)
    end
  end

  @spec fetch_runnable_issues(Tracker.stage_id()) :: {:ok, [term()]} | {:error, term()}
  def fetch_runnable_issues(_start_stage), do: Tracker.unsupported_stage_contract(:github)

  @spec read_issue_stage(term()) :: {:ok, Tracker.stage_id()} | {:error, term()}
  def read_issue_stage(_issue_or_id), do: Tracker.unsupported_stage_contract(:github)

  @spec write_issue_stage(String.t(), Tracker.stage_id()) :: :ok | {:error, term()}
  def write_issue_stage(_issue_id, _stage_id), do: Tracker.unsupported_stage_contract(:github)

  @spec is_native_terminal?(term()) :: boolean() | {:error, term()}
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_native_terminal?(_issue), do: Tracker.unsupported_stage_contract(:github)

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
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end

  defp validate_project_backed_stage_states(tracker_config) do
    tracker = tracker_payload(tracker_config)

    if is_integer(Map.get(tracker, "project_number")) do
      :ok
    else
      tracker
      |> SymphonyElixir.TrackerConfig.stage_states()
      |> Enum.map(fn {_stage_id, stage_config} -> Map.get(stage_config, "state") end)
      |> Enum.map(&Tracker.normalize_provider_state/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> case do
        [_single_state] ->
          :ok

        states ->
          {:error,
           {:invalid_tracker_config,
            "GitHub issues-only tracker cannot represent multiple provider-visible workflow stage states without tracker.project_number; configured states: #{Enum.join(Enum.sort(states), ", ")}"}}
      end
    end
  end

  defp tracker_payload(config) when is_map(config) do
    config
    |> normalize_keys()
    |> then(&Map.get(&1, "tracker", &1))
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
