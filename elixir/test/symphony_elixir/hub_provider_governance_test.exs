defmodule SymphonyElixir.HubProviderGovernanceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.IssueRef
  alias SymphonyElixir.Hub.ProviderGovernance

  test "builds safe provider request snapshots across projects and scopes" do
    assert {:ok, github_request} =
             ProviderGovernance.new_request(%{
               project_id: "alpha",
               config_fingerprint: "alpha-fingerprint",
               snapshot_version: "hub-registry:alpha:1",
               provider_scope: github_scope(),
               issue_ref: issue_ref("alpha", "github", "github:jhihjian/symphony", "123", "jhihjian/symphony#79"),
               operation_kind: :candidate_scan,
               logical_key: "scan-ready",
               timeout_ms: 5_000,
               deadline_at: ~U[2026-06-27 09:00:00Z],
               cancel_token: "cancel-token-should-not-leak",
               correlation: %{
                 trace_id: "trace-alpha",
                 token: "github_pat_secret",
                 prompt: "full prompt should not be retained",
                 transcript: "complete Codex transcript"
               }
             })

    assert {:ok, gitlab_request} =
             ProviderGovernance.new_request(%{
               project_id: "beta",
               config_fingerprint: "beta-fingerprint",
               snapshot_version: "hub-registry:beta:1",
               provider_scope: gitlab_scope(),
               operation_kind: :running_reconciliation,
               correlation: %{trace_id: "trace-beta", cookie: "session=secret"}
             })

    github_snapshot = ProviderGovernance.request_snapshot(github_request)
    gitlab_snapshot = ProviderGovernance.request_snapshot(gitlab_request)

    assert github_snapshot.project_id == "alpha"
    assert github_snapshot.provider_kind == "github"
    assert github_snapshot.provider_scope_key == "github:jhihjian/symphony"
    assert github_snapshot.issue_key == "alpha:github:jhihjian/symphony:123"
    assert github_snapshot.operation_kind == "candidate_scan"
    assert github_snapshot.priority == 100
    assert github_snapshot.fairness_key == "alpha"
    assert github_snapshot.replay_policy == "idempotent"
    assert github_snapshot.cancellation_boundary_present == true
    assert github_snapshot.correlation == %{trace_id: "trace-alpha"}

    assert gitlab_snapshot.project_id == "beta"
    assert gitlab_snapshot.provider_kind == "gitlab"
    assert gitlab_snapshot.provider_scope_key == "gitlab:platform/beta"
    assert gitlab_snapshot.operation_kind == "running_reconciliation"
    assert gitlab_snapshot.priority < github_snapshot.priority

    safe_text = inspect([github_snapshot, gitlab_snapshot])
    refute safe_text =~ "github_pat_secret"
    refute safe_text =~ "cancel-token-should-not-leak"
    refute safe_text =~ "token"
    refute safe_text =~ "api_key"
    refute safe_text =~ "credential"
    refute safe_text =~ "cookie"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "Codex transcript"
  end

  test "schedules by priority and rotates same-scope project fairness" do
    queue = ProviderGovernance.new_queue()

    queue =
      queue
      |> enqueue!(
        request(
          project_id: "alpha",
          provider_scope: github_scope(),
          operation_kind: :candidate_scan,
          logical_key: "alpha-scan-1"
        )
      )
      |> enqueue!(
        request(
          project_id: "alpha",
          provider_scope: github_scope(),
          operation_kind: :candidate_scan,
          logical_key: "alpha-scan-2"
        )
      )
      |> enqueue!(
        request(
          project_id: "beta",
          provider_scope: github_scope(),
          operation_kind: :candidate_scan,
          logical_key: "beta-scan"
        )
      )
      |> enqueue!(
        request(
          project_id: "beta",
          provider_scope: github_scope(),
          operation_kind: :running_reconciliation,
          logical_key: "beta-reconcile"
        )
      )

    assert {:ok, reconcile, queue} = ProviderGovernance.next_request(queue, ~U[2026-06-27 09:00:00Z])
    assert reconcile.project_id == "beta"
    assert reconcile.operation_kind == :running_reconciliation
    assert reconcile.priority == 10
    queue = ProviderGovernance.record_result(queue, ProviderGovernance.result(reconcile, :success))

    assert {:ok, alpha_scan, queue} = ProviderGovernance.next_request(queue, ~U[2026-06-27 09:00:01Z])
    assert alpha_scan.project_id == "alpha"
    queue = ProviderGovernance.record_result(queue, ProviderGovernance.result(alpha_scan, :success))

    assert {:ok, beta_scan, queue} = ProviderGovernance.next_request(queue, ~U[2026-06-27 09:00:02Z])
    assert beta_scan.project_id == "beta"
    queue = ProviderGovernance.record_result(queue, ProviderGovernance.result(beta_scan, :success))

    assert {:ok, alpha_scan_2, queue} = ProviderGovernance.next_request(queue, ~U[2026-06-27 09:00:03Z])
    assert alpha_scan_2.project_id == "alpha"

    summary = ProviderGovernance.queue_summary(queue, ~U[2026-06-27 09:00:04Z])
    assert summary.pending_count == 0
    assert summary.running_count == 1
    assert [%{project_id: "alpha", operation_kind: "candidate_scan"}] = summary.running
  end

  test "reports manual refresh and scope concurrency as observable backpressure" do
    queue = ProviderGovernance.new_queue(max_running_per_scope: 1)

    queue =
      queue
      |> enqueue!(
        request(
          project_id: "alpha",
          provider_scope: github_scope(),
          operation_kind: :manual_refresh,
          user_initiated: true
        )
      )
      |> enqueue!(request(project_id: "beta", provider_scope: github_scope(), operation_kind: :candidate_scan))

    assert {:ok, manual_refresh, queue} = ProviderGovernance.next_request(queue, ~U[2026-06-27 09:00:00Z])
    assert manual_refresh.operation_kind == :manual_refresh
    assert manual_refresh.user_initiated == true

    assert {:blocked, blocked_summary} = ProviderGovernance.next_request(queue, ~U[2026-06-27 09:00:01Z])
    assert [%{reason: :scope_concurrency, provider_scope_key: "github:jhihjian/symphony"}] = blocked_summary.backpressure

    summary = ProviderGovernance.queue_summary(queue, ~U[2026-06-27 09:00:02Z])
    assert [%{operation_kind: "manual_refresh", user_initiated: true}] = summary.running
    assert [%{backpressure: %{reason: :scope_concurrency}}] = summary.pending
  end

  test "scope rate limits, backoff, and circuit state block only matching scopes" do
    queue =
      ProviderGovernance.new_queue()
      |> enqueue!(request(project_id: "alpha", provider_scope: github_scope(), operation_kind: :candidate_scan))
      |> enqueue!(request(project_id: "beta", provider_scope: gitlab_scope(), operation_kind: :candidate_scan))
      |> ProviderGovernance.update_scope_state(github_scope(), %{
        quota: %{remaining: 0, limit: 5_000, reset_at: ~U[2026-06-27 09:05:00Z], authorization: "Bearer secret"},
        backoff_until: ~U[2026-06-27 09:05:00Z],
        circuit_state: :closed,
        last_error_class: :rate_limited
      })

    assert {:ok, gitlab, queue} = ProviderGovernance.next_request(queue, ~U[2026-06-27 09:00:00Z])
    assert gitlab.provider_scope_key == "gitlab:platform/beta"
    queue = ProviderGovernance.record_result(queue, ProviderGovernance.result(gitlab, :success))

    assert {:blocked, blocked_summary} = ProviderGovernance.next_request(queue, ~U[2026-06-27 09:00:01Z])
    assert [%{reason: :rate_limited, provider_scope_key: "github:jhihjian/symphony"}] = blocked_summary.backpressure

    queue =
      ProviderGovernance.update_scope_state(queue, github_scope(), %{
        backoff_until: nil,
        circuit_state: :open,
        last_error_class: :auth_config
      })

    assert {:blocked, circuit_summary} = ProviderGovernance.next_request(queue, ~U[2026-06-27 09:06:00Z])
    assert [%{reason: :circuit_open, error_class: :auth_config}] = circuit_summary.backpressure

    safe_text = inspect(ProviderGovernance.queue_summary(queue, ~U[2026-06-27 09:06:00Z]))
    refute safe_text =~ "Bearer secret"
    refute safe_text =~ "authorization"
  end

  test "classifies provider results and marks unsafe unknown writebacks for manual attention" do
    writeback =
      request(
        project_id: "alpha",
        provider_scope: github_scope(),
        operation_kind: :stage_writeback,
        replay_policy: :unknown_requires_manual_attention
      )

    unknown =
      ProviderGovernance.result(writeback, :unknown_result,
        writeback_intent_key: "alpha:github:jhihjian/symphony:123:writeback:needs-review-comment",
        result_summary: %{message: "timeout after provider accepted request", token: "secret"}
      )

    assert unknown.status == :unknown_result
    assert unknown.manual_attention == true
    assert unknown.replayable == false
    assert unknown.ledger.issue_key == "alpha:github:jhihjian/symphony:123"
    assert unknown.ledger.writeback_intent_key == "alpha:github:jhihjian/symphony:123:writeback:needs-review-comment"

    classifications =
      [
        ProviderGovernance.result(writeback, :success, result_summary: %{external: "comment-1"}),
        ProviderGovernance.result(writeback, :retryable_failure, error_class: :network_timeout, backoff_until: ~U[2026-06-27 09:10:00Z]),
        ProviderGovernance.result(writeback, :permanent_failure, error_class: :validation),
        ProviderGovernance.result(writeback, :rate_limited, retry_after_ms: 60_000),
        ProviderGovernance.result(writeback, :circuit_open, error_class: :auth_config),
        ProviderGovernance.result(writeback, :canceled),
        ProviderGovernance.result(writeback, :timed_out)
      ]

    assert Enum.map(classifications, & &1.status) == [
             :success,
             :retryable_failure,
             :permanent_failure,
             :rate_limited,
             :circuit_open,
             :canceled,
             :timed_out
           ]

    safe_text = inspect(ProviderGovernance.result_summary(unknown))
    refute safe_text =~ "secret"
    refute safe_text =~ "token"
  end

  test "queue summaries and recent results keep provider secrets out" do
    request =
      request(
        project_id: "alpha",
        provider_scope: github_scope(),
        operation_kind: :comment_workpad_upsert,
        replay_policy: :marker_upsert,
        correlation: %{trace_id: "trace", api_key: "$GITHUB_TOKEN", credential: "secret"}
      )

    queue =
      ProviderGovernance.new_queue()
      |> enqueue!(request)

    assert {:ok, started, queue} = ProviderGovernance.next_request(queue, ~U[2026-06-27 09:00:00Z])

    result =
      ProviderGovernance.result(started, :success,
        result_summary: %{comment_id: "123", cookie: "session=secret", transcript: "full Codex transcript"},
        external_ref: "https://github.com/JhihJian/symphony/issues/79#issuecomment-1"
      )

    summary =
      queue
      |> ProviderGovernance.record_result(result)
      |> ProviderGovernance.queue_summary(~U[2026-06-27 09:00:01Z])

    assert [%{status: :success, result_summary: %{comment_id: "123"}}] = summary.recent_results

    safe_text = inspect(summary)
    refute safe_text =~ "$GITHUB_TOKEN"
    refute safe_text =~ "session=secret"
    refute safe_text =~ "api_key"
    refute safe_text =~ "credential"
    refute safe_text =~ "cookie"
    refute safe_text =~ "full Codex transcript"
  end

  defp enqueue!(queue, request) do
    assert {:ok, queue} = ProviderGovernance.enqueue(queue, request)
    queue
  end

  defp request(overrides) do
    defaults = %{
      project_id: "alpha",
      config_fingerprint: "fingerprint",
      snapshot_version: "hub-registry:alpha:1",
      provider_scope: github_scope(),
      issue_ref: issue_ref("alpha", "github", "github:jhihjian/symphony", "123", "jhihjian/symphony#79"),
      operation_kind: :candidate_scan,
      logical_key: "default"
    }

    assert {:ok, request} = ProviderGovernance.new_request(Map.merge(defaults, Map.new(overrides)))
    request
  end

  defp github_scope do
    %{kind: "github", key: "github:jhihjian/symphony", scope: %{owner: "JhihJian", repo: "symphony", project_number: 3}}
  end

  defp gitlab_scope do
    %{kind: "gitlab", key: "gitlab:platform/beta", scope: %{project_slug: "platform/beta"}}
  end

  defp issue_ref(project_id, tracker_kind, provider_scope_key, provider_issue_id, identifier) do
    %IssueRef{
      project_id: project_id,
      tracker_kind: tracker_kind,
      provider_scope: provider_scope(tracker_kind, provider_scope_key),
      provider_scope_key: provider_scope_key,
      provider_issue_id: provider_issue_id,
      provider_local_id: identifier,
      identifier: identifier,
      url: "https://example.test/#{provider_issue_id}"
    }
  end

  defp provider_scope("github", "github:" <> owner_repo) do
    [owner, repo] = String.split(owner_repo, "/", parts: 2)
    %{owner: owner, repo: repo}
  end

  defp provider_scope("gitlab", "gitlab:" <> project_slug), do: %{project_slug: project_slug}
end
