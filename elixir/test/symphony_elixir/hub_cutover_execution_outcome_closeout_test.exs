defmodule SymphonyElixir.HubCutoverExecutionOutcomeCloseoutTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{
    CutoverAuthorizationConsumptionGuard,
    CutoverExecutionOutcomeCloseout,
    CutoverExecutionOutcomeLedger
  }

  @now ~U[2026-07-01 09:00:00Z]

  test "resolves unresolved outcome with matching safe evidence and never allows automatic replay" do
    outcome = unresolved_outcome(side_effect_entered: false, side_effect_may_have_happened: false)
    ledger = CutoverExecutionOutcomeLedger.build(%{events: [outcome]}, now: @now)
    closeout = closeout_from_outcome(outcome, "allow_explicit_retry_consideration")

    summary =
      CutoverExecutionOutcomeCloseout.build(
        %{
          cutover_execution_outcome_ledger: ledger,
          execution_outcome_closeouts: [closeout]
        },
        now: @now
      )

    assert summary.status == "resolved"
    assert summary.counts.unresolved_outcome_count == 1
    assert summary.counts.resolved_count == 1
    assert summary.counts.allow_explicit_retry_consideration_count == 1
    assert summary.auto_replay_allowed == false

    [project] = summary.projects
    assert project.status == "resolved"
    assert project.allow_explicit_retry_consideration == true
    assert project.counts.still_requires_operator_count == 0
    assert "requires_new_permit_authorization_and_consumption_guard" in project.retry_consideration_reasons

    [record] = project.closeouts
    assert record.status == "resolved"
    assert record.allow_explicit_retry_consideration == true
    assert record.auto_replay_allowed == false
    assert record.replay_blocked == true
    assert record.replay_key == outcome.replay_key
    assert record.authorization_record_fingerprint == outcome.authorization_record_fingerprint
    assert record.readiness_permit_fingerprint == outcome.readiness_permit_fingerprint
    assert record.consumption_guard_fingerprint == outcome.safe_evidence_fingerprints.consumption_guard

    assert CutoverExecutionOutcomeCloseout.retry_consideration_allowed?(summary, outcome)

    safe_text = inspect(summary, limit: :infinity, printable_limit: :infinity)
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "raw_provider_response"
    refute safe_text =~ "full provider body"
    refute safe_text =~ "/home/jhihjian/private"
  end

  test "missing closeout leaves unresolved unknown/manual attention observable" do
    outcome = unresolved_outcome()
    ledger = CutoverExecutionOutcomeLedger.build(%{events: [outcome]}, now: @now)

    summary =
      CutoverExecutionOutcomeCloseout.build(
        %{cutover_execution_outcome_ledger: ledger},
        now: @now
      )

    assert summary.status == "no_closeout"
    assert summary.counts.unresolved_outcome_count == 1
    assert summary.counts.closeout_count == 0
    assert summary.auto_replay_allowed == false
    assert [project] = summary.projects
    assert project.status == "no_closeout"
    assert project.counts.still_requires_operator_count == 1
    refute CutoverExecutionOutcomeCloseout.retry_consideration_allowed?(summary, outcome)
  end

  test "stale conflict and malformed closeouts do not cover current outcome or other projects" do
    alpha = unresolved_outcome(project_id: "alpha", side_effect_entered: false, side_effect_may_have_happened: false)
    beta = unresolved_outcome(project_id: "beta", side_effect_entered: false, side_effect_may_have_happened: false)
    ledger = CutoverExecutionOutcomeLedger.build(%{events: [alpha, beta]}, now: @now)

    stale =
      alpha
      |> closeout_from_outcome("confirmed_resolved")
      |> Map.put(:outcome_fingerprint, "old-outcome-fingerprint")

    conflict =
      alpha
      |> closeout_from_outcome("allow_explicit_retry_consideration")
      |> Map.put(:side_effect_may_have_happened, true)

    malformed =
      beta
      |> closeout_from_outcome("confirmed_resolved")
      |> Map.delete(:readiness_permit_fingerprint)

    summary =
      CutoverExecutionOutcomeCloseout.build(
        %{
          cutover_execution_outcome_ledger: ledger,
          execution_outcome_closeouts: [stale, conflict, malformed]
        },
        now: @now
      )

    projects = Map.new(summary.projects, &{&1.project_id, &1})

    assert projects["alpha"].status == "conflict"
    assert projects["alpha"].counts.stale_count == 1
    assert projects["alpha"].counts.conflict_count == 1
    assert projects["alpha"].counts.still_requires_operator_count == 1

    assert projects["beta"].status == "malformed"
    assert projects["beta"].counts.malformed_count == 1
    assert projects["beta"].counts.still_requires_operator_count == 1

    refute CutoverExecutionOutcomeCloseout.retry_consideration_allowed?(summary, alpha)
    refute CutoverExecutionOutcomeCloseout.retry_consideration_allowed?(summary, beta)
  end

  defp unresolved_outcome(opts \\ []) do
    project_id = Keyword.get(opts, :project_id, "alpha")
    side_effect_entered = Keyword.get(opts, :side_effect_entered, true)
    side_effect_may_have_happened = Keyword.get(opts, :side_effect_may_have_happened, true)

    guard =
      CutoverAuthorizationConsumptionGuard.to_decision(%{
        project_id: project_id,
        provider_scope: %{kind: "github", key: "github:o/r", provider_scope_key: "github:o/r", scope: %{owner: "o", repo: "r"}},
        operation: "writeback",
        side_effect_source: "writeback_executor",
        decision: "allowed",
        allowed: true,
        authorization_record_fingerprint: "#{project_id}-record-fp",
        authorization_request_fingerprint: "#{project_id}-auth-request-fp",
        safe_evidence_fingerprints: %{
          cutover_operation_request: "#{project_id}-request-fp",
          readiness_permit: "#{project_id}-permit-fp",
          readiness_permit_decision: "ready_for_execution_consideration",
          cutover_gate: "#{project_id}-gate-fp",
          dry_run_audit: "#{project_id}-audit-fp",
          audit_history: "#{project_id}-history-fp"
        }
      })

    CutoverExecutionOutcomeLedger.fact_snapshot(%{
      project_id: project_id,
      provider_scope: %{kind: "github", key: "github:o/r", provider_scope_key: "github:o/r", scope: %{owner: "o", repo: "r"}},
      operation: "writeback",
      side_effect_source: "writeback_executor",
      status: "unknown",
      reason_code: "provider_ack_lost",
      authorization_consumption_guard: guard,
      executor_result: %{
        provider_io: side_effect_entered,
        raw_provider_response: "full provider body with ghp_secret",
        local_path: "/home/jhihjian/private/runtime.log"
      },
      side_effect_entered: side_effect_entered,
      side_effect_may_have_happened: side_effect_may_have_happened,
      started_at: @now,
      completed_at: @now
    })
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
end
