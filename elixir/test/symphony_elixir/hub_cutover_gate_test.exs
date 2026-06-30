defmodule SymphonyElixir.HubCutoverGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{CutoverGate, DeviceObservability}

  @now ~U[2026-06-30 09:00:00Z]

  test "allows staged operations and emits a stable staged ownership record when all gates pass" do
    base = DeviceObservability.build(sources("hub_managed"), now: @now)
    plan_id = base.projects |> hd() |> get_in([:activation_plan, :plan_id])

    projection =
      DeviceObservability.build(
        sources("hub_managed"),
        now: @now,
        operator_acknowledgements: [ack(plan_id)]
      )

    assert [project] = projection.projects
    assert project.cutover_gate.decision == "allowed"
    assert project.cutover_gate.allowed_operations == ["dispatch", "poll", "worker_start", "writeback"]
    assert project.cutover_gate.blocked_operations == []
    assert project.cutover_gate.staged_ownership_record.record_id != nil
    assert project.cutover_gate.staged_ownership_record.plan_id == plan_id
    assert project.cutover_gate.staged_ownership_record.note == "read_only_audit_record_no_external_state_change"
    assert projection.cutover_gate.counts.allowed_count == 1
    assert projection.cutover_gate.counts.staged_ownership_record_count == 1
    assert projection.overview.cutover_gate.allowed_count == 1
    assert CutoverGate.block_reason(projection.cutover_gate, "alpha", :poll) == nil

    safe_text = inspect(projection.cutover_gate)
    refute safe_text =~ "GITHUB_TOKEN"
    refute safe_text =~ "/workspaces/alpha"
  end

  test "blocks missing stale malformed preflight and executor mismatch without reusing records" do
    base = DeviceObservability.build(sources("hub_managed"), now: @now)
    plan_id = base.projects |> hd() |> get_in([:activation_plan, :plan_id])

    missing = DeviceObservability.build(sources("hub_managed"), now: @now)
    [project] = missing.projects
    assert project.cutover_gate.decision == "blocked"
    assert reason_codes(project.cutover_gate) |> Enum.member?("operator_acknowledgement_missing")
    assert project.cutover_gate.allowed_operations == []
    assert project.cutover_gate.staged_ownership_record == nil

    stale = DeviceObservability.build(sources("hub_managed"), now: @now, operator_acknowledgements: [ack("old-plan")])
    [project] = stale.projects
    assert project.cutover_gate.decision == "blocked"
    assert reason_codes(project.cutover_gate) |> Enum.member?("operator_acknowledgement_stale")

    malformed =
      DeviceObservability.build(sources("hub_managed"),
        now: @now,
        operator_acknowledgements: [%{project_id: "alpha", plan_id: plan_id}]
      )

    [project] = malformed.projects
    assert project.cutover_gate.decision == "manual_attention"
    assert reason_codes(project.cutover_gate) |> Enum.member?("operator_acknowledgement_malformed")

    preflight =
      DeviceObservability.build(
        put_in(sources("hub_managed"), [:activation_preflight, :projects, Access.at(0), :status], "unknown_manual_attention"),
        now: @now,
        operator_acknowledgements: [ack(plan_id)]
      )

    [project] = preflight.projects
    assert project.cutover_gate.decision == "manual_attention"
    assert reason_codes(project.cutover_gate) |> Enum.member?("activation_preflight_unknown")

    skeleton =
      DeviceObservability.build(
        put_in(sources("hub_managed"), [:hub_runtime, :provider_executor], %{mode: "skeleton", provider_io: false}),
        now: @now,
        operator_acknowledgements: [
          ack(
            DeviceObservability.build(
              put_in(sources("hub_managed"), [:hub_runtime, :provider_executor], %{mode: "skeleton", provider_io: false}),
              now: @now
            )
            |> then(fn projection -> projection.projects |> hd() |> get_in([:activation_plan, :plan_id]) end)
          )
        ]
      )

    [project] = skeleton.projects
    assert project.cutover_gate.decision == "staged_ready"
    assert project.cutover_gate.allowed_operations == ["dispatch", "worker_start", "writeback"]
    assert "poll" in project.cutover_gate.blocked_operations
    assert reason_codes(project.cutover_gate) |> Enum.member?("provider_executor_candidate_scan_not_real")
  end

  test "manual attention for one project stays isolated from another allowed project" do
    base = DeviceObservability.build(sources("hub_managed", ["alpha", "beta"]), now: @now)
    plans = Map.new(base.projects, &{&1.project_id, &1.activation_plan.plan_id})

    sources =
      sources("hub_managed", ["alpha", "beta"])
      |> put_in([:activation_preflight, :projects, Access.at(0), :status], "unknown_manual_attention")

    projection =
      DeviceObservability.build(sources,
        now: @now,
        operator_acknowledgements: [ack(plans["alpha"], "alpha"), ack(plans["beta"], "beta")]
      )

    projects = Map.new(projection.projects, &{&1.project_id, &1})
    assert projects["alpha"].cutover_gate.decision == "manual_attention"
    assert projects["beta"].cutover_gate.decision == "allowed"
    assert projects["beta"].cutover_gate.allowed_operations == ["dispatch", "poll", "worker_start", "writeback"]
    assert projection.cutover_gate.counts.allowed_count == 1
    assert projection.cutover_gate.counts.manual_attention_count == 1
  end

  test "fallback snapshots are safe and non misleading" do
    snapshot = CutoverGate.to_snapshot(%{projects: [%{project_id: "legacy", migration_state: "legacy_only"}]})

    assert snapshot.status == "not_applicable"
    assert [project] = snapshot.projects
    assert project.decision == "not_applicable"
    assert project.allowed_operations == []
    assert project.staged_ownership_record == nil

    assert %{status: "blocked", blocked_operations: blocked} =
             CutoverGate.block_reason(%{projects: [%{project_id: "alpha"}]}, "alpha", :writeback)

    assert "writeback" in blocked
  end

  defp ack(plan_id, project_id \\ "alpha") do
    %{
      project_id: project_id,
      plan_id: plan_id,
      source: "operator-file",
      created_at: "2026-06-30T09:01:00Z",
      acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
    }
  end

  defp sources(migration_state, project_ids \\ ["alpha"]) do
    %{
      hub_runtime: %{
        mode: "hub",
        read_only: false,
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
              status: :ready,
              dispatch_enabled: true,
              migration_state: migration_state,
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
              status: preflight_status(migration_state),
              safe_to_manage: migration_state == "hub_managed",
              reason: if(migration_state == "hub_managed", do: "hub_managed_no_conflict", else: "migration_state_not_hub_managed"),
              checked_at: "2026-06-30T09:00:00Z",
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

  defp preflight_status("hub_managed"), do: "safe_to_manage"
  defp preflight_status(_state), do: "not_hub_managed"

  defp reason_codes(gate), do: Enum.map(gate.blocking_reasons, & &1.code)
end
