defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.

  The stage-aware contract uses provider-neutral workflow stage ids at this
  boundary. Provider-visible states, labels, or native statuses are external
  observation and recovery records; they are not the normal trigger for moving
  one issue through workflow stages.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.TrackerConfig
  alias SymphonyElixir.Workflow.Definition

  @type stage_id :: String.t()
  @type validation_result :: :ok | {:error, {:invalid_tracker_config, String.t()}}
  @type stage_contract_error :: {:error, {:stage_contract_not_implemented, atom()}}

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback capabilities() :: map()
  @callback validate_workflow_state_mapping(map() | Definition.t(), map()) :: validation_result()
  @callback fetch_runnable_issues(stage_id()) :: {:ok, [term()]} | {:error, term()}
  @callback read_issue_stage(term()) :: {:ok, stage_id()} | {:error, term()}
  @callback write_issue_stage(String.t(), stage_id()) :: :ok | {:error, term()}
  @callback is_native_terminal?(term()) :: boolean() | {:error, term()}

  @spec capabilities() :: map()
  def capabilities do
    adapter().capabilities()
  end

  @spec validate_workflow_state_mapping(map() | Definition.t(), map()) :: validation_result()
  def validate_workflow_state_mapping(workflow, tracker_config) do
    tracker_config
    |> adapter_for_config()
    |> then(& &1.validate_workflow_state_mapping(workflow, tracker_config))
  end

  @spec fetch_runnable_issues(stage_id()) :: {:ok, [term()]} | {:error, term()}
  def fetch_runnable_issues(start_stage) do
    adapter().fetch_runnable_issues(start_stage)
  end

  @spec read_issue_stage(term()) :: {:ok, stage_id()} | {:error, term()}
  def read_issue_stage(issue_or_id) do
    adapter().read_issue_stage(issue_or_id)
  end

  @spec write_issue_stage(String.t(), stage_id()) :: :ok | {:error, term()}
  def write_issue_stage(issue_id, stage_id) do
    adapter().write_issue_stage(issue_id, stage_id)
  end

  @spec is_native_terminal?(term()) :: boolean() | {:error, term()}
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_native_terminal?(issue) do
    adapter().is_native_terminal?(issue)
  end

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec adapter() :: module()
  def adapter do
    Config.settings!().tracker.kind
    |> adapter_for_kind()
  end

  @doc false
  @spec adapter_for_config(map()) :: module()
  def adapter_for_config(tracker_config) when is_map(tracker_config) do
    tracker_config
    |> tracker_payload()
    |> Map.get("kind")
    |> adapter_for_kind()
  end

  @doc false
  @spec adapter_for_kind(term()) :: module()
  def adapter_for_kind(kind) when is_atom(kind), do: kind |> Atom.to_string() |> adapter_for_kind()
  def adapter_for_kind("memory"), do: SymphonyElixir.Tracker.Memory
  def adapter_for_kind("github"), do: SymphonyElixir.GitHub.Adapter
  def adapter_for_kind("gitlab"), do: SymphonyElixir.GitLab.Adapter
  def adapter_for_kind(_kind), do: SymphonyElixir.Linear.Adapter

  @doc false
  @spec validate_workflow_state_mapping_for_adapter(map() | Definition.t(), map(), keyword()) :: validation_result()
  def validate_workflow_state_mapping_for_adapter(workflow, tracker_config, opts \\ []) do
    workflow = workflow_to_map(workflow)

    with :ok <- TrackerConfig.validate_stage_states(workflow, tracker_config) do
      validate_known_provider_states(tracker_config, opts)
    end
  end

  @doc false
  @spec unsupported_stage_capabilities(atom()) :: map()
  def unsupported_stage_capabilities(kind) when is_atom(kind) do
    %{
      tracker: kind,
      stage_contract: :unsupported,
      reason: :stage_contract_not_implemented
    }
  end

  @doc false
  @spec unsupported_stage_contract(atom()) :: stage_contract_error()
  def unsupported_stage_contract(kind) when is_atom(kind) do
    {:error, {:stage_contract_not_implemented, kind}}
  end

  @doc false
  @spec normalize_provider_state(term()) :: String.t()
  def normalize_provider_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  def normalize_provider_state(_state), do: ""

  @spec workflow_to_map(map() | Definition.t()) :: map()
  defp workflow_to_map(%Definition{} = workflow), do: Definition.to_map(workflow)
  defp workflow_to_map(workflow) when is_map(workflow), do: normalize_keys(workflow)

  @spec validate_known_provider_states(map(), keyword()) :: validation_result()
  defp validate_known_provider_states(tracker_config, opts) do
    known_states =
      opts
      |> Keyword.get(:provider_states, provider_states(tracker_config))
      |> normalize_provider_state_set()

    if Enum.empty?(known_states) do
      :ok
    else
      tracker_config
      |> TrackerConfig.stage_states()
      |> Enum.flat_map(fn {stage_id, %{"state" => state}} ->
        if normalize_provider_state(state) in known_states do
          []
        else
          [{stage_id, state}]
        end
      end)
      |> unknown_provider_state_result(known_states)
    end
  end

  @spec unknown_provider_state_result([{String.t(), String.t()}], [String.t()]) :: validation_result()
  defp unknown_provider_state_result([], _known_states), do: :ok

  defp unknown_provider_state_result(unknown_states, known_states) do
    details =
      unknown_states
      |> Enum.map_join(", ", fn {stage_id, state} -> "#{stage_id}=#{inspect(state)}" end)

    known =
      known_states
      |> Enum.sort()
      |> Enum.join(", ")

    {:error, {:invalid_tracker_config, "TRACKER.yaml tracker.stage_states maps workflow stages to unknown provider states: #{details}; known provider states: #{known}"}}
  end

  @spec provider_states(map()) :: [String.t()]
  defp provider_states(tracker_config) do
    tracker_config
    |> tracker_payload()
    |> Map.get("provider_states", [])
  end

  @spec normalize_provider_state_set(term()) :: [String.t()]
  defp normalize_provider_state_set(states) when is_list(states) do
    states
    |> Enum.map(&normalize_provider_state/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_provider_state_set(_states), do: []

  @spec tracker_payload(map()) :: map()
  defp tracker_payload(config) when is_map(config) do
    config = normalize_keys(config)
    Map.get(config, "tracker", config)
  end

  @spec normalize_keys(term()) :: term()
  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  @spec normalize_key(term()) :: String.t()
  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)
end
