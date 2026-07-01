defmodule SymphonyElixir.Hub.DeviceObservability do
  @moduledoc """
  Safe Hub device-level observability projection.

  This module is model-only. It summarizes existing Hub registry, provider
  governance, poll coordination, runtime ledger, dispatch, and writeback
  observability snapshots into one Dashboard/API-safe device projection. It
  does not start poll loops, dispatch agents, execute provider calls, or replace
  the legacy `symphony@project.service` single-project path.
  """

  alias SymphonyElixir.Hub.{
    ActivationPlan,
    CutoverAuditHistory,
    CutoverExecutionAuthorization,
    CutoverGate,
    CutoverOperationAudit,
    CutoverReadinessPermit
  }

  @version 1
  @project_statuses [
    "running",
    "idle",
    "ready_to_poll",
    "backoff",
    "paused",
    "blocked",
    "manual_attention",
    "legacy_only",
    "config_invalid"
  ]
  @readiness_version 1
  @readiness_decisions [
    "legacy_only",
    "ready_for_dry_run",
    "ready_for_hub_management",
    "blocked",
    "unknown_manual_attention",
    "already_hub_managed"
  ]
  @migration_states ["legacy_only", "hub_ready", "hub_managed"]
  @risk_levels ["blocking", "advisory"]
  @provider_risk_codes [
    "provider_rate_limit",
    "provider_backoff",
    "provider_circuit_open",
    "provider_unavailable",
    "queue_pressure"
  ]
  @unknown_readiness_codes [
    "probe_unknown",
    "probe_missing",
    "summary_error",
    "summary_version_incompatible",
    "writeback_unknown",
    "writeback_manual_attention",
    "manual_attention_required",
    "lifecycle_unknown",
    "worker_lifecycle_lost",
    "start_intent_unresolved"
  ]
  @hub_management_blocking_codes [
    "config_invalid",
    "legacy_service_active",
    "legacy_service_enabled",
    "provider_scope_owner_conflict",
    "workspace_owner_conflict",
    "runtime_path_owner_conflict",
    "log_path_owner_conflict",
    "state_path_owner_conflict",
    "dashboard_port_owner_conflict",
    "api_port_owner_conflict",
    "instance_registry_owner_conflict",
    "probe_unknown",
    "probe_missing",
    "summary_error",
    "summary_version_incompatible",
    "provider_backoff",
    "provider_circuit_open",
    "provider_rate_limit",
    "provider_unavailable",
    "writeback_conflict",
    "writeback_unknown",
    "writeback_manual_attention",
    "active_attempt_exists",
    "workspace_occupied",
    "workspace_retained",
    "pending_start_intent",
    "start_intent_unresolved",
    "worker_lifecycle_unknown",
    "worker_lifecycle_lost",
    "capacity_unavailable"
  ]
  @hub_management_blocking_code_set MapSet.new(
                                      @hub_management_blocking_codes ++
                                        [
                                          "legacy_ownership_conflict",
                                          "legacy_instance_registered",
                                          "legacy_only_project",
                                          "pending_start_intent",
                                          "manual_attention_required"
                                        ]
                                    )
  @active_attempt_statuses ["pending", "running"]
  @active_start_intent_statuses ["pending", "unknown", "manual_attention"]
  @sensitive_key_fragments [
    "api_key",
    "apikey",
    "authorization",
    "cookie",
    "credential",
    "credentials",
    "exception",
    "hook_output",
    "raw_config",
    "raw_env",
    "raw_output",
    "raw_provider_config",
    "raw_provider_response",
    "raw_response",
    "secret",
    "secret_env",
    "secret_envs",
    "stack_trace",
    "stacktrace",
    "systemd_output",
    "token",
    "prompt",
    "transcript"
  ]
  @body_keys ["body", "comment_body", "pull_request_body", "pr_body", "provider_body", "raw_body"]
  @sensitive_value_patterns [
    ~r/\$[A-Z0-9_]*(TOKEN|API_KEY|SECRET|CREDENTIAL)[A-Z0-9_]*/,
    ~r/\b(api[_-]?key|authorization|bearer|cookie|credential|secret|token|transcript|full prompt|codex transcript|raw provider response|raw systemd output|stacktrace|stack trace)\b/i,
    ~r/\b(ghp_|github_pat_|glpat-|sk-[A-Za-z0-9])/
  ]

  @type projection :: map()

  def build(sources, opts \\ [])

  @spec build(term(), keyword()) :: projection()
  def build(sources, opts) when is_map(sources) and is_list(opts) do
    now = iso8601(Keyword.get(opts, :now) || value(sources, :generated_at) || DateTime.utc_now())
    registry = source_map(sources, [:registry, :project_registry, :hub_project_registry])
    poll_coordination = source_map(sources, [:poll_coordination, :hub_poll_coordination])
    runtime = source_map(sources, [:runtime_ledger, :dispatch_boundary, :hub_dispatch_boundary, :runtime])
    activation_preflight = source_map(sources, [:activation_preflight, :hub_activation_preflight])
    scheduler = source_map(sources, [:scheduler, :hub_scheduler])
    tick = source_map(sources, [:tick, :poll_tick, :hub_poll_tick])
    candidate_intake = source_map(sources, [:candidate_intake, :hub_candidate_intake])
    dispatch_planning = source_map(sources, [:dispatch_planning, :hub_dispatch_planning])
    dispatch_plan_application = source_map(sources, [:dispatch_plan_application, :hub_dispatch_plan_application])
    worker_start_handoff = source_map(sources, [:worker_start_handoff, :hub_worker_start_handoff])

    worker_lifecycle_reconciliation =
      source_map(sources, [:worker_lifecycle_reconciliation, :hub_worker_lifecycle_reconciliation])

    writeback = source_map(sources, [:writeback, :hub_writeback])
    cutover_gate = source_map(sources, [:cutover_gate, :hub_cutover_gate])
    cutover_operation_audit = source_map(sources, [:cutover_operation_audit, :hub_cutover_operation_audit])
    cutover_audit_history = source_map(sources, [:cutover_audit_history, :hub_cutover_audit_history])
    cutover_readiness_permit = source_map(sources, [:cutover_readiness_permit, :hub_cutover_readiness_permit])

    cutover_execution_authorization_ledger =
      source_map(sources, [:cutover_execution_authorization_ledger, :hub_cutover_execution_authorization_ledger])

    provider_queue = provider_queue_summary(sources, poll_coordination)
    legacy_projects = list_value(sources, :legacy_projects)
    managed_project_ids = managed_project_ids(sources, opts)

    project_ids =
      [
        registry |> list_value(:projects) |> Enum.map(&required_string(&1, :project_id)),
        poll_coordination |> list_value(:projects) |> Enum.map(&required_string(&1, :project_id)),
        runtime |> list_value(:projects) |> Enum.map(&required_string(&1, :project_id)),
        activation_preflight |> list_value(:projects) |> Enum.map(&required_string(&1, :project_id)),
        candidate_intake |> list_value(:projects) |> Enum.map(&required_string(&1, :project_id)),
        dispatch_planning |> list_value(:projects) |> Enum.map(&required_string(&1, :project_id)),
        dispatch_plan_application |> list_value(:projects) |> Enum.map(&required_string(&1, :project_id)),
        worker_start_handoff |> list_value(:results) |> Enum.map(&required_string(&1, :project_id)),
        worker_start_handoff |> list_value(:pending_start_intents) |> Enum.map(&required_string(&1, :project_id)),
        worker_lifecycle_reconciliation |> list_value(:results) |> Enum.map(&required_string(&1, :project_id)),
        cutover_gate |> list_value(:projects) |> Enum.map(&required_string(&1, :project_id)),
        cutover_operation_audit |> list_value(:projects) |> Enum.map(&required_string(&1, :project_id)),
        cutover_audit_history |> list_value(:projects) |> Enum.map(&required_string(&1, :project_id)),
        cutover_readiness_permit |> list_value(:projects) |> Enum.map(&required_string(&1, :project_id)),
        cutover_execution_authorization_ledger |> list_value(:projects) |> Enum.map(&required_string(&1, :project_id)),
        Enum.map(legacy_projects, &required_string(&1, :project_id))
      ]
      |> List.flatten()
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.sort()

    source_context = %{
      registry: registry,
      poll_coordination: poll_coordination,
      runtime: runtime,
      activation_preflight: activation_preflight,
      provider_queue: provider_queue,
      legacy_projects: legacy_projects,
      managed_project_ids: managed_project_ids,
      candidate_intake: candidate_intake,
      dispatch_planning: dispatch_planning,
      dispatch_plan_application: dispatch_plan_application,
      worker_start_handoff: worker_start_handoff,
      worker_lifecycle_reconciliation: worker_lifecycle_reconciliation,
      cutover_gate: cutover_gate,
      cutover_operation_audit: cutover_operation_audit,
      cutover_audit_history: cutover_audit_history,
      cutover_readiness_permit: cutover_readiness_permit,
      cutover_execution_authorization_ledger: cutover_execution_authorization_ledger
    }

    projects =
      Enum.map(project_ids, fn project_id ->
        safe_project_projection(project_id, source_context)
      end)

    overview =
      overview_summary(
        projects,
        registry,
        poll_coordination,
        provider_queue,
        scheduler,
        tick,
        activation_preflight,
        runtime,
        writeback,
        sources,
        opts
      )

    projection = %{
      version: @version,
      generated_at: now,
      overview: overview,
      device: device_summary(projects, registry, poll_coordination, provider_queue, sources, opts),
      status_counts: status_counts(projects),
      migration_readiness: migration_readiness_summary(projects, overview, now),
      activation_plan: %{},
      cutover_gate: cutover_gate,
      cutover_operation_audit: cutover_operation_audit,
      cutover_audit_history: cutover_audit_history,
      cutover_readiness_permit: cutover_readiness_permit,
      cutover_execution_authorization_ledger: cutover_execution_authorization_ledger,
      migration_boundary: migration_boundary_summary(sources),
      provider_queue: sanitize_value(provider_queue),
      projects: projects,
      backpressure_reasons: aggregate_backpressure_reasons(projects)
    }

    projection
    |> attach_activation_plan_summary(opts)
    |> attach_cutover_gate_summary(opts)
    |> to_snapshot()
  end

  def build(_sources, opts) when is_list(opts), do: build(%{}, opts)

  @spec to_snapshot(term()) :: projection()
  def to_snapshot(projection) when is_map(projection) do
    projects =
      projection
      |> list_value(:projects)
      |> Enum.map(&project_snapshot/1)
      |> Enum.sort_by(& &1.project_id)

    overview = overview_snapshot(value(projection, :overview), projects)
    generated_at = iso8601(value(projection, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601()

    migration_readiness =
      migration_readiness_snapshot(
        value(projection, :migration_readiness),
        projects,
        overview,
        generated_at
      )

    activation_plan =
      activation_plan_snapshot(
        value(projection, :activation_plan),
        migration_readiness,
        projects,
        overview
      )

    migration_readiness = attach_activation_plan_to_readiness_summary(migration_readiness, activation_plan.projects)

    projects =
      projects
      |> attach_project_readiness(migration_readiness.projects)
      |> attach_project_activation_plans(activation_plan.projects)

    cutover_gate =
      cutover_gate_snapshot(
        value(projection, :cutover_gate),
        migration_readiness,
        activation_plan,
        projects,
        overview,
        generated_at
      )

    projects = attach_project_cutover_gates(projects, cutover_gate.projects)
    overview = Map.put(overview, :cutover_gate, cutover_gate_overview_snapshot(cutover_gate))

    cutover_operation_audit =
      cutover_operation_audit_snapshot(
        value(projection, :cutover_operation_audit),
        projects,
        migration_readiness,
        activation_plan,
        cutover_gate,
        overview,
        generated_at
      )

    projects = attach_project_cutover_operation_audits(projects, cutover_operation_audit.projects)
    overview = Map.put(overview, :cutover_operation_audit, cutover_operation_audit_overview_snapshot(cutover_operation_audit))

    cutover_audit_history =
      cutover_audit_history_snapshot(
        value(projection, :cutover_audit_history),
        projects,
        cutover_operation_audit,
        generated_at
      )

    projects = attach_project_cutover_audit_history(projects, cutover_audit_history.projects)
    overview = Map.put(overview, :cutover_audit_history, cutover_audit_history_overview_snapshot(cutover_audit_history))

    cutover_readiness_permit =
      cutover_readiness_permit_snapshot(
        value(projection, :cutover_readiness_permit),
        projects,
        activation_plan,
        cutover_gate,
        cutover_operation_audit,
        cutover_audit_history,
        overview,
        generated_at
      )

    projects = attach_project_cutover_readiness_permits(projects, cutover_readiness_permit.projects)
    overview = Map.put(overview, :cutover_readiness_permit, cutover_readiness_permit_overview_snapshot(cutover_readiness_permit))

    cutover_execution_authorization_ledger =
      cutover_execution_authorization_ledger_snapshot(
        value(projection, :cutover_execution_authorization_ledger),
        projects,
        cutover_readiness_permit,
        overview,
        generated_at
      )

    projects =
      attach_project_cutover_execution_authorization_ledgers(
        projects,
        cutover_execution_authorization_ledger.projects
      )

    overview =
      Map.put(
        overview,
        :cutover_execution_authorization_ledger,
        cutover_execution_authorization_ledger_overview_snapshot(cutover_execution_authorization_ledger)
      )

    %{
      version: positive_integer(value(projection, :version)) || @version,
      generated_at: generated_at,
      overview: overview,
      device: device_snapshot(value(projection, :device), projects),
      status_counts: status_counts(projects),
      migration_readiness: migration_readiness,
      activation_plan: activation_plan,
      cutover_gate: cutover_gate,
      cutover_operation_audit: cutover_operation_audit,
      cutover_audit_history: cutover_audit_history,
      cutover_readiness_permit: cutover_readiness_permit,
      cutover_execution_authorization_ledger: cutover_execution_authorization_ledger,
      migration_boundary: migration_boundary_snapshot(value(projection, :migration_boundary)),
      provider_queue: sanitize_value(value(projection, :provider_queue) || %{}),
      projects: projects,
      backpressure_reasons:
        case list_value(projection, :backpressure_reasons) do
          [] -> aggregate_backpressure_reasons(projects)
          reasons -> reason_snapshots(reasons)
        end
    }
  end

  def to_snapshot(_projection) do
    to_snapshot(%{projects: []})
  end

  @spec from_snapshot(term()) :: {:ok, projection()} | {:error, [map()]}
  def from_snapshot(snapshot) when is_map(snapshot), do: {:ok, to_snapshot(snapshot)}

  def from_snapshot(_snapshot) do
    {:error,
     [
       %{
         level: :error,
         code: :invalid_device_observability_snapshot,
         message: "Device observability snapshot must be a map"
       }
     ]}
  end

  @spec observability_snapshot(term()) :: projection() | nil
  def observability_snapshot(nil), do: nil
  def observability_snapshot(snapshot) when is_map(snapshot), do: to_snapshot(snapshot)
  def observability_snapshot(_snapshot), do: nil

  defp project_projection(project_id, sources) do
    registry = sources.registry
    poll_coordination = sources.poll_coordination
    runtime = sources.runtime
    activation_preflight = sources.activation_preflight
    provider_queue = sources.provider_queue
    legacy_projects = sources.legacy_projects
    managed_project_ids = sources.managed_project_ids
    registry_project = find_project(registry, project_id)
    poll_project = find_project(poll_coordination, project_id)
    runtime_project = find_project(runtime, project_id)
    preflight_project = find_project(activation_preflight, project_id)
    legacy_project = Enum.find(legacy_projects, &(required_string(&1, :project_id) == project_id))

    migration_state =
      migration_state(
        project_id,
        registry_project,
        poll_project,
        runtime_project,
        legacy_project,
        managed_project_ids
      )

    runtime_summary = runtime_summary(runtime_project)
    writeback_summary = writeback_summary(runtime_project)
    summary_error = source_summary_error(project_id, registry_project, poll_project, runtime_project, preflight_project)

    project_queue =
      provider_queue_for_project(
        provider_queue,
        project_id,
        provider_scope_key(registry_project, poll_project, runtime_project)
      )

    base = %{
      project_id: project_id,
      name: project_name(registry_project, poll_project, legacy_project),
      status: nil,
      migration_state: migration_state,
      dispatch_enabled: dispatch_enabled?(registry_project, legacy_project),
      provider: provider_summary(registry_project, poll_project, runtime_project),
      poll: poll_summary(poll_project),
      provider_queue: project_queue,
      runtime: runtime_summary,
      activation_preflight: activation_preflight_summary(preflight_project),
      writebacks: writeback_summary,
      conflicts: sanitize_value(list_value(runtime_project, :conflicts)),
      manual_attention: sanitize_value(list_value(runtime_project, :manual_attention)),
      detail:
        detail_summary(
          project_id,
          registry_project,
          poll_project,
          runtime_project,
          preflight_project,
          sources,
          project_queue,
          writeback_summary,
          legacy_project,
          summary_error
        ),
      summary_error: summary_error,
      backpressure_reasons: []
    }

    reasons =
      backpressure_reasons(
        base,
        registry_project,
        poll_project,
        runtime_summary,
        preflight_project,
        writeback_summary,
        project_queue
      )
      |> add_project_reason(
        not is_nil(summary_error),
        "summary_error",
        "hub_device_observability",
        project_id,
        summary_error && summary_error.code
      )

    status =
      if is_nil(summary_error) do
        project_status(
          migration_state,
          registry_project,
          poll_project,
          runtime_summary,
          writeback_summary,
          reasons
        )
      else
        "manual_attention"
      end

    base
    |> Map.put(:status, status)
    |> Map.put(:backpressure_reasons, reason_snapshots(reasons))
    |> project_snapshot()
  end

  defp safe_project_projection(project_id, sources) do
    project_projection(project_id, sources)
  rescue
    _error ->
      summary_error_project(project_id, "project_summary_exception", "hub_device_observability")
  catch
    _kind, _reason ->
      summary_error_project(project_id, "project_summary_throw", "hub_device_observability")
  end

  defp summary_error_project(project_id, code, source) do
    summary_error = summary_error_snapshot(%{code: code, source: source})

    %{
      project_id: project_id,
      name: nil,
      status: "manual_attention",
      migration_state: "hub_ready",
      dispatch_enabled: false,
      provider: %{},
      poll: %{},
      provider_queue: %{},
      runtime: %{},
      activation_preflight: nil,
      writebacks: %{},
      conflicts: [],
      manual_attention: [%{code: code, source: source}],
      detail: %{summary_error: summary_error},
      summary_error: summary_error,
      backpressure_reasons: [
        %{reason: "summary_error", source: source, project_id: project_id, detail: code},
        %{reason: "manual_attention", source: source, project_id: project_id, detail: code}
      ]
    }
    |> project_snapshot()
  end

  defp project_snapshot(project) when is_map(project) do
    project_id = required_string(project, :project_id)

    cutover_execution_authorization_ledger =
      cutover_execution_authorization_ledger_project_snapshot(value(project, :cutover_execution_authorization_ledger))

    %{
      project_id: project_id,
      name: optional_string(project, :name),
      status: normalize_project_status(value(project, :status)),
      migration_state: normalize_migration_state(value(project, :migration_state)),
      dispatch_enabled: truthy?(value(project, :dispatch_enabled)),
      provider: provider_snapshot(value(project, :provider)),
      poll: poll_snapshot(value(project, :poll)),
      provider_queue: provider_queue_project_snapshot(value(project, :provider_queue)),
      runtime: runtime_snapshot(value(project, :runtime)),
      activation_preflight: activation_preflight_project_snapshot(value(project, :activation_preflight)),
      writebacks: writeback_snapshot(value(project, :writebacks)),
      conflicts: sanitize_list(value(project, :conflicts)),
      manual_attention: sanitize_list(value(project, :manual_attention)),
      detail: detail_snapshot(value(project, :detail)),
      migration_readiness: migration_readiness_project_snapshot(value(project, :migration_readiness)),
      activation_plan: activation_plan_project_snapshot(value(project, :activation_plan)),
      cutover_gate: cutover_gate_project_snapshot(value(project, :cutover_gate)),
      cutover_operation_audit: cutover_operation_audit_project_snapshot(value(project, :cutover_operation_audit)),
      cutover_audit_history: cutover_audit_history_project_snapshot(value(project, :cutover_audit_history)),
      cutover_readiness_permit: cutover_readiness_permit_project_snapshot(value(project, :cutover_readiness_permit)),
      cutover_execution_authorization_ledger: cutover_execution_authorization_ledger,
      summary_error: summary_error_snapshot(value(project, :summary_error)),
      backpressure_reasons: reason_snapshots(list_value(project, :backpressure_reasons))
    }
  end

  defp project_snapshot(_project) do
    project_snapshot(%{})
  end

  defp overview_snapshot(overview, projects) do
    overview = if is_map(overview), do: overview, else: %{}

    cutover_execution_authorization_ledger =
      cutover_execution_authorization_ledger_overview_snapshot(value(overview, :cutover_execution_authorization_ledger))

    %{
      hub_runtime: hub_runtime_overview_snapshot(value(overview, :hub_runtime)),
      scheduler: scheduler_overview_snapshot(value(overview, :scheduler)),
      project_status_counts:
        case map_value(overview, :project_status_counts) do
          nil -> status_counts(projects)
          counts -> status_counts_snapshot(counts)
        end,
      provider_governance: provider_governance_overview_snapshot(value(overview, :provider_governance)),
      capacity_workspace: capacity_workspace_overview_snapshot(value(overview, :capacity_workspace)),
      writeback: writeback_overview_snapshot(value(overview, :writeback)),
      activation_preflight: activation_preflight_overview_snapshot(value(overview, :activation_preflight)),
      cutover_gate: cutover_gate_overview_snapshot(value(overview, :cutover_gate)),
      cutover_operation_audit: cutover_operation_audit_overview_snapshot(value(overview, :cutover_operation_audit)),
      cutover_audit_history: cutover_audit_history_overview_snapshot(value(overview, :cutover_audit_history)),
      cutover_readiness_permit: cutover_readiness_permit_overview_snapshot(value(overview, :cutover_readiness_permit)),
      cutover_execution_authorization_ledger: cutover_execution_authorization_ledger,
      lifecycle: lifecycle_overview_snapshot(value(overview, :lifecycle)),
      manual_attention: manual_attention_overview_snapshot(value(overview, :manual_attention)),
      summary_errors: sanitize_list(value(overview, :summary_errors))
    }
  end

  defp hub_runtime_overview_snapshot(runtime) when is_map(runtime) do
    %{
      enabled: truthy?(value(runtime, :enabled)),
      mode: optional_string(runtime, :mode) || "hub",
      read_only: truthy?(value(runtime, :read_only)),
      provider_executor: sanitize_value(value(runtime, :provider_executor) || %{}),
      writeback_executor: sanitize_value(value(runtime, :writeback_executor) || %{}),
      worker_starter: sanitize_value(value(runtime, :worker_starter) || %{}),
      activation_probe: sanitize_value(value(runtime, :activation_probe) || %{})
    }
  end

  defp hub_runtime_overview_snapshot(_runtime), do: hub_runtime_overview_snapshot(%{})

  defp migration_readiness_snapshot(readiness, projects, overview, generated_at) do
    readiness =
      if is_map(readiness) and list_value(readiness, :projects) != [] do
        readiness
      else
        migration_readiness_summary(projects, overview, generated_at)
      end

    project_decisions =
      readiness
      |> list_value(:projects)
      |> Enum.map(&migration_readiness_project_snapshot/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.project_id)

    risks =
      case {list_value(readiness, :global_blocking_risks), list_value(readiness, :global_advisory_risks)} do
        {[], []} -> global_readiness_risks(project_decisions, overview)
        {blocking, advisory} -> %{blocking: blocking, advisory: advisory}
      end

    %{
      version: positive_integer(value(readiness, :version)) || @readiness_version,
      generated_at: iso8601(value(readiness, :generated_at)) || generated_at,
      status: readiness_status(value(readiness, :status), project_decisions, risks.blocking),
      hub_runtime:
        hub_runtime_readiness_snapshot(
          value(readiness, :hub_runtime) || value(overview, :hub_runtime),
          value(overview, :scheduler)
        ),
      counts: readiness_counts_snapshot(value(readiness, :counts), project_decisions),
      global_blocking_risks:
        risks.blocking
        |> Enum.map(&readiness_reason_snapshot(&1, "blocking"))
        |> Enum.sort_by(&{&1.code, &1.source || ""}),
      global_advisory_risks:
        risks.advisory
        |> Enum.map(&readiness_reason_snapshot(&1, "advisory"))
        |> Enum.sort_by(&{&1.code, &1.source || ""}),
      projects: project_decisions
    }
  end

  defp migration_readiness_summary(projects, overview, generated_at) do
    project_decisions =
      projects
      |> Enum.map(&project_readiness_decision(&1, overview, generated_at))
      |> Enum.sort_by(& &1.project_id)

    risks = global_readiness_risks(project_decisions, overview)

    %{
      version: @readiness_version,
      generated_at: generated_at,
      status: readiness_status(nil, project_decisions, risks.blocking),
      hub_runtime: hub_runtime_readiness_snapshot(value(overview, :hub_runtime), value(overview, :scheduler)),
      counts: readiness_counts_snapshot(%{}, project_decisions),
      global_blocking_risks: risks.blocking,
      global_advisory_risks: risks.advisory,
      projects: project_decisions
    }
  end

  defp attach_activation_plan_summary(projection, opts) do
    activation_plan =
      ActivationPlan.build(
        value(projection, :migration_readiness),
        list_value(projection, :projects),
        value(projection, :overview),
        now: value(projection, :generated_at),
        operator_acknowledgements: Keyword.get(opts, :operator_acknowledgements) || Keyword.get(opts, :acknowledgements)
      )

    Map.put(projection, :activation_plan, activation_plan)
  end

  defp attach_cutover_gate_summary(projection, _opts) do
    cutover_gate =
      if is_map(value(projection, :cutover_gate)) and list_value(value(projection, :cutover_gate), :projects) != [] do
        CutoverGate.to_snapshot(value(projection, :cutover_gate))
      else
        CutoverGate.build(
          %{
            generated_at: value(projection, :generated_at),
            overview: value(projection, :overview),
            projects: list_value(projection, :projects),
            migration_readiness: value(projection, :migration_readiness),
            activation_plan: value(projection, :activation_plan)
          },
          now: value(projection, :generated_at)
        )
      end

    Map.put(projection, :cutover_gate, cutover_gate)
  end

  defp activation_plan_snapshot(activation_plan, migration_readiness, projects, overview) do
    project_plans =
      projects
      |> Enum.map(&value(&1, :activation_plan))
      |> Enum.filter(&is_map/1)

    cond do
      is_map(activation_plan) and list_value(activation_plan, :projects) != [] ->
        ActivationPlan.to_snapshot(activation_plan)

      project_plans != [] ->
        ActivationPlan.to_snapshot(%{
          generated_at: value(migration_readiness, :generated_at),
          hub_runtime: value(migration_readiness, :hub_runtime),
          projects: project_plans
        })

      true ->
        ActivationPlan.build(migration_readiness, projects, overview, now: value(migration_readiness, :generated_at))
    end
  end

  defp activation_plan_project_snapshot(nil), do: nil

  defp activation_plan_project_snapshot(plan) when is_map(plan) do
    ActivationPlan.project_plan_snapshot(plan)
  end

  defp activation_plan_project_snapshot(_plan), do: nil

  defp cutover_gate_snapshot(cutover_gate, migration_readiness, activation_plan, projects, overview, generated_at) do
    project_gates =
      projects
      |> Enum.map(&value(&1, :cutover_gate))
      |> Enum.filter(&is_map/1)

    cond do
      is_map(cutover_gate) and list_value(cutover_gate, :projects) != [] ->
        CutoverGate.to_snapshot(cutover_gate)

      project_gates != [] ->
        CutoverGate.to_snapshot(%{
          generated_at: generated_at,
          projects: project_gates
        })

      true ->
        CutoverGate.build(
          %{
            generated_at: generated_at,
            overview: overview,
            projects: projects,
            migration_readiness: migration_readiness,
            activation_plan: activation_plan
          },
          now: generated_at
        )
    end
  end

  defp cutover_gate_project_snapshot(nil), do: nil

  defp cutover_gate_project_snapshot(gate) when is_map(gate) do
    summary = CutoverGate.to_snapshot(%{projects: [gate]})
    Enum.find(summary.projects, &(required_string(&1, :project_id) == required_string(gate, :project_id)))
  end

  defp cutover_gate_project_snapshot(_gate), do: nil

  defp attach_project_cutover_gates(projects, cutover_gates) do
    gates_by_project =
      cutover_gates
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1.project_id, &1})

    Enum.map(projects, fn project ->
      Map.put(project, :cutover_gate, Map.get(gates_by_project, project.project_id))
    end)
  end

  defp cutover_operation_audit_snapshot(audit, projects, migration_readiness, activation_plan, cutover_gate, overview, generated_at) do
    project_audits =
      projects
      |> Enum.map(&value(&1, :cutover_operation_audit))
      |> Enum.filter(&is_map/1)

    cond do
      is_map(audit) and list_value(audit, :projects) != [] ->
        CutoverOperationAudit.to_snapshot(audit)

      project_audits != [] ->
        CutoverOperationAudit.to_snapshot(%{
          generated_at: generated_at,
          projects: project_audits
        })

      true ->
        CutoverOperationAudit.build(%{
          generated_at: generated_at,
          overview: overview,
          projects: projects,
          migration_readiness: migration_readiness,
          activation_plan: activation_plan,
          cutover_gate: cutover_gate
        })
    end
  end

  defp cutover_operation_audit_project_snapshot(nil), do: nil

  defp cutover_operation_audit_project_snapshot(audit) when is_map(audit) do
    summary = CutoverOperationAudit.to_snapshot(%{projects: [audit]})
    Enum.find(summary.projects, &(required_string(&1, :project_id) == required_string(audit, :project_id)))
  end

  defp cutover_operation_audit_project_snapshot(_audit), do: nil

  defp attach_project_cutover_operation_audits(projects, audits) do
    audits_by_project =
      audits
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1.project_id, &1})

    Enum.map(projects, fn project ->
      Map.put(project, :cutover_operation_audit, Map.get(audits_by_project, project.project_id))
    end)
  end

  defp cutover_audit_history_snapshot(history, projects, cutover_operation_audit, generated_at) do
    project_history =
      projects
      |> Enum.map(&value(&1, :cutover_audit_history))
      |> Enum.filter(&is_map/1)

    cond do
      is_map(history) and list_value(history, :projects) != [] ->
        CutoverAuditHistory.to_snapshot(history)

      project_history != [] ->
        CutoverAuditHistory.to_snapshot(%{
          generated_at: generated_at,
          projects: project_history
        })

      true ->
        CutoverAuditHistory.build(
          %{
            generated_at: generated_at,
            cutover_operation_audit: cutover_operation_audit
          },
          now: generated_at
        )
    end
  end

  defp cutover_audit_history_project_snapshot(nil), do: nil

  defp cutover_audit_history_project_snapshot(history) when is_map(history) do
    summary = CutoverAuditHistory.to_snapshot(%{projects: [history]})
    Enum.find(summary.projects, &(required_string(&1, :project_id) == required_string(history, :project_id)))
  end

  defp cutover_audit_history_project_snapshot(_history), do: nil

  defp attach_project_cutover_audit_history(projects, histories) do
    history_by_project =
      histories
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1.project_id, &1})

    Enum.map(projects, fn project ->
      Map.put(project, :cutover_audit_history, Map.get(history_by_project, project.project_id))
    end)
  end

  defp cutover_readiness_permit_snapshot(
         permit,
         projects,
         activation_plan,
         cutover_gate,
         cutover_operation_audit,
         cutover_audit_history,
         overview,
         generated_at
       ) do
    project_permits =
      projects
      |> Enum.map(&value(&1, :cutover_readiness_permit))
      |> Enum.filter(&is_map/1)

    cond do
      is_map(permit) and list_value(permit, :projects) != [] ->
        CutoverReadinessPermit.to_snapshot(permit)

      project_permits != [] ->
        CutoverReadinessPermit.to_snapshot(%{
          generated_at: generated_at,
          projects: project_permits
        })

      true ->
        CutoverReadinessPermit.build(
          %{
            generated_at: generated_at,
            hub_runtime: value(overview, :hub_runtime),
            overview: overview,
            projects: projects,
            activation_plan: activation_plan,
            cutover_gate: cutover_gate,
            cutover_operation_audit: cutover_operation_audit,
            cutover_audit_history: cutover_audit_history
          },
          now: generated_at
        )
    end
  end

  defp cutover_readiness_permit_project_snapshot(nil), do: nil

  defp cutover_readiness_permit_project_snapshot(permit) when is_map(permit) do
    summary = CutoverReadinessPermit.to_snapshot(%{projects: [permit]})
    Enum.find(summary.projects, &(required_string(&1, :project_id) == required_string(permit, :project_id)))
  end

  defp cutover_readiness_permit_project_snapshot(_permit), do: nil

  defp attach_project_cutover_readiness_permits(projects, permits) do
    permits_by_project =
      permits
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1.project_id, &1})

    Enum.map(projects, fn project ->
      Map.put(project, :cutover_readiness_permit, Map.get(permits_by_project, project.project_id))
    end)
  end

  defp cutover_execution_authorization_ledger_snapshot(ledger, projects, cutover_readiness_permit, overview, generated_at) do
    project_ledgers =
      projects
      |> Enum.map(&value(&1, :cutover_execution_authorization_ledger))
      |> Enum.filter(&is_map/1)

    cond do
      is_map(ledger) and list_value(ledger, :projects) != [] ->
        CutoverExecutionAuthorization.to_snapshot(ledger)

      project_ledgers != [] ->
        CutoverExecutionAuthorization.to_snapshot(%{
          generated_at: generated_at,
          projects: project_ledgers
        })

      true ->
        CutoverExecutionAuthorization.build(
          %{
            generated_at: generated_at,
            hub_runtime: value(overview, :hub_runtime),
            overview: overview,
            projects: projects,
            cutover_readiness_permit: cutover_readiness_permit
          },
          now: generated_at
        )
    end
  end

  defp cutover_execution_authorization_ledger_project_snapshot(nil), do: nil

  defp cutover_execution_authorization_ledger_project_snapshot(ledger) when is_map(ledger) do
    summary = CutoverExecutionAuthorization.to_snapshot(%{projects: [ledger]})
    Enum.find(summary.projects, &(required_string(&1, :project_id) == required_string(ledger, :project_id)))
  end

  defp cutover_execution_authorization_ledger_project_snapshot(_ledger), do: nil

  defp attach_project_cutover_execution_authorization_ledgers(projects, ledgers) do
    ledgers_by_project =
      ledgers
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1.project_id, &1})

    Enum.map(projects, fn project ->
      Map.put(project, :cutover_execution_authorization_ledger, Map.get(ledgers_by_project, project.project_id))
    end)
  end

  defp hub_runtime_readiness_snapshot(runtime, scheduler) do
    runtime = hub_runtime_overview_snapshot(runtime || %{})
    scheduler = scheduler_overview_snapshot(scheduler || %{})

    %{
      enabled: runtime.enabled,
      mode: runtime.mode,
      read_only: runtime.read_only,
      scheduler_enabled: scheduler.enabled,
      scheduler_status: scheduler.status,
      provider_executor: runtime.provider_executor,
      writeback_executor: runtime.writeback_executor,
      worker_starter: runtime.worker_starter,
      activation_probe: runtime.activation_probe
    }
  end

  defp migration_readiness_project_snapshot(nil), do: nil

  defp migration_readiness_project_snapshot(readiness) when is_map(readiness) do
    decision = normalize_readiness_decision(value(readiness, :decision))
    activation_plan = activation_plan_project_snapshot(value(readiness, :activation_plan))

    %{
      version: positive_integer(value(readiness, :version)) || @readiness_version,
      project_id: required_string(readiness, :project_id),
      migration_state: normalize_migration_state(value(readiness, :migration_state)),
      decision: decision,
      blocking_reasons:
        readiness
        |> list_value(:blocking_reasons)
        |> Enum.map(&readiness_reason_snapshot(&1, "blocking"))
        |> Enum.sort_by(&{&1.code, &1.source || ""}),
      advisory_reasons:
        readiness
        |> list_value(:advisory_reasons)
        |> Enum.map(&readiness_reason_snapshot(&1, "advisory"))
        |> Enum.sort_by(&{&1.code, &1.source || ""}),
      required_operator_actions:
        readiness
        |> list_value(:required_operator_actions)
        |> Enum.map(&operator_action_snapshot/1)
        |> Enum.reject(&blank?(&1.code))
        |> Enum.uniq_by(& &1.code)
        |> Enum.sort_by(& &1.code),
      evidence: readiness_evidence_snapshot(value(readiness, :evidence)),
      activation_plan: activation_plan,
      operator_acknowledgement:
        case activation_plan do
          nil -> nil
          plan -> plan.operator_acknowledgement
        end
    }
  end

  defp migration_readiness_project_snapshot(_readiness), do: nil

  defp attach_project_readiness(projects, decisions) do
    decisions_by_project =
      decisions
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1.project_id, &1})

    Enum.map(projects, fn project ->
      Map.put(project, :migration_readiness, Map.get(decisions_by_project, project.project_id))
    end)
  end

  defp attach_activation_plan_to_readiness_summary(readiness, activation_plans) do
    plans_by_project =
      activation_plans
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1.project_id, &1})

    projects =
      readiness
      |> list_value(:projects)
      |> Enum.map(fn project ->
        activation_plan = Map.get(plans_by_project, project.project_id)
        attach_activation_plan_to_readiness(project, activation_plan)
      end)

    Map.put(readiness, :projects, projects)
  end

  defp attach_project_activation_plans(projects, activation_plans) do
    plans_by_project =
      activation_plans
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1.project_id, &1})

    Enum.map(projects, fn project ->
      activation_plan = Map.get(plans_by_project, project.project_id)

      project
      |> Map.put(:activation_plan, activation_plan)
      |> put_in(
        [:migration_readiness],
        attach_activation_plan_to_readiness(value(project, :migration_readiness), activation_plan)
      )
    end)
  end

  defp attach_activation_plan_to_readiness(nil, _activation_plan), do: nil

  defp attach_activation_plan_to_readiness(readiness, nil) do
    Map.put(readiness, :activation_plan, nil)
  end

  defp attach_activation_plan_to_readiness(readiness, activation_plan) do
    readiness
    |> Map.put(:activation_plan, activation_plan)
    |> Map.put(:operator_acknowledgement, activation_plan.operator_acknowledgement)
  end

  defp project_readiness_decision(project, overview, generated_at) do
    blocking_reasons = project_blocking_readiness_reasons(project)
    advisory_reasons = project_advisory_readiness_reasons(project, overview)
    decision = project_readiness_state(project, blocking_reasons)

    %{
      version: @readiness_version,
      generated_at: generated_at,
      project_id: required_string(project, :project_id),
      migration_state: normalize_migration_state(value(project, :migration_state)),
      decision: decision,
      blocking_reasons: blocking_reasons,
      advisory_reasons: advisory_reasons,
      required_operator_actions: operator_actions(decision, blocking_reasons, advisory_reasons),
      evidence: project_readiness_evidence(project, overview)
    }
    |> migration_readiness_project_snapshot()
  rescue
    _error ->
      summary_error_readiness(required_string(project, :project_id), "summary_error", "hub_device_observability")
  catch
    _kind, _reason ->
      summary_error_readiness(required_string(project, :project_id), "summary_error", "hub_device_observability")
  end

  defp summary_error_readiness(project_id, code, source) do
    reason = readiness_reason(code, source, %{project_id: project_id})

    %{
      version: @readiness_version,
      project_id: project_id,
      migration_state: "hub_ready",
      decision: "unknown_manual_attention",
      blocking_reasons: [reason],
      advisory_reasons: [],
      required_operator_actions: operator_actions("unknown_manual_attention", [reason], []),
      evidence: %{summary_error: %{code: code, source: source}}
    }
    |> migration_readiness_project_snapshot()
  end

  defp project_blocking_readiness_reasons(project) do
    migration_state = normalize_migration_state(value(project, :migration_state))
    status = normalize_project_status(value(project, :status))
    detail = value(project, :detail) || %{}
    config = value(detail, :config) || %{}
    poll = value(detail, :poll_eligibility) || %{}
    preflight = value(project, :activation_preflight)
    runtime = value(project, :runtime) || %{}
    lifecycle = runtime |> value(:lifecycle) |> lifecycle_snapshot()
    lifecycle_counts = lifecycle |> value(:counts) |> lifecycle_count_snapshot()
    writebacks = writeback_snapshot(value(project, :writebacks))
    writeback_counts = writeback_count_snapshot(value(writebacks, :counts))
    summary_error = value(project, :summary_error)

    []
    |> maybe_add_summary_error_reason(summary_error)
    |> add_readiness_reason(
      status == "config_invalid" or not blank?(optional_string(config, :load_error)),
      "config_invalid",
      "project_registry",
      %{status: status, load_error: optional_string(config, :load_error)}
    )
    |> add_preflight_blocking_reasons(preflight, migration_state)
    |> add_provider_blocking_reasons(project)
    |> add_readiness_reason(writeback_counts.unknown > 0, "writeback_unknown", "writeback", %{unknown_count: writeback_counts.unknown})
    |> add_readiness_reason(
      writeback_counts.manual_attention > 0,
      "writeback_manual_attention",
      "writeback",
      %{manual_attention_count: writeback_counts.manual_attention}
    )
    |> add_readiness_reason(
      non_empty_list?(runtime, :active_attempts),
      "active_attempt_exists",
      "runtime_ledger",
      %{active_attempt_count: length(list_value(runtime, :active_attempts))}
    )
    |> add_readiness_reason(
      non_empty_list?(runtime, :pending_start_intents),
      "pending_start_intent",
      "runtime_ledger",
      %{pending_start_intent_count: length(list_value(runtime, :pending_start_intents))}
    )
    |> add_readiness_reason(
      non_empty_list?(runtime, :workspace_leases),
      "workspace_occupied",
      "runtime_ledger",
      %{workspace_lease_count: length(list_value(runtime, :workspace_leases))}
    )
    |> add_readiness_reason(
      non_empty_list?(lifecycle, :retained_workspace) or lifecycle_counts.retained_workspace > 0,
      "workspace_retained",
      "runtime_ledger",
      %{
        retained_workspace_count:
          max(
            length(list_value(lifecycle, :retained_workspace)),
            lifecycle_counts.retained_workspace
          )
      }
    )
    |> add_readiness_reason(lifecycle_counts.lost > 0, "worker_lifecycle_lost", "runtime_ledger", %{lost_count: lifecycle_counts.lost})
    |> add_readiness_reason(
      lifecycle_counts.unknown > 0,
      "worker_lifecycle_unknown",
      "runtime_ledger",
      %{unknown_count: lifecycle_counts.unknown}
    )
    |> add_readiness_reason(
      lifecycle_counts.manual_attention > 0,
      "manual_attention_required",
      "runtime_ledger",
      %{manual_attention_count: lifecycle_counts.manual_attention}
    )
    |> add_readiness_reason(
      safe_status(value(poll, :reason)) == "capacity_unavailable",
      "capacity_unavailable",
      "poll_coordination",
      %{reason: value(poll, :reason)}
    )
    |> add_readiness_reason(
      conflict_count(project) > 0,
      "writeback_conflict",
      "runtime_ledger",
      %{conflict_count: conflict_count(project)}
    )
    |> Enum.uniq_by(&{&1.code, &1.source})
  end

  defp maybe_add_summary_error_reason(reasons, nil), do: reasons

  defp maybe_add_summary_error_reason(reasons, summary_error) do
    code =
      case safe_status(value(summary_error, :code)) do
        "summary_version_incompatible" -> "summary_version_incompatible"
        _other -> "summary_error"
      end

    add_readiness_reason(reasons, true, code, optional_string(summary_error, :source) || "hub_device_observability", summary_error)
  end

  defp add_preflight_blocking_reasons(reasons, _preflight, "legacy_only"), do: reasons

  defp add_preflight_blocking_reasons(reasons, nil, _migration_state) do
    add_readiness_reason(reasons, true, "probe_missing", "activation_preflight", %{})
  end

  defp add_preflight_blocking_reasons(reasons, preflight, _migration_state) do
    status = safe_status(value(preflight, :status))

    reasons =
      preflight
      |> list_value(:detected_legacy_ownership)
      |> Enum.reduce(reasons, fn ownership, acc ->
        add_readiness_reason(
          acc,
          true,
          ownership_conflict_code(ownership),
          "activation_preflight",
          ownership_evidence(ownership, preflight)
        )
      end)

    reasons =
      preflight
      |> list_value(:unknown_probe_results)
      |> Enum.reduce(reasons, fn unknown, acc ->
        add_readiness_reason(
          acc,
          true,
          "probe_unknown",
          "activation_preflight",
          unknown_evidence(unknown, preflight)
        )
      end)

    reasons
    |> add_readiness_reason(
      status == "blocked_conflict" and list_value(preflight, :detected_legacy_ownership) == [],
      "legacy_ownership_conflict",
      "activation_preflight",
      preflight_evidence(preflight)
    )
    |> add_readiness_reason(
      status == "unknown_manual_attention" and list_value(preflight, :unknown_probe_results) == [],
      "probe_unknown",
      "activation_preflight",
      preflight_evidence(preflight)
    )
  end

  defp ownership_conflict_code(ownership) do
    source = optional_string(ownership, :source)
    reason = safe_status(value(ownership, :reason))

    cond do
      reason in ["legacy_service_active", "legacy_service_enabled"] ->
        reason

      source == "legacy_service" ->
        "legacy_service_active"

      source == "legacy_instance" ->
        "legacy_instance_registered"

      source == "provider_scope_owner" ->
        "provider_scope_owner_conflict"

      source == "workspace_owner" ->
        "workspace_owner_conflict"

      source == "runtime_path_owner" ->
        "runtime_path_owner_conflict"

      source == "log_path_owner" ->
        "log_path_owner_conflict"

      source == "state_path_owner" ->
        "state_path_owner_conflict"

      source == "dashboard_port_owner" ->
        "dashboard_port_owner_conflict"

      source == "api_port_owner" ->
        "api_port_owner_conflict"

      source == "instance_registry" ->
        "instance_registry_owner_conflict"

      true ->
        "legacy_ownership_conflict"
    end
  end

  defp add_provider_blocking_reasons(reasons, project) do
    project
    |> list_value(:backpressure_reasons)
    |> Enum.reduce(reasons, fn reason, acc ->
      code = safe_status(value(reason, :reason))

      if code in @provider_risk_codes do
        add_readiness_reason(acc, true, code, optional_string(reason, :source) || "provider_governance", %{
          detail: optional_string(reason, :detail)
        })
      else
        acc
      end
    end)
  end

  defp project_advisory_readiness_reasons(project, overview) do
    migration_state = normalize_migration_state(value(project, :migration_state))
    status = normalize_project_status(value(project, :status))
    runtime = hub_runtime_readiness_snapshot(value(overview, :hub_runtime), value(overview, :scheduler))
    preflight = value(project, :activation_preflight)
    recent_failures = recent_provider_failure_count(project)

    []
    |> add_readiness_reason(
      migration_state == "legacy_only",
      "legacy_only_project",
      "project_registry",
      %{migration_state: migration_state}
    )
    |> add_readiness_reason(
      migration_state == "hub_ready" and preflight_status(preflight) == "not_hub_managed",
      "hub_management_requires_operator_mark_hub_managed",
      "activation_preflight",
      preflight_evidence(preflight || %{})
    )
    |> add_readiness_reason(status == "paused", "project_paused", "project_registry", %{status: status})
    |> add_readiness_reason(not runtime.scheduler_enabled, "scheduler_disabled", "scheduler", %{status: runtime.scheduler_status})
    |> add_readiness_reason(runtime.read_only, "runtime_read_only", "hub_runtime", %{read_only: runtime.read_only})
    |> add_readiness_reason(
      not host_service_probe_enabled?(runtime.activation_probe),
      "activation_probe_not_host_service",
      "activation_preflight",
      runtime.activation_probe
    )
    |> add_readiness_reason(
      skeleton_executor?(runtime.provider_executor),
      "provider_executor_skeleton",
      "hub_runtime",
      runtime.provider_executor
    )
    |> add_readiness_reason(
      skeleton_executor?(runtime.writeback_executor),
      "writeback_executor_skeleton",
      "hub_runtime",
      runtime.writeback_executor
    )
    |> add_readiness_reason(
      skeleton_worker_starter?(runtime.worker_starter),
      "worker_starter_skeleton",
      "hub_runtime",
      runtime.worker_starter
    )
    |> add_readiness_reason(
      recent_failures > 0,
      "recent_provider_retryable_failure",
      "provider_governance",
      %{recent_failure_count: recent_failures}
    )
    |> Enum.uniq_by(&{&1.code, &1.source})
    |> advisory_reasons()
  end

  defp project_readiness_state(project, blocking_reasons) do
    migration_state = normalize_migration_state(value(project, :migration_state))
    blocking_codes = MapSet.new(blocking_reasons, & &1.code)

    cond do
      migration_state == "legacy_only" ->
        "legacy_only"

      MapSet.size(blocking_codes) > 0 and Enum.any?(blocking_codes, &(&1 in @unknown_readiness_codes)) ->
        "unknown_manual_attention"

      MapSet.size(blocking_codes) > 0 ->
        "blocked"

      migration_state == "hub_managed" ->
        "already_hub_managed"

      hub_management_ready_project?(project) ->
        "ready_for_hub_management"

      true ->
        "ready_for_dry_run"
    end
  end

  defp hub_management_ready_project?(project) do
    preflight = value(project, :activation_preflight)

    normalize_migration_state(value(project, :migration_state)) == "hub_ready" and
      preflight_status(preflight) == "not_hub_managed" and
      list_value(preflight, :detected_legacy_ownership) == [] and
      list_value(preflight, :unknown_probe_results) == [] and
      optional_string(preflight || %{}, :probe_source) == "host_service_probe"
  end

  defp global_readiness_risks(project_decisions, overview) do
    runtime = hub_runtime_readiness_snapshot(value(overview, :hub_runtime), value(overview, :scheduler))
    provider = provider_governance_overview_snapshot(value(overview, :provider_governance))
    capacity = capacity_workspace_overview_snapshot(value(overview, :capacity_workspace))
    writeback = writeback_overview_snapshot(value(overview, :writeback))
    lifecycle = lifecycle_overview_snapshot(value(overview, :lifecycle))
    manual_attention = manual_attention_overview_snapshot(value(overview, :manual_attention))

    blocking =
      []
      |> add_readiness_reason(not runtime.scheduler_enabled, "scheduler_disabled", "scheduler", %{status: runtime.scheduler_status})
      |> add_readiness_reason(
        not host_service_probe_enabled?(runtime.activation_probe),
        "activation_probe_not_host_service",
        "activation_preflight",
        runtime.activation_probe
      )
      |> add_readiness_reason(provider.queue_pressure_count > 0, "queue_pressure", "provider_governance", %{count: provider.queue_pressure_count})
      |> add_readiness_reason(provider.quota_backoff_count > 0, "provider_backoff", "provider_governance", %{count: provider.quota_backoff_count})
      |> add_readiness_reason(provider.circuit_open_count > 0, "provider_circuit_open", "provider_governance", %{count: provider.circuit_open_count})
      |> add_readiness_reason(writeback.counts.unknown > 0, "writeback_unknown", "writeback", %{count: writeback.counts.unknown})
      |> add_readiness_reason(
        writeback.manual_attention_count > 0,
        "writeback_manual_attention",
        "writeback",
        %{count: writeback.manual_attention_count}
      )
      |> add_readiness_reason(
        lifecycle.unresolved_count > 0,
        "worker_lifecycle_unknown",
        "runtime_ledger",
        %{count: lifecycle.unresolved_count}
      )
      |> add_readiness_reason(
        capacity.active_attempt_count > 0,
        "active_attempt_exists",
        "runtime_ledger",
        %{count: capacity.active_attempt_count}
      )
      |> add_readiness_reason(
        capacity.pending_start_intent_count > 0,
        "pending_start_intent",
        "runtime_ledger",
        %{count: capacity.pending_start_intent_count}
      )
      |> add_readiness_reason(
        capacity.workspace_lease_count > 0,
        "workspace_occupied",
        "runtime_ledger",
        %{count: capacity.workspace_lease_count}
      )
      |> add_readiness_reason(
        capacity.unreleased_capacity_count > 0,
        "capacity_unavailable",
        "runtime_ledger",
        %{count: capacity.unreleased_capacity_count}
      )
      |> add_readiness_reason(
        manual_attention.project_count > 0,
        "manual_attention_required",
        "hub_device_observability",
        %{project_count: manual_attention.project_count}
      )

    advisory =
      []
      |> add_readiness_reason(runtime.read_only, "runtime_read_only", "hub_runtime", %{read_only: runtime.read_only})
      |> add_readiness_reason(
        skeleton_executor?(runtime.provider_executor),
        "provider_executor_skeleton",
        "hub_runtime",
        runtime.provider_executor
      )
      |> add_readiness_reason(
        skeleton_executor?(runtime.writeback_executor),
        "writeback_executor_skeleton",
        "hub_runtime",
        runtime.writeback_executor
      )
      |> add_readiness_reason(
        skeleton_worker_starter?(runtime.worker_starter),
        "worker_starter_skeleton",
        "hub_runtime",
        runtime.worker_starter
      )
      |> add_readiness_reason(provider.recent_failure_count > 0, "recent_provider_retryable_failure", "provider_governance", %{
        count: provider.recent_failure_count,
        recent_failure_classes: provider.recent_failure_classes
      })
      |> add_readiness_reason(
        readiness_decision_count(project_decisions, "legacy_only") > 0,
        "legacy_only_projects_present",
        "project_registry",
        %{project_count: readiness_decision_count(project_decisions, "legacy_only")}
      )
      |> advisory_reasons()

    %{blocking: blocking, advisory: advisory}
  end

  defp readiness_status(status, project_decisions, global_blocking_risks) do
    explicit = normalize_readiness_decision(status)

    cond do
      explicit != "unknown_manual_attention" and safe_status(status) in @readiness_decisions ->
        explicit

      global_blocking_risks != [] or readiness_decision_count(project_decisions, "blocked") > 0 ->
        "blocked"

      readiness_decision_count(project_decisions, "unknown_manual_attention") > 0 ->
        "unknown_manual_attention"

      readiness_decision_count(project_decisions, "ready_for_hub_management") > 0 ->
        "ready_for_hub_management"

      readiness_decision_count(project_decisions, "ready_for_dry_run") > 0 ->
        "ready_for_dry_run"

      readiness_decision_count(project_decisions, "already_hub_managed") > 0 ->
        "already_hub_managed"

      true ->
        "legacy_only"
    end
  end

  defp readiness_counts_snapshot(counts, project_decisions) when is_map(counts) do
    decisions = Map.new(@readiness_decisions, &{String.to_atom(&1), 0})
    migration_states = Map.new(@migration_states, &{String.to_atom(&1), 0})

    decision_counts =
      Enum.reduce(project_decisions, decisions, fn project, acc ->
        key = project.decision |> normalize_readiness_decision() |> String.to_existing_atom()
        Map.update!(acc, key, &(&1 + 1))
      end)

    migration_state_counts =
      Enum.reduce(project_decisions, migration_states, fn project, acc ->
        key = project.migration_state |> normalize_migration_state() |> String.to_existing_atom()
        Map.update!(acc, key, &(&1 + 1))
      end)

    %{
      project_count: non_negative_integer(value(counts, :project_count)) || length(project_decisions),
      migration_states: migration_state_counts,
      decisions: decision_counts,
      blocked_count: non_negative_integer(value(counts, :blocked_count)) || decision_counts.blocked,
      unknown_manual_attention_count:
        non_negative_integer(value(counts, :unknown_manual_attention_count)) ||
          decision_counts.unknown_manual_attention,
      ready_for_dry_run_count:
        non_negative_integer(value(counts, :ready_for_dry_run_count)) ||
          decision_counts.ready_for_dry_run,
      ready_for_hub_management_count:
        non_negative_integer(value(counts, :ready_for_hub_management_count)) ||
          decision_counts.ready_for_hub_management,
      config_error_count: reason_project_count(project_decisions, "config_invalid"),
      provider_backoff_risk_count: provider_risk_project_count(project_decisions)
    }
  end

  defp readiness_counts_snapshot(_counts, project_decisions), do: readiness_counts_snapshot(%{}, project_decisions)

  defp readiness_reason_snapshot(reason, default_level) when is_map(reason) do
    code = safe_status(value(reason, :code) || value(reason, :reason)) |> blank_to_default("unknown")
    level = normalize_risk_level(value(reason, :level), default_level)

    %{
      code: code,
      label: optional_string(reason, :label) || reason_label(code),
      source: optional_string(reason, :source),
      level: level,
      blocks_hub_management: readiness_blocks_hub_management?(code, level, value(reason, :blocks_hub_management)),
      evidence: sanitize_value(value(reason, :evidence) || %{})
    }
    |> maybe_put(:count, non_negative_integer(value(reason, :count)))
    |> maybe_put(:project_count, non_negative_integer(value(reason, :project_count)))
  end

  defp readiness_reason_snapshot(reason, default_level) do
    readiness_reason_snapshot(%{code: reason}, default_level)
  end

  defp operator_action_snapshot(action) when is_map(action) do
    code = safe_status(value(action, :code)) |> blank_to_default("manual_review")

    %{
      code: code,
      label: optional_string(action, :label) || action_label(code)
    }
  end

  defp operator_action_snapshot(action), do: operator_action_snapshot(%{code: action})

  defp readiness_evidence_snapshot(evidence) when is_map(evidence), do: sanitize_value(evidence)
  defp readiness_evidence_snapshot(_evidence), do: %{}

  defp add_readiness_reason(reasons, true, code, source, evidence) do
    [readiness_reason(code, source, evidence) | reasons]
  end

  defp add_readiness_reason(reasons, condition, _code, _source, _evidence)
       when condition in [false, nil],
       do: reasons

  defp readiness_reason(code, source, evidence) do
    %{
      code: safe_status(code),
      label: reason_label(code),
      source: source,
      level: "blocking",
      blocks_hub_management: true,
      evidence: sanitize_value(evidence || %{})
    }
  end

  defp advisory_reasons(reasons) do
    Enum.map(reasons, &Map.merge(&1, %{level: "advisory", blocks_hub_management: false}))
  end

  defp normalize_risk_level(level, default_level) do
    normalized = safe_status(level) |> blank_to_default(default_level)

    if normalized in @risk_levels do
      normalized
    else
      default_level
    end
  end

  defp readiness_blocks_hub_management?(_code, "advisory", value), do: value == true

  defp readiness_blocks_hub_management?(code, _level, value) do
    value != false and MapSet.member?(@hub_management_blocking_code_set, code)
  end

  defp operator_actions(decision, blocking_reasons, advisory_reasons) do
    reason_codes =
      (blocking_reasons ++ advisory_reasons)
      |> Enum.map(& &1.code)
      |> MapSet.new()

    reason_codes
    |> Enum.flat_map(&actions_for_reason/1)
    |> Kernel.++(actions_for_decision(decision))
    |> Enum.map(&%{code: &1, label: action_label(&1)})
    |> Enum.uniq_by(& &1.code)
  end

  defp actions_for_reason("legacy_only_project"), do: ["prepare_hub_yaml"]
  defp actions_for_reason("legacy_service_active"), do: ["stop_disable_legacy_service"]
  defp actions_for_reason("legacy_service_enabled"), do: ["stop_disable_legacy_service"]
  defp actions_for_reason("legacy_instance_registered"), do: ["stop_disable_legacy_service"]
  defp actions_for_reason("config_invalid"), do: ["fix_project_config"]
  defp actions_for_reason("summary_error"), do: ["inspect_summary_error"]
  defp actions_for_reason("summary_version_incompatible"), do: ["inspect_summary_error"]
  defp actions_for_reason("probe_missing"), do: ["enable_host_service_probe"]
  defp actions_for_reason("probe_unknown"), do: ["enable_host_service_probe"]
  defp actions_for_reason("activation_probe_not_host_service"), do: ["enable_host_service_probe"]
  defp actions_for_reason("provider_rate_limit"), do: ["wait_provider_backoff"]
  defp actions_for_reason("provider_backoff"), do: ["wait_provider_backoff"]
  defp actions_for_reason("provider_circuit_open"), do: ["fix_provider_auth_or_circuit"]
  defp actions_for_reason("provider_unavailable"), do: ["restore_provider_access"]
  defp actions_for_reason("queue_pressure"), do: ["wait_provider_queue"]
  defp actions_for_reason("writeback_unknown"), do: ["resolve_writeback_manual_attention"]
  defp actions_for_reason("writeback_manual_attention"), do: ["resolve_writeback_manual_attention"]
  defp actions_for_reason("manual_attention_required"), do: ["resolve_manual_attention"]
  defp actions_for_reason("active_attempt_exists"), do: ["wait_or_reconcile_lifecycle"]
  defp actions_for_reason("pending_start_intent"), do: ["wait_or_reconcile_lifecycle"]
  defp actions_for_reason("start_intent_unresolved"), do: ["wait_or_reconcile_lifecycle"]
  defp actions_for_reason("worker_lifecycle_unknown"), do: ["wait_or_reconcile_lifecycle"]
  defp actions_for_reason("worker_lifecycle_lost"), do: ["wait_or_reconcile_lifecycle"]
  defp actions_for_reason("workspace_occupied"), do: ["release_workspace_or_capacity"]
  defp actions_for_reason("workspace_retained"), do: ["release_workspace_or_capacity"]
  defp actions_for_reason("capacity_unavailable"), do: ["release_workspace_or_capacity"]
  defp actions_for_reason("project_paused"), do: ["unpause_project_when_ready"]
  defp actions_for_reason("scheduler_disabled"), do: ["enable_hub_scheduler_before_management"]
  defp actions_for_reason("provider_executor_skeleton"), do: ["confirm_hub_executor_modes"]
  defp actions_for_reason("writeback_executor_skeleton"), do: ["confirm_hub_executor_modes"]
  defp actions_for_reason("worker_starter_skeleton"), do: ["confirm_hub_executor_modes"]
  defp actions_for_reason("runtime_read_only"), do: ["keep_read_only_dry_run"]
  defp actions_for_reason("hub_management_requires_operator_mark_hub_managed"), do: ["mark_hub_managed_after_checks"]

  defp actions_for_reason(reason)
       when reason in [
              "provider_scope_owner_conflict",
              "workspace_owner_conflict",
              "runtime_path_owner_conflict",
              "log_path_owner_conflict",
              "state_path_owner_conflict",
              "dashboard_port_owner_conflict",
              "api_port_owner_conflict",
              "instance_registry_owner_conflict",
              "legacy_ownership_conflict"
            ],
       do: ["resolve_legacy_ownership_conflict"]

  defp actions_for_reason(_reason), do: ["manual_review"]

  defp actions_for_decision("ready_for_dry_run"), do: ["run_read_only_dry_run"]
  defp actions_for_decision("ready_for_hub_management"), do: ["mark_hub_managed_after_checks"]
  defp actions_for_decision("legacy_only"), do: ["prepare_hub_yaml"]
  defp actions_for_decision(_decision), do: []

  defp reason_label(code) do
    code
    |> safe_status()
    |> String.replace("_", " ")
  end

  defp action_label("prepare_hub_yaml"), do: "Prepare HUB.yaml"
  defp action_label("stop_disable_legacy_service"), do: "Stop/disable legacy service"
  defp action_label("fix_project_config"), do: "Fix project config"
  defp action_label("inspect_summary_error"), do: "Inspect safe summary error"
  defp action_label("enable_host_service_probe"), do: "Enable host-service probe"
  defp action_label("wait_provider_backoff"), do: "Wait for provider backoff"
  defp action_label("fix_provider_auth_or_circuit"), do: "Fix provider auth/circuit"
  defp action_label("restore_provider_access"), do: "Restore provider access"
  defp action_label("wait_provider_queue"), do: "Wait for provider queue"
  defp action_label("resolve_writeback_manual_attention"), do: "Resolve writeback manual attention"
  defp action_label("resolve_manual_attention"), do: "Resolve manual attention"
  defp action_label("wait_or_reconcile_lifecycle"), do: "Wait/reconcile lifecycle"
  defp action_label("release_workspace_or_capacity"), do: "Release workspace/capacity"
  defp action_label("unpause_project_when_ready"), do: "Unpause project when ready"
  defp action_label("enable_hub_scheduler_before_management"), do: "Enable Hub scheduler before management"
  defp action_label("confirm_hub_executor_modes"), do: "Confirm Hub executor modes"
  defp action_label("keep_read_only_dry_run"), do: "Keep dry-run read-only"
  defp action_label("mark_hub_managed_after_checks"), do: "Mark hub_managed after checks"
  defp action_label("run_read_only_dry_run"), do: "Run read-only dry-run"
  defp action_label("resolve_legacy_ownership_conflict"), do: "Resolve legacy ownership conflict"

  defp action_label(code) do
    code
    |> safe_status()
    |> String.replace("_", " ")
  end

  defp project_readiness_evidence(project, overview) do
    preflight = value(project, :activation_preflight)
    poll = project |> value(:detail) |> value(:poll_eligibility)
    runtime = value(project, :runtime) || %{}
    lifecycle = runtime |> value(:lifecycle) |> lifecycle_snapshot()
    writebacks = writeback_snapshot(value(project, :writebacks))
    provider_queue = provider_queue_project_snapshot(value(project, :provider_queue))
    config = project |> value(:detail) |> value(:config)

    %{
      registry: %{
        migration_state: normalize_migration_state(value(project, :migration_state)),
        status: normalize_project_status(value(project, :status)),
        dispatch_enabled: truthy?(value(project, :dispatch_enabled))
      },
      hub_runtime: hub_runtime_readiness_snapshot(value(overview, :hub_runtime), value(overview, :scheduler)),
      config: %{
        snapshot_version: optional_string(config || %{}, :snapshot_version),
        config_fingerprint: optional_string(config || %{}, :config_fingerprint),
        loaded_at: iso8601(value(config || %{}, :loaded_at)),
        load_error: optional_string(config || %{}, :load_error)
      },
      activation_preflight: preflight_evidence(preflight || %{}),
      poll_eligibility: %{
        allow_poll: truthy?(value(poll || %{}, :allow_poll)),
        reason: safe_status(value(poll || %{}, :reason)),
        next_due_at: iso8601(value(poll || %{}, :next_due_at)),
        backoff_until: iso8601(value(poll || %{}, :backoff_until))
      },
      provider_governance: %{
        pending_count: provider_queue.pending_count,
        running_count: provider_queue.running_count,
        backpressure_count: length(provider_queue.backpressure),
        recent_result_count: length(provider_queue.recent_results)
      },
      runtime_ledger: %{
        active_attempt_count: length(list_value(runtime, :active_attempts)),
        pending_start_intent_count: length(list_value(runtime, :pending_start_intents)),
        workspace_lease_count: length(list_value(runtime, :workspace_leases)),
        retry_backoff_count: length(list_value(runtime, :retry_backoff)),
        lifecycle_counts: lifecycle_count_snapshot(value(lifecycle, :counts))
      },
      writeback: %{counts: writeback_count_snapshot(value(writebacks, :counts))},
      summary_error: summary_error_snapshot(value(project, :summary_error))
    }
  end

  defp preflight_evidence(preflight) when is_map(preflight) do
    %{
      status: normalize_activation_preflight_status(value(preflight, :status)),
      safe_to_manage: truthy?(value(preflight, :safe_to_manage)),
      reason: optional_string(preflight, :reason),
      checked_at: iso8601(value(preflight, :checked_at)),
      probe_source: optional_string(preflight, :probe_source),
      conflict_count: non_negative_integer(value(preflight, :conflict_count)) || 0,
      manual_attention_count: non_negative_integer(value(preflight, :manual_attention_count)) || 0,
      detected_legacy_ownership_count: length(list_value(preflight, :detected_legacy_ownership)),
      unknown_probe_result_count: length(list_value(preflight, :unknown_probe_results)),
      blocked_operations: string_list(value(preflight, :blocked_operations))
    }
  end

  defp preflight_evidence(_preflight), do: %{}

  defp ownership_evidence(ownership, preflight) do
    %{
      source: optional_string(ownership, :source),
      reason: optional_string(ownership, :reason),
      owner: optional_string(ownership, :owner),
      checked_at: iso8601(value(preflight, :checked_at)),
      probe_source: optional_string(preflight, :probe_source)
    }
  end

  defp unknown_evidence(unknown, preflight) do
    %{
      source: optional_string(unknown, :source),
      reason: optional_string(unknown, :reason),
      checked_at: iso8601(value(preflight, :checked_at)),
      probe_source: optional_string(preflight, :probe_source)
    }
  end

  defp preflight_status(nil), do: nil
  defp preflight_status(preflight), do: safe_status(value(preflight, :status))

  defp host_service_probe_enabled?(probe) when is_map(probe) do
    truthy?(value(probe, :host_service_probe)) or optional_string(probe, :source) == "host_service_probe" or
      optional_string(probe, :mode) == "host_service"
  end

  defp host_service_probe_enabled?(_probe), do: false

  defp skeleton_executor?(executor) when is_map(executor) do
    safe_status(value(executor, :mode)) == "skeleton" or value(executor, :provider_io) == false
  end

  defp skeleton_executor?(_executor), do: false

  defp skeleton_worker_starter?(starter) when is_map(starter) do
    safe_status(value(starter, :mode)) == "skeleton" or value(starter, :worker_start) == false
  end

  defp skeleton_worker_starter?(_starter), do: false

  defp recent_provider_failure_count(project) do
    project
    |> value(:provider_queue)
    |> list_value(:recent_results)
    |> Enum.count(&provider_failure_result?/1)
  end

  defp conflict_count(project), do: length(list_value(project, :conflicts))

  defp readiness_decision_count(project_decisions, decision) do
    Enum.count(project_decisions, &(&1.decision == decision))
  end

  defp reason_project_count(project_decisions, reason_code) do
    Enum.count(project_decisions, fn project ->
      Enum.any?(project.blocking_reasons ++ project.advisory_reasons, &(&1.code == reason_code))
    end)
  end

  defp provider_risk_project_count(project_decisions) do
    Enum.count(project_decisions, fn project ->
      Enum.any?(project.blocking_reasons, &(&1.code in @provider_risk_codes))
    end)
  end

  defp normalize_readiness_decision(value) do
    case safe_status(value) do
      "ready_for_dry_run" -> "ready_for_dry_run"
      "ready_for_hub_management" -> "ready_for_hub_management"
      "already_hub_managed" -> "already_hub_managed"
      "legacy_only" -> "legacy_only"
      "blocked" -> "blocked"
      "unknown_manual_attention" -> "unknown_manual_attention"
      "manual_attention" -> "unknown_manual_attention"
      _other -> "unknown_manual_attention"
    end
  end

  defp scheduler_overview_snapshot(scheduler) when is_map(scheduler) do
    %{
      enabled: truthy?(value(scheduler, :enabled)),
      status: safe_status(value(scheduler, :status)) |> blank_to_default("disabled"),
      queued: truthy?(value(scheduler, :queued)),
      running: truthy?(value(scheduler, :running)),
      coalesced: truthy?(value(scheduler, :coalesced)),
      next_tick_at: iso8601(value(scheduler, :next_tick_at)),
      next_reason: safe_status(value(scheduler, :next_reason)),
      last_reason: safe_status(value(scheduler, :last_reason)),
      last_error: optional_string(scheduler, :last_error),
      counts: sanitize_value(value(scheduler, :counts) || %{}),
      unresolved_runtime: sanitize_value(value(scheduler, :unresolved_runtime) || %{})
    }
  end

  defp scheduler_overview_snapshot(_scheduler), do: scheduler_overview_snapshot(%{})

  defp status_counts_snapshot(counts) when is_map(counts) do
    base = Map.new(@project_statuses, &{String.to_atom(&1), 0})

    Enum.reduce(base, %{}, fn {key, default}, acc ->
      Map.put(acc, key, non_negative_integer(value(counts, key)) || default)
    end)
  end

  defp provider_governance_overview_snapshot(provider) when is_map(provider) do
    %{
      pending_count: non_negative_integer(value(provider, :pending_count)) || 0,
      running_count: non_negative_integer(value(provider, :running_count)) || 0,
      provider_scope_count: non_negative_integer(value(provider, :provider_scope_count)) || 0,
      queue_pressure_count: non_negative_integer(value(provider, :queue_pressure_count)) || 0,
      quota_backoff_count: non_negative_integer(value(provider, :quota_backoff_count)) || 0,
      circuit_open_count: non_negative_integer(value(provider, :circuit_open_count)) || 0,
      unsupported_operation_count: non_negative_integer(value(provider, :unsupported_operation_count)) || 0,
      recent_failure_count: non_negative_integer(value(provider, :recent_failure_count)) || 0,
      manual_attention_count: non_negative_integer(value(provider, :manual_attention_count)) || 0,
      backpressure_reasons: reason_count_snapshot(value(provider, :backpressure_reasons)),
      recent_failure_classes: sanitize_list(value(provider, :recent_failure_classes))
    }
  end

  defp provider_governance_overview_snapshot(_provider), do: provider_governance_overview_snapshot(%{})

  defp capacity_workspace_overview_snapshot(capacity) when is_map(capacity) do
    %{
      active_attempt_count: non_negative_integer(value(capacity, :active_attempt_count)) || 0,
      pending_start_intent_count: non_negative_integer(value(capacity, :pending_start_intent_count)) || 0,
      unknown_lifecycle_count: non_negative_integer(value(capacity, :unknown_lifecycle_count)) || 0,
      workspace_lease_count: non_negative_integer(value(capacity, :workspace_lease_count)) || 0,
      unreleased_capacity_count: non_negative_integer(value(capacity, :unreleased_capacity_count)) || 0,
      waiting_capacity_count: non_negative_integer(value(capacity, :waiting_capacity_count)) || 0,
      max_agent_capacity: non_negative_integer(value(capacity, :max_agent_capacity))
    }
  end

  defp capacity_workspace_overview_snapshot(_capacity), do: capacity_workspace_overview_snapshot(%{})

  defp writeback_overview_snapshot(writeback) when is_map(writeback) do
    %{
      counts: writeback_count_snapshot(value(writeback, :counts)),
      intent_conflict_count: non_negative_integer(value(writeback, :intent_conflict_count)) || 0,
      unknown_non_idempotent_count: non_negative_integer(value(writeback, :unknown_non_idempotent_count)) || 0,
      provider_lookup_required_count: non_negative_integer(value(writeback, :provider_lookup_required_count)) || 0,
      dangerous_replay_rejected_count: non_negative_integer(value(writeback, :dangerous_replay_rejected_count)) || 0,
      manual_attention_count: non_negative_integer(value(writeback, :manual_attention_count)) || 0,
      recent_errors: sanitize_list(value(writeback, :recent_errors))
    }
  end

  defp writeback_overview_snapshot(_writeback), do: writeback_overview_snapshot(%{})

  defp activation_preflight_overview_snapshot(preflight) when is_map(preflight) do
    %{
      blocked_project_count: non_negative_integer(value(preflight, :blocked_project_count)) || 0,
      unknown_project_count: non_negative_integer(value(preflight, :unknown_project_count)) || 0,
      manual_attention_count: non_negative_integer(value(preflight, :manual_attention_count)) || 0,
      conflict_count: non_negative_integer(value(preflight, :conflict_count)) || 0,
      blocked_operations: string_list(value(preflight, :blocked_operations)),
      reason_counts: reason_count_snapshot(value(preflight, :reason_counts))
    }
  end

  defp activation_preflight_overview_snapshot(_preflight), do: activation_preflight_overview_snapshot(%{})

  defp cutover_gate_overview_snapshot(gate) when is_map(gate) do
    counts = value(gate, :counts) || %{}

    %{
      status: safe_status(value(gate, :status)) |> blank_to_default("not_applicable"),
      project_count: non_negative_integer(value(counts, :project_count)) || length(list_value(gate, :projects)),
      allowed_count: non_negative_integer(value(counts, :allowed_count)) || 0,
      staged_ready_count: non_negative_integer(value(counts, :staged_ready_count)) || 0,
      blocked_count: non_negative_integer(value(counts, :blocked_count)) || 0,
      manual_attention_count: non_negative_integer(value(counts, :manual_attention_count)) || 0,
      not_applicable_count: non_negative_integer(value(counts, :not_applicable_count)) || 0,
      staged_ownership_record_count:
        non_negative_integer(value(counts, :staged_ownership_record_count)) ||
          length(list_value(gate, :staged_ownership_records)),
      blocked_operations: cutover_gate_blocked_operations(gate),
      allowed_operations: cutover_gate_allowed_operations(gate),
      decision_counts: sanitize_value(value(counts, :decisions) || %{})
    }
  end

  defp cutover_gate_overview_snapshot(_gate), do: cutover_gate_overview_snapshot(%{})

  defp cutover_operation_audit_overview_snapshot(audit) when is_map(audit) do
    counts = value(audit, :counts) || %{}

    %{
      status: safe_status(value(audit, :status)) |> blank_to_default("no_request"),
      project_count: non_negative_integer(value(counts, :project_count)) || length(list_value(audit, :projects)),
      request_count: non_negative_integer(value(counts, :request_count)) || 0,
      no_request_count: non_negative_integer(value(counts, :no_request_count)) || 0,
      dry_run_ready_count: non_negative_integer(value(counts, :dry_run_ready_count)) || 0,
      blocked_count: non_negative_integer(value(counts, :blocked_count)) || 0,
      manual_attention_count: non_negative_integer(value(counts, :manual_attention_count)) || 0,
      unsupported_count: non_negative_integer(value(counts, :unsupported_count)) || 0,
      summary_error_count: non_negative_integer(value(counts, :summary_error_count)) || 0,
      requested_operation_count: non_negative_integer(value(counts, :requested_operation_count)) || 0,
      operation_decision_counts: sanitize_value(value(counts, :operation_decision_counts) || %{})
    }
  end

  defp cutover_operation_audit_overview_snapshot(_audit), do: cutover_operation_audit_overview_snapshot(%{})

  defp cutover_audit_history_overview_snapshot(history) when is_map(history) do
    counts = value(history, :counts) || %{}

    %{
      status: safe_status(value(history, :status)) |> blank_to_default("no_history"),
      project_count: non_negative_integer(value(counts, :project_count)) || length(list_value(history, :projects)),
      history_entry_count: non_negative_integer(value(counts, :history_entry_count)) || 0,
      unresolved_manual_attention_count: non_negative_integer(value(counts, :unresolved_manual_attention_count)) || 0,
      closed_count: non_negative_integer(value(counts, :closed_count)) || 0,
      deferred_count: non_negative_integer(value(counts, :deferred_count)) || 0,
      stale_count: non_negative_integer(value(counts, :stale_count)) || 0,
      conflict_count: non_negative_integer(value(counts, :conflict_count)) || 0,
      malformed_count: non_negative_integer(value(counts, :malformed_count)) || 0,
      unsupported_count: non_negative_integer(value(counts, :unsupported_count)) || 0,
      summary_error_count: non_negative_integer(value(counts, :summary_error_count)) || 0,
      no_history_count: non_negative_integer(value(counts, :no_history_count)) || 0,
      dry_run_only_count: non_negative_integer(value(counts, :dry_run_only_count)) || 0
    }
  end

  defp cutover_audit_history_overview_snapshot(_history), do: cutover_audit_history_overview_snapshot(%{})

  defp cutover_readiness_permit_overview_snapshot(permit) when is_map(permit) do
    counts = value(permit, :counts) || %{}

    %{
      status: safe_status(value(permit, :status)) |> blank_to_default("no_request"),
      project_count: non_negative_integer(value(counts, :project_count)) || length(list_value(permit, :projects)),
      permit_count: non_negative_integer(value(counts, :permit_count)) || 0,
      ready_count: non_negative_integer(value(counts, :ready_count)) || 0,
      blocked_count: non_negative_integer(value(counts, :blocked_count)) || 0,
      stale_count: non_negative_integer(value(counts, :stale_count)) || 0,
      manual_attention_count: non_negative_integer(value(counts, :manual_attention_count)) || 0,
      unsupported_count: non_negative_integer(value(counts, :unsupported_count)) || 0,
      malformed_count: non_negative_integer(value(counts, :malformed_count)) || 0,
      summary_error_count: non_negative_integer(value(counts, :summary_error_count)) || 0,
      no_request_count: non_negative_integer(value(counts, :no_request_count)) || 0,
      operation_decision_counts: sanitize_value(value(counts, :operation_decision_counts) || %{})
    }
  end

  defp cutover_readiness_permit_overview_snapshot(_permit), do: cutover_readiness_permit_overview_snapshot(%{})

  defp cutover_execution_authorization_ledger_overview_snapshot(ledger) when is_map(ledger) do
    counts = value(ledger, :counts) || %{}

    %{
      status: safe_status(value(ledger, :status)) |> blank_to_default("no_ready_permit"),
      project_count: non_negative_integer(value(counts, :project_count)) || length(list_value(ledger, :projects)),
      authorization_request_count: non_negative_integer(value(counts, :authorization_request_count)) || 0,
      record_count: non_negative_integer(value(counts, :record_count)) || 0,
      authorized_count: non_negative_integer(value(counts, :authorized_count)) || 0,
      blocked_count: non_negative_integer(value(counts, :blocked_count)) || 0,
      stale_count: non_negative_integer(value(counts, :stale_count)) || 0,
      manual_attention_count: non_negative_integer(value(counts, :manual_attention_count)) || 0,
      unsupported_count: non_negative_integer(value(counts, :unsupported_count)) || 0,
      malformed_count: non_negative_integer(value(counts, :malformed_count)) || 0,
      no_ready_permit_count: non_negative_integer(value(counts, :no_ready_permit_count)) || 0,
      summary_error_count: non_negative_integer(value(counts, :summary_error_count)) || 0,
      operation_status_counts: sanitize_value(value(counts, :operation_status_counts) || %{})
    }
  end

  defp cutover_execution_authorization_ledger_overview_snapshot(_ledger), do: cutover_execution_authorization_ledger_overview_snapshot(%{})

  defp lifecycle_overview_snapshot(lifecycle) when is_map(lifecycle) do
    %{
      counts: lifecycle_count_snapshot(value(lifecycle, :counts)),
      unresolved_count: non_negative_integer(value(lifecycle, :unresolved_count)) || 0,
      retained_workspace_count: non_negative_integer(value(lifecycle, :retained_workspace_count)) || 0,
      released_workspace_count: non_negative_integer(value(lifecycle, :released_workspace_count)) || 0,
      manual_attention_count: non_negative_integer(value(lifecycle, :manual_attention_count)) || 0,
      reason_counts: reason_count_snapshot(value(lifecycle, :reason_counts))
    }
  end

  defp lifecycle_overview_snapshot(_lifecycle), do: lifecycle_overview_snapshot(%{})

  defp manual_attention_overview_snapshot(manual_attention) when is_map(manual_attention) do
    %{
      total_count: non_negative_integer(value(manual_attention, :total_count)) || 0,
      project_count: non_negative_integer(value(manual_attention, :project_count)) || 0,
      reason_counts: reason_count_snapshot(value(manual_attention, :reason_counts)),
      projects: sanitize_list(value(manual_attention, :projects))
    }
  end

  defp manual_attention_overview_snapshot(_manual_attention), do: manual_attention_overview_snapshot(%{})

  defp detail_snapshot(detail) when is_map(detail) do
    %{
      identity: identity_detail_snapshot(value(detail, :identity)),
      ownership: ownership_detail_snapshot(value(detail, :ownership)),
      config: config_detail_snapshot(value(detail, :config)),
      poll_eligibility: poll_eligibility_detail_snapshot(value(detail, :poll_eligibility)),
      candidate_intake: stage_detail_snapshot(value(detail, :candidate_intake)),
      dispatch_planning: stage_detail_snapshot(value(detail, :dispatch_planning)),
      dispatch_application: stage_detail_snapshot(value(detail, :dispatch_application)),
      worker_start: stage_detail_snapshot(value(detail, :worker_start)),
      lifecycle: lifecycle_detail_snapshot(value(detail, :lifecycle)),
      writeback: writeback_detail_snapshot(value(detail, :writeback)),
      summary_error: summary_error_snapshot(value(detail, :summary_error))
    }
  end

  defp detail_snapshot(_detail), do: detail_snapshot(%{})

  defp identity_detail_snapshot(identity) when is_map(identity) do
    %{
      project_id: optional_string(identity, :project_id),
      name: optional_string(identity, :name),
      provider_kind: optional_string(identity, :provider_kind),
      provider_scope_key: optional_string(identity, :provider_scope_key),
      provider_scope: sanitize_value(value(identity, :provider_scope) || %{})
    }
  end

  defp identity_detail_snapshot(_identity), do: identity_detail_snapshot(%{})

  defp ownership_detail_snapshot(ownership) when is_map(ownership) do
    %{
      migration_state: normalize_migration_state(value(ownership, :migration_state)),
      status: normalize_project_status(value(ownership, :status)),
      dispatch_enabled: truthy?(value(ownership, :dispatch_enabled)),
      legacy_service: optional_string(ownership, :legacy_service),
      detected_legacy_ownership: sanitize_list(value(ownership, :detected_legacy_ownership)),
      blocked_operations: string_list(value(ownership, :blocked_operations))
    }
  end

  defp ownership_detail_snapshot(_ownership), do: ownership_detail_snapshot(%{})

  defp config_detail_snapshot(config) when is_map(config) do
    %{
      snapshot_version: optional_string(config, :snapshot_version),
      config_fingerprint: optional_string(config, :config_fingerprint),
      max_concurrent_agents: non_negative_integer(value(config, :max_concurrent_agents)),
      workflow_path: optional_string(config, :workflow_path),
      tracker_config_path: optional_string(config, :tracker_config_path),
      loaded_at: iso8601(value(config, :loaded_at)),
      load_error: optional_string(config, :load_error)
    }
  end

  defp config_detail_snapshot(_config), do: config_detail_snapshot(%{})

  defp poll_eligibility_detail_snapshot(poll) when is_map(poll) do
    %{
      allow_poll: truthy?(value(poll, :allow_poll)),
      reason: safe_status(value(poll, :reason)),
      message: optional_string(poll, :message),
      next_due_at: iso8601(value(poll, :next_due_at)),
      backoff_until: iso8601(value(poll, :backoff_until)),
      waiting_capacity: truthy?(value(poll, :waiting_capacity)),
      blocked_by_manual_attention: truthy?(value(poll, :blocked_by_manual_attention)),
      blocked_by_legacy_ownership: truthy?(value(poll, :blocked_by_legacy_ownership)),
      governance: sanitize_value(value(poll, :governance) || %{})
    }
  end

  defp poll_eligibility_detail_snapshot(_poll), do: poll_eligibility_detail_snapshot(%{})

  defp stage_detail_snapshot(stage) when is_map(stage) do
    %{
      status: safe_status(value(stage, :status)) |> blank_to_default("unknown"),
      counts: sanitize_value(value(stage, :counts) || %{}),
      reason_counts: reason_count_snapshot(value(stage, :reason_counts) || value(stage, :skipped_reasons)),
      current: sanitize_list(value(stage, :current)),
      pending: sanitize_list(value(stage, :pending)),
      blocked: sanitize_list(value(stage, :blocked)),
      manual_attention: sanitize_list(value(stage, :manual_attention))
    }
  end

  defp stage_detail_snapshot(_stage), do: stage_detail_snapshot(%{})

  defp lifecycle_detail_snapshot(lifecycle) when is_map(lifecycle) do
    %{
      status: safe_status(value(lifecycle, :status)) |> blank_to_default("unknown"),
      counts: lifecycle_count_snapshot(value(lifecycle, :counts)),
      reason_counts: reason_count_snapshot(value(lifecycle, :reason_counts)),
      running: sanitize_list(value(lifecycle, :running)),
      unresolved: sanitize_list(value(lifecycle, :unresolved)),
      retained_workspace: sanitize_list(value(lifecycle, :retained_workspace)),
      manual_attention: sanitize_list(value(lifecycle, :manual_attention))
    }
  end

  defp lifecycle_detail_snapshot(_lifecycle), do: lifecycle_detail_snapshot(%{})

  defp writeback_detail_snapshot(writeback) when is_map(writeback) do
    %{
      counts: writeback_count_snapshot(value(writeback, :counts)),
      completed: sanitize_list(value(writeback, :completed)),
      retryable: sanitize_list(value(writeback, :retryable)),
      unknown: sanitize_list(value(writeback, :unknown)),
      manual_attention: sanitize_list(value(writeback, :manual_attention)),
      dangerous_replay_rejected: sanitize_list(value(writeback, :dangerous_replay_rejected)),
      provider_lookup_required: sanitize_list(value(writeback, :provider_lookup_required))
    }
  end

  defp writeback_detail_snapshot(_writeback), do: writeback_detail_snapshot(%{})

  defp summary_error_snapshot(nil), do: nil

  defp summary_error_snapshot(error) when is_map(error) do
    %{
      code: safe_status(value(error, :code)) |> blank_to_default("summary_error"),
      source: optional_string(error, :source) || "hub_device_observability",
      message: optional_string(error, :message)
    }
  end

  defp summary_error_snapshot(_error) do
    %{code: "summary_error", source: "hub_device_observability", message: nil}
  end

  defp provider_snapshot(provider) when is_map(provider) do
    %{
      kind: optional_string(provider, :kind),
      provider_scope_key: optional_string(provider, :provider_scope_key),
      scope: sanitize_value(value(provider, :scope) || %{})
    }
  end

  defp provider_snapshot(_provider), do: provider_snapshot(%{})

  defp poll_snapshot(poll) when is_map(poll) do
    %{
      allow_poll: truthy?(value(poll, :allow_poll)),
      eligibility: sanitize_value(value(poll, :eligibility) || %{}),
      next_due_at: iso8601(value(poll, :next_due_at)),
      backoff_until: iso8601(value(poll, :backoff_until)),
      last_poll: sanitize_value(value(poll, :last_poll)),
      governance: sanitize_value(value(poll, :governance))
    }
  end

  defp poll_snapshot(_poll), do: poll_snapshot(%{})

  defp provider_queue_project_snapshot(queue) when is_map(queue) do
    %{
      pending_count: non_negative_integer(value(queue, :pending_count)) || 0,
      running_count: non_negative_integer(value(queue, :running_count)) || 0,
      provider_scopes: sanitize_list(value(queue, :provider_scopes)),
      pending: sanitize_list(value(queue, :pending)),
      running: sanitize_list(value(queue, :running)),
      recent_results: sanitize_list(value(queue, :recent_results)),
      backpressure: sanitize_list(value(queue, :backpressure))
    }
  end

  defp provider_queue_project_snapshot(_queue), do: provider_queue_project_snapshot(%{})

  defp runtime_snapshot(runtime) when is_map(runtime) do
    %{
      counts: count_snapshot(value(runtime, :counts)),
      active_attempts: sanitize_list(value(runtime, :active_attempts)),
      pending_start_intents: sanitize_list(value(runtime, :pending_start_intents)),
      workspace_leases: sanitize_list(value(runtime, :workspace_leases)),
      retry_backoff: sanitize_list(value(runtime, :retry_backoff)),
      blocked_candidates: sanitize_list(value(runtime, :blocked_candidates)),
      lifecycle: lifecycle_snapshot(value(runtime, :lifecycle))
    }
  end

  defp runtime_snapshot(_runtime), do: runtime_snapshot(%{})

  defp activation_preflight_summary(nil), do: nil

  defp activation_preflight_summary(preflight) do
    activation_preflight_snapshot(preflight)
  end

  defp activation_preflight_project_snapshot(nil), do: nil
  defp activation_preflight_project_snapshot(preflight), do: activation_preflight_snapshot(preflight)

  defp activation_preflight_snapshot(preflight) when is_map(preflight) do
    %{
      status: normalize_activation_preflight_status(value(preflight, :status)),
      safe_to_manage: truthy?(value(preflight, :safe_to_manage)),
      reason: optional_string(preflight, :reason),
      blocked_operations: string_list(value(preflight, :blocked_operations)),
      checked_at: iso8601(value(preflight, :checked_at)),
      probe_source: optional_string(preflight, :probe_source),
      conflict_count: non_negative_integer(value(preflight, :conflict_count)) || 0,
      manual_attention_count: non_negative_integer(value(preflight, :manual_attention_count)) || 0,
      detected_legacy_ownership: sanitize_list(value(preflight, :detected_legacy_ownership)),
      unknown_probe_results: sanitize_list(value(preflight, :unknown_probe_results))
    }
  end

  defp activation_preflight_snapshot(_preflight) do
    %{
      status: "unknown_manual_attention",
      safe_to_manage: false,
      reason: nil,
      blocked_operations: [],
      checked_at: nil,
      probe_source: nil,
      conflict_count: 0,
      manual_attention_count: 0,
      detected_legacy_ownership: [],
      unknown_probe_results: []
    }
  end

  defp normalize_activation_preflight_status(status) do
    case safe_status(status) do
      "" -> "unknown_manual_attention"
      value -> value
    end
  end

  defp writeback_snapshot(writebacks) when is_map(writebacks) do
    %{
      counts: writeback_count_snapshot(value(writebacks, :counts)),
      pending: sanitize_list(value(writebacks, :pending)),
      succeeded: sanitize_list(value(writebacks, :succeeded)),
      failed: sanitize_list(value(writebacks, :failed)),
      unknown: sanitize_list(value(writebacks, :unknown)),
      manual_attention: sanitize_list(value(writebacks, :manual_attention))
    }
  end

  defp writeback_snapshot(_writebacks), do: writeback_snapshot(%{})

  defp device_snapshot(device, projects) do
    device = if is_map(device), do: device, else: %{}

    %{
      project_count: non_negative_integer(value(device, :project_count)) || length(projects),
      active_agent_count: non_negative_integer(value(device, :active_agent_count)) || active_agent_count(projects),
      max_agent_capacity: non_negative_integer(value(device, :max_agent_capacity)),
      provider_scopes_count:
        non_negative_integer(value(device, :provider_scopes_count)) ||
          provider_scopes_count(projects, %{}, %{})
    }
  end

  defp migration_boundary_snapshot(boundary) when is_map(boundary) do
    %{
      legacy_service: optional_string(boundary, :legacy_service) || "symphony@project.service",
      legacy_default_path: optional_string(boundary, :legacy_default_path) || "direct_poll_and_writeback",
      hub_projection_model_only: value(boundary, :hub_projection_model_only) != false,
      hub_takes_over_legacy_poll_loop: value(boundary, :hub_takes_over_legacy_poll_loop) == true,
      hub_routing_requires_opt_in: value(boundary, :hub_routing_requires_opt_in) != false,
      direct_path_capabilities: string_list(value(boundary, :direct_path_capabilities)),
      opt_in_hub_capabilities: string_list(value(boundary, :opt_in_hub_capabilities))
    }
  end

  defp migration_boundary_snapshot(_boundary) do
    migration_boundary_snapshot(%{})
  end

  defp device_summary(projects, registry, poll_coordination, provider_queue, sources, opts) do
    %{
      project_count: length(projects),
      active_agent_count: active_agent_count(projects),
      max_agent_capacity: explicit_capacity(sources, opts) || registry_capacity(registry),
      provider_scopes_count: provider_scopes_count(projects, poll_coordination, provider_queue)
    }
  end

  defp active_agent_count(projects) do
    Enum.reduce(projects, 0, fn project, total ->
      total + length(list_value(value(project, :runtime), :active_attempts))
    end)
  end

  defp explicit_capacity(sources, opts) do
    Keyword.get(opts, :max_agent_capacity) ||
      value(sources, :max_agent_capacity)
      |> non_negative_integer()
  end

  defp registry_capacity(registry) do
    capacity =
      registry
      |> list_value(:projects)
      |> Enum.map(fn project ->
        project
        |> value(:runtime_summary)
        |> value(:max_concurrent_agents)
        |> non_negative_integer()
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    if capacity > 0, do: capacity
  end

  defp provider_scopes_count(projects, poll_coordination, provider_queue) do
    project_scope_keys =
      projects
      |> Enum.map(fn project -> get_in(project, [:provider, :provider_scope_key]) end)

    poll_scope_keys =
      poll_coordination
      |> list_value(:projects)
      |> Enum.map(&optional_string(&1, :provider_scope_key))

    queue_scope_keys =
      provider_queue
      |> list_value(:provider_scopes)
      |> Enum.map(&optional_string(&1, :provider_scope_key))

    (project_scope_keys ++ poll_scope_keys ++ queue_scope_keys)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> length()
  end

  defp migration_boundary_summary(sources) do
    migration_boundary_snapshot(value(sources, :migration_boundary) || %{})
  end

  defp overview_summary(
         projects,
         _registry,
         _poll_coordination,
         provider_queue,
         scheduler,
         tick,
         activation_preflight,
         runtime,
         writeback,
         sources,
         opts
       ) do
    %{
      hub_runtime: hub_runtime_overview(sources),
      scheduler: scheduler_overview(scheduler, tick),
      project_status_counts: status_counts(projects),
      provider_governance: provider_governance_overview(provider_queue),
      capacity_workspace: capacity_workspace_overview(projects, sources, opts),
      writeback: writeback_overview(projects, writeback),
      activation_preflight: activation_preflight_overview(activation_preflight),
      lifecycle: lifecycle_overview(projects, runtime),
      manual_attention: manual_attention_overview(projects),
      summary_errors: summary_errors(projects)
    }
  end

  defp hub_runtime_overview(sources) do
    runtime = map_value(sources, :hub_runtime) || map_value(sources, :runtime) || %{}

    %{
      enabled: true,
      mode: optional_string(runtime, :mode) || "hub",
      read_only: truthy?(value(runtime, :read_only)),
      provider_executor: sanitize_value(value(runtime, :provider_executor) || %{}),
      writeback_executor: sanitize_value(value(runtime, :writeback_executor) || %{}),
      worker_starter: sanitize_value(value(runtime, :worker_starter) || %{}),
      activation_probe: sanitize_value(value(runtime, :activation_probe) || %{})
    }
  end

  defp scheduler_overview(scheduler, tick) do
    last_tick = map_value(scheduler, :last_tick) || %{}

    %{
      enabled: truthy?(value(scheduler, :enabled)),
      status: safe_status(value(scheduler, :status)) |> blank_to_default("disabled"),
      queued: truthy?(value(scheduler, :queued)),
      running: truthy?(value(scheduler, :running?) || value(scheduler, :running)),
      coalesced: truthy?(value(scheduler, :coalesced)),
      next_tick_at: value(scheduler, :next_tick_at),
      next_reason: safe_status(value(scheduler, :next_reason)),
      last_reason:
        first_status([
          value(scheduler, :last_reason),
          value(last_tick, :reason),
          value(tick, :reason)
        ]),
      last_error: optional_string(scheduler, :last_error),
      counts: sanitize_value(value(scheduler, :counts) || %{}),
      unresolved_runtime: sanitize_value(value(scheduler, :unresolved_runtime) || %{})
    }
  end

  defp provider_governance_overview(provider_queue) do
    scopes = list_value(provider_queue, :provider_scopes)
    backpressure = list_value(provider_queue, :backpressure)
    recent_results = list_value(provider_queue, :recent_results)

    %{
      pending_count:
        non_negative_integer(value(provider_queue, :pending_count)) ||
          length(list_value(provider_queue, :pending)),
      running_count:
        non_negative_integer(value(provider_queue, :running_count)) ||
          length(list_value(provider_queue, :running)),
      provider_scope_count: length(scopes),
      queue_pressure_count:
        Enum.count(backpressure, &(safe_status(value(&1, :reason)) in ["scope_concurrency", "queue_pressure"])) +
          Enum.count(scopes, &((non_negative_integer(value(&1, :pending_count)) || 0) > 0)),
      quota_backoff_count:
        Enum.count(backpressure, &(safe_status(value(&1, :reason)) in ["rate_limited", "backoff"])) +
          Enum.count(scopes, &scope_quota_or_backoff?/1),
      circuit_open_count:
        Enum.count(backpressure, &(safe_status(value(&1, :reason)) == "circuit_open")) +
          Enum.count(scopes, &scope_circuit_open?/1),
      unsupported_operation_count: Enum.count(recent_results, &unsupported_result?/1),
      recent_failure_count: Enum.count(recent_results, &provider_failure_result?/1),
      manual_attention_count: Enum.count(recent_results, &truthy?(value(&1, :manual_attention))),
      backpressure_reasons: reason_count_snapshot(Enum.map(backpressure, &safe_status(value(&1, :reason)))),
      recent_failure_classes:
        recent_results
        |> Enum.map(&(optional_string(&1, :error_class) || safe_status(value(&1, :status))))
        |> Enum.reject(&blank?/1)
        |> Enum.take(10)
    }
  end

  defp capacity_workspace_overview(projects, sources, opts) do
    initial_counts = %{active_attempts: 0, pending_start_intents: 0, workspace_leases: 0, waiting_capacity: 0}

    runtime_counts =
      Enum.reduce(projects, initial_counts, fn project, counts ->
        runtime = value(project, :runtime) || %{}
        detail = value(project, :detail) || %{}
        poll = value(detail, :poll_eligibility) || %{}

        counts
        |> Map.update!(:active_attempts, &(&1 + length(list_value(runtime, :active_attempts))))
        |> Map.update!(:pending_start_intents, &(&1 + length(list_value(runtime, :pending_start_intents))))
        |> Map.update!(:workspace_leases, &(&1 + length(list_value(runtime, :workspace_leases))))
        |> Map.update!(:waiting_capacity, &(&1 + if(truthy?(value(poll, :waiting_capacity)), do: 1, else: 0)))
      end)

    lifecycle_counts = lifecycle_count_totals(projects)

    unreleased_capacity =
      runtime_counts.active_attempts + runtime_counts.pending_start_intents + lifecycle_counts.retained_workspace

    %{
      active_attempt_count: runtime_counts.active_attempts,
      pending_start_intent_count: runtime_counts.pending_start_intents,
      unknown_lifecycle_count: lifecycle_counts.unknown + lifecycle_counts.lost,
      workspace_lease_count: runtime_counts.workspace_leases,
      unreleased_capacity_count: unreleased_capacity,
      waiting_capacity_count: runtime_counts.waiting_capacity,
      max_agent_capacity: explicit_capacity(sources, opts) || max_capacity_from_projects(projects)
    }
  end

  defp writeback_overview(projects, writeback) do
    project_totals =
      Enum.reduce(projects, writeback_count_snapshot(%{}), fn project, counts ->
        project_counts = project |> value(:writebacks) |> value(:counts) |> writeback_count_snapshot()

        counts
        |> Map.update!(:pending, &(&1 + project_counts.pending))
        |> Map.update!(:succeeded, &(&1 + project_counts.succeeded))
        |> Map.update!(:failed, &(&1 + project_counts.failed))
        |> Map.update!(:unknown, &(&1 + project_counts.unknown))
        |> Map.update!(:manual_attention, &(&1 + project_counts.manual_attention))
      end)

    conflicts = projects |> Enum.flat_map(&list_value(&1, :conflicts))
    unknown = projects |> Enum.flat_map(&(value(&1, :writebacks) |> list_value(:unknown)))
    manual_attention = projects |> Enum.flat_map(&(value(&1, :writebacks) |> list_value(:manual_attention)))

    %{
      counts: project_totals,
      intent_conflict_count: Enum.count(conflicts, &(safe_status(value(&1, :code)) in ["writeback_intent_conflict", "writeback_intent_key_unstable"])),
      unknown_non_idempotent_count: Enum.count(unknown, &unknown_non_idempotent_writeback?/1),
      provider_lookup_required_count: Enum.count(manual_attention ++ unknown, &provider_lookup_required?/1),
      dangerous_replay_rejected_count: Enum.count(manual_attention ++ unknown, &dangerous_replay_rejected?/1),
      manual_attention_count: project_totals.manual_attention,
      recent_errors:
        (list_value(writeback, :recent_errors) ++
           Enum.flat_map(projects, fn project ->
             project
             |> value(:writebacks)
             |> list_value(:failed)
             |> Enum.map(&Map.put(&1, "project_id", value(project, :project_id)))
           end))
        |> Enum.take(10)
    }
  end

  defp activation_preflight_overview(activation_preflight) do
    projects = list_value(activation_preflight, :projects)

    %{
      blocked_project_count: Enum.count(projects, &(safe_status(value(&1, :status)) == "blocked_conflict")),
      unknown_project_count: Enum.count(projects, &(safe_status(value(&1, :status)) == "unknown_manual_attention")),
      manual_attention_count:
        Enum.reduce(projects, 0, fn project, count ->
          count + (non_negative_integer(value(project, :manual_attention_count)) || 0)
        end),
      conflict_count:
        Enum.reduce(projects, 0, fn project, count ->
          count + (non_negative_integer(value(project, :conflict_count)) || 0)
        end),
      blocked_operations: projects |> Enum.flat_map(&string_list(value(&1, :blocked_operations))) |> Enum.uniq() |> Enum.sort(),
      reason_counts: projects |> Enum.map(&(optional_string(&1, :reason) || safe_status(value(&1, :status)))) |> reason_count_snapshot()
    }
  end

  defp cutover_gate_blocked_operations(gate) do
    gate
    |> list_value(:projects)
    |> Enum.flat_map(&string_list(value(&1, :blocked_operations)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp cutover_gate_allowed_operations(gate) do
    gate
    |> list_value(:projects)
    |> Enum.flat_map(&string_list(value(&1, :allowed_operations)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp lifecycle_overview(projects, _runtime) do
    counts = lifecycle_count_totals(projects)

    %{
      counts: counts,
      unresolved_count: counts.lost + counts.unknown + counts.manual_attention,
      retained_workspace_count: counts.retained_workspace,
      released_workspace_count: counts.released,
      manual_attention_count: counts.manual_attention,
      reason_counts:
        projects
        |> Enum.flat_map(fn project ->
          project
          |> value(:runtime)
          |> value(:lifecycle)
          |> value(:reason_counts)
          |> map_to_repeated_keys()
        end)
        |> reason_count_snapshot()
    }
  end

  defp manual_attention_overview(projects) do
    projects_with_attention =
      Enum.filter(projects, fn project ->
        value(project, :status) == "manual_attention" or
          list_value(project, :manual_attention) != [] or
          not is_nil(value(project, :summary_error))
      end)

    reasons =
      projects_with_attention
      |> Enum.flat_map(fn project ->
        project
        |> list_value(:backpressure_reasons)
        |> Enum.filter(&(value(&1, :reason) == "manual_attention" or value(&1, :reason) == "summary_error"))
        |> Enum.map(&value(&1, :reason))
      end)

    %{
      total_count:
        Enum.reduce(projects_with_attention, 0, fn project, count ->
          count + max(length(list_value(project, :manual_attention)), 1)
        end),
      project_count: length(projects_with_attention),
      reason_counts: reason_count_snapshot(reasons),
      projects:
        Enum.map(projects_with_attention, fn project ->
          %{
            project_id: value(project, :project_id),
            status: value(project, :status),
            summary_error: value(project, :summary_error)
          }
        end)
    }
  end

  defp summary_errors(projects) do
    projects
    |> Enum.map(&value(&1, :summary_error))
    |> Enum.reject(&is_nil/1)
  end

  defp detail_summary(
         project_id,
         registry_project,
         poll_project,
         runtime_project,
         preflight_project,
         sources,
         project_queue,
         writeback_summary,
         legacy_project,
         summary_error
       ) do
    %{
      identity: identity_detail(project_id, registry_project, poll_project, runtime_project),
      ownership: ownership_detail(registry_project, legacy_project, preflight_project),
      config: config_detail(registry_project, runtime_project),
      poll_eligibility: poll_eligibility_detail(poll_project, preflight_project, project_queue, writeback_summary),
      candidate_intake: project_stage_detail(sources.candidate_intake, project_id, :skipped_reasons),
      dispatch_planning: project_stage_detail(sources.dispatch_planning, project_id, :skipped_reasons),
      dispatch_application: project_stage_detail(sources.dispatch_plan_application, project_id, :reason_counts),
      worker_start: worker_start_detail(sources.worker_start_handoff, project_id),
      lifecycle: lifecycle_detail(runtime_project, sources.worker_lifecycle_reconciliation, project_id),
      writeback: writeback_detail(writeback_summary),
      summary_error: summary_error
    }
  end

  defp identity_detail(project_id, registry_project, poll_project, runtime_project) do
    provider = provider_summary(registry_project, poll_project, runtime_project)

    %{
      project_id: project_id,
      name: project_name(registry_project, poll_project, nil),
      provider_kind: value(provider, :kind),
      provider_scope_key: value(provider, :provider_scope_key),
      provider_scope: value(provider, :scope) || %{}
    }
  end

  defp ownership_detail(registry_project, legacy_project, preflight_project) do
    preflight = activation_preflight_summary(preflight_project) || %{}

    %{
      migration_state: normalize_migration_state(value(registry_project || legacy_project || %{}, :migration_state)),
      status: safe_status(value(registry_project || %{}, :status)),
      dispatch_enabled: dispatch_enabled?(registry_project, legacy_project),
      legacy_service: optional_string(legacy_project || %{}, :service),
      detected_legacy_ownership: list_value(preflight, :detected_legacy_ownership),
      blocked_operations: string_list(value(preflight, :blocked_operations))
    }
  end

  defp config_detail(registry_project, runtime_project) do
    runtime_summary = map_value(registry_project || %{}, :runtime_summary) || %{}

    %{
      snapshot_version:
        optional_string(registry_project || %{}, :snapshot_version) ||
          optional_string(runtime_project || %{}, :snapshot_version) ||
          "1",
      config_fingerprint:
        optional_string(registry_project || %{}, :fingerprint) ||
          optional_string(runtime_project || %{}, :config_fingerprint),
      max_concurrent_agents: non_negative_integer(value(runtime_summary, :max_concurrent_agents)),
      workflow_path: optional_string(registry_project || %{}, :workflow_path),
      tracker_config_path: optional_string(registry_project || %{}, :tracker_config_path),
      loaded_at: value(registry_project || %{}, :loaded_at),
      load_error: optional_string(registry_project || %{}, :load_error)
    }
  end

  defp poll_eligibility_detail(poll_project, preflight_project, project_queue, writebacks) do
    reason = poll_eligibility_reason(poll_project)
    preflight = activation_preflight_summary(preflight_project) || %{}
    writeback_counts = writeback_count_snapshot(value(writebacks, :counts))

    %{
      allow_poll: value(poll_project || %{}, :allow_poll) == true,
      reason: reason || "unknown",
      message: poll_message(poll_project),
      next_due_at: value(poll_project || %{}, :next_due_at),
      backoff_until: value(poll_project || %{}, :backoff_until),
      waiting_capacity: reason in ["capacity_unavailable", "scope_concurrency"] or writeback_counts.pending > 0,
      blocked_by_manual_attention: writeback_counts.manual_attention > 0 or value(preflight, :status) == "unknown_manual_attention",
      blocked_by_legacy_ownership: value(preflight, :status) == "blocked_conflict",
      governance: value(poll_project || %{}, :governance) || value(project_queue, :backpressure) || %{}
    }
  end

  defp project_stage_detail(source, project_id, reason_key) do
    project = find_project(source, project_id)

    %{
      status: safe_status(value(source || %{}, :status)) |> blank_to_default(if(project, do: "completed", else: "idle")),
      counts: value(project || %{}, :counts) || %{},
      reason_counts: value(project || %{}, reason_key) || %{},
      current: list_value(project || %{}, :outcomes) ++ list_value(project || %{}, :results),
      pending: list_value(project || %{}, :pending_intents) ++ list_value(project || %{}, :pending_start_intents),
      blocked: filter_status_entries(project, ["blocked", "blocked_by_active_attempt", "blocked_by_workspace", "capacity_unavailable"]),
      manual_attention: filter_status_entries(project, ["manual_attention"])
    }
  end

  defp worker_start_detail(worker_start_handoff, project_id) do
    %{
      status: safe_status(value(worker_start_handoff || %{}, :status)) |> blank_to_default("idle"),
      counts: value(worker_start_handoff || %{}, :counts) || %{},
      reason_counts: value(worker_start_handoff || %{}, :reason_counts) || %{},
      current: filter_project_entries(worker_start_handoff, :results, project_id),
      pending: filter_project_entries(worker_start_handoff, :pending_start_intents, project_id),
      blocked: filter_project_entries(worker_start_handoff, :results, project_id, ["skipped", "failed", "unknown"]),
      manual_attention: filter_project_entries(worker_start_handoff, :results, project_id, ["manual_attention"])
    }
  end

  defp lifecycle_detail(runtime_project, lifecycle_reconciliation, project_id) do
    lifecycle = runtime_project |> runtime_summary() |> value(:lifecycle) |> lifecycle_snapshot()

    %{
      status: safe_status(value(lifecycle_reconciliation || %{}, :status)) |> blank_to_default("idle"),
      counts: value(lifecycle, :counts),
      reason_counts: value(lifecycle, :reason_counts) || %{},
      running: list_value(lifecycle, :running),
      unresolved:
        list_value(lifecycle, :unresolved) ++
          filter_project_entries(lifecycle_reconciliation, :results, project_id, ["lost", "unknown"]),
      retained_workspace: list_value(lifecycle, :retained_workspace),
      manual_attention:
        list_value(lifecycle, :manual_attention) ++
          filter_project_entries(lifecycle_reconciliation, :results, project_id, ["manual_attention"])
    }
  end

  defp writeback_detail(writebacks) do
    %{
      counts: value(writebacks, :counts) || %{},
      completed: list_value(writebacks, :succeeded),
      retryable: list_value(writebacks, :pending) ++ list_value(writebacks, :failed),
      unknown: list_value(writebacks, :unknown),
      manual_attention: list_value(writebacks, :manual_attention),
      dangerous_replay_rejected: Enum.filter(list_value(writebacks, :manual_attention), &dangerous_replay_rejected?/1),
      provider_lookup_required:
        Enum.filter(
          list_value(writebacks, :manual_attention) ++ list_value(writebacks, :unknown),
          &provider_lookup_required?/1
        )
    }
  end

  defp source_summary_error(project_id, registry_project, poll_project, runtime_project, preflight_project) do
    summary_sources = [registry_project, poll_project, runtime_project, preflight_project]

    cond do
      explicit_summary_error = first_summary_error(summary_sources) ->
        explicit_summary_error

      incompatible_snapshot?(registry_project) or incompatible_snapshot?(poll_project) or
        incompatible_snapshot?(runtime_project) or incompatible_snapshot?(preflight_project) ->
        summary_error_snapshot(%{
          code: "summary_version_incompatible",
          source: "hub_device_observability",
          message: project_id
        })

      true ->
        nil
    end
  end

  defp first_summary_error(sources) do
    sources
    |> Enum.find_value(fn source ->
      cond do
        is_map(source) and map_value(source, :summary_error) ->
          summary_error_snapshot(map_value(source, :summary_error))

        is_map(source) and truthy?(value(source, :summary_error)) ->
          summary_error_snapshot(%{code: "summary_error"})

        is_map(source) and truthy?(value(source, :summary_build_failed)) ->
          summary_error_snapshot(%{code: "summary_build_failed"})

        true ->
          nil
      end
    end)
  end

  defp incompatible_snapshot?(nil), do: false

  defp incompatible_snapshot?(source) when is_map(source) do
    case positive_integer(value(source, :version) || value(source, :snapshot_version)) do
      nil -> false
      version -> version > @version
    end
  end

  defp incompatible_snapshot?(_source), do: true

  defp provider_queue_summary(sources, poll_coordination) do
    source_map(sources, [:provider_queue, :provider_governance, :provider_queue_summary]) ||
      map_value(poll_coordination, :provider_queue) ||
      %{}
  end

  defp provider_queue_for_project(provider_queue, project_id, provider_scope_key) do
    provider_scopes =
      provider_queue
      |> list_value(:provider_scopes)
      |> Enum.filter(fn scope ->
        optional_string(scope, :provider_scope_key) == provider_scope_key
      end)

    pending = filter_queue_entries(provider_queue, :pending, project_id, provider_scope_key)
    running = filter_queue_entries(provider_queue, :running, project_id, provider_scope_key)
    recent_results = filter_queue_entries(provider_queue, :recent_results, project_id, provider_scope_key)
    backpressure = filter_queue_entries(provider_queue, :backpressure, project_id, provider_scope_key)

    %{
      pending_count: length(pending),
      running_count: length(running),
      provider_scopes: provider_scopes,
      pending: pending,
      running: running,
      recent_results: recent_results,
      backpressure: backpressure
    }
  end

  defp filter_queue_entries(provider_queue, key, project_id, provider_scope_key) do
    provider_queue
    |> list_value(key)
    |> Enum.filter(fn entry ->
      entry_project_id = optional_string(entry, :project_id)
      entry_scope_key = optional_string(entry, :provider_scope_key)

      entry_project_id == project_id or
        (not blank?(provider_scope_key) and entry_scope_key == provider_scope_key)
    end)
  end

  defp find_project(source, project_id) do
    source
    |> list_value(:projects)
    |> Enum.find(&(required_string(&1, :project_id) == project_id))
  end

  defp project_name(registry_project, poll_project, legacy_project) do
    optional_string(registry_project, :name) ||
      optional_string(poll_project, :name) ||
      optional_string(legacy_project, :name)
  end

  defp migration_state(
         project_id,
         registry_project,
         poll_project,
         runtime_project,
         legacy_project,
         managed_project_ids
       ) do
    explicit =
      optional_string(registry_project, :migration_state) ||
        optional_string(registry_project, :hub_migration_state) ||
        optional_string(poll_project, :migration_state) ||
        optional_string(runtime_project, :migration_state) ||
        optional_string(legacy_project, :migration_state)

    cond do
      not blank?(explicit) ->
        normalize_migration_state(explicit)

      is_nil(registry_project) and not is_nil(legacy_project) ->
        "legacy_only"

      MapSet.member?(managed_project_ids, project_id) or truthy?(value(registry_project || %{}, :hub_managed)) ->
        "hub_managed"

      true ->
        "hub_ready"
    end
  end

  defp dispatch_enabled?(nil, legacy_project) do
    is_nil(legacy_project) or value(legacy_project, :dispatch_enabled) != false
  end

  defp dispatch_enabled?(registry_project, _legacy_project) do
    value(registry_project, :dispatch_enabled) != false and value(registry_project, :paused) != true
  end

  defp provider_summary(registry_project, poll_project, runtime_project) do
    tracker_summary = map_value(registry_project, :tracker_summary)
    poll_tracker = map_value(poll_project, :tracker_identity)

    %{
      kind:
        optional_string(tracker_summary, :kind) ||
          optional_string(poll_tracker, :kind),
      provider_scope_key: provider_scope_key(registry_project, poll_project, runtime_project),
      scope:
        value(tracker_summary, :provider_scope) ||
          value(poll_project || %{}, :provider_scope) ||
          %{}
    }
  end

  defp provider_scope_key(registry_project, poll_project, runtime_project) do
    tracker_summary = map_value(registry_project, :tracker_summary)

    optional_string(tracker_summary, :provider_scope_key) ||
      optional_string(poll_project, :provider_scope_key) ||
      get_in_map(poll_project, [:tracker_identity, :provider_scope_key]) ||
      runtime_provider_scope_key(runtime_project)
  end

  defp runtime_provider_scope_key(runtime_project) do
    runtime_project
    |> list_value(:active_issues)
    |> Enum.find_value(fn issue ->
      issue
      |> value(:issue_ref)
      |> optional_string(:provider_scope_key)
    end)
  end

  defp poll_summary(nil), do: %{}

  defp poll_summary(poll_project) do
    %{
      allow_poll: value(poll_project, :allow_poll) == true,
      eligibility: value(poll_project, :eligibility) || %{},
      next_due_at: value(poll_project, :next_due_at),
      backoff_until: value(poll_project, :backoff_until),
      last_poll: value(poll_project, :last_poll),
      governance: value(poll_project, :governance)
    }
  end

  defp runtime_summary(nil), do: runtime_snapshot(%{})

  defp runtime_summary(runtime_project) do
    if map_value(runtime_project, :counts) do
      %{
        counts: value(runtime_project, :counts),
        active_attempts: list_value(runtime_project, :active_attempts),
        pending_start_intents: list_value(runtime_project, :pending_start_intents),
        workspace_leases: list_value(runtime_project, :workspace_leases),
        retry_backoff: list_value(runtime_project, :retry_backoff),
        blocked_candidates: list_value(runtime_project, :blocked_candidates),
        lifecycle: value(runtime_project, :lifecycle) || %{}
      }
    else
      runtime_summary_from_raw_project(runtime_project)
    end
  end

  defp runtime_summary_from_raw_project(project) do
    issues = list_value(project, :issues)
    workspace_leases = project |> list_value(:workspace_leases) |> Enum.filter(&active_workspace_lease?/1)
    start_intents = project |> list_value(:start_intents) |> Enum.filter(&active_start_intent?/1)

    active_attempts =
      Enum.flat_map(issues, fn issue ->
        issue
        |> list_value(:attempts)
        |> Enum.filter(&active_attempt?/1)
        |> Enum.map(fn attempt ->
          %{
            issue_key: required_string(issue, :issue_key),
            attempt_id: required_string(attempt, :attempt_id),
            attempt_number: non_negative_integer(value(attempt, :attempt_number)),
            status: safe_status(value(attempt, :status)),
            stage: optional_string(attempt, :current_stage) || optional_string(issue, :current_stage),
            workspace_path: optional_string(attempt, :workspace_path),
            worker_host: optional_string(attempt, :worker_host),
            run_context: value(attempt, :run_context)
          }
        end)
      end)

    %{
      counts: raw_issue_counts(issues),
      active_attempts: active_attempts,
      pending_start_intents: start_intents,
      workspace_leases: workspace_leases,
      retry_backoff: Enum.flat_map(issues, &retry_backoff_summary/1),
      blocked_candidates:
        Enum.filter(issues, fn issue ->
          safe_status(value(issue, :claim_status) || value(issue, :status)) == "blocked"
        end),
      lifecycle: lifecycle_summary_from_raw_project(project)
    }
  end

  defp lifecycle_snapshot(lifecycle) when is_map(lifecycle) do
    %{
      counts: lifecycle_count_snapshot(value(lifecycle, :counts)),
      reason_counts: sanitize_value(value(lifecycle, :reason_counts) || %{}),
      workspace_action_counts: sanitize_value(value(lifecycle, :workspace_action_counts) || %{}),
      running: sanitize_list(value(lifecycle, :running)),
      terminal: sanitize_list(value(lifecycle, :terminal)),
      unresolved: sanitize_list(value(lifecycle, :unresolved)),
      retry_backoff: sanitize_list(value(lifecycle, :retry_backoff)),
      blocked: sanitize_list(value(lifecycle, :blocked)),
      released: sanitize_list(value(lifecycle, :released)),
      retained_workspace: sanitize_list(value(lifecycle, :retained_workspace)),
      manual_attention: sanitize_list(value(lifecycle, :manual_attention))
    }
  end

  defp lifecycle_snapshot(_lifecycle), do: lifecycle_snapshot(%{})

  defp lifecycle_summary_from_raw_project(project) do
    results =
      project
      |> list_value(:issues)
      |> Enum.flat_map(fn issue ->
        issue
        |> list_value(:lifecycle_results)
        |> Enum.map(fn result ->
          result
          |> sanitize_value()
          |> Map.put_new("issue_key", required_string(issue, :issue_key))
        end)
      end)

    grouped = Enum.group_by(results, &safe_status(value(&1, :status)))
    unresolved = Enum.flat_map(["lost", "unknown", "manual_attention"], &Map.get(grouped, &1, []))
    terminal = Enum.flat_map(["succeeded", "failed", "cancelled", "timeout", "stopped"], &Map.get(grouped, &1, []))

    %{
      counts: lifecycle_counts_from_results(results),
      reason_counts: reason_counts(results),
      workspace_action_counts: reason_counts(Enum.map(results, &%{"reason" => value(&1, :workspace_action)})),
      running: Map.get(grouped, "running", []),
      terminal: terminal,
      unresolved: unresolved,
      retry_backoff: [],
      blocked: [],
      released: Enum.filter(results, &(safe_status(value(&1, :workspace_action)) == "released")),
      retained_workspace: Enum.filter(results, &(safe_status(value(&1, :workspace_action)) == "retained")),
      manual_attention: Enum.filter(results, &truthy?(value(&1, :manual_attention)))
    }
  end

  defp raw_issue_counts(issues) do
    Enum.reduce(issues, count_snapshot(%{}), fn issue, counts ->
      case safe_status(value(issue, :claim_status) || value(issue, :status)) do
        "claimed" -> Map.update!(counts, :claimed, &(&1 + 1))
        "running" -> Map.update!(counts, :running, &(&1 + 1))
        "retry_queued" -> Map.update!(counts, :retry, &(&1 + 1))
        "blocked" -> Map.update!(counts, :blocked, &(&1 + 1))
        "manual_attention" -> Map.update!(counts, :manual_attention, &(&1 + 1))
        "released" -> Map.update!(counts, :released, &(&1 + 1))
        "terminal" -> Map.update!(counts, :terminal, &(&1 + 1))
        _status -> counts
      end
    end)
  end

  defp retry_backoff_summary(issue) do
    case map_value(issue, :retry_backoff) do
      nil ->
        []

      retry ->
        [
          %{
            issue_key: required_string(issue, :issue_key),
            attempt_id: optional_string(retry, :attempt_id),
            due_at: iso8601(value(retry, :due_at)),
            error_summary: optional_string(retry, :error_summary),
            preferred_workspace_path: optional_string(retry, :preferred_workspace_path),
            preferred_worker_host: optional_string(retry, :preferred_worker_host)
          }
        ]
    end
  end

  defp writeback_summary(nil), do: writeback_snapshot(%{})

  defp writeback_summary(runtime_project) do
    case map_value(runtime_project, :writebacks) do
      nil -> writeback_summary_from_raw_project(runtime_project)
      writebacks -> writeback_snapshot(writebacks)
    end
  end

  defp writeback_summary_from_raw_project(project) do
    writebacks =
      project
      |> list_value(:issues)
      |> Enum.flat_map(fn issue ->
        issue
        |> list_value(:writebacks)
        |> Enum.map(fn writeback ->
          writeback
          |> sanitize_value()
          |> Map.put_new("issue_key", required_string(issue, :issue_key))
        end)
      end)

    grouped = Enum.group_by(writebacks, &safe_status(value(&1, :result_status)))
    manual_attention = Enum.filter(writebacks, &writeback_manual_attention?/1)

    %{
      counts: %{
        pending: length(Map.get(grouped, "pending", [])),
        succeeded: length(Map.get(grouped, "succeeded", [])),
        failed: length(Map.get(grouped, "failed", [])),
        unknown: length(Map.get(grouped, "unknown", [])),
        manual_attention: length(manual_attention)
      },
      pending: Map.get(grouped, "pending", []),
      succeeded: Map.get(grouped, "succeeded", []),
      failed: Map.get(grouped, "failed", []),
      unknown: Map.get(grouped, "unknown", []),
      manual_attention: manual_attention
    }
  end

  defp writeback_manual_attention?(writeback) do
    truthy?(value(writeback, :manual_attention)) or
      (safe_status(value(writeback, :result_status)) == "unknown" and
         safe_status(value(writeback, :replay_policy)) == "non_idempotent")
  end

  defp project_status(migration_state, registry_project, poll_project, runtime_summary, writebacks, reasons) do
    reason_names = MapSet.new(reasons, & &1.reason)
    counts = count_snapshot(value(runtime_summary, :counts))
    writeback_counts = writeback_count_snapshot(value(writebacks, :counts))

    cond do
      migration_state == "legacy_only" ->
        "legacy_only"

      config_invalid?(registry_project, poll_project) ->
        "config_invalid"

      counts.manual_attention > 0 or writeback_counts.manual_attention > 0 or
          MapSet.member?(reason_names, "manual_attention") ->
        "manual_attention"

      counts.running > 0 or non_empty_list?(runtime_summary, :active_attempts) ->
        "running"

      counts.blocked > 0 or MapSet.member?(reason_names, "blocked") ->
        "blocked"

      MapSet.member?(reason_names, "activation_preflight_blocked") ->
        "blocked"

      MapSet.member?(reason_names, "project_backoff") or
        MapSet.member?(reason_names, "provider_rate_limit") or
          MapSet.member?(reason_names, "provider_backoff") ->
        "backoff"

      paused?(registry_project, poll_project) ->
        "paused"

      value(poll_project || %{}, :allow_poll) == true ->
        "ready_to_poll"

      true ->
        "idle"
    end
  end

  defp config_invalid?(registry_project, poll_project) do
    safe_status(value(registry_project || %{}, :status)) in ["error", "config_invalid"] or
      poll_eligibility_reason(poll_project) == "config_error"
  end

  defp paused?(registry_project, poll_project) do
    value(registry_project || %{}, :paused) == true or
      value(registry_project || %{}, :dispatch_enabled) == false or
      safe_status(value(registry_project || %{}, :status)) == "paused" or
      poll_eligibility_reason(poll_project) == "paused"
  end

  defp backpressure_reasons(
         project,
         registry_project,
         poll_project,
         runtime_summary,
         preflight_project,
         writebacks,
         provider_queue
       ) do
    project_id = project.project_id
    config_error = optional_string(registry_project || %{}, :load_error)
    writeback_counts = writeback_count_snapshot(value(writebacks, :counts))
    lifecycle = lifecycle_snapshot(value(runtime_summary, :lifecycle))
    lifecycle_counts = lifecycle_count_snapshot(value(lifecycle, :counts))
    preflight = activation_preflight_summary(preflight_project)
    preflight_status = value(preflight, :status)
    preflight_reason = value(preflight, :reason)

    []
    |> add_project_reason(
      paused?(registry_project, poll_project),
      "project_paused",
      "project_registry",
      project_id,
      nil
    )
    |> add_project_reason(
      config_invalid?(registry_project, poll_project),
      "config_invalid",
      "project_registry",
      project_id,
      config_error
    )
    |> add_poll_reason(project, poll_project)
    |> add_provider_queue_reasons(project, provider_queue)
    |> add_project_reason(
      non_empty_list?(runtime_summary, :active_attempts),
      "active_attempt_exists",
      "runtime_ledger",
      project_id,
      nil
    )
    |> add_project_reason(
      non_empty_list?(runtime_summary, :workspace_leases),
      "workspace_occupied",
      "runtime_ledger",
      project_id,
      nil
    )
    |> add_project_reason(
      non_empty_list?(runtime_summary, :retry_backoff),
      "project_backoff",
      "runtime_ledger",
      project_id,
      nil
    )
    |> add_project_reason(
      non_empty_list?(runtime_summary, :blocked_candidates),
      "blocked",
      "runtime_ledger",
      project_id,
      nil
    )
    |> add_project_reason(writeback_counts.unknown > 0, "writeback_unknown", "runtime_ledger", project_id, nil)
    |> add_project_reason(writeback_counts.manual_attention > 0, "manual_attention", "runtime_ledger", project_id, nil)
    |> add_project_reason(
      preflight_status == "blocked_conflict",
      "activation_preflight_blocked",
      "activation_preflight",
      project_id,
      preflight_reason
    )
    |> add_project_reason(
      preflight_status == "unknown_manual_attention",
      "manual_attention",
      "activation_preflight",
      project_id,
      preflight_reason
    )
    |> add_project_reason(lifecycle_counts.lost > 0, "worker_lifecycle_lost", "runtime_ledger", project_id, nil)
    |> add_project_reason(lifecycle_counts.unknown > 0, "worker_lifecycle_unknown", "runtime_ledger", project_id, nil)
    |> add_project_reason(lifecycle_counts.manual_attention > 0, "manual_attention", "runtime_ledger", project_id, nil)
    |> add_project_reason(non_empty_list?(lifecycle, :retained_workspace), "workspace_retained", "runtime_ledger", project_id, nil)
    |> add_project_reason(
      non_empty_list?(project, :manual_attention),
      "manual_attention",
      "runtime_ledger",
      project_id,
      nil
    )
    |> add_project_reason(non_empty_list?(project, :conflicts), "conflict", "runtime_ledger", project_id, nil)
    |> uniq_reasons()
  end

  defp add_poll_reason(reasons, project, poll_project) do
    case poll_eligibility_reason(poll_project) do
      "backoff" ->
        add_project_reason(
          reasons,
          true,
          "project_backoff",
          "poll_coordination",
          project.project_id,
          poll_message(poll_project)
        )

      "rate_limited" ->
        add_project_reason(
          reasons,
          true,
          "provider_rate_limit",
          "poll_coordination",
          project.project_id,
          poll_message(poll_project)
        )

      "circuit_open" ->
        add_project_reason(
          reasons,
          true,
          "provider_circuit_open",
          "poll_coordination",
          project.project_id,
          poll_message(poll_project)
        )

      "scope_concurrency" ->
        add_project_reason(
          reasons,
          true,
          "queue_pressure",
          "poll_coordination",
          project.project_id,
          poll_message(poll_project)
        )

      "provider_unavailable" ->
        add_project_reason(
          reasons,
          true,
          "provider_unavailable",
          "poll_coordination",
          project.project_id,
          poll_message(poll_project)
        )

      _reason ->
        reasons
    end
  end

  defp add_provider_queue_reasons(reasons, project, provider_queue) do
    reasons =
      provider_queue
      |> list_value(:backpressure)
      |> Enum.reduce(reasons, fn backpressure, acc ->
        acc
        |> add_queue_backpressure_reason(project, backpressure)
      end)

    reasons =
      provider_queue
      |> list_value(:provider_scopes)
      |> Enum.reduce(reasons, fn scope, acc ->
        state = map_value(scope, :state) || %{}
        quota = map_value(state, :quota) || %{}
        scope_key = optional_string(scope, :provider_scope_key)
        backoff_until = iso8601(value(state, :backoff_until))
        last_error_class = optional_string(state, :last_error_class)

        acc
        |> add_project_reason(
          quota_remaining_zero?(quota),
          "provider_rate_limit",
          "provider_governance",
          project.project_id,
          scope_key
        )
        |> add_project_reason(
          future_time?(value(state, :backoff_until)),
          provider_backoff_reason(state),
          "provider_governance",
          project.project_id,
          backoff_until
        )
        |> add_project_reason(
          safe_status(value(state, :circuit_state)) == "open",
          "provider_circuit_open",
          "provider_governance",
          project.project_id,
          last_error_class
        )
      end)

    add_project_reason(
      reasons,
      non_negative_integer(value(provider_queue, :pending_count)) > 0,
      "queue_pressure",
      "provider_governance",
      project.project_id,
      nil
    )
  end

  defp add_queue_backpressure_reason(reasons, project, backpressure) do
    case safe_status(value(backpressure, :reason)) do
      "rate_limited" ->
        scope_key = optional_string(backpressure, :provider_scope_key)
        add_project_reason(reasons, true, "provider_rate_limit", "provider_governance", project.project_id, scope_key)

      "scope_concurrency" ->
        scope_key = optional_string(backpressure, :provider_scope_key)
        add_project_reason(reasons, true, "queue_pressure", "provider_governance", project.project_id, scope_key)

      "circuit_open" ->
        error_class = optional_string(backpressure, :error_class)

        add_project_reason(
          reasons,
          true,
          "provider_circuit_open",
          "provider_governance",
          project.project_id,
          error_class
        )

      "backoff" ->
        backoff_until = iso8601(value(backpressure, :backoff_until))
        add_project_reason(reasons, true, "provider_backoff", "provider_governance", project.project_id, backoff_until)

      _reason ->
        reasons
    end
  end

  defp add_project_reason(reasons, true, reason, source, project_id, detail) do
    [%{reason: reason, source: source, project_id: project_id, detail: detail} | reasons]
  end

  defp add_project_reason(reasons, condition, _reason, _source, _project_id, _detail)
       when condition in [false, nil],
       do: reasons

  defp provider_backoff_reason(state) do
    if safe_status(value(state, :last_error_class)) == "rate_limited" do
      "provider_rate_limit"
    else
      "provider_backoff"
    end
  end

  defp poll_eligibility_reason(nil), do: nil

  defp poll_eligibility_reason(poll_project) do
    poll_project
    |> value(:eligibility)
    |> value(:reason)
    |> safe_status()
  end

  defp poll_message(nil), do: nil

  defp poll_message(poll_project) do
    poll_project
    |> value(:eligibility)
    |> optional_string(:message)
  end

  defp aggregate_backpressure_reasons(projects) do
    projects
    |> Enum.flat_map(&list_value(&1, :backpressure_reasons))
    |> reason_snapshots()
    |> Enum.sort_by(&{&1.reason, &1.project_id || "", &1.source || ""})
  end

  defp reason_snapshots(reasons) when is_list(reasons) do
    reasons
    |> Enum.map(fn reason ->
      %{
        reason: required_string(reason, :reason),
        source: optional_string(reason, :source),
        project_id: optional_string(reason, :project_id),
        detail: optional_string(reason, :detail)
      }
    end)
    |> Enum.reject(&blank?(&1.reason))
    |> uniq_reasons()
    |> Enum.sort_by(&{&1.reason, &1.project_id || "", &1.source || ""})
  end

  defp reason_snapshots(_reasons), do: []

  defp uniq_reasons(reasons) do
    reasons
    |> Enum.uniq_by(fn reason ->
      {
        required_string(reason, :reason),
        optional_string(reason, :source),
        optional_string(reason, :project_id),
        optional_string(reason, :detail)
      }
    end)
  end

  defp count_snapshot(counts) when is_map(counts) do
    %{
      claimed: non_negative_integer(value(counts, :claimed)) || 0,
      running: non_negative_integer(value(counts, :running)) || 0,
      retry:
        non_negative_integer(value(counts, :retry)) ||
          non_negative_integer(value(counts, :retry_queued)) ||
          0,
      blocked: non_negative_integer(value(counts, :blocked)) || 0,
      manual_attention: non_negative_integer(value(counts, :manual_attention)) || 0,
      released: non_negative_integer(value(counts, :released)) || 0,
      terminal: non_negative_integer(value(counts, :terminal)) || 0
    }
  end

  defp count_snapshot(_counts), do: count_snapshot(%{})

  defp lifecycle_count_snapshot(counts) when is_map(counts) do
    %{
      running: non_negative_integer(value(counts, :running)) || 0,
      succeeded: non_negative_integer(value(counts, :succeeded)) || 0,
      failed: non_negative_integer(value(counts, :failed)) || 0,
      cancelled: non_negative_integer(value(counts, :cancelled)) || 0,
      timeout: non_negative_integer(value(counts, :timeout)) || 0,
      stopped: non_negative_integer(value(counts, :stopped)) || 0,
      lost: non_negative_integer(value(counts, :lost)) || 0,
      unknown: non_negative_integer(value(counts, :unknown)) || 0,
      manual_attention: non_negative_integer(value(counts, :manual_attention)) || 0,
      retry: non_negative_integer(value(counts, :retry)) || 0,
      blocked: non_negative_integer(value(counts, :blocked)) || 0,
      released: non_negative_integer(value(counts, :released)) || 0,
      retained_workspace: non_negative_integer(value(counts, :retained_workspace)) || 0
    }
  end

  defp lifecycle_count_snapshot(_counts), do: lifecycle_count_snapshot(%{})

  defp lifecycle_counts_from_results(results) do
    Enum.reduce(results, lifecycle_count_snapshot(%{}), fn result, counts ->
      status = safe_status(value(result, :status))
      recovery = safe_status(value(result, :recovery_status))
      workspace_action = safe_status(value(result, :workspace_action))

      counts
      |> update_lifecycle_status_count(status)
      |> update_lifecycle_recovery_count(recovery)
      |> update_lifecycle_retained_count(workspace_action)
    end)
  end

  defp update_lifecycle_status_count(counts, status)
       when status in ["running", "succeeded", "failed", "cancelled", "timeout", "stopped", "lost", "unknown", "manual_attention"] do
    Map.update!(counts, String.to_existing_atom(status), &(&1 + 1))
  end

  defp update_lifecycle_status_count(counts, _status), do: counts

  defp update_lifecycle_recovery_count(counts, "retry_queued"), do: Map.update!(counts, :retry, &(&1 + 1))
  defp update_lifecycle_recovery_count(counts, "blocked"), do: Map.update!(counts, :blocked, &(&1 + 1))
  defp update_lifecycle_recovery_count(counts, "released"), do: Map.update!(counts, :released, &(&1 + 1))
  defp update_lifecycle_recovery_count(counts, "manual_attention"), do: Map.update!(counts, :manual_attention, &(&1 + 1))
  defp update_lifecycle_recovery_count(counts, _recovery), do: counts

  defp update_lifecycle_retained_count(counts, "retained"), do: Map.update!(counts, :retained_workspace, &(&1 + 1))
  defp update_lifecycle_retained_count(counts, _workspace_action), do: counts

  defp writeback_count_snapshot(counts) when is_map(counts) do
    %{
      pending: non_negative_integer(value(counts, :pending)) || 0,
      succeeded: non_negative_integer(value(counts, :succeeded)) || 0,
      failed: non_negative_integer(value(counts, :failed)) || 0,
      unknown: non_negative_integer(value(counts, :unknown)) || 0,
      manual_attention: non_negative_integer(value(counts, :manual_attention)) || 0
    }
  end

  defp writeback_count_snapshot(_counts), do: writeback_count_snapshot(%{})

  defp reason_counts(entries) when is_list(entries) do
    entries
    |> Enum.map(&(optional_string(&1, :reason) || optional_string(&1, "reason")))
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {reason, _count} -> reason end)
    |> Map.new()
  end

  defp reason_count_snapshot(reasons) when is_map(reasons) do
    reasons
    |> Enum.map(fn {reason, count} -> {required_string(%{reason: reason}, :reason), non_negative_integer(count) || 0} end)
    |> Enum.reject(fn {reason, count} -> blank?(reason) or count <= 0 end)
    |> Enum.sort_by(fn {reason, _count} -> reason end)
    |> Map.new()
  end

  defp reason_count_snapshot(reasons) when is_list(reasons) do
    reasons
    |> Enum.map(fn
      reason when is_binary(reason) or is_atom(reason) ->
        optional_string(reason)

      reason when is_map(reason) ->
        optional_string(reason, :reason) || optional_string(reason, :status) || optional_string(reason, :code)

      _reason ->
        nil
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {reason, _count} -> reason end)
    |> Map.new()
  end

  defp reason_count_snapshot(_reasons), do: %{}

  defp map_to_repeated_keys(map) when is_map(map) do
    Enum.flat_map(map, fn {key, count} ->
      List.duplicate(optional_string(key) || "", non_negative_integer(count) || 0)
    end)
  end

  defp map_to_repeated_keys(_map), do: []

  defp lifecycle_count_totals(projects) do
    Enum.reduce(projects, lifecycle_count_snapshot(%{}), fn project, totals ->
      counts =
        project
        |> value(:runtime)
        |> value(:lifecycle)
        |> value(:counts)
        |> lifecycle_count_snapshot()

      totals
      |> Map.update!(:running, &(&1 + counts.running))
      |> Map.update!(:succeeded, &(&1 + counts.succeeded))
      |> Map.update!(:failed, &(&1 + counts.failed))
      |> Map.update!(:cancelled, &(&1 + counts.cancelled))
      |> Map.update!(:timeout, &(&1 + counts.timeout))
      |> Map.update!(:stopped, &(&1 + counts.stopped))
      |> Map.update!(:lost, &(&1 + counts.lost))
      |> Map.update!(:unknown, &(&1 + counts.unknown))
      |> Map.update!(:manual_attention, &(&1 + counts.manual_attention))
      |> Map.update!(:retry, &(&1 + counts.retry))
      |> Map.update!(:blocked, &(&1 + counts.blocked))
      |> Map.update!(:released, &(&1 + counts.released))
      |> Map.update!(:retained_workspace, &(&1 + counts.retained_workspace))
    end)
  end

  defp max_capacity_from_projects(projects) do
    capacity =
      projects
      |> Enum.map(fn project ->
        project
        |> value(:detail)
        |> value(:config)
        |> value(:max_concurrent_agents)
        |> non_negative_integer()
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    if capacity > 0, do: capacity
  end

  defp scope_quota_or_backoff?(scope) do
    state = value(scope, :state) || %{}
    quota = value(state, :quota) || %{}
    quota_remaining_zero?(quota) or not is_nil(iso8601(value(state, :backoff_until)))
  end

  defp scope_circuit_open?(scope) do
    scope |> value(:state) |> value(:circuit_state) |> safe_status() == "open"
  end

  defp unsupported_result?(result) do
    status = safe_status(value(result, :status))
    error_class = safe_status(value(result, :error_class))
    reason = safe_status(value(result, :reason))
    operation = safe_status(value(result, :operation_kind))

    status in ["unsupported", "permanent_failure"] or
      error_class in ["unsupported", "unsupported_operation", "unsupported_provider"] or
      reason in ["unsupported", "unsupported_operation", "unsupported_provider"] or
      operation in ["unsupported", "unsupported_operation"]
  end

  defp provider_failure_result?(result) do
    safe_status(value(result, :status)) in [
      "retryable_failure",
      "permanent_failure",
      "rate_limited",
      "circuit_open",
      "timed_out",
      "unknown_result"
    ]
  end

  defp unknown_non_idempotent_writeback?(writeback) do
    safe_status(value(writeback, :result_status)) == "unknown" and
      safe_status(value(writeback, :replay_policy)) in ["non_idempotent", "unknown_requires_manual_attention"]
  end

  defp provider_lookup_required?(writeback) do
    reason =
      optional_string(writeback, :manual_attention_reason) ||
        optional_string(writeback, :error_summary) ||
        optional_string(writeback, :provider_result_status) ||
        ""

    reason = String.downcase(reason)
    String.contains?(reason, "provider_lookup") or String.contains?(reason, "lookup")
  end

  defp dangerous_replay_rejected?(writeback) do
    reason =
      optional_string(writeback, :manual_attention_reason) ||
        optional_string(writeback, :error_summary) ||
        optional_string(writeback, :provider_result_status) ||
        ""

    reason = String.downcase(reason)

    String.contains?(reason, "dangerous_replay") or
      String.contains?(reason, "non_idempotent") or
      safe_status(value(writeback, :replay_policy)) in ["non_replayable", "unknown_requires_manual_attention"]
  end

  defp filter_status_entries(nil, _statuses), do: []

  defp filter_status_entries(project, statuses) do
    statuses = MapSet.new(statuses)

    [:candidates, :invalid_candidates, :outcomes, :results, :pending_intents, :pending_start_intents]
    |> Enum.flat_map(&list_value(project || %{}, &1))
    |> Enum.filter(fn entry ->
      status = safe_status(value(entry, :status) || value(entry, :reason) || value(entry, :skipped_reason))
      MapSet.member?(statuses, status)
    end)
  end

  defp filter_project_entries(source, key, project_id) do
    filter_project_entries(source, key, project_id, nil)
  end

  defp filter_project_entries(source, key, project_id, statuses) do
    status_set = statuses && MapSet.new(statuses)

    source
    |> list_value(key)
    |> Enum.filter(fn entry ->
      entry_project_id = optional_string(entry, :project_id)
      status = safe_status(value(entry, :status))

      entry_project_id == project_id and (is_nil(status_set) or MapSet.member?(status_set, status))
    end)
  end

  defp status_counts(projects) do
    base = Map.new(@project_statuses, &{String.to_atom(&1), 0})

    Enum.reduce(projects, base, fn project, counts ->
      status = normalize_project_status(value(project, :status))
      key = status_key(status)
      Map.update!(counts, key, &(&1 + 1))
    end)
  end

  defp status_key("running"), do: :running
  defp status_key("idle"), do: :idle
  defp status_key("ready_to_poll"), do: :ready_to_poll
  defp status_key("backoff"), do: :backoff
  defp status_key("paused"), do: :paused
  defp status_key("blocked"), do: :blocked
  defp status_key("manual_attention"), do: :manual_attention
  defp status_key("legacy_only"), do: :legacy_only
  defp status_key("config_invalid"), do: :config_invalid
  defp status_key(_status), do: :idle

  defp source_map(sources, keys) do
    Enum.find_value(keys, &map_value(sources, &1))
  end

  defp map_value(map, key) do
    case value(map, key) do
      value when is_map(value) -> value
      _value -> nil
    end
  end

  defp list_value(map, key) do
    case value(map, key) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  defp non_empty_list?(map, key), do: list_value(map, key) != []

  defp get_in_map(map, keys) do
    Enum.reduce_while(keys, map, fn key, current ->
      case value(current, key) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
    |> optional_string()
  end

  defp value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, nil} -> Map.get(map, Atom.to_string(key))
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key)
  defp value(_map, _key), do: nil

  defp managed_project_ids(sources, opts) do
    explicit_ids =
      Keyword.get(opts, :managed_project_ids) ||
        value(sources, :managed_project_ids) ||
        []

    explicit_ids
    |> List.wrap()
    |> Enum.map(&optional_string/1)
    |> Enum.reject(&blank?/1)
    |> MapSet.new()
  end

  defp active_attempt?(attempt) do
    safe_status(value(attempt, :status)) in @active_attempt_statuses and blank?(value(attempt, :ended_at))
  end

  defp active_workspace_lease?(lease) do
    safe_status(value(lease, :status)) == "active" and blank?(value(lease, :released_at))
  end

  defp active_start_intent?(intent) do
    safe_status(value(intent, :status)) in @active_start_intent_statuses and
      blank?(value(intent, :acked_at)) and
      blank?(value(intent, :finished_at))
  end

  defp quota_remaining_zero?(quota) when is_map(quota) do
    non_negative_integer(value(quota, :remaining)) == 0
  end

  defp quota_remaining_zero?(_quota), do: false

  defp future_time?(value) do
    case normalize_datetime(value) do
      nil -> false
      datetime -> DateTime.compare(datetime, DateTime.utc_now()) == :gt
    end
  end

  defp normalize_project_status(status) do
    status = safe_status(status)

    cond do
      status in @project_statuses -> status
      status in ["ready-to-poll", "ready to poll"] -> "ready_to_poll"
      status in ["manual-attention", "manual attention"] -> "manual_attention"
      status in ["legacy-only", "legacy only"] -> "legacy_only"
      status in ["config-invalid", "config invalid", "error", "config_error"] -> "config_invalid"
      status == "ready" -> "idle"
      true -> "idle"
    end
  end

  defp normalize_migration_state(value) do
    case safe_status(value) do
      "legacy-only" -> "legacy_only"
      "legacy_only" -> "legacy_only"
      "hub-managed" -> "hub_managed"
      "hub_managed" -> "hub_managed"
      "hub-ready" -> "hub_ready"
      "hub_ready" -> "hub_ready"
      _other -> "hub_ready"
    end
  end

  defp safe_status(value) do
    value
    |> optional_string()
    |> case do
      nil -> ""
      string -> string |> String.trim() |> String.downcase() |> String.replace("-", "_") |> String.replace(" ", "_")
    end
  end

  defp first_status(values) when is_list(values) do
    values
    |> Enum.map(&safe_status/1)
    |> Enum.find("", &(not blank?(&1)))
  end

  defp sanitize_list(value) when is_list(value), do: Enum.map(value, &sanitize_value/1)
  defp sanitize_list(_value), do: []

  defp sanitize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp sanitize_value(%_struct{} = value), do: value |> Map.from_struct() |> sanitize_value()

  defp sanitize_value(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {raw_key, raw_value}, sanitized ->
      key = normalize_key(raw_key)

      cond do
        body_key?(key) ->
          sanitized
          |> maybe_put("#{key}_sha256", body_hash(raw_value))
          |> maybe_put("#{key}_bytes", byte_size_or_nil(raw_value))

        sensitive_key?(key) or sensitive_string?(raw_value) ->
          sanitized

        true ->
          Map.put(sanitized, key, sanitize_value(raw_value))
      end
    end)
  end

  defp sanitize_value(value) when is_list(value) do
    value
    |> Enum.reject(&sensitive_string?/1)
    |> Enum.map(&sanitize_value/1)
  end

  defp sanitize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_value(value), do: value

  defp body_key?(key), do: key in @body_keys or String.ends_with?(key, "_body")

  defp sensitive_key?(key) do
    key = String.downcase(key)
    Enum.any?(@sensitive_key_fragments, &String.contains?(key, &1))
  end

  defp sensitive_string?(value) when is_binary(value) do
    Enum.any?(@sensitive_value_patterns, &Regex.match?(&1, value))
  end

  defp sensitive_string?(_value), do: false

  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(%DateTime{} = value), do: value

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp normalize_datetime(_value), do: nil

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp iso8601(value) when is_binary(value) do
    case normalize_datetime(value) do
      nil -> optional_string(value)
      datetime -> DateTime.to_iso8601(datetime)
    end
  end

  defp iso8601(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _parse_result -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _parse_result -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp string_list(value) when is_list(value) do
    value
    |> Enum.map(&optional_string/1)
    |> Enum.reject(&blank?/1)
  end

  defp string_list(_value), do: []

  defp required_string(map, key), do: optional_string(map, key) || ""
  defp optional_string(map, key) when is_map(map), do: map |> value(key) |> optional_string()
  defp optional_string(_map, _key), do: nil
  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(_value), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp body_hash(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp body_hash(_value), do: nil

  defp byte_size_or_nil(value) when is_binary(value), do: byte_size(value)
  defp byte_size_or_nil(_value), do: nil
end
