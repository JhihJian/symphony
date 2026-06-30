defmodule SymphonyElixir.PullRequest.Unsupported do
  @moduledoc false

  @behaviour SymphonyElixir.PullRequest

  @unsupported {:error, :pull_request_provider_not_configured}

  @impl true
  def list_for_head(_head_ref_name), do: @unsupported

  @impl true
  def get(_pr_number), do: @unsupported

  @impl true
  def create(_head_ref_name, _base_ref_name, _title, _body, _draft), do: @unsupported

  @impl true
  def list_issue_comments(_pr_number), do: @unsupported

  @impl true
  def list_reviews(_pr_number), do: @unsupported

  @impl true
  def list_review_comments(_pr_number), do: @unsupported

  @impl true
  def get_check_status(_pr_number), do: @unsupported
end
