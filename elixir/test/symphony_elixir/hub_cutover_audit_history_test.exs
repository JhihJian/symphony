defmodule SymphonyElixir.HubCutoverAuditHistoryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{CutoverAuditHistory, CutoverOperationAudit, DeviceObservability}

  @now ~U[2026-06-30 11:00:00Z]

  test "builds bounded audit history from dry-run audit without side effects or secret leakage" do
    parent = self()
    projection = projection(["alpha"], acknowledgements?: false)
    [project] = projection.projects

    audit =
      CutoverOperationAudit.build(
        audit_sources(projection),
        now: @now,
        requests: [
          request(project, project.cutover_gate,
            requested_operations: ["poll", "dispatch"],
            note: "Authorization: Bearer ghp_secret should only be digested"
          )
        ],
        provider_executor: fn _request, _opts -> send(parent, :provider_called) end,
        worker_starter: fn _request, _opts -> send(parent, :worker_started) end
      )

    history =
      CutoverAuditHistory.build(
        %{
          generated_at: @now,
          cutover_operation_audit: audit
        },
        now: @now,
        history_limit: 1,
        project_history_limit: 1
      )

    assert history.status == "unresolved_manual_attention"
    assert history.counts.history_entry_count == 1
    assert history.counts.unresolved_manual_attention_count >= 1
    assert history.dry_run_only == true
    assert history.no_side_effects == true
    assert history.limits.max_history_entries == 1

    [history_project] = history.projects
    assert history_project.project_id == "alpha"
    assert history_project.latest_audit.request_fingerprint != nil
    assert Enum.all?(history_project.history_entries, &(&1.dry_run_only == true and &1.no_side_effects == true))
    assert history_project.unresolved_manual_attention != []

    refute_received :provider_called
    refute_received :worker_started

    safe_text = inspect(history)
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "Bearer"
    refute safe_text =~ "Authorization"
    refute safe_text =~ "/workspaces"
  end

  test "matching closeout closes only the bound unresolved manual attention item" do
    projection = projection(["alpha"], acknowledgements?: false)
    [project] = projection.projects

    audit =
      CutoverOperationAudit.build(audit_sources(projection),
        now: @now,
        requests: [request(project, project.cutover_gate, requested_operations: ["poll"])]
      )

    base = CutoverAuditHistory.build(%{generated_at: @now, cutover_operation_audit: audit}, now: @now)
    [base_project] = base.projects
    item = hd(base_project.unresolved_manual_attention)

    history =
      CutoverAuditHistory.build(
        %{
          generated_at: @now,
          cutover_operation_audit: audit,
          manual_attention_closeouts: [
            closeout(item, decision: "accepted_risk", note: "full prompt and token must not leak")
          ]
        },
        now: @now
      )

    [history_project] = history.projects
    assert history.status == "closed"
    assert history.counts.closed_count == 1
    assert history.counts.unresolved_manual_attention_count == 0
    assert history_project.status == "closed"
    assert history_project.counts.closed_count == 1
    assert history_project.unresolved_manual_attention == []
    assert [%{status: "closed", decision: "accepted_risk"}] = history_project.closeouts

    safe_text = inspect(history)
    refute safe_text =~ "full prompt"
    refute safe_text =~ "token"
  end

  test "stale conflict malformed and unsupported closeouts never clear unresolved manual attention" do
    projection = projection(["alpha", "beta", "gamma", "delta"], acknowledgements?: false)
    projects = Map.new(projection.projects, &{&1.project_id, &1})

    audit =
      CutoverOperationAudit.build(audit_sources(projection),
        now: @now,
        requests: [
          request(projects["alpha"], projects["alpha"].cutover_gate, requested_operations: ["poll"]),
          request(projects["beta"], projects["beta"].cutover_gate, requested_operations: ["dispatch"]),
          request(projects["gamma"], projects["gamma"].cutover_gate, requested_operations: ["worker_start"]),
          request(projects["delta"], projects["delta"].cutover_gate, requested_operations: ["writeback"])
        ]
      )

    base = CutoverAuditHistory.build(%{generated_at: @now, cutover_operation_audit: audit}, now: @now)
    items = base.projects |> Enum.map(&{&1.project_id, hd(&1.unresolved_manual_attention)}) |> Map.new()

    history =
      CutoverAuditHistory.build(
        %{
          generated_at: @now,
          cutover_operation_audit: audit,
          manual_attention_closeouts: [
            closeout(items["alpha"], request_fingerprint: "old-request-fingerprint"),
            closeout(items["beta"], reason_code: "different_reason"),
            closeout(items["gamma"], evidence_fingerprint: nil),
            closeout(items["delta"], decision: "not_a_supported_decision")
          ]
        },
        now: @now
      )

    closeouts = Map.new(history.closeouts, &{&1.project_id, &1.status})
    assert closeouts["alpha"] == "stale"
    assert closeouts["beta"] == "conflict"
    assert closeouts["gamma"] == "malformed"
    assert closeouts["delta"] == "unsupported"
    assert history.counts.unresolved_manual_attention_count >= 4

    projects_by_id = Map.new(history.projects, &{&1.project_id, &1})
    assert projects_by_id["alpha"].counts.unresolved_manual_attention_count >= 1
    assert projects_by_id["beta"].counts.unresolved_manual_attention_count >= 1
    assert projects_by_id["gamma"].counts.unresolved_manual_attention_count >= 1
    assert projects_by_id["delta"].counts.unresolved_manual_attention_count >= 1
  end

  test "device projection embeds cutover audit history and no-history projects" do
    projection =
      projection(["alpha", "beta"], acknowledgements?: true)

    alpha = Enum.find(projection.projects, &(&1.project_id == "alpha"))

    audit =
      CutoverOperationAudit.build(audit_sources(projection),
        now: @now,
        requests: [request(alpha, alpha.cutover_gate, requested_operations: ["writeback"])]
      )

    history = CutoverAuditHistory.build(%{generated_at: @now, cutover_operation_audit: audit}, now: @now)

    projected =
      DeviceObservability.to_snapshot(%{
        projection
        | cutover_operation_audit: audit,
          cutover_audit_history: history
      })

    projects = Map.new(projected.projects, &{&1.project_id, &1})
    assert projected.cutover_audit_history.counts.history_entry_count == 1
    assert projected.overview.cutover_audit_history.history_entry_count == 1
    assert projects["alpha"].cutover_audit_history.status == "history_ready"
    assert projects["alpha"].cutover_audit_history.latest_audit.request_id == "req-alpha"
    assert projects["beta"].cutover_audit_history.status == "no_history"
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
      requested_at: "2026-06-30T11:01:00Z",
      operator_intent: %{
        action_codes: ["run_read_only_dry_run"],
        risk_codes: ["no_side_effects"],
        note: Keyword.get(opts, :note, "dry-run only")
      },
      safe_project_snapshot: %{
        migration_state: project.migration_state,
        status: project.status,
        provider_scope_key: project.provider.provider_scope_key,
        config_fingerprint: project.detail.config.config_fingerprint
      }
    }
  end

  defp closeout(item, opts) do
    %{
      project_id: item.project_id,
      request_fingerprint: Keyword.get(opts, :request_fingerprint, item.request_fingerprint),
      activation_plan_fingerprint: Keyword.get(opts, :activation_plan_fingerprint, item.activation_plan_fingerprint),
      cutover_gate_fingerprint: Keyword.get(opts, :cutover_gate_fingerprint, item.cutover_gate_fingerprint),
      evidence_fingerprint: Keyword.get(opts, :evidence_fingerprint, item.evidence_fingerprint),
      operation: Keyword.get(opts, :operation, item.operation),
      reason_code: Keyword.get(opts, :reason_code, item.reason_code),
      required_operator_action_code: Keyword.get(opts, :required_operator_action_code, item.required_operator_action_code),
      decision: Keyword.get(opts, :decision, "accepted_risk"),
      source: Keyword.get(opts, :source, "operator-file"),
      decided_at: "2026-06-30T11:02:00Z",
      operator_note: Keyword.get(opts, :note, "operator closeout")
    }
  end

  defp gate_fingerprint(%{staged_ownership_record: %{record_id: record_id}}) when is_binary(record_id), do: record_id
  defp gate_fingerprint(%{safe_evidence: %{fingerprint: fingerprint}}) when is_binary(fingerprint), do: fingerprint
  defp gate_fingerprint(gate), do: gate.decision

  defp plan_id(project_id) do
    sources([project_id])
    |> DeviceObservability.build(now: @now)
    |> Map.get(:projects)
    |> hd()
    |> get_in([:activation_plan, :plan_id])
  end

  defp ack(plan_id, project_id) do
    %{
      project_id: project_id,
      plan_id: plan_id,
      source: "operator-file",
      created_at: "2026-06-30T11:00:30Z",
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
              checked_at: "2026-06-30T11:00:00Z",
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
