defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, GitHub, Linear, PullRequest}

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured Linear auth.
  Use this for Linear issue, workflow-state, and comment operations when the tracker is Linear.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @github_issue_tool "github_issue"
  @github_issue_description """
  Execute structured GitHub issue and project operations using Symphony's configured GitHub auth.
  Supported operations: get issue, list comments, upsert workpad comment, set project status,
  and add labels. Available when Symphony is configured for a GitHub tracker.
  """
  @github_issue_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["operation", "issueId"],
    "properties" => %{
      "operation" => %{
        "type" => "string",
        "enum" => ["get_issue", "list_comments", "upsert_workpad_comment", "set_status", "add_labels"],
        "description" => "GitHub issue operation to perform."
      },
      "issueId" => %{
        "type" => "string",
        "description" => "Symphony issue id, which maps to the GitHub issue number."
      },
      "body" => %{
        "type" => "string",
        "description" => "Comment body used by `upsert_workpad_comment`."
      },
      "header" => %{
        "type" => "string",
        "description" => "Optional comment header used to identify the persistent workpad comment."
      },
      "state" => %{
        "type" => "string",
        "description" => "Project status name used by `set_status`."
      },
      "labels" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "Labels to add to an issue or pull request when using `add_labels`."
      }
    }
  }
  @github_pr_tool "github_pr"
  @github_pr_description """
  Execute structured GitHub pull request read/create operations using Symphony's configured GitHub auth.
  Supported operations: list PRs for a branch head, get PR details, create a PR, list PR issue
  comments, list reviews, list inline review comments, and get check status.
  """
  @github_pr_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["operation"],
    "properties" => %{
      "operation" => %{
        "type" => "string",
        "enum" => [
          "list_for_head",
          "get_pr",
          "create_pr",
          "list_issue_comments",
          "list_reviews",
          "list_review_comments",
          "get_check_status"
        ],
        "description" => "GitHub pull request operation to perform."
      },
      "prNumber" => %{
        "type" => "string",
        "description" => "GitHub pull request number for operations that target an existing PR."
      },
      "headRefName" => %{
        "type" => "string",
        "description" => "Head branch name used by `list_for_head` and `create_pr`."
      },
      "baseRefName" => %{
        "type" => "string",
        "description" => "Base branch name used by `create_pr`."
      },
      "title" => %{
        "type" => "string",
        "description" => "Pull request title used by `create_pr`."
      },
      "body" => %{
        "type" => "string",
        "description" => "Pull request body used by `create_pr`."
      },
      "draft" => %{
        "type" => "boolean",
        "description" => "Draft flag used by `create_pr`."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @github_issue_tool ->
        execute_github_issue(arguments, opts)

      @github_pr_tool ->
        execute_github_pr(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @github_issue_tool,
        "description" => @github_issue_description,
        "inputSchema" => @github_issue_input_schema
      },
      %{
        "name" => @github_pr_tool,
        "description" => @github_pr_description,
        "inputSchema" => @github_pr_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Linear.Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_github_issue(arguments, opts) do
    github_fetch_issue = Keyword.get(opts, :github_fetch_issue, &GitHub.Client.fetch_issue/1)
    github_list_comments = Keyword.get(opts, :github_list_comments, &GitHub.Client.list_comments/1)

    github_upsert_workpad_comment =
      Keyword.get(opts, :github_upsert_workpad_comment, &GitHub.Client.upsert_workpad_comment/3)

    github_update_issue_state =
      Keyword.get(opts, :github_update_issue_state, &GitHub.Client.update_issue_state/2)

    github_add_labels = Keyword.get(opts, :github_add_labels, &GitHub.Client.add_labels/2)

    with :ok <- validate_github_tracker(opts),
         {:ok, operation, issue_id, payload} <- normalize_github_issue_arguments(arguments),
         {:ok, response} <-
           execute_github_issue_operation(
             operation,
             issue_id,
             payload,
             github_fetch_issue,
             github_list_comments,
             github_upsert_workpad_comment,
             github_update_issue_state,
             github_add_labels
           ) do
      dynamic_tool_response(true, encode_payload(response))
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_github_pr(arguments, opts) do
    github_list_pull_requests_for_head =
      Keyword.get(opts, :github_list_pull_requests_for_head, &PullRequest.list_for_head/1)

    github_get_pull_request =
      Keyword.get(opts, :github_get_pull_request, &PullRequest.get/1)

    github_create_pull_request =
      Keyword.get(opts, :github_create_pull_request, &PullRequest.create/5)

    github_list_pull_request_issue_comments =
      Keyword.get(
        opts,
        :github_list_pull_request_issue_comments,
        &PullRequest.list_issue_comments/1
      )

    github_list_pull_request_reviews =
      Keyword.get(opts, :github_list_pull_request_reviews, &PullRequest.list_reviews/1)

    github_list_pull_request_review_comments =
      Keyword.get(
        opts,
        :github_list_pull_request_review_comments,
        &PullRequest.list_review_comments/1
      )

    github_get_pull_request_check_status =
      Keyword.get(
        opts,
        :github_get_pull_request_check_status,
        &PullRequest.get_check_status/1
      )

    with :ok <- validate_github_tracker(opts),
         {:ok, operation, payload} <- normalize_github_pr_arguments(arguments),
         {:ok, response} <-
           execute_github_pr_operation(
             operation,
             payload,
             github_list_pull_requests_for_head,
             github_get_pull_request,
             github_create_pull_request,
             github_list_pull_request_issue_comments,
             github_list_pull_request_reviews,
             github_list_pull_request_review_comments,
             github_get_pull_request_check_status
           ) do
      dynamic_tool_response(true, encode_payload(response))
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_github_issue_arguments(arguments) when is_map(arguments) do
    with {:ok, operation} <- normalize_github_issue_operation(arguments),
         {:ok, issue_id} <- normalize_github_issue_id(arguments),
         {:ok, payload} <- normalize_github_issue_payload(operation, arguments) do
      {:ok, operation, issue_id, payload}
    end
  end

  defp normalize_github_issue_arguments(_arguments), do: {:error, :invalid_github_issue_arguments}

  defp normalize_github_issue_operation(arguments) do
    case Map.get(arguments, "operation") || Map.get(arguments, :operation) do
      operation when is_binary(operation) ->
        case String.trim(operation) do
          "get_issue" = normalized_operation -> {:ok, normalized_operation}
          "list_comments" = normalized_operation -> {:ok, normalized_operation}
          "upsert_workpad_comment" = normalized_operation -> {:ok, normalized_operation}
          "set_status" = normalized_operation -> {:ok, normalized_operation}
          "add_labels" = normalized_operation -> {:ok, normalized_operation}
          other -> {:error, {:unsupported_github_issue_operation, other}}
        end

      _ ->
        {:error, :missing_github_issue_operation}
    end
  end

  defp normalize_github_issue_id(arguments) do
    case Map.get(arguments, "issueId") || Map.get(arguments, :issueId) do
      issue_id when is_binary(issue_id) ->
        case String.trim(issue_id) do
          "" -> {:error, :missing_issue_id}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_issue_id}
    end
  end

  defp normalize_github_issue_payload("get_issue", _arguments), do: {:ok, %{}}
  defp normalize_github_issue_payload("list_comments", _arguments), do: {:ok, %{}}

  defp normalize_github_issue_payload("upsert_workpad_comment", arguments) do
    with {:ok, body} <- normalize_github_body(arguments) do
      {:ok,
       %{
         "body" => body,
         "header" => normalize_github_header(arguments)
       }}
    end
  end

  defp normalize_github_issue_payload("set_status", arguments) do
    with {:ok, state} <- normalize_github_state(arguments) do
      {:ok, %{"state" => state}}
    end
  end

  defp normalize_github_issue_payload("add_labels", arguments) do
    with {:ok, labels} <- normalize_github_labels(arguments) do
      {:ok, %{"labels" => labels}}
    end
  end

  defp normalize_github_issue_payload(_operation, _arguments), do: {:ok, %{}}

  defp normalize_github_body(arguments) do
    case Map.get(arguments, "body") || Map.get(arguments, :body) do
      body when is_binary(body) ->
        case String.trim(body) do
          "" -> {:error, :missing_github_issue_body}
          _ -> {:ok, body}
        end

      _ ->
        {:error, :missing_github_issue_body}
    end
  end

  defp normalize_github_header(arguments) do
    case Map.get(arguments, "header") || Map.get(arguments, :header) do
      header when is_binary(header) ->
        case String.trim(header) do
          "" -> "## Codex Workpad"
          trimmed -> trimmed
        end

      _ -> "## Codex Workpad"
    end
  end

  defp normalize_github_state(arguments) do
    case Map.get(arguments, "state") || Map.get(arguments, :state) do
      state when is_binary(state) ->
        case String.trim(state) do
          "" -> {:error, :missing_github_issue_state}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_github_issue_state}
    end
  end

  defp normalize_github_labels(arguments) do
    case Map.get(arguments, "labels") || Map.get(arguments, :labels) do
      labels when is_list(labels) ->
        normalized_labels =
          labels
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        if normalized_labels == [] do
          {:error, :missing_github_issue_labels}
        else
          {:ok, normalized_labels}
        end

      _ ->
        {:error, :missing_github_issue_labels}
    end
  end

  defp normalize_github_pr_arguments(arguments) when is_map(arguments) do
    with {:ok, operation} <- normalize_github_pr_operation(arguments),
         {:ok, payload} <- normalize_github_pr_payload(operation, arguments) do
      {:ok, operation, payload}
    end
  end

  defp normalize_github_pr_arguments(_arguments), do: {:error, :invalid_github_pr_arguments}

  defp normalize_github_pr_operation(arguments) do
    case Map.get(arguments, "operation") || Map.get(arguments, :operation) do
      operation when is_binary(operation) ->
        case String.trim(operation) do
          "list_for_head" = normalized_operation -> {:ok, normalized_operation}
          "get_pr" = normalized_operation -> {:ok, normalized_operation}
          "create_pr" = normalized_operation -> {:ok, normalized_operation}
          "list_issue_comments" = normalized_operation -> {:ok, normalized_operation}
          "list_reviews" = normalized_operation -> {:ok, normalized_operation}
          "list_review_comments" = normalized_operation -> {:ok, normalized_operation}
          "get_check_status" = normalized_operation -> {:ok, normalized_operation}
          other -> {:error, {:unsupported_github_pr_operation, other}}
        end

      _ ->
        {:error, :missing_github_pr_operation}
    end
  end

  defp normalize_github_pr_payload("list_for_head", arguments) do
    with {:ok, head_ref_name} <- normalize_head_ref_name(arguments) do
      {:ok, %{"headRefName" => head_ref_name}}
    end
  end

  defp normalize_github_pr_payload("get_pr", arguments),
    do: normalize_pr_number_payload(arguments)

  defp normalize_github_pr_payload("list_issue_comments", arguments),
    do: normalize_pr_number_payload(arguments)

  defp normalize_github_pr_payload("list_reviews", arguments),
    do: normalize_pr_number_payload(arguments)

  defp normalize_github_pr_payload("list_review_comments", arguments),
    do: normalize_pr_number_payload(arguments)

  defp normalize_github_pr_payload("get_check_status", arguments),
    do: normalize_pr_number_payload(arguments)

  defp normalize_github_pr_payload("create_pr", arguments) do
    with {:ok, head_ref_name} <- normalize_head_ref_name(arguments),
         {:ok, base_ref_name} <- normalize_base_ref_name(arguments),
         {:ok, title} <- normalize_github_pr_title(arguments),
         {:ok, body} <- normalize_github_pr_body(arguments) do
      {:ok,
       %{
         "headRefName" => head_ref_name,
         "baseRefName" => base_ref_name,
         "title" => title,
         "body" => body,
         "draft" => normalize_github_pr_draft(arguments)
       }}
    end
  end

  defp normalize_github_pr_payload(_operation, _arguments), do: {:ok, %{}}

  defp normalize_pr_number_payload(arguments) do
    with {:ok, pr_number} <- normalize_pr_number(arguments) do
      {:ok, %{"prNumber" => pr_number}}
    end
  end

  defp normalize_pr_number(arguments) do
    case Map.get(arguments, "prNumber") || Map.get(arguments, :prNumber) do
      pr_number when is_binary(pr_number) ->
        case String.trim(pr_number) do
          "" -> {:error, :missing_github_pr_number}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_github_pr_number}
    end
  end

  defp normalize_head_ref_name(arguments) do
    case Map.get(arguments, "headRefName") || Map.get(arguments, :headRefName) do
      head_ref_name when is_binary(head_ref_name) ->
        case String.trim(head_ref_name) do
          "" -> {:error, :missing_github_pr_head_ref_name}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_github_pr_head_ref_name}
    end
  end

  defp normalize_base_ref_name(arguments) do
    case Map.get(arguments, "baseRefName") || Map.get(arguments, :baseRefName) do
      base_ref_name when is_binary(base_ref_name) ->
        case String.trim(base_ref_name) do
          "" -> {:error, :missing_github_pr_base_ref_name}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_github_pr_base_ref_name}
    end
  end

  defp normalize_github_pr_title(arguments) do
    case Map.get(arguments, "title") || Map.get(arguments, :title) do
      title when is_binary(title) ->
        case String.trim(title) do
          "" -> {:error, :missing_github_pr_title}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_github_pr_title}
    end
  end

  defp normalize_github_pr_body(arguments) do
    case Map.get(arguments, "body") || Map.get(arguments, :body) do
      body when is_binary(body) -> {:ok, body}
      _ -> {:error, :missing_github_pr_body}
    end
  end

  defp normalize_github_pr_draft(arguments) do
    case argument_value(arguments, "draft", :draft) do
      draft when is_boolean(draft) -> draft
      _ -> true
    end
  end

  defp execute_github_issue_operation(
         "get_issue",
         issue_id,
         _payload,
         github_fetch_issue,
         _github_list_comments,
         _github_upsert_workpad_comment,
         _github_update_issue_state,
         _github_add_labels
       ) do
    with {:ok, issue} <- github_fetch_issue.(issue_id) do
      {:ok, issue_payload(issue)}
    end
  end

  defp execute_github_issue_operation(
         "list_comments",
         issue_id,
         _payload,
         _github_fetch_issue,
         github_list_comments,
         _github_upsert_workpad_comment,
         _github_update_issue_state,
         _github_add_labels
       ) do
    with {:ok, comments} <- github_list_comments.(issue_id) do
      {:ok, %{"comments" => comments, "issueId" => issue_id}}
    end
  end

  defp execute_github_issue_operation(
         "upsert_workpad_comment",
         issue_id,
         %{"body" => body, "header" => header},
         _github_fetch_issue,
         _github_list_comments,
         github_upsert_workpad_comment,
         _github_update_issue_state,
         _github_add_labels
       ) do
    with {:ok, result} <- github_upsert_workpad_comment.(issue_id, body, header) do
      {:ok, Map.put(result, "issueId", issue_id)}
    end
  end

  defp execute_github_issue_operation(
         "set_status",
         issue_id,
         %{"state" => state},
         _github_fetch_issue,
         _github_list_comments,
         _github_upsert_workpad_comment,
         github_update_issue_state,
         _github_add_labels
       ) do
    with :ok <- github_update_issue_state.(issue_id, state) do
      {:ok, %{"issueId" => issue_id, "state" => state, "updated" => true}}
    end
  end

  defp execute_github_issue_operation(
         "add_labels",
         issue_id,
         %{"labels" => labels},
         _github_fetch_issue,
         _github_list_comments,
         _github_upsert_workpad_comment,
         _github_update_issue_state,
         github_add_labels
       ) do
    with {:ok, applied_labels} <- github_add_labels.(issue_id, labels) do
      {:ok, %{"issueId" => issue_id, "labels" => applied_labels}}
    end
  end

  defp execute_github_pr_operation(
         "list_for_head",
         %{"headRefName" => head_ref_name},
         github_list_pull_requests_for_head,
         _github_get_pull_request,
         _github_create_pull_request,
         _github_list_pull_request_issue_comments,
         _github_list_pull_request_reviews,
         _github_list_pull_request_review_comments,
         _github_get_pull_request_check_status
       ) do
    with {:ok, pull_requests} <- github_list_pull_requests_for_head.(head_ref_name) do
      {:ok, %{"headRefName" => head_ref_name, "pullRequests" => pull_requests}}
    end
  end

  defp execute_github_pr_operation(
         "get_pr",
         %{"prNumber" => pr_number},
         _github_list_pull_requests_for_head,
         github_get_pull_request,
         _github_create_pull_request,
         _github_list_pull_request_issue_comments,
         _github_list_pull_request_reviews,
         _github_list_pull_request_review_comments,
         _github_get_pull_request_check_status
       ) do
    with {:ok, pull_request} <- github_get_pull_request.(pr_number) do
      {:ok, %{"pullRequest" => pull_request}}
    end
  end

  defp execute_github_pr_operation(
         "create_pr",
         %{
           "headRefName" => head_ref_name,
           "baseRefName" => base_ref_name,
           "title" => title,
           "body" => body,
           "draft" => draft
         },
         _github_list_pull_requests_for_head,
         _github_get_pull_request,
         github_create_pull_request,
         _github_list_pull_request_issue_comments,
         _github_list_pull_request_reviews,
         _github_list_pull_request_review_comments,
         _github_get_pull_request_check_status
       ) do
    with {:ok, pull_request} <-
           github_create_pull_request.(head_ref_name, base_ref_name, title, body, draft) do
      {:ok, %{"pullRequest" => pull_request}}
    end
  end

  defp execute_github_pr_operation(
         "list_issue_comments",
         %{"prNumber" => pr_number},
         _github_list_pull_requests_for_head,
         _github_get_pull_request,
         _github_create_pull_request,
         github_list_pull_request_issue_comments,
         _github_list_pull_request_reviews,
         _github_list_pull_request_review_comments,
         _github_get_pull_request_check_status
       ) do
    with {:ok, comments} <- github_list_pull_request_issue_comments.(pr_number) do
      {:ok, %{"comments" => comments, "prNumber" => pr_number}}
    end
  end

  defp execute_github_pr_operation(
         "list_reviews",
         %{"prNumber" => pr_number},
         _github_list_pull_requests_for_head,
         _github_get_pull_request,
         _github_create_pull_request,
         _github_list_pull_request_issue_comments,
         github_list_pull_request_reviews,
         _github_list_pull_request_review_comments,
         _github_get_pull_request_check_status
       ) do
    with {:ok, reviews} <- github_list_pull_request_reviews.(pr_number) do
      {:ok, %{"prNumber" => pr_number, "reviews" => reviews}}
    end
  end

  defp execute_github_pr_operation(
         "list_review_comments",
         %{"prNumber" => pr_number},
         _github_list_pull_requests_for_head,
         _github_get_pull_request,
         _github_create_pull_request,
         _github_list_pull_request_issue_comments,
         _github_list_pull_request_reviews,
         github_list_pull_request_review_comments,
         _github_get_pull_request_check_status
       ) do
    with {:ok, comments} <- github_list_pull_request_review_comments.(pr_number) do
      {:ok, %{"comments" => comments, "prNumber" => pr_number}}
    end
  end

  defp execute_github_pr_operation(
         "get_check_status",
         %{"prNumber" => pr_number},
         _github_list_pull_requests_for_head,
         _github_get_pull_request,
         _github_create_pull_request,
         _github_list_pull_request_issue_comments,
         _github_list_pull_request_reviews,
         _github_list_pull_request_review_comments,
         github_get_pull_request_check_status
       ) do
    with {:ok, check_status} <- github_get_pull_request_check_status.(pr_number) do
      {:ok, check_status}
    end
  end

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp issue_payload(nil), do: %{"issue" => nil}

  defp issue_payload(%Linear.Issue{} = issue) do
    %{
      "issue" => %{
        "assignedToWorker" => issue.assigned_to_worker,
        "assigneeId" => issue.assignee_id,
        "blockedBy" => issue.blocked_by,
        "createdAt" => format_datetime(issue.created_at),
        "description" => issue.description,
        "id" => issue.id,
        "identifier" => issue.identifier,
        "labels" => issue.labels,
        "priority" => issue.priority,
        "state" => issue.state,
        "title" => issue.title,
        "updatedAt" => format_datetime(issue.updated_at),
        "url" => issue.url
      }
    }
  end

  defp validate_github_tracker(opts) do
    tracker_kind =
      Keyword.get_lazy(opts, :tracker_kind, fn ->
        Config.settings!().tracker.kind
      end)

    if tracker_kind == "github" do
      :ok
    else
      {:error, :github_tracker_not_configured}
    end
  end

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(_datetime), do: nil

  defp argument_value(arguments, string_key, atom_key) when is_map(arguments) do
    cond do
      Map.has_key?(arguments, string_key) -> Map.get(arguments, string_key)
      Map.has_key?(arguments, atom_key) -> Map.get(arguments, atom_key)
      true -> nil
    end
  end

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    case reason do
      :missing_github_issue_operation ->
        %{
          "error" => %{
            "message" => "`github_issue` requires an `operation`."
          }
        }

      {:unsupported_github_issue_operation, operation} ->
        %{
          "error" => %{
            "message" => "Unsupported `github_issue.operation`: #{inspect(operation)}.",
              "supportedOperations" => [
                "get_issue",
                "list_comments",
                "upsert_workpad_comment",
                "set_status",
                "add_labels"
              ]
          }
        }

      :missing_issue_id ->
        %{
          "error" => %{
            "message" => "`github_issue` requires a non-empty `issueId`."
          }
        }

      :missing_github_issue_body ->
        %{
          "error" => %{
            "message" => "`github_issue` requires a non-empty `body` for `upsert_workpad_comment`."
          }
        }

      :missing_github_issue_state ->
        %{
          "error" => %{
            "message" => "`github_issue` requires a non-empty `state` for `set_status`."
          }
        }

      :missing_github_issue_labels ->
        %{
          "error" => %{
            "message" => "`github_issue` requires a non-empty `labels` array for `add_labels`."
          }
        }

      :invalid_github_issue_arguments ->
        %{
          "error" => %{
            "message" => "`github_issue` expects an object with `operation`, `issueId`, and any required operation-specific fields."
          }
        }

      :missing_github_pr_operation ->
        %{
          "error" => %{
            "message" => "`github_pr` requires an `operation`."
          }
        }

      {:unsupported_github_pr_operation, operation} ->
        %{
          "error" => %{
            "message" => "Unsupported `github_pr.operation`: #{inspect(operation)}.",
            "supportedOperations" => [
              "list_for_head",
              "get_pr",
              "create_pr",
              "list_issue_comments",
              "list_reviews",
              "list_review_comments",
              "get_check_status"
            ]
          }
        }

      :missing_github_pr_number ->
        %{
          "error" => %{
            "message" => "`github_pr` requires a non-empty `prNumber` for this operation."
          }
        }

      :missing_github_pr_head_ref_name ->
        %{
          "error" => %{
            "message" => "`github_pr` requires a non-empty `headRefName`."
          }
        }

      :missing_github_pr_base_ref_name ->
        %{
          "error" => %{
            "message" => "`github_pr` requires a non-empty `baseRefName` for `create_pr`."
          }
        }

      :missing_github_pr_title ->
        %{
          "error" => %{
            "message" => "`github_pr` requires a non-empty `title` for `create_pr`."
          }
        }

      :missing_github_pr_body ->
        %{
          "error" => %{
            "message" => "`github_pr` requires a `body` string for `create_pr`."
          }
        }

      :invalid_github_pr_arguments ->
        %{
          "error" => %{
            "message" => "`github_pr` expects an object with `operation` and any required operation-specific fields."
          }
        }

      :github_tracker_not_configured ->
        %{
          "error" => %{
            "message" => "Symphony's tracker is not configured for GitHub, so `github_issue` is unavailable."
          }
        }

      :missing_github_api_token ->
        %{
          "error" => %{
            "message" => "Symphony is missing GitHub auth. Set `tracker.api_key` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
          }
        }

      {:github_api_status, status} ->
        %{
          "error" => %{
            "message" => "GitHub API request failed with HTTP #{status}.",
            "status" => status
          }
        }

      {:github_api_request, reason} ->
        %{
          "error" => %{
            "message" => "GitHub API request failed before receiving a successful response.",
            "reason" => inspect(reason)
          }
        }

      :invalid_issue_id ->
        %{
          "error" => %{
            "message" => "`github_issue.issueId` must be a positive integer string."
          }
        }

      :invalid_comment_id ->
        %{
          "error" => %{
            "message" => "GitHub comment ids must be positive integer strings."
          }
        }

      :github_project_item_not_found ->
        %{
          "error" => %{
            "message" => "The issue is not attached to the configured GitHub Project."
          }
        }

      :github_project_status_option_not_found ->
        %{
          "error" => %{
            "message" => "The requested GitHub Project status does not exist on the configured Status field."
          }
        }

      :issue_not_found ->
        %{
          "error" => %{
            "message" => "The requested GitHub issue was not found."
          }
        }

      :comment_create_failed ->
        %{
          "error" => %{
            "message" => "GitHub issue comment creation failed."
          }
        }

      :comment_update_failed ->
        %{
          "error" => %{
            "message" => "GitHub issue comment update failed."
          }
        }

      :label_update_failed ->
        %{
          "error" => %{
            "message" => "GitHub label update failed."
          }
        }

      :pull_request_create_failed ->
        %{
          "error" => %{
            "message" => "GitHub pull request creation failed."
          }
        }

      _ ->
        %{
          "error" => %{
            "message" => "Dynamic tool execution failed.",
            "reason" => inspect(reason)
          }
        }
    end
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
