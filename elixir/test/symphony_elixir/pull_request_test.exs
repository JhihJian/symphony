defmodule SymphonyElixir.PullRequestTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PullRequest

  setup do
    previous_provider = Application.get_env(:symphony_elixir, :pull_request_provider_module)

    on_exit(fn ->
      if is_nil(previous_provider) do
        Application.delete_env(:symphony_elixir, :pull_request_provider_module)
      else
        Application.put_env(:symphony_elixir, :pull_request_provider_module, previous_provider)
      end
    end)

    :ok
  end

  test "github tracker selects the GitHub pull request provider" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_owner: "your-org",
      tracker_repo: "your-repo",
      tracker_project_number: 1
    )

    assert PullRequest.provider() == SymphonyElixir.GitHub.PullRequest
  end

  test "non-github trackers use the unsupported pull request provider" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")

    assert PullRequest.provider() == SymphonyElixir.PullRequest.Unsupported
    assert {:error, :pull_request_provider_not_configured} = PullRequest.get("12")
  end
end
