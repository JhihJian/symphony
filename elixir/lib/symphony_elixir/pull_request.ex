defmodule SymphonyElixir.PullRequest do
  @moduledoc """
  Provider boundary for pull request lifecycle operations.

  This is intentionally separate from `SymphonyElixir.Tracker`, which owns issue and workflow-state
  concerns. A tracker may be Linear or GitHub Projects, while the pull request provider can remain
  GitHub-backed regardless of where issue state lives.
  """

  alias SymphonyElixir.Config

  @callback list_for_head(String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback get(String.t()) :: {:ok, map()} | {:error, term()}
  @callback create(String.t(), String.t(), String.t(), String.t(), boolean()) ::
              {:ok, map()} | {:error, term()}
  @callback list_issue_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback list_reviews(String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback list_review_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback get_check_status(String.t()) :: {:ok, map()} | {:error, term()}

  @spec list_for_head(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_for_head(head_ref_name) do
    provider().list_for_head(head_ref_name)
  end

  @spec get(String.t()) :: {:ok, map()} | {:error, term()}
  def get(pr_number) do
    provider().get(pr_number)
  end

  @spec create(String.t(), String.t(), String.t(), String.t(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def create(head_ref_name, base_ref_name, title, body, draft \\ true) do
    provider().create(head_ref_name, base_ref_name, title, body, draft)
  end

  @spec list_issue_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_issue_comments(pr_number) do
    provider().list_issue_comments(pr_number)
  end

  @spec list_reviews(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_reviews(pr_number) do
    provider().list_reviews(pr_number)
  end

  @spec list_review_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_review_comments(pr_number) do
    provider().list_review_comments(pr_number)
  end

  @spec get_check_status(String.t()) :: {:ok, map()} | {:error, term()}
  def get_check_status(pr_number) do
    provider().get_check_status(pr_number)
  end

  @spec provider() :: module()
  def provider do
    case Config.settings!().tracker.kind do
      "github" ->
        Application.get_env(
          :symphony_elixir,
          :pull_request_provider_module,
          SymphonyElixir.GitHub.PullRequest
        )

      _ ->
        SymphonyElixir.PullRequest.Unsupported
    end
  end
end
