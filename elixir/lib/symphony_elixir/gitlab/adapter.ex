defmodule SymphonyElixir.GitLab.Adapter do
  @moduledoc """
  GitLab-backed tracker adapter using project issues.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitLab.Client
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Workflow.Definition

  @spec capabilities() :: map()
  def capabilities, do: Tracker.unsupported_stage_capabilities(:gitlab)

  @spec validate_workflow_state_mapping(map() | Definition.t(), map()) :: Tracker.validation_result()
  def validate_workflow_state_mapping(workflow, tracker_config) do
    Tracker.validate_workflow_state_mapping_for_adapter(workflow, tracker_config)
  end

  @spec fetch_runnable_issues(Tracker.stage_id()) :: {:ok, [term()]} | {:error, term()}
  def fetch_runnable_issues(_start_stage), do: Tracker.unsupported_stage_contract(:gitlab)

  @spec read_issue_stage(term()) :: {:ok, Tracker.stage_id()} | {:error, term()}
  def read_issue_stage(_issue_or_id), do: Tracker.unsupported_stage_contract(:gitlab)

  @spec write_issue_stage(String.t(), Tracker.stage_id()) :: :ok | {:error, term()}
  def write_issue_stage(_issue_id, _stage_id), do: Tracker.unsupported_stage_contract(:gitlab)

  @spec is_native_terminal?(term()) :: boolean() | {:error, term()}
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_native_terminal?(_issue), do: Tracker.unsupported_stage_contract(:gitlab)

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
end
