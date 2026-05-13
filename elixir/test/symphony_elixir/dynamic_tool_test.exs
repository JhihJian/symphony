defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises the Linear and GitHub dynamic tool contracts" do
    specs = DynamicTool.tool_specs()

    assert Enum.any?(specs, fn
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{"query" => _, "variables" => _},
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             } -> description =~ "Linear"
             _ -> false
           end)

    assert Enum.any?(specs, fn
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "body" => _,
                   "header" => _,
                   "issueId" => _,
                   "labels" => _,
                   "operation" => %{"enum" => operations},
                   "state" => _
                 },
                 "required" => ["operation", "issueId"],
                 "type" => "object"
               },
               "name" => "github_issue"
             } ->
               description =~ "GitHub" and
                 operations == [
                   "get_issue",
                   "list_comments",
                   "upsert_workpad_comment",
                   "set_status",
                   "add_labels"
                 ]

             _ ->
               false
           end)

    assert Enum.any?(specs, fn
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "baseRefName" => _,
                   "body" => _,
                   "draft" => _,
                   "headRefName" => _,
                   "operation" => %{"enum" => operations},
                   "prNumber" => _,
                   "title" => _
                 },
                 "required" => ["operation"],
                 "type" => "object"
               },
               "name" => "github_pr"
             } ->
               description =~ "GitHub pull request" and
                 operations == [
                   "list_for_head",
                   "get_pr",
                   "create_pr",
                   "list_issue_comments",
                   "list_reviews",
                   "list_review_comments",
                   "get_check_status"
                 ]

             _ ->
               false
           end)
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql", "github_issue", "github_pr"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Dynamic tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end

  test "github_issue gets issue details through Symphony's GitHub auth" do
    response =
      DynamicTool.execute(
        "github_issue",
        %{"operation" => "get_issue", "issueId" => "42"},
        tracker_kind: "github",
        github_fetch_issue: fn "42" ->
          {:ok,
           %SymphonyElixir.Linear.Issue{
             id: "42",
             identifier: "your-org/your-repo#42",
             title: "Wire GitHub tool",
             description: "Use the API path.",
             state: "In Progress",
             url: "https://github.com/your-org/your-repo/issues/42",
             labels: ["symphony"],
             assigned_to_worker: true
           }}
        end
      )

    assert response["success"] == true

    assert Jason.decode!(response["output"]) == %{
             "issue" => %{
               "assignedToWorker" => true,
               "assigneeId" => nil,
               "blockedBy" => [],
               "createdAt" => nil,
               "description" => "Use the API path.",
               "id" => "42",
               "identifier" => "your-org/your-repo#42",
               "labels" => ["symphony"],
               "priority" => nil,
               "state" => "In Progress",
               "title" => "Wire GitHub tool",
               "updatedAt" => nil,
               "url" => "https://github.com/your-org/your-repo/issues/42"
             }
           }
  end

  test "github_issue lists comments" do
    response =
      DynamicTool.execute(
        "github_issue",
        %{"operation" => "list_comments", "issueId" => "42"},
        tracker_kind: "github",
        github_list_comments: fn "42" ->
          {:ok,
           [
             %{
               "id" => "101",
               "authorLogin" => "codex",
               "body" => "## Codex Workpad",
               "url" => "https://github.com/comment/101"
             }
           ]}
        end
      )

    assert response["success"] == true

    assert Jason.decode!(response["output"]) == %{
             "comments" => [
               %{
                 "authorLogin" => "codex",
                 "body" => "## Codex Workpad",
                 "id" => "101",
                 "url" => "https://github.com/comment/101"
               }
             ],
             "issueId" => "42"
           }
  end

  test "github_issue upserts the workpad comment" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "github_issue",
        %{
          "operation" => "upsert_workpad_comment",
          "issueId" => "42",
          "body" => "## Codex Workpad\n\nUpdated body"
        },
        tracker_kind: "github",
        github_upsert_workpad_comment: fn issue_id, body, header ->
          send(test_pid, {:github_upsert_workpad_comment_called, issue_id, body, header})

          {:ok,
           %{
             "action" => "updated",
             "comment" => %{"id" => "101", "url" => "https://github.com/comment/101"}
           }}
        end
      )

    assert_received {:github_upsert_workpad_comment_called, "42",
                     "## Codex Workpad\n\nUpdated body", "## Codex Workpad"}

    assert response["success"] == true

    assert Jason.decode!(response["output"]) == %{
             "action" => "updated",
             "comment" => %{"id" => "101", "url" => "https://github.com/comment/101"},
             "issueId" => "42"
           }
  end

  test "github_issue sets the project status" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "github_issue",
        %{"operation" => "set_status", "issueId" => "42", "state" => "Human Review"},
        tracker_kind: "github",
        github_update_issue_state: fn issue_id, state ->
          send(test_pid, {:github_update_issue_state_called, issue_id, state})
          :ok
        end
      )

    assert_received {:github_update_issue_state_called, "42", "Human Review"}
    assert response["success"] == true

    assert Jason.decode!(response["output"]) == %{
             "issueId" => "42",
             "state" => "Human Review",
             "updated" => true
           }
  end

  test "github_issue adds labels to an issue or pull request" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "github_issue",
        %{"operation" => "add_labels", "issueId" => "42", "labels" => ["symphony", "backend"]},
        tracker_kind: "github",
        github_add_labels: fn issue_id, labels ->
          send(test_pid, {:github_add_labels_called, issue_id, labels})
          {:ok, labels}
        end
      )

    assert_received {:github_add_labels_called, "42", ["symphony", "backend"]}

    assert Jason.decode!(response["output"]) == %{
             "issueId" => "42",
             "labels" => ["symphony", "backend"]
           }
  end

  test "github_issue rejects use when the GitHub tracker is not configured" do
    response =
      DynamicTool.execute(
        "github_issue",
        %{"operation" => "get_issue", "issueId" => "42"},
        tracker_kind: "linear"
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" =>
                 "Symphony's tracker is not configured for GitHub, so `github_issue` is unavailable."
             }
           }
  end

  test "github_issue validates operation-specific arguments" do
    missing_operation =
      DynamicTool.execute(
        "github_issue",
        %{"issueId" => "42"},
        tracker_kind: "github"
      )

    assert Jason.decode!(missing_operation["output"]) == %{
             "error" => %{"message" => "`github_issue` requires an `operation`."}
           }

    missing_body =
      DynamicTool.execute(
        "github_issue",
        %{"operation" => "upsert_workpad_comment", "issueId" => "42", "body" => "   "},
        tracker_kind: "github"
      )

    assert Jason.decode!(missing_body["output"]) == %{
             "error" => %{
               "message" =>
                 "`github_issue` requires a non-empty `body` for `upsert_workpad_comment`."
             }
           }

    missing_state =
      DynamicTool.execute(
        "github_issue",
        %{"operation" => "set_status", "issueId" => "42"},
        tracker_kind: "github"
      )

    assert Jason.decode!(missing_state["output"]) == %{
             "error" => %{
               "message" => "`github_issue` requires a non-empty `state` for `set_status`."
             }
           }

    missing_labels =
      DynamicTool.execute(
        "github_issue",
        %{"operation" => "add_labels", "issueId" => "42", "labels" => []},
        tracker_kind: "github"
      )

    assert Jason.decode!(missing_labels["output"]) == %{
             "error" => %{
               "message" => "`github_issue` requires a non-empty `labels` array for `add_labels`."
             }
           }
  end

  test "github_issue formats GitHub API failures" do
    missing_token =
      DynamicTool.execute(
        "github_issue",
        %{"operation" => "get_issue", "issueId" => "42"},
        tracker_kind: "github",
        github_fetch_issue: fn _issue_id -> {:error, :missing_github_api_token} end
      )

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" =>
                 "Symphony is missing GitHub auth. Set `tracker.api_key` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
             }
           }

    status_error =
      DynamicTool.execute(
        "github_issue",
        %{"operation" => "set_status", "issueId" => "42", "state" => "Todo"},
        tracker_kind: "github",
        github_update_issue_state: fn _issue_id, _state -> {:error, {:github_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "GitHub API request failed with HTTP 503.",
               "status" => 503
             }
           }
  end

  test "github_pr lists pull requests for a branch head" do
    response =
      DynamicTool.execute(
        "github_pr",
        %{"operation" => "list_for_head", "headRefName" => "feature/test-branch"},
        tracker_kind: "github",
        github_list_pull_requests_for_head: fn "feature/test-branch" ->
          {:ok, [%{"number" => 11, "title" => "Test PR"}]}
        end
      )

    assert Jason.decode!(response["output"]) == %{
             "headRefName" => "feature/test-branch",
             "pullRequests" => [%{"number" => 11, "title" => "Test PR"}]
           }
  end

  test "github_pr gets a pull request, reviews, comments, and checks" do
    pr_response =
      DynamicTool.execute(
        "github_pr",
        %{"operation" => "get_pr", "prNumber" => "11"},
        tracker_kind: "github",
        github_get_pull_request: fn "11" ->
          {:ok, %{"number" => 11, "title" => "Test PR", "state" => "OPEN"}}
        end
      )

    assert Jason.decode!(pr_response["output"]) == %{
             "pullRequest" => %{"number" => 11, "state" => "OPEN", "title" => "Test PR"}
           }

    reviews_response =
      DynamicTool.execute(
        "github_pr",
        %{"operation" => "list_reviews", "prNumber" => "11"},
        tracker_kind: "github",
        github_list_pull_request_reviews: fn "11" ->
          {:ok, [%{"state" => "APPROVED", "authorLogin" => "reviewer"}]}
        end
      )

    assert Jason.decode!(reviews_response["output"]) == %{
             "prNumber" => "11",
             "reviews" => [%{"authorLogin" => "reviewer", "state" => "APPROVED"}]
           }

    review_comments_response =
      DynamicTool.execute(
        "github_pr",
        %{"operation" => "list_review_comments", "prNumber" => "11"},
        tracker_kind: "github",
        github_list_pull_request_review_comments: fn "11" ->
          {:ok, [%{"body" => "nit", "path" => "server/test.py"}]}
        end
      )

    assert Jason.decode!(review_comments_response["output"]) == %{
             "comments" => [%{"body" => "nit", "path" => "server/test.py"}],
             "prNumber" => "11"
           }

    checks_response =
      DynamicTool.execute(
        "github_pr",
        %{"operation" => "get_check_status", "prNumber" => "11"},
        tracker_kind: "github",
        github_get_pull_request_check_status: fn "11" ->
          {:ok, %{"combinedStatus" => %{"state" => "success"}, "headSha" => "abc123"}}
        end
      )

    assert Jason.decode!(checks_response["output"]) == %{
             "combinedStatus" => %{"state" => "success"},
             "headSha" => "abc123"
           }
  end

  test "github_pr creates a draft pull request" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "github_pr",
        %{
          "operation" => "create_pr",
          "headRefName" => "feature/test-branch",
          "baseRefName" => "main",
          "title" => "Test PR",
          "body" => "Summary",
          "draft" => true
        },
        tracker_kind: "github",
        github_create_pull_request: fn head_ref_name, base_ref_name, title, body, draft ->
          send(test_pid, {:github_create_pull_request_called, head_ref_name, base_ref_name, title, body, draft})
          {:ok, %{"number" => 11, "title" => title, "isDraft" => draft}}
        end
      )

    assert_received {:github_create_pull_request_called, "feature/test-branch", "main", "Test PR", "Summary", true}

    assert Jason.decode!(response["output"]) == %{
             "pullRequest" => %{"isDraft" => true, "number" => 11, "title" => "Test PR"}
           }
  end

  test "github_pr preserves draft false when creating a ready-for-review pull request" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "github_pr",
        %{
          "operation" => "create_pr",
          "headRefName" => "feature/test-branch",
          "baseRefName" => "main",
          "title" => "Ready PR",
          "body" => "Summary",
          "draft" => false
        },
        tracker_kind: "github",
        github_create_pull_request: fn head_ref_name, base_ref_name, title, body, draft ->
          send(test_pid, {:github_create_pull_request_called, head_ref_name, base_ref_name, title, body, draft})
          {:ok, %{"number" => 12, "title" => title, "isDraft" => draft}}
        end
      )

    assert_received {:github_create_pull_request_called, "feature/test-branch", "main", "Ready PR", "Summary", false}

    assert Jason.decode!(response["output"]) == %{
             "pullRequest" => %{"isDraft" => false, "number" => 12, "title" => "Ready PR"}
           }
  end

  test "github_pr validates required arguments" do
    missing_operation =
      DynamicTool.execute(
        "github_pr",
        %{"prNumber" => "11"},
        tracker_kind: "github"
      )

    assert Jason.decode!(missing_operation["output"]) == %{
             "error" => %{"message" => "`github_pr` requires an `operation`."}
           }

    missing_pr_number =
      DynamicTool.execute(
        "github_pr",
        %{"operation" => "get_pr"},
        tracker_kind: "github"
      )

    assert Jason.decode!(missing_pr_number["output"]) == %{
             "error" => %{
               "message" => "`github_pr` requires a non-empty `prNumber` for this operation."
             }
           }

    missing_head_ref_name =
      DynamicTool.execute(
        "github_pr",
        %{"operation" => "list_for_head"},
        tracker_kind: "github"
      )

    assert Jason.decode!(missing_head_ref_name["output"]) == %{
             "error" => %{
               "message" => "`github_pr` requires a non-empty `headRefName`."
             }
           }
  end

  test "github_pr formats GitHub transport failures" do
    response =
      DynamicTool.execute(
        "github_pr",
        %{"operation" => "get_pr", "prNumber" => "11"},
        tracker_kind: "github",
        github_get_pull_request: fn _pr_number -> {:error, {:github_api_request, :timeout}} end
      )

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "GitHub API request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end
end
