defmodule SymphonyElixir.HubCutoverClosureReportPacketDryRunFixture do
  @moduledoc false

  alias SymphonyElixir.Hub.{
    CutoverClosureReportPacket,
    DeviceObservability
  }

  @fixture_version 1
  @now ~U[2026-07-02 09:00:00Z]
  @now_iso DateTime.to_iso8601(@now)

  @project_specs [
    %{
      project_id: "success",
      provider_kind: "github",
      provider_scope_key: "github:org/success",
      status: "closed_succeeded",
      report_status: "fully_closed",
      conclusion: "closed_succeeded",
      severity: "info",
      attention_level: "review",
      summary_code: "closure_closed_succeeded",
      actions: ["review_success_evidence"],
      blockers: [],
      fully_closed: true,
      operation_success: true
    },
    %{
      project_id: "clear",
      provider_kind: "gitlab",
      provider_scope_key: "gitlab:group/clear",
      status: "closed_no_side_effect",
      report_status: "closed_no_side_effect",
      conclusion: "closed_no_side_effect",
      severity: "notice",
      attention_level: "review",
      summary_code: "closure_closed_no_side_effect",
      actions: ["review_no_side_effect_evidence"],
      blockers: [],
      fully_closed: true,
      operation_success: false
    },
    %{
      project_id: "retry",
      provider_kind: "github",
      provider_scope_key: "github:org/retry",
      status: "open_retryable",
      report_status: "retry_consideration_required",
      conclusion: "waiting_explicit_retry_consideration",
      severity: "warning",
      attention_level: "retry_consideration",
      summary_code: "closure_open_retryable_waiting_explicit_consideration",
      actions: ["request_explicit_retry_consideration"],
      blockers: [],
      fully_closed: false,
      operation_success: false
    },
    %{
      project_id: "unknown-manual",
      provider_kind: "github",
      provider_scope_key: "github:ops/unknown-manual",
      status: "open_manual_attention",
      report_status: "manual_attention_required",
      conclusion: "manual_attention_required",
      severity: "warning",
      attention_level: "manual_attention",
      summary_code: "closure_unknown_outcome_requires_manual_attention",
      actions: ["resolve_manual_attention"],
      blockers: [
        %{code: "unknown_outcome_requires_manual_attention", closure_chain_status: "open_manual_attention"}
      ],
      fully_closed: false,
      operation_success: false
    },
    %{
      project_id: "stale",
      provider_kind: "gitlab",
      provider_scope_key: "gitlab:group/stale",
      status: "stale",
      report_status: "stale_evidence_review_required",
      conclusion: "evidence_stale_reaudit_required",
      severity: "warning",
      attention_level: "audit_required",
      summary_code: "closure_evidence_stale",
      actions: ["refresh_stale_evidence"],
      blockers: [
        %{code: "stale_evidence_requires_reaudit", closure_chain_status: "stale"}
      ],
      fully_closed: false,
      operation_success: false
    },
    %{
      project_id: "no-request",
      provider_kind: "github",
      provider_scope_key: "github:org/no-request",
      status: "no_request",
      report_status: "no_request",
      conclusion: "no_explicit_cutover_request",
      severity: "none",
      attention_level: "none",
      summary_code: "closure_no_request",
      actions: ["none_required"],
      blockers: [],
      fully_closed: false,
      operation_success: false
    },
    %{
      project_id: "no-chain",
      provider_kind: "gitlab",
      provider_scope_key: "gitlab:group/no-chain",
      status: "no_chain",
      report_status: "no_chain",
      conclusion: "no_explicit_closure_chain",
      severity: "none",
      attention_level: "none",
      summary_code: "closure_no_chain",
      actions: ["none_required"],
      blockers: [],
      fully_closed: false,
      operation_success: false
    }
  ]

  @forbidden_output_markers [
    "ghp_secret_fixture_token",
    "sk-secret-fixture",
    "Authorization: Bearer fixture",
    "session=fixture-secret",
    "raw provider payload fixture",
    "raw config fixture",
    "raw systemd output fixture",
    "raw hook output fixture",
    "raw app-server output fixture",
    "full prompt fixture",
    "complete transcript fixture",
    "complete PR body fixture",
    "complete comment body fixture",
    "/home/jhihjian/private/fixture",
    "stack trace fixture"
  ]

  @spec fixture_version() :: pos_integer()
  def fixture_version, do: @fixture_version

  @spec generated_at() :: String.t()
  def generated_at, do: @now_iso

  @spec project_specs() :: [map()]
  def project_specs, do: @project_specs

  @spec forbidden_output_markers() :: [String.t()]
  def forbidden_output_markers, do: @forbidden_output_markers

  @spec safe_sources() :: map()
  def safe_sources do
    chain = closure_chain()

    %{
      fixture_version: @fixture_version,
      generated_at: @now_iso,
      hub_cutover_closure_chain: chain,
      hub_cutover_closure_conclusion: closure_conclusion()
    }
  end

  @spec closure_report_packet() :: map()
  def closure_report_packet do
    CutoverClosureReportPacket.build(safe_sources(), now: @now)
  end

  @spec device_observability() :: map()
  def device_observability do
    sources = safe_sources()
    packet = closure_report_packet()

    DeviceObservability.build(
      %{
        hub_runtime: hub_runtime_boundary(),
        registry: registry(),
        scheduler: %{enabled: false, status: "disabled", queued: false},
        runtime_ledger: %{projects: []},
        cutover_closure_chain: sources.hub_cutover_closure_chain,
        cutover_closure_conclusion: sources.hub_cutover_closure_conclusion,
        cutover_closure_report_packet: packet
      },
      now: @now
    )
  end

  @spec runtime_snapshot() :: map()
  def runtime_snapshot do
    sources = safe_sources()
    packet = closure_report_packet()
    observability = device_observability()

    %{
      running: [],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil,
      polling: %{checking?: false, next_poll_in_ms: nil, poll_interval_ms: nil},
      hub_runtime:
        hub_runtime_boundary()
        |> Map.merge(%{
          loaded_at: @now_iso,
          generated_at: @now_iso,
          counts: %{
            project_count: length(@project_specs),
            ready_project_count: length(@project_specs),
            paused_project_count: 0
          },
          cutover_closure_chain: sources.hub_cutover_closure_chain,
          cutover_closure_conclusion: sources.hub_cutover_closure_conclusion,
          cutover_closure_report_packet: packet
        }),
      hub_cutover_closure_chain: sources.hub_cutover_closure_chain,
      hub_cutover_closure_conclusion: sources.hub_cutover_closure_conclusion,
      hub_cutover_closure_report_packet: packet,
      hub_device_observability: observability
    }
  end

  @spec support_source_path() :: Path.t()
  def support_source_path do
    Path.expand("hub_cutover_closure_report_packet_dry_run_fixture.exs", __DIR__)
  end

  defp closure_chain do
    %{
      version: @fixture_version,
      generated_at: @now_iso,
      evaluated_at: @now_iso,
      status: "stale",
      read_only: true,
      no_side_effects: true,
      auto_replay_allowed: false,
      counts: count_map(Enum.map(@project_specs, & &1.status)),
      recent_reference_reason_codes: ["fixture_device_stale_evidence"],
      recent_reference_action_codes: ["refresh_stale_evidence"],
      safe_evidence_fingerprints: %{fixture: "device-chain-fp"},
      safe_evidence_fingerprint: "device-chain-fp",
      projects: Enum.map(@project_specs, &closure_chain_project/1)
    }
  end

  defp closure_conclusion do
    %{
      version: @fixture_version,
      generated_at: @now_iso,
      evaluated_at: @now_iso,
      closure_chain_status: "stale",
      conclusion: "evidence_stale_reaudit_required",
      severity: "warning",
      attention_level: "audit_required",
      summary_code: "closure_evidence_stale",
      required_action_codes: [
        "refresh_stale_evidence",
        "request_explicit_retry_consideration",
        "resolve_manual_attention"
      ],
      blocked_by: [
        %{code: "stale_evidence_requires_reaudit", closure_chain_status: "stale", project_id: "stale"}
      ],
      evidence_references: [
        evidence_reference(%{
          project_id: "device",
          status: "stale",
          summary_code: "closure_evidence_stale",
          fingerprint: "device-reference-fp"
        })
      ],
      closure_status_counts: status_counts(Enum.map(@project_specs, & &1.status)),
      reference_status_counts: reference_status_counts("current"),
      project_count: length(@project_specs),
      chain_count: length(@project_specs),
      fully_closed: false,
      operation_success: false,
      read_only: true,
      no_side_effects: true,
      actions_are_advisory: true,
      auto_retry_allowed: false,
      auto_replay_allowed: false,
      queued_replay: false,
      pending_execution: false,
      pending_retry: false,
      legacy_takeover: false,
      projects: Enum.map(@project_specs, &closure_conclusion_project/1)
    }
  end

  defp closure_chain_project(spec) do
    %{
      version: @fixture_version,
      project_id: spec.project_id,
      status: spec.status,
      counts: count_map([spec.status]),
      recent_reference_reason_codes: ["fixture_#{spec.project_id}_#{spec.status}_reason"],
      recent_reference_action_codes: spec.actions,
      provider_scope: provider_scope(spec),
      evidence_references: [
        evidence_reference(%{
          project_id: spec.project_id,
          status: spec.status,
          summary_code: spec.summary_code,
          fingerprint: "#{spec.project_id}-chain-reference-fp"
        })
      ],
      safe_evidence_fingerprints: %{
        outcome: "#{spec.project_id}-outcome-fp",
        reference: "#{spec.project_id}-reference-fp"
      },
      safe_evidence_fingerprint: "#{spec.project_id}-chain-fp",
      read_only: true,
      no_side_effects: true,
      auto_replay_allowed: false
    }
  end

  defp closure_conclusion_project(spec) do
    %{
      project_id: spec.project_id,
      provider_scope: provider_scope(spec),
      closure_chain_status: spec.status,
      conclusion: spec.conclusion,
      severity: spec.severity,
      attention_level: spec.attention_level,
      summary_code: spec.summary_code,
      required_action_codes: spec.actions,
      blocked_by: spec.blockers,
      evidence_references: [
        evidence_reference(%{
          project_id: spec.project_id,
          status: spec.status,
          summary_code: spec.summary_code,
          fingerprint: "#{spec.project_id}-conclusion-reference-fp"
        })
      ],
      closure_status_counts: status_counts([spec.status]),
      reference_status_counts: reference_status_counts("current"),
      safe_evidence_fingerprints: %{
        outcome: "#{spec.project_id}-outcome-fp",
        reference: "#{spec.project_id}-conclusion-reference-fp"
      },
      safe_evidence_fingerprint: "#{spec.project_id}-conclusion-fp",
      fully_closed: spec.fully_closed,
      operation_success: spec.operation_success,
      read_only: true,
      no_side_effects: true,
      actions_are_advisory: true,
      auto_retry_allowed: false,
      auto_replay_allowed: false,
      queued_replay: false,
      pending_execution: false,
      pending_retry: false,
      legacy_takeover: false
    }
  end

  defp registry do
    %{
      projects: Enum.map(@project_specs, &registry_project/1),
      warnings: [],
      errors: []
    }
  end

  defp registry_project(spec) do
    %{
      project_id: spec.project_id,
      name: String.capitalize(spec.project_id),
      dispatch_enabled: false,
      paused: false,
      status: :ready,
      migration_state: "hub_managed",
      tracker_summary: %{
        kind: spec.provider_kind,
        provider_scope_key: spec.provider_scope_key,
        provider_scope: Map.fetch!(provider_scope(spec), :scope),
        required_labels: ["symphony"]
      },
      runtime_summary: %{
        workspace_root: "safe-fixture-workspace-#{spec.project_id}",
        max_concurrent_agents: 0,
        max_concurrent_agents_by_state: %{},
        polling_interval_ms: nil,
        server_port: nil
      },
      fingerprint: "#{spec.project_id}-registry-fp",
      loaded_at: @now,
      load_error: nil
    }
  end

  defp hub_runtime_boundary do
    %{
      mode: "hub",
      read_only: true,
      poll_tick_execution: false,
      dry_run_fixture: %{version: @fixture_version, consumes_safe_fields_only: true},
      provider_executor: %{mode: "dry_run_fixture", provider_io: false},
      writeback_executor: %{mode: "dry_run_fixture", provider_io: false},
      worker_starter: %{mode: "dry_run_fixture", worker_start: false},
      dispatch: %{dispatch_calls: false},
      systemd: %{calls: false},
      workspace_hook: %{calls: false},
      config_mutation: false,
      legacy_service_operation: false
    }
  end

  defp evidence_reference(attrs) do
    %{
      type: "dry_run_fixture",
      closure_chain_status: attrs.status,
      summary_code: attrs.summary_code,
      reference: "safe://hub-cutover-closure-report-packet/#{attrs.project_id}/#{attrs.status}",
      safe_evidence_fingerprints: %{reference: attrs.fingerprint}
    }
  end

  defp provider_scope(spec) do
    scope =
      case String.split(spec.provider_scope_key, ":", parts: 2) do
        ["github", repo] ->
          [owner, repo] = String.split(repo, "/", parts: 2)
          %{owner: owner, repo: repo}

        ["gitlab", path] ->
          [group, project] = String.split(path, "/", parts: 2)
          %{group: group, project: project}
      end

    %{
      kind: spec.provider_kind,
      key: spec.provider_scope_key,
      provider_scope_key: spec.provider_scope_key,
      scope: scope
    }
  end

  defp count_map(statuses) do
    Map.merge(
      %{
        chain_count: length(statuses),
        no_chain_count: Enum.count(statuses, &(&1 == "no_chain")),
        no_request_count: Enum.count(statuses, &(&1 == "no_request")),
        closed_succeeded_count: Enum.count(statuses, &(&1 == "closed_succeeded")),
        closed_no_side_effect_count: Enum.count(statuses, &(&1 == "closed_no_side_effect")),
        open_retryable_count: Enum.count(statuses, &(&1 == "open_retryable")),
        open_manual_attention_count: Enum.count(statuses, &(&1 == "open_manual_attention")),
        conflict_count: Enum.count(statuses, &(&1 == "conflict")),
        stale_count: Enum.count(statuses, &(&1 == "stale")),
        malformed_count: Enum.count(statuses, &(&1 == "malformed")),
        unsupported_count: Enum.count(statuses, &(&1 == "unsupported")),
        closeout_reference_status_counts: zero_reference_counts(),
        replay_decision_reference_status_counts: zero_reference_counts(),
        replay_request_audit_reference_status_counts: zero_reference_counts()
      },
      %{reference_status_counts: reference_status_counts("current")}
    )
  end

  defp status_counts(statuses) do
    %{
      no_chain: Enum.count(statuses, &(&1 == "no_chain")),
      no_request: Enum.count(statuses, &(&1 == "no_request")),
      closed_succeeded: Enum.count(statuses, &(&1 == "closed_succeeded")),
      closed_no_side_effect: Enum.count(statuses, &(&1 == "closed_no_side_effect")),
      open_retryable: Enum.count(statuses, &(&1 == "open_retryable")),
      open_manual_attention: Enum.count(statuses, &(&1 == "open_manual_attention")),
      conflict: Enum.count(statuses, &(&1 == "conflict")),
      stale: Enum.count(statuses, &(&1 == "stale")),
      malformed: Enum.count(statuses, &(&1 == "malformed")),
      unsupported: Enum.count(statuses, &(&1 == "unsupported"))
    }
  end

  defp reference_status_counts(status) do
    counts = zero_reference_counts() |> Map.put(String.to_atom(status), 1)

    %{
      closeout: counts,
      replay_decision: counts,
      replay_request_audit: counts
    }
  end

  defp zero_reference_counts do
    %{missing: 0, current: 0, stale: 0, conflict: 0, malformed: 0, unsupported: 0}
  end
end
