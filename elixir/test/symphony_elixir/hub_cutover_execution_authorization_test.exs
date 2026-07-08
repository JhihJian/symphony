defmodule SymphonyElixir.HubCutoverExecutionAuthorizationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{
    CutoverAuditHistory,
    CutoverAuthorizationConsumptionGuard,
    CutoverExecutionAuthorization,
    CutoverOperationAudit,
    CutoverReadinessPermit,
    DeviceObservability
  }

  @now ~U[2026-07-01 08:00:00Z]

  test "authorizes an explicit execution request only when current permit evidence still matches" do
    parent = self()
    projection = projection(["alpha"], acknowledgements?: true)
    [project] = projection.projects

    request = cutover_request(project, project.cutover_gate, requested_operations: ["writeback"])
    audit = CutoverOperationAudit.build(audit_sources(projection), now: @now, requests: [request])
    history = CutoverAuditHistory.build(%{generated_at: @now, cutover_operation_audit: audit}, now: @now)
    permit = CutoverReadinessPermit.build(permit_sources(projection, audit, history), now: @now)
    [operation_permit] = hd(permit.projects).permits

    authorization =
      CutoverExecutionAuthorization.build(
        authorization_sources(projection, permit),
        now: @now,
        requests: [authorization_request(operation_permit)]
      )

    assert authorization.status == "authorized_for_explicit_execution"
    assert authorization.counts.authorization_request_count == 1
    assert authorization.counts.record_count == 1
    assert authorization.counts.authorized_count == 1
    assert authorization.dry_run_only == true
    assert authorization.no_side_effects == true

    [authorization_project] = authorization.projects
    assert authorization_project.status == "authorized_for_explicit_execution"
    assert authorization_project.authorization_request_count == 1

    [record] = authorization_project.records
    assert record.status == "authorized_for_explicit_execution"
    assert record.operation == "writeback"
    assert record.authorization_request.authorization_request_id == "auth-alpha-writeback"
    assert record.cutover_operation_request.request_fingerprint == operation_permit.request.request_fingerprint
    assert record.readiness_permit.permit_fingerprint == operation_permit.permit_fingerprint
    assert record.readiness_permit.decision == "ready_for_execution_consideration"
    assert record.activation_plan.fingerprint == operation_permit.activation_plan.fingerprint
    assert record.operator_acknowledgement.fingerprint == operation_permit.operator_acknowledgement.fingerprint
    assert record.cutover_gate.fingerprint == operation_permit.cutover_gate.fingerprint
    assert record.dry_run_audit.operation_decision == "would_allow"
    assert record.audit_history.status == "history_ready"
    assert record.evidence_fingerprints.authorization_input != nil
    assert record.authorization_record_fingerprint != nil

    refute_received :provider_called
    refute_received :worker_started
    send(parent, :ledger_checked)
    assert_received :ledger_checked

    safe_text = inspect(authorization, limit: :infinity, printable_limit: :infinity)
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "Bearer"
    refute safe_text =~ "Authorization"
    refute safe_text =~ "/workspaces"
    refute safe_text =~ "full prompt"
  end

  test "blocked stale manual unsupported malformed and no-ready-permit requests never authorize" do
    blocked = build_authorization("blocked", :blocked)
    stale = build_authorization("stale", :stale)
    manual = build_authorization("manual", :manual_attention)
    unsupported = build_authorization("unsupported", :unsupported)
    malformed = build_authorization("malformed", :malformed)

    no_ready_permit =
      CutoverExecutionAuthorization.build(
        authorization_sources(projection(["missing"], acknowledgements?: true), %{projects: []}),
        now: @now,
        requests: [
          %{
            authorization_request_id: "auth-missing",
            project_id: "missing",
            operation: "poll",
            source: "operator-file",
            requested_at: "2026-07-01T08:05:00Z",
            operator_intent: %{note: "Authorization: Bearer secret"},
            readiness_permit_fingerprint: "missing-permit"
          }
        ]
      )

    assert only_record(blocked, "blocked").status == "blocked"
    assert "readiness_permit_blocked" in only_record(blocked, "blocked").reason_codes

    assert only_record(stale, "stale").status == "stale"
    assert "readiness_permit_fingerprint_mismatch" in only_record(stale, "stale").reason_codes

    assert only_record(manual, "manual").status == "manual_attention"
    assert "readiness_permit_manual_attention" in only_record(manual, "manual").reason_codes

    assert only_record(unsupported, "unsupported").status == "unsupported"
    assert "unknown_operation" in only_record(unsupported, "unsupported").reason_codes

    assert only_record(malformed, "malformed").status == "malformed"
    assert "readiness_permit_malformed" in only_record(malformed, "malformed").reason_codes

    assert only_record(no_ready_permit, "missing").status == "no_ready_permit"
    assert "readiness_permit_missing" in only_record(no_ready_permit, "missing").reason_codes
  end

  test "device projection embeds authorization ledger and isolates malformed project input" do
    projection = projection(["alpha", "beta"], acknowledgements?: true)
    alpha = Enum.find(projection.projects, &(&1.project_id == "alpha"))
    audit = CutoverOperationAudit.build(audit_sources(projection), now: @now, requests: [cutover_request(alpha, alpha.cutover_gate, requested_operations: ["poll"])])
    history = CutoverAuditHistory.build(%{generated_at: @now, cutover_operation_audit: audit}, now: @now)
    permit = CutoverReadinessPermit.build(permit_sources(projection, audit, history), now: @now)
    [operation_permit] = hd(permit.projects).permits

    ledger =
      CutoverExecutionAuthorization.build(
        authorization_sources(projection, permit),
        now: @now,
        requests: [authorization_request(operation_permit)]
      )

    projected =
      DeviceObservability.to_snapshot(%{
        projection
        | cutover_readiness_permit: permit,
          cutover_execution_authorization_ledger: ledger
      })

    projects = Map.new(projected.projects, &{&1.project_id, &1})

    assert projected.cutover_execution_authorization_ledger.counts.record_count == 1
    assert projected.overview.cutover_execution_authorization_ledger.authorized_count == 1
    assert projects["alpha"].cutover_execution_authorization_ledger.status == "authorized_for_explicit_execution"
    assert projects["beta"].cutover_execution_authorization_ledger.status == "no_ready_permit"

    malformed = CutoverExecutionAuthorization.to_snapshot(%{generated_at: @now, projects: ["not-a-project-map", hd(ledger.projects)]})
    assert Enum.any?(malformed.projects, &(&1.project_id == "" and &1.status == "no_ready_permit"))
    assert Enum.any?(malformed.projects, &(&1.project_id == "alpha" and &1.status == "authorized_for_explicit_execution"))
  end

  test "authorization consumption guard allows current records and blocks stale malformed or missing records" do
    projection = projection(["alpha"], acknowledgements?: true)
    [project] = projection.projects
    audit = CutoverOperationAudit.build(audit_sources(projection), now: @now, requests: [cutover_request(project, project.cutover_gate, requested_operations: ["writeback"])])
    history = CutoverAuditHistory.build(%{generated_at: @now, cutover_operation_audit: audit}, now: @now)
    permit = CutoverReadinessPermit.build(permit_sources(projection, audit, history), now: @now)
    [operation_permit] = hd(permit.projects).permits

    ledger =
      CutoverExecutionAuthorization.build(
        authorization_sources(projection, permit),
        now: @now,
        requests: [authorization_request(operation_permit)]
      )

    [record] = hd(ledger.projects).records

    guard_input = %{
      authorization_ledger: ledger,
      project_id: "alpha",
      provider_scope: operation_permit.provider_scope,
      operation: "writeback",
      side_effect_source: "writeback_executor",
      current_fingerprints: %{
        cutover_operation_request: operation_permit.request.request_fingerprint,
        readiness_permit: operation_permit.permit_fingerprint,
        readiness_permit_decision: operation_permit.decision,
        activation_plan: operation_permit.activation_plan.fingerprint,
        operator_acknowledgement: operation_permit.operator_acknowledgement.fingerprint,
        cutover_gate: operation_permit.cutover_gate.fingerprint,
        dry_run_audit: operation_permit.evidence_fingerprints.dry_run_audit,
        audit_history: operation_permit.evidence_fingerprints.audit_history,
        executor_modes: record.evidence_fingerprints.executor_modes
      },
      execution_mode: %{mode: "real_writeback", provider_io: true, supported_operations: ["stage_writeback"]}
    }

    allowed = CutoverAuthorizationConsumptionGuard.evaluate(guard_input, now: @now)
    assert allowed.decision == "allowed"
    assert allowed.allowed == true
    assert allowed.reason_code == "authorization_consumed"
    assert allowed.authorization_record_fingerprint != nil

    stale =
      guard_input
      |> put_in([:current_fingerprints, :readiness_permit], "old-permit")
      |> CutoverAuthorizationConsumptionGuard.evaluate(now: @now)

    assert stale.decision == "stale"
    assert stale.allowed == false
    assert stale.reason_code == "readiness_permit_fingerprint_drift"

    no_authorization =
      guard_input
      |> Map.put(:operation, "poll")
      |> Map.put(:side_effect_source, "candidate_scan")
      |> CutoverAuthorizationConsumptionGuard.evaluate(now: @now)

    assert no_authorization.decision == "no_authorization"
    assert no_authorization.reason_code == "authorization_record_operation_missing"

    malformed = CutoverAuthorizationConsumptionGuard.evaluate("not-a-map", now: @now)
    assert malformed.decision == "malformed"

    summary =
      CutoverAuthorizationConsumptionGuard.build(%{events: [allowed, stale, no_authorization, malformed]}, now: @now)

    assert summary.counts.allowed_count == 1
    assert summary.counts.stale_count == 1
    assert summary.counts.no_authorization_count == 1
    assert summary.counts.malformed_count == 1

    safe_text = inspect(summary, limit: :infinity, printable_limit: :infinity)
    refute safe_text =~ "Bearer"
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "/workspaces"
    refute safe_text =~ "full prompt"
  end

  defp build_authorization(project_id, mode) do
    projection = projection([project_id], acknowledgements?: mode != :manual_attention)
    [project] = projection.projects

    requested_operations =
      case mode do
        :unsupported -> ["unknown_op"]
        _mode -> ["writeback"]
      end

    audit = CutoverOperationAudit.build(audit_sources(projection), now: @now, requests: [cutover_request(project, project.cutover_gate, requested_operations: requested_operations)])
    history = CutoverAuditHistory.build(%{generated_at: @now, cutover_operation_audit: audit}, now: @now)

    permit_sources =
      case mode do
        :blocked ->
          projection
          |> permit_sources(audit, history)
          |> put_in([:hub_runtime, :writeback_executor], %{mode: "skeleton", provider_io: false})

        _mode ->
          permit_sources(projection, audit, history)
      end

    permit =
      permit_sources
      |> CutoverReadinessPermit.build(now: @now)
      |> maybe_malformed_permit(mode, project_id)

    operation_permit = permit.projects |> Enum.find(&(&1.project_id == project_id)) |> Map.fetch!(:permits) |> hd()

    request =
      case mode do
        :stale -> authorization_request(operation_permit, readiness_permit_fingerprint: "old-permit-fingerprint")
        _mode -> authorization_request(operation_permit)
      end

    CutoverExecutionAuthorization.build(authorization_sources(projection, permit), now: @now, requests: [request])
  end

  defp maybe_malformed_permit(permit, :malformed, project_id) do
    update_in(permit.projects, fn projects ->
      Enum.map(projects, fn
        %{project_id: ^project_id, permits: permits} = project ->
          %{project | status: "malformed", permits: Enum.map(permits, &%{&1 | decision: "malformed", reason_codes: ["cutover_readiness_permit_malformed"]})}

        project ->
          project
      end)
    end)
  end

  defp maybe_malformed_permit(permit, _mode, _project_id), do: permit

  defp only_record(ledger, project_id) do
    ledger.projects
    |> Enum.find(&(&1.project_id == project_id))
    |> Map.fetch!(:records)
    |> hd()
  end

  defp authorization_request(operation_permit, opts \\ []) do
    %{
      authorization_request_id: "auth-#{operation_permit.project_id}-#{operation_permit.operation}",
      project_id: operation_permit.project_id,
      provider_scope: operation_permit.provider_scope,
      operation: operation_permit.operation,
      cutover_operation_request_fingerprint: operation_permit.request.request_fingerprint,
      readiness_permit_fingerprint: Keyword.get(opts, :readiness_permit_fingerprint, operation_permit.permit_fingerprint),
      readiness_permit_decision: operation_permit.decision,
      activation_plan_fingerprint: operation_permit.activation_plan.fingerprint,
      operator_acknowledgement_fingerprint: operation_permit.operator_acknowledgement.fingerprint,
      cutover_gate_decision: operation_permit.cutover_gate.decision,
      cutover_gate_fingerprint: operation_permit.cutover_gate.fingerprint,
      dry_run_audit_fingerprint: operation_permit.evidence_fingerprints.dry_run_audit,
      audit_history_fingerprint: operation_permit.evidence_fingerprints.audit_history,
      evidence_fingerprints: %{runtime_modes: operation_permit.evidence_fingerprints.runtime_modes},
      executor_modes: operation_permit.executor_modes,
      skeleton_mode: operation_permit.executor_modes.skeleton_mode,
      dry_run_mode: operation_permit.executor_modes.dry_run_mode,
      unsupported_mode: operation_permit.executor_modes.unsupported_mode,
      source: Keyword.get(opts, :source, "operator-file"),
      requested_at: "2026-07-01T08:05:00Z",
      operator_intent: %{
        action_codes: ["authorize_explicit_execution"],
        risk_codes: ["no_side_effects"],
        note: "Authorization: Bearer ghp_secret full prompt /workspaces should not leak"
      }
    }
  end

  defp authorization_sources(projection, permit) do
    %{
      generated_at: @now,
      hub_runtime: projection.overview.hub_runtime,
      projects: projection.projects,
      cutover_readiness_permit: permit
    }
  end

  defp permit_sources(projection, audit, history) do
    %{
      generated_at: @now,
      hub_runtime: projection.overview.hub_runtime,
      projects: projection.projects,
      activation_plan: projection.activation_plan,
      cutover_gate: projection.cutover_gate,
      cutover_operation_audit: audit,
      cutover_audit_history: history
    }
  end

  defp audit_sources(projection) do
    %{
      generated_at: @now,
      hub_runtime: projection.overview.hub_runtime,
      projects: projection.projects,
      migration_readiness: projection.migration_readiness,
      activation_plan: projection.activation_plan,
      activation_preflight: sources(["alpha"]).activation_preflight,
      cutover_gate: projection.cutover_gate
    }
  end

  defp projection(project_ids, opts) do
    acknowledgements =
      if Keyword.get(opts, :acknowledgements?, false) do
        Enum.map(project_ids, &ack(plan_id(&1), &1))
      else
        []
      end

    DeviceObservability.build(sources(project_ids),
      now: @now,
      operator_acknowledgements: acknowledgements
    )
  end

  defp cutover_request(project, gate, opts) do
    %{
      request_id: "req-#{Keyword.get(opts, :project_id, project.project_id)}",
      project_id: Keyword.get(opts, :project_id, project.project_id),
      provider_scope: %{
        kind: project.provider.kind,
        provider_scope_key: project.provider.provider_scope_key
      },
      requested_operations: Keyword.fetch!(opts, :requested_operations),
      activation_plan_id: Keyword.get(opts, :activation_plan_id, project.activation_plan.plan_id),
      activation_plan_fingerprint: Keyword.get(opts, :activation_plan_fingerprint, Map.get(project.activation_plan, :fingerprint) || project.activation_plan.plan_id),
      cutover_gate_decision: Keyword.get(opts, :cutover_gate_decision, gate.decision),
      cutover_gate_fingerprint: Keyword.get(opts, :cutover_gate_fingerprint, gate_fingerprint(gate)),
      staged_ownership_record_id: Keyword.get(opts, :staged_ownership_record_id, gate.staged_ownership_record && gate.staged_ownership_record.record_id),
      source: Keyword.get(opts, :source, "operator-file"),
      requested_at: "2026-07-01T08:01:00Z",
      operator_intent: %{
        action_codes: ["run_read_only_dry_run"],
        risk_codes: ["no_side_effects"],
        note: "Authorization: Bearer ghp_secret should not leak"
      },
      safe_project_snapshot: %{
        migration_state: project.migration_state,
        status: project.status,
        provider_scope_key: project.provider.provider_scope_key,
        config_fingerprint: project.detail.config.config_fingerprint
      }
    }
  end

  defp ack(plan_id, project_id) do
    %{
      project_id: project_id,
      plan_id: plan_id,
      source: "operator-file",
      created_at: "2026-07-01T08:00:30Z",
      acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
    }
  end

  defp plan_id(project_id) do
    sources([project_id])
    |> DeviceObservability.build(now: @now)
    |> Map.get(:projects)
    |> hd()
    |> get_in([:activation_plan, :plan_id])
  end

  defp gate_fingerprint(%{staged_ownership_record: %{record_id: record_id}}) when is_binary(record_id), do: record_id
  defp gate_fingerprint(%{safe_evidence: %{fingerprint: fingerprint}}) when is_binary(fingerprint), do: fingerprint
  defp gate_fingerprint(_gate), do: nil

  defp sources(project_ids) do
    %{
      hub_runtime: %{
        mode: "hub",
        read_only: false,
        scheduler_enabled: true,
        scheduler_status: "scheduled",
        provider_executor: %{mode: "real_candidate_scan", provider_io: true, supported_operations: ["candidate_scan"]},
        writeback_executor: %{
          mode: "real_writeback",
          provider_io: true,
          supported_operations: ["stage_writeback", "comment_workpad_upsert"],
          supported_logical_actions: ["status_set", "workpad_upsert", "label_add"]
        },
        worker_starter: %{mode: "real_worker_starter", worker_start: true},
        activation_probe: %{mode: "host_service", source: "host_service_probe", host_service_probe: true}
      },
      registry: %{
        projects:
          Enum.map(project_ids, fn project_id ->
            %{
              project_id: project_id,
              name: String.capitalize(project_id),
              status: :ready,
              dispatch_enabled: true,
              migration_state: "hub_managed",
              tracker_summary: %{
                kind: "github",
                provider_scope_key: "github:owner/#{project_id}",
                provider_scope: %{owner: "owner", repo: project_id, token: "$GITHUB_TOKEN"}
              },
              runtime_summary: %{workspace_root: "/workspaces/#{project_id}"},
              fingerprint: "fingerprint-#{project_id}",
              snapshot_version: "1"
            }
          end),
        warnings: [],
        errors: []
      },
      poll_coordination: %{
        projects:
          Enum.map(project_ids, fn project_id ->
            %{project_id: project_id, allow_poll: true, eligibility: %{reason: "ready"}, provider_scope_key: "github:owner/#{project_id}"}
          end)
      },
      activation_preflight: %{
        projects:
          Enum.map(project_ids, fn project_id ->
            %{
              project_id: project_id,
              status: "safe_to_manage",
              safe_to_manage: true,
              reason: "hub_managed_no_conflict",
              checked_at: "2026-07-01T08:00:00Z",
              probe_source: "host_service_probe",
              blocked_operations: [],
              detected_legacy_ownership: [],
              unknown_probe_results: []
            }
          end)
      },
      scheduler: %{enabled: true, status: "scheduled"},
      runtime_ledger: %{projects: []}
    }
  end
end
