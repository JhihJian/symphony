defmodule SymphonyElixir.Hub.CutoverReadinessPermit do
  @moduledoc """
  Read-only Hub cutover execution readiness permit model.

  The permit is a stable go/no-go summary for a requested Hub-owned operation.
  It only consumes already-safe Hub snapshots: cutover request dry-run audit,
  audit history/closeout, activation plan acknowledgement, cutover gate, and
  executor/starter modes. It does not call providers, scan candidates, dispatch
  work, start workers, mutate the runtime ledger, write providers, operate
  systemd, or edit Hub/project configuration.
  """

  alias SymphonyElixir.Hub.{CutoverAuditHistory, CutoverGate, CutoverOperationAudit, SafeSummary}

  @version 1
  @operations ["poll", "dispatch", "worker_start", "writeback"]
  @decisions [
    "no_request",
    "ready_for_execution_consideration",
    "blocked",
    "stale",
    "manual_attention",
    "unsupported",
    "malformed",
    "summary_error"
  ]
  @permit_decisions [
    "ready_for_execution_consideration",
    "blocked",
    "stale",
    "manual_attention",
    "unsupported",
    "malformed"
  ]
  @stale_history_statuses ["stale", "conflict"]
  @malformed_history_statuses ["malformed", "summary_error"]
  @unsupported_history_statuses ["unsupported"]
  @manual_history_statuses ["unresolved_manual_attention", "deferred"]
  @mode_incompatible_actions %{
    "poll" => "enable_real_candidate_scan_executor",
    "worker_start" => "enable_real_worker_starter",
    "writeback" => "enable_real_writeback_executor"
  }

  @type summary :: map()
  @type permit :: map()

  @spec build(term(), keyword()) :: summary()
  def build(sources, opts \\ []) when is_list(opts) do
    now =
      opts
      |> Keyword.get(:now)
      |> Kernel.||(value(sources, :generated_at))
      |> Kernel.||(DateTime.utc_now())
      |> iso8601()

    audit = CutoverOperationAudit.to_snapshot(value(sources, :cutover_operation_audit) || %{})

    history =
      case value(sources, :cutover_audit_history) || value(sources, :audit_history) do
        history when is_map(history) and map_size(history) > 0 ->
          CutoverAuditHistory.to_snapshot(history)

        _history ->
          CutoverAuditHistory.build(%{generated_at: now, cutover_operation_audit: audit}, now: now)
      end

    context = %{
      generated_at: now,
      evaluated_at: now,
      projects_by_id: index_projects(value(sources, :projects)),
      activation_plan_by_project: index_projects(value(sources, :activation_plan)),
      cutover_gate: CutoverGate.to_snapshot(value(sources, :cutover_gate)),
      audit_by_project: index_projects(audit),
      history_by_project: index_projects(history),
      runtime: runtime_snapshot(sources)
    }

    project_ids =
      [audit, history, context.cutover_gate, value(sources, :projects)]
      |> Enum.flat_map(&project_ids_from/1)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.sort()

    projects =
      project_ids
      |> Enum.map(&safe_project_permit(&1, context))
      |> Enum.sort_by(& &1.project_id)

    %{
      version: @version,
      generated_at: now,
      evaluated_at: now,
      status: overall_status(projects),
      operation_set: @operations,
      dry_run_only: true,
      no_side_effects: true,
      counts: count_snapshot(%{}, projects),
      projects: projects
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

    generated_at = iso8601(value(summary, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      version: positive_integer(value(summary, :version)) || @version,
      generated_at: generated_at,
      evaluated_at: iso8601(value(summary, :evaluated_at)) || generated_at,
      status: normalize_overall_status(value(summary, :status), projects),
      operation_set: operation_list(value(summary, :operation_set)) |> default_operations(),
      dry_run_only: value(summary, :dry_run_only) != false,
      no_side_effects: value(summary, :no_side_effects) != false,
      counts: count_snapshot(value(summary, :counts), projects),
      projects: projects
    }
  end

  def to_snapshot(_summary), do: to_snapshot(%{})

  @spec observability_snapshot(term()) :: summary() | nil
  def observability_snapshot(nil), do: nil
  def observability_snapshot(summary) when is_map(summary), do: to_snapshot(summary)
  def observability_snapshot(_summary), do: nil

  defp safe_project_permit(project_id, context) do
    project_permit(project_id, context)
  rescue
    _error ->
      summary_error_project(project_id)
  catch
    _kind, _reason ->
      summary_error_project(project_id)
  end

  defp project_permit(project_id, context) do
    audit = Map.get(context.audit_by_project, project_id)
    history = Map.get(context.history_by_project, project_id)
    gate = CutoverGate.project(context.cutover_gate, project_id)
    plan = Map.get(context.activation_plan_by_project, project_id)
    project = Map.get(context.projects_by_id, project_id)

    permits =
      audit
      |> audit_operation_results()
      |> Enum.map(&permit_snapshot(project_id, &1, audit, history, gate, plan, project, context))
      |> Enum.sort_by(& &1.operation)

    status = project_status(audit, history, permits)

    %{
      version: @version,
      project_id: project_id,
      status: status,
      request: audit_request(audit),
      provider_scope: provider_scope(audit, history, project),
      requested_operations: requested_operations(audit),
      permits: permits,
      reason_codes: project_reason_codes(audit, history, permits),
      required_operator_actions: project_actions(audit, history, permits),
      safe_evidence: project_safe_evidence(audit, history, gate, plan, project, context.runtime),
      dry_run_only: true,
      no_side_effects: true
    }
    |> project_snapshot()
  end

  defp permit_snapshot(project_id, operation_result, audit, history, gate, plan, project, context) do
    operation = operation_name(value(operation_result, :operation))
    request = audit_request(audit)
    audit_decision = safe_status(value(operation_result, :decision))
    mode = mode_for_operation(operation, context.runtime)

    evidence =
      permit_evidence(
        project_id,
        operation,
        request,
        operation_result,
        audit,
        history,
        gate,
        plan,
        project,
        context.runtime
      )

    validation = permit_validation(operation, audit_decision, audit, history, gate, plan, request, mode, evidence)
    decision = permit_decision(validation)
    reason_codes = validation |> Enum.map(& &1.code) |> Enum.uniq() |> Enum.sort()
    actions = validation |> Enum.flat_map(& &1.actions) |> Enum.reject(&blank?/1) |> Enum.uniq() |> Enum.sort()

    snapshot = %{
      version: @version,
      project_id: project_id,
      operation: operation,
      decision: decision,
      reason_codes: reason_codes,
      required_operator_actions: action_snapshots(actions),
      request: request_binding(request),
      provider_scope: provider_scope(audit, history, project),
      activation_plan: plan_binding(plan, request),
      operator_acknowledgement: acknowledgement_binding(plan),
      cutover_gate: gate_binding(gate, request),
      dry_run_audit: dry_run_binding(audit, operation_result),
      audit_history: history_binding(history, operation, request),
      executor_modes: mode,
      evidence_fingerprints: evidence_fingerprints(evidence),
      source: optional_string(request || %{}, :source) || "current_dry_run_audit",
      generated_at: context.generated_at,
      evaluated_at: context.evaluated_at,
      expires_at: nil,
      stale: decision == "stale",
      stale_reasons: if(decision == "stale", do: reason_codes, else: []),
      safe_evidence: evidence,
      permit_fingerprint: nil,
      dry_run_only: true,
      no_side_effects: true
    }

    %{snapshot | permit_fingerprint: permit_fingerprint(snapshot)}
    |> operation_permit_snapshot()
  end

  defp permit_validation(operation, audit_decision, audit, history, gate, plan, request, mode, evidence) do
    []
    |> add_validation(operation not in @operations, "unknown_operation", "choose_supported_operations", "unsupported")
    |> add_validation(audit == nil or value(audit, :request) == nil, "cutover_operation_request_missing", "submit_cutover_operation_request", "blocked")
    |> add_validation(request_missing_fingerprint?(request), "operation_request_fingerprint_missing", "refresh_cutover_operation_request", "malformed")
    |> add_validation(plan_missing?(plan, request), "activation_plan_missing", "refresh_activation_plan", "blocked")
    |> add_validation(acknowledgement_not_accepted?(plan), "activation_acknowledgement_not_accepted", "accept_activation_plan", "blocked")
    |> add_validation(gate == nil, "cutover_gate_missing", "refresh_cutover_gate", "blocked")
    |> add_validation(gate_mismatch?(gate, request), "cutover_gate_evidence_mismatch", "refresh_cutover_operation_request", "stale")
    |> add_validation(not gate_allows_operation?(gate, operation), "cutover_gate_blocked", "refresh_cutover_gate", gate_block_level(gate))
    |> add_validation(audit_decision == "unsupported", "dry_run_audit_unsupported", "choose_supported_operations", "unsupported")
    |> add_validation(audit_decision == "manual_attention", "dry_run_audit_manual_attention", "resolve_manual_attention", "manual_attention")
    |> add_validation(audit_decision not in ["would_allow", "manual_attention", "unsupported"], "dry_run_audit_blocked", "refresh_cutover_operation_request", "blocked")
    |> add_validation(history == nil, "cutover_audit_history_missing", "refresh_cutover_audit_history", "stale")
    |> add_history_status_validation(history)
    |> add_validation(history_request_stale?(history, request), "audit_history_request_fingerprint_mismatch", "refresh_cutover_audit_history", "stale")
    |> add_validation(history_operation_missing?(history, operation), "audit_history_operation_missing", "refresh_cutover_audit_history", "stale")
    |> add_validation(unresolved_attention?(history, operation, request), "manual_attention_unresolved", "closeout_manual_attention", "manual_attention")
    |> add_validation(not mode_allows_operation?(operation, mode), "executor_starter_mode_incompatible", action_for_mode(operation), "blocked")
    |> add_validation(evidence_drift?(evidence, request, gate, plan), "evidence_fingerprint_drift", "refresh_cutover_operation_request", "stale")
  end

  defp add_history_status_validation(reasons, nil), do: reasons

  defp add_history_status_validation(reasons, history) do
    status = safe_status(value(history, :status))

    cond do
      status in @malformed_history_statuses ->
        add_validation(reasons, true, "cutover_audit_history_malformed", "fix_cutover_audit_history", "malformed")

      status in @unsupported_history_statuses ->
        add_validation(reasons, true, "cutover_audit_history_unsupported", "fix_cutover_audit_history", "unsupported")

      status in @stale_history_statuses ->
        add_validation(reasons, true, "cutover_audit_history_#{status}", "refresh_cutover_audit_history", "stale")

      status in @manual_history_statuses ->
        add_validation(reasons, true, "cutover_audit_history_#{status}", "closeout_manual_attention", "manual_attention")

      true ->
        reasons
    end
  end

  defp add_validation(reasons, true, code, action, level) do
    [%{code: code, actions: [action], level: level} | reasons]
  end

  defp add_validation(reasons, _condition, _code, _action, _level), do: reasons

  defp permit_decision(validation) do
    cond do
      Enum.any?(validation, &(&1.level == "malformed")) -> "malformed"
      Enum.any?(validation, &(&1.level == "unsupported")) -> "unsupported"
      Enum.any?(validation, &(&1.level == "stale")) -> "stale"
      Enum.any?(validation, &(&1.level == "manual_attention")) -> "manual_attention"
      validation != [] -> "blocked"
      true -> "ready_for_execution_consideration"
    end
  end

  defp gate_block_level(nil), do: "blocked"
  defp gate_block_level(gate), do: if(safe_status(value(gate, :decision)) == "manual_attention", do: "manual_attention", else: "blocked")

  defp request_missing_fingerprint?(nil), do: true
  defp request_missing_fingerprint?(request), do: blank?(optional_string(request, :request_fingerprint))

  defp plan_missing?(nil, _request), do: true

  defp plan_missing?(plan, request) do
    plan_id = optional_string(plan, :plan_id)
    request_plan = value(request || %{}, :activation_plan) || %{}
    request_plan_id = optional_string(request_plan, :plan_id)
    request_fingerprint = optional_string(request_plan, :fingerprint)

    blank?(plan_id) or
      (not blank?(request_plan_id) and request_plan_id != plan_id) or
      (not blank?(request_fingerprint) and request_fingerprint != plan_fingerprint(plan))
  end

  defp acknowledgement_not_accepted?(plan) do
    acknowledgement = value(plan || %{}, :operator_acknowledgement) || %{}
    safe_status(value(acknowledgement, :status)) != "accepted" or value(acknowledgement, :plan_id_matches) != true
  end

  defp gate_mismatch?(nil, _request), do: false

  defp gate_mismatch?(gate, request) do
    request_gate = value(request || %{}, :cutover_gate) || %{}
    request_decision = optional_string(request_gate, :decision)
    request_fingerprint = optional_string(request_gate, :fingerprint)
    request_record_id = optional_string(request_gate, :staged_ownership_record_id)
    gate_fingerprint = gate_fingerprint(gate)
    gate_record_id = get_in_value(gate, [:staged_ownership_record, :record_id])

    cond do
      not blank?(request_decision) and request_decision != optional_string(gate, :decision) -> true
      not blank?(request_fingerprint) and request_fingerprint != gate_fingerprint -> true
      not blank?(request_record_id) and request_record_id != gate_record_id -> true
      true -> false
    end
  end

  defp gate_allows_operation?(nil, _operation), do: false

  defp gate_allows_operation?(gate, operation) do
    operation in operation_list(value(gate, :allowed_operations))
  end

  defp history_request_stale?(nil, _request), do: false

  defp history_request_stale?(history, request) do
    latest_request_fingerprint = get_in_value(history, [:latest_audit, :request_fingerprint])
    request_fingerprint = optional_string(request || %{}, :request_fingerprint)

    not blank?(request_fingerprint) and not blank?(latest_request_fingerprint) and
      latest_request_fingerprint != request_fingerprint
  end

  defp history_operation_missing?(nil, _operation), do: false

  defp history_operation_missing?(history, operation) do
    latest_operations = operation_list(get_in_value(history, [:latest_audit, :requested_operations]))

    latest_operations != [] and operation not in latest_operations
  end

  defp unresolved_attention?(nil, _operation, _request), do: false

  defp unresolved_attention?(history, operation, request) do
    request_fingerprint = optional_string(request || %{}, :request_fingerprint)

    history
    |> list_value(:unresolved_manual_attention)
    |> Enum.any?(fn item ->
      operation_name(value(item, :operation)) == operation and
        (blank?(request_fingerprint) or optional_string(item, :request_fingerprint) == request_fingerprint)
    end)
  end

  defp evidence_drift?(evidence, request, gate, plan) do
    request_gate = value(request || %{}, :cutover_gate) || %{}
    request_plan = value(request || %{}, :activation_plan) || %{}

    [
      {
        optional_string(request_gate, :fingerprint),
        get_in_value(evidence, [:cutover_gate, :fingerprint]) || gate_fingerprint(gate)
      },
      {
        optional_string(request_plan, :fingerprint),
        get_in_value(evidence, [:activation_plan, :fingerprint]) || plan_fingerprint(plan)
      }
    ]
    |> Enum.any?(fn {bound, current} -> not blank?(bound) and not blank?(current) and bound != current end)
  end

  defp mode_for_operation(operation, runtime) do
    %{
      operation: operation,
      scheduler: value(runtime, :scheduler) || %{},
      provider_executor: value(runtime, :provider_executor) || %{},
      writeback_executor: value(runtime, :writeback_executor) || %{},
      worker_starter: value(runtime, :worker_starter) || %{},
      dry_run_mode: dry_run_mode?(runtime),
      skeleton_mode: skeleton_mode?(runtime),
      unsupported_mode: not mode_allows_operation?(operation, runtime)
    }
    |> SafeSummary.sanitize_map(output_keys: :preserve)
  end

  defp mode_allows_operation?("poll", runtime) do
    provider = value(runtime, :provider_executor) || %{}
    truthy?(value(provider, :provider_io)) and "candidate_scan" in string_list(value(provider, :supported_operations))
  end

  defp mode_allows_operation?("dispatch", _runtime), do: true

  defp mode_allows_operation?("worker_start", runtime) do
    starter = value(runtime, :worker_starter) || %{}
    truthy?(value(starter, :worker_start)) and safe_status(value(starter, :mode)) == "real_worker_starter"
  end

  defp mode_allows_operation?("writeback", runtime) do
    executor = value(runtime, :writeback_executor) || value(runtime, :provider_executor) || %{}

    truthy?(value(executor, :provider_io)) and safe_status(value(executor, :mode)) == "real_writeback" and
      string_list(value(executor, :supported_operations)) != []
  end

  defp mode_allows_operation?(_operation, _runtime), do: false

  defp action_for_mode(operation), do: Map.get(@mode_incompatible_actions, operation, "confirm_hub_executor_modes")

  defp dry_run_mode?(runtime) do
    value(runtime, :read_only) == true or skeleton_mode?(runtime)
  end

  defp skeleton_mode?(runtime) do
    [value(runtime, :provider_executor), value(runtime, :writeback_executor), value(runtime, :worker_starter)]
    |> Enum.any?(fn mode ->
      mode = mode || %{}
      safe_status(value(mode, :mode)) == "skeleton" or value(mode, :provider_io) == false or value(mode, :worker_start) == false
    end)
  end

  defp project_status(audit, history, permits) do
    cond do
      permits != [] ->
        cond do
          Enum.any?(permits, &(&1.decision == "malformed")) -> "malformed"
          Enum.any?(permits, &(&1.decision == "unsupported")) -> "unsupported"
          Enum.any?(permits, &(&1.decision == "stale")) -> "stale"
          Enum.any?(permits, &(&1.decision == "manual_attention")) -> "manual_attention"
          Enum.any?(permits, &(&1.decision == "blocked")) -> "blocked"
          Enum.all?(permits, &(&1.decision == "ready_for_execution_consideration")) -> "ready_for_execution_consideration"
          true -> "blocked"
        end

      safe_status(value(audit || %{}, :status)) == "summary_error" or safe_status(value(history || %{}, :status)) == "summary_error" ->
        "summary_error"

      audit == nil or value(audit, :request) == nil ->
        "no_request"

      true ->
        "blocked"
    end
  end

  defp project_snapshot(project) when is_map(project) do
    permits =
      project
      |> list_value(:permits)
      |> Enum.map(&operation_permit_snapshot/1)
      |> Enum.sort_by(& &1.operation)

    request =
      case value(project, :request) do
        nil -> nil
        request -> request_binding(request)
      end

    %{
      version: positive_integer(value(project, :version)) || @version,
      project_id: required_string(project, :project_id),
      status: normalize_project_status(value(project, :status), request, permits),
      request: request,
      provider_scope: provider_scope_snapshot(value(project, :provider_scope) || %{}),
      requested_operations: operation_list(value(project, :requested_operations)),
      permits: permits,
      reason_codes: string_list(value(project, :reason_codes)),
      required_operator_actions: action_snapshots(value(project, :required_operator_actions)),
      safe_evidence: safe_evidence_snapshot(value(project, :safe_evidence) || %{}),
      dry_run_only: value(project, :dry_run_only) != false,
      no_side_effects: value(project, :no_side_effects) != false
    }
  end

  defp project_snapshot(_project), do: project_snapshot(%{})

  defp operation_permit_snapshot(permit) when is_map(permit) do
    decision = normalize_permit_decision(value(permit, :decision))

    snapshot = %{
      version: positive_integer(value(permit, :version)) || @version,
      project_id: required_string(permit, :project_id),
      operation: operation_name(value(permit, :operation)),
      decision: decision,
      reason_codes: string_list(value(permit, :reason_codes)),
      required_operator_actions: action_snapshots(value(permit, :required_operator_actions)),
      request: request_binding(value(permit, :request)),
      provider_scope: provider_scope_snapshot(value(permit, :provider_scope) || %{}),
      activation_plan: plan_binding(value(permit, :activation_plan), value(permit, :request)),
      operator_acknowledgement: acknowledgement_binding(value(permit, :operator_acknowledgement)),
      cutover_gate: gate_binding(value(permit, :cutover_gate), value(permit, :request)),
      dry_run_audit: dry_run_binding(value(permit, :dry_run_audit), %{}),
      audit_history:
        history_binding(
          value(permit, :audit_history),
          operation_name(value(permit, :operation)),
          value(permit, :request)
        ),
      executor_modes: SafeSummary.sanitize_map(value(permit, :executor_modes) || %{}, output_keys: :preserve),
      evidence_fingerprints:
        SafeSummary.sanitize_map(value(permit, :evidence_fingerprints) || %{},
          output_keys: :preserve
        ),
      source: safe_status(value(permit, :source)) |> blank_to_default("unknown"),
      generated_at: iso8601(value(permit, :generated_at)),
      evaluated_at: iso8601(value(permit, :evaluated_at)),
      expires_at: iso8601(value(permit, :expires_at)),
      stale: value(permit, :stale) == true or decision == "stale",
      stale_reasons: string_list(value(permit, :stale_reasons)),
      safe_evidence: safe_evidence_snapshot(value(permit, :safe_evidence) || %{}),
      dry_run_only: value(permit, :dry_run_only) != false,
      no_side_effects: value(permit, :no_side_effects) != false
    }

    Map.put(snapshot, :permit_fingerprint, optional_string(permit, :permit_fingerprint) || permit_fingerprint(snapshot))
  end

  defp operation_permit_snapshot(permit), do: operation_permit_snapshot(%{operation: permit})

  defp normalize_project_status(status, request, permits) do
    status = safe_status(status)

    cond do
      status in @decisions -> status
      request == nil -> "no_request"
      permits == [] -> "blocked"
      true -> project_status(%{request: request}, %{}, permits)
    end
  end

  defp normalize_permit_decision(decision) do
    decision = safe_status(decision)
    if decision in @permit_decisions, do: decision, else: "blocked"
  end

  defp overall_status(projects) do
    active = Enum.reject(projects, &(&1.status == "no_request"))

    cond do
      active == [] -> "no_request"
      Enum.any?(active, &(&1.status == "summary_error")) -> "summary_error"
      Enum.any?(active, &(&1.status == "malformed")) -> "malformed"
      Enum.any?(active, &(&1.status == "unsupported")) -> "unsupported"
      Enum.any?(active, &(&1.status == "stale")) -> "stale"
      Enum.any?(active, &(&1.status == "manual_attention")) -> "manual_attention"
      Enum.any?(active, &(&1.status == "blocked")) -> "blocked"
      Enum.any?(active, &(&1.status == "ready_for_execution_consideration")) -> "ready_for_execution_consideration"
      true -> "no_request"
    end
  end

  defp normalize_overall_status(status, projects) do
    status = safe_status(status)
    if status in @decisions, do: status, else: overall_status(projects)
  end

  defp count_snapshot(counts, projects) when is_map(counts) do
    permits = Enum.flat_map(projects, &list_value(&1, :permits))

    %{
      project_count: non_negative_integer(value(counts, :project_count)) || length(projects),
      permit_count: non_negative_integer(value(counts, :permit_count)) || length(permits),
      no_request_count: non_negative_integer(value(counts, :no_request_count)) || Enum.count(projects, &(&1.status == "no_request")),
      ready_count:
        non_negative_integer(value(counts, :ready_count)) ||
          Enum.count(permits, &(&1.decision == "ready_for_execution_consideration")),
      blocked_count: non_negative_integer(value(counts, :blocked_count)) || Enum.count(permits, &(&1.decision == "blocked")),
      stale_count: non_negative_integer(value(counts, :stale_count)) || Enum.count(permits, &(&1.decision == "stale")),
      manual_attention_count:
        non_negative_integer(value(counts, :manual_attention_count)) ||
          Enum.count(permits, &(&1.decision == "manual_attention")),
      unsupported_count: non_negative_integer(value(counts, :unsupported_count)) || Enum.count(permits, &(&1.decision == "unsupported")),
      malformed_count: non_negative_integer(value(counts, :malformed_count)) || Enum.count(permits, &(&1.decision == "malformed")),
      summary_error_count: non_negative_integer(value(counts, :summary_error_count)) || Enum.count(projects, &(&1.status == "summary_error")),
      operation_decision_counts:
        value(counts, :operation_decision_counts) ||
          operation_decision_counts(permits)
    }
  end

  defp count_snapshot(_counts, projects), do: count_snapshot(%{}, projects)

  defp operation_decision_counts(permits) do
    base = Map.new(@permit_decisions, &{String.to_atom(&1), 0})

    Enum.reduce(permits, base, fn permit, acc ->
      key =
        permit
        |> value(:decision)
        |> normalize_permit_decision()
        |> String.to_atom()

      Map.update!(acc, key, &(&1 + 1))
    end)
  end

  defp audit_operation_results(nil), do: []
  defp audit_operation_results(audit), do: list_value(audit, :operation_results)

  defp audit_request(nil), do: nil
  defp audit_request(audit), do: value(audit, :request)

  defp requested_operations(nil), do: []
  defp requested_operations(audit), do: operation_list(value(audit, :requested_operations))

  defp project_reason_codes(audit, history, permits) do
    (string_list(value(audit || %{}, :reason_codes)) ++
       string_list(get_in_value(history || %{}, [:latest_audit, :reason_codes])) ++
       Enum.flat_map(permits, &string_list(value(&1, :reason_codes))))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp project_actions(audit, history, permits) do
    (action_codes(value(audit || %{}, :required_operator_actions)) ++
       action_codes(get_in_value(history || %{}, [:latest_audit, :required_operator_actions])) ++
       Enum.flat_map(permits, &action_codes(value(&1, :required_operator_actions))))
    |> Enum.uniq()
    |> Enum.sort()
    |> action_snapshots()
  end

  defp project_safe_evidence(audit, history, gate, plan, project, runtime) do
    %{
      request: request_binding(audit_request(audit)),
      activation_plan: plan_binding(plan, audit_request(audit)),
      cutover_gate: gate_binding(gate, audit_request(audit)),
      dry_run_audit: dry_run_binding(audit, nil),
      audit_history: history_binding(history, nil, audit_request(audit)),
      project: project_binding(project),
      runtime_modes: runtime,
      dry_run_only: true,
      no_side_effects: true
    }
    |> safe_evidence_snapshot()
  end

  defp permit_evidence(project_id, operation, request, operation_result, audit, history, gate, plan, project, runtime) do
    %{
      project: project_binding(project) |> Map.put(:project_id, project_id),
      request: request_binding(request),
      activation_plan: plan_binding(plan, request),
      operator_acknowledgement: acknowledgement_binding(plan),
      cutover_gate: gate_binding(gate, request),
      dry_run_audit: dry_run_binding(audit, operation_result),
      audit_history: history_binding(history, operation, request),
      executor_modes: mode_for_operation(operation, runtime),
      dry_run_only: true,
      no_side_effects: true
    }
    |> safe_evidence_snapshot()
  end

  defp evidence_fingerprints(evidence) do
    %{
      request: fingerprint(value(evidence, :request) || %{}),
      activation_plan:
        get_in_value(evidence, [:activation_plan, :fingerprint]) ||
          fingerprint(value(evidence, :activation_plan) || %{}),
      operator_acknowledgement: fingerprint(value(evidence, :operator_acknowledgement) || %{}),
      cutover_gate:
        get_in_value(evidence, [:cutover_gate, :fingerprint]) ||
          fingerprint(value(evidence, :cutover_gate) || %{}),
      dry_run_audit: fingerprint(value(evidence, :dry_run_audit) || %{}),
      audit_history: fingerprint(value(evidence, :audit_history) || %{}),
      runtime_modes: fingerprint(value(evidence, :executor_modes) || %{}),
      permit_input: fingerprint(Map.drop(evidence, [:dry_run_only, :no_side_effects]))
    }
  end

  defp request_binding(nil), do: nil

  defp request_binding(request) when is_map(request) do
    %{
      request_id: optional_string(request, :request_id),
      request_fingerprint: optional_string(request, :request_fingerprint),
      project_id: optional_string(request, :project_id),
      requested_operations: operation_list(value(request, :requested_operations)),
      source: safe_status(value(request, :source)) |> blank_to_default("unknown"),
      requested_at: iso8601(value(request, :requested_at))
    }
    |> compact_map()
  end

  defp request_binding(_request), do: nil

  defp plan_binding(nil, request) do
    request_plan = value(request || %{}, :activation_plan) || %{}

    %{
      plan_id: optional_string(request_plan, :plan_id),
      fingerprint: optional_string(request_plan, :fingerprint),
      status: "missing"
    }
    |> compact_map()
  end

  defp plan_binding(plan, request) when is_map(plan) do
    request_plan = value(request || %{}, :activation_plan) || %{}

    %{
      plan_id: optional_string(plan, :plan_id) || optional_string(request_plan, :plan_id),
      fingerprint: plan_fingerprint(plan) || optional_string(request_plan, :fingerprint),
      status: safe_status(value(plan, :status)),
      readiness_decision: safe_status(value(plan, :readiness_decision)),
      proposed_next_state: safe_status(value(plan, :proposed_next_state))
    }
    |> compact_map()
  end

  defp plan_binding(_plan, request), do: plan_binding(nil, request)

  defp acknowledgement_binding(plan) when is_map(plan) do
    acknowledgement = value(plan, :operator_acknowledgement) || plan

    %{
      status: safe_status(value(acknowledgement, :status)) |> blank_to_default("missing"),
      project_id: optional_string(acknowledgement, :project_id),
      plan_id: optional_string(acknowledgement, :plan_id),
      plan_id_matches: value(acknowledgement, :plan_id_matches) == true,
      source: safe_status(value(acknowledgement, :source)),
      created_at: iso8601(value(acknowledgement, :created_at)),
      fingerprint:
        fingerprint(%{
          status: safe_status(value(acknowledgement, :status)),
          project_id: optional_string(acknowledgement, :project_id),
          plan_id: optional_string(acknowledgement, :plan_id),
          plan_id_matches: value(acknowledgement, :plan_id_matches) == true,
          acknowledged_action_codes: string_list(value(acknowledgement, :acknowledged_action_codes))
        })
    }
    |> compact_map()
  end

  defp acknowledgement_binding(_plan), do: %{status: "missing", plan_id_matches: false, fingerprint: fingerprint(%{status: "missing"})}

  defp gate_binding(nil, request) do
    request_gate = value(request || %{}, :cutover_gate) || %{}

    %{
      decision: optional_string(request_gate, :decision),
      fingerprint: optional_string(request_gate, :fingerprint),
      staged_ownership_record_id: optional_string(request_gate, :staged_ownership_record_id),
      allowed_operations: [],
      blocked_operations: @operations
    }
    |> compact_map()
  end

  defp gate_binding(gate, request) when is_map(gate) do
    request_gate = value(request || %{}, :cutover_gate) || %{}

    %{
      decision: safe_status(value(gate, :decision)) |> blank_to_default(optional_string(request_gate, :decision)),
      fingerprint: gate_fingerprint(gate) || optional_string(request_gate, :fingerprint),
      staged_ownership_record_id:
        get_in_value(gate, [:staged_ownership_record, :record_id]) ||
          optional_string(request_gate, :staged_ownership_record_id),
      allowed_operations: operation_list(value(gate, :allowed_operations)),
      blocked_operations: operation_list(value(gate, :blocked_operations)),
      reason_codes: gate_reason_codes(gate)
    }
    |> compact_map()
  end

  defp gate_binding(_gate, request), do: gate_binding(nil, request)

  defp dry_run_binding(nil, _operation_result), do: %{}

  defp dry_run_binding(audit, operation_result) when is_map(audit) and is_map(operation_result) and map_size(operation_result) == 0 do
    %{
      status: safe_status(value(audit, :status)),
      request_fingerprint: optional_string(audit, :request_fingerprint),
      requested_operations: operation_list(value(audit, :requested_operations)),
      operation: operation_name(value(audit, :operation)),
      operation_decision: safe_status(value(audit, :operation_decision)),
      reason_codes: string_list(value(audit, :reason_codes)),
      required_operator_actions: action_snapshots(value(audit, :required_operator_actions)),
      dry_run_only: value(audit, :dry_run_only) != false,
      operation_evidence_fingerprint: optional_string(audit, :operation_evidence_fingerprint)
    }
    |> compact_map()
  end

  defp dry_run_binding(audit, nil) when is_map(audit) do
    %{
      status: safe_status(value(audit, :status)),
      request_fingerprint: get_in_value(audit, [:request, :request_fingerprint]),
      requested_operations: operation_list(value(audit, :requested_operations)),
      reason_codes: string_list(value(audit, :reason_codes)),
      dry_run_only: value(audit, :dry_run_only) != false
    }
    |> compact_map()
  end

  defp dry_run_binding(audit, operation_result) when is_map(operation_result) do
    %{
      status: safe_status(value(audit || %{}, :status)),
      request_fingerprint: get_in_value(audit || %{}, [:request, :request_fingerprint]),
      operation: operation_name(value(operation_result, :operation)),
      operation_decision: safe_status(value(operation_result, :decision)),
      reason_codes: string_list(value(operation_result, :reason_codes)),
      required_operator_actions: action_snapshots(value(operation_result, :required_operator_actions)),
      dry_run_only: value(operation_result, :dry_run_only) != false,
      operation_evidence_fingerprint:
        operation_result
        |> value(:safe_evidence)
        |> Kernel.||(%{})
        |> safe_evidence_snapshot()
        |> fingerprint()
    }
    |> compact_map()
  end

  defp dry_run_binding(audit, _operation_result), do: dry_run_binding(audit, nil)

  defp history_binding(nil, _operation, _request), do: %{}

  defp history_binding(history, operation, request) when is_map(history) do
    request_fingerprint = optional_string(request || %{}, :request_fingerprint)

    unresolved =
      history
      |> list_value(:unresolved_manual_attention)
      |> Enum.filter(fn item ->
        operation in [nil, operation_name(value(item, :operation))] and
          (blank?(request_fingerprint) or optional_string(item, :request_fingerprint) == request_fingerprint)
      end)
      |> Enum.map(&attention_item_binding/1)

    %{
      status: safe_status(value(history, :status)),
      latest_entry_id: get_in_value(history, [:latest_audit, :entry_id]),
      latest_request_fingerprint: get_in_value(history, [:latest_audit, :request_fingerprint]),
      latest_evaluated_at: get_in_value(history, [:latest_audit, :evaluated_at]),
      unresolved_manual_attention_count: length(unresolved),
      unresolved_manual_attention: unresolved,
      closeout_statuses:
        history
        |> list_value(:closeouts)
        |> Enum.map(&safe_status(value(&1, :status)))
        |> Enum.reject(&blank?/1)
        |> Enum.uniq()
        |> Enum.sort(),
      counts: SafeSummary.sanitize_map(value(history, :counts) || %{}, output_keys: :preserve),
      dry_run_only: value(history, :dry_run_only) != false,
      no_side_effects: value(history, :no_side_effects) != false
    }
    |> compact_map()
  end

  defp history_binding(_history, _operation, _request), do: %{}

  defp attention_item_binding(item) when is_map(item) do
    %{
      item_id: optional_string(item, :item_id),
      operation: operation_name(value(item, :operation)),
      operation_decision: safe_status(value(item, :operation_decision)),
      reason_code: safe_status(value(item, :reason_code)),
      required_operator_action_code: safe_status(value(item, :required_operator_action_code)),
      request_fingerprint: optional_string(item, :request_fingerprint),
      activation_plan_fingerprint: optional_string(item, :activation_plan_fingerprint),
      cutover_gate_fingerprint: optional_string(item, :cutover_gate_fingerprint),
      evidence_fingerprint: optional_string(item, :evidence_fingerprint)
    }
    |> compact_map()
  end

  defp attention_item_binding(_item), do: %{}

  defp provider_scope(audit, history, project) do
    request = audit_request(audit)

    cond do
      is_map(request) and is_map(value(request, :provider_scope)) ->
        provider_scope_snapshot(value(request, :provider_scope))

      is_map(history) and is_map(value(history, :provider_scope)) ->
        provider_scope_snapshot(value(history, :provider_scope))

      true ->
        provider_scope_snapshot(
          value(project || %{}, :provider) ||
            get_in_value(project || %{}, [:detail, :identity]) ||
            %{}
        )
    end
  end

  defp provider_scope_snapshot(scope) when is_map(scope) do
    %{
      kind: optional_string(scope, :kind) || optional_string(scope, :provider_kind),
      provider_scope_key: optional_string(scope, :provider_scope_key) || optional_string(scope, :key),
      scope:
        SafeSummary.sanitize_map(value(scope, :scope) || value(scope, :provider_scope) || %{},
          output_keys: :preserve
        )
    }
    |> compact_map()
  end

  defp provider_scope_snapshot(_scope), do: %{}

  defp project_binding(project) when is_map(project) do
    %{
      project_id: optional_string(project, :project_id),
      migration_state: safe_status(value(project, :migration_state)),
      status: safe_status(value(project, :status)),
      provider_scope_key:
        get_in_value(project, [:provider, :provider_scope_key]) ||
          get_in_value(project, [:detail, :identity, :provider_scope_key]),
      config_fingerprint:
        get_in_value(project, [:detail, :config, :config_fingerprint]) ||
          optional_string(project, :config_fingerprint) ||
          optional_string(project, :fingerprint)
    }
    |> compact_map()
  end

  defp project_binding(_project), do: %{}

  defp runtime_snapshot(sources) do
    runtime = value(sources, :hub_runtime) || value(sources, :runtime) || %{}
    overview = value(sources, :overview) || %{}

    %{
      scheduler: %{
        enabled:
          value(runtime, :scheduler_enabled) ||
            get_in_value(runtime, [:scheduler, :enabled]) ||
            get_in_value(overview, [:scheduler, :enabled]),
        status:
          safe_status(
            value(runtime, :scheduler_status) ||
              get_in_value(runtime, [:scheduler, :status]) ||
              get_in_value(overview, [:scheduler, :status])
          )
          |> blank_to_default("disabled")
      },
      read_only: value(runtime, :read_only) == true,
      provider_executor: SafeSummary.sanitize_map(value(runtime, :provider_executor) || %{}, output_keys: :preserve),
      writeback_executor:
        SafeSummary.sanitize_map(value(runtime, :writeback_executor) || value(runtime, :provider_executor) || %{},
          output_keys: :preserve
        ),
      worker_starter: SafeSummary.sanitize_map(value(runtime, :worker_starter) || %{}, output_keys: :preserve),
      activation_probe: SafeSummary.sanitize_map(value(runtime, :activation_probe) || %{}, output_keys: :preserve)
    }
  end

  defp project_ids_from(summary) when is_map(summary) do
    summary
    |> list_value(:projects)
    |> Enum.map(&required_string(&1, :project_id))
  end

  defp project_ids_from(projects) when is_list(projects), do: Enum.map(projects, &required_string(&1, :project_id))
  defp project_ids_from(_summary), do: []

  defp index_projects(summary) when is_map(summary), do: index_projects(list_value(summary, :projects))

  defp index_projects(projects) when is_list(projects) do
    projects
    |> Enum.filter(&is_map/1)
    |> Map.new(&{required_string(&1, :project_id), &1})
  end

  defp index_projects(_summary), do: %{}

  defp plan_fingerprint(nil), do: nil

  defp plan_fingerprint(plan) do
    optional_string(plan, :fingerprint) ||
      optional_string(plan, :plan_fingerprint) ||
      optional_string(plan, :plan_id)
  end

  defp gate_fingerprint(nil), do: nil

  defp gate_fingerprint(gate) do
    optional_string(gate, :fingerprint) ||
      get_in_value(gate, [:safe_evidence, :fingerprint]) ||
      get_in_value(gate, [:staged_ownership_record, :record_id]) ||
      fingerprint(%{
        project_id: optional_string(gate, :project_id),
        decision: safe_status(value(gate, :decision)),
        allowed_operations: operation_list(value(gate, :allowed_operations)),
        blocked_operations: operation_list(value(gate, :blocked_operations)),
        reason_codes: gate_reason_codes(gate)
      })
  end

  defp gate_reason_codes(gate) do
    gate
    |> list_value(:blocking_reasons)
    |> Enum.map(&(optional_string(&1, :code) || optional_string(&1, :reason)))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp summary_error_project(project_id) do
    project_snapshot(%{
      project_id: project_id || "",
      status: "summary_error",
      request: nil,
      requested_operations: [],
      permits: [],
      reason_codes: ["cutover_readiness_permit_summary_error"],
      required_operator_actions: action_snapshots(["inspect_summary_error"]),
      safe_evidence: %{summary_error: %{code: "cutover_readiness_permit_summary_error"}},
      dry_run_only: true,
      no_side_effects: true
    })
  end

  defp safe_evidence_snapshot(evidence) do
    evidence
    |> SafeSummary.sanitize_map(output_keys: :preserve)
    |> redact_local_evidence_paths()
  end

  defp redact_local_evidence_paths(%_struct{} = value), do: value

  defp redact_local_evidence_paths(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, sanitized ->
      normalized_key = key |> to_string() |> String.downcase()

      cond do
        path_like_key?(normalized_key) or raw_output_key?(normalized_key) ->
          sanitized

        local_absolute_path_value?(raw_value) ->
          sanitized

        true ->
          Map.put(sanitized, key, redact_local_evidence_paths(raw_value))
      end
    end)
  end

  defp redact_local_evidence_paths(value) when is_list(value) do
    value
    |> Enum.reject(&local_absolute_path_value?/1)
    |> Enum.map(&redact_local_evidence_paths/1)
  end

  defp redact_local_evidence_paths(value), do: value

  defp path_like_key?(key) do
    key in ["path", "local_path", "workspace_path", "workflow_path", "tracker_config_path"] or
      Regex.match?(~r/(^|_)(path|file_path|config_path|env_path|dir|root)$/, key)
  end

  defp raw_output_key?(key) do
    Regex.match?(~r/(^|_)(raw_)?(systemd|hook|app_server|appserver|provider)_?(output|response)$/, key) or
      key in ["stacktrace", "stack_trace", "exception"]
  end

  defp local_absolute_path_value?(value) when is_binary(value) do
    Regex.match?(~r/(^|[\s"'=:])\/(home|tmp|var\/folders|Users|root|workspaces?|data)\/[^\s"',)]+/, value)
  end

  defp local_absolute_path_value?(_value), do: false

  defp permit_fingerprint(permit) do
    permit
    |> Map.drop([:permit_fingerprint, :generated_at, :evaluated_at, :expires_at])
    |> fingerprint()
  end

  defp fingerprint(payload) do
    :crypto.hash(:sha256, :erlang.term_to_binary(payload))
    |> Base.encode16(case: :lower)
  end

  defp action_snapshots(actions) when is_list(actions) do
    actions
    |> action_codes()
    |> Enum.map(&%{code: &1, label: label_for(&1)})
    |> Enum.uniq_by(& &1.code)
    |> Enum.sort_by(& &1.code)
  end

  defp action_snapshots(_actions), do: []

  defp action_codes(actions) when is_list(actions) do
    actions
    |> Enum.map(fn
      action when is_map(action) -> optional_string(action, :code)
      action -> optional_string(action)
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.map(&safe_status/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp action_codes(_actions), do: []

  defp operation_list(value) when is_list(value) do
    value
    |> Enum.map(&operation_name/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp operation_list(_value), do: []

  defp default_operations([]), do: @operations
  defp default_operations(operations), do: operations

  defp operation_name(value) do
    case safe_status(value) do
      "candidate_scan" -> "poll"
      "worker-start" -> "worker_start"
      "provider_writeback" -> "writeback"
      other -> other
    end
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp get_in_value(map, keys), do: Enum.reduce_while(keys, map, &get_in_step/2)
  defp get_in_step(_key, nil), do: {:halt, nil}
  defp get_in_step(key, map) when is_map(map), do: {:cont, value(map, key)}
  defp get_in_step(_key, _value), do: {:halt, nil}

  defp list_value(map, key) do
    case value(map, key) do
      value when is_list(value) -> value
      _value -> []
    end
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

  defp string_list(value) when is_list(value) do
    value
    |> Enum.map(&optional_string/1)
    |> Enum.reject(&blank?/1)
    |> Enum.map(&safe_status/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp string_list(_value), do: []

  defp required_string(map, key), do: optional_string(map, key) || ""
  defp optional_string(map, key) when is_map(map), do: map |> value(key) |> optional_string()
  defp optional_string(_map, _key), do: nil
  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(_value), do: nil

  defp safe_status(value) do
    value
    |> optional_string()
    |> case do
      nil ->
        ""

      string ->
        string
        |> String.downcase()
        |> String.replace("-", "_")
        |> String.replace(~r/[^a-z0-9_:-]+/, "_")
        |> String.trim("_")
    end
  end

  defp label_for(value), do: value |> safe_status() |> String.replace("_", " ")

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

  defp truthy?(value), do: value == true or value in ["true", "1", 1]

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value
end
