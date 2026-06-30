defmodule SymphonyElixir.HubCutoverReadinessPermitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{CutoverAuditHistory, CutoverOperationAudit, CutoverReadinessPermit, DeviceObservability}

  @now ~U[2026-06-30 12:00:00Z]

  test "builds ready execution consideration permits from current safe cutover evidence without side effects" do
    parent = self()
    projection = projection(["alpha"], acknowledgements?: true)
    [project] = projection.projects
    request = request(project, project.cutover_gate, requested_operations: ["poll", "dispatch", "worker_start", "writeback"])
    audit = CutoverOperationAudit.build(audit_sources(projection), now: @now, requests: [request])
    history = CutoverAuditHistory.build(%{generated_at: @now, cutover_operation_audit: audit}, now: @now)

    permit =
      CutoverReadinessPermit.build(
        permit_sources(projection, audit, history),
        now: @now,
        provider_executor: fn _request, _opts -> send(parent, :provider_called) end,
        worker_starter: fn _request, _opts -> send(parent, :worker_started) end
      )

    assert permit.status == "ready_for_execution_consideration"
    assert permit.counts.permit_count == 4
    assert permit.counts.ready_count == 4
    assert permit.dry_run_only == true
    assert permit.no_side_effects == true

    [permit_project] = permit.projects
    assert permit_project.status == "ready_for_execution_consideration"
    assert permit_project.request.request_fingerprint == hd(audit.projects).request.request_fingerprint
    assert Enum.map(permit_project.permits, & &1.operation) == ["dispatch", "poll", "worker_start", "writeback"]
    assert Enum.all?(permit_project.permits, &(&1.decision == "ready_for_execution_consideration"))
    assert Enum.all?(permit_project.permits, &(&1.permit_fingerprint != nil))
    assert Enum.all?(permit_project.permits, &(&1.dry_run_only == true and &1.no_side_effects == true))

    writeback = Enum.find(permit_project.permits, &(&1.operation == "writeback"))
    assert writeback.request.request_fingerprint == hd(audit.projects).request.request_fingerprint
    assert writeback.activation_plan.plan_id == project.activation_plan.plan_id
    assert writeback.operator_acknowledgement.status == "accepted"
    assert writeback.cutover_gate.decision == "allowed"
    assert writeback.dry_run_audit.operation_decision == "would_allow"
    assert writeback.audit_history.status == "history_ready"
    assert writeback.evidence_fingerprints.permit_input != nil

    refute_received :provider_called
    refute_received :worker_started

    safe_text = inspect(permit, limit: :infinity, printable_limit: :infinity)
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "Bearer"
    refute safe_text =~ "Authorization"
    refute safe_text =~ "/workspaces"
  end

  test "blocked stale manual unsupported and malformed inputs never become ready" do
    projection =
      projection(["blocked", "stale", "manual", "unsupported", "malformed"],
        acknowledgements?: true
      )

    projects = Map.new(projection.projects, &{&1.project_id, &1})

    stale_request = request(projects["stale"], projects["stale"].cutover_gate, requested_operations: ["poll"])
    unsupported_request = request(projects["unsupported"], projects["unsupported"].cutover_gate, requested_operations: ["unknown_op"])
    malformed_request = request(projects["malformed"], projects["malformed"].cutover_gate, requested_operations: ["worker_start"])

    blocked_projection = projection(["blocked"], acknowledgements?: true)
    blocked_project = hd(blocked_projection.projects)

    blocked_audit =
      CutoverOperationAudit.build(audit_sources(blocked_projection),
        now: @now,
        requests: [request(blocked_project, blocked_project.cutover_gate, requested_operations: ["writeback"])]
      )

    blocked_history = CutoverAuditHistory.build(%{generated_at: @now, cutover_operation_audit: blocked_audit}, now: @now)

    stale_audit =
      CutoverOperationAudit.build(audit_sources(projection),
        now: @now,
        requests: [%{stale_request | cutover_gate_fingerprint: "old-gate-fingerprint"}]
      )

    manual_projection = projection(["manual"], acknowledgements?: false)
    manual_project = hd(manual_projection.projects)

    manual_audit =
      CutoverOperationAudit.build(audit_sources(manual_projection),
        now: @now,
        requests: [request(manual_project, manual_project.cutover_gate, requested_operations: ["dispatch"])]
      )

    manual_history = CutoverAuditHistory.build(%{generated_at: @now, cutover_operation_audit: manual_audit}, now: @now)

    unsupported_audit =
      CutoverOperationAudit.build(audit_sources(projection), now: @now, requests: [unsupported_request])

    malformed_audit =
      CutoverOperationAudit.build(audit_sources(projection),
        now: @now,
        requests: [malformed_request]
      )

    stale_history = CutoverAuditHistory.build(%{generated_at: @now, cutover_operation_audit: stale_audit}, now: @now)
    unsupported_history = CutoverAuditHistory.build(%{generated_at: @now, cutover_operation_audit: unsupported_audit}, now: @now)

    malformed_history =
      CutoverAuditHistory.build(
        %{
          generated_at: @now,
          cutover_operation_audit: malformed_audit,
          manual_attention_closeouts: [
            %{project_id: "malformed", operation: "worker_start", decision: "accepted_risk", source: "operator-file"}
          ]
        },
        now: @now
      )

    blocked_sources =
      blocked_projection
      |> permit_sources(blocked_audit, blocked_history)
      |> put_in([:hub_runtime, :writeback_executor], %{mode: "skeleton", provider_io: false})

    blocked_permit = CutoverReadinessPermit.build(blocked_sources, now: @now)
    stale_permit = CutoverReadinessPermit.build(permit_sources(projection, stale_audit, stale_history), now: @now)
    manual_permit = CutoverReadinessPermit.build(permit_sources(manual_projection, manual_audit, manual_history), now: @now)
    unsupported_permit = CutoverReadinessPermit.build(permit_sources(projection, unsupported_audit, unsupported_history), now: @now)
    malformed_permit = CutoverReadinessPermit.build(permit_sources(projection, malformed_audit, malformed_history), now: @now)

    assert only_permit(blocked_permit, "blocked").decision == "blocked"
    assert "executor_starter_mode_incompatible" in only_permit(blocked_permit, "blocked").reason_codes

    assert only_permit(stale_permit, "stale").decision == "stale"
    assert Enum.any?(only_permit(stale_permit, "stale").reason_codes, &String.contains?(&1, "mismatch"))

    assert only_permit(manual_permit, "manual").decision == "manual_attention"
    assert "manual_attention_unresolved" in only_permit(manual_permit, "manual").reason_codes

    assert only_permit(unsupported_permit, "unsupported").decision == "unsupported"
    assert "unknown_operation" in only_permit(unsupported_permit, "unsupported").reason_codes

    assert only_permit(malformed_permit, "malformed").decision == "malformed"
    assert "cutover_audit_history_malformed" in only_permit(malformed_permit, "malformed").reason_codes
  end

  test "device projection embeds permit summary and isolates malformed project input" do
    projection = projection(["alpha", "beta"], acknowledgements?: true)
    alpha = Enum.find(projection.projects, &(&1.project_id == "alpha"))
    audit = CutoverOperationAudit.build(audit_sources(projection), now: @now, requests: [request(alpha, alpha.cutover_gate, requested_operations: ["poll"])])
    history = CutoverAuditHistory.build(%{generated_at: @now, cutover_operation_audit: audit}, now: @now)

    permit = CutoverReadinessPermit.build(permit_sources(projection, audit, history), now: @now)

    projected =
      DeviceObservability.to_snapshot(%{
        projection
        | cutover_operation_audit: audit,
          cutover_audit_history: history,
          cutover_readiness_permit: permit
      })

    projects = Map.new(projected.projects, &{&1.project_id, &1})

    assert projected.cutover_readiness_permit.counts.permit_count == 1
    assert projected.overview.cutover_readiness_permit.permit_count == 1
    assert projects["alpha"].cutover_readiness_permit.status == "ready_for_execution_consideration"
    assert projects["beta"].cutover_readiness_permit.status == "no_request"
    assert Enum.any?(projected.cutover_readiness_permit.projects, &(&1.status == "no_request"))

    malformed = CutoverReadinessPermit.to_snapshot(%{generated_at: @now, projects: ["not-a-project-map", hd(permit.projects)]})
    assert Enum.any?(malformed.projects, &(&1.project_id == "" and &1.status == "no_request"))
    assert Enum.any?(malformed.projects, &(&1.project_id == "alpha" and &1.status == "ready_for_execution_consideration"))
  end

  defp only_permit(permit, project_id) do
    permit.projects
    |> Enum.find(&(&1.project_id == project_id))
    |> Map.fetch!(:permits)
    |> hd()
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
      hub_runtime: sources(["alpha"]).hub_runtime,
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

  defp request(project, gate, opts) do
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
      requested_at: "2026-06-30T12:01:00Z",
      operator_intent: %{
        action_codes: ["run_read_only_dry_run"],
        risk_codes: ["no_side_effects"],
        note: Keyword.get(opts, :note, "Authorization: Bearer ghp_secret should not leak")
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
      created_at: "2026-06-30T12:00:30Z",
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
              checked_at: "2026-06-30T12:00:00Z",
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
