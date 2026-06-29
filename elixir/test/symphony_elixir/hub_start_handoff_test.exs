defmodule SymphonyElixir.HubStartHandoffTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{DispatchBoundary, IssueRef, RuntimeLedger, WorkerStartHandoff}

  @now ~U[2026-06-29 09:00:00Z]

  test "acknowledges a pending start intent and links the running attempt in replay" do
    assert {:ok, ledger, context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)

    starter = fn request, _opts ->
      assert request.project_id == "alpha"
      assert request.provider_scope_key == "github:jhihjian/symphony"
      assert request.issue_ref.provider_issue_id == "123"
      assert request.attempt_id == context.attempt_id
      assert request.start_intent_id == context.start_intent_id
      assert request.workspace_lease_id == context.workspace_lease_id
      assert request.source_poll.request_id == "provider-request-alpha"
      assert request.source_intake.candidate_key == context.issue_key
      assert request.planning.intent_id == context.start_intent_id
      assert request.start_command_summary.starts_agent in [false, "false"]

      %{
        status: :ack,
        reason: :starter_acknowledged,
        session_id: "session-alpha",
        worker_host: "worker-ack",
        usage: %{input_tokens: 12, authorization: "Bearer should-not-leak"}
      }
    end

    assert {acked_ledger, handoff} = WorkerStartHandoff.run(registry(), ledger, now: @now, starter: starter)

    assert handoff.counts.selected_count == 1
    assert handoff.counts.acked_count == 1
    assert handoff.counts.unresolved_start_intent_count == 0
    assert handoff.reason_counts == %{"starter_acknowledged" => 1}
    assert [%{status: "ack", request: request}] = handoff.results
    assert request.project_id == "alpha"
    assert request.source_poll.request_id == "provider-request-alpha"
    assert handoff.pending_start_intents == []

    [project] = RuntimeLedger.replay(acked_ledger).projects
    assert project.counts.running == 1
    assert project.pending_start_intents == []

    assert [
             %{status: :running, start_intent_id: start_intent_id, start_intent_status: :acknowledged}
           ] = project.active_attempts

    assert start_intent_id == context.start_intent_id
    assert [%{status: :running, start_intent_status: :acknowledged}] = project.active_issues

    safe_text = inspect({acked_ledger, handoff})
    refute safe_text =~ "Bearer"
    refute safe_text =~ "authorization"
  end

  test "records start failure as retry backoff with observable reason" do
    assert {:ok, ledger, context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)

    starter = fn _request, _opts ->
      %{
        status: "failed",
        failure_status: "retry_queued",
        reason: "worker_capacity_missing",
        error_summary: "worker unavailable",
        due_at: "2026-06-29T09:05:00Z"
      }
    end

    assert {failed_ledger, handoff} = WorkerStartHandoff.run(registry(), ledger, now: @now, starter: starter)

    assert handoff.counts.failed_count == 1
    assert handoff.reason_counts == %{"worker_capacity_missing" => 1}
    assert [%{status: "failed", failure_status: "retry_queued", error_summary: "worker unavailable"}] = handoff.results

    [project] = RuntimeLedger.replay(failed_ledger).projects
    assert project.counts.retry == 1
    assert project.pending_start_intents == []
    assert [%{attempt_id: attempt_id, due_at: "2026-06-29T09:05:00Z", error_summary: "worker unavailable"}] = project.retry_backoff
    assert attempt_id == context.attempt_id
    assert project.workspace_leases == []
  end

  test "records manual attention while preserving unresolved start intent" do
    assert {:ok, ledger, _context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)

    starter = fn _request, _opts ->
      %{
        status: :manual_attention,
        reason: :requires_operator_check,
        error_summary: "ack ambiguous"
      }
    end

    assert {manual_ledger, handoff} = WorkerStartHandoff.run(registry(), ledger, now: @now, starter: starter)

    assert handoff.counts.manual_attention_count == 1
    assert handoff.counts.unresolved_start_intent_count == 1
    assert handoff.reason_counts == %{"requires_operator_check" => 1}
    assert [%{status: "manual_attention"}] = handoff.results
    assert [%{status: "unknown", manual_attention: true}] = handoff.unresolved_start_intents

    [project] = RuntimeLedger.replay(manual_ledger).projects
    assert project.counts.manual_attention == 1
    assert [%{status: :unknown, manual_attention: true}] = project.pending_start_intents
    assert [%{code: :start_intent_unknown_manual_attention}] = project.manual_attention
    assert length(project.workspace_leases) == 1
  end

  test "unknown result remains unresolved and repeat handoff does not call starter again" do
    parent = self()
    assert {:ok, ledger, context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)

    unknown_starter = fn _request, _opts ->
      send(parent, :starter_called)
      %{status: "unknown", reason: "lost_ack", error_summary: "ack result lost"}
    end

    assert {unknown_ledger, first_handoff} = WorkerStartHandoff.run(registry(), ledger, now: @now, starter: unknown_starter)
    assert_receive :starter_called

    assert first_handoff.counts.unknown_count == 1
    assert first_handoff.counts.unresolved_start_intent_count == 1
    assert [%{status: "unknown", reason: "lost_ack"}] = first_handoff.results

    [first_project] = RuntimeLedger.replay(unknown_ledger).projects
    assert [%{status: :unknown, intent_id: intent_id}] = first_project.pending_start_intents
    assert intent_id == context.start_intent_id
    assert length(first_project.active_attempts) == 1
    assert length(first_project.workspace_leases) == 1

    fail_if_called = fn _request, _opts ->
      flunk("starter must not be called for an unresolved unknown start intent")
    end

    assert {repeat_ledger, repeat_handoff} = WorkerStartHandoff.run(registry(), unknown_ledger, now: DateTime.add(@now, 60, :second), starter: fail_if_called)
    assert repeat_ledger == unknown_ledger
    assert repeat_handoff.counts.selected_count == 1
    assert repeat_handoff.counts.skipped_count == 1
    assert repeat_handoff.reason_counts == %{"start_intent_unresolved" => 1}

    [repeat_project] = RuntimeLedger.replay(repeat_ledger).projects
    assert length(repeat_project.active_attempts) == 1
    assert length(repeat_project.workspace_leases) == 1
    assert [%{intent_id: ^intent_id, status: :unknown}] = repeat_project.pending_start_intents
  end

  test "already acknowledged ledgers are idempotent and report no selected start intents" do
    assert {:ok, ledger, _context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)

    ack_starter = fn _request, _opts ->
      %{status: "ack", reason: "worker_ack", session_id: "session-alpha"}
    end

    assert {acked_ledger, first_handoff} = WorkerStartHandoff.run(registry(), ledger, now: @now, starter: ack_starter)
    assert first_handoff.counts.acked_count == 1

    fail_if_called = fn _request, _opts ->
      flunk("starter must not be called after start intent is acknowledged")
    end

    assert {same_ledger, second_handoff} = WorkerStartHandoff.run(registry(), acked_ledger, now: DateTime.add(@now, 60, :second), starter: fail_if_called)
    assert same_ledger == acked_ledger
    assert second_handoff.counts.selected_count == 0
    assert second_handoff.counts.already_acked_count == 0
    assert second_handoff.pending_start_intents == []
  end

  test "handoff summaries redact secrets, raw provider config, prompts, transcripts and bodies" do
    unsafe =
      candidate(
        runtime_identity: %{
          boundary: "hub_dispatch_plan_application",
          source_poll: %{request_id: "provider-request-alpha", raw_provider_config: %{token: "ghp_should_not_leak"}},
          source_intake: %{candidate_key: "alpha:github:jhihjian/symphony:123", comment_body: "complete comment body"},
          planning: %{intent_id: "planning-intent", transcript: "complete transcript"}
        },
        start_command_summary: %{
          runner: "codex",
          argv: ["codex", "exec"],
          secret_env: ["GITHUB_TOKEN"],
          prompt: "full prompt should not leak",
          pull_request_body: "full pr body should not leak"
        }
      )

    assert {:ok, ledger, _context} = DispatchBoundary.dispatch(RuntimeLedger.new(), unsafe, now: @now)

    starter = fn _request, _opts ->
      %{
        status: :ack,
        reason: :safe_ack,
        session_id: "session-alpha",
        token: "ghp_starter_secret",
        cookie: "session=secret",
        comment_body: "starter comment body"
      }
    end

    assert {_ledger, handoff} = WorkerStartHandoff.run(registry(), ledger, now: @now, starter: starter)
    safe_text = inspect(handoff)

    refute safe_text =~ "ghp_should_not_leak"
    refute safe_text =~ "ghp_starter_secret"
    refute safe_text =~ "session=secret"
    refute safe_text =~ "GITHUB_TOKEN"
    refute safe_text =~ "complete comment body"
    refute safe_text =~ "complete transcript"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "full pr body"
    refute safe_text =~ "raw_provider_config"
    refute safe_text =~ "secret_env"
    refute safe_text =~ "prompt"
    refute safe_text =~ "transcript"
    refute safe_text =~ "comment_body"
    refute safe_text =~ "pull_request_body"
  end

  defp registry do
    %{
      projects: [
        %{
          project_id: "alpha",
          name: "Alpha",
          dispatch_enabled: true,
          paused: false,
          status: :ready,
          workflow_summary: %{
            start_stage: "ready",
            terminal_stages: ["done", "blocked"],
            stage_ids: ["ready", "in_progress", "done", "blocked"]
          },
          tracker_summary: %{
            kind: "github",
            provider_scope: %{owner: "jhihjian", repo: "symphony"},
            provider_scope_key: "github:jhihjian/symphony"
          },
          runtime_summary: %{
            workspace_root: "/workspaces/alpha",
            max_concurrent_agents: 5,
            max_concurrent_agents_by_state: %{},
            polling_interval_ms: 30_000,
            server_port: nil
          },
          fingerprint: "alpha-fingerprint",
          snapshot_version: "hub-project:alpha:1",
          loaded_at: @now
        }
      ],
      warnings: [],
      errors: []
    }
  end

  defp candidate(overrides \\ []) do
    ref = Keyword.get(overrides, :issue_ref, issue_ref("alpha", "123", "jhihjian/symphony#123"))
    issue_key = RuntimeLedger.issue_key(ref)
    attempt_id = "attempt-alpha-123"
    start_intent_id = "start-intent-alpha-123"

    %{
      project_id: "alpha",
      config_fingerprint: "alpha-fingerprint",
      snapshot_version: "hub-project:alpha:1",
      issue_ref: ref,
      workflow: %{start_stage: "ready", terminal_stages: ["done", "blocked"], stage_ids: ["ready", "in_progress", "done", "blocked"]},
      tracker: %{kind: "github", provider_scope_key: "github:jhihjian/symphony", required_labels: ["symphony"]},
      current_stage: "ready",
      trigger_source: :poll_plan,
      governance: %{request: %{request_id: "poll-request-1"}, decision: :selected},
      correlation_id: "correlation-alpha-123",
      attempt_id: attempt_id,
      start_intent_id: start_intent_id,
      workspace_path: "/workspaces/alpha/123",
      worker_host: "worker-1",
      runtime_identity: %{
        boundary: "hub_dispatch_plan_application",
        model_only: true,
        source_poll: %{
          request_id: "provider-request-alpha",
          logical_key: "hub-poll:alpha:candidate_scan",
          poll_attempt_id: "poll-attempt-alpha",
          poll_result_status: "success"
        },
        source_intake: %{candidate_key: issue_key, candidate_id: "candidate-alpha-123"},
        planning: %{intent_id: start_intent_id, candidate_key: issue_key}
      },
      runner: "codex",
      start_command_summary: %{
        runner: "codex",
        starts_agent: false,
        creates_workspace: false,
        writes_provider: false,
        planning: %{intent_id: start_intent_id},
        source_intake: %{candidate_key: issue_key}
      }
    }
    |> Map.merge(Map.new(overrides))
  end

  defp issue_ref(project_id, provider_issue_id, identifier) do
    %IssueRef{
      project_id: project_id,
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
