defmodule SymphonyElixir.HubDispatchPlanApplicationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{
    ActivationPreflight,
    CandidateIntake,
    CutoverExecutionOutcomeCloseout,
    CutoverExecutionOutcomeLedger,
    DispatchPlanApplication,
    DispatchPlanning,
    RuntimeLedger
  }

  @now ~U[2026-06-29 08:00:00Z]

  test "applies planned intents into runtime ledger facts with safe source correlation" do
    registry = registry([project("alpha", max_concurrent_agents: 2)])
    intake = CandidateIntake.build(registry, [source("alpha", [%{id: "123", identifier: "ALPHA-123"}])], now: @now)
    plan = DispatchPlanning.build(registry, intake, now: @now)

    {ledger, application} = DispatchPlanApplication.apply_plan(registry, plan, RuntimeLedger.new(), now: @now)

    assert application.counts.applied_count == 1
    assert application.counts.pending_start_intent_count == 1
    assert application.reason_counts == %{}

    assert [project] = application.projects
    assert [%{status: "applied", preflight: %{status: "allowed"}}] = project.outcomes

    assert [
             %{runtime_identity: runtime_identity, start_command_summary: start_command_summary} = intent
           ] = application.pending_start_intents

    assert runtime_identity.source_poll.request_id == "provider-request-alpha"
    assert runtime_identity.source_intake.candidate_key == "alpha:github:jhihjian/symphony:123"
    assert runtime_identity.planning.intent_id == intent.intent_id
    assert start_command_summary.starts_agent in [false, "false"]
    assert start_command_summary.creates_workspace in [false, "false"]
    assert start_command_summary.writes_provider in [false, "false"]

    assert [ledger_project] = RuntimeLedger.replay(ledger).projects
    assert [%{status: :pending, run_context: run_context}] = ledger_project.active_attempts
    assert run_context.runtime_identity.source_poll.request_id == "provider-request-alpha"
    assert [%{status: :pending}] = ledger_project.pending_start_intents
    assert [%{lease_id: lease_id}] = ledger_project.workspace_leases
    assert is_binary(lease_id)
  end

  test "repeat application reports already applied without creating another active attempt" do
    registry = registry([project("alpha", max_concurrent_agents: 2)])
    intake = CandidateIntake.build(registry, [source("alpha", [%{id: "123", identifier: "ALPHA-123"}])], now: @now)
    plan = DispatchPlanning.build(registry, intake, now: @now)

    {ledger, first_application} = DispatchPlanApplication.apply_plan(registry, plan, RuntimeLedger.new(), now: @now)
    {_ledger, second_application} = DispatchPlanApplication.apply_plan(registry, plan, ledger, now: DateTime.add(@now, 60, :second))

    assert first_application.counts.applied_count == 1
    assert second_application.counts.already_applied_count == 1
    assert second_application.reason_counts == %{"start_intent_unresolved" => 1}

    assert [project] = RuntimeLedger.replay(ledger).projects
    assert length(project.active_attempts) == 1
    assert length(project.pending_start_intents) == 1
  end

  test "respects runtime ledger capacity and unsafe planning outcomes" do
    registry = registry([project("alpha", max_concurrent_agents: 1)])
    intake = CandidateIntake.build(registry, [source("alpha", [%{id: "123"}, %{id: "124"}])], now: @now)
    plan = DispatchPlanning.build(registry, intake, now: @now)

    {_ledger, application} = DispatchPlanApplication.apply_plan(registry, plan, RuntimeLedger.new(), now: @now)

    assert application.counts.applied_count == 1
    assert application.counts.skipped_count == 1
    assert application.reason_counts == %{"project_capacity_full" => 1}

    statuses =
      application.projects
      |> Enum.flat_map(& &1.outcomes)
      |> Map.new(&{&1.issue_ref.provider_issue_id, &1.status})

    assert statuses["123"] == "applied"
    assert statuses["124"] == "skipped"
  end

  test "activation preflight blocks planned intent application without mutating the ledger" do
    registry = registry([project("alpha", migration_state: "hub_managed")])
    intake = CandidateIntake.build(registry, [source("alpha", [%{id: "123", identifier: "ALPHA-123"}])], now: @now)
    plan = DispatchPlanning.build(registry, intake, now: @now)

    preflight =
      ActivationPreflight.build(registry,
        now: @now,
        probe: %{
          projects: %{
            "alpha" => %{workspace_owners: [%{project_id: "alpha", workspace_root: "/workspaces/alpha", owner: "legacy-worker"}]}
          }
        }
      )

    {ledger, application} =
      DispatchPlanApplication.apply_plan(registry, plan, RuntimeLedger.new(),
        now: @now,
        activation_preflight: preflight
      )

    assert application.counts.applied_count == 0
    assert application.counts.blocked_count == 1
    assert application.reason_counts == %{"activation_preflight_blocked" => 1}
    assert [%{outcomes: [%{status: "blocked", reason: "activation_preflight_blocked"}]}] = application.projects
    assert RuntimeLedger.replay(ledger).projects == []
  end

  test "cutover gate blocks planned intent application before ledger mutation" do
    registry = registry([project("alpha", migration_state: "hub_managed")])
    intake = CandidateIntake.build(registry, [source("alpha", [%{id: "123", identifier: "ALPHA-123"}])], now: @now)
    plan = DispatchPlanning.build(registry, intake, now: @now)

    cutover_gate = cutover_gate("alpha", "blocked", blocked_operations: ["dispatch"], reasons: ["operator_acknowledgement_missing"])

    {ledger, application} =
      DispatchPlanApplication.apply_plan(registry, plan, RuntimeLedger.new(),
        now: @now,
        cutover_gate: cutover_gate
      )

    assert application.counts.applied_count == 0
    assert application.counts.blocked_count == 1
    assert application.reason_counts == %{"cutover_gate_blocked" => 1}
    assert [%{outcomes: [%{status: "blocked", reason: "cutover_gate_blocked"}]}] = application.projects
    assert RuntimeLedger.replay(ledger).projects == []
  end

  test "authorization consumption guard blocks planned intent application before ledger mutation" do
    registry = registry([project("alpha", migration_state: "hub_managed")])
    intake = CandidateIntake.build(registry, [source("alpha", [%{id: "123", identifier: "ALPHA-123"}])], now: @now)
    plan = DispatchPlanning.build(registry, intake, now: @now)

    {ledger, application} =
      DispatchPlanApplication.apply_plan(registry, plan, RuntimeLedger.new(),
        now: @now,
        authorization_consumption_guard: %{authorization_ledger: %{projects: []}}
      )

    assert application.counts.applied_count == 0
    assert application.counts.blocked_count == 1
    assert application.reason_counts == %{"authorization_consumption_blocked" => 1}

    assert [
             %{
               outcomes: [
                 %{
                   status: "blocked",
                   reason: "authorization_consumption_blocked",
                   authorization_consumption: %{decision: "no_authorization", side_effect_source: "dispatch_application"}
                 }
               ]
             }
           ] = application.projects

    assert RuntimeLedger.replay(ledger).projects == []
  end

  test "unresolved execution outcome blocks dispatch mutation before ledger changes" do
    registry = registry([project("alpha", migration_state: "hub_managed")])
    intake = CandidateIntake.build(registry, [source("alpha", [%{id: "123", identifier: "ALPHA-123"}])], now: @now)
    plan = DispatchPlanning.build(registry, intake, now: @now)

    {_first_ledger, first_application} =
      DispatchPlanApplication.apply_plan(registry, plan, RuntimeLedger.new(),
        now: @now,
        authorization_consumption_guard: %{authorization_ledger: authorization_ledger()}
      )

    [first_project] = first_application.projects
    [first_outcome] = first_project.outcomes

    unresolved =
      first_outcome.execution_outcome
      |> Map.put(:status, "unknown")
      |> Map.put(:reason_code, "dispatch_ack_lost")
      |> CutoverExecutionOutcomeLedger.fact_snapshot()

    outcome_ledger = CutoverExecutionOutcomeLedger.build(%{events: [unresolved]}, now: @now)

    {ledger, application} =
      DispatchPlanApplication.apply_plan(registry, plan, RuntimeLedger.new(),
        now: DateTime.add(@now, 60, :second),
        authorization_consumption_guard: %{authorization_ledger: authorization_ledger()},
        cutover_execution_outcome_ledger: outcome_ledger
      )

    assert application.counts.applied_count == 0
    assert application.counts.blocked_count == 1
    assert application.reason_counts == %{"execution_outcome_replay_blocked" => 1}

    assert [
             %{
               outcomes: [
                 %{
                   status: "blocked",
                   reason: "execution_outcome_replay_blocked",
                   replay_decision: %{decision: "blocked_unresolved_outcome"},
                   execution_outcome: %{status: "unknown"}
                 }
               ]
             }
           ] = application.projects

    assert RuntimeLedger.replay(ledger).projects == []
  end

  test "matching retry-consideration closeout allows explicit dispatch reconsideration only after current guard" do
    registry = registry([project("alpha", migration_state: "hub_managed")])
    intake = CandidateIntake.build(registry, [source("alpha", [%{id: "123", identifier: "ALPHA-123"}])], now: @now)
    plan = DispatchPlanning.build(registry, intake, now: @now)

    {_first_ledger, first_application} =
      DispatchPlanApplication.apply_plan(registry, plan, RuntimeLedger.new(),
        now: @now,
        authorization_consumption_guard: %{authorization_ledger: authorization_ledger()}
      )

    [first_project] = first_application.projects
    [first_outcome] = first_project.outcomes

    unresolved =
      first_outcome.execution_outcome
      |> Map.put(:status, "unknown")
      |> Map.put(:reason_code, "dispatch_ack_lost")
      |> CutoverExecutionOutcomeLedger.fact_snapshot()

    outcome_ledger = CutoverExecutionOutcomeLedger.build(%{events: [unresolved]}, now: @now)
    closeout = closeout_summary(outcome_ledger, unresolved, "allow_explicit_retry_consideration")

    {ledger, application} =
      DispatchPlanApplication.apply_plan(registry, plan, RuntimeLedger.new(),
        now: DateTime.add(@now, 60, :second),
        authorization_consumption_guard: %{authorization_ledger: authorization_ledger()},
        cutover_execution_outcome_ledger: outcome_ledger,
        cutover_execution_outcome_closeout: closeout
      )

    assert application.counts.applied_count == 1
    assert application.counts.blocked_count == 0

    assert [project] = application.projects
    assert [outcome] = project.outcomes
    assert outcome.status == "applied"
    assert outcome.replay_decision.decision == "retry_consideration_allowed"
    assert outcome.replay_decision.auto_replay_allowed == false
    assert outcome.execution_outcome.status == "succeeded"

    assert [_project] = RuntimeLedger.replay(ledger).projects
  end

  test "sanitizes application summary and pending start intent metadata" do
    registry = registry([project("alpha")])

    intake =
      CandidateIntake.build(
        registry,
        [
          %{
            result: %{
              project_id: "alpha",
              provider_scope_key: "github:jhihjian/symphony",
              request_id: "provider-request-alpha",
              logical_key: "hub-poll:alpha:candidate_scan",
              status: :success,
              result_summary: %{
                authorization: "Bearer supersecret",
                cookie: "session=supersecret",
                token: "ghp_supersecret",
                prompt: "full prompt should not leak",
                transcript: "complete transcript should not leak",
                raw_body: "raw provider body should not leak",
                candidates: [
                  %{id: "123", identifier: "ALPHA-123", comment_body: "complete comment body should not leak"}
                ]
              }
            },
            attempt: %{attempt_id: "poll-attempt-alpha"}
          }
        ],
        now: @now
      )

    plan = DispatchPlanning.build(registry, intake, now: @now)
    {_ledger, application} = DispatchPlanApplication.apply_plan(registry, plan, RuntimeLedger.new(), now: @now)
    safe_text = inspect(application)

    refute safe_text =~ "Bearer"
    refute safe_text =~ "session=supersecret"
    refute safe_text =~ "ghp_supersecret"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "complete transcript"
    refute safe_text =~ "raw provider body"
    refute safe_text =~ "complete comment body"
    refute safe_text =~ "authorization"
    refute safe_text =~ "cookie"
    refute safe_text =~ "comment_body"
  end

  defp registry(projects), do: %{projects: projects, warnings: [], errors: []}

  defp project(project_id, opts \\ []) do
    %{
      project_id: project_id,
      name: String.capitalize(project_id),
      migration_state: Keyword.get(opts, :migration_state, "hub_ready"),
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
        provider_scope_key: "github:jhihjian/symphony",
        required_labels: ["symphony"]
      },
      runtime_summary: %{
        workspace_root: "/workspaces/#{project_id}",
        max_concurrent_agents: Keyword.get(opts, :max_concurrent_agents, 10),
        max_concurrent_agents_by_state: %{},
        polling_interval_ms: 30_000,
        server_port: nil
      },
      fingerprint: "#{project_id}-fingerprint",
      loaded_at: @now
    }
  end

  defp source(project_id, candidates, opts \\ []) do
    %{
      result: %{
        project_id: project_id,
        provider_scope_key: "github:jhihjian/symphony",
        request_id: "provider-request-#{project_id}",
        logical_key: "hub-poll:#{project_id}:candidate_scan",
        status: Keyword.get(opts, :status, :success),
        result_summary: %{candidates: candidates}
      },
      attempt: %{attempt_id: "poll-attempt-#{project_id}"}
    }
  end

  defp cutover_gate(project_id, decision, opts) do
    %{
      projects: [
        %{
          project_id: project_id,
          migration_state: "hub_managed",
          decision: decision,
          allowed_operations: Keyword.get(opts, :allowed_operations, []),
          blocked_operations: Keyword.get(opts, :blocked_operations, ["poll", "dispatch", "worker_start", "writeback"]),
          blocking_reasons:
            opts
            |> Keyword.get(:reasons, [])
            |> Enum.map(&%{code: &1, source: "cutover_gate", level: "blocking"}),
          required_operator_actions: [%{code: "accept_activation_plan"}]
        }
      ]
    }
  end

  defp authorization_ledger do
    %{
      projects: [
        %{
          project_id: "alpha",
          authorization_request_count: 1,
          records: [
            %{
              project_id: "alpha",
              operation: "dispatch",
              status: "authorized_for_explicit_execution",
              provider_scope: %{kind: "github", key: "github:jhihjian/symphony", provider_scope_key: "github:jhihjian/symphony", scope: %{owner: "jhihjian", repo: "symphony"}},
              authorization_record_fingerprint: "record-alpha-dispatch",
              authorization_request: %{authorization_request_fingerprint: "auth-alpha-dispatch"},
              cutover_operation_request: %{request_fingerprint: "request-alpha-dispatch"},
              readiness_permit: %{permit_fingerprint: "permit-alpha-dispatch", decision: "ready_for_execution_consideration"},
              cutover_gate: %{fingerprint: "gate-alpha-dispatch"},
              evidence_fingerprints: %{
                dry_run_audit: "audit-alpha-dispatch",
                audit_history: "history-alpha-dispatch"
              }
            }
          ]
        }
      ]
    }
  end

  defp closeout_summary(ledger, outcome, resolution_code) do
    CutoverExecutionOutcomeCloseout.build(
      %{
        cutover_execution_outcome_ledger: ledger,
        execution_outcome_closeouts: [closeout_from_outcome(outcome, resolution_code)]
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
      closed_at: "2026-07-01T09:02:00Z"
    }
  end
end
