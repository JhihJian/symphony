defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub-backed tracker adapter using repository issues plus Projects v2 status.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.StageState
  alias SymphonyElixir.Workflow.Definition

  @spec capabilities() :: map()
  def capabilities do
    if project_backed?() do
      StageState.capabilities(:github)
    else
      %{
        tracker: :github,
        stage_contract: :unsupported,
        reason: :github_issues_only_no_multistage_state
      }
    end
  end

  @spec validate_workflow_state_mapping(map() | Definition.t(), map()) :: Tracker.validation_result()
  def validate_workflow_state_mapping(workflow, tracker_config) do
    with :ok <- Tracker.validate_workflow_state_mapping_for_adapter(workflow, tracker_config) do
      validate_project_backed_stage_states(workflow_to_map(workflow), tracker_config)
    end
  end

  @spec fetch_runnable_issues(Tracker.stage_id()) :: {:ok, [term()]} | {:error, term()}
  def fetch_runnable_issues(start_stage) do
    if project_backed?() do
      StageState.fetch_runnable_issues(start_stage, &fetch_issues_by_states/1)
    else
      github_issues_only_stage_contract_error()
    end
  end

  @spec read_issue_stage(term()) :: {:ok, Tracker.stage_id()} | {:error, term()}
  def read_issue_stage(%Issue{} = issue) do
    if project_backed?() do
      issue
      |> effective_issue_state()
      |> stage_for_effective_provider_state()
    else
      github_issues_only_stage_contract_error()
    end
  end

  def read_issue_stage(issue_id) when is_binary(issue_id) do
    if project_backed?() do
      with {:ok, provider_state} <- client_module().read_project_issue_state(issue_id) do
        stage_for_effective_provider_state(provider_state)
      end
    else
      github_issues_only_stage_contract_error()
    end
  end

  def read_issue_stage(issue_or_id) do
    if project_backed?() do
      {:error, {:invalid_issue, issue_or_id}}
    else
      github_issues_only_stage_contract_error()
    end
  end

  @spec write_issue_stage(String.t(), Tracker.stage_id()) :: :ok | {:error, term()}
  def write_issue_stage(issue_id, stage_id) do
    if project_backed?() do
      StageState.write_issue_stage(issue_id, stage_id, &update_issue_state/2)
    else
      github_issues_only_stage_contract_error()
    end
  end

  @spec is_native_terminal?(term()) :: boolean() | {:error, term()}
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_native_terminal?(%Issue{} = issue) do
    effective_issue_state(issue)
    |> terminal_effective_provider_state?()
  end

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_native_terminal?(issue) do
    if project_backed?() do
      {:error, {:invalid_issue, issue}}
    else
      github_issues_only_stage_contract_error()
    end
  end

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

  defp validate_project_backed_stage_states(workflow, tracker_config) do
    tracker = tracker_payload(tracker_config)

    if is_integer(Map.get(tracker, "project_number")) do
      :ok
    else
      tracker
      |> SymphonyElixir.TrackerConfig.stage_states(workflow)
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

  defp workflow_to_map(%Definition{} = workflow), do: Definition.to_map(workflow)
  defp workflow_to_map(workflow) when is_map(workflow), do: normalize_keys(workflow)

  defp project_backed? do
    is_integer(Config.settings!().tracker.project_number)
  end

  defp effective_issue_state(%Issue{state: "Closed"}), do: "Closed"
  defp effective_issue_state(%Issue{state: "CLOSED"}), do: "Closed"
  defp effective_issue_state(%Issue{state: state}), do: state

  defp stage_for_effective_provider_state("Closed") do
    case terminal_stage_for_native_closed() do
      stage_id when is_binary(stage_id) -> {:ok, stage_id}
      nil -> StageState.stage_for_provider_state("Closed")
    end
  end

  defp stage_for_effective_provider_state(provider_state) do
    StageState.stage_for_provider_state(provider_state)
  end

  defp terminal_effective_provider_state?("Closed"), do: true
  defp terminal_effective_provider_state?(state) when is_binary(state), do: StageState.terminal_provider_state?(state)
  defp terminal_effective_provider_state?(_state), do: false

  defp terminal_stage_for_native_closed do
    case Config.settings!().workflow do
      %{} = workflow ->
        workflow
        |> Map.get("terminal_stages", [])
        |> Enum.find(&is_binary/1)

      _other ->
        nil
    end
  end

  defp github_issues_only_stage_contract_error do
    {:error, {:stage_contract_not_supported, :github_issues_only}}
  end
end
