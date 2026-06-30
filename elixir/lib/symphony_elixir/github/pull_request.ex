defmodule SymphonyElixir.GitHub.PullRequest do
  @moduledoc """
  GitHub-backed pull request provider.

  This module owns PR, review, and check-state operations. It is intentionally separate from
  `SymphonyElixir.GitHub.Client`, which is focused on issue and project-tracker concerns.
  """

  @behaviour SymphonyElixir.PullRequest

  alias SymphonyElixir.{Config, GitHub.Client}

  @api_version "2022-11-28"

  @impl true
  def list_for_head(head_ref_name) when is_binary(head_ref_name) do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_config(),
         {:ok, response} <-
           rest_request(
             :get,
             pull_requests_path(%{
               "state" => "all",
               "head" => "#{tracker.owner}:#{String.trim(head_ref_name)}"
             }),
             nil
           ),
         body when is_list(body) <- response.body do
      {:ok, Enum.map(body, &normalize_pull_request/1)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_unknown_payload}
    end
  end

  @impl true
  def get(pr_number) when is_binary(pr_number) do
    with {:ok, normalized_pr_number} <- parse_issue_number(pr_number),
         {:ok, response} <- rest_request(:get, pull_request_path(normalized_pr_number), nil),
         body when is_map(body) <- response.body do
      {:ok, normalize_pull_request(body)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_unknown_payload}
    end
  end

  @impl true
  def create(head_ref_name, base_ref_name, title, body, draft \\ true)
      when is_binary(head_ref_name) and is_binary(base_ref_name) and is_binary(title) and
             is_binary(body) and is_boolean(draft) do
    payload = %{
      head: String.trim(head_ref_name),
      base: String.trim(base_ref_name),
      title: title,
      body: body,
      draft: draft
    }

    with {:ok, response} <- rest_request(:post, pull_requests_path(), payload),
         body when is_map(body) <- response.body do
      {:ok, normalize_pull_request(body)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :pull_request_create_failed}
    end
  end

  @impl true
  def list_issue_comments(pr_number) when is_binary(pr_number) do
    with {:ok, normalized_pr_number} <- parse_issue_number(pr_number),
         {:ok, response} <- rest_request(:get, issue_comments_path(normalized_pr_number), nil),
         body when is_list(body) <- response.body do
      {:ok, Enum.map(body, &normalize_comment/1)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_unknown_payload}
    end
  end

  @impl true
  def list_reviews(pr_number) when is_binary(pr_number) do
    with {:ok, normalized_pr_number} <- parse_issue_number(pr_number),
         {:ok, response} <- rest_request(:get, pull_request_reviews_path(normalized_pr_number), nil),
         body when is_list(body) <- response.body do
      {:ok, Enum.map(body, &normalize_review/1)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_unknown_payload}
    end
  end

  @impl true
  def list_review_comments(pr_number) when is_binary(pr_number) do
    with {:ok, normalized_pr_number} <- parse_issue_number(pr_number),
         {:ok, response} <-
           rest_request(:get, pull_request_review_comments_path(normalized_pr_number), nil),
         body when is_list(body) <- response.body do
      {:ok, Enum.map(body, &normalize_review_comment/1)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_unknown_payload}
    end
  end

  @impl true
  def get_check_status(pr_number) when is_binary(pr_number) do
    with {:ok, pull_request} <- get(pr_number),
         head_sha when is_binary(head_sha) <- pull_request["headSha"],
         {:ok, check_runs_response} <- rest_request(:get, check_runs_path(head_sha), nil),
         {:ok, combined_status_response} <- rest_request(:get, combined_status_path(head_sha), nil) do
      {:ok,
       %{
         "checkRuns" => normalize_check_runs(check_runs_response.body),
         "combinedStatus" => normalize_combined_status(combined_status_response.body),
         "headSha" => head_sha,
         "pullRequest" => pull_request
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_unknown_payload}
    end
  end

  defp validate_tracker_config do
    tracker = Config.settings!().tracker

    cond do
      not is_binary(tracker.api_key) -> {:error, :missing_github_api_token}
      not is_binary(tracker.owner) -> {:error, :missing_github_owner}
      not is_binary(tracker.repo) -> {:error, :missing_github_repo}
      true -> :ok
    end
  end

  defp parse_issue_number(issue_id) when is_binary(issue_id) do
    case Integer.parse(issue_id) do
      {issue_number, ""} when issue_number > 0 -> {:ok, issue_number}
      _ -> {:error, :invalid_issue_id}
    end
  end

  defp rest_request(method, path, body) do
    with {:ok, headers} <- github_headers(),
         {:ok, response} <- Req.request(rest_request_options(method, path, body, headers)) do
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

  defp pull_requests_path(query \\ %{}) do
    tracker = Config.settings!().tracker
    maybe_append_query("/repos/#{tracker.owner}/#{tracker.repo}/pulls", query)
  end

  defp pull_request_path(pr_number) do
    tracker = Config.settings!().tracker
    "/repos/#{tracker.owner}/#{tracker.repo}/pulls/#{pr_number}"
  end

  defp pull_request_reviews_path(pr_number) do
    tracker = Config.settings!().tracker
    "/repos/#{tracker.owner}/#{tracker.repo}/pulls/#{pr_number}/reviews"
  end

  defp pull_request_review_comments_path(pr_number) do
    tracker = Config.settings!().tracker
    "/repos/#{tracker.owner}/#{tracker.repo}/pulls/#{pr_number}/comments"
  end

  defp check_runs_path(head_sha) do
    tracker = Config.settings!().tracker
    "/repos/#{tracker.owner}/#{tracker.repo}/commits/#{head_sha}/check-runs"
  end

  defp combined_status_path(head_sha) do
    tracker = Config.settings!().tracker
    "/repos/#{tracker.owner}/#{tracker.repo}/commits/#{head_sha}/status"
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

  defp maybe_append_query(path, query) when is_map(query) do
    filtered_query =
      query
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Enum.into(%{})

    if map_size(filtered_query) == 0 do
      path
    else
      path <> "?" <> URI.encode_query(filtered_query)
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

  defp normalize_pull_request(pull_request) when is_map(pull_request) do
    %{
      "authorLogin" => get_in(pull_request, ["user", "login"]),
      "baseRefName" => get_in(pull_request, ["base", "ref"]),
      "body" => Map.get(pull_request, "body"),
      "headRefName" => get_in(pull_request, ["head", "ref"]),
      "headSha" => get_in(pull_request, ["head", "sha"]),
      "id" => pull_request_number_as_string(pull_request),
      "isDraft" => Map.get(pull_request, "draft"),
      "labels" => pull_request_labels(pull_request),
      "mergeable" => Map.get(pull_request, "mergeable"),
      "number" => Map.get(pull_request, "number"),
      "state" => Map.get(pull_request, "state"),
      "title" => Map.get(pull_request, "title"),
      "updatedAt" => Map.get(pull_request, "updated_at"),
      "url" => Map.get(pull_request, "html_url")
    }
  end

  defp normalize_pull_request(_pull_request), do: %{}

  defp pull_request_number_as_string(%{"number" => number}) when is_integer(number),
    do: Integer.to_string(number)

  defp pull_request_number_as_string(%{"number" => number}) when is_binary(number), do: number
  defp pull_request_number_as_string(_pull_request), do: nil

  defp pull_request_labels(%{"labels" => labels}) when is_list(labels),
    do: Enum.map(labels, &Map.get(&1, "name"))

  defp pull_request_labels(_pull_request), do: []

  defp normalize_review(review) when is_map(review) do
    %{
      "authorLogin" => get_in(review, ["user", "login"]),
      "body" => Map.get(review, "body"),
      "commitId" => Map.get(review, "commit_id"),
      "id" => comment_id(review),
      "state" => Map.get(review, "state"),
      "submittedAt" => Map.get(review, "submitted_at"),
      "url" => Map.get(review, "html_url")
    }
  end

  defp normalize_review(_review), do: %{}

  defp normalize_review_comment(comment) when is_map(comment) do
    %{
      "authorLogin" => get_in(comment, ["user", "login"]),
      "body" => Map.get(comment, "body"),
      "createdAt" => Map.get(comment, "created_at"),
      "id" => comment_id(comment),
      "line" => Map.get(comment, "line"),
      "path" => Map.get(comment, "path"),
      "side" => Map.get(comment, "side"),
      "updatedAt" => Map.get(comment, "updated_at"),
      "url" => Map.get(comment, "html_url")
    }
  end

  defp normalize_review_comment(_comment), do: %{}

  defp normalize_check_runs(%{"check_runs" => check_runs}) when is_list(check_runs) do
    Enum.map(check_runs, fn check_run ->
      %{
        "completedAt" => Map.get(check_run, "completed_at"),
        "conclusion" => Map.get(check_run, "conclusion"),
        "detailsUrl" => Map.get(check_run, "details_url"),
        "name" => Map.get(check_run, "name"),
        "startedAt" => Map.get(check_run, "started_at"),
        "status" => Map.get(check_run, "status")
      }
    end)
  end

  defp normalize_check_runs(_payload), do: []

  defp normalize_combined_status(%{"state" => state, "statuses" => statuses}) when is_list(statuses) do
    %{
      "state" => state,
      "statuses" =>
        Enum.map(statuses, fn status ->
          %{
            "context" => Map.get(status, "context"),
            "description" => Map.get(status, "description"),
            "state" => Map.get(status, "state"),
            "targetUrl" => Map.get(status, "target_url")
          }
        end)
    }
  end

  defp normalize_combined_status(_payload), do: %{"state" => nil, "statuses" => []}

  defp rest_api_base_url do
    tracker_endpoint = Config.settings!().tracker.endpoint || "https://api.github.com/graphql"
    Client.rest_api_base_url_for_test(tracker_endpoint)
  end
end
