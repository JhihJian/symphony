defmodule SymphonyElixir.E2ESupport do
  @moduledoc false

  alias SymphonyElixir.Linear.Issue

  defmodule TrackerDouble do
    @moduledoc false

    use Agent

    alias SymphonyElixir.Config
    alias SymphonyElixir.Linear.Issue
    alias SymphonyElixir.Tracker

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      Agent.start_link(fn -> init(opts) end, name: name)
    end

    def init(opts) do
      issue = Keyword.fetch!(opts, :issue)

      %{
        issue: issue,
        events: []
      }
    end

    def child_spec(opts) do
      %{
        id: Keyword.fetch!(opts, :name),
        start: {__MODULE__, :start_link, [opts]}
      }
    end

    def capabilities do
      %{
        tracker: :e2e_tracker_double,
        stage_contract: :supported,
        fetch_runnable_issues: true,
        read_issue_stage: true,
        write_issue_stage: true,
        native_terminal: :explicit_stage_state_terminal_flag
      }
    end

    def validate_workflow_state_mapping(workflow, tracker_config) do
      Tracker.validate_workflow_state_mapping_for_adapter(workflow, tracker_config)
    end

    def fetch_runnable_issues(start_stage) do
      with {:ok, state} <- provider_state_for_stage(start_stage) do
        fetch_issues_by_states([state])
      end
    end

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

    def write_issue_stage(issue_id, stage_id) when is_binary(issue_id) and is_binary(stage_id) do
      with {:ok, provider_state} <- provider_state_for_stage(stage_id) do
        Agent.get_and_update(server!(), fn state ->
          if state.issue.id == issue_id do
            %Issue{} = issue = state.issue

            next_state =
              state
              |> Map.put(:issue, %Issue{issue | state: provider_state})
              |> record_event({:write_issue_stage, issue_id, stage_id, provider_state})

            {:ok, next_state}
          else
            {{:error, :issue_not_found}, record_event(state, {:write_issue_stage, issue_id, stage_id, provider_state})}
          end
        end)
      end
    end

    def write_issue_stage(issue_id, stage_id), do: {:error, {:invalid_stage_write, issue_id, stage_id}}

    # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
    def is_native_terminal?(%Issue{state: state}) do
      terminal_provider_states()
      |> MapSet.member?(normalize_state(state))
    end

    # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
    def is_native_terminal?(issue), do: {:error, {:invalid_issue, issue}}

    def fetch_candidate_issues do
      Agent.get_and_update(server!(), fn state ->
        {{:ok, candidate_issues(state)}, record_event(state, {:fetch_candidate_issues, []})}
      end)
    end

    def fetch_issues_by_states(states) do
      Agent.get_and_update(server!(), fn state ->
        normalized_states = MapSet.new(Enum.map(states, &normalize_state/1))

        issues =
          state
          |> candidate_issues()
          |> Enum.filter(&MapSet.member?(normalized_states, normalize_state(&1.state)))

        {{:ok, issues}, record_event(state, {:fetch_issues_by_states, states})}
      end)
    end

    def fetch_issue_states_by_ids(issue_ids) do
      Agent.get_and_update(server!(), fn state ->
        wanted_ids = MapSet.new(issue_ids)

        issues =
          state
          |> candidate_issues()
          |> Enum.filter(&MapSet.member?(wanted_ids, &1.id))

        {{:ok, issues}, record_event(state, {:fetch_issue_states_by_ids, issue_ids})}
      end)
    end

    def fetch_issue(issue_id) do
      Agent.get_and_update(server!(), fn state ->
        response =
          if state.issue.id == issue_id do
            {:ok, state.issue}
          else
            {:ok, nil}
          end

        {response, record_event(state, {:fetch_issue, issue_id})}
      end)
    end

    def list_comments(issue_id) do
      Agent.get_and_update(server!(), fn state ->
        {{:ok, []}, record_event(state, {:list_comments, issue_id})}
      end)
    end

    def upsert_workpad_comment(issue_id, body, header) do
      Agent.get_and_update(server!(), fn state ->
        result = %{
          "action" => "created",
          "comment" => %{"id" => "comment-#{issue_id}", "body" => body}
        }

        {{:ok, result}, record_event(state, {:upsert_workpad_comment, issue_id, body, header})}
      end)
    end

    def create_comment(issue_id, body) do
      Agent.update(server!(), &record_event(&1, {:create_comment, issue_id, body}))
      :ok
    end

    def add_labels(issue_id, labels) do
      Agent.get_and_update(server!(), fn state ->
        {{:ok, labels}, record_event(state, {:add_labels, issue_id, labels})}
      end)
    end

    def update_issue_state(issue_id, state_name) do
      Agent.get_and_update(server!(), fn state ->
        next_state =
          if state.issue.id == issue_id do
            %Issue{} = issue = state.issue
            %{state | issue: %Issue{issue | state: state_name}}
          else
            state
          end
          |> record_event({:update_issue_state, issue_id, state_name})

        {:ok, next_state}
      end)
    end

    def events(server) do
      Agent.get(server, &Enum.reverse(&1.events))
    end

    def issue(server) do
      Agent.get(server, & &1.issue)
    end

    defp candidate_issues(%{issue: %Issue{} = issue}), do: [issue]

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

    defp terminal_provider_states do
      stage_states()
      |> Enum.filter(fn {_stage_id, config} -> Map.get(config, "terminal", false) == true end)
      |> Enum.map(fn {_stage_id, %{"state" => state}} -> normalize_state(state) end)
      |> MapSet.new()
    end

    defp stage_states do
      Config.settings!().tracker.stage_states
    end

    defp find_issue(issue_id) do
      Enum.find(candidate_issues(Agent.get(server!(), & &1)), &(&1.id == issue_id))
    end

    defp record_event(state, event) do
      Map.update!(state, :events, &[event | &1])
    end

    defp normalize_state(state) when is_binary(state) do
      state
      |> String.trim()
      |> String.downcase()
    end

    defp normalize_state(_state), do: ""

    defp server! do
      Application.fetch_env!(:symphony_elixir, :e2e_tracker_double)
    end
  end

  defmodule GitHubTrackerDouble do
    @moduledoc false

    defdelegate start_link(opts), to: TrackerDouble
    defdelegate child_spec(opts), to: TrackerDouble
    defdelegate fetch_candidate_issues(), to: TrackerDouble
    defdelegate fetch_issues_by_states(states), to: TrackerDouble
    defdelegate fetch_issue_states_by_ids(issue_ids), to: TrackerDouble
    defdelegate fetch_runnable_issues(start_stage), to: TrackerDouble
    defdelegate read_issue_stage(issue_or_id), to: TrackerDouble
    defdelegate write_issue_stage(issue_id, stage_id), to: TrackerDouble
    defdelegate is_native_terminal?(issue), to: TrackerDouble
    defdelegate capabilities(), to: TrackerDouble
    defdelegate validate_workflow_state_mapping(workflow, tracker_config), to: TrackerDouble
    defdelegate fetch_issue(issue_id), to: TrackerDouble
    defdelegate list_comments(issue_id), to: TrackerDouble
    defdelegate upsert_workpad_comment(issue_id, body, header), to: TrackerDouble
    defdelegate create_comment(issue_id, body), to: TrackerDouble
    defdelegate add_labels(issue_id, labels), to: TrackerDouble
    defdelegate update_issue_state(issue_id, state_name), to: TrackerDouble
    defdelegate events(server), to: TrackerDouble
    defdelegate issue(server), to: TrackerDouble
  end

  defmodule GitLabTrackerDouble do
    @moduledoc false

    defdelegate start_link(opts), to: TrackerDouble
    defdelegate child_spec(opts), to: TrackerDouble
    defdelegate fetch_candidate_issues(), to: TrackerDouble
    defdelegate fetch_issues_by_states(states), to: TrackerDouble
    defdelegate fetch_issue_states_by_ids(issue_ids), to: TrackerDouble
    defdelegate fetch_runnable_issues(start_stage), to: TrackerDouble
    defdelegate read_issue_stage(issue_or_id), to: TrackerDouble
    defdelegate write_issue_stage(issue_id, stage_id), to: TrackerDouble
    defdelegate is_native_terminal?(issue), to: TrackerDouble
    defdelegate capabilities(), to: TrackerDouble
    defdelegate validate_workflow_state_mapping(workflow, tracker_config), to: TrackerDouble
    defdelegate create_comment(issue_id, body), to: TrackerDouble
    defdelegate update_issue_state(issue_id, state_name), to: TrackerDouble
    defdelegate events(server), to: TrackerDouble
    defdelegate issue(server), to: TrackerDouble
  end

  def unique_name(prefix) when is_binary(prefix) do
    String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
  end
end
