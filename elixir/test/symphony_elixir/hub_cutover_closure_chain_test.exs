defmodule SymphonyElixir.HubCutoverClosureChainTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{
    CutoverAuthorizationConsumptionGuard,
    CutoverClosureChain,
    CutoverExecutionOutcomeLedger
  }

  @now ~U[2026-07-01 09:00:00Z]

  test "reports no_chain and no_request without implying queued execution" do
    empty = CutoverClosureChain.build(%{}, now: @now)
    assert empty.status == "no_chain"
    assert empty.counts.chain_count == 0
    assert empty.counts.no_chain_count == 1
    assert empty.no_side_effects == true
    assert empty.auto_replay_allowed == false

    no_request = CutoverClosureChain.build(%{projects: [%{project_id: "alpha"}]}, now: @now)
    assert no_request.status == "no_request"
    assert no_request.counts.no_request_count == 1
    assert [%{project_id: "alpha", status: "no_request", closure_chains: []}] = no_request.projects
  end

  test "closes succeeded only from matching succeeded outcome evidence" do
    outcome = outcome_fact(status: "succeeded")
    ledger = CutoverExecutionOutcomeLedger.build(%{events: [outcome]}, now: @now)

    summary =
      CutoverClosureChain.build(
        %{cutover_execution_outcome_ledger: ledger},
        now: @now
      )

    [chain] = summary.recent_chains

    assert summary.status == "closed_succeeded"
    assert summary.counts.closed_succeeded_count == 1
    assert chain.closure_status == "closed_succeeded"
    assert chain.project_id == "alpha"
    assert chain.provider_scope.provider_scope_key == "github:o/alpha"
    assert chain.operation == "writeback"
    assert chain.source == "writeback_executor"
    assert chain.execution_key.attempt_fingerprint == outcome.attempt_fingerprint
    assert chain.execution_key.replay_key == outcome.replay_key
    assert chain.request.request_fingerprint == outcome.cutover_operation_request_fingerprint
    assert chain.readiness_permit.permit_fingerprint == outcome.readiness_permit_fingerprint
    assert chain.authorization.authorization_record_fingerprint == outcome.authorization_record_fingerprint
    assert chain.authorization.authorization_request_fingerprint == outcome.authorization_request_fingerprint
    assert chain.consumption_guard.decision == "allowed"
    assert chain.outcome.status == "succeeded"
    assert chain.outcome.evidence_fingerprint == outcome.evidence_fingerprint
    assert chain.safe_evidence_fingerprints.outcome == outcome.evidence_fingerprint
    assert is_binary(chain.safe_evidence_fingerprint)

    safe_text = inspect(summary, limit: :infinity, printable_limit: :infinity)
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "raw_provider_response"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "/home/jhihjian/private"
  end

  test "closes no-side-effect outcomes without reporting operation success" do
    no_auth_guard =
      guard_decision(
        decision: "no_authorization",
        allowed: false,
        reason_code: "authorization_record_missing",
        action_code: "submit_execution_authorization_request"
      )

    guard_blocked = CutoverExecutionOutcomeLedger.from_guard_decision(no_auth_guard, now: @now)

    validation_blocked =
      outcome_fact(
        status: "not_executed",
        reason_code: "validation_blocked_before_side_effect",
        action_code: "fix_validation_input",
        side_effect_entered: false,
        side_effect_may_have_happened: false,
        executor_result: %{}
      )

    summary =
      CutoverClosureChain.build(
        %{execution_outcomes: [guard_blocked, validation_blocked]},
        now: @now
      )

    assert summary.status == "closed_no_side_effect"
    assert summary.counts.closed_no_side_effect_count == 2
    assert Enum.all?(summary.recent_chains, &(&1.closure_status == "closed_no_side_effect"))
    assert Enum.all?(summary.recent_chains, &(get_in(&1, [:outcome, :status]) != "succeeded"))
    assert Enum.all?(summary.recent_chains, &(get_in(&1, [:outcome, :side_effect_entered]) == false))
  end

  test "marks drift, conflicts, malformed, and unsupported input without closing success" do
    outcome = outcome_fact(status: "succeeded")

    stale =
      %{
        outcome: outcome,
        safe_evidence_fingerprints: %{cutover_operation_request: "request-alpha-new"}
      }
      |> build_one()

    assert stale.closure_status == "stale"
    assert "cutover_operation_request_fingerprint_drift" in stale.reason_codes

    conflict =
      %{
        project_id: "alpha",
        provider_scope: provider_scope("other"),
        operation: "writeback",
        side_effect_source: "writeback_executor",
        outcome: outcome
      }
      |> build_one()

    assert conflict.closure_status == "conflict"
    assert "outcome_provider_scope_mismatch" in conflict.reason_codes

    malformed =
      %{
        project_id: "alpha",
        provider_scope: provider_scope("alpha"),
        operation: "writeback",
        side_effect_source: "writeback_executor",
        request: %{request_fingerprint: "request-alpha"}
      }
      |> build_one()

    assert malformed.closure_status == "malformed"
    assert "attempt_or_replay_key_missing" in malformed.reason_codes

    unsupported =
      %{
        project_id: "alpha",
        provider_scope: provider_scope("alpha"),
        operation: "writeback",
        side_effect_source: "unsupported_source",
        outcome: outcome
      }
      |> build_one()

    assert unsupported.closure_status == "unsupported"
    assert "unsupported_side_effect_source" in unsupported.reason_codes

    refute stale.closure_status == "closed_succeeded"
    refute conflict.closure_status == "closed_succeeded"
    refute malformed.closure_status == "closed_succeeded"
    refute unsupported.closure_status == "closed_succeeded"
  end

  test "allowed references alone do not imply succeeded closure" do
    outcome = outcome_fact(status: "unknown")

    reference_only = %{
      project_id: "alpha",
      provider_scope: provider_scope("alpha"),
      operation: "writeback",
      side_effect_source: "writeback_executor",
      attempt_fingerprint: outcome.attempt_fingerprint,
      replay_key: outcome.replay_key,
      request: %{request_fingerprint: outcome.cutover_operation_request_fingerprint},
      readiness_permit: %{
        permit_fingerprint: outcome.readiness_permit_fingerprint,
        decision: "ready_for_execution_consideration"
      },
      authorization: %{
        status: "authorized_for_explicit_execution",
        authorization_record_fingerprint: outcome.authorization_record_fingerprint,
        authorization_request_fingerprint: outcome.authorization_request_fingerprint
      },
      consumption_guard: guard_decision(decision: "allowed", allowed: true),
      closeout: %{
        status: "resolved",
        resolution_code: "confirmed_resolved",
        closeout_record_fingerprint: "closeout-alpha"
      },
      replay_decision: %{
        decision: "retry_consideration_allowed",
        allowed: true,
        replay_decision_fingerprint: "replay-decision-alpha"
      },
      replay_request_audit: %{
        status: "would_allow_retry_consideration",
        request_fingerprint: "replay-request-alpha"
      }
    }

    chain = build_one(reference_only)

    assert chain.closure_status == "unsupported"
    assert chain.reason_code == "execution_outcome_required"
    assert chain.retained_references.closeout.status == "resolved"
    assert chain.retained_references.replay_decision.decision == "retry_consideration_allowed"
    assert chain.retained_references.replay_request_audit.status == "would_allow_retry_consideration"
    refute chain.closure_status == "closed_succeeded"
  end

  test "read-only boundary does not invoke fake side-effect adapters" do
    test_pid = self()

    fake = fn name ->
      fn _input ->
        send(test_pid, {:called, name})
        :unexpected
      end
    end

    outcome = outcome_fact(status: "succeeded")

    summary =
      CutoverClosureChain.build(
        %{
          execution_outcomes: [outcome],
          fake_executor: fake.(:executor),
          fake_provider: fake.(:provider),
          fake_dispatch: fake.(:dispatch),
          fake_worker_starter: fake.(:worker_starter),
          fake_writeback: fake.(:writeback),
          fake_systemd: fake.(:systemd),
          fake_config_writer: fake.(:config_writer)
        },
        now: @now
      )

    assert summary.status == "closed_succeeded"
    refute_received {:called, :executor}
    refute_received {:called, :provider}
    refute_received {:called, :dispatch}
    refute_received {:called, :worker_starter}
    refute_received {:called, :writeback}
    refute_received {:called, :systemd}
    refute_received {:called, :config_writer}
  end

  defp build_one(chain) do
    summary = CutoverClosureChain.build(%{closure_chains: [chain]}, now: @now)
    [record] = summary.recent_chains
    record
  end

  defp outcome_fact(opts) do
    status = Keyword.get(opts, :status, "succeeded")

    CutoverExecutionOutcomeLedger.fact_snapshot(%{
      project_id: "alpha",
      provider_scope: provider_scope("alpha"),
      operation: "writeback",
      side_effect_source: "writeback_executor",
      status: status,
      reason_code: Keyword.get(opts, :reason_code, reason_for_status(status)),
      action_code: Keyword.get(opts, :action_code),
      authorization_consumption_guard: guard_decision(decision: "allowed", allowed: true),
      executor_result:
        Keyword.get(opts, :executor_result, %{
          provider_io: status == "succeeded",
          status: if(status == "succeeded", do: "success", else: status),
          raw_provider_response: "full raw_provider_response with ghp_secret",
          full_prompt: "full prompt should not appear",
          local_path: "/home/jhihjian/private/runtime.log"
        }),
      side_effect_entered: Keyword.get(opts, :side_effect_entered, status == "succeeded"),
      side_effect_may_have_happened: Keyword.get(opts, :side_effect_may_have_happened, status == "succeeded"),
      started_at: @now,
      completed_at: @now,
      generated_at: @now
    })
  end

  defp guard_decision(opts) do
    decision = Keyword.get(opts, :decision, "allowed")
    allowed = Keyword.get(opts, :allowed, decision == "allowed")

    CutoverAuthorizationConsumptionGuard.to_decision(%{
      project_id: "alpha",
      provider_scope: provider_scope("alpha"),
      operation: "writeback",
      side_effect_source: "writeback_executor",
      decision: decision,
      allowed: allowed,
      authorization_record_fingerprint: if(allowed, do: "record-alpha-writeback"),
      authorization_request_fingerprint: if(allowed, do: "auth-alpha-writeback"),
      reason_code: Keyword.get(opts, :reason_code, if(allowed, do: "authorization_consumed", else: "authorization_blocked")),
      action_code: Keyword.get(opts, :action_code),
      safe_evidence_fingerprints: %{
        cutover_operation_request: "request-alpha",
        readiness_permit: "permit-alpha",
        readiness_permit_decision: "ready_for_execution_consideration",
        cutover_gate: "gate-alpha",
        dry_run_audit: "audit-alpha",
        audit_history: "history-alpha"
      }
    })
  end

  defp reason_for_status("succeeded"), do: "execution_succeeded"
  defp reason_for_status("not_executed"), do: "side_effect_not_entered"
  defp reason_for_status("unknown"), do: "execution_result_unknown"
  defp reason_for_status(_status), do: "execution_result"

  defp provider_scope(project_id) do
    %{
      kind: "github",
      key: "github:o/#{project_id}",
      provider_scope_key: "github:o/#{project_id}",
      scope: %{owner: "o", repo: project_id}
    }
  end
end
