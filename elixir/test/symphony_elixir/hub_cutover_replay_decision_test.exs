defmodule SymphonyElixir.HubCutoverReplayDecisionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{
    CutoverAuthorizationConsumptionGuard,
    CutoverExecutionOutcomeCloseout,
    CutoverExecutionOutcomeLedger,
    CutoverReplayDecision
  }

  @now ~U[2026-07-01 09:00:00Z]

  test "reports no unresolved outcome without implying pending retry" do
    decision =
      CutoverReplayDecision.evaluate(%{
        candidate: outcome_candidate(status: "unknown"),
        authorization_consumption_guard: allowed_guard(),
        cutover_execution_outcome_ledger: CutoverExecutionOutcomeLedger.build(%{events: []}, now: @now)
      })

    assert decision.decision == "no_unresolved_outcome"
    assert decision.allowed == true
    assert decision.reason_code == "no_matching_unresolved_outcome"
    assert decision.auto_replay_allowed == false
    refute decision.requires_operator_attention
  end

  test "blocks unresolved outcome when no effective closeout exists before side effects" do
    outcome = outcome_candidate(status: "unknown")
    ledger = CutoverExecutionOutcomeLedger.build(%{events: [outcome]}, now: @now)

    decision =
      CutoverReplayDecision.evaluate(%{
        candidate: outcome,
        authorization_consumption_guard: allowed_guard(),
        cutover_execution_outcome_ledger: ledger
      })

    assert decision.decision == "blocked_unresolved_outcome"
    assert decision.allowed == false
    assert decision.reason_code == "matching_closeout_missing"
    assert decision.unresolved_outcome.replay_key == outcome.replay_key
    assert decision.outcome_side_effect.entered == true
  end

  test "allows explicit retry consideration only with matching closeout and current allowed authorization" do
    outcome = outcome_candidate(status: "unknown")
    ledger = CutoverExecutionOutcomeLedger.build(%{events: [outcome]}, now: @now)
    closeout = closeout_summary(ledger, outcome, closeout_from_outcome(outcome, "allow_explicit_retry_consideration"))

    decision =
      CutoverReplayDecision.evaluate(%{
        candidate: outcome,
        authorization_consumption_guard: allowed_guard(),
        cutover_execution_outcome_ledger: ledger,
        cutover_execution_outcome_closeout: closeout
      })

    assert decision.decision == "retry_consideration_allowed"
    assert decision.allowed == true
    assert decision.closeout_resolution_code == "allow_explicit_retry_consideration"
    assert decision.closeout_record_fingerprint != nil
    assert decision.authorization_record_fingerprint == "record-alpha-writeback"
    assert decision.readiness_permit_fingerprint == "permit-alpha"
    assert decision.consumption_guard_fingerprint == outcome.safe_evidence_fingerprints.consumption_guard
    assert decision.no_side_effects == true
    assert decision.auto_replay_allowed == false
  end

  test "does not allow retry consideration when current authorization or safety no longer matches" do
    outcome = outcome_candidate(status: "unknown")
    ledger = CutoverExecutionOutcomeLedger.build(%{events: [outcome]}, now: @now)
    closeout = closeout_summary(ledger, outcome, closeout_from_outcome(outcome, "allow_explicit_retry_consideration"))

    stale_authorization =
      allowed_guard()
      |> Map.put(:authorization_record_fingerprint, "record-alpha-new")
      |> CutoverAuthorizationConsumptionGuard.to_decision()

    stale =
      CutoverReplayDecision.evaluate(%{
        candidate: outcome,
        authorization_consumption_guard: stale_authorization,
        cutover_execution_outcome_ledger: ledger,
        cutover_execution_outcome_closeout: closeout
      })

    assert stale.decision == "stale_closeout"
    assert stale.allowed == false
    assert stale.reason_code == "current_authorization_record_fingerprint_mismatch"

    safety_conflict_closeout =
      closeout_from_outcome(outcome, "allow_explicit_retry_consideration")
      |> Map.put(:side_effect_may_have_happened, false)
      |> then(&closeout_summary(ledger, outcome, &1))

    conflict =
      CutoverReplayDecision.evaluate(%{
        candidate: outcome,
        authorization_consumption_guard: allowed_guard(),
        cutover_execution_outcome_ledger: ledger,
        cutover_execution_outcome_closeout: safety_conflict_closeout
      })

    assert conflict.decision == "conflict"
    assert conflict.allowed == false
  end

  test "summary aggregates per-project decisions and remains safe" do
    alpha = outcome_candidate(project_id: "alpha", status: "unknown")
    beta = outcome_candidate(project_id: "beta", status: "unknown")
    ledger = CutoverExecutionOutcomeLedger.build(%{events: [alpha, beta]}, now: @now)

    alpha_closeout =
      closeout_summary(ledger, alpha, closeout_from_outcome(alpha, "allow_explicit_retry_consideration"))

    alpha_decision =
      CutoverReplayDecision.evaluate(%{
        candidate: alpha,
        authorization_consumption_guard: allowed_guard("alpha"),
        cutover_execution_outcome_ledger: ledger,
        cutover_execution_outcome_closeout: alpha_closeout
      })

    beta_decision =
      CutoverReplayDecision.evaluate(%{
        candidate: beta,
        authorization_consumption_guard: allowed_guard("beta"),
        cutover_execution_outcome_ledger: ledger
      })

    summary = CutoverReplayDecision.build(%{events: [alpha_decision, beta_decision]}, now: @now)
    projects = Map.new(summary.projects, &{&1.project_id, &1})

    assert summary.status == "blocked_unresolved_outcome"
    assert summary.counts.retry_consideration_allowed_count == 1
    assert summary.counts.unresolved_outcome_blocked_count == 1
    assert projects["alpha"].status == "retry_consideration_allowed"
    assert projects["beta"].status == "blocked_unresolved_outcome"

    safe_text = inspect(summary, limit: :infinity, printable_limit: :infinity)
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "raw_provider_response"
    refute safe_text =~ "full provider body"
    refute safe_text =~ "/home/jhihjian/private"
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

  defp closeout_summary(ledger, _outcome, closeout) do
    CutoverExecutionOutcomeCloseout.build(
      %{
        cutover_execution_outcome_ledger: ledger,
        execution_outcome_closeouts: [closeout]
      },
      now: @now
    )
  end

  defp closeout_from_outcome(outcome, resolution_code) do
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
      resolution_code: resolution_code,
      reason_code: "operator_checked_external_state",
      action_code: "record_manual_resolution",
      source: "operator_file",
      created_at: "2026-07-01T09:01:00Z",
      closed_at: "2026-07-01T09:02:00Z",
      operator_note: "operator note with raw_provider_response and ghp_secret redacted by digest"
    }
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
