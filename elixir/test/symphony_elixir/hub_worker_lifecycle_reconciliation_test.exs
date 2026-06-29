defmodule SymphonyElixir.HubWorkerLifecycleReconciliationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{DispatchBoundary, IssueRef, RuntimeLedger, WorkerLifecycleReconciliation}

  @now ~U[2026-06-29 10:00:00Z]

  test "applies succeeded lifecycle result and releases active attempt workspace" do
    assert {:ok, ledger, context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)
    assert {:ok, ledger} = DispatchBoundary.acknowledge_start(ledger, ack(context), now: @now)

    result_source = fn [request], _opts ->
      assert request.attempt_id == context.attempt_id
      assert request.start_intent_id == context.start_intent_id
      assert request.workspace_lease_id == context.workspace_lease_id

      [
        %{
          status: :completed,
          reason: :stage_outcome_needs_review,
          project_id: request.project_id,
          issue_key: request.issue_key,
          attempt_id: request.attempt_id,
          start_intent_id: request.start_intent_id,
          workspace_lease_id: request.workspace_lease_id,
          workspace_path: request.workspace_path,
          session_id: "session-alpha",
          worker_host: "worker-1",
          finished_at: "2026-06-29T10:08:00Z",
          source: :test_supervisor,
          source_correlation: %{event_id: "event-succeeded"}
        }
      ]
    end

    assert {reconciled_ledger, summary} =
             WorkerLifecycleReconciliation.run(registry(), ledger,
               now: DateTime.add(@now, 8, :minute),
               result_source: result_source
             )

    assert summary.counts.selected_count == 1
    assert summary.counts.applied_count == 1
    assert summary.counts.succeeded_count == 1
    assert summary.counts.released_workspace_count == 1
    assert summary.reason_counts == %{"stage_outcome_needs_review" => 1}
    assert [%{status: "succeeded", workspace_action: "released", ledger_changed: true}] = summary.results

    [project] = RuntimeLedger.replay(reconciled_ledger).projects
    assert project.counts.released == 1
    assert project.active_attempts == []
    assert project.workspace_leases == []
    assert project.lifecycle.counts.succeeded == 1
    assert project.lifecycle.workspace_action_counts == %{"released" => 1}
    assert [%{status: :succeeded, workspace_action: "released"}] = project.lifecycle.terminal
    assert RuntimeLedger.validate(reconciled_ledger) == :ok
  end

  test "failed cancelled and timeout lifecycle results converge to recoverable ledger states" do
    {:ok, failed_ledger, failed_context} =
      RuntimeLedger.new()
      |> DispatchBoundary.dispatch(
        candidate(
          issue_id: "124",
          identifier: "jhihjian/symphony#124",
          attempt_id: "attempt-failed",
          start_intent_id: "intent-failed"
        ),
        now: @now
      )

    {:ok, failed_ledger} =
      DispatchBoundary.acknowledge_start(failed_ledger, ack(failed_context, session_id: "session-failed"), now: @now)

    assert {retry_ledger, failed_summary} =
             WorkerLifecycleReconciliation.run(registry(), failed_ledger,
               now: @now,
               result_source: fn [request], _opts ->
                 [
                   %{
                     status: :failed,
                     recovery_status: :retry_queued,
                     reason: :worker_runtime_error,
                     project_id: request.project_id,
                     issue_key: request.issue_key,
                     attempt_id: request.attempt_id,
                     start_intent_id: request.start_intent_id,
                     session_id: "session-failed",
                     due_at: "2026-06-29T10:15:00Z"
                   }
                 ]
               end
             )

    assert failed_summary.counts.failed_count == 1
    assert [%{reason: "worker_runtime_error", workspace_action: "released"}] = failed_summary.results
    [retry_project] = RuntimeLedger.replay(retry_ledger).projects
    assert retry_project.counts.retry == 1
    assert [%{attempt_id: "attempt-failed", due_at: "2026-06-29T10:15:00Z"}] = retry_project.retry_backoff
    assert retry_project.workspace_leases == []

    {:ok, cancelled_ledger, cancelled_context} =
      RuntimeLedger.new()
      |> DispatchBoundary.dispatch(
        candidate(
          issue_id: "125",
          identifier: "jhihjian/symphony#125",
          attempt_id: "attempt-cancelled",
          start_intent_id: "intent-cancelled"
        ),
        now: @now
      )

    {:ok, cancelled_ledger} =
      DispatchBoundary.acknowledge_start(
        cancelled_ledger,
        ack(cancelled_context, session_id: "session-cancelled"),
        now: @now
      )

    assert {released_ledger, cancelled_summary} =
             WorkerLifecycleReconciliation.run(registry(), cancelled_ledger,
               now: @now,
               result_source: one_result(:cancelled, :released, "operator_cancelled", "session-cancelled")
             )

    assert cancelled_summary.counts.cancelled_count == 1
    [released_project] = RuntimeLedger.replay(released_ledger).projects
    assert released_project.counts.released == 1
    assert released_project.active_attempts == []

    {:ok, timeout_ledger, timeout_context} =
      RuntimeLedger.new()
      |> DispatchBoundary.dispatch(
        candidate(
          issue_id: "126",
          identifier: "jhihjian/symphony#126",
          attempt_id: "attempt-timeout",
          start_intent_id: "intent-timeout"
        ),
        now: @now
      )

    {:ok, timeout_ledger} =
      DispatchBoundary.acknowledge_start(timeout_ledger, ack(timeout_context, session_id: "session-timeout"), now: @now)

    assert {blocked_ledger, timeout_summary} =
             WorkerLifecycleReconciliation.run(registry(), timeout_ledger,
               now: @now,
               result_source: one_result(:timeout, :blocked, "worker_timeout", "session-timeout")
             )

    assert timeout_summary.counts.timeout_count == 1
    [blocked_project] = RuntimeLedger.replay(blocked_ledger).projects
    assert blocked_project.counts.blocked == 1
    assert [%{terminal_reason: "worker_timeout"}] = blocked_project.blocked_candidates
  end

  test "lost unknown and manual attention retain active attempt and remain idempotent" do
    assert {:ok, ledger, context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)
    assert {:ok, ledger} = DispatchBoundary.acknowledge_start(ledger, ack(context), now: @now)

    unknown_result = fn [request], _opts ->
      [
        %{
          status: :lost,
          reason: :heartbeat_lost,
          project_id: request.project_id,
          issue_key: request.issue_key,
          attempt_id: request.attempt_id,
          start_intent_id: request.start_intent_id,
          workspace_lease_id: request.workspace_lease_id,
          workspace_path: request.workspace_path,
          session_id: "session-alpha",
          last_activity_at: "2026-06-29T10:01:00Z",
          workspace_retained_reason: :heartbeat_lost
        }
      ]
    end

    assert {unknown_ledger, first_summary} =
             WorkerLifecycleReconciliation.run(registry(), ledger,
               now: DateTime.add(@now, 2, :minute),
               result_source: unknown_result
             )

    assert first_summary.counts.lost_count == 1
    assert first_summary.counts.unresolved_count == 1
    assert first_summary.counts.retained_workspace_count == 1

    [first_project] = RuntimeLedger.replay(unknown_ledger).projects
    assert first_project.counts.manual_attention == 1
    assert length(first_project.active_attempts) == 1
    assert length(first_project.workspace_leases) == 1
    assert [%{status: :lost, workspace_action: "retained"}] = first_project.lifecycle.unresolved
    assert Enum.any?(first_project.manual_attention, &(&1.code == :worker_lifecycle_unresolved_manual_attention))

    assert {repeat_ledger, repeat_summary} =
             WorkerLifecycleReconciliation.run(registry(), unknown_ledger,
               now: DateTime.add(@now, 3, :minute),
               result_source: unknown_result
             )

    assert repeat_ledger == unknown_ledger
    assert repeat_summary.counts.lost_count == 1
    assert repeat_summary.counts.applied_count == 0
    assert RuntimeLedger.validate(repeat_ledger) == :ok
  end

  test "duplicate terminal late old-session and workspace-mismatch results do not corrupt current ledger" do
    assert {:ok, ledger, context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)
    assert {:ok, ledger} = DispatchBoundary.acknowledge_start(ledger, ack(context), now: @now)

    assert {succeeded_ledger, _summary} =
             WorkerLifecycleReconciliation.run(registry(), ledger,
               now: @now,
               result_source: one_result(:succeeded, :released, "completed", "session-alpha")
             )

    assert {duplicate_ledger, duplicate_summary} =
             WorkerLifecycleReconciliation.run(registry(), succeeded_ledger,
               now: DateTime.add(@now, 1, :minute),
               result_source: fn _requests, _opts ->
                 [
                   %{
                     status: :succeeded,
                     recovery_status: :released,
                     reason: :completed,
                     project_id: "alpha",
                     issue_key: context.issue_key,
                     attempt_id: context.attempt_id,
                     start_intent_id: context.start_intent_id,
                     session_id: "session-alpha",
                     finished_at: "2026-06-29T10:10:00Z"
                   }
                 ]
               end
             )

    assert duplicate_ledger == succeeded_ledger
    assert [%{status: "succeeded", ledger_changed: false}] = duplicate_summary.results

    assert {late_ledger, late_summary} =
             WorkerLifecycleReconciliation.run(registry(), succeeded_ledger,
               now: DateTime.add(@now, 2, :minute),
               result_source: fn _requests, _opts ->
                 [
                   %{
                     status: :failed,
                     reason: :late_failure,
                     project_id: "alpha",
                     issue_key: context.issue_key,
                     attempt_id: context.attempt_id,
                     start_intent_id: context.start_intent_id,
                     session_id: "session-alpha"
                   }
                 ]
               end
             )

    assert late_ledger == succeeded_ledger
    assert [%{status: "skipped", reason: "ledger_apply_error"}] = late_summary.results

    assert {:ok, active_ledger, active_context} =
             DispatchBoundary.dispatch(
               RuntimeLedger.new(),
               candidate(
                 issue_id: "127",
                 identifier: "jhihjian/symphony#127",
                 attempt_id: "attempt-active",
                 start_intent_id: "intent-active"
               ),
               now: @now
             )

    assert {:ok, active_ledger} =
             DispatchBoundary.acknowledge_start(active_ledger, ack(active_context, session_id: "session-current"), now: @now)

    assert {same_ledger, mismatch_summary} =
             WorkerLifecycleReconciliation.run(registry(), active_ledger,
               now: @now,
               result_source: fn [request], _opts ->
                 [
                   %{
                     status: :succeeded,
                     reason: :wrong_session,
                     project_id: request.project_id,
                     issue_key: request.issue_key,
                     attempt_id: request.attempt_id,
                     start_intent_id: request.start_intent_id,
                     session_id: "session-old"
                   },
                   %{
                     status: :succeeded,
                     reason: :wrong_workspace,
                     project_id: request.project_id,
                     issue_key: request.issue_key,
                     attempt_id: request.attempt_id,
                     start_intent_id: request.start_intent_id,
                     session_id: "session-current",
                     workspace_lease_id: "wrong-lease",
                     workspace_path: "/workspaces/wrong"
                   }
                 ]
               end
             )

    assert same_ledger == active_ledger
    assert Enum.all?(mismatch_summary.results, &(&1.status == "skipped"))
    [active_project] = RuntimeLedger.replay(same_ledger).projects
    assert length(active_project.active_attempts) == 1
    assert length(active_project.workspace_leases) == 1
  end

  test "summaries redact lifecycle secrets and raw bodies" do
    assert {:ok, ledger, context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)
    assert {:ok, ledger} = DispatchBoundary.acknowledge_start(ledger, ack(context), now: @now)

    assert {_ledger, summary} =
             WorkerLifecycleReconciliation.run(registry(), ledger,
               now: @now,
               result_source: fn [request], _opts ->
                 [
                   %{
                     status: :succeeded,
                     reason: :done,
                     project_id: request.project_id,
                     issue_key: request.issue_key,
                     attempt_id: request.attempt_id,
                     start_intent_id: request.start_intent_id,
                     session_id: "session-alpha",
                     token: "ghp_should_not_leak",
                     authorization: "Bearer secret",
                     cookie: "session=secret",
                     secret_env: ["GITHUB_TOKEN"],
                     raw_config: %{api_key: "sk-secret"},
                     full_prompt: "full prompt should not leak",
                     transcript: "complete transcript should not leak",
                     comment_body: "complete comment body should not leak",
                     pull_request_body: "complete pr body should not leak",
                     raw_output: "raw hook output should not leak",
                     worker_identity: %{pid: "123", raw_output: "raw output should not leak"}
                   }
                 ]
               end
             )

    safe_text = inspect(summary)
    refute safe_text =~ "ghp_should_not_leak"
    refute safe_text =~ "Bearer secret"
    refute safe_text =~ "session=secret"
    refute safe_text =~ "GITHUB_TOKEN"
    refute safe_text =~ "sk-secret"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "complete transcript"
    refute safe_text =~ "complete comment body"
    refute safe_text =~ "complete pr body"
    refute safe_text =~ "raw hook output"
    refute safe_text =~ "raw_output"
    refute safe_text =~ "authorization"
    refute safe_text =~ "cookie"
  end

  defp one_result(status, recovery_status, reason, session_id) do
    fn [request], _opts ->
      [
        %{
          status: status,
          recovery_status: recovery_status,
          reason: reason,
          project_id: request.project_id,
          issue_key: request.issue_key,
          attempt_id: request.attempt_id,
          start_intent_id: request.start_intent_id,
          workspace_lease_id: request.workspace_lease_id,
          workspace_path: request.workspace_path,
          session_id: session_id,
          finished_at: "2026-06-29T10:10:00Z"
        }
      ]
    end
  end

  defp registry do
    %{
      projects: [
        %{
          project_id: "alpha",
          name: "Alpha",
          status: :ready,
          dispatch_enabled: true,
          paused: false,
          tracker_summary: %{kind: "github", provider_scope_key: "github:jhihjian/symphony"},
          runtime_summary: %{workspace_root: "/workspaces/alpha", max_concurrent_agents: 5}
        }
      ],
      warnings: [],
      errors: []
    }
  end

  defp candidate(overrides \\ []) do
    issue_id = Keyword.get(overrides, :issue_id, "123")
    identifier = Keyword.get(overrides, :identifier, "jhihjian/symphony#123")
    ref = issue_ref(issue_id, identifier)
    issue_key = RuntimeLedger.issue_key(ref)
    attempt_id = Keyword.get(overrides, :attempt_id, "attempt-alpha-123")
    start_intent_id = Keyword.get(overrides, :start_intent_id, "start-intent-alpha-123")

    %{
      project_id: "alpha",
      config_fingerprint: "alpha-fingerprint",
      snapshot_version: "hub-project:alpha:1",
      issue_ref: ref,
      workflow: %{start_stage: "ready", terminal_stages: ["done", "blocked"], stage_ids: ["ready", "in_progress", "done", "blocked"]},
      tracker: %{kind: "github", provider_scope_key: "github:jhihjian/symphony"},
      current_stage: "ready",
      trigger_source: :poll_plan,
      correlation_id: "correlation-#{issue_id}",
      attempt_id: attempt_id,
      start_intent_id: start_intent_id,
      workspace_path: "/workspaces/alpha/#{issue_id}",
      worker_host: "worker-1",
      runtime_identity: %{planning: %{intent_id: start_intent_id, candidate_key: issue_key}},
      runner: "codex",
      start_command_summary: %{runner: "codex", starts_agent: false}
    }
    |> Map.merge(Map.new(Keyword.drop(overrides, [:issue_id, :identifier])))
  end

  defp ack(context, overrides \\ []) do
    %{
      project_id: context.project_id,
      issue_key: context.issue_key,
      attempt_id: context.attempt_id,
      start_intent_id: context.start_intent_id,
      session_id: Keyword.get(overrides, :session_id, "session-alpha"),
      worker_host: "worker-1",
      workspace_path: context.workspace_path,
      workspace_lease_id: context.workspace_lease_id,
      acked_at: DateTime.add(@now, 1, :second),
      started_at: @now,
      last_activity_at: @now
    }
  end

  defp issue_ref(provider_issue_id, identifier) do
    %IssueRef{
      project_id: "alpha",
      tracker_kind: "github",
      provider_scope: %{owner: "jhihjian", repo: "symphony"},
      provider_scope_key: "github:jhihjian/symphony",
      provider_issue_id: provider_issue_id,
      provider_local_id: identifier,
      identifier: identifier,
      url: "https://example.test/#{provider_issue_id}"
    }
  end
end
