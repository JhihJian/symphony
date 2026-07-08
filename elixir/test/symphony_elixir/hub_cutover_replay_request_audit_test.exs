defmodule SymphonyElixir.HubCutoverReplayRequestAuditTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{
    CutoverAuthorizationConsumptionGuard,
    CutoverExecutionAuthorization,
    CutoverExecutionOutcomeCloseout,
    CutoverExecutionOutcomeLedger,
    CutoverReadinessPermit,
    CutoverReplayDecision,
    CutoverReplayRequestAudit
  }

  @now ~U[2026-07-01 09:00:00Z]

  test "reports no_request without implying pending execution" do
    summary = CutoverReplayRequestAudit.build(%{projects: [%{project_id: "alpha"}]}, now: @now)

    assert summary.status == "no_request"
    assert summary.counts.request_count == 0
    assert summary.counts.no_request_count == 1
    assert summary.no_side_effects == true
    assert summary.auto_replay_allowed == false
  end

  test "allows explicit retry consideration only when replay request binds current safe evidence" do
    context = replay_context()
    request = replay_request(context)

    summary =
      CutoverReplayRequestAudit.build(
        Map.merge(context.sources, %{replay_requests: [request]}),
        now: @now
      )

    [record] = summary.recent_requests

    assert summary.status == "would_allow_retry_consideration"
    assert summary.counts.allow_count == 1
    assert record.status == "would_allow_retry_consideration"
    assert record.project_id == "alpha"
    assert record.operation == "writeback"
    assert record.side_effect_source == "writeback_executor"
    assert record.replay_key == context.outcome.replay_key
    assert record.outcome_fingerprint == context.outcome.evidence_fingerprint
    assert record.matching_closeout.closeout_record_fingerprint == context.closeout.closeout_record_fingerprint
    assert record.replay_decision.decision == "retry_consideration_allowed"
    assert record.readiness_permit.permit_fingerprint == context.outcome.readiness_permit_fingerprint

    assert record.authorization_record.authorization_record_fingerprint ==
             context.outcome.authorization_record_fingerprint

    assert record.consumption_guard.decision_fingerprint == context.outcome.safe_evidence_fingerprints.consumption_guard
    assert record.outcome_link_status == "not_linked"
    assert record.no_side_effects == true
    assert record.auto_replay_allowed == false

    safe_text = inspect(summary, limit: :infinity, printable_limit: :infinity)
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "raw_provider_response"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "/home/jhihjian/private"
  end

  test "blocks or marks stale/conflict when request evidence drifts" do
    context = replay_context()

    stale =
      context
      |> replay_request()
      |> Map.put(:cutover_operation_request_fingerprint, "request-alpha-new")
      |> audit_one(context)

    assert stale.status == "stale"
    assert "outcome_cutover_operation_request_fingerprint_mismatch" in stale.status_reasons

    conflict =
      context
      |> replay_request()
      |> Map.put(:outcome_side_effect, %{entered: true, may_have_happened: false})
      |> audit_one(context)

    assert conflict.status == "conflict"
    assert "side_effect_safety_conflict" in conflict.status_reasons

    blocked =
      context
      |> replay_request()
      |> Map.put(:closeout_record_fingerprint, "missing-closeout")
      |> audit_one(context)

    assert blocked.status in ["would_block", "stale"]
    refute blocked.status == "would_allow_retry_consideration"
  end

  test "links later outcome by replay request fingerprint without treating request as side effect success" do
    context = replay_context()
    request = replay_request(context)
    request = CutoverReplayRequestAudit.request_snapshot(request)

    linked_outcome =
      CutoverExecutionOutcomeLedger.fact_snapshot(%{
        project_id: "alpha",
        provider_scope: provider_scope("alpha"),
        operation: "writeback",
        side_effect_source: "writeback_executor",
        status: "succeeded",
        reason_code: "execution_succeeded",
        authorization_consumption_guard: allowed_guard(),
        replay_request_fingerprint: request.request_fingerprint,
        replay_request_audit_fingerprint: "audit-record-alpha",
        executor_result: %{provider_io: true, status: "success"},
        side_effect_entered: true,
        side_effect_may_have_happened: true,
        started_at: @now,
        completed_at: @now
      })

    ledger =
      CutoverExecutionOutcomeLedger.build(
        %{events: [context.outcome, linked_outcome]},
        now: @now
      )

    summary =
      CutoverReplayRequestAudit.build(
        context.sources
        |> Map.put(:cutover_execution_outcome_ledger, ledger)
        |> Map.put(:replay_requests, [request]),
        now: @now
      )

    [record] = summary.recent_requests

    assert record.status == "would_allow_retry_consideration"
    assert record.outcome_link_status == "outcome_recorded"
    assert record.linked_outcome.status == "succeeded"
    assert record.linked_outcome.replay_request_fingerprint == request.request_fingerprint
    assert summary.counts.linked_outcome_recorded_count == 1
    assert summary.auto_replay_allowed == false
  end

  defp audit_one(request, context) do
    summary =
      CutoverReplayRequestAudit.build(
        Map.merge(context.sources, %{replay_requests: [request]}),
        now: @now
      )

    [record] = summary.recent_requests
    record
  end

  defp replay_context do
    outcome = outcome_candidate(status: "unknown")
    ledger = CutoverExecutionOutcomeLedger.build(%{events: [outcome]}, now: @now)

    closeout_summary =
      CutoverExecutionOutcomeCloseout.build(
        %{
          cutover_execution_outcome_ledger: ledger,
          execution_outcome_closeouts: [closeout_from_outcome(outcome)]
        },
        now: @now
      )

    [closeout] = closeout_summary.projects |> hd() |> Map.fetch!(:closeouts)

    replay_decision =
      CutoverReplayDecision.evaluate(%{
        candidate: outcome,
        authorization_consumption_guard: allowed_guard(),
        cutover_execution_outcome_ledger: ledger,
        cutover_execution_outcome_closeout: closeout_summary
      })

    replay_decision_summary = CutoverReplayDecision.build(%{events: [replay_decision]}, now: @now)
    readiness_permit = readiness_permit_summary(outcome)
    authorization_ledger = authorization_ledger_summary(outcome)
    guard_summary = CutoverAuthorizationConsumptionGuard.build(%{events: [allowed_guard()]}, now: @now)

    %{
      outcome: outcome,
      closeout: closeout,
      replay_decision: replay_decision,
      replay_decision_fingerprint: replay_decision_fingerprint(replay_decision),
      sources: %{
        projects: [%{project_id: "alpha"}],
        cutover_execution_outcome_ledger: ledger,
        cutover_execution_outcome_closeout: closeout_summary,
        cutover_replay_decision: replay_decision_summary,
        cutover_readiness_permit: readiness_permit,
        cutover_execution_authorization_ledger: authorization_ledger,
        cutover_authorization_consumption_guard: guard_summary
      }
    }
  end

  defp replay_request(context) do
    outcome = context.outcome
    closeout = context.closeout

    %{
      request_id: "replay-request-alpha-writeback",
      project_id: outcome.project_id,
      provider_scope: outcome.provider_scope,
      operation: outcome.operation,
      side_effect_source: outcome.side_effect_source,
      replay_key: outcome.replay_key,
      outcome_fingerprint: outcome.evidence_fingerprint,
      outcome_status: outcome.status,
      outcome_side_effect: %{
        entered: outcome.side_effect_entered,
        may_have_happened: outcome.side_effect_may_have_happened
      },
      closeout_record_fingerprint: closeout.closeout_record_fingerprint,
      closeout_resolution_code: closeout.resolution_code,
      closeout_operator_request_fingerprint: closeout.operator_request_fingerprint,
      replay_decision_fingerprint: context.replay_decision_fingerprint,
      replay_decision_status: context.replay_decision.decision,
      cutover_operation_request_fingerprint: outcome.cutover_operation_request_fingerprint,
      readiness_permit_fingerprint: outcome.readiness_permit_fingerprint,
      readiness_permit_decision: outcome.readiness_permit_decision,
      authorization_record_fingerprint: outcome.authorization_record_fingerprint,
      authorization_request_fingerprint: outcome.authorization_request_fingerprint,
      consumption_guard_fingerprint: outcome.safe_evidence_fingerprints.consumption_guard,
      guard_decision: "allowed",
      cutover_gate_fingerprint: outcome.cutover_gate_fingerprint,
      dry_run_audit_fingerprint: outcome.dry_run_audit_fingerprint,
      audit_history_fingerprint: outcome.audit_history_fingerprint,
      source: "operator_file",
      requested_at: "2026-07-01T09:03:00Z",
      action_code: "request_explicit_retry_consideration",
      operator_note: "full prompt, raw_provider_response, ghp_secret and /home/jhihjian/private must be digested"
    }
  end

  defp outcome_candidate(opts) do
    project_id = Keyword.get(opts, :project_id, "alpha")
    status = Keyword.get(opts, :status, "unknown")

    CutoverExecutionOutcomeLedger.fact_snapshot(%{
      project_id: project_id,
      provider_scope: provider_scope(project_id),
      operation: "writeback",
      side_effect_source: "writeback_executor",
      status: status,
      reason_code: "provider_ack_lost",
      authorization_consumption_guard: allowed_guard(project_id),
      executor_result: %{
        provider_io: true,
        raw_provider_response: "full provider body with ghp_secret",
        local_path: "/home/jhihjian/private/runtime.log"
      },
      side_effect_entered: true,
      side_effect_may_have_happened: true,
      started_at: @now,
      completed_at: @now
    })
  end

  defp allowed_guard(project_id \\ "alpha") do
    CutoverAuthorizationConsumptionGuard.to_decision(%{
      project_id: project_id,
      provider_scope: provider_scope(project_id),
      operation: "writeback",
      side_effect_source: "writeback_executor",
      decision: "allowed",
      allowed: true,
      authorization_record_fingerprint: "record-#{project_id}-writeback",
      authorization_request_fingerprint: "auth-#{project_id}-writeback",
      safe_evidence_fingerprints: %{
        cutover_operation_request: "request-#{project_id}",
        readiness_permit: "permit-#{project_id}",
        readiness_permit_decision: "ready_for_execution_consideration",
        cutover_gate: "gate-#{project_id}",
        dry_run_audit: "audit-#{project_id}",
        audit_history: "history-#{project_id}"
      }
    })
  end

  defp closeout_from_outcome(outcome) do
    %{
      project_id: outcome.project_id,
      provider_scope: outcome.provider_scope,
      operation: outcome.operation,
      side_effect_source: outcome.side_effect_source,
      replay_key: outcome.replay_key,
      outcome_fingerprint: outcome.evidence_fingerprint,
      outcome_status: outcome.status,
      side_effect_entered: outcome.side_effect_entered,
      side_effect_may_have_happened: outcome.side_effect_may_have_happened,
      cutover_operation_request_fingerprint: outcome.cutover_operation_request_fingerprint,
      authorization_record_fingerprint: outcome.authorization_record_fingerprint,
      authorization_request_fingerprint: outcome.authorization_request_fingerprint,
      readiness_permit_fingerprint: outcome.readiness_permit_fingerprint,
      readiness_permit_decision: outcome.readiness_permit_decision,
      cutover_gate_fingerprint: outcome.cutover_gate_fingerprint,
      dry_run_audit_fingerprint: outcome.dry_run_audit_fingerprint,
      audit_history_fingerprint: outcome.audit_history_fingerprint,
      consumption_guard_fingerprint: outcome.safe_evidence_fingerprints.consumption_guard,
      resolution_code: "allow_explicit_retry_consideration",
      reason_code: "operator_checked_external_state",
      action_code: "request_explicit_retry_consideration",
      source: "operator_file",
      created_at: "2026-07-01T09:01:00Z",
      closed_at: "2026-07-01T09:02:00Z",
      operator_note: "operator note with raw_provider_response and ghp_secret"
    }
  end

  defp readiness_permit_summary(outcome) do
    CutoverReadinessPermit.to_snapshot(%{
      projects: [
        %{
          project_id: outcome.project_id,
          status: "ready_for_execution_consideration",
          provider_scope: outcome.provider_scope,
          permits: [
            %{
              project_id: outcome.project_id,
              provider_scope: outcome.provider_scope,
              operation: outcome.operation,
              decision: "ready_for_execution_consideration",
              permit_fingerprint: outcome.readiness_permit_fingerprint,
              request: %{request_fingerprint: outcome.cutover_operation_request_fingerprint},
              evidence_fingerprints: %{
                dry_run_audit: outcome.dry_run_audit_fingerprint,
                audit_history: outcome.audit_history_fingerprint
              }
            }
          ]
        }
      ]
    })
  end

  defp authorization_ledger_summary(outcome) do
    CutoverExecutionAuthorization.to_snapshot(%{
      projects: [
        %{
          project_id: outcome.project_id,
          status: "authorized_for_explicit_execution",
          provider_scope: outcome.provider_scope,
          records: [
            %{
              project_id: outcome.project_id,
              provider_scope: outcome.provider_scope,
              operation: outcome.operation,
              status: "authorized_for_explicit_execution",
              authorization_record_fingerprint: outcome.authorization_record_fingerprint,
              authorization_request: %{authorization_request_fingerprint: outcome.authorization_request_fingerprint},
              cutover_operation_request: %{request_fingerprint: outcome.cutover_operation_request_fingerprint},
              readiness_permit: %{
                permit_fingerprint: outcome.readiness_permit_fingerprint,
                decision: outcome.readiness_permit_decision
              },
              evidence_fingerprints: %{
                dry_run_audit: outcome.dry_run_audit_fingerprint,
                audit_history: outcome.audit_history_fingerprint
              },
              source: "operator_file",
              requested_at: "2026-07-01T09:02:30Z"
            }
          ]
        }
      ]
    })
  end

  defp replay_decision_fingerprint(decision) do
    decision = CutoverReplayDecision.to_decision(decision)

    decision
    |> Map.take([
      :project_id,
      :provider_scope,
      :operation,
      :side_effect_source,
      :replay_key,
      :decision,
      :allowed,
      :outcome_fingerprint,
      :closeout_record_fingerprint,
      :authorization_record_fingerprint,
      :readiness_permit_fingerprint,
      :consumption_guard_fingerprint,
      :safe_evidence_fingerprints
    ])
    |> fingerprint()
  end

  defp fingerprint(value) do
    value
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp provider_scope(project_id) do
    %{
      kind: "github",
      key: "github:o/#{project_id}",
      provider_scope_key: "github:o/#{project_id}",
      scope: %{owner: "o", repo: project_id}
    }
  end
end
