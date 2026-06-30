defmodule SymphonyElixir.Hub.CutoverGate do
  @moduledoc """
  Safe Hub migration cutover gate decision model.

  The gate consumes Dashboard/API-safe Hub summaries and decides which
  Hub-owned operations may proceed for each project. It is read-only: it does
  not edit project config, stop legacy services, start workers, or write to
  providers.
  """

  alias SymphonyElixir.Hub.{ActivationPlan, SafeSummary}

  @version 1
  @operations ["poll", "dispatch", "worker_start", "writeback"]
  @decisions ["not_applicable", "blocked", "manual_attention", "staged_ready", "allowed"]
  @blocking_ack_statuses ["missing", "stale", "conflict"]
  @manual_attention_ack_statuses ["malformed", "unsupported", "manual_attention"]

  @type summary :: map()
  @type project_decision :: map()

  @spec build(term(), keyword()) :: summary()
  def build(sources, opts \\ []) when is_list(opts) do
    now =
      opts
      |> Keyword.get(:now)
      |> Kernel.||(value(sources, :generated_at))
      |> Kernel.||(DateTime.utc_now())
      |> iso8601()

    projects = list_value(sources, :projects)
    overview = map_value(sources, :overview)
    migration_readiness = map_value(sources, :migration_readiness)
    activation_plan = map_value(sources, :activation_plan)
    runtime = runtime_summary(sources, overview, migration_readiness)

    context = %{
      generated_at: now,
      runtime: runtime,
      readiness_by_project: index_projects(value(migration_readiness, :projects)),
      activation_plan_by_project: index_projects(value(activation_plan, :projects))
    }

    project_decisions =
      projects
      |> Enum.map(&safe_project_decision(&1, context))
      |> Enum.sort_by(& &1.project_id)

    %{
      version: @version,
      generated_at: now,
      status: overall_status(project_decisions),
      operation_set: @operations,
      counts: count_snapshot(%{}, project_decisions),
      projects: project_decisions,
      staged_ownership_records: staged_records(project_decisions)
    }
    |> to_snapshot()
  end

  @spec to_snapshot(term()) :: summary()
  def to_snapshot(summary) when is_map(summary) do
    projects =
      summary
      |> list_value(:projects)
      |> Enum.map(&project_snapshot/1)
      |> Enum.sort_by(& &1.project_id)

    %{
      version: positive_integer(value(summary, :version)) || @version,
      generated_at: iso8601(value(summary, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601(),
      status: normalize_overall_status(value(summary, :status), projects),
      operation_set: string_list(value(summary, :operation_set)) |> Enum.filter(&(&1 in @operations)),
      counts: count_snapshot(value(summary, :counts), projects),
      projects: projects,
      staged_ownership_records:
        case list_value(summary, :staged_ownership_records) do
          [] -> staged_records(projects)
          records -> Enum.map(records, &staged_record_snapshot/1)
        end
    }
  end

  def to_snapshot(_summary), do: to_snapshot(%{})

  @spec observability_snapshot(term()) :: summary() | nil
  def observability_snapshot(nil), do: nil
  def observability_snapshot(summary) when is_map(summary), do: to_snapshot(summary)
  def observability_snapshot(_summary), do: nil

  @spec project(summary() | map(), String.t() | nil) :: project_decision() | nil
  def project(summary, project_id) when is_map(summary) and is_binary(project_id) do
    summary
    |> to_snapshot()
    |> list_value(:projects)
    |> Enum.find(&(&1.project_id == project_id))
  end

  def project(_summary, _project_id), do: nil

  @spec allowed?(summary() | map() | nil, String.t() | nil, String.t() | atom()) :: boolean()
  def allowed?(summary, project_id, operation) do
    operation = operation_name(operation)

    case project(summary, project_id) do
      %{allowed_operations: allowed} -> operation in allowed
      _project -> false
    end
  end

  @spec block_reason(summary() | map() | nil, String.t() | nil, String.t() | atom()) :: map() | nil
  def block_reason(nil, _project_id, _operation), do: nil

  def block_reason(summary, project_id, operation) do
    operation = operation_name(operation)

    case project(summary, project_id) do
      nil ->
        nil

      %{allowed_operations: allowed} = project ->
        if operation in allowed do
          nil
        else
          reason = first_reason(project)

          %{
            reason: "cutover_gate_blocked",
            status: project.decision,
            message: reason_message(reason, operation),
            blocked_operations: project.blocked_operations,
            allowed_operations: project.allowed_operations,
            required_operator_actions: project.required_operator_actions,
            sources: reason_sources(project),
            cutover_gate: project_block_reason_snapshot(project)
          }
        end
    end
  end

  defp safe_project_decision(project, context) do
    project_decision(project, context)
  rescue
    _error ->
      summary_error_project(required_string(project, :project_id), context.generated_at)
  catch
    _kind, _reason ->
      summary_error_project(required_string(project, :project_id), context.generated_at)
  end

  defp project_decision(project, context) do
    project_id = required_string(project, :project_id)
    readiness = Map.get(context.readiness_by_project, project_id) || value(project, :migration_readiness) || %{}
    plan = Map.get(context.activation_plan_by_project, project_id) || value(project, :activation_plan) || %{}
    acknowledgement = ActivationPlan.acknowledgement_snapshot(value(plan, :operator_acknowledgement))
    preflight = preflight_snapshot(value(project, :activation_preflight))
    provider = provider_snapshot(value(project, :provider) || get_in_map(project, [:detail, :identity]))

    migration_input =
      value(project, :migration_state) ||
        value(readiness, :migration_state) ||
        value(plan, :migration_state)

    migration_state = normalize_migration_state(migration_input)

    readiness_decision = normalize_readiness_decision(value(readiness, :decision) || value(plan, :readiness_decision))
    modes = mode_snapshot(context.runtime)

    blocking =
      []
      |> add_reason(migration_state == "legacy_only", "legacy_only_project", "project_registry", %{migration_state: migration_state})
      |> add_reason(migration_state == "hub_ready", "migration_state_not_hub_managed", "project_registry", %{migration_state: migration_state})
      |> add_reason(
        migration_state not in ["legacy_only", "hub_ready", "hub_managed"],
        "migration_state_unknown",
        "project_registry",
        %{migration_state: migration_state}
      )
      |> add_ack_reasons(acknowledgement)
      |> add_readiness_reasons(readiness)
      |> add_preflight_reasons(preflight)
      |> add_summary_error_reason(value(project, :summary_error))
      |> add_mode_reasons(modes)

    advisory =
      []
      |> add_reason(readiness_decision == "ready_for_hub_management", "activation_plan_pre_mark_hub_managed", "activation_plan", %{})
      |> add_reason(readiness_decision == "ready_for_dry_run", "dry_run_not_cutover_ready", "migration_readiness", %{})
      |> add_reason(readiness_decision == "legacy_only", "legacy_only_project", "migration_readiness", %{})
      |> add_reason(modes.scheduler.enabled != true, "scheduler_disabled", "scheduler", modes.scheduler)
      |> Enum.map(&Map.merge(&1, %{level: "advisory", blocks_cutover: false}))

    required_actions = required_actions(blocking, advisory)

    allowed_operations =
      allowed_operations(migration_state, acknowledgement, readiness_decision, preflight, modes, blocking)

    blocked_operations = @operations -- allowed_operations
    decision = project_decision_status(migration_state, blocking, allowed_operations, blocked_operations)

    project_snapshot(%{
      project_id: project_id,
      provider: provider,
      migration_state: migration_state,
      activation_plan: activation_plan_snapshot(plan),
      operator_acknowledgement: acknowledgement,
      readiness: readiness_snapshot(readiness),
      activation_preflight: preflight,
      modes: modes,
      decision: decision,
      allowed_operations: allowed_operations,
      blocked_operations: blocked_operations,
      blocking_reasons: blocking,
      advisory_reasons: advisory,
      required_operator_actions: required_actions,
      safe_evidence: safe_evidence(project, readiness, plan, preflight, modes),
      staged_ownership_record:
        staged_record(%{
          project_id: project_id,
          provider: provider,
          migration_state: migration_state,
          activation_plan: plan,
          acknowledgement: acknowledgement,
          preflight: preflight,
          modes: modes,
          allowed_operations: allowed_operations,
          decision: decision,
          generated_at: context.generated_at
        })
    })
  end

  defp summary_error_project(project_id, generated_at) do
    reason = reason("cutover_gate_summary_error", "cutover_gate", %{project_id: project_id})

    project_snapshot(%{
      project_id: project_id,
      migration_state: "hub_ready",
      decision: "manual_attention",
      allowed_operations: [],
      blocked_operations: @operations,
      blocking_reasons: [reason],
      required_operator_actions: [%{code: "inspect_summary_error"}],
      safe_evidence: %{summary_error: %{code: "cutover_gate_summary_error"}},
      staged_ownership_record: nil,
      generated_at: generated_at
    })
  end

  defp project_snapshot(project) when is_map(project) do
    allowed = operation_list(value(project, :allowed_operations))

    blocked =
      case operation_list(value(project, :blocked_operations)) do
        [] -> @operations -- allowed
        operations -> operations
      end

    migration_state = normalize_migration_state(value(project, :migration_state))

    %{
      version: positive_integer(value(project, :version)) || @version,
      project_id: required_string(project, :project_id),
      provider: provider_snapshot(value(project, :provider)),
      migration_state: migration_state,
      activation_plan: activation_plan_snapshot(value(project, :activation_plan)),
      operator_acknowledgement: ActivationPlan.acknowledgement_snapshot(value(project, :operator_acknowledgement)),
      readiness: readiness_snapshot(value(project, :readiness)),
      activation_preflight: preflight_snapshot(value(project, :activation_preflight)),
      modes: mode_snapshot(value(project, :modes)),
      decision: normalize_decision(value(project, :decision), migration_state, allowed, blocked),
      allowed_operations: allowed,
      blocked_operations: blocked,
      blocking_reasons: reason_snapshots(value(project, :blocking_reasons), "blocking"),
      advisory_reasons: reason_snapshots(value(project, :advisory_reasons), "advisory"),
      required_operator_actions: action_snapshots(value(project, :required_operator_actions)),
      safe_evidence: SafeSummary.sanitize_map(value(project, :safe_evidence) || %{}, output_keys: :preserve),
      staged_ownership_record: staged_record_snapshot(value(project, :staged_ownership_record))
    }
  end

  defp project_snapshot(_project), do: project_snapshot(%{})

  defp activation_plan_snapshot(plan) when is_map(plan) do
    %{
      plan_id: optional_string(plan, :plan_id),
      fingerprint:
        optional_string(plan, :fingerprint) ||
          optional_string(plan, :plan_fingerprint) ||
          optional_string(plan, :plan_id),
      status: safe_status(value(plan, :status)) |> blank_to_default("unknown"),
      readiness_decision: normalize_readiness_decision(value(plan, :readiness_decision)),
      proposed_next_state: safe_status(value(plan, :proposed_next_state))
    }
  end

  defp activation_plan_snapshot(_plan), do: activation_plan_snapshot(%{})

  defp readiness_snapshot(readiness) when is_map(readiness) do
    %{
      decision: normalize_readiness_decision(value(readiness, :decision)),
      blocking_reasons: reason_snapshots(value(readiness, :blocking_reasons), "blocking"),
      advisory_reasons: reason_snapshots(value(readiness, :advisory_reasons), "advisory"),
      required_operator_actions: action_snapshots(value(readiness, :required_operator_actions)),
      evidence: SafeSummary.sanitize_map(value(readiness, :evidence) || %{}, output_keys: :preserve)
    }
  end

  defp readiness_snapshot(_readiness), do: readiness_snapshot(%{})

  defp preflight_snapshot(preflight) when is_map(preflight) do
    %{
      status: safe_status(value(preflight, :status)) |> blank_to_default("unknown_manual_attention"),
      safe_to_manage: truthy?(value(preflight, :safe_to_manage)),
      reason: optional_string(preflight, :reason),
      message: optional_string(preflight, :message),
      checked_at: iso8601(value(preflight, :checked_at)),
      probe_source: optional_string(preflight, :probe_source),
      blocked_operations: operation_list(value(preflight, :blocked_operations)),
      conflict_count: non_negative_integer(value(preflight, :conflict_count)) || 0,
      manual_attention_count: non_negative_integer(value(preflight, :manual_attention_count)) || 0,
      detected_legacy_ownership: safe_list(value(preflight, :detected_legacy_ownership)),
      unknown_probe_results: safe_list(value(preflight, :unknown_probe_results))
    }
  end

  defp preflight_snapshot(_preflight) do
    %{
      status: "unknown_manual_attention",
      safe_to_manage: false,
      reason: nil,
      message: nil,
      checked_at: nil,
      probe_source: nil,
      blocked_operations: @operations,
      conflict_count: 0,
      manual_attention_count: 1,
      detected_legacy_ownership: [],
      unknown_probe_results: []
    }
  end

  defp mode_snapshot(runtime) when is_map(runtime) do
    %{
      scheduler: %{
        enabled: truthy?(value(runtime, :scheduler_enabled) || get_in_map(runtime, [:scheduler, :enabled])),
        status:
          value(runtime, :scheduler_status)
          |> Kernel.||(get_in_map(runtime, [:scheduler, :status]))
          |> safe_status()
          |> blank_to_default("disabled")
      },
      provider_executor: executor_snapshot(value(runtime, :provider_executor)),
      writeback_executor: executor_snapshot(value(runtime, :writeback_executor)),
      worker_starter: worker_starter_snapshot(value(runtime, :worker_starter)),
      activation_probe: SafeSummary.sanitize_map(value(runtime, :activation_probe) || %{}, output_keys: :preserve)
    }
  end

  defp mode_snapshot(_runtime), do: mode_snapshot(%{})

  defp executor_snapshot(executor) when is_map(executor) do
    %{
      mode: safe_status(value(executor, :mode)) |> blank_to_default("unknown"),
      provider_io: value(executor, :provider_io),
      supported_operations: string_list(value(executor, :supported_operations)),
      supported_logical_actions: string_list(value(executor, :supported_logical_actions)),
      rejected_operations: string_list(value(executor, :rejected_operations))
    }
  end

  defp executor_snapshot(_executor), do: executor_snapshot(%{})

  defp worker_starter_snapshot(starter) when is_map(starter) do
    %{
      mode: safe_status(value(starter, :mode)) |> blank_to_default("unknown"),
      worker_start: value(starter, :worker_start)
    }
  end

  defp worker_starter_snapshot(_starter), do: worker_starter_snapshot(%{})

  defp allowed_operations("hub_managed", acknowledgement, readiness_decision, preflight, modes, blocking) do
    if base_allowed?(acknowledgement, readiness_decision, preflight, blocking) do
      @operations
      |> Enum.filter(&mode_allows_operation?(&1, modes))
    else
      []
    end
  end

  defp allowed_operations(_migration_state, _acknowledgement, _readiness_decision, _preflight, _modes, _blocking), do: []

  defp base_allowed?(acknowledgement, readiness_decision, preflight, blocking) do
    acknowledgement.status == "accepted" and
      value(acknowledgement, :plan_id_matches) == true and
      readiness_decision == "already_hub_managed" and
      preflight.safe_to_manage == true and
      preflight.status == "safe_to_manage" and
      Enum.all?(blocking, &mode_reason?/1)
  end

  defp mode_reason?(reason) do
    source = optional_string(reason, :source)
    source in ["hub_runtime", "scheduler", "provider_executor", "writeback_executor", "worker_starter"]
  end

  defp mode_allows_operation?("poll", modes) do
    provider = modes.provider_executor
    truthy?(provider.provider_io) and "candidate_scan" in provider.supported_operations
  end

  defp mode_allows_operation?("dispatch", _modes), do: true

  defp mode_allows_operation?("worker_start", modes) do
    truthy?(modes.worker_starter.worker_start) and modes.worker_starter.mode == "real_worker_starter"
  end

  defp mode_allows_operation?("writeback", modes) do
    executor = modes.writeback_executor
    truthy?(executor.provider_io) and executor.mode == "real_writeback" and executor.supported_operations != []
  end

  defp mode_allows_operation?(_operation, _modes), do: false

  defp project_decision_status("legacy_only", _blocking, _allowed, _blocked), do: "not_applicable"

  defp project_decision_status(_migration_state, blocking, [], _blocked) do
    if Enum.any?(blocking, &(optional_string(&1, :level) == "manual_attention")) do
      "manual_attention"
    else
      "blocked"
    end
  end

  defp project_decision_status(_migration_state, _blocking, _allowed, []), do: "allowed"
  defp project_decision_status(_migration_state, _blocking, _allowed, _blocked), do: "staged_ready"

  defp add_ack_reasons(reasons, acknowledgement) do
    cond do
      acknowledgement.status == "accepted" and acknowledgement.plan_id_matches == true ->
        reasons

      acknowledgement.status in @blocking_ack_statuses ->
        [reason("operator_acknowledgement_#{acknowledgement.status}", "operator_acknowledgement", ack_evidence(acknowledgement)) | reasons]

      acknowledgement.status in @manual_attention_ack_statuses ->
        [
          reason("operator_acknowledgement_#{acknowledgement.status}", "operator_acknowledgement", ack_evidence(acknowledgement))
          |> Map.merge(%{level: "manual_attention", blocks_cutover: true})
          | reasons
        ]

      true ->
        [reason("operator_acknowledgement_missing", "operator_acknowledgement", ack_evidence(acknowledgement)) | reasons]
    end
  end

  defp add_readiness_reasons(reasons, readiness) do
    readiness = readiness_snapshot(readiness)

    readiness.blocking_reasons
    |> Enum.reduce(reasons, fn reason, acc ->
      [Map.merge(reason, %{blocks_cutover: true}) | acc]
    end)
    |> add_reason(
      readiness.decision in ["blocked", "unknown_manual_attention"],
      "migration_readiness_#{readiness.decision}",
      "migration_readiness",
      %{decision: readiness.decision}
    )
    |> add_reason(
      readiness.decision != "already_hub_managed",
      "migration_readiness_not_already_hub_managed",
      "migration_readiness",
      %{decision: readiness.decision}
    )
  end

  defp add_preflight_reasons(reasons, preflight) do
    reasons =
      preflight.detected_legacy_ownership
      |> Enum.reduce(reasons, fn ownership, acc ->
        [reason("legacy_ownership_conflict", "activation_preflight", ownership) | acc]
      end)

    reasons =
      preflight.unknown_probe_results
      |> Enum.reduce(reasons, fn unknown, acc ->
        [
          reason("probe_unknown", "activation_preflight", unknown)
          |> Map.merge(%{level: "manual_attention", blocks_cutover: true})
          | acc
        ]
      end)

    reasons
    |> add_reason(
      preflight.status in ["blocked_conflict", "config_invalid"],
      "activation_preflight_#{preflight.status}",
      "activation_preflight",
      preflight_evidence(preflight)
    )
    |> add_manual_reason(
      preflight.status == "unknown_manual_attention",
      "activation_preflight_unknown",
      "activation_preflight",
      preflight_evidence(preflight)
    )
    |> add_reason(
      preflight.safe_to_manage != true,
      "activation_preflight_not_safe",
      "activation_preflight",
      preflight_evidence(preflight)
    )
  end

  defp add_summary_error_reason(reasons, nil), do: reasons

  defp add_summary_error_reason(reasons, summary_error) do
    [
      reason("project_summary_error", "hub_device_observability", SafeSummary.sanitize_map(summary_error, output_keys: :preserve))
      |> Map.merge(%{level: "manual_attention", blocks_cutover: true})
      | reasons
    ]
  end

  defp add_mode_reasons(reasons, modes) do
    reasons
    |> add_reason(not mode_allows_operation?("poll", modes), "provider_executor_candidate_scan_not_real", "provider_executor", modes.provider_executor)
    |> add_reason(not mode_allows_operation?("worker_start", modes), "worker_starter_not_real", "worker_starter", modes.worker_starter)
    |> add_reason(not mode_allows_operation?("writeback", modes), "writeback_executor_not_real", "writeback_executor", modes.writeback_executor)
  end

  defp add_reason(reasons, true, code, source, evidence), do: [reason(code, source, evidence) | reasons]
  defp add_reason(reasons, _condition, _code, _source, _evidence), do: reasons

  defp add_manual_reason(reasons, true, code, source, evidence) do
    [reason(code, source, evidence) |> Map.merge(%{level: "manual_attention", blocks_cutover: true}) | reasons]
  end

  defp add_manual_reason(reasons, _condition, _code, _source, _evidence), do: reasons

  defp reason(code, source, evidence) do
    %{
      code: safe_status(code),
      label: label_for(code),
      source: source,
      level: "blocking",
      blocks_cutover: true,
      evidence: SafeSummary.sanitize_map(evidence || %{}, output_keys: :preserve)
    }
  end

  defp reason_snapshots(reasons, default_level) when is_list(reasons) do
    reasons
    |> Enum.map(&reason_snapshot(&1, default_level))
    |> Enum.reject(&blank?(&1.code))
    |> Enum.uniq_by(&{&1.code, &1.source, inspect(&1.evidence)})
    |> Enum.sort_by(&{&1.code, &1.source || ""})
  end

  defp reason_snapshots(_reasons, _default_level), do: []

  defp reason_snapshot(reason, default_level) when is_map(reason) do
    %{
      code: safe_status(value(reason, :code) || value(reason, :reason)) |> blank_to_default("unknown"),
      label: optional_string(reason, :label) || label_for(value(reason, :code) || value(reason, :reason)),
      source: optional_string(reason, :source),
      level: safe_status(value(reason, :level)) |> blank_to_default(default_level),
      blocks_cutover: value(reason, :blocks_cutover) != false,
      evidence: SafeSummary.sanitize_map(value(reason, :evidence) || %{}, output_keys: :preserve)
    }
  end

  defp reason_snapshot(reason, default_level), do: reason_snapshot(%{code: reason}, default_level)

  defp action_snapshots(actions) when is_list(actions) do
    actions
    |> Enum.map(&action_snapshot/1)
    |> Enum.reject(&blank?(&1.code))
    |> Enum.uniq_by(& &1.code)
    |> Enum.sort_by(& &1.code)
  end

  defp action_snapshots(_actions), do: []

  defp action_snapshot(action) when is_map(action) do
    code = safe_status(value(action, :code))
    %{code: code, label: optional_string(action, :label) || label_for(code)}
  end

  defp action_snapshot(action), do: action_snapshot(%{code: action})

  defp required_actions(blocking, advisory) do
    (blocking ++ advisory)
    |> Enum.flat_map(&actions_for_reason(&1.code))
    |> Enum.map(&%{code: &1, label: label_for(&1)})
    |> Enum.uniq_by(& &1.code)
    |> Enum.sort_by(& &1.code)
  end

  defp actions_for_reason("legacy_only_project"), do: ["prepare_hub_yaml"]
  defp actions_for_reason("migration_state_not_hub_managed"), do: ["mark_hub_managed_after_checks"]
  defp actions_for_reason("operator_acknowledgement_missing"), do: ["accept_activation_plan"]
  defp actions_for_reason("operator_acknowledgement_stale"), do: ["refresh_activation_plan_acknowledgement"]
  defp actions_for_reason("operator_acknowledgement_conflict"), do: ["fix_activation_plan_acknowledgement"]
  defp actions_for_reason("operator_acknowledgement_malformed"), do: ["fix_activation_plan_acknowledgement"]
  defp actions_for_reason("operator_acknowledgement_unsupported"), do: ["fix_activation_plan_acknowledgement"]
  defp actions_for_reason("operator_acknowledgement_manual_attention"), do: ["review_activation_plan_acknowledgement"]
  defp actions_for_reason("activation_preflight_unknown"), do: ["enable_host_service_probe"]
  defp actions_for_reason("activation_preflight_not_safe"), do: ["resolve_activation_preflight"]
  defp actions_for_reason("activation_preflight_blocked_conflict"), do: ["resolve_legacy_ownership_conflict"]
  defp actions_for_reason("legacy_ownership_conflict"), do: ["resolve_legacy_ownership_conflict"]
  defp actions_for_reason("probe_unknown"), do: ["enable_host_service_probe"]
  defp actions_for_reason("project_summary_error"), do: ["inspect_summary_error"]
  defp actions_for_reason("scheduler_disabled"), do: ["enable_hub_scheduler_before_management"]
  defp actions_for_reason("provider_executor_candidate_scan_not_real"), do: ["confirm_hub_executor_modes"]
  defp actions_for_reason("worker_starter_not_real"), do: ["confirm_hub_executor_modes"]
  defp actions_for_reason("writeback_executor_not_real"), do: ["confirm_hub_executor_modes"]
  defp actions_for_reason("migration_readiness_not_already_hub_managed"), do: ["review_migration_readiness"]
  defp actions_for_reason("activation_plan_pre_mark_hub_managed"), do: ["mark_hub_managed_after_checks"]
  defp actions_for_reason(_reason), do: ["manual_review"]

  defp staged_record(%{allowed_operations: []}), do: nil

  defp staged_record(attrs) do
    allowed_operations = operation_list(value(attrs, :allowed_operations))
    acknowledgement = value(attrs, :acknowledgement) || %{}
    plan = activation_plan_snapshot(value(attrs, :activation_plan))
    provider = provider_snapshot(value(attrs, :provider))
    modes = mode_snapshot(value(attrs, :modes))
    preflight = preflight_snapshot(value(attrs, :preflight))

    fingerprint_payload = %{
      project_id: value(attrs, :project_id),
      provider: provider,
      migration_state: value(attrs, :migration_state),
      plan_id: plan.plan_id,
      plan_fingerprint: plan.fingerprint,
      acknowledgement: %{
        status: acknowledgement.status,
        source: acknowledgement.source,
        created_at: acknowledgement.created_at,
        acknowledged_action_codes: acknowledgement.acknowledged_action_codes,
        acknowledged_risk_codes: acknowledgement.acknowledged_risk_codes
      },
      preflight: %{
        status: preflight.status,
        checked_at: preflight.checked_at,
        probe_source: preflight.probe_source,
        reason: preflight.reason
      },
      modes: modes,
      allowed_operations: allowed_operations
    }

    %{
      record_id: fingerprint(fingerprint_payload),
      project_id: required_string(attrs, :project_id),
      provider: provider,
      migration_state: normalize_migration_state(value(attrs, :migration_state)),
      plan_id: plan.plan_id,
      plan_fingerprint: plan.fingerprint,
      acknowledgement: %{
        status: acknowledgement.status,
        source: acknowledgement.source,
        created_at: acknowledgement.created_at,
        acknowledged_action_codes: acknowledgement.acknowledged_action_codes,
        acknowledged_risk_codes: acknowledgement.acknowledged_risk_codes
      },
      activation_preflight: %{
        status: preflight.status,
        checked_at: preflight.checked_at,
        probe_source: preflight.probe_source,
        reason: preflight.reason
      },
      modes: modes,
      allowed_operations: allowed_operations,
      generated_at: iso8601(value(attrs, :generated_at)),
      note: "read_only_audit_record_no_external_state_change"
    }
    |> staged_record_snapshot()
  end

  defp staged_record_snapshot(nil), do: nil

  defp staged_record_snapshot(record) when is_map(record) do
    acknowledgement =
      SafeSummary.sanitize_map(value(record, :acknowledgement) || %{}, output_keys: :preserve)

    activation_preflight =
      SafeSummary.sanitize_map(value(record, :activation_preflight) || %{}, output_keys: :preserve)

    %{
      record_id: optional_string(record, :record_id),
      project_id: required_string(record, :project_id),
      provider: provider_snapshot(value(record, :provider)),
      migration_state: normalize_migration_state(value(record, :migration_state)),
      plan_id: optional_string(record, :plan_id),
      plan_fingerprint: optional_string(record, :plan_fingerprint),
      acknowledgement: acknowledgement,
      activation_preflight: activation_preflight,
      modes: mode_snapshot(value(record, :modes)),
      allowed_operations: operation_list(value(record, :allowed_operations)),
      generated_at: iso8601(value(record, :generated_at)),
      note: optional_string(record, :note) || "read_only_audit_record_no_external_state_change"
    }
  end

  defp staged_record_snapshot(_record), do: nil

  defp staged_records(projects) do
    projects
    |> Enum.map(&value(&1, :staged_ownership_record))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&staged_record_snapshot/1)
    |> Enum.sort_by(&{&1.project_id, &1.record_id || ""})
  end

  defp safe_evidence(project, readiness, plan, preflight, modes) do
    %{
      project: %{
        status: safe_status(value(project, :status)),
        dispatch_enabled: value(project, :dispatch_enabled)
      },
      readiness: %{
        decision: normalize_readiness_decision(value(readiness, :decision)),
        blocking_reason_codes: readiness |> list_value(:blocking_reasons) |> Enum.map(&safe_status(value(&1, :code) || value(&1, :reason)))
      },
      activation_plan: %{
        plan_id: optional_string(plan, :plan_id),
        status: safe_status(value(plan, :status))
      },
      activation_preflight: preflight_evidence(preflight),
      modes: modes
    }
    |> SafeSummary.sanitize_map(output_keys: :preserve)
  end

  defp preflight_evidence(preflight) do
    %{
      status: preflight.status,
      safe_to_manage: preflight.safe_to_manage,
      reason: preflight.reason,
      checked_at: preflight.checked_at,
      probe_source: preflight.probe_source,
      conflict_count: preflight.conflict_count,
      manual_attention_count: preflight.manual_attention_count,
      blocked_operations: preflight.blocked_operations
    }
  end

  defp ack_evidence(acknowledgement) do
    %{
      status: acknowledgement.status,
      required: acknowledgement.required,
      plan_id: acknowledgement.plan_id,
      plan_id_matches: acknowledgement.plan_id_matches,
      source: acknowledgement.source,
      created_at: acknowledgement.created_at,
      missing_acknowledgements: acknowledgement.missing_acknowledgements,
      stale_reasons: acknowledgement.stale_reasons,
      conflict_reasons: acknowledgement.conflict_reasons,
      malformed_reasons: acknowledgement.malformed_reasons,
      unsupported_reasons: acknowledgement.unsupported_reasons,
      manual_attention_reasons: acknowledgement.manual_attention_reasons
    }
  end

  defp first_reason(project) do
    case project.blocking_reasons do
      [reason | _rest] -> reason
      [] -> %{code: "cutover_gate_blocked", source: "cutover_gate"}
    end
  end

  defp reason_message(reason, operation) do
    code = optional_string(reason, :code) || "cutover_gate_blocked"
    "Cutover gate blocked #{operation}: #{code}"
  end

  defp reason_sources(project) do
    project.blocking_reasons
    |> Enum.map(&optional_string(&1, :source))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp project_block_reason_snapshot(project) do
    %{
      project_id: project.project_id,
      decision: project.decision,
      allowed_operations: project.allowed_operations,
      blocked_operations: project.blocked_operations,
      blocking_reasons: Enum.take(project.blocking_reasons, 5),
      required_operator_actions: project.required_operator_actions
    }
  end

  defp overall_status(projects) do
    cond do
      projects == [] -> "not_applicable"
      Enum.any?(projects, &(&1.decision == "manual_attention")) -> "manual_attention"
      Enum.any?(projects, &(&1.decision == "blocked")) -> "blocked"
      Enum.any?(projects, &(&1.decision == "staged_ready")) -> "staged_ready"
      Enum.any?(projects, &(&1.decision == "allowed")) -> "allowed"
      true -> "not_applicable"
    end
  end

  defp normalize_overall_status(status, projects) do
    normalized = safe_status(status)
    if normalized in @decisions, do: normalized, else: overall_status(projects)
  end

  defp normalize_decision(decision, migration_state, allowed, blocked) do
    normalized = safe_status(decision)

    cond do
      normalized in @decisions -> normalized
      migration_state == "legacy_only" -> "not_applicable"
      allowed == [] and blocked == [] -> "not_applicable"
      allowed == [] -> "blocked"
      blocked == [] -> "allowed"
      true -> "staged_ready"
    end
  end

  defp count_snapshot(counts, projects) when is_map(counts) do
    decisions = Map.new(@decisions, &{String.to_atom(&1), 0})

    decision_counts =
      Enum.reduce(projects, decisions, fn project, acc ->
        decision =
          normalize_decision(
            value(project, :decision),
            normalize_migration_state(value(project, :migration_state)),
            value(project, :allowed_operations) || [],
            value(project, :blocked_operations) || []
          )

        key = String.to_existing_atom(decision)
        Map.update!(acc, key, &(&1 + 1))
      end)

    %{
      project_count: non_negative_integer(value(counts, :project_count)) || length(projects),
      decisions: decision_counts,
      allowed_count: decision_counts.allowed,
      staged_ready_count: decision_counts.staged_ready,
      blocked_count: decision_counts.blocked,
      manual_attention_count: decision_counts.manual_attention,
      not_applicable_count: decision_counts.not_applicable,
      staged_ownership_record_count: length(staged_records(projects))
    }
  end

  defp count_snapshot(_counts, projects), do: count_snapshot(%{}, projects)

  defp runtime_summary(sources, overview, migration_readiness) do
    runtime =
      [
        value(sources, :hub_runtime),
        value(sources, :runtime),
        value(overview, :hub_runtime),
        value(migration_readiness, :hub_runtime)
      ]
      |> Enum.find(%{}, &(is_map(&1) and map_size(&1) > 0))

    scheduler = map_value(overview, :scheduler)

    runtime
    |> Map.put_new(:scheduler_enabled, value(scheduler, :enabled))
    |> Map.put_new(:scheduler_status, value(scheduler, :status))
  end

  defp index_projects(projects) when is_list(projects) do
    projects
    |> Enum.filter(&is_map/1)
    |> Map.new(&{required_string(&1, :project_id), &1})
  end

  defp index_projects(_projects), do: %{}

  defp provider_snapshot(provider) when is_map(provider) do
    %{
      kind: optional_string(provider, :kind) || optional_string(provider, :provider_kind),
      provider_scope_key: optional_string(provider, :provider_scope_key),
      scope:
        SafeSummary.sanitize_map(
          value(provider, :scope) || value(provider, :provider_scope) || %{},
          output_keys: :preserve
        )
    }
  end

  defp provider_snapshot(_provider), do: provider_snapshot(%{})

  defp normalize_migration_state(value) do
    case safe_status(value) do
      "legacy_only" -> "legacy_only"
      "legacy-only" -> "legacy_only"
      "hub_managed" -> "hub_managed"
      "hub-managed" -> "hub_managed"
      "hub_ready" -> "hub_ready"
      "hub-ready" -> "hub_ready"
      _other -> "hub_ready"
    end
  end

  defp normalize_readiness_decision(value) do
    case safe_status(value) do
      "legacy_only" -> "legacy_only"
      "ready_for_dry_run" -> "ready_for_dry_run"
      "ready_for_hub_management" -> "ready_for_hub_management"
      "already_hub_managed" -> "already_hub_managed"
      "blocked" -> "blocked"
      "unknown_manual_attention" -> "unknown_manual_attention"
      "manual_attention" -> "unknown_manual_attention"
      _other -> "unknown_manual_attention"
    end
  end

  defp operation_name(operation) do
    case safe_status(operation) do
      "candidate_scan" -> "poll"
      "poll" -> "poll"
      "dispatch" -> "dispatch"
      "worker_start" -> "worker_start"
      "writeback" -> "writeback"
      other -> other
    end
  end

  defp operation_list(value) when is_list(value) do
    value
    |> Enum.map(&operation_name/1)
    |> Enum.filter(&(&1 in @operations))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp operation_list(_value), do: []

  defp safe_list(value) when is_list(value), do: Enum.map(value, &SafeSummary.sanitize_value(&1, output_keys: :preserve))
  defp safe_list(_value), do: []

  defp string_list(value) when is_list(value) do
    value
    |> Enum.map(&optional_string/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp string_list(_value), do: []

  defp map_value(map, key) do
    case value(map, key) do
      value when is_map(value) -> value
      _value -> %{}
    end
  end

  defp list_value(map, key) do
    case value(map, key) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  defp get_in_map(map, keys) do
    Enum.reduce_while(keys, map, fn key, current ->
      case value(current, key) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
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

  defp truthy?(value), do: value in [true, "true", 1, "1", "yes", "enabled"]

  defp required_string(map, key) when is_map(map), do: optional_string(map, key) || "unknown"
  defp required_string(_map, _key), do: "unknown"

  defp optional_string(map, key) when is_map(map), do: optional_string(value(map, key))
  defp optional_string(value, _key), do: optional_string(value)
  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(value), do: to_string(value)

  defp safe_status(value) do
    value
    |> optional_string()
    |> case do
      nil -> ""
      string -> string |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")
    end
  end

  defp blank?(value), do: is_nil(value) or value == ""
  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  defp label_for(value) do
    value
    |> safe_status()
    |> String.replace("_", " ")
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      {:error, _reason} -> optional_string(value)
    end
  end

  defp iso8601(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _parse -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _parse -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp fingerprint(payload) do
    :crypto.hash(:sha256, :erlang.term_to_binary(payload))
    |> Base.encode16(case: :lower)
  end
end
