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

  test "opens retryable outcomes without granting automatic replay" do
    outcome = outcome_fact(status: "retryable")

    summary =
      CutoverClosureChain.build(
        %{execution_outcomes: [outcome]},
        now: @now
      )

    [chain] = summary.recent_chains
    [project] = summary.projects

    assert summary.status == "open_retryable"
    assert summary.counts.open_retryable_count == 1
    assert summary.counts.unsupported_count == 0
    assert summary.counts.operation_status_counts.writeback.open_retryable == 1
    assert summary.counts.source_status_counts.writeback_executor.open_retryable == 1
    assert summary.auto_replay_allowed == false
    assert summary.read_only == true

    assert project.status == "open_retryable"
    assert project.counts.open_retryable_count == 1

    assert chain.closure_status == "open_retryable"
    assert chain.reason_code == "retryable_outcome_waiting_for_explicit_consideration"
    assert chain.action_code == "re_evaluate_explicit_retry_consideration"
    assert action_code?(chain, "re_evaluate_explicit_retry_consideration")
    assert chain.auto_replay_allowed == false
    assert chain.request.request_fingerprint == outcome.cutover_operation_request_fingerprint
    assert chain.readiness_permit.permit_fingerprint == outcome.readiness_permit_fingerprint
    assert chain.authorization.authorization_record_fingerprint == outcome.authorization_record_fingerprint
    assert chain.authorization.authorization_request_fingerprint == outcome.authorization_request_fingerprint
    assert chain.consumption_guard.decision == "allowed"
    assert chain.outcome.status == "retryable"
    assert chain.execution_key.attempt_fingerprint == outcome.attempt_fingerprint
    assert chain.safe_evidence_fingerprints.outcome == outcome.evidence_fingerprint
    refute chain.closure_status == "closed_succeeded"
    refute chain.closure_status == "closed_no_side_effect"
  end

  test "opens unknown and manual attention outcomes for operator closeout" do
    unknown = outcome_fact(status: "unknown")
    manual_attention = outcome_fact(status: "manual_attention")

    summary =
      CutoverClosureChain.build(
        %{execution_outcomes: [unknown, manual_attention]},
        now: @now
      )

    assert summary.status == "open_manual_attention"
    assert summary.counts.open_manual_attention_count == 2
    assert summary.counts.closed_succeeded_count == 0
    assert summary.counts.closed_no_side_effect_count == 0
    assert Enum.all?(summary.recent_chains, &(&1.closure_status == "open_manual_attention"))
    assert Enum.all?(summary.recent_chains, &(&1.action_code == "perform_operator_closeout"))
    assert Enum.all?(summary.recent_chains, &action_code?(&1, "perform_operator_closeout"))
    assert Enum.map(summary.recent_chains, & &1.outcome.status) |> Enum.sort() == ["manual_attention", "unknown"]

    assert Enum.map(summary.recent_chains, & &1.reason_code) |> Enum.sort() == [
             "manual_attention_outcome_requires_closeout",
             "unknown_outcome_requires_manual_attention"
           ]
  end

  test "summarizes closeout reference status for open manual-attention chains" do
    missing = outcome_fact(status: "unknown", project_id: "missing")
    current = outcome_fact(status: "manual_attention", project_id: "current", side_effect_entered: true, side_effect_may_have_happened: true)
    stale = outcome_fact(status: "unknown", project_id: "stale")
    conflict = outcome_fact(status: "unknown", project_id: "conflict")
    malformed = outcome_fact(status: "unknown", project_id: "malformed")
    unsupported = outcome_fact(status: "unknown", project_id: "unsupported")

    summary =
      CutoverClosureChain.build(
        %{
          closure_chains: [
            %{outcome: missing},
            %{outcome: current, closeout: closeout_reference(current)},
            %{outcome: stale, closeout: closeout_reference(stale, %{outcome_fingerprint: "old-outcome"})},
            %{
              outcome: conflict,
              closeout:
                closeout_reference(conflict, %{
                  project_id: "other",
                  provider_scope: provider_scope("other")
                })
            },
            %{outcome: malformed, closeout: malformed |> closeout_reference() |> Map.delete(:resolution_code)},
            %{outcome: unsupported, closeout: closeout_reference(unsupported, %{resolution_code: "retry_without_contract"})}
          ]
        },
        now: @now
      )

    closeout_statuses = reference_statuses_by_project(summary, :closeout)

    assert summary.status == "open_manual_attention"
    assert Enum.all?(summary.recent_chains, &(&1.closure_status == "open_manual_attention"))

    assert closeout_statuses == %{
             "missing" => "missing",
             "current" => "current",
             "stale" => "stale",
             "conflict" => "conflict",
             "malformed" => "malformed",
             "unsupported" => "unsupported"
           }

    assert summary.counts.reference_status_counts.closeout.current == 1
    assert summary.counts.closeout_reference_status_counts.missing == 1
    assert summary.counts.closeout_reference_status_counts.current == 1
    assert summary.counts.closeout_reference_status_counts.stale == 1
    assert summary.counts.closeout_reference_status_counts.conflict == 1
    assert summary.counts.closeout_reference_status_counts.malformed == 1
    assert summary.counts.closeout_reference_status_counts.unsupported == 1

    current_project = Enum.find(summary.projects, &(&1.project_id == "current"))
    assert current_project.counts.closeout_reference_status_counts.current == 1
    assert "closeout_reference_current" in summary.recent_reference_reason_codes

    snapshot = CutoverClosureChain.to_snapshot(summary)
    assert snapshot.counts.closeout_reference_status_counts == summary.counts.closeout_reference_status_counts
    assert reference_statuses_by_project(snapshot, :closeout) == closeout_statuses
  end

  test "summarizes replay decision and replay request audit reference status for retryable chains" do
    missing = outcome_fact(status: "retryable", project_id: "missing")
    current = outcome_fact(status: "retryable", project_id: "current")
    stale = outcome_fact(status: "retryable", project_id: "stale")
    conflict = outcome_fact(status: "retryable", project_id: "conflict")
    malformed = outcome_fact(status: "retryable", project_id: "malformed")
    unsupported = outcome_fact(status: "retryable", project_id: "unsupported")

    current_decision = replay_decision_reference(current)
    stale_decision = replay_decision_reference(stale, %{outcome_fingerprint: "old-outcome"})
    conflict_decision = replay_decision_reference(conflict, %{project_id: "other", provider_scope: provider_scope("other")})
    malformed_decision = malformed |> replay_decision_reference() |> Map.delete(:replay_decision_fingerprint)
    unsupported_decision = replay_decision_reference(unsupported, %{decision: "retry_now"})

    summary =
      CutoverClosureChain.build(
        %{
          closure_chains: [
            %{outcome: missing},
            %{
              outcome: current,
              replay_decision: current_decision,
              replay_request_audit: replay_request_audit_reference(current, current_decision)
            },
            %{
              outcome: stale,
              replay_decision: stale_decision,
              replay_request_audit: replay_request_audit_reference(stale, stale_decision, %{outcome_fingerprint: "old-outcome"})
            },
            %{
              outcome: conflict,
              replay_decision: conflict_decision,
              replay_request_audit:
                replay_request_audit_reference(conflict, conflict_decision, %{
                  project_id: "other",
                  provider_scope: provider_scope("other")
                })
            },
            %{
              outcome: malformed,
              replay_decision: malformed_decision,
              replay_request_audit:
                malformed
                |> replay_request_audit_reference(malformed_decision)
                |> Map.delete(:audit_record_fingerprint)
            },
            %{
              outcome: unsupported,
              replay_decision: unsupported_decision,
              replay_request_audit: replay_request_audit_reference(unsupported, unsupported_decision, %{status: "execute_now"})
            }
          ]
        },
        now: @now
      )

    decision_statuses = reference_statuses_by_project(summary, :replay_decision)
    request_statuses = reference_statuses_by_project(summary, :replay_request_audit)

    assert summary.status == "open_retryable"
    assert summary.auto_replay_allowed == false
    assert Enum.all?(summary.recent_chains, &(&1.closure_status == "open_retryable"))

    assert decision_statuses == %{
             "missing" => "missing",
             "current" => "current",
             "stale" => "stale",
             "conflict" => "conflict",
             "malformed" => "malformed",
             "unsupported" => "unsupported"
           }

    assert request_statuses == decision_statuses
    assert summary.counts.replay_decision_reference_status_counts.missing == 1
    assert summary.counts.replay_decision_reference_status_counts.current == 1
    assert summary.counts.replay_decision_reference_status_counts.stale == 1
    assert summary.counts.replay_decision_reference_status_counts.conflict == 1
    assert summary.counts.replay_decision_reference_status_counts.malformed == 1
    assert summary.counts.replay_decision_reference_status_counts.unsupported == 1
    assert summary.counts.replay_request_audit_reference_status_counts == summary.counts.replay_decision_reference_status_counts

    current_project = Enum.find(summary.projects, &(&1.project_id == "current"))
    assert current_project.counts.replay_decision_reference_status_counts.current == 1
    assert current_project.counts.replay_request_audit_reference_status_counts.current == 1
    assert "replay_decision_reference_current" in summary.recent_reference_reason_codes
    assert "replay_request_audit_reference_current" in summary.recent_reference_reason_codes

    snapshot = CutoverClosureChain.to_snapshot(summary)
    assert snapshot.counts.replay_decision_reference_status_counts == summary.counts.replay_decision_reference_status_counts
    assert snapshot.counts.replay_request_audit_reference_status_counts == summary.counts.replay_request_audit_reference_status_counts
    assert reference_statuses_by_project(snapshot, :replay_decision) == decision_statuses
    assert reference_statuses_by_project(snapshot, :replay_request_audit) == request_statuses

    safe_text = inspect(summary, limit: :infinity, printable_limit: :infinity)
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "raw_provider_response"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "/home/jhihjian/private"
  end

  test "retained references do not resolve open retryable outcomes" do
    outcome = outcome_fact(status: "retryable")

    chain =
      build_one(%{
        outcome: outcome,
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
      })

    assert chain.closure_status == "open_retryable"
    assert chain.retained_references.closeout.status == "resolved"
    assert chain.retained_references.replay_decision.decision == "retry_consideration_allowed"
    assert chain.retained_references.replay_decision.allowed == true
    assert chain.retained_references.replay_request_audit.status == "would_allow_retry_consideration"
    assert chain.auto_replay_allowed == false
    refute chain.closure_status == "closed_succeeded"
    refute chain.closure_status == "closed_no_side_effect"
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

  test "prioritizes stale conflict and malformed evidence before open outcome classification" do
    retryable = outcome_fact(status: "retryable")

    stale =
      %{
        outcome: retryable,
        safe_evidence_fingerprints: %{outcome: "outcome-alpha-new"}
      }
      |> build_one()

    assert stale.closure_status == "stale"
    assert "outcome_fingerprint_drift" in stale.reason_codes

    manual_attention = outcome_fact(status: "manual_attention")

    conflict =
      %{
        project_id: "alpha",
        provider_scope: provider_scope("other"),
        operation: "writeback",
        side_effect_source: "writeback_executor",
        outcome: manual_attention
      }
      |> build_one()

    assert conflict.closure_status == "conflict"
    assert "outcome_provider_scope_mismatch" in conflict.reason_codes

    malformed =
      "unknown"
      |> open_outcome_without_permit()
      |> build_one()

    assert malformed.closure_status == "malformed"
    assert malformed.reason_code == "readiness_permit_fingerprint_missing"
    refute stale.closure_status == "open_retryable"
    refute conflict.closure_status == "open_manual_attention"
    refute malformed.closure_status == "open_manual_attention"
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

  defp action_code?(chain, code) do
    Enum.any?(chain.required_operator_actions, &(&1.code == code))
  end

  defp reference_statuses_by_project(summary, type) do
    summary.recent_chains
    |> Map.new(fn chain ->
      {chain.project_id, get_in(chain, [:retained_reference_statuses, type, :status])}
    end)
  end

  defp open_outcome_without_permit(status) do
    %{
      project_id: "alpha",
      provider_scope: provider_scope("alpha"),
      operation: "writeback",
      side_effect_source: "writeback_executor",
      attempt_fingerprint: "attempt-alpha-missing-permit",
      replay_key: "replay-alpha-missing-permit",
      request: %{request_fingerprint: "request-alpha"},
      authorization: %{
        authorization_record_fingerprint: "record-alpha-writeback",
        authorization_request_fingerprint: "auth-alpha-writeback"
      },
      consumption_guard: %{
        project_id: "alpha",
        provider_scope: provider_scope("alpha"),
        operation: "writeback",
        side_effect_source: "writeback_executor",
        decision: "allowed",
        allowed: true,
        decision_fingerprint: "guard-alpha"
      },
      outcome: %{
        project_id: "alpha",
        provider_scope: provider_scope("alpha"),
        operation: "writeback",
        side_effect_source: "writeback_executor",
        status: status,
        attempt_fingerprint: "attempt-alpha-missing-permit",
        replay_key: "replay-alpha-missing-permit",
        cutover_operation_request_fingerprint: "request-alpha",
        authorization_record_fingerprint: "record-alpha-writeback",
        authorization_request_fingerprint: "auth-alpha-writeback",
        consumption_guard_fingerprint: "guard-alpha",
        evidence_fingerprint: "outcome-alpha",
        side_effect_entered: true,
        side_effect_may_have_happened: true,
        generated_at: @now
      }
    }
  end

  defp outcome_fact(opts) do
    status = Keyword.get(opts, :status, "succeeded")
    project_id = Keyword.get(opts, :project_id, "alpha")

    CutoverExecutionOutcomeLedger.fact_snapshot(%{
      project_id: project_id,
      provider_scope: Keyword.get(opts, :provider_scope, provider_scope(project_id)),
      operation: "writeback",
      side_effect_source: "writeback_executor",
      attempt_fingerprint: Keyword.get(opts, :attempt_fingerprint),
      replay_key: Keyword.get(opts, :replay_key),
      status: status,
      reason_code: Keyword.get(opts, :reason_code, reason_for_status(status)),
      action_code: Keyword.get(opts, :action_code),
      authorization_consumption_guard: guard_decision(decision: "allowed", allowed: true, project_id: project_id),
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
    project_id = Keyword.get(opts, :project_id, "alpha")

    CutoverAuthorizationConsumptionGuard.to_decision(%{
      project_id: project_id,
      provider_scope: provider_scope(project_id),
      operation: "writeback",
      side_effect_source: "writeback_executor",
      decision: decision,
      allowed: allowed,
      authorization_record_fingerprint: if(allowed, do: "record-#{project_id}-writeback"),
      authorization_request_fingerprint: if(allowed, do: "auth-#{project_id}-writeback"),
      reason_code: Keyword.get(opts, :reason_code, if(allowed, do: "authorization_consumed", else: "authorization_blocked")),
      action_code: Keyword.get(opts, :action_code),
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

  defp closeout_reference(outcome, attrs \\ %{}) do
    Map.merge(
      %{
        closeout_record_fingerprint: "closeout-#{outcome.project_id}",
        project_id: outcome.project_id,
        provider_scope: outcome.provider_scope,
        operation: outcome.operation,
        side_effect_source: outcome.side_effect_source,
        replay_key: outcome.replay_key,
        attempt_fingerprint: outcome.attempt_fingerprint,
        outcome_id: outcome.outcome_id,
        status: "resolved",
        resolution_code: "confirmed_resolved",
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
        safe_evidence_fingerprints: outcome.safe_evidence_fingerprints,
        reason_code: "closeout_reference_current",
        action_code: "review_closeout_reference",
        source: "test"
      },
      attrs
    )
  end

  defp replay_decision_reference(outcome, attrs \\ %{}) do
    Map.merge(
      %{
        replay_decision_fingerprint: "replay-decision-#{outcome.project_id}",
        project_id: outcome.project_id,
        provider_scope: outcome.provider_scope,
        operation: outcome.operation,
        side_effect_source: outcome.side_effect_source,
        replay_key: outcome.replay_key,
        decision: "retry_consideration_allowed",
        allowed: true,
        reason_code: "replay_decision_reference_current",
        action_code: "review_replay_decision_reference",
        outcome_fingerprint: outcome.evidence_fingerprint,
        outcome_status: outcome.status,
        side_effect_entered: outcome.side_effect_entered,
        side_effect_may_have_happened: outcome.side_effect_may_have_happened,
        cutover_operation_request_fingerprint: outcome.cutover_operation_request_fingerprint,
        authorization_record_fingerprint: outcome.authorization_record_fingerprint,
        authorization_request_fingerprint: outcome.authorization_request_fingerprint,
        readiness_permit_fingerprint: outcome.readiness_permit_fingerprint,
        readiness_permit_decision: outcome.readiness_permit_decision,
        consumption_guard_fingerprint: outcome.safe_evidence_fingerprints.consumption_guard,
        safe_evidence_fingerprints: outcome.safe_evidence_fingerprints
      },
      attrs
    )
  end

  defp replay_request_audit_reference(outcome, decision, attrs \\ %{}) do
    Map.merge(
      %{
        request_fingerprint: "replay-request-#{outcome.project_id}",
        audit_record_fingerprint: "replay-request-audit-#{outcome.project_id}",
        project_id: outcome.project_id,
        provider_scope: outcome.provider_scope,
        operation: outcome.operation,
        side_effect_source: outcome.side_effect_source,
        replay_key: outcome.replay_key,
        status: "would_allow_retry_consideration",
        outcome_link_status: "not_linked",
        outcome_fingerprint: outcome.evidence_fingerprint,
        outcome_status: outcome.status,
        side_effect_entered: outcome.side_effect_entered,
        side_effect_may_have_happened: outcome.side_effect_may_have_happened,
        replay_decision_fingerprint: Map.get(decision, :replay_decision_fingerprint),
        replay_decision_status: Map.get(decision, :decision),
        cutover_operation_request_fingerprint: outcome.cutover_operation_request_fingerprint,
        authorization_record_fingerprint: outcome.authorization_record_fingerprint,
        authorization_request_fingerprint: outcome.authorization_request_fingerprint,
        readiness_permit_fingerprint: outcome.readiness_permit_fingerprint,
        readiness_permit_decision: outcome.readiness_permit_decision,
        consumption_guard_fingerprint: outcome.safe_evidence_fingerprints.consumption_guard,
        safe_evidence_fingerprints: outcome.safe_evidence_fingerprints,
        reason_code: "replay_request_audit_reference_current",
        action_code: "review_replay_request_audit_reference",
        source: "test"
      },
      attrs
    )
  end

  defp reason_for_status("succeeded"), do: "execution_succeeded"
  defp reason_for_status("not_executed"), do: "side_effect_not_entered"
  defp reason_for_status("retryable"), do: "execution_retryable"
  defp reason_for_status("unknown"), do: "execution_result_unknown"
  defp reason_for_status("manual_attention"), do: "execution_requires_manual_attention"
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
