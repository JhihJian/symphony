defmodule SymphonyElixir.GitLab.Client do
  @moduledoc """
  GitLab REST client for project issues.
  """

  alias SymphonyElixir.{Config, Linear.Issue}

  @per_page 100

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    fetch_candidate_issues(&Req.request/1)
  end

  @doc false
  @spec fetch_candidate_issues_for_test((keyword() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues_for_test(request_fun) when is_function(request_fun, 1) do
    fetch_candidate_issues(request_fun)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    fetch_issues_by_states(state_names, &Req.request/1)
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], (keyword() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(state_names, request_fun)
      when is_list(state_names) and is_function(request_fun, 1) do
    fetch_issues_by_states(state_names, request_fun)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    fetch_issue_states_by_ids(issue_ids, &Req.request/1)
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test([String.t()], (keyword() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, request_fun)
      when is_list(issue_ids) and is_function(request_fun, 1) do
    fetch_issue_states_by_ids(issue_ids, request_fun)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    create_comment(issue_id, body, &Req.request/1)
  end

  @doc false
  @spec create_comment_for_test(String.t(), String.t(), (keyword() -> {:ok, map()} | {:error, term()})) ::
          :ok | {:error, term()}
  def create_comment_for_test(issue_id, body, request_fun)
      when is_binary(issue_id) and is_binary(body) and is_function(request_fun, 1) do
    create_comment(issue_id, body, request_fun)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    update_issue_state(issue_id, state_name, &Req.request/1)
  end

  @doc false
  @spec update_issue_state_for_test(String.t(), String.t(), (keyword() -> {:ok, map()} | {:error, term()})) ::
          :ok | {:error, term()}
  def update_issue_state_for_test(issue_id, state_name, request_fun)
      when is_binary(issue_id) and is_binary(state_name) and is_function(request_fun, 1) do
    update_issue_state(issue_id, state_name, request_fun)
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue)
  end

  @doc false
  @spec rest_api_base_url_for_test(String.t()) :: String.t()
  def rest_api_base_url_for_test(endpoint) when is_binary(endpoint) do
    rest_api_base_url_for_endpoint(endpoint)
  end

  defp fetch_candidate_issues(request_fun) when is_function(request_fun, 1) do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_config(),
         {:ok, issues} <- fetch_issue_pages("opened", request_fun, candidate_params(tracker)) do
      active_states =
        tracker.active_states
        |> Enum.map(&normalize_state/1)
        |> MapSet.new()

      {:ok,
       Enum.filter(issues, fn issue ->
         Issue.routable?(issue, tracker.required_labels) and
           MapSet.member?(active_states, normalize_state(issue.state))
       end)}
    end
  end

  defp fetch_issues_by_states([], _request_fun), do: {:ok, []}

  defp fetch_issues_by_states(state_names, request_fun) when is_function(request_fun, 1) do
    with :ok <- validate_tracker_config() do
      wanted_states =
        state_names
        |> Enum.map(&normalize_state/1)
        |> MapSet.new()

      native_states =
        state_names
        |> native_states_for_requested_states()
        |> Enum.uniq()

      native_states
      |> Enum.reduce_while({:ok, []}, fn native_state, {:ok, acc} ->
        case fetch_issue_pages(native_state, request_fun, %{}) do
          {:ok, issues} -> {:cont, {:ok, acc ++ issues}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, issues} ->
          {:ok, Enum.filter(issues, &MapSet.member?(wanted_states, normalize_state(&1.state)))}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_issue_states_by_ids(issue_ids, request_fun) when is_function(request_fun, 1) do
    with :ok <- validate_tracker_config() do
      issue_ids
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
        case fetch_issue_by_id(issue_id, request_fun) do
          {:ok, nil} -> {:cont, {:ok, acc}}
          {:ok, issue} -> {:cont, {:ok, [issue | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, issues} -> {:ok, Enum.reverse(issues)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp create_comment(issue_id, body, request_fun) when is_function(request_fun, 1) do
    with :ok <- validate_tracker_config(),
         {:ok, iid} <- parse_issue_iid(issue_id),
         {:ok, _response} <- rest_request(:post, issue_notes_path(iid), [json: %{body: body}], request_fun) do
      :ok
    end
  end

  defp update_issue_state(issue_id, state_name, request_fun) when is_function(request_fun, 1) do
    with :ok <- validate_tracker_config(),
         {:ok, iid} <- parse_issue_iid(issue_id),
         {:ok, payload} <- state_update_payload(state_name),
         {:ok, _response} <-
           rest_request(:put, issue_path(iid), [json: payload], request_fun) do
      :ok
    end
  end

  defp fetch_issue_pages(native_state, request_fun, extra_params) do
    do_fetch_issue_pages(native_state, request_fun, extra_params, 1, [])
  end

  defp do_fetch_issue_pages(native_state, request_fun, extra_params, page, acc) do
    params =
      extra_params
      |> Map.put(:state, native_state)
      |> Map.put(:page, page)
      |> Map.put(:per_page, @per_page)

    with {:ok, response} <- rest_request(:get, project_issues_path(), [params: params], request_fun),
         body when is_list(body) <- Map.get(response, :body) do
      issues =
        body
        |> Enum.map(&normalize_issue/1)
        |> Enum.reject(&is_nil/1)

      next_acc = acc ++ issues

      case next_page(response) do
        {:ok, next_page} -> do_fetch_issue_pages(native_state, request_fun, extra_params, next_page, next_acc)
        :done -> {:ok, next_acc}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :gitlab_unknown_payload}
    end
  end

  defp fetch_issue_by_id(issue_id, request_fun) do
    with {:ok, iid} <- parse_issue_iid(issue_id),
         {:ok, response} <- rest_request(:get, issue_path(iid), [], request_fun),
         body when is_map(body) <- Map.get(response, :body) do
      {:ok, normalize_issue(body)}
    else
      {:error, {:gitlab_api_status, 404}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :gitlab_unknown_payload}
    end
  end

  defp candidate_params(tracker) do
    %{}
    |> maybe_put_required_labels(tracker.required_labels)
    |> maybe_put_assignee_username(tracker.assignee)
  end

  defp maybe_put_required_labels(params, labels) when is_list(labels) and labels != [] do
    Map.put(params, :labels, Enum.join(labels, ","))
  end

  defp maybe_put_required_labels(params, _labels), do: params

  defp maybe_put_assignee_username(params, assignee) when is_binary(assignee) and assignee != "" do
    Map.put(params, :assignee_username, assignee)
  end

  defp maybe_put_assignee_username(params, _assignee), do: params

  defp native_states_for_requested_states(state_names) do
    tracker = Config.settings!().tracker
    active_states = MapSet.new(Enum.map(tracker.active_states, &normalize_state/1))
    terminal_states = MapSet.new(Enum.map(tracker.terminal_states, &normalize_state/1))

    Enum.flat_map(state_names, fn state_name ->
      normalized_state = normalize_state(state_name)

      cond do
        MapSet.member?(active_states, normalized_state) -> ["opened"]
        MapSet.member?(terminal_states, normalized_state) -> terminal_native_states(tracker)
        true -> []
      end
    end)
  end

  defp terminal_native_states(%{state_label_prefix: prefix}) when is_binary(prefix), do: ["closed", "opened"]
  defp terminal_native_states(_tracker), do: ["closed"]

  defp normalize_issue(issue) when is_map(issue) do
    tracker = Config.settings!().tracker

    case issue["iid"] do
      iid when is_integer(iid) ->
        assignees = issue["assignees"] || []

        %Issue{
          id: internal_issue_id(iid),
          identifier: issue_identifier(iid),
          title: issue["title"],
          description: issue["description"],
          priority: nil,
          state: scheduling_state(issue["state"], tracker, normalize_labels(issue["labels"])),
          branch_name: nil,
          url: issue["web_url"],
          assignee_id: first_assignee_username(assignees),
          blocked_by: extract_blockers(issue, tracker),
          labels: normalize_labels(issue["labels"]),
          assigned_to_worker: assigned_to_worker?(assignees, tracker.assignee),
          created_at: parse_datetime(issue["created_at"]),
          updated_at: parse_datetime(issue["updated_at"])
        }

      _ ->
        nil
    end
  end

  defp normalize_issue(_issue), do: nil

  defp extract_blockers(%{"blocking_issues" => blockers}, tracker) when is_list(blockers) do
    Enum.flat_map(blockers, fn
      %{"iid" => iid} = blocker when is_integer(iid) ->
        [
          %{
            id: internal_issue_id(iid),
            identifier: blocker_identifier(blocker, iid, tracker),
            state: scheduling_state(blocker["state"], tracker, normalize_labels(blocker["labels"]))
          }
        ]

      _ ->
        []
    end)
  end

  defp extract_blockers(_issue, _tracker), do: []

  defp blocker_identifier(blocker, iid, tracker) do
    get_in(blocker, ["references", "full"]) || "#{tracker.project_slug}##{iid}"
  end

  defp normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase(String.trim(&1)))
  end

  defp normalize_labels(_labels), do: []

  defp first_assignee_username([%{"username" => username} | _rest]) when is_binary(username), do: username
  defp first_assignee_username(_assignees), do: nil

  defp assigned_to_worker?(_assignees, nil), do: true

  defp assigned_to_worker?(assignees, configured_assignee) do
    normalized_assignee = normalize_state(configured_assignee)

    Enum.any?(assignees, fn
      %{"username" => username} when is_binary(username) ->
        normalize_state(username) == normalized_assignee

      _ ->
        false
    end)
  end

  defp scheduling_state("closed", tracker, labels) do
    label_state = label_scheduling_state(labels, tracker)

    if configured_state?(label_state, tracker.terminal_states) do
      label_state
    else
      first_configured_state(tracker.terminal_states, "Closed")
    end
  end

  defp scheduling_state("opened", tracker, labels) do
    label_scheduling_state(labels, tracker) || first_configured_state(tracker.active_states, "Todo")
  end

  defp scheduling_state("reopened", tracker, labels) do
    label_scheduling_state(labels, tracker) || first_configured_state(tracker.active_states, "Todo")
  end

  defp scheduling_state(state, _tracker, _labels) when is_binary(state), do: state
  defp scheduling_state(_state, _tracker, _labels), do: "Unknown"

  defp first_configured_state([state | _rest], _fallback) when is_binary(state) and state != "", do: state
  defp first_configured_state(_states, fallback), do: fallback

  defp state_update_payload(state_name) do
    tracker = Config.settings!().tracker

    with {:ok, state_event} <- state_event_for(state_name, tracker) do
      {:ok,
       %{state_event: state_event}
       |> maybe_put_state_label_addition(state_name, tracker)
       |> maybe_put_state_label_removals(state_name, tracker)}
    end
  end

  defp state_event_for(state_name, tracker) do
    cond do
      configured_state?(state_name, tracker.terminal_states) ->
        {:ok, "close"}

      configured_state?(state_name, tracker.active_states) ->
        {:ok, "reopen"}

      true ->
        {:error, {:gitlab_unsupported_state, state_name}}
    end
  end

  defp label_scheduling_state(labels, tracker) do
    case tracker.state_label_prefix do
      prefix when is_binary(prefix) ->
        label_set =
          labels
          |> Enum.map(&normalize_label/1)
          |> MapSet.new()

        Enum.find(all_configured_states(tracker), fn state_name ->
          MapSet.member?(label_set, normalize_label(prefix <> state_label_suffix(state_name)))
        end)

      _ ->
        nil
    end
  end

  defp maybe_put_state_label_addition(payload, state_name, tracker) do
    case state_label_for(state_name, tracker) do
      label when is_binary(label) -> Map.put(payload, :add_labels, label)
      nil -> payload
    end
  end

  defp maybe_put_state_label_removals(payload, state_name, tracker) do
    case state_labels_except(state_name, tracker) do
      [] -> payload
      labels -> Map.put(payload, :remove_labels, Enum.join(labels, ","))
    end
  end

  defp state_label_for(state_name, tracker) do
    with prefix when is_binary(prefix) <- tracker.state_label_prefix,
         true <- configured_state?(state_name, all_configured_states(tracker)) do
      prefix <> state_label_suffix(state_name)
    else
      _ -> nil
    end
  end

  defp state_labels_except(state_name, tracker) do
    case tracker.state_label_prefix do
      prefix when is_binary(prefix) ->
        tracker
        |> all_configured_states()
        |> Enum.reject(&(normalize_state(&1) == normalize_state(state_name)))
        |> Enum.map(&(prefix <> state_label_suffix(&1)))

      _ ->
        []
    end
  end

  defp all_configured_states(tracker), do: tracker.active_states ++ tracker.terminal_states

  defp configured_state?(state_name, states) when is_binary(state_name) and is_list(states) do
    normalized_state = normalize_state(state_name)
    Enum.any?(states, &(normalize_state(&1) == normalized_state))
  end

  defp configured_state?(_state_name, _states), do: false

  defp state_label_suffix(state_name) when is_binary(state_name) do
    state_name
    |> normalize_state()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp normalize_label(label) when is_binary(label), do: String.downcase(String.trim(label))

  defp parse_issue_iid(issue_id) when is_binary(issue_id) do
    issue_id
    |> String.trim()
    |> String.replace_prefix("gitlab:", "")
    |> String.split("#")
    |> List.last()
    |> case do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {iid, ""} when iid > 0 -> {:ok, iid}
          _ -> {:error, :invalid_issue_id}
        end
    end
  end

  defp internal_issue_id(iid) when is_integer(iid) do
    "gitlab:#{Config.settings!().tracker.project_slug}##{iid}"
  end

  defp issue_identifier(iid) when is_integer(iid) do
    "#{Config.settings!().tracker.project_slug}##{iid}"
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp rest_request(method, path, opts, request_fun) do
    with {:ok, headers} <- gitlab_headers(),
         {:ok, response} <-
           request_fun.(
             opts
             |> Keyword.put(:method, method)
             |> Keyword.put(:url, rest_api_base_url() <> path)
             |> Keyword.put(:headers, headers)
           ) do
      case response do
        %{status: status} = full_response when status in 200..299 ->
          {:ok, full_response}

        %{status: status} ->
          {:error, {:gitlab_api_status, status}}
      end
    else
      {:error, reason} -> {:error, {:gitlab_api_request, reason}}
    end
  end

  defp gitlab_headers do
    token = Config.settings!().tracker.api_key
    {:ok, [{"accept", "application/json"}, {"private-token", token}]}
  end

  defp validate_tracker_config do
    tracker = Config.settings!().tracker

    cond do
      not is_binary(tracker.api_key) -> {:error, :missing_gitlab_api_token}
      not is_binary(tracker.project_slug) -> {:error, :missing_gitlab_project_slug}
      true -> :ok
    end
  end

  defp project_issues_path do
    "/projects/#{encoded_project_slug()}/issues"
  end

  defp issue_path(iid) when is_integer(iid) do
    project_issues_path() <> "/#{iid}"
  end

  defp issue_notes_path(iid) when is_integer(iid) do
    issue_path(iid) <> "/notes"
  end

  defp encoded_project_slug do
    Config.settings!().tracker.project_slug
    |> to_string()
    |> URI.encode_www_form()
  end

  defp rest_api_base_url do
    tracker_endpoint = Config.settings!().tracker.endpoint || "https://gitlab.com/api/v4"
    rest_api_base_url_for_endpoint(tracker_endpoint)
  end

  defp rest_api_base_url_for_endpoint(endpoint) when is_binary(endpoint) do
    endpoint
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp next_page(%{headers: headers}) do
    case header_value(headers, "x-next-page") do
      value when is_binary(value) and value != "" ->
        case Integer.parse(value) do
          {page, ""} when page > 0 -> {:ok, page}
          _ -> :done
        end

      _ ->
        :done
    end
  end

  defp next_page(_response), do: :done

  defp header_value(headers, wanted) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == wanted, do: value

      _ ->
        nil
    end)
  end

  defp header_value(headers, wanted) when is_map(headers) do
    Map.get(headers, wanted) || Map.get(headers, String.to_atom(wanted))
  end

  defp header_value(_headers, _wanted), do: nil

  defp normalize_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state_name), do: ""
end
