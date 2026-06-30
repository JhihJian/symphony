defmodule SymphonyElixir.Hub.DeviceObservability do
  @moduledoc """
  Safe Hub device-level observability projection.

  This module is model-only. It summarizes existing Hub registry, provider
  governance, poll coordination, runtime ledger, dispatch, and writeback
  observability snapshots into one Dashboard/API-safe device projection. It
  does not start poll loops, dispatch agents, execute provider calls, or replace
  the legacy `symphony@project.service` single-project path.
  """

  @version 1
  @project_statuses [
    "running",
    "idle",
    "ready_to_poll",
    "waiting_capacity",
    "backoff",
    "paused",
    "blocked",
    "manual_attention",
    "legacy_only",
    "config_invalid"
  ]
  @active_attempt_statuses ["pending", "running"]
  @active_start_intent_statuses ["pending", "unknown", "manual_attention"]
  @sensitive_key_fragments [
    "api_key",
    "apikey",
    "authorization",
    "cookie",
    "credential",
    "credentials",
    "raw_config",
    "raw_provider_config",
    "secret",
    "secret_env",
    "secret_envs",
    "token",
    "prompt",
    "transcript"
  ]
  @body_keys ["body", "comment_body", "pull_request_body", "pr_body", "raw_body"]
  @sensitive_value_patterns [
    ~r/\$[A-Z0-9_]*(TOKEN|API_KEY|SECRET|CREDENTIAL)[A-Z0-9_]*/,
    ~r/\b(api[_-]?key|authorization|bearer|cookie|credential|secret|token|transcript|full prompt|codex transcript)\b/i,
    ~r/\b(ghp_|github_pat_|glpat-|sk-[A-Za-z0-9])/,
    ~r/\b[a-z0-9_]+_api_status:\d{3}\b/i
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
    provider_queue = provider_queue_summary(sources, poll_coordination)
    scheduler = source_map(sources, [:scheduler, :hub_scheduler])
    tick = source_map(sources, [:tick, :poll_tick, :hub_poll_tick])
    candidate_intake = source_map(sources, [:candidate_intake, :hub_candidate_intake])
    dispatch_planning = source_map(sources, [:dispatch_planning, :hub_dispatch_planning])
    dispatch_plan_application = source_map(sources, [:dispatch_plan_application, :hub_dispatch_plan_application])
    worker_start_handoff = source_map(sources, [:worker_start_handoff, :hub_worker_start_handoff])

    worker_lifecycle_reconciliation =
      source_map(sources, [:worker_lifecycle_reconciliation, :hub_worker_lifecycle_reconciliation])

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
        Enum.map(legacy_projects, &required_string(&1, :project_id))
      ]
      |> List.flatten()
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.sort()

    project_sources = %{
      registry: registry,
      poll_coordination: poll_coordination,
      runtime: runtime,
      activation_preflight: activation_preflight,
      provider_queue: provider_queue,
      candidate_intake: candidate_intake,
      dispatch_planning: dispatch_planning,
      dispatch_plan_application: dispatch_plan_application,
      worker_start_handoff: worker_start_handoff,
      worker_lifecycle_reconciliation: worker_lifecycle_reconciliation,
      legacy_projects: legacy_projects,
      managed_project_ids: managed_project_ids
    }

    projects =
      Enum.map(project_ids, fn project_id ->
        safe_project_projection(project_id, project_sources)
      end)

    overview =
      overview_summary(
        projects,
        sources,
        scheduler,
        tick,
        provider_queue,
        candidate_intake,
        dispatch_planning,
        dispatch_plan_application,
        worker_start_handoff,
        worker_lifecycle_reconciliation
      )

    projection = %{
      version: @version,
      generated_at: now,
      overview: overview,
      device: device_summary(projects, registry, poll_coordination, provider_queue, sources, opts),
      status_counts: status_counts(projects),
      migration_boundary: migration_boundary_summary(sources),
      provider_queue: sanitize_value(provider_queue),
      projects: projects,
      backpressure_reasons: aggregate_backpressure_reasons(projects)
    }

    to_snapshot(projection)
  end

  def build(_sources, opts) when is_list(opts), do: build(%{}, opts)

  @spec to_snapshot(term()) :: projection()
  def to_snapshot(projection) when is_map(projection) do
    projects =
      projection
      |> list_value(:projects)
      |> Enum.map(&project_snapshot/1)
      |> Enum.sort_by(& &1.project_id)

    %{
      version: positive_integer(value(projection, :version)) || @version,
      generated_at: iso8601(value(projection, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601(),
      overview: overview_snapshot(value(projection, :overview), projects),
      device: device_snapshot(value(projection, :device), projects),
      status_counts: status_counts(projects),
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

  defp project_projection(
         project_id,
         registry,
         poll_coordination,
         runtime,
         activation_preflight,
         provider_queue,
         candidate_intake,
         dispatch_planning,
         dispatch_plan_application,
         worker_start_handoff,
         worker_lifecycle_reconciliation,
         legacy_projects,
         managed_project_ids
       ) do
    registry_project = find_project(registry, project_id)
    poll_project = find_project(poll_coordination, project_id)
    runtime_project = find_project(runtime, project_id)
    preflight_project = find_project(activation_preflight, project_id)
    legacy_project = Enum.find(legacy_projects, &(required_string(&1, :project_id) == project_id))

    if reason = project_summary_error_reason(registry_project, poll_project, runtime_project, preflight_project) do
      summary_error_project(project_id, reason)
    else
      project_projection_from_parts(
        project_id,
        registry_project,
        poll_project,
        runtime_project,
        preflight_project,
        provider_queue,
        candidate_intake,
        dispatch_planning,
        dispatch_plan_application,
        worker_start_handoff,
        worker_lifecycle_reconciliation,
        legacy_project,
        managed_project_ids
      )
    end
  end

  defp project_projection_from_parts(
         project_id,
         registry_project,
         poll_project,
         runtime_project,
         preflight_project,
         provider_queue,
         candidate_intake,
         dispatch_planning,
         dispatch_plan_application,
         worker_start_handoff,
         worker_lifecycle_reconciliation,
         legacy_project,
         managed_project_ids
       ) do
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
      summary_error: nil,
      identity: identity_summary(project_id, registry_project, poll_project, legacy_project),
      config: config_summary(registry_project),
      migration_state: migration_state,
      dispatch_enabled: dispatch_enabled?(registry_project, legacy_project),
      provider: provider_summary(registry_project, poll_project, runtime_project),
      poll: poll_summary(poll_project),
      provider_queue: project_queue,
      candidate_intake: project_stage_summary(candidate_intake, project_id),
      dispatch_planning: project_stage_summary(dispatch_planning, project_id),
      dispatch_application: project_stage_summary(dispatch_plan_application, project_id),
      start_handoff: start_handoff_summary(worker_start_handoff, project_id),
      lifecycle_reconciliation: lifecycle_reconciliation_summary(worker_lifecycle_reconciliation, project_id),
      runtime: runtime_summary,
      activation_preflight: activation_preflight_summary(preflight_project),
      writebacks: writeback_summary,
      conflicts: sanitize_value(list_value(runtime_project, :conflicts)),
      manual_attention: sanitize_value(list_value(runtime_project, :manual_attention)),
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

    status =
      project_status(
        migration_state,
        registry_project,
        poll_project,
        runtime_summary,
        writeback_summary,
        reasons
      )

    base
    |> Map.put(:status, status)
    |> Map.put(:backpressure_reasons, reason_snapshots(reasons))
    |> project_snapshot()
  end

  defp safe_project_projection(project_id, sources) do
    project_projection(
      project_id,
      sources.registry,
      sources.poll_coordination,
      sources.runtime,
      sources.activation_preflight,
      sources.provider_queue,
      sources.candidate_intake,
      sources.dispatch_planning,
      sources.dispatch_plan_application,
      sources.worker_start_handoff,
      sources.worker_lifecycle_reconciliation,
      sources.legacy_projects,
      sources.managed_project_ids
    )
  rescue
    _error ->
      summary_error_project(project_id, "exception")
  catch
    _kind, _reason ->
      summary_error_project(project_id, "throw")
  end

  defp summary_error_project(project_id, reason) do
    project_snapshot(%{
      project_id: project_id,
      status: "manual_attention",
      summary_error: %{
        status: "manual_attention",
        reason: "project_summary_#{default_status(reason, "unavailable")}",
        message: "Hub project summary could not be built"
      },
      identity: %{project_id: project_id},
      migration_state: "hub_ready",
      dispatch_enabled: false,
      manual_attention: [
        %{
          level: :error,
          code: :hub_project_summary_error,
          project_id: project_id,
          message: "Hub project summary could not be built"
        }
      ],
      backpressure_reasons: [
        %{
          reason: "manual_attention",
          source: "device_observability",
          project_id: project_id,
          detail: "project_summary_error"
        }
      ]
    })
  end

  defp project_summary_error_reason(sources) when is_list(sources) do
    Enum.find_value(sources, &project_summary_error_reason/1)
  end

  defp project_summary_error_reason(nil), do: nil

  defp project_summary_error_reason(source) when is_map(source) do
    cond do
      map_value(source, :summary_error) ->
        optional_string(value(source, :summary_error), :reason) || "summary_error"

      safe_status(value(source, :summary_status)) in ["error", "summary_error", "incompatible"] ->
        optional_string(source, :summary_reason) || safe_status(value(source, :summary_status))

      safe_status(value(source, :summary_state)) in ["error", "summary_error", "incompatible"] ->
        optional_string(source, :summary_reason) || safe_status(value(source, :summary_state))

      incompatible_summary_version?(value(source, :summary_version)) ->
        "incompatible_snapshot_version"

      incompatible_summary_version?(value(source, :observability_version)) ->
        "incompatible_snapshot_version"

      true ->
        nil
    end
  end

  defp project_summary_error_reason(_source), do: nil

  defp project_summary_error_reason(registry_project, poll_project, runtime_project, preflight_project) do
    project_summary_error_reason([registry_project, poll_project, runtime_project, preflight_project])
  end

  defp incompatible_summary_version?(nil), do: false
  defp incompatible_summary_version?(""), do: false
  defp incompatible_summary_version?(version) when is_integer(version), do: version > @version

  defp incompatible_summary_version?(version) when is_binary(version) do
    case Integer.parse(version) do
      {number, ""} -> number > @version
      _parse -> false
    end
  end

  defp incompatible_summary_version?(_version), do: false

  defp project_snapshot(project) when is_map(project) do
    project_id = required_string(project, :project_id)

    %{
      project_id: project_id,
      name: optional_string(project, :name),
      status: normalize_project_status(value(project, :status)),
      summary_error: summary_error_snapshot(value(project, :summary_error)),
      identity: identity_snapshot(value(project, :identity), project_id),
      config: config_snapshot(value(project, :config)),
      migration_state: normalize_migration_state(value(project, :migration_state)),
      dispatch_enabled: truthy?(value(project, :dispatch_enabled)),
      provider: provider_snapshot(value(project, :provider)),
      poll: poll_snapshot(value(project, :poll)),
      provider_queue: provider_queue_project_snapshot(value(project, :provider_queue)),
      candidate_intake: stage_snapshot(value(project, :candidate_intake)),
      dispatch_planning: stage_snapshot(value(project, :dispatch_planning)),
      dispatch_application: stage_snapshot(value(project, :dispatch_application)),
      start_handoff: stage_snapshot(value(project, :start_handoff)),
      lifecycle_reconciliation: stage_snapshot(value(project, :lifecycle_reconciliation)),
      runtime: runtime_snapshot(value(project, :runtime)),
      activation_preflight: activation_preflight_project_snapshot(value(project, :activation_preflight)),
      writebacks: writeback_snapshot(value(project, :writebacks)),
      conflicts: sanitize_list(value(project, :conflicts)),
      manual_attention: sanitize_list(value(project, :manual_attention)),
      backpressure_reasons: reason_snapshots(list_value(project, :backpressure_reasons))
    }
  end

  defp project_snapshot(_project) do
    project_snapshot(%{})
  end

  defp provider_snapshot(provider) when is_map(provider) do
    %{
      kind: optional_string(provider, :kind),
      provider_scope_key: optional_string(provider, :provider_scope_key),
      scope: sanitize_value(value(provider, :scope) || %{})
    }
  end

  defp provider_snapshot(_provider), do: provider_snapshot(%{})

  defp summary_error_snapshot(nil), do: nil

  defp summary_error_snapshot(error) when is_map(error) do
    %{
      status: optional_string(error, :status) || "manual_attention",
      reason: optional_string(error, :reason) || "summary_unavailable",
      message: optional_string(error, :message) || "Hub project summary could not be built"
    }
  end

  defp summary_error_snapshot(_error), do: summary_error_snapshot(%{})

  defp identity_snapshot(identity, project_id) when is_map(identity) do
    %{
      project_id: optional_string(identity, :project_id) || project_id,
      name: optional_string(identity, :name),
      provider_kind: optional_string(identity, :provider_kind),
      provider_scope_key: optional_string(identity, :provider_scope_key),
      service: optional_string(identity, :service)
    }
  end

  defp identity_snapshot(_identity, project_id), do: identity_snapshot(%{project_id: project_id}, project_id)

  defp config_snapshot(config) when is_map(config) do
    %{
      snapshot_version: optional_string(config, :snapshot_version),
      fingerprint: optional_string(config, :fingerprint),
      loaded_at: iso8601(value(config, :loaded_at)),
      status: default_status(value(config, :status), "unknown"),
      error: optional_string(config, :error)
    }
  end

  defp config_snapshot(_config), do: config_snapshot(%{})

  defp stage_snapshot(stage) when is_map(stage) do
    %{
      status: default_status(value(stage, :status), "unknown"),
      counts: sanitize_value(value(stage, :counts) || %{}),
      reason_counts: sanitize_value(value(stage, :reason_counts) || value(stage, :skipped_reasons) || %{}),
      pending_count: non_negative_integer(value(stage, :pending_count)) || 0,
      unresolved_count: non_negative_integer(value(stage, :unresolved_count)) || 0,
      manual_attention_count: non_negative_integer(value(stage, :manual_attention_count)) || 0,
      recent: sanitize_list(value(stage, :recent))
    }
  end

  defp stage_snapshot(_stage), do: stage_snapshot(%{})

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

  defp overview_snapshot(overview, projects) when is_map(overview) do
    %{
      hub: hub_overview_snapshot(value(overview, :hub)),
      scheduler: scheduler_snapshot(value(overview, :scheduler)),
      project_status_counts: status_counts(projects),
      provider_governance: provider_governance_snapshot(value(overview, :provider_governance)),
      capacity: capacity_overview_snapshot(value(overview, :capacity)),
      workspace: workspace_overview_snapshot(value(overview, :workspace)),
      writeback: writeback_overview_snapshot(value(overview, :writeback)),
      activation_preflight: activation_preflight_overview_snapshot(value(overview, :activation_preflight)),
      lifecycle: lifecycle_overview_snapshot(value(overview, :lifecycle)),
      manual_attention: manual_attention_overview_snapshot(value(overview, :manual_attention)),
      summary_errors: sanitize_list(value(overview, :summary_errors))
    }
  end

  defp overview_snapshot(_overview, projects) do
    overview_snapshot(%{project_status_counts: status_counts(projects)}, projects)
  end

  defp hub_overview_snapshot(hub) when is_map(hub) do
    %{
      runtime_enabled: truthy?(value(hub, :runtime_enabled)),
      mode: optional_string(hub, :mode) || "legacy",
      project_count: non_negative_integer(value(hub, :project_count)) || 0,
      generated_at: iso8601(value(hub, :generated_at))
    }
  end

  defp hub_overview_snapshot(_hub), do: hub_overview_snapshot(%{})

  defp scheduler_snapshot(scheduler) when is_map(scheduler) do
    %{
      enabled: truthy?(value(scheduler, :enabled)),
      status: default_status(value(scheduler, :status), "unknown"),
      running: truthy?(value(scheduler, :running) || value(scheduler, :running?)),
      queued: truthy?(value(scheduler, :queued)),
      coalesced: truthy?(value(scheduler, :coalesced)),
      next_tick_at: iso8601(value(scheduler, :next_tick_at)),
      next_reason: safe_status(value(scheduler, :next_reason)),
      last_tick: sanitize_value(value(scheduler, :last_tick) || %{}),
      poll_tick: sanitize_value(value(scheduler, :poll_tick) || %{})
    }
  end

  defp scheduler_snapshot(_scheduler), do: scheduler_snapshot(%{})

  defp provider_governance_snapshot(governance) when is_map(governance) do
    %{
      pending_count: non_negative_integer(value(governance, :pending_count)) || 0,
      running_count: non_negative_integer(value(governance, :running_count)) || 0,
      provider_scopes_count: non_negative_integer(value(governance, :provider_scopes_count)) || 0,
      queue_pressure: truthy?(value(governance, :queue_pressure)),
      quota_or_backoff_count: non_negative_integer(value(governance, :quota_or_backoff_count)) || 0,
      circuit_open_count: non_negative_integer(value(governance, :circuit_open_count)) || 0,
      unsupported_count: non_negative_integer(value(governance, :unsupported_count)) || 0,
      recent_failure_count: non_negative_integer(value(governance, :recent_failure_count)) || 0,
      manual_attention_count: non_negative_integer(value(governance, :manual_attention_count)) || 0,
      reasons: sanitize_value(value(governance, :reasons) || %{})
    }
  end

  defp provider_governance_snapshot(_governance), do: provider_governance_snapshot(%{})

  defp capacity_overview_snapshot(capacity) when is_map(capacity) do
    %{
      active_attempt_count: non_negative_integer(value(capacity, :active_attempt_count)) || 0,
      pending_start_intent_count: non_negative_integer(value(capacity, :pending_start_intent_count)) || 0,
      waiting_capacity_count: non_negative_integer(value(capacity, :waiting_capacity_count)) || 0,
      unreleased_capacity_count: non_negative_integer(value(capacity, :unreleased_capacity_count)) || 0
    }
  end

  defp capacity_overview_snapshot(_capacity), do: capacity_overview_snapshot(%{})

  defp workspace_overview_snapshot(workspace) when is_map(workspace) do
    %{
      lease_count: non_negative_integer(value(workspace, :lease_count)) || 0,
      retained_count: non_negative_integer(value(workspace, :retained_count)) || 0
    }
  end

  defp workspace_overview_snapshot(_workspace), do: workspace_overview_snapshot(%{})

  defp writeback_overview_snapshot(writeback) when is_map(writeback) do
    %{
      pending_count: non_negative_integer(value(writeback, :pending_count)) || 0,
      succeeded_count: non_negative_integer(value(writeback, :succeeded_count)) || 0,
      failed_count: non_negative_integer(value(writeback, :failed_count)) || 0,
      unknown_count: non_negative_integer(value(writeback, :unknown_count)) || 0,
      manual_attention_count: non_negative_integer(value(writeback, :manual_attention_count)) || 0,
      conflict_count: non_negative_integer(value(writeback, :conflict_count)) || 0,
      provider_lookup_required_count: non_negative_integer(value(writeback, :provider_lookup_required_count)) || 0,
      unknown_non_idempotent_count: non_negative_integer(value(writeback, :unknown_non_idempotent_count)) || 0,
      dangerous_replay_rejected_count: non_negative_integer(value(writeback, :dangerous_replay_rejected_count)) || 0
    }
  end

  defp writeback_overview_snapshot(_writeback), do: writeback_overview_snapshot(%{})

  defp activation_preflight_overview_snapshot(preflight) when is_map(preflight) do
    %{
      blocked_count: non_negative_integer(value(preflight, :blocked_count)) || 0,
      unknown_count: non_negative_integer(value(preflight, :unknown_count)) || 0,
      manual_attention_count: non_negative_integer(value(preflight, :manual_attention_count)) || 0,
      legacy_ownership_count: non_negative_integer(value(preflight, :legacy_ownership_count)) || 0,
      probe_unknown_count: non_negative_integer(value(preflight, :probe_unknown_count)) || 0
    }
  end

  defp activation_preflight_overview_snapshot(_preflight), do: activation_preflight_overview_snapshot(%{})

  defp lifecycle_overview_snapshot(lifecycle) when is_map(lifecycle) do
    %{
      running_count: non_negative_integer(value(lifecycle, :running_count)) || 0,
      unknown_count: non_negative_integer(value(lifecycle, :unknown_count)) || 0,
      lost_count: non_negative_integer(value(lifecycle, :lost_count)) || 0,
      manual_attention_count: non_negative_integer(value(lifecycle, :manual_attention_count)) || 0,
      retained_workspace_count: non_negative_integer(value(lifecycle, :retained_workspace_count)) || 0
    }
  end

  defp lifecycle_overview_snapshot(_lifecycle), do: lifecycle_overview_snapshot(%{})

  defp manual_attention_overview_snapshot(manual_attention) when is_map(manual_attention) do
    %{
      total_count: non_negative_integer(value(manual_attention, :total_count)) || 0,
      project_ids: string_list(value(manual_attention, :project_ids)),
      reasons: sanitize_value(value(manual_attention, :reasons) || %{})
    }
  end

  defp manual_attention_overview_snapshot(_manual_attention), do: manual_attention_overview_snapshot(%{})

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

  defp overview_summary(
         projects,
         sources,
         scheduler,
         tick,
         provider_queue,
         candidate_intake,
         dispatch_planning,
         dispatch_plan_application,
         worker_start_handoff,
         worker_lifecycle_reconciliation
       ) do
    %{
      hub: %{
        runtime_enabled: hub_runtime_enabled?(sources, projects),
        mode: hub_mode(sources),
        project_count: length(projects),
        generated_at: value(sources, :generated_at)
      },
      scheduler: scheduler_overview(sources, scheduler, tick),
      provider_governance: provider_governance_overview(provider_queue),
      capacity: capacity_overview(projects, dispatch_planning, dispatch_plan_application, worker_start_handoff),
      workspace: workspace_overview(projects),
      writeback: writeback_overview(projects),
      activation_preflight: activation_preflight_overview(projects),
      lifecycle: lifecycle_overview(projects, worker_lifecycle_reconciliation),
      manual_attention: manual_attention_overview(projects),
      summary_errors: summary_errors(projects),
      candidate_intake: stage_topline(candidate_intake),
      dispatch_planning: stage_topline(dispatch_planning),
      dispatch_application: stage_topline(dispatch_plan_application),
      start_handoff: stage_topline(worker_start_handoff),
      lifecycle_reconciliation: stage_topline(worker_lifecycle_reconciliation)
    }
  end

  defp hub_runtime_enabled?(sources, projects) do
    hub_runtime = value(sources, :hub_runtime) || %{}

    hub_mode(sources) == "hub" or
      value(hub_runtime, :mode) == "hub" or
      value(sources, :runtime_enabled) == true or
      projects != []
  end

  defp hub_mode(sources) do
    hub_runtime = value(sources, :hub_runtime) || %{}
    optional_string(hub_runtime, :mode) || optional_string(sources, :mode) || "hub"
  end

  defp scheduler_overview(sources, scheduler, tick) do
    hub_runtime = value(sources, :hub_runtime) || %{}
    runtime_scheduler = map_value(hub_runtime, :scheduler)
    scheduler = scheduler || runtime_scheduler || %{}
    tick = tick || map_value(hub_runtime, :poll_tick) || %{}

    %{
      enabled: value(scheduler, :enabled) == true,
      status: value(scheduler, :status),
      running: value(scheduler, :running?) == true,
      queued: value(scheduler, :queued) == true,
      coalesced: value(scheduler, :coalesced) == true,
      next_tick_at: value(scheduler, :next_tick_at),
      next_reason: value(scheduler, :next_reason) || poll_tick_wait_reason(tick),
      last_tick: value(scheduler, :last_tick) || %{},
      poll_tick: tick_topline(tick)
    }
  end

  defp poll_tick_wait_reason(tick) do
    case safe_status(value(tick, :status)) do
      "idle" -> "idle"
      "running" -> "running"
      "completed" -> "completed"
      status when status != "" -> status
      _status -> nil
    end
  end

  defp tick_topline(tick) do
    %{
      status: default_status(value(tick, :status), "idle"),
      running: truthy?(value(tick, :running) || value(tick, :running?)),
      selected_count: non_negative_integer(value(tick, :selected_count)) || 0,
      result_counts: sanitize_value(value(tick, :result_counts) || %{})
    }
  end

  defp provider_governance_overview(provider_queue) do
    provider_scopes = list_value(provider_queue, :provider_scopes)
    pending = list_value(provider_queue, :pending)
    running = list_value(provider_queue, :running)
    recent_results = list_value(provider_queue, :recent_results)
    backpressure = list_value(provider_queue, :backpressure)
    unsupported = Enum.filter(pending ++ running ++ recent_results ++ backpressure, &unsupported_provider_entry?/1)

    quota_or_backoff_count =
      Enum.count(provider_scopes, fn scope ->
        state = map_value(scope, :state) || %{}
        quota_remaining_zero?(value(state, :quota) || %{}) or future_time?(value(state, :backoff_until))
      end)

    circuit_open_count =
      Enum.count(provider_scopes, fn scope ->
        state = map_value(scope, :state) || %{}
        safe_status(value(state, :circuit_state)) == "open"
      end)

    recent_failure_count =
      Enum.count(recent_results, fn result ->
        status = safe_status(value(result, :status) || value(result, :result_status))
        status in ["failed", "failure", "retryable_failure", "permanent_failure", "rate_limited", "error"]
      end)

    reasons =
      (Enum.map(backpressure, &default_status(value(&1, :reason), "backpressure")) ++
         Enum.map(unsupported, fn _entry -> "unsupported_provider_operation" end))
      |> Enum.reject(&blank?/1)
      |> Enum.frequencies()
      |> Map.new()

    %{
      pending_count: non_negative_integer(value(provider_queue, :pending_count)) || length(pending),
      running_count: non_negative_integer(value(provider_queue, :running_count)) || length(running),
      provider_scopes_count: length(provider_scopes),
      queue_pressure: pending != [] or Enum.any?(backpressure, &(safe_status(value(&1, :reason)) == "scope_concurrency")),
      quota_or_backoff_count: quota_or_backoff_count,
      circuit_open_count: circuit_open_count,
      unsupported_count: length(unsupported),
      recent_failure_count: recent_failure_count,
      manual_attention_count: Enum.count(backpressure ++ recent_results, &truthy?(value(&1, :manual_attention))),
      reasons: reasons
    }
  end

  defp unsupported_provider_entry?(entry) do
    reason = safe_status(value(entry, :reason) || value(entry, :error_class) || value(entry, :status))
    operation = safe_status(value(entry, :operation_kind) || value(entry, :operation))

    String.contains?(reason, "unsupported") or
      String.contains?(operation, "unsupported")
  end

  defp capacity_overview(projects, dispatch_planning, dispatch_plan_application, worker_start_handoff) do
    waiting_capacity_count =
      Enum.count(projects, &(&1.status == "waiting_capacity")) +
        count_reason(projects, "queue_pressure") +
        count_reason(projects, "project_capacity_full") +
        count_reason(projects, "global_capacity_full")

    planning_capacity_count = stage_count(dispatch_planning, :capacity_unavailable_count) || 0

    %{
      active_attempt_count:
        Enum.reduce(projects, 0, fn project, count ->
          count + length(project.runtime.active_attempts)
        end),
      pending_start_intent_count:
        stage_count(dispatch_plan_application, :pending_start_intent_count) ||
          stage_count(worker_start_handoff, :pending_start_intent_count) ||
          Enum.reduce(projects, 0, fn project, count -> count + length(project.runtime.pending_start_intents) end),
      waiting_capacity_count: max(waiting_capacity_count, planning_capacity_count),
      unreleased_capacity_count:
        Enum.reduce(projects, 0, fn project, count ->
          lifecycle = project.runtime.lifecycle
          count + length(lifecycle.retained_workspace) + length(project.runtime.workspace_leases)
        end)
    }
  end

  defp workspace_overview(projects) do
    Enum.reduce(projects, %{lease_count: 0, retained_count: 0}, fn project, totals ->
      lifecycle = project.runtime.lifecycle

      totals
      |> Map.update!(:lease_count, &(&1 + length(project.runtime.workspace_leases)))
      |> Map.update!(:retained_count, &(&1 + length(lifecycle.retained_workspace)))
    end)
  end

  defp writeback_overview(projects) do
    Enum.reduce(projects, writeback_overview_snapshot(%{}), fn project, totals ->
      counts = project.writebacks.counts

      all_writebacks =
        project.writebacks.pending ++
          project.writebacks.failed ++ project.writebacks.unknown ++ project.writebacks.manual_attention

      conflicts = project.conflicts

      totals
      |> Map.update!(:pending_count, &(&1 + counts.pending))
      |> Map.update!(:succeeded_count, &(&1 + counts.succeeded))
      |> Map.update!(:failed_count, &(&1 + counts.failed))
      |> Map.update!(:unknown_count, &(&1 + counts.unknown))
      |> Map.update!(:manual_attention_count, &(&1 + counts.manual_attention))
      |> Map.update!(:conflict_count, &(&1 + writeback_conflict_count(conflicts)))
      |> Map.update!(:provider_lookup_required_count, &(&1 + reason_match_count(all_writebacks, "provider_lookup")))
      |> Map.update!(
        :unknown_non_idempotent_count,
        &(&1 + reason_match_count(all_writebacks, "unknown_non_idempotent"))
      )
      |> Map.update!(:dangerous_replay_rejected_count, &(&1 + dangerous_replay_count(all_writebacks)))
    end)
  end

  defp writeback_conflict_count(conflicts) do
    Enum.count(conflicts, fn conflict ->
      code = safe_status(value(conflict, :code) || value(conflict, :reason))
      String.contains?(code, "writeback") and String.contains?(code, "conflict")
    end)
  end

  defp reason_match_count(entries, fragment) do
    Enum.count(entries, fn entry ->
      reason =
        safe_status(value(entry, :reason) || value(entry, :manual_attention_reason) || value(entry, :error_summary))

      String.contains?(reason, fragment)
    end)
  end

  defp dangerous_replay_count(entries) do
    Enum.count(entries, fn entry ->
      reason =
        safe_status(value(entry, :reason) || value(entry, :manual_attention_reason) || value(entry, :error_summary))

      replay_policy = safe_status(value(entry, :replay_policy))

      String.contains?(reason, "dangerous") or
        String.contains?(reason, "not_replayable") or
        (safe_status(value(entry, :result_status)) == "unknown" and replay_policy == "non_idempotent")
    end)
  end

  defp activation_preflight_overview(projects) do
    Enum.reduce(projects, activation_preflight_overview_snapshot(%{}), fn project, totals ->
      preflight = project.activation_preflight

      totals
      |> Map.update!(:blocked_count, &(&1 + if(preflight && preflight.status == "blocked_conflict", do: 1, else: 0)))
      |> Map.update!(:unknown_count, &(&1 + if(preflight && preflight.status == "unknown_manual_attention", do: 1, else: 0)))
      |> Map.update!(:manual_attention_count, &(&1 + if(preflight, do: preflight.manual_attention_count, else: 0)))
      |> Map.update!(:legacy_ownership_count, &(&1 + if(preflight, do: length(preflight.detected_legacy_ownership), else: 0)))
      |> Map.update!(:probe_unknown_count, &(&1 + if(preflight, do: length(preflight.unknown_probe_results), else: 0)))
    end)
  end

  defp lifecycle_overview(projects, worker_lifecycle_reconciliation) do
    from_projects =
      Enum.reduce(projects, lifecycle_overview_snapshot(%{}), fn project, totals ->
        counts = project.runtime.lifecycle.counts

        totals
        |> Map.update!(:running_count, &(&1 + counts.running))
        |> Map.update!(:unknown_count, &(&1 + counts.unknown))
        |> Map.update!(:lost_count, &(&1 + counts.lost))
        |> Map.update!(:manual_attention_count, &(&1 + counts.manual_attention))
        |> Map.update!(:retained_workspace_count, &(&1 + counts.retained_workspace))
      end)

    counts = value(worker_lifecycle_reconciliation, :counts) || %{}
    running_count = non_negative_integer(value(counts, :running_count)) || 0
    unknown_count = non_negative_integer(value(counts, :unknown_count)) || 0
    lost_count = non_negative_integer(value(counts, :lost_count)) || 0
    manual_attention_count = non_negative_integer(value(counts, :manual_attention_count)) || 0
    retained_workspace_count = non_negative_integer(value(counts, :retained_workspace_count)) || 0

    %{
      from_projects
      | running_count: max(from_projects.running_count, running_count),
        unknown_count: max(from_projects.unknown_count, unknown_count),
        lost_count: max(from_projects.lost_count, lost_count),
        manual_attention_count: max(from_projects.manual_attention_count, manual_attention_count),
        retained_workspace_count: max(from_projects.retained_workspace_count, retained_workspace_count)
    }
  end

  defp manual_attention_overview(projects) do
    attention_projects =
      Enum.filter(projects, fn project ->
        project.status == "manual_attention" or project.manual_attention != [] or project.summary_error != nil
      end)

    reasons =
      projects
      |> Enum.flat_map(& &1.backpressure_reasons)
      |> Enum.filter(&(&1.reason == "manual_attention" or String.contains?(&1.reason, "unknown")))
      |> Enum.map(& &1.reason)
      |> Enum.frequencies()

    %{
      total_count: length(attention_projects),
      project_ids: Enum.map(attention_projects, & &1.project_id),
      reasons: reasons
    }
  end

  defp summary_errors(projects) do
    projects
    |> Enum.filter(& &1.summary_error)
    |> Enum.map(fn project ->
      %{project_id: project.project_id, reason: project.summary_error.reason, message: project.summary_error.message}
    end)
  end

  defp stage_topline(stage) when is_map(stage) do
    %{
      status: default_status(value(stage, :status), "unknown"),
      counts: sanitize_value(value(stage, :counts) || %{}),
      reason_counts: sanitize_value(value(stage, :reason_counts) || value(stage, :skipped_reasons) || %{})
    }
  end

  defp stage_topline(_stage), do: stage_topline(%{})

  defp count_reason(projects, reason) do
    Enum.count(projects, fn project ->
      Enum.any?(project.backpressure_reasons, &(&1.reason == reason))
    end)
  end

  defp stage_count(stage, key) when is_map(stage) do
    stage
    |> value(:counts)
    |> value(key)
    |> non_negative_integer()
  end

  defp stage_count(_stage, _key), do: nil

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

  defp identity_summary(project_id, registry_project, poll_project, legacy_project) do
    provider = provider_summary(registry_project, poll_project, nil)

    %{
      project_id: project_id,
      name: project_name(registry_project, poll_project, legacy_project),
      provider_kind: provider.kind,
      provider_scope_key: provider.provider_scope_key,
      service: optional_string(legacy_project, :service)
    }
  end

  defp config_summary(nil), do: %{}

  defp config_summary(registry_project) do
    %{
      snapshot_version:
        optional_string(registry_project, :config_snapshot_version) ||
          optional_string(registry_project, :snapshot_version) ||
          optional_string(registry_project, :version),
      fingerprint: optional_string(registry_project, :fingerprint),
      loaded_at: value(registry_project, :loaded_at),
      status: value(registry_project, :status),
      error: optional_string(registry_project, :load_error)
    }
  end

  defp project_stage_summary(nil, _project_id), do: stage_snapshot(%{})

  defp project_stage_summary(stage, project_id) do
    project = find_project(stage, project_id) || %{}
    counts = value(project, :counts) || %{}
    reason_counts = value(project, :reason_counts) || value(project, :skipped_reasons) || %{}

    %{
      status: value(stage, :status),
      counts: counts,
      reason_counts: reason_counts,
      pending_count: stage_pending_count(project),
      unresolved_count: stage_unresolved_count(counts, project),
      manual_attention_count: stage_manual_attention_count(counts, project),
      recent: compact_stage_entries(project)
    }
  end

  defp start_handoff_summary(nil, _project_id), do: stage_snapshot(%{})

  defp start_handoff_summary(stage, project_id) do
    results = stage |> list_value(:results) |> Enum.filter(&(optional_string(&1, :project_id) == project_id))

    pending =
      stage
      |> list_value(:pending_start_intents)
      |> Enum.filter(&(optional_string(&1, :project_id) == project_id))

    unresolved =
      stage
      |> list_value(:unresolved_start_intents)
      |> Enum.filter(&(optional_string(&1, :project_id) == project_id))

    counts = %{
      selected_count: length(results),
      acked_count: Enum.count(results, &(safe_status(value(&1, :status)) == "ack")),
      failed_count: Enum.count(results, &(safe_status(value(&1, :status)) == "failed")),
      unknown_count: Enum.count(results, &(safe_status(value(&1, :status)) == "unknown")),
      manual_attention_count: Enum.count(results, &(safe_status(value(&1, :status)) == "manual_attention")),
      skipped_count: Enum.count(results, &(safe_status(value(&1, :status)) == "skipped")),
      pending_start_intent_count: length(pending),
      unresolved_start_intent_count: length(unresolved)
    }

    %{
      status: value(stage, :status),
      counts: counts,
      reason_counts: reason_counts(results),
      pending_count: length(pending),
      unresolved_count: length(unresolved),
      manual_attention_count: counts.manual_attention_count,
      recent: compact_entries(results ++ unresolved)
    }
  end

  defp lifecycle_reconciliation_summary(nil, _project_id), do: stage_snapshot(%{})

  defp lifecycle_reconciliation_summary(stage, project_id) do
    results = stage |> list_value(:results) |> Enum.filter(&(optional_string(&1, :project_id) == project_id))

    counts = %{
      selected_count: length(results),
      running_count: Enum.count(results, &(safe_status(value(&1, :status)) == "running")),
      succeeded_count: Enum.count(results, &(safe_status(value(&1, :status)) == "succeeded")),
      failed_count: Enum.count(results, &(safe_status(value(&1, :status)) == "failed")),
      lost_count: Enum.count(results, &(safe_status(value(&1, :status)) == "lost")),
      unknown_count: Enum.count(results, &(safe_status(value(&1, :status)) == "unknown")),
      manual_attention_count: Enum.count(results, &(safe_status(value(&1, :status)) == "manual_attention" or truthy?(value(&1, :manual_attention)))),
      retained_workspace_count: Enum.count(results, &(safe_status(value(&1, :workspace_action)) == "retained")),
      released_workspace_count: Enum.count(results, &(safe_status(value(&1, :workspace_action)) == "released"))
    }

    %{
      status: value(stage, :status),
      counts: counts,
      reason_counts: reason_counts(results),
      pending_count: 0,
      unresolved_count: counts.lost_count + counts.unknown_count + counts.manual_attention_count,
      manual_attention_count: counts.manual_attention_count,
      recent: compact_entries(results)
    }
  end

  defp stage_pending_count(project) do
    length(list_value(project, :pending_intents)) + length(list_value(project, :pending_start_intents))
  end

  defp stage_unresolved_count(counts, project) do
    non_negative_integer(value(counts, :unresolved_count)) ||
      non_negative_integer(value(counts, :unresolved_start_intent_count)) ||
      length(list_value(project, :unresolved_start_intents)) ||
      0
  end

  defp stage_manual_attention_count(counts, project) do
    non_negative_integer(value(counts, :manual_attention_count)) ||
      Enum.count(list_value(project, :outcomes), &(safe_status(value(&1, :status)) == "manual_attention")) ||
      0
  end

  defp compact_stage_entries(project) do
    project
    |> list_value(:candidates)
    |> Kernel.++(list_value(project, :invalid_candidates))
    |> Kernel.++(list_value(project, :outcomes))
    |> Kernel.++(list_value(project, :pending_intents))
    |> Kernel.++(list_value(project, :pending_start_intents))
    |> compact_entries()
  end

  defp compact_entries(entries) do
    entries
    |> Enum.take(5)
    |> Enum.map(fn entry ->
      %{
        status: safe_status(value(entry, :status) || value(entry, :result_status) || value(entry, :claim_status)),
        reason: safe_status(value(entry, :reason) || value(entry, :skipped_reason) || value(entry, :invalid_reason)),
        issue_key: optional_string(entry, :issue_key),
        candidate_key: optional_string(entry, :candidate_key),
        intent_id: optional_string(entry, :intent_id) || optional_string(entry, :start_intent_id),
        attempt_id: optional_string(entry, :attempt_id),
        workspace_path: optional_string(entry, :workspace_path)
      }
    end)
    |> sanitize_list()
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

  defp default_status(value, default) do
    case safe_status(value) do
      "" -> default
      status -> status
    end
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
