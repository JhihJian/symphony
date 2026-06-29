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
    provider_queue = provider_queue_summary(sources, poll_coordination)
    legacy_projects = list_value(sources, :legacy_projects)
    managed_project_ids = managed_project_ids(sources, opts)

    project_ids =
      [
        registry |> list_value(:projects) |> Enum.map(&required_string(&1, :project_id)),
        poll_coordination |> list_value(:projects) |> Enum.map(&required_string(&1, :project_id)),
        runtime |> list_value(:projects) |> Enum.map(&required_string(&1, :project_id)),
        Enum.map(legacy_projects, &required_string(&1, :project_id))
      ]
      |> List.flatten()
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.sort()

    projects =
      Enum.map(project_ids, fn project_id ->
        project_projection(
          project_id,
          registry,
          poll_coordination,
          runtime,
          provider_queue,
          legacy_projects,
          managed_project_ids
        )
      end)

    projection = %{
      version: @version,
      generated_at: now,
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
         provider_queue,
         legacy_projects,
         managed_project_ids
       ) do
    registry_project = find_project(registry, project_id)
    poll_project = find_project(poll_coordination, project_id)
    runtime_project = find_project(runtime, project_id)
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

  defp project_snapshot(project) when is_map(project) do
    project_id = required_string(project, :project_id)

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
      blocked_candidates: sanitize_list(value(runtime, :blocked_candidates))
    }
  end

  defp runtime_snapshot(_runtime), do: runtime_snapshot(%{})

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
        blocked_candidates: list_value(runtime_project, :blocked_candidates)
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
        end)
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
         writebacks,
         provider_queue
       ) do
    project_id = project.project_id
    config_error = optional_string(registry_project || %{}, :load_error)
    writeback_counts = writeback_count_snapshot(value(writebacks, :counts))

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
