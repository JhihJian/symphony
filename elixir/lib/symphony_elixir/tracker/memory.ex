defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.StageState
  alias SymphonyElixir.Workflow.Definition

  @spec capabilities() :: map()
  def capabilities do
    StageState.capabilities(:memory)
  end

  @spec validate_workflow_state_mapping(map() | Definition.t(), map()) :: Tracker.validation_result()
  def validate_workflow_state_mapping(workflow, tracker_config) do
    Tracker.validate_workflow_state_mapping_for_adapter(workflow, tracker_config)
  end

  @spec fetch_runnable_issues(Tracker.stage_id()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_runnable_issues(start_stage) when is_binary(start_stage) do
    StageState.fetch_runnable_issues(start_stage, &fetch_issues_by_states/1)
  end

  def fetch_runnable_issues(start_stage), do: StageState.fetch_runnable_issues(start_stage, &fetch_issues_by_states/1)

  @spec read_issue_stage(Issue.t() | String.t()) :: {:ok, Tracker.stage_id()} | {:error, term()}
  def read_issue_stage(%Issue{} = issue) do
    StageState.read_issue_stage(issue, &fetch_issue_states_by_ids/1)
  end

  def read_issue_stage(issue_id) when is_binary(issue_id) do
    StageState.read_issue_stage(issue_id, &fetch_issue_states_by_ids/1)
  end

  def read_issue_stage(issue_or_id), do: StageState.read_issue_stage(issue_or_id, &fetch_issue_states_by_ids/1)

  @spec write_issue_stage(String.t(), Tracker.stage_id()) :: :ok | {:error, term()}
  def write_issue_stage(issue_id, stage_id) when is_binary(issue_id) and is_binary(stage_id) do
    with {:ok, provider_state} <- StageState.provider_state_for_stage(stage_id),
         :ok <- replace_issue_state(issue_id, provider_state) do
      send_event({:memory_tracker_stage_update, issue_id, stage_id, provider_state})
      :ok
    end
  end

  def write_issue_stage(issue_id, stage_id), do: {:error, {:invalid_stage_write, issue_id, stage_id}}

  @spec is_native_terminal?(Issue.t()) :: boolean() | {:error, term()}
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_native_terminal?(%Issue{state: state}) do
    StageState.terminal_provider_state?(state)
  end

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_native_terminal?(issue), do: StageState.native_terminal?(issue)

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    send_event({:memory_tracker_fetch_candidate_issues, memory_project_id()})

    case configured_issues_for_project() do
      {:error, reason} -> {:error, reason}
      issues -> {:ok, issue_entries(issues)}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    case configured_issues_for_project() do
      {:error, reason} ->
        {:error, reason}

      issues ->
        {:ok,
         Enum.filter(issue_entries(issues), fn %Issue{state: state} ->
           MapSet.member?(normalized_states, normalize_state(state))
         end)}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    case configured_issues_for_project() do
      {:error, reason} ->
        {:error, reason}

      issues ->
        {:ok,
         Enum.filter(issue_entries(issues), fn %Issue{id: id} ->
           MapSet.member?(wanted_ids, id)
         end)}
    end
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

  defp configured_issues_for_project do
    project_id = memory_project_id()

    case Application.get_env(:symphony_elixir, :memory_tracker_issues_by_project) do
      issues_by_project when is_map(issues_by_project) and is_binary(project_id) ->
        Map.get(issues_by_project, project_id, [])

      _issues_by_project ->
        configured_issues()
    end
  end

  defp issue_entries(issues) when is_list(issues) do
    Enum.filter(issues, &match?(%Issue{}, &1))
  end

  defp issue_entries(_issues), do: []

  defp memory_project_id do
    case Config.settings() do
      {:ok, settings} ->
        case settings.tracker.kind do
          "memory" -> get_in(settings.workflow, ["hub", "project_id"]) || memory_project_id_from_workspace(settings.workspace.root)
          _other -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp memory_project_id_from_workspace(workspace_root) when is_binary(workspace_root) do
    workspace_root
    |> Path.basename()
    |> case do
      "" -> nil
      basename -> basename
    end
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
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

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
