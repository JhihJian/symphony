defmodule SymphonyElixir.ProviderContractE2ETest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Client, as: GitHubClient
  alias SymphonyElixir.GitLab.Client, as: GitLabClient

  test "GitHub issues-only contract fetches, refreshes, comments, and updates native issue state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com/graphql",
      tracker_api_token: "github-token",
      tracker_owner: "openai",
      tracker_repo: "symphony",
      tracker_project_number: nil,
      tracker_required_labels: ["symphony-test"]
    )

    graphql_fun = fn query, variables ->
      send(self(), {:github_graphql, query, variables})

      {:ok,
       %{
         "data" => %{
           "repository" => %{
             "issues" => %{
               "nodes" => [
                 github_issue_payload(42, "OPEN", ["symphony-test"], ["worker-1"], [])
               ],
               "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
             }
           }
         }
       }}
    end

    assert {:ok, [issue]} = GitHubClient.fetch_candidate_issues_for_test(graphql_fun)
    assert issue.id == "42"
    assert issue.state == "Open"
    assert issue.labels == ["symphony-test"]

    assert_receive {:github_graphql, list_query, list_variables}
    assert list_query =~ "query SymphonyGitHubIssues"
    assert list_variables.owner == "openai"
    assert list_variables.repo == "symphony"
    assert list_variables.issueStates == ["OPEN"]
    assert list_variables.after == nil

    rest_fun = fn method, path, body ->
      send(self(), {:github_rest, method, path, body})
      status = if method == :post, do: 201, else: 200
      {:ok, %{status: status, body: []}}
    end

    assert :ok = GitHubClient.create_comment_for_test("42", "hello", rest_fun)
    assert_receive {:github_rest, :post, "/repos/openai/symphony/issues/42/comments", %{body: "hello"}}

    assert :ok = GitHubClient.update_issue_state_for_test("42", "Closed", graphql_fun, rest_fun)
    assert_receive {:github_rest, :patch, "/repos/openai/symphony/issues/42", %{state: "closed", state_reason: "completed"}}
  end

  test "GitHub Projects v2 contract fetches project status and updates project field plus native issue state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com/graphql",
      tracker_api_token: "github-token",
      tracker_owner: "openai",
      tracker_repo: "symphony",
      tracker_project_number: 7,
      tracker_project_status_field_name: "Status",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Blocked"]
    )

    graphql_fun = fn query, variables ->
      send(self(), {:github_project_graphql, query, variables})

      cond do
        query =~ "query SymphonyGitHubIssueByNumber" ->
          {:ok,
           %{
             "data" => %{
               "repository" => %{
                 "issue" =>
                   github_issue_payload(
                     42,
                     "OPEN",
                     ["symphony-test"],
                     ["worker-1"],
                     [
                       %{
                         "id" => "item-1",
                         "project" => %{"id" => "project-7", "number" => 7},
                         "fieldValueByName" => %{
                           "name" => "Todo",
                           "field" => %{
                             "id" => "field-1",
                             "options" => [
                               %{"id" => "opt-todo", "name" => "Todo"},
                               %{"id" => "opt-review", "name" => "In Progress"},
                               %{"id" => "opt-blocked", "name" => "Blocked"}
                             ]
                           }
                         }
                       }
                     ]
                   )
               }
             }
           }}

        query =~ "mutation SymphonyUpdateGitHubProjectStatus" ->
          {:ok,
           %{
             "data" => %{
               "updateProjectV2ItemFieldValue" => %{
                 "projectV2Item" => %{"id" => "item-1"}
               }
             }
           }}
      end
    end

    rest_fun = fn method, path, body ->
      send(self(), {:github_project_rest, method, path, body})
      {:ok, %{status: 200, body: %{}}}
    end

    assert :ok = GitHubClient.update_issue_state_for_test("42", "In Progress", graphql_fun, rest_fun)

    assert_receive {:github_project_graphql, issue_query, issue_variables}
    assert issue_query =~ "query SymphonyGitHubIssueByNumber"
    assert issue_variables.issueNumber == 42
    assert issue_variables.statusFieldName == "Status"

    assert_receive {:github_project_graphql, mutation, mutation_variables}
    assert mutation =~ "mutation SymphonyUpdateGitHubProjectStatus"
    assert mutation_variables.projectId == "project-7"
    assert mutation_variables.itemId == "item-1"
    assert mutation_variables.fieldId == "field-1"
    assert mutation_variables.optionId == "opt-review"

    assert_receive {:github_project_rest, :patch, "/repos/openai/symphony/issues/42", %{state: "open"}}

    assert :ok = GitHubClient.update_issue_state_for_test("42", "Blocked", graphql_fun, rest_fun)

    assert_receive {:github_project_graphql, issue_query, issue_variables}
    assert issue_query =~ "query SymphonyGitHubIssueByNumber"
    assert issue_variables.issueNumber == 42

    assert_receive {:github_project_graphql, mutation, mutation_variables}
    assert mutation =~ "mutation SymphonyUpdateGitHubProjectStatus"
    assert mutation_variables.optionId == "opt-blocked"
    refute_receive {:github_project_rest, :patch, "/repos/openai/symphony/issues/42", %{state: "closed"}}, 100
  end

  test "GitLab contract pages candidates, refreshes IDs, comments, and maps active and terminal updates" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: "https://gitlab.example.com/api/v4",
      tracker_api_token: "gitlab-token",
      tracker_project_slug: "platform/symphony",
      tracker_required_labels: ["symphony-test"],
      tracker_assignee: "worker-1",
      tracker_active_states: ["Todo"],
      tracker_terminal_states: ["Done", "Closed"]
    )

    request_fun = fn opts ->
      send(self(), {:gitlab_request, opts})

      case {opts[:method], opts[:url], opts[:params], opts[:json]} do
        {:get, "https://gitlab.example.com/api/v4/projects/platform%2Fsymphony/issues", %{page: 1}, _json} ->
          {:ok,
           %{
             status: 200,
             body: [gitlab_issue_payload(7, "opened", ["symphony-test"], [%{"username" => "worker-1"}])],
             headers: [{"x-next-page", "2"}]
           }}

        {:get, "https://gitlab.example.com/api/v4/projects/platform%2Fsymphony/issues", %{page: 2}, _json} ->
          {:ok, %{status: 200, body: [], headers: [{"x-next-page", ""}]}}

        {:get, "https://gitlab.example.com/api/v4/projects/platform%2Fsymphony/issues/7", _params, _json} ->
          {:ok,
           %{
             status: 200,
             body: gitlab_issue_payload(7, "opened", ["symphony-test"], [%{"username" => "worker-1"}]),
             headers: []
           }}

        {:post, "https://gitlab.example.com/api/v4/projects/platform%2Fsymphony/issues/7/notes", _params, %{body: "hello"}} ->
          {:ok, %{status: 201, body: %{}, headers: []}}

        {:put, "https://gitlab.example.com/api/v4/projects/platform%2Fsymphony/issues/7", _params, %{state_event: event}}
        when event in ["close", "reopen"] ->
          {:ok, %{status: 200, body: %{}, headers: []}}
      end
    end

    assert {:ok, [issue]} = GitLabClient.fetch_candidate_issues_for_test(request_fun)
    assert issue.id == "gitlab:platform/symphony#7"
    assert issue.state == "Todo"

    assert_receive {:gitlab_request, list_page_1}
    assert list_page_1[:params][:state] == "opened"
    assert list_page_1[:params][:labels] == "symphony-test"
    assert list_page_1[:params][:assignee_username] == "worker-1"
    assert list_page_1[:headers] == [{"accept", "application/json"}, {"private-token", "gitlab-token"}]

    assert_receive {:gitlab_request, list_page_2}
    assert list_page_2[:params][:page] == 2

    assert {:ok, [refreshed]} = GitLabClient.fetch_issue_states_by_ids_for_test(["gitlab:platform/symphony#7"], request_fun)
    assert refreshed.identifier == "platform/symphony#7"
    assert_receive {:gitlab_request, refresh_request}
    assert refresh_request[:method] == :get
    assert refresh_request[:url] == "https://gitlab.example.com/api/v4/projects/platform%2Fsymphony/issues/7"

    assert :ok = GitLabClient.create_comment_for_test("gitlab:platform/symphony#7", "hello", request_fun)
    assert :ok = GitLabClient.update_issue_state_for_test("gitlab:platform/symphony#7", "Done", request_fun)
    assert :ok = GitLabClient.update_issue_state_for_test("gitlab:platform/symphony#7", "Closed", request_fun)
    assert :ok = GitLabClient.update_issue_state_for_test("gitlab:platform/symphony#7", "Todo", request_fun)

    assert_receive {:gitlab_request, comment_request}
    assert comment_request[:method] == :post
    assert comment_request[:json] == %{body: "hello"}

    assert_receive {:gitlab_request, close_request}
    assert close_request[:json] == %{state_event: "close"}

    assert_receive {:gitlab_request, blocked_request}
    assert blocked_request[:json] == %{state_event: "reopen"}

    assert_receive {:gitlab_request, reopen_request}
    assert reopen_request[:json] == %{state_event: "reopen"}
  end

  defp github_issue_payload(number, state, labels, assignees, project_items) do
    %{
      "id" => "issue-node-#{number}",
      "number" => number,
      "title" => "GitHub issue #{number}",
      "body" => "Issue body #{number}",
      "state" => state,
      "url" => "https://github.com/openai/symphony/issues/#{number}",
      "labels" => %{"nodes" => Enum.map(labels, &%{"name" => &1})},
      "assignees" => %{"nodes" => Enum.map(assignees, &%{"login" => &1})},
      "blockedBy" => %{"nodes" => []},
      "projectItems" => %{"nodes" => project_items},
      "createdAt" => "2026-06-08T00:00:00Z",
      "updatedAt" => "2026-06-08T00:00:00Z"
    }
  end

  defp gitlab_issue_payload(iid, state, labels, assignees) when is_integer(iid) do
    %{
      "id" => 10_000 + iid,
      "iid" => iid,
      "title" => "GitLab issue #{iid}",
      "description" => "Issue body #{iid}",
      "state" => state,
      "web_url" => "https://gitlab.example.com/platform/symphony/-/issues/#{iid}",
      "labels" => labels,
      "assignees" => assignees,
      "blocking_issues" => [],
      "created_at" => "2026-06-08T00:00:00.000Z",
      "updated_at" => "2026-06-08T00:00:00.000Z"
    }
  end
end
