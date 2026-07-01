defmodule SymphonyElixir.HubCutoverExecutionOutcomeLedgerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{CutoverAuthorizationConsumptionGuard, CutoverExecutionOutcomeLedger}

  @now ~U[2026-07-01 09:00:00Z]

  test "normalizes guard-blocked and executor outcomes into safe facts and summaries" do
    guard =
      CutoverAuthorizationConsumptionGuard.to_decision(%{
        project_id: "alpha",
        provider_scope: %{kind: "github", key: "github:o/r", scope: %{owner: "o", repo: "r"}},
        operation: "writeback",
        side_effect_source: "writeback_executor",
        decision: "no_authorization",
        reason_code: "authorization_record_missing",
        action_code: "submit_execution_authorization_request",
        safe_evidence_fingerprints: %{
          authorization: "Bearer ghp_secret",
          cutover_operation_request: "request-fp",
          readiness_permit: "permit-fp",
          cutover_gate: "gate-fp"
        }
      })

    blocked = CutoverExecutionOutcomeLedger.from_guard_decision(guard, now: @now)
    assert blocked.status == "not_executed"
    assert blocked.no_side_effects == true
    assert blocked.side_effect_entered == false
    assert Map.get(blocked, :authorization_record_fingerprint) == nil
    assert blocked.cutover_operation_request_fingerprint == "request-fp"

    allowed =
      CutoverAuthorizationConsumptionGuard.to_decision(%{
        project_id: "alpha",
        provider_scope: %{kind: "github", key: "github:o/r", scope: %{owner: "o", repo: "r"}},
        operation: "writeback",
        side_effect_source: "writeback_executor",
        decision: "allowed",
        allowed: true,
        authorization_record_fingerprint: "record-fp",
        authorization_request_fingerprint: "auth-request-fp",
        reason_code: "authorization_consumed",
        safe_evidence_fingerprints: %{
          cutover_operation_request: "request-fp",
          readiness_permit: "permit-fp",
          dry_run_audit: "audit-fp",
          audit_history: "history-fp",
          cutover_gate: "gate-fp"
        }
      })

    unknown =
      CutoverExecutionOutcomeLedger.fact_snapshot(%{
        project_id: "alpha",
        provider_scope: %{kind: "github", key: "github:o/r", scope: %{owner: "o", repo: "r"}},
        operation: "writeback",
        side_effect_source: "writeback_executor",
        status: "unknown",
        reason_code: "provider_ack_lost",
        authorization_consumption_guard: allowed,
        executor_result: %{
          provider_io: true,
          raw_provider_response: "full provider response with ghp_secret",
          body: "full comment body"
        },
        side_effect_entered: true,
        side_effect_may_have_happened: true,
        started_at: @now,
        completed_at: @now
      })

    summary = CutoverExecutionOutcomeLedger.build(%{events: [blocked, unknown]}, now: @now)

    assert summary.status == "unknown"
    assert summary.counts.outcome_count == 2
    assert summary.counts.not_executed_count == 1
    assert summary.counts.unknown_count == 1
    assert summary.counts.side_effect_entered_count == 1
    assert summary.counts.side_effect_not_entered_count == 1
    assert summary.counts.unresolved_count == 1
    assert [%{status: "unknown", replay_blocked: true}] = summary.unresolved_outcomes

    assert CutoverExecutionOutcomeLedger.find_unresolved(summary, unknown).status == "unknown"
    assert CutoverExecutionOutcomeLedger.unresolved_for?(summary, unknown)

    later_success = %{unknown | status: "succeeded", reason_code: "late_success"}
    deduped = CutoverExecutionOutcomeLedger.build(%{previous_ledger: summary, events: [later_success]}, now: @now)
    assert deduped.counts.outcome_count == 2
    assert deduped.counts.unknown_count == 1
    assert deduped.counts.succeeded_count == 0

    safe_text = inspect(summary, limit: :infinity, printable_limit: :infinity)
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "raw_provider_response"
    refute safe_text =~ "full provider response"
    refute safe_text =~ "full comment body"
  end

  test "malformed single outcome does not crash project summaries" do
    summary =
      CutoverExecutionOutcomeLedger.build(
        %{
          events: [
            "not-a-map",
            %{
              project_id: "beta",
              operation: "worker_start",
              side_effect_source: "worker_start_handoff",
              status: "succeeded",
              reason_code: "worker_started",
              side_effect_entered: true
            }
          ]
        },
        now: @now
      )

    assert summary.counts.outcome_count == 1
    assert [%{project_id: "beta", status: "succeeded"}] = summary.projects
  end
end
