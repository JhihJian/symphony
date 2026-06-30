defmodule SymphonyElixir.HubCutoverOperationAuditTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{CutoverOperationAudit, DeviceObservability}

  @now ~U[2026-06-30 10:00:00Z]

  test "builds a dry-run ready audit for an explicit request without executing side effects" do
    parent = self()

    projection =
      DeviceObservability.build(sources(["alpha"]),
        now: @now,
        operator_acknowledgements: [ack(plan_id("alpha"))]
      )

    [project] = projection.projects
    gate = project.cutover_gate

    audit =
      CutoverOperationAudit.build(
        %{
          generated_at: @now,
          hub_runtime: sources(["alpha"]).hub_runtime,
          projects: projection.projects,
          migration_readiness: projection.migration_readiness,
          activation_plan: projection.activation_plan,
          activation_preflight: sources(["alpha"]).activation_preflight,
          cutover_gate: projection.cutover_gate
        },
        now: @now,
        requests: [
          request(project, gate,
            requested_operations: ["poll", "dispatch", "worker_start", "writeback"],
            note: "Authorization: Bearer ghp_secret should only become a digest"
          )
        ],
        provider_executor: fn _request, _opts -> send(parent, :provider_called) end,
        worker_starter: fn _request, _opts -> send(parent, :worker_started) end
      )

    assert audit.status == "dry_run_ready"
    assert audit.counts.request_count == 1
    assert audit.counts.dry_run_ready_count == 1

    [audit_project] = audit.projects
    assert audit_project.status == "dry_run_ready"
    assert audit_project.request.project_id == "alpha"
    assert audit_project.request.request_fingerprint != nil
    assert audit_project.request.operator_intent.note_digest.bytes > 0
    assert audit_project.requested_operations == ["poll", "dispatch", "worker_start", "writeback"]
    assert Enum.all?(audit_project.operation_results, &(&1.decision == "would_allow"))
    assert Enum.all?(audit_project.operation_results, &(&1.dry_run_only == true))
    assert audit_project.safe_evidence.cutover_gate.staged_ownership_record_id == gate.staged_ownership_record.record_id

    refute_received :provider_called
    refute_received :worker_started

    safe_text = inspect(audit)
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "Bearer"
    refute safe_text =~ "Authorization"
    refute safe_text =~ "/workspaces"
  end

  test "request cannot override a blocking cutover gate" do
    projection = DeviceObservability.build(sources(["alpha"]), now: @now)
    [project] = projection.projects

    audit =
      CutoverOperationAudit.build(
        audit_sources(projection),
        now: @now,
        requests: [
          request(project, project.cutover_gate,
            requested_operations: ["poll", "dispatch"],
            activation_plan_id: project.activation_plan.plan_id
          )
        ]
      )

    [audit_project] = audit.projects
    assert audit_project.status == "blocked"
    assert audit_project.reason_codes == ["cutover_gate_blocked", "operator_acknowledgement_missing"]
    assert Enum.all?(audit_project.operation_results, &(&1.decision == "would_block"))
    assert Enum.any?(audit_project.operation_results, &("operator_acknowledgement_missing" in &1.reason_codes))
  end

  test "malformed stale unsupported and unknown requests are not optimistic" do
    project_ids = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"]

    projection =
      DeviceObservability.build(sources(project_ids),
        now: @now,
        operator_acknowledgements: Enum.map(project_ids, &ack(plan_id(&1), &1))
      )

    projects_by_id = Map.new(projection.projects, &{&1.project_id, &1})

    audit =
      CutoverOperationAudit.build(
        audit_sources(projection),
        now: @now,
        requests: [
          request(projects_by_id["alpha"], projects_by_id["alpha"].cutover_gate,
            project_id: "alpha",
            requested_operations: ["poll"],
            activation_plan_id: "old-plan"
          ),
          request(projects_by_id["beta"], projects_by_id["beta"].cutover_gate,
            project_id: "unknown-project",
            requested_operations: ["poll"]
          ),
          request(projects_by_id["gamma"], projects_by_id["gamma"].cutover_gate, project_id: "gamma", requested_operations: ["unknown_op"]),
          request(projects_by_id["delta"], projects_by_id["delta"].cutover_gate,
            project_id: "delta",
            source: "raw-prompt",
            requested_operations: ["poll"]
          ),
          request(projects_by_id["epsilon"], projects_by_id["epsilon"].cutover_gate,
            project_id: "epsilon",
            requested_operations: ["dispatch"],
            cutover_gate_fingerprint: "stale-gate-fingerprint"
          ),
          request(projects_by_id["zeta"], projects_by_id["zeta"].cutover_gate,
            project_id: "zeta",
            requested_operations: ["writeback"],
            safe_project_snapshot: false
          )
        ]
      )

    projects = Map.new(audit.projects, &{&1.project_id, &1})

    assert projects["alpha"].status == "manual_attention"
    assert "activation_plan_mismatch" in projects["alpha"].reason_codes
    assert projects["unknown-project"].status == "blocked"
    assert "unknown_project" in projects["unknown-project"].reason_codes
    assert projects["gamma"].status == "unsupported"
    assert "unknown_operation" in projects["gamma"].reason_codes
    assert projects["delta"].status == "unsupported"
    assert "unsupported_source" in projects["delta"].reason_codes
    assert projects["epsilon"].status == "manual_attention"
    assert "cutover_gate_mismatch" in projects["epsilon"].reason_codes
    assert projects["zeta"].status == "blocked"
    assert "safe_project_snapshot_missing" in projects["zeta"].reason_codes
    assert audit.counts.request_count == 6
    assert audit.counts.manual_attention_count == 2
    assert audit.counts.unsupported_count == 2
    assert audit.counts.blocked_count >= 2
  end

  test "device projection embeds no-request and explicit request summaries" do
    projection =
      DeviceObservability.build(
        Map.merge(sources(["alpha", "beta"]), %{}),
        now: @now,
        operator_acknowledgements: [ack(plan_id("alpha"), "alpha"), ack(plan_id("beta"), "beta")]
      )

    alpha = Enum.find(projection.projects, &(&1.project_id == "alpha"))

    audit =
      CutoverOperationAudit.build(audit_sources(projection),
        now: @now,
        requests: [request(alpha, alpha.cutover_gate, requested_operations: ["dispatch"])]
      )

    projected =
      DeviceObservability.to_snapshot(%{
        projection
        | cutover_operation_audit: audit
      })

    projects = Map.new(projected.projects, &{&1.project_id, &1})
    assert projected.cutover_operation_audit.counts.request_count == 1
    assert projected.overview.cutover_operation_audit.request_count == 1
    assert projects["alpha"].cutover_operation_audit.status == "dry_run_ready"
    assert projects["beta"].cutover_operation_audit.status == "no_request"
    assert projects["beta"].cutover_operation_audit.request == nil
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

  defp request(project, gate, opts) do
    %{
      request_id: Keyword.get(opts, :request_id, "req-#{Keyword.get(opts, :project_id, project.project_id)}"),
      project_id: Keyword.get(opts, :project_id, project.project_id),
      provider_scope: %{
        kind: project.provider.kind,
        provider_scope_key: project.provider.provider_scope_key
      },
      requested_operations: Keyword.fetch!(opts, :requested_operations),
      activation_plan_id: Keyword.get(opts, :activation_plan_id, project.activation_plan.plan_id),
      activation_plan_fingerprint: Keyword.get(opts, :activation_plan_fingerprint, Map.get(project.activation_plan, :fingerprint) || project.activation_plan.plan_id),
      cutover_gate_decision: Keyword.get(opts, :cutover_gate_decision, gate.decision),
      cutover_gate_fingerprint: Keyword.get(opts, :cutover_gate_fingerprint, gate.staged_ownership_record && gate.staged_ownership_record.record_id),
      staged_ownership_record_id: Keyword.get(opts, :staged_ownership_record_id, gate.staged_ownership_record && gate.staged_ownership_record.record_id),
      source: Keyword.get(opts, :source, "operator-file"),
      requested_at: "2026-06-30T10:01:00Z",
      operator_intent: %{
        action_codes: ["run_read_only_dry_run"],
        risk_codes: ["no_side_effects"],
        note: Keyword.get(opts, :note, "dry-run only")
      },
      safe_project_snapshot:
        if Keyword.get(opts, :safe_project_snapshot, true) do
          %{
            migration_state: project.migration_state,
            status: project.status,
            provider_scope_key: project.provider.provider_scope_key,
            config_fingerprint: project.detail.config.config_fingerprint
          }
        else
          %{}
        end
    }
  end

  defp plan_id(project_id) do
    sources([project_id])
    |> DeviceObservability.build(now: @now)
    |> Map.get(:projects)
    |> hd()
    |> get_in([:activation_plan, :plan_id])
  end

  defp ack(plan_id, project_id \\ "alpha") do
    %{
      project_id: project_id,
      plan_id: plan_id,
      source: "operator-file",
      created_at: "2026-06-30T10:00:30Z",
      acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
    }
  end

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
              checked_at: "2026-06-30T10:00:00Z",
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
