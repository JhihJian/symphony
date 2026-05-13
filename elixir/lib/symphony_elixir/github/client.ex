defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub GraphQL/REST client for repository issues tracked via Projects v2 status.
  """

  alias SymphonyElixir.{Config, GitHub.PullRequest, Linear.Issue}

  @issue_page_size 50
  @api_version "2022-11-28"

  @list_issues_query """
  query SymphonyGitHubIssues(
    $owner: String!,
    $repo: String!,
    $statusFieldName: String!,
    $issueStates: [IssueState!],
    $after: String
  ) {
    repository(owner: $owner, name: $repo) {
      issues(first: #{@issue_page_size}, after: $after, states: $issueStates, orderBy: {field: UPDATED_AT, direction: DESC}) {
        nodes {
          id
          number
          title
          body
          state
          url
          createdAt
          updatedAt
          labels(first: 50) {
            nodes {
              name
            }
          }
          assignees(first: 20) {
            nodes {
              login
            }
          }
          blockedBy(first: 20) {
            nodes {
              id
              number
              state
              repository {
                name
                owner {
                  login
                }
              }
            }
          }
          projectItems(first: 20) {
            nodes {
              id
              project {
                ... on ProjectV2 {
                  id
                  number
                }
              }
              fieldValueByName(name: $statusFieldName) {
                ... on ProjectV2ItemFieldSingleSelectValue {
                  name
                  optionId
                  field {
                    ... on ProjectV2SingleSelectField {
                      id
                      options {
                        id
                        name
                      }
                    }
                  }
                }
              }
            }
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
  """

  @issue_by_number_query """
  query SymphonyGitHubIssueByNumber(
    $owner: String!,
    $repo: String!,
    $issueNumber: Int!,
    $statusFieldName: String!
  ) {
    repository(owner: $owner, name: $repo) {
      issue(number: $issueNumber) {
        id
        number
        title
        body
        state
        url
        createdAt
        updatedAt
        labels(first: 50) {
          nodes {
            name
          }
        }
        assignees(first: 20) {
          nodes {
            login
          }
        }
        blockedBy(first: 20) {
          nodes {
            id
            number
            state
            repository {
              name
              owner {
                login
              }
            }
          }
        }
        projectItems(first: 20) {
          nodes {
            id
            project {
              ... on ProjectV2 {
                id
                number
              }
            }
            fieldValueByName(name: $statusFieldName) {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                optionId
                field {
                  ... on ProjectV2SingleSelectField {
                    id
                    options {
                      id
                      name
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  """

  @update_project_status_mutation """
  mutation SymphonyUpdateGitHubProjectStatus(
    $projectId: ID!,
    $itemId: ID!,
    $fieldId: ID!,
    $optionId: String!
  ) {
    updateProjectV2ItemFieldValue(
      input: {
        projectId: $projectId,
        itemId: $itemId,
        fieldId: $fieldId,
        value: {singleSelectOptionId: $optionId}
      }
    ) {
      projectV2Item {
        id
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with :ok <- validate_tracker_config(),
         {:ok, issues} <- fetch_all_issues(["OPEN"]) do
      active_states =
        Config.settings!().tracker.active_states
        |> Enum.map(&normalize_state/1)
        |> MapSet.new()

      {:ok,
       Enum.filter(issues, fn %Issue{state: state, assigned_to_worker: assigned_to_worker} ->
         assigned_to_worker and MapSet.member?(active_states, normalize_state(state))
       end)}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    with :ok <- validate_tracker_config(),
         {:ok, issues} <- fetch_all_issues(["OPEN", "CLOSED"]) do
      wanted_states =
        state_names
        |> Enum.map(&normalize_state/1)
        |> MapSet.new()

      {:ok,
       Enum.filter(issues, fn %Issue{state: state} ->
         MapSet.member?(wanted_states, normalize_state(state))
       end)}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    issue_ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
      case fetch_issue_by_id(issue_id) do
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

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, response} <-
           rest_request(:post, issue_comments_path(issue_number), %{body: body}),
         201 <- response.status do
      :ok
    else
      {:error, reason} -> {:error, reason}
      %{status: status} -> {:error, {:github_api_status, status}}
      status when is_integer(status) -> {:error, {:github_api_status, status}}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec fetch_issue(String.t()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_issue(issue_id) when is_binary(issue_id) do
    fetch_issue_by_id(issue_id)
  end

  @spec list_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_comments(issue_id) when is_binary(issue_id) do
    with {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, response} <- rest_request(:get, issue_comments_path(issue_number), nil),
         comments when is_list(comments) <- response.body do
      {:ok, Enum.map(comments, &normalize_comment/1)}
    else
      {:error, reason} -> {:error, reason}
      %{body: body} when is_list(body) -> {:ok, Enum.map(body, &normalize_comment/1)}
      _ -> {:error, :github_unknown_payload}
    end
  end

  @spec update_comment(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def update_comment(comment_id, body) when is_binary(comment_id) and is_binary(body) do
    with {:ok, normalized_comment_id} <- parse_comment_id(comment_id),
         {:ok, response} <-
           rest_request(:patch, issue_comment_path(normalized_comment_id), %{body: body}),
         %{body: comment} when is_map(comment) <- response do
      {:ok, normalize_comment(comment)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_update_failed}
    end
  end

  @spec upsert_workpad_comment(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def upsert_workpad_comment(issue_id, body, header \\ "## Codex Workpad")
      when is_binary(issue_id) and is_binary(body) and is_binary(header) do
    with {:ok, comments} <- list_comments(issue_id) do
      case Enum.find(comments, &workpad_comment?(&1, header)) do
        %{"id" => comment_id} = existing_comment ->
          with {:ok, updated_comment} <- update_comment(comment_id, body) do
            {:ok,
             %{
               "action" => "updated",
               "comment" => updated_comment,
               "previousCommentId" => existing_comment["id"]
             }}
          end

        nil ->
          with {:ok, issue_number} <- parse_issue_number(issue_id),
               {:ok, response} <-
                 rest_request(:post, issue_comments_path(issue_number), %{body: body}),
               %{body: comment} when is_map(comment) <- response do
            {:ok, %{"action" => "created", "comment" => normalize_comment(comment)}}
          else
            {:error, reason} -> {:error, reason}
            _ -> {:error, :comment_create_failed}
          end
      end
    end
  end

  @spec add_labels(String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def add_labels(issue_id, labels) when is_binary(issue_id) and is_list(labels) do
    normalized_labels =
      labels
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    with {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, response} <- rest_request(:post, issue_labels_path(issue_number), %{labels: normalized_labels}),
         body when is_list(body) <- response.body do
      {:ok, Enum.map(body, &Map.get(&1, "name"))}
    else
      {:error, reason} -> {:error, reason}
      %{body: body} when is_list(body) -> {:ok, Enum.map(body, &Map.get(&1, "name"))}
      _ -> {:error, :label_update_failed}
    end
  end

  @spec list_pull_requests_for_head(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_pull_requests_for_head(head_ref_name) when is_binary(head_ref_name),
    do: PullRequest.list_for_head(head_ref_name)

  @spec get_pull_request(String.t()) :: {:ok, map()} | {:error, term()}
  def get_pull_request(pr_number) when is_binary(pr_number), do: PullRequest.get(pr_number)

  @spec create_pull_request(String.t(), String.t(), String.t(), String.t(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def create_pull_request(head_ref_name, base_ref_name, title, body, draft \\ true)
      when is_binary(head_ref_name) and is_binary(base_ref_name) and is_binary(title) and
             is_binary(body) and is_boolean(draft),
      do: PullRequest.create(head_ref_name, base_ref_name, title, body, draft)

  @spec list_pull_request_issue_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_pull_request_issue_comments(pr_number) when is_binary(pr_number),
    do: PullRequest.list_issue_comments(pr_number)

  @spec list_pull_request_reviews(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_pull_request_reviews(pr_number) when is_binary(pr_number),
    do: PullRequest.list_reviews(pr_number)

  @spec list_pull_request_review_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_pull_request_review_comments(pr_number) when is_binary(pr_number),
    do: PullRequest.list_review_comments(pr_number)

  @spec get_pull_request_check_status(String.t()) :: {:ok, map()} | {:error, term()}
  def get_pull_request_check_status(pr_number) when is_binary(pr_number),
    do: PullRequest.get_check_status(pr_number)

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, details} <- fetch_issue_details(issue_number),
         {:ok, project_item} <- find_project_item(details),
         {:ok, field_id, option_id} <- resolve_status_option(project_item, state_name),
         {:ok, response} <-
           graphql(@update_project_status_mutation, %{
             projectId: get_in(project_item, ["project", "id"]),
             itemId: project_item["id"],
             fieldId: field_id,
             optionId: option_id
           }),
         :ok <- validate_project_status_update(response),
         :ok <- sync_issue_open_closed(issue_number, state_name) do
      :ok
    end
  end

  @spec graphql(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}) when is_binary(query) and is_map(variables) do
    with {:ok, headers} <- github_headers(),
         {:ok, response} <-
           Req.post(Config.settings!().tracker.endpoint,
             json: %{query: query, variables: variables},
             headers: headers
           ) do
      case response do
        %{status: 200, body: %{"errors" => errors}} ->
          {:error, {:github_graphql_errors, errors}}

        %{status: 200, body: body} when is_map(body) ->
          {:ok, body}

        %{status: status} ->
          {:error, {:github_api_status, status}}
      end
    else
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  defp fetch_all_issues(issue_states) do
    do_fetch_all_issues(issue_states, nil, [])
  end

  defp do_fetch_all_issues(issue_states, after_cursor, acc) do
    tracker = Config.settings!().tracker

    with {:ok, body} <-
           graphql(@list_issues_query, %{
             owner: tracker.owner,
             repo: tracker.repo,
             statusFieldName: tracker.project_status_field_name,
             issueStates: issue_states,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_issue_page(body) do
      merged = Enum.reverse(issues, acc)

      case page_info do
        %{"hasNextPage" => true, "endCursor" => next_cursor} when is_binary(next_cursor) ->
          do_fetch_all_issues(issue_states, next_cursor, merged)

        _ ->
          {:ok, Enum.reverse(merged)}
      end
    end
  end

  defp fetch_issue_by_id(issue_id) do
    with {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, details} <- fetch_issue_details(issue_number) do
      {:ok, normalize_issue(details)}
    end
  end

  defp fetch_issue_details(issue_number) do
    tracker = Config.settings!().tracker

    with {:ok, body} <-
           graphql(@issue_by_number_query, %{
             owner: tracker.owner,
             repo: tracker.repo,
             issueNumber: issue_number,
             statusFieldName: tracker.project_status_field_name
           }),
         %{"data" => %{"repository" => %{"issue" => issue}}} when is_map(issue) <- body do
      {:ok, issue}
    else
      %{"data" => %{"repository" => %{"issue" => nil}}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_unknown_payload}
    end
  end

  defp decode_issue_page(%{"data" => %{"repository" => %{"issues" => %{"nodes" => nodes, "pageInfo" => page_info}}}})
       when is_list(nodes) and is_map(page_info) do
    issues =
      nodes
      |> Enum.map(&normalize_issue/1)
      |> Enum.reject(&is_nil/1)

    {:ok, issues, page_info}
  end

  defp decode_issue_page(%{"errors" => errors}), do: {:error, {:github_graphql_errors, errors}}
  defp decode_issue_page(_payload), do: {:error, :github_unknown_payload}

  defp normalize_issue(nil), do: nil

  defp normalize_issue(issue) when is_map(issue) do
    tracker = Config.settings!().tracker
    assignees = get_in(issue, ["assignees", "nodes"]) || []
    labels = get_in(issue, ["labels", "nodes"]) || []
    project_item = matching_project_item(issue)
    state = project_state_name(project_item, issue["state"])
    issue_number = issue["number"]

    if is_integer(issue_number) do
      %Issue{
        id: Integer.to_string(issue_number),
        identifier: "#{tracker.owner}/#{tracker.repo}##{issue_number}",
        title: issue["title"],
        description: issue["body"],
        priority: nil,
        state: state,
        branch_name: nil,
        url: issue["url"],
        assignee_id: first_assignee_login(assignees),
        blocked_by: extract_blockers(issue, tracker),
        labels: Enum.map(labels, &Map.get(&1, "name")),
        assigned_to_worker: assigned_to_worker?(assignees, tracker.assignee),
        created_at: parse_datetime(issue["createdAt"]),
        updated_at: parse_datetime(issue["updatedAt"])
      }
    else
      nil
    end
  end

  defp matching_project_item(issue) do
    tracker = Config.settings!().tracker

    issue
    |> get_in(["projectItems", "nodes"])
    |> List.wrap()
    |> Enum.find(fn item ->
      get_in(item, ["project", "number"]) == tracker.project_number
    end)
  end

  defp project_state_name(nil, github_issue_state), do: normalize_github_issue_state(github_issue_state)

  defp project_state_name(project_item, github_issue_state) do
    case get_in(project_item, ["fieldValueByName", "name"]) do
      value when is_binary(value) and value != "" -> value
      _ -> normalize_github_issue_state(github_issue_state)
    end
  end

  defp normalize_github_issue_state("OPEN"), do: "Open"
  defp normalize_github_issue_state("CLOSED"), do: "Closed"
  defp normalize_github_issue_state(other) when is_binary(other), do: other
  defp normalize_github_issue_state(_other), do: "Unknown"

  defp extract_blockers(%{"blockedBy" => %{"nodes" => blockers}}, tracker)
       when is_list(blockers) do
    Enum.flat_map(blockers, fn
      %{"number" => number} = blocker when is_integer(number) ->
        owner =
          get_in(blocker, ["repository", "owner", "login"]) ||
            tracker.owner

        repo =
          get_in(blocker, ["repository", "name"]) ||
            tracker.repo

        [
          %{
            id: blocker_id(blocker, number),
            identifier: "#{owner}/#{repo}##{number}",
            state: normalize_github_issue_state(blocker["state"])
          }
        ]

      _ ->
        []
    end)
  end

  defp extract_blockers(_issue, _tracker), do: []

  defp blocker_id(%{"id" => id}, _number) when is_binary(id), do: id
  defp blocker_id(_blocker, number), do: Integer.to_string(number)

  defp first_assignee_login([%{"login" => login} | _rest]) when is_binary(login), do: login
  defp first_assignee_login(_assignees), do: nil

  defp assigned_to_worker?(_assignees, nil), do: true
  defp assigned_to_worker?(_assignees, ""), do: true

  defp assigned_to_worker?(assignees, configured_assignee) do
    normalized_assignee = String.downcase(String.trim(configured_assignee))

    Enum.any?(assignees, fn
      %{"login" => login} when is_binary(login) ->
        String.downcase(login) == normalized_assignee

      _ ->
        false
    end)
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp validate_tracker_config do
    tracker = Config.settings!().tracker

    cond do
      not is_binary(tracker.api_key) -> {:error, :missing_github_api_token}
      not is_binary(tracker.owner) -> {:error, :missing_github_owner}
      not is_binary(tracker.repo) -> {:error, :missing_github_repo}
      not is_integer(tracker.project_number) -> {:error, :missing_github_project_number}
      true -> :ok
    end
  end

  defp parse_issue_number(issue_id) when is_binary(issue_id) do
    case Integer.parse(issue_id) do
      {issue_number, ""} when issue_number > 0 -> {:ok, issue_number}
      _ -> {:error, :invalid_issue_id}
    end
  end

  defp find_project_item(nil), do: {:error, :issue_not_found}

  defp find_project_item(issue_details) do
    case matching_project_item(issue_details) do
      %{} = item -> {:ok, item}
      nil -> {:error, :github_project_item_not_found}
    end
  end

  defp resolve_status_option(project_item, state_name) do
    normalized_state_name = normalize_state(state_name)
    field_value = project_item["fieldValueByName"] || %{}
    options = get_in(field_value, ["field", "options"]) || []
    field_id = get_in(field_value, ["field", "id"])

    case Enum.find(options, fn option ->
           normalize_state(option["name"]) == normalized_state_name
         end) do
      %{"id" => option_id} when is_binary(option_id) and is_binary(field_id) ->
        {:ok, field_id, option_id}

      _ ->
        {:error, :github_project_status_option_not_found}
    end
  end

  defp validate_project_status_update(%{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => _id}}}}),
    do: :ok

  defp validate_project_status_update(_response), do: {:error, :issue_update_failed}

  defp sync_issue_open_closed(issue_number, state_name) do
    tracker = Config.settings!().tracker
    normalized_state_name = normalize_state(state_name)
    terminal_states = MapSet.new(Enum.map(tracker.terminal_states, &normalize_state/1))
    active_states = MapSet.new(Enum.map(tracker.active_states, &normalize_state/1))

    cond do
      MapSet.member?(terminal_states, normalized_state_name) ->
        patch_issue_state(issue_number, "closed", close_state_reason(state_name))

      MapSet.member?(active_states, normalized_state_name) ->
        patch_issue_state(issue_number, "open", "reopened")

      true ->
        :ok
    end
  end

  defp patch_issue_state(issue_number, issue_state, state_reason) do
    body =
      %{state: issue_state}
      |> maybe_put_state_reason(issue_state, state_reason)

    with {:ok, response} <- rest_request(:patch, issue_path(issue_number), body),
         status when status in [200, 201] <- response.status do
      :ok
    else
      {:error, {:github_api_status, 422}} ->
        :ok

      {:error, reason} ->
        {:error, reason}

      %{status: status} ->
        {:error, {:github_api_status, status}}

      status when is_integer(status) ->
        {:error, {:github_api_status, status}}

      _ ->
        {:error, :issue_update_failed}
    end
  end

  defp maybe_put_state_reason(body, "closed", state_reason), do: Map.put(body, :state_reason, state_reason)
  defp maybe_put_state_reason(body, _issue_state, _state_reason), do: body

  defp close_state_reason(state_name) do
    case normalize_state(state_name) do
      "duplicate" -> "duplicate"
      "cancelled" -> "not_planned"
      "canceled" -> "not_planned"
      _ -> "completed"
    end
  end

  defp rest_request(method, path, body) do
    with {:ok, headers} <- github_headers(),
         {:ok, response} <-
           Req.request(rest_request_options(method, path, body, headers)) do
      case response do
        %{status: status} = full_response when status in 200..299 ->
          {:ok, full_response}

        %{status: status} ->
          {:error, {:github_api_status, status}}
      end
    else
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  defp github_headers do
    case Config.settings!().tracker.api_key do
      token when is_binary(token) and token != "" ->
        {:ok,
         [
           {"accept", "application/vnd.github+json"},
           {"authorization", "Bearer " <> token},
           {"x-github-api-version", @api_version}
         ]}

      _ ->
        {:error, :missing_github_api_token}
    end
  end

  defp issue_comments_path(issue_number) do
    tracker = Config.settings!().tracker
    "/repos/#{tracker.owner}/#{tracker.repo}/issues/#{issue_number}/comments"
  end

  defp issue_labels_path(issue_number) do
    tracker = Config.settings!().tracker
    "/repos/#{tracker.owner}/#{tracker.repo}/issues/#{issue_number}/labels"
  end

  defp issue_comment_path(comment_id) do
    tracker = Config.settings!().tracker
    "/repos/#{tracker.owner}/#{tracker.repo}/issues/comments/#{comment_id}"
  end

  defp issue_path(issue_number) do
    tracker = Config.settings!().tracker
    "/repos/#{tracker.owner}/#{tracker.repo}/issues/#{issue_number}"
  end

  defp rest_request_options(method, path, nil, headers) do
    [
      method: method,
      url: rest_api_base_url() <> path,
      headers: headers
    ]
  end

  defp rest_request_options(method, path, body, headers) do
    [
      method: method,
      url: rest_api_base_url() <> path,
      json: body,
      headers: headers
    ]
  end

  defp parse_comment_id(comment_id) when is_binary(comment_id) do
    case Integer.parse(comment_id) do
      {normalized_comment_id, ""} when normalized_comment_id > 0 ->
        {:ok, Integer.to_string(normalized_comment_id)}

      _ ->
        {:error, :invalid_comment_id}
    end
  end

  defp normalize_comment(comment) when is_map(comment) do
    %{
      "authorLogin" => get_in(comment, ["user", "login"]),
      "body" => Map.get(comment, "body"),
      "createdAt" => Map.get(comment, "created_at"),
      "id" => comment_id(comment),
      "updatedAt" => Map.get(comment, "updated_at"),
      "url" => Map.get(comment, "html_url")
    }
  end

  defp normalize_comment(_comment), do: %{}

  defp comment_id(%{"id" => id}) when is_integer(id), do: Integer.to_string(id)
  defp comment_id(%{"id" => id}) when is_binary(id), do: id
  defp comment_id(_comment), do: nil

  defp workpad_comment?(%{"body" => body}, header) when is_binary(body) and is_binary(header) do
    body
    |> String.trim_leading()
    |> String.starts_with?(header)
  end

  defp workpad_comment?(_comment, _header), do: false

  defp rest_api_base_url do
    tracker_endpoint = Config.settings!().tracker.endpoint || "https://api.github.com/graphql"
    rest_api_base_url_for_endpoint(tracker_endpoint)
  end

  @doc false
  @spec rest_api_base_url_for_test(String.t()) :: String.t()
  def rest_api_base_url_for_test(endpoint) when is_binary(endpoint) do
    rest_api_base_url_for_endpoint(endpoint)
  end

  defp rest_api_base_url_for_endpoint(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        path = uri.path || ""

        normalized_path =
          cond do
            String.ends_with?(path, "/api/graphql") ->
              String.replace_suffix(path, "/api/graphql", "/api/v3")

            path == "/graphql" ->
              ""

            String.ends_with?(path, "/graphql") ->
              String.replace_suffix(path, "/graphql", "")

            true ->
              path
          end

        uri
        |> Map.put(:path, normalized_path)
        |> Map.put(:query, nil)
        |> Map.put(:fragment, nil)
        |> URI.to_string()

      _ ->
        "https://api.github.com"
    end
  end

  defp normalize_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state_name), do: ""
end
