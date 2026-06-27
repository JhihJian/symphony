defmodule SymphonyElixir.HubIssueRefTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.IssueRef

  test "builds a Memory issue ref scoped by project namespace" do
    tracker = %{kind: "memory", namespace: "local-dev"}
    issue = %Issue{id: "memory-1", identifier: "MEM-1", title: "Memory", url: nil}

    assert {:ok, ref} = IssueRef.from_issue("memory-project", tracker, issue)
    assert ref.project_id == "memory-project"
    assert ref.tracker_kind == "memory"
    assert ref.provider_scope == %{namespace: "local-dev"}
    assert ref.provider_scope_key == "memory:local-dev"
    assert ref.provider_issue_id == "memory-1"
    assert ref.provider_local_id == "MEM-1"
    assert ref.identifier == "MEM-1"
    assert IssueRef.key(ref) == "memory-project:memory:local-dev:memory-1"
  end

  test "builds a GitHub issue ref without treating the issue number as global" do
    tracker = %{kind: "github", owner: "OpenAI", repo: "symphony", project_number: 7}
    issue = %Issue{id: "42", identifier: "OpenAI/symphony#42", title: "GitHub", url: "https://github.com/OpenAI/symphony/issues/42"}

    assert {:ok, ref} = IssueRef.from_issue("github-project", tracker, issue)
    assert ref.tracker_kind == "github"
    assert ref.provider_scope == %{owner: "OpenAI", repo: "symphony", project_number: 7}
    assert ref.provider_scope_key == "github:openai/symphony"
    assert ref.provider_issue_id == "42"
    assert ref.provider_local_id == nil
    assert ref.identifier == "OpenAI/symphony#42"
    assert IssueRef.key(ref) == "github-project:github:openai/symphony:42"
  end

  test "builds a GitLab issue ref with project scope and provider-local iid" do
    tracker = %{kind: "gitlab", project_slug: "platform/symphony"}
    issue = %{id: "gitlab:platform/symphony#7", iid: 7, identifier: "platform/symphony#7", url: "https://gitlab.example.com/platform/symphony/-/issues/7"}

    assert {:ok, ref} = IssueRef.from_issue("gitlab-project", tracker, issue)
    assert ref.tracker_kind == "gitlab"
    assert ref.provider_scope == %{project_slug: "platform/symphony"}
    assert ref.provider_scope_key == "gitlab:platform/symphony"
    assert ref.provider_issue_id == "gitlab:platform/symphony#7"
    assert ref.provider_local_id == "7"
    assert ref.identifier == "platform/symphony#7"
    assert IssueRef.key(ref) == "gitlab-project:gitlab:platform/symphony:gitlab:platform/symphony#7"
  end

  test "builds a Linear issue ref with project scope" do
    tracker = %{kind: "linear", project_slug: "symphony"}
    issue = %Issue{id: "lin_123", identifier: "SYM-75", title: "Linear", url: "https://linear.app/project/symphony/issue/SYM-75"}

    assert {:ok, ref} = IssueRef.from_issue("linear-project", tracker, issue)
    assert ref.tracker_kind == "linear"
    assert ref.provider_scope == %{project_slug: "symphony"}
    assert ref.provider_scope_key == "linear:symphony"
    assert ref.provider_issue_id == "lin_123"
    assert ref.provider_local_id == "SYM-75"
    assert IssueRef.key(ref) == "linear-project:linear:symphony:lin_123"
  end

  test "requires a provider issue identity" do
    tracker = %{kind: "github", owner: "OpenAI", repo: "symphony"}

    assert {:error, :missing_issue_identity} =
             IssueRef.from_issue("github-project", tracker, %{title: "No id"})
  end
end
