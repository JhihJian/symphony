defmodule SymphonyElixir.Hub.CutoverExecutionAuthorization do
  @moduledoc """
  Read-only Hub cutover execution authorization ledger baseline.

  The ledger records an explicit operator authorization request for a single
  Hub-owned operation and binds it to the current readiness permit and safe
  cutover evidence. It produces a stable, sanitized record summary for a later
  explicit execution stage to consume. It does not call providers, scan
  candidates, dispatch work, start workers, mutate the runtime ledger, write
  providers, operate systemd, or edit Hub/project configuration.
  """

  alias SymphonyElixir.Hub.{CutoverReadinessPermit, SafeSummary}

  @version 1
  @operations ["poll", "dispatch", "worker_start", "writeback"]
  @sources ["operator_file", "operator_cli", "test", "api", "hub_startup_option"]
  @statuses [
    "no_ready_permit",
    "authorized_for_explicit_execution",
    "blocked",
    "stale",
    "manual_attention",
    "unsupported",
    "malformed",
    "summary_error"
  ]
  @record_statuses [
    "authorized_for_explicit_execution",
    "blocked",
    "stale",
    "manual_attention",
    "unsupported",
    "malformed",
    "no_ready_permit"
  ]
  @blocked_permit_decisions ["blocked"]
  @stale_permit_decisions ["stale"]
  @manual_permit_decisions ["manual_attention"]
  @unsupported_permit_decisions ["unsupported"]
  @malformed_permit_decisions ["malformed"]

  @type request :: map()
  @type summary :: map()
  @type record :: map()

  @spec build(term(), keyword()) :: summary()
  def build(sources, opts \\ []) when is_list(opts) do
    now =
      opts
      |> Keyword.get(:now)
      |> Kernel.||(value(sources, :generated_at))
      |> Kernel.||(DateTime.utc_now())
      |> iso8601()

    readiness_permit =
      sources
      |> value(:cutover_readiness_permit)
      |> Kernel.||(value(sources, :hub_cutover_readiness_permit))
      |> CutoverReadinessPermit.to_snapshot()

    requests =
      opts
      |> Keyword.get(:requests, value(sources, :cutover_execution_authorization_requests))
      |> request_list(now)

    context = %{
      generated_at: now,
      evaluated_at: now,
      readiness_permit: readiness_permit,
      permits_by_project_operation: permits_by_project_operation(readiness_permit),
      projects_by_id: index_projects(value(sources, :projects)),
      runtime: runtime_snapshot(sources)
    }

    project_ids =
      [
        project_ids_from(readiness_permit),
        Enum.map(requests, &optional_string(&1, :project_id)),
        project_ids_from(value(sources, :projects))
      ]
      |> List.flatten()
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.sort()

    projects =
      project_ids
      |> Enum.map(&safe_project_authorization(&1, requests, context))
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

  @spec request_snapshot(term()) :: request()
  def request_snapshot(request), do: request_snapshot(request, DateTime.utc_now() |> DateTime.to_iso8601())

  @spec request_snapshot(term(), String.t()) :: request()
  def request_snapshot(request, now) when is_map(request) do
    permit = value(request, :readiness_permit) || %{}
    cutover_request = value(request, :cutover_operation_request) || %{}
    activation_plan = value(request, :activation_plan) || %{}
    acknowledgement = value(request, :operator_acknowledgement) || value(request, :acknowledgement) || %{}
    cutover_gate = value(request, :cutover_gate) || %{}
    dry_run_audit = value(request, :dry_run_audit) || %{}
    audit_history = value(request, :audit_history) || %{}
    executor_modes = value(request, :executor_modes) || %{}
    evidence_fingerprints = value(request, :evidence_fingerprints) || %{}

    snapshot =
      %{
        version: positive_integer(value(request, :version)) || @version,
        authorization_request_id:
          optional_string(request, :authorization_request_id) ||
            optional_string(request, :request_id) ||
            optional_string(request, :id),
        project_id: optional_string(request, :project_id),
        provider_scope:
          provider_scope_snapshot(
            value(request, :provider_scope) ||
              value(request, :provider) ||
              %{}
          ),
        operation: operation_name(value(request, :operation) || value(request, :requested_operation)),
        source: safe_status(value(request, :source)) |> blank_to_default("unknown"),
        requested_at: iso8601(value(request, :requested_at)) || now,
        operator_intent:
          operator_intent_snapshot(
            value(request, :operator_intent) ||
              value(request, :intent) ||
              %{}
          ),
        cutover_operation_request: %{
          request_id:
            optional_string(cutover_request, :request_id) ||
              optional_string(request, :cutover_operation_request_id),
          request_fingerprint:
            optional_string(cutover_request, :request_fingerprint) ||
              optional_string(request, :cutover_operation_request_fingerprint)
        },
        readiness_permit: %{
          permit_fingerprint:
            optional_string(permit, :permit_fingerprint) ||
              optional_string(request, :readiness_permit_fingerprint) ||
              optional_string(request, :permit_fingerprint),
          decision:
            safe_status(
              value(permit, :decision) ||
                value(request, :readiness_permit_decision) ||
                value(request, :permit_decision)
            ),
          reason_codes:
            string_list(
              value(permit, :reason_codes) ||
                value(request, :readiness_permit_reason_codes) ||
                value(request, :reason_codes)
            ),
          required_operator_actions:
            action_snapshots(
              value(permit, :required_operator_actions) ||
                value(request, :readiness_permit_required_operator_actions) ||
                value(request, :required_operator_actions)
            )
        },
        activation_plan: %{
          plan_id:
            optional_string(activation_plan, :plan_id) ||
              optional_string(request, :activation_plan_id) ||
              optional_string(request, :plan_id),
          fingerprint:
            optional_string(activation_plan, :fingerprint) ||
              optional_string(request, :activation_plan_fingerprint) ||
              optional_string(request, :plan_fingerprint)
        },
        operator_acknowledgement: %{
          fingerprint:
            optional_string(acknowledgement, :fingerprint) ||
              optional_string(request, :operator_acknowledgement_fingerprint) ||
              optional_string(request, :ack_fingerprint)
        },
        cutover_gate: %{
          decision: safe_status(value(cutover_gate, :decision) || value(request, :cutover_gate_decision)),
          fingerprint:
            optional_string(cutover_gate, :fingerprint) ||
              optional_string(request, :cutover_gate_fingerprint) ||
              optional_string(request, :gate_fingerprint),
          staged_ownership_record_id:
            optional_string(cutover_gate, :staged_ownership_record_id) ||
              optional_string(request, :staged_ownership_record_id)
        },
        dry_run_audit: %{
          fingerprint:
            optional_string(dry_run_audit, :fingerprint) ||
              optional_string(request, :dry_run_audit_fingerprint),
          decision: safe_status(value(dry_run_audit, :decision) || value(request, :dry_run_audit_decision))
        },
        audit_history: %{
          fingerprint:
            optional_string(audit_history, :fingerprint) ||
              optional_string(request, :audit_history_fingerprint),
          status: safe_status(value(audit_history, :status) || value(request, :audit_history_status))
        },
        executor_modes: SafeSummary.sanitize_map(executor_modes, output_keys: :preserve),
        evidence_fingerprints: SafeSummary.sanitize_map(evidence_fingerprints, output_keys: :preserve),
        skeleton_mode: truthy?(value(request, :skeleton_mode)),
        dry_run_mode: value(request, :dry_run_mode) != false,
        unsupported_mode: truthy?(value(request, :unsupported_mode))
      }

    snapshot
    |> Map.put(:authorization_request_fingerprint, optional_string(request, :authorization_request_fingerprint) || optional_string(request, :request_fingerprint) || request_fingerprint(snapshot))
    |> compact_map()
  end

  def request_snapshot(_request, now) do
    %{
      version: @version,
      requested_at: now,
      source: "malformed",
      operation: "unknown_operation",
      operator_intent: %{},
      dry_run_mode: true,
      skeleton_mode: true,
      unsupported_mode: true,
      authorization_request_fingerprint:
        request_fingerprint(%{
          version: @version,
          requested_at: now,
          source: "malformed",
          malformed: true
        })
    }
  end

  defp safe_project_authorization(project_id, requests, context) do
    project_authorization(project_id, requests, context)
  rescue
    _error ->
      summary_error_project(project_id)
  catch
    _kind, _reason ->
      summary_error_project(project_id)
  end

  defp project_authorization(project_id, requests, context) do
    project_requests =
      requests
      |> Enum.filter(&(optional_string(&1, :project_id) == project_id))
      |> Enum.sort_by(fn request ->
        optional_string(request, :authorization_request_id) ||
          optional_string(request, :authorization_request_fingerprint) ||
          ""
      end)

    records =
      project_requests
      |> Enum.map(&record_snapshot(project_id, &1, context))
      |> Enum.sort_by(&{&1.operation, &1.authorization_request.authorization_request_fingerprint || ""})

    project_permits =
      context.readiness_permit
      |> list_value(:projects)
      |> Enum.find(&(required_string(&1, :project_id) == project_id))

    %{
      version: @version,
      project_id: project_id,
      status: project_status(records, project_permits),
      authorization_request_count: length(project_requests),
      provider_scope: provider_scope(project_requests, project_permits, Map.get(context.projects_by_id, project_id)),
      requested_operations: operation_list(Enum.map(project_requests, &value(&1, :operation))),
      records: records,
      reason_codes: project_reason_codes(records, project_permits),
      required_operator_actions: project_actions(records, project_permits),
      safe_evidence: project_safe_evidence(project_requests, project_permits, Map.get(context.projects_by_id, project_id), context.runtime),
      dry_run_only: true,
      no_side_effects: true
    }
    |> project_snapshot()
  end

  defp record_snapshot(project_id, request, context) do
    operation = operation_name(value(request, :operation))
    permit = Map.get(context.permits_by_project_operation, {project_id, operation})
    evidence = record_evidence(project_id, request, permit, context)
    validation = record_validation(project_id, operation, request, permit, evidence, context)
    status = record_status(validation)
    reason_codes = validation |> Enum.map(& &1.code) |> Enum.uniq() |> Enum.sort()
    actions = validation |> Enum.flat_map(& &1.actions) |> Enum.reject(&blank?/1) |> Enum.uniq() |> Enum.sort()

    snapshot = %{
      version: @version,
      project_id: project_id,
      operation: operation,
      status: status,
      reason_codes: reason_codes,
      required_operator_actions: action_snapshots(actions),
      authorization_request: request_binding(request),
      provider_scope: provider_scope_snapshot(value(request, :provider_scope) || %{}),
      cutover_operation_request: cutover_request_binding(request, permit),
      readiness_permit: permit_binding(permit, request),
      activation_plan: activation_plan_binding(permit, request),
      operator_acknowledgement: acknowledgement_binding(permit, request),
      cutover_gate: gate_binding(permit, request),
      dry_run_audit: dry_run_binding(permit, request),
      audit_history: history_binding(permit, request),
      executor_modes: executor_modes_binding(permit, request),
      evidence_fingerprints: evidence_fingerprints(evidence),
      source: optional_string(request, :source) || "unknown",
      requested_at: iso8601(value(request, :requested_at)),
      evaluated_at: context.evaluated_at,
      stale: status == "stale",
      stale_reasons: if(status == "stale", do: reason_codes, else: []),
      safe_evidence: evidence,
      authorization_record_fingerprint: nil,
      dry_run_only: true,
      no_side_effects: true
    }

    %{snapshot | authorization_record_fingerprint: record_fingerprint(snapshot)}
    |> operation_record_snapshot()
  end

  defp record_validation(project_id, operation, request, permit, evidence, context) do
    permit_decision = safe_status(value(permit || %{}, :decision))

    []
    |> add_validation(optional_string(request, :project_id) in [nil, ""], "project_id_missing", "fix_authorization_request_project_id", "malformed")
    |> add_validation(blank?(project_id), "project_id_missing", "fix_authorization_request_project_id", "malformed")
    |> add_validation(operation not in @operations, "unknown_operation", "choose_supported_operations", "unsupported")
    |> add_validation(safe_status(value(request, :source)) not in @sources, "unsupported_source", "use_supported_authorization_source", "unsupported")
    |> add_validation(blank?(optional_string(request, :authorization_request_fingerprint)), "authorization_request_fingerprint_missing", "refresh_execution_authorization_request", "malformed")
    |> add_validation(permit == nil, "readiness_permit_missing", "refresh_cutover_readiness_permit", "no_ready_permit")
    |> add_validation(permit_decision in @blocked_permit_decisions, "readiness_permit_blocked", "refresh_cutover_readiness_permit", "blocked")
    |> add_validation(permit_decision in @stale_permit_decisions, "readiness_permit_stale", "refresh_cutover_readiness_permit", "stale")
    |> add_validation(permit_decision in @manual_permit_decisions, "readiness_permit_manual_attention", "resolve_manual_attention", "manual_attention")
    |> add_validation(permit_decision in @unsupported_permit_decisions, "readiness_permit_unsupported", "choose_supported_operations", "unsupported")
    |> add_validation(permit_decision in @malformed_permit_decisions, "readiness_permit_malformed", "fix_cutover_readiness_permit", "malformed")
    |> add_validation(permit != nil and permit_decision != "ready_for_execution_consideration", "readiness_permit_not_ready", "refresh_cutover_readiness_permit", permit_level(permit_decision))
    |> add_validation(cutover_request_fingerprint_mismatch?(request, permit), "cutover_operation_request_fingerprint_mismatch", "refresh_execution_authorization_request", "stale")
    |> add_validation(readiness_permit_fingerprint_mismatch?(request, permit), "readiness_permit_fingerprint_mismatch", "refresh_execution_authorization_request", "stale")
    |> add_validation(readiness_permit_decision_mismatch?(request, permit), "readiness_permit_decision_mismatch", "refresh_execution_authorization_request", "stale")
    |> add_validation(activation_plan_fingerprint_mismatch?(request, permit), "activation_plan_fingerprint_mismatch", "refresh_execution_authorization_request", "stale")
    |> add_validation(acknowledgement_fingerprint_mismatch?(request, permit), "operator_acknowledgement_fingerprint_mismatch", "refresh_execution_authorization_request", "stale")
    |> add_validation(cutover_gate_fingerprint_mismatch?(request, permit), "cutover_gate_fingerprint_mismatch", "refresh_execution_authorization_request", "stale")
    |> add_validation(cutover_gate_decision_mismatch?(request, permit), "cutover_gate_decision_mismatch", "refresh_execution_authorization_request", "stale")
    |> add_validation(dry_run_audit_fingerprint_mismatch?(request, evidence), "dry_run_audit_fingerprint_mismatch", "refresh_execution_authorization_request", "stale")
    |> add_validation(audit_history_fingerprint_mismatch?(request, evidence), "audit_history_fingerprint_mismatch", "refresh_execution_authorization_request", "stale")
    |> add_validation(executor_mode_fingerprint_mismatch?(request, evidence), "executor_mode_fingerprint_mismatch", "refresh_execution_authorization_request", "stale")
    |> add_validation(provider_scope_mismatch?(request, permit), "provider_scope_mismatch", "refresh_execution_authorization_request", "stale")
    |> add_validation(project_unknown?(project_id, context), "unknown_project", "fix_authorization_request_project_id", "malformed")
    |> add_validation(request_mode_incompatible?(request, permit), "executor_starter_mode_incompatible", "confirm_hub_executor_modes", "blocked")
  end

  defp add_validation(reasons, true, code, action, level) do
    [%{code: code, actions: [action], level: level} | reasons]
  end

  defp add_validation(reasons, _condition, _code, _action, _level), do: reasons

  defp record_status(validation) do
    cond do
      Enum.any?(validation, &(&1.level == "malformed")) -> "malformed"
      Enum.any?(validation, &(&1.level == "unsupported")) -> "unsupported"
      Enum.any?(validation, &(&1.level == "no_ready_permit")) -> "no_ready_permit"
      Enum.any?(validation, &(&1.level == "stale")) -> "stale"
      Enum.any?(validation, &(&1.level == "manual_attention")) -> "manual_attention"
      validation != [] -> "blocked"
      true -> "authorized_for_explicit_execution"
    end
  end

  defp permit_level("stale"), do: "stale"
  defp permit_level("manual_attention"), do: "manual_attention"
  defp permit_level("unsupported"), do: "unsupported"
  defp permit_level("malformed"), do: "malformed"
  defp permit_level(""), do: "no_ready_permit"
  defp permit_level(_decision), do: "blocked"

  defp cutover_request_fingerprint_mismatch?(request, nil), do: bound?(get_in_value(request, [:cutover_operation_request, :request_fingerprint]))

  defp cutover_request_fingerprint_mismatch?(request, permit) do
    bound = get_in_value(request, [:cutover_operation_request, :request_fingerprint])
    current = get_in_value(permit, [:request, :request_fingerprint])
    bound?(bound) and bound != current
  end

  defp readiness_permit_fingerprint_mismatch?(request, nil), do: bound?(get_in_value(request, [:readiness_permit, :permit_fingerprint]))

  defp readiness_permit_fingerprint_mismatch?(request, permit) do
    bound = get_in_value(request, [:readiness_permit, :permit_fingerprint])
    current = optional_string(permit, :permit_fingerprint)
    bound?(bound) and bound != current
  end

  defp readiness_permit_decision_mismatch?(request, nil), do: safe_status(get_in_value(request, [:readiness_permit, :decision])) != ""

  defp readiness_permit_decision_mismatch?(request, permit) do
    bound = safe_status(get_in_value(request, [:readiness_permit, :decision]))
    current = safe_status(value(permit, :decision))
    bound != "" and bound != current
  end

  defp activation_plan_fingerprint_mismatch?(request, nil), do: bound?(get_in_value(request, [:activation_plan, :fingerprint]))

  defp activation_plan_fingerprint_mismatch?(request, permit) do
    bound = get_in_value(request, [:activation_plan, :fingerprint])
    current = get_in_value(permit, [:activation_plan, :fingerprint])
    bound?(bound) and bound != current
  end

  defp acknowledgement_fingerprint_mismatch?(request, nil), do: bound?(get_in_value(request, [:operator_acknowledgement, :fingerprint]))

  defp acknowledgement_fingerprint_mismatch?(request, permit) do
    bound = get_in_value(request, [:operator_acknowledgement, :fingerprint])
    current = get_in_value(permit, [:operator_acknowledgement, :fingerprint])
    bound?(bound) and bound != current
  end

  defp cutover_gate_fingerprint_mismatch?(request, nil), do: bound?(get_in_value(request, [:cutover_gate, :fingerprint]))

  defp cutover_gate_fingerprint_mismatch?(request, permit) do
    bound = get_in_value(request, [:cutover_gate, :fingerprint])
    current = get_in_value(permit, [:cutover_gate, :fingerprint])
    bound?(bound) and bound != current
  end

  defp cutover_gate_decision_mismatch?(request, nil), do: safe_status(get_in_value(request, [:cutover_gate, :decision])) != ""

  defp cutover_gate_decision_mismatch?(request, permit) do
    bound = safe_status(get_in_value(request, [:cutover_gate, :decision]))
    current = safe_status(get_in_value(permit, [:cutover_gate, :decision]))
    bound != "" and bound != current
  end

  defp dry_run_audit_fingerprint_mismatch?(request, evidence) do
    bound = get_in_value(request, [:dry_run_audit, :fingerprint])
    current = get_in_value(evidence, [:fingerprints, :dry_run_audit])
    bound?(bound) and bound != current
  end

  defp audit_history_fingerprint_mismatch?(request, evidence) do
    bound = get_in_value(request, [:audit_history, :fingerprint])
    current = get_in_value(evidence, [:fingerprints, :audit_history])
    bound?(bound) and bound != current
  end

  defp executor_mode_fingerprint_mismatch?(request, evidence) do
    bound =
      get_in_value(request, [:evidence_fingerprints, :runtime_modes]) ||
        get_in_value(request, [:evidence_fingerprints, :executor_modes])

    current = get_in_value(evidence, [:fingerprints, :executor_modes])
    bound?(bound) and bound != current
  end

  defp provider_scope_mismatch?(request, permit) do
    request_scope = provider_scope_snapshot(value(request, :provider_scope) || %{})
    permit_scope = provider_scope_snapshot(value(permit || %{}, :provider_scope) || %{})

    request_scope != %{} and permit_scope != %{} and request_scope != permit_scope
  end

  defp project_unknown?(project_id, context) do
    Map.has_key?(context.projects_by_id, project_id) == false and
      not Enum.any?(list_value(context.readiness_permit, :projects), &(required_string(&1, :project_id) == project_id))
  end

  defp request_mode_incompatible?(request, permit) do
    request_unsupported = truthy?(value(request, :unsupported_mode))
    request_skeleton = truthy?(value(request, :skeleton_mode))
    permit_modes = value(permit || %{}, :executor_modes) || %{}
    permit_unsupported = truthy?(value(permit_modes, :unsupported_mode))
    permit_not_ready? = safe_status(value(permit || %{}, :decision)) != "ready_for_execution_consideration"

    request_unsupported or permit_unsupported or (request_skeleton and permit_not_ready?)
  end

  defp project_status([], project_permits) do
    cond do
      project_permits == nil -> "no_ready_permit"
      list_value(project_permits, :permits) == [] -> "no_ready_permit"
      true -> "no_ready_permit"
    end
  end

  defp project_status(records, _project_permits) do
    cond do
      Enum.any?(records, &(&1.status == "malformed")) -> "malformed"
      Enum.any?(records, &(&1.status == "unsupported")) -> "unsupported"
      Enum.any?(records, &(&1.status == "no_ready_permit")) -> "no_ready_permit"
      Enum.any?(records, &(&1.status == "stale")) -> "stale"
      Enum.any?(records, &(&1.status == "manual_attention")) -> "manual_attention"
      Enum.any?(records, &(&1.status == "blocked")) -> "blocked"
      Enum.all?(records, &(&1.status == "authorized_for_explicit_execution")) -> "authorized_for_explicit_execution"
      true -> "blocked"
    end
  end

  defp project_snapshot(project) when is_map(project) do
    records =
      project
      |> list_value(:records)
      |> Enum.map(&operation_record_snapshot/1)
      |> Enum.sort_by(fn record ->
        {record.operation, get_in_value(record, [:authorization_request, :authorization_request_fingerprint]) || ""}
      end)

    %{
      version: positive_integer(value(project, :version)) || @version,
      project_id: required_string(project, :project_id),
      status: normalize_project_status(value(project, :status), records),
      authorization_request_count:
        non_negative_integer(value(project, :authorization_request_count)) ||
          length(records),
      provider_scope: provider_scope_snapshot(value(project, :provider_scope) || %{}),
      requested_operations: operation_list(value(project, :requested_operations)),
      records: records,
      reason_codes: string_list(value(project, :reason_codes)),
      required_operator_actions: action_snapshots(value(project, :required_operator_actions)),
      safe_evidence: safe_evidence_snapshot(value(project, :safe_evidence) || %{}),
      dry_run_only: value(project, :dry_run_only) != false,
      no_side_effects: value(project, :no_side_effects) != false
    }
  end

  defp project_snapshot(_project), do: project_snapshot(%{})

  defp operation_record_snapshot(record) when is_map(record) do
    status = normalize_record_status(value(record, :status))

    snapshot = %{
      version: positive_integer(value(record, :version)) || @version,
      project_id: required_string(record, :project_id),
      operation: operation_name(value(record, :operation)),
      status: status,
      reason_codes: string_list(value(record, :reason_codes)),
      required_operator_actions: action_snapshots(value(record, :required_operator_actions)),
      authorization_request: request_binding(value(record, :authorization_request)),
      provider_scope: provider_scope_snapshot(value(record, :provider_scope) || %{}),
      cutover_operation_request: cutover_request_binding(value(record, :cutover_operation_request), nil),
      readiness_permit: permit_binding(value(record, :readiness_permit), nil),
      activation_plan: activation_plan_binding(value(record, :activation_plan), nil),
      operator_acknowledgement: acknowledgement_binding(value(record, :operator_acknowledgement), nil),
      cutover_gate: gate_binding(value(record, :cutover_gate), nil),
      dry_run_audit: dry_run_binding(value(record, :dry_run_audit), nil),
      audit_history: history_binding(value(record, :audit_history), nil),
      executor_modes: SafeSummary.sanitize_map(value(record, :executor_modes) || %{}, output_keys: :preserve),
      evidence_fingerprints:
        SafeSummary.sanitize_map(value(record, :evidence_fingerprints) || %{},
          output_keys: :preserve
        ),
      source: safe_status(value(record, :source)) |> blank_to_default("unknown"),
      requested_at: iso8601(value(record, :requested_at)),
      evaluated_at: iso8601(value(record, :evaluated_at)),
      stale: value(record, :stale) == true or status == "stale",
      stale_reasons: string_list(value(record, :stale_reasons)),
      safe_evidence: safe_evidence_snapshot(value(record, :safe_evidence) || %{}),
      dry_run_only: value(record, :dry_run_only) != false,
      no_side_effects: value(record, :no_side_effects) != false
    }

    Map.put(snapshot, :authorization_record_fingerprint, optional_string(record, :authorization_record_fingerprint) || record_fingerprint(snapshot))
  end

  defp operation_record_snapshot(record), do: operation_record_snapshot(%{operation: record})

  defp normalize_project_status(status, records) do
    status = safe_status(status)

    cond do
      status in @statuses -> status
      records == [] -> "no_ready_permit"
      true -> project_status(records, %{})
    end
  end

  defp normalize_record_status(status) do
    status = safe_status(status)
    if status in @record_statuses, do: status, else: "blocked"
  end

  defp overall_status(projects) do
    active = Enum.reject(projects, &(&1.authorization_request_count == 0))

    cond do
      active == [] -> "no_ready_permit"
      Enum.any?(active, &(&1.status == "summary_error")) -> "summary_error"
      Enum.any?(active, &(&1.status == "malformed")) -> "malformed"
      Enum.any?(active, &(&1.status == "unsupported")) -> "unsupported"
      Enum.any?(active, &(&1.status == "no_ready_permit")) -> "no_ready_permit"
      Enum.any?(active, &(&1.status == "stale")) -> "stale"
      Enum.any?(active, &(&1.status == "manual_attention")) -> "manual_attention"
      Enum.any?(active, &(&1.status == "blocked")) -> "blocked"
      Enum.any?(active, &(&1.status == "authorized_for_explicit_execution")) -> "authorized_for_explicit_execution"
      true -> "no_ready_permit"
    end
  end

  defp normalize_overall_status(status, projects) do
    status = safe_status(status)
    if status in @statuses, do: status, else: overall_status(projects)
  end

  defp count_snapshot(counts, projects) when is_map(counts) do
    records = Enum.flat_map(projects, &list_value(&1, :records))

    %{
      project_count: non_negative_integer(value(counts, :project_count)) || length(projects),
      authorization_request_count:
        non_negative_integer(value(counts, :authorization_request_count)) ||
          Enum.reduce(projects, 0, &(&2 + (non_negative_integer(value(&1, :authorization_request_count)) || 0))),
      record_count: non_negative_integer(value(counts, :record_count)) || length(records),
      authorized_count:
        non_negative_integer(value(counts, :authorized_count)) ||
          Enum.count(records, &(&1.status == "authorized_for_explicit_execution")),
      blocked_count: non_negative_integer(value(counts, :blocked_count)) || Enum.count(records, &(&1.status == "blocked")),
      stale_count: non_negative_integer(value(counts, :stale_count)) || Enum.count(records, &(&1.status == "stale")),
      manual_attention_count:
        non_negative_integer(value(counts, :manual_attention_count)) ||
          Enum.count(records, &(&1.status == "manual_attention")),
      unsupported_count: non_negative_integer(value(counts, :unsupported_count)) || Enum.count(records, &(&1.status == "unsupported")),
      malformed_count: non_negative_integer(value(counts, :malformed_count)) || Enum.count(records, &(&1.status == "malformed")),
      no_ready_permit_count:
        non_negative_integer(value(counts, :no_ready_permit_count)) ||
          Enum.count(records, &(&1.status == "no_ready_permit")),
      summary_error_count: non_negative_integer(value(counts, :summary_error_count)) || Enum.count(projects, &(&1.status == "summary_error")),
      operation_status_counts:
        value(counts, :operation_status_counts) ||
          operation_status_counts(records)
    }
  end

  defp count_snapshot(_counts, projects), do: count_snapshot(%{}, projects)

  defp operation_status_counts(records) do
    base = Map.new(@record_statuses, &{String.to_atom(&1), 0})

    Enum.reduce(records, base, fn record, acc ->
      key =
        record
        |> value(:status)
        |> normalize_record_status()
        |> String.to_atom()

      Map.update!(acc, key, &(&1 + 1))
    end)
  end

  defp project_reason_codes(records, project_permits) do
    (Enum.flat_map(records, &string_list(value(&1, :reason_codes))) ++
       string_list(value(project_permits || %{}, :reason_codes)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp project_actions(records, project_permits) do
    (Enum.flat_map(records, &action_codes(value(&1, :required_operator_actions))) ++
       action_codes(value(project_permits || %{}, :required_operator_actions)))
    |> Enum.uniq()
    |> Enum.sort()
    |> action_snapshots()
  end

  defp project_safe_evidence(requests, project_permits, project, runtime) do
    %{
      authorization_requests: Enum.map(requests, &request_binding/1),
      readiness_permit: permit_project_binding(project_permits),
      project: project_binding(project),
      runtime_modes: runtime,
      dry_run_only: true,
      no_side_effects: true
    }
    |> safe_evidence_snapshot()
  end

  defp record_evidence(project_id, request, permit, context) do
    permit_evidence = value(permit || %{}, :safe_evidence) || %{}

    evidence =
      %{
        project: project_binding(Map.get(context.projects_by_id, project_id)) |> Map.put(:project_id, project_id),
        authorization_request: request_binding(request),
        cutover_operation_request: cutover_request_binding(request, permit),
        readiness_permit: permit_binding(permit, request),
        activation_plan: activation_plan_binding(permit, request),
        operator_acknowledgement: acknowledgement_binding(permit, request),
        cutover_gate: gate_binding(permit, request),
        dry_run_audit: dry_run_binding(permit, request),
        audit_history: history_binding(permit, request),
        executor_modes: executor_modes_binding(permit, request),
        readiness_permit_evidence_fingerprints:
          SafeSummary.sanitize_map(value(permit || %{}, :evidence_fingerprints) || %{},
            output_keys: :preserve
          ),
        permit_evidence: permit_evidence,
        dry_run_only: true,
        no_side_effects: true
      }
      |> safe_evidence_snapshot()

    Map.put(evidence, :fingerprints, evidence_fingerprints(evidence))
  end

  defp evidence_fingerprints(evidence) do
    permit_fingerprints = value(evidence, :readiness_permit_evidence_fingerprints) || %{}

    %{
      authorization_request: fingerprint(value(evidence, :authorization_request) || %{}),
      cutover_operation_request: fingerprint(value(evidence, :cutover_operation_request) || %{}),
      readiness_permit:
        get_in_value(evidence, [:readiness_permit, :permit_fingerprint]) ||
          fingerprint(value(evidence, :readiness_permit) || %{}),
      activation_plan:
        get_in_value(evidence, [:activation_plan, :fingerprint]) ||
          fingerprint(value(evidence, :activation_plan) || %{}),
      operator_acknowledgement:
        get_in_value(evidence, [:operator_acknowledgement, :fingerprint]) ||
          fingerprint(value(evidence, :operator_acknowledgement) || %{}),
      cutover_gate:
        get_in_value(evidence, [:cutover_gate, :fingerprint]) ||
          fingerprint(value(evidence, :cutover_gate) || %{}),
      dry_run_audit:
        optional_string(permit_fingerprints, :dry_run_audit) ||
          fingerprint(value(evidence, :dry_run_audit) || %{}),
      audit_history:
        optional_string(permit_fingerprints, :audit_history) ||
          fingerprint(value(evidence, :audit_history) || %{}),
      executor_modes:
        optional_string(permit_fingerprints, :runtime_modes) ||
          optional_string(permit_fingerprints, :executor_modes) ||
          fingerprint(value(evidence, :executor_modes) || %{}),
      authorization_input: fingerprint(Map.drop(evidence, [:dry_run_only, :no_side_effects, :fingerprints]))
    }
  end

  defp request_binding(nil), do: nil

  defp request_binding(request) when is_map(request) do
    %{
      authorization_request_id: optional_string(request, :authorization_request_id),
      authorization_request_fingerprint: optional_string(request, :authorization_request_fingerprint),
      project_id: optional_string(request, :project_id),
      operation: operation_name(value(request, :operation)),
      source: safe_status(value(request, :source)) |> blank_to_default("unknown"),
      requested_at: iso8601(value(request, :requested_at)),
      operator_intent: operator_intent_snapshot(value(request, :operator_intent) || %{})
    }
    |> compact_map()
  end

  defp request_binding(_request), do: nil

  defp cutover_request_binding(request, permit) do
    request_binding = value(request || %{}, :cutover_operation_request) || %{}
    permit_binding = value(permit || %{}, :request) || %{}

    %{
      request_id:
        optional_string(request, :request_id) ||
          optional_string(request_binding, :request_id) ||
          optional_string(permit_binding, :request_id),
      request_fingerprint:
        optional_string(request, :request_fingerprint) ||
          optional_string(request_binding, :request_fingerprint) ||
          optional_string(permit_binding, :request_fingerprint),
      requested_operations:
        operation_list(
          value(permit_binding, :requested_operations) ||
            value(request_binding, :requested_operations)
        ),
      source:
        safe_status(
          value(permit_binding, :source) ||
            value(request_binding, :source) ||
            value(request, :source)
        ),
      requested_at:
        iso8601(
          value(permit_binding, :requested_at) ||
            value(request_binding, :requested_at) ||
            value(request, :requested_at)
        )
    }
    |> compact_map()
  end

  defp permit_binding(nil, request) do
    request_permit = value(request || %{}, :readiness_permit) || %{}

    %{
      permit_fingerprint: optional_string(request_permit, :permit_fingerprint),
      decision: safe_status(value(request_permit, :decision)),
      status: "missing",
      reason_codes: string_list(value(request_permit, :reason_codes)),
      required_operator_actions: action_snapshots(value(request_permit, :required_operator_actions))
    }
    |> compact_map()
  end

  defp permit_binding(permit, _request) when is_map(permit) do
    %{
      permit_fingerprint: optional_string(permit, :permit_fingerprint),
      decision: safe_status(value(permit, :decision)),
      reason_codes: string_list(value(permit, :reason_codes)),
      required_operator_actions: action_snapshots(value(permit, :required_operator_actions)),
      generated_at: iso8601(value(permit, :generated_at)),
      evaluated_at: iso8601(value(permit, :evaluated_at))
    }
    |> compact_map()
  end

  defp permit_binding(_permit, request), do: permit_binding(nil, request)

  defp permit_project_binding(nil), do: nil

  defp permit_project_binding(project_permits) when is_map(project_permits) do
    %{
      status: safe_status(value(project_permits, :status)),
      request: value(project_permits, :request),
      requested_operations: operation_list(value(project_permits, :requested_operations)),
      reason_codes: string_list(value(project_permits, :reason_codes)),
      permit_count: length(list_value(project_permits, :permits))
    }
    |> compact_map()
  end

  defp permit_project_binding(_project_permits), do: nil

  defp activation_plan_binding(permit, request) do
    request_plan = value(request || %{}, :activation_plan) || %{}
    permit_plan = value(permit || %{}, :activation_plan) || %{}

    %{
      plan_id:
        optional_string(permit, :plan_id) ||
          optional_string(permit_plan, :plan_id) ||
          optional_string(request_plan, :plan_id),
      fingerprint:
        optional_string(permit, :fingerprint) ||
          optional_string(permit_plan, :fingerprint) ||
          optional_string(request_plan, :fingerprint),
      status: safe_status(value(permit, :status) || value(permit_plan, :status)),
      readiness_decision: safe_status(value(permit, :readiness_decision) || value(permit_plan, :readiness_decision)),
      proposed_next_state:
        safe_status(
          value(permit, :proposed_next_state) ||
            value(permit_plan, :proposed_next_state)
        )
    }
    |> compact_map()
  end

  defp acknowledgement_binding(permit, request) do
    request_ack = value(request || %{}, :operator_acknowledgement) || %{}
    permit_ack = value(permit || %{}, :operator_acknowledgement) || %{}

    %{
      status: safe_status(value(permit, :status) || value(permit_ack, :status)),
      project_id: optional_string(permit, :project_id) || optional_string(permit_ack, :project_id),
      plan_id: optional_string(permit, :plan_id) || optional_string(permit_ack, :plan_id),
      plan_id_matches: value(permit, :plan_id_matches) == true or value(permit_ack, :plan_id_matches) == true,
      source: safe_status(value(permit, :source) || value(permit_ack, :source)),
      created_at: iso8601(value(permit, :created_at) || value(permit_ack, :created_at)),
      fingerprint:
        optional_string(permit, :fingerprint) ||
          optional_string(permit_ack, :fingerprint) ||
          optional_string(request_ack, :fingerprint)
    }
    |> compact_map()
  end

  defp gate_binding(permit, request) do
    request_gate = value(request || %{}, :cutover_gate) || %{}
    permit_gate = value(permit || %{}, :cutover_gate) || %{}

    %{
      decision:
        safe_status(
          value(permit, :decision) ||
            value(permit_gate, :decision) ||
            value(request_gate, :decision)
        ),
      fingerprint:
        optional_string(permit, :fingerprint) ||
          optional_string(permit_gate, :fingerprint) ||
          optional_string(request_gate, :fingerprint),
      staged_ownership_record_id:
        optional_string(permit, :staged_ownership_record_id) ||
          optional_string(permit_gate, :staged_ownership_record_id) ||
          optional_string(request_gate, :staged_ownership_record_id),
      allowed_operations:
        operation_list(
          value(permit, :allowed_operations) ||
            value(permit_gate, :allowed_operations)
        ),
      blocked_operations: operation_list(value(permit, :blocked_operations) || value(permit_gate, :blocked_operations)),
      reason_codes: string_list(value(permit, :reason_codes) || value(permit_gate, :reason_codes))
    }
    |> compact_map()
  end

  defp dry_run_binding(permit, request) do
    request_audit = value(request || %{}, :dry_run_audit) || %{}
    permit_audit = value(permit || %{}, :dry_run_audit) || %{}

    %{
      status: safe_status(value(permit, :status) || value(permit_audit, :status)),
      request_fingerprint:
        optional_string(permit, :request_fingerprint) ||
          optional_string(permit_audit, :request_fingerprint),
      operation: operation_name(value(permit, :operation) || value(permit_audit, :operation)),
      operation_decision:
        safe_status(
          value(permit, :operation_decision) ||
            value(permit_audit, :operation_decision) ||
            value(request_audit, :decision)
        ),
      reason_codes: string_list(value(permit, :reason_codes) || value(permit_audit, :reason_codes)),
      required_operator_actions:
        action_snapshots(
          value(permit, :required_operator_actions) ||
            value(permit_audit, :required_operator_actions)
        ),
      operation_evidence_fingerprint:
        optional_string(permit, :operation_evidence_fingerprint) ||
          optional_string(permit_audit, :operation_evidence_fingerprint),
      fingerprint: optional_string(permit, :fingerprint) || optional_string(request_audit, :fingerprint),
      dry_run_only: value(permit, :dry_run_only) != false and value(permit_audit, :dry_run_only) != false
    }
    |> compact_map()
  end

  defp history_binding(permit, request) do
    request_history = value(request || %{}, :audit_history) || %{}
    permit_history = value(permit || %{}, :audit_history) || %{}

    %{
      status:
        safe_status(
          value(permit, :status) ||
            value(permit_history, :status) ||
            value(request_history, :status)
        ),
      latest_entry_id: optional_string(permit, :latest_entry_id) || optional_string(permit_history, :latest_entry_id),
      latest_request_fingerprint:
        optional_string(permit, :latest_request_fingerprint) ||
          optional_string(permit_history, :latest_request_fingerprint),
      latest_evaluated_at: iso8601(value(permit, :latest_evaluated_at) || value(permit_history, :latest_evaluated_at)),
      unresolved_manual_attention_count:
        non_negative_integer(value(permit, :unresolved_manual_attention_count)) ||
          non_negative_integer(value(permit_history, :unresolved_manual_attention_count)),
      closeout_statuses: string_list(value(permit, :closeout_statuses) || value(permit_history, :closeout_statuses)),
      counts:
        SafeSummary.sanitize_map(value(permit, :counts) || value(permit_history, :counts) || %{},
          output_keys: :preserve
        ),
      fingerprint: optional_string(permit, :fingerprint) || optional_string(request_history, :fingerprint),
      dry_run_only: value(permit, :dry_run_only) != false and value(permit_history, :dry_run_only) != false,
      no_side_effects: value(permit, :no_side_effects) != false and value(permit_history, :no_side_effects) != false
    }
    |> compact_map()
  end

  defp executor_modes_binding(permit, request) do
    request_modes = value(request || %{}, :executor_modes) || %{}
    permit_modes = value(permit || %{}, :executor_modes) || %{}

    permit_modes
    |> Map.merge(request_modes, fn _key, permit_value, request_value ->
      if request_value in [nil, "", %{}, []], do: permit_value, else: request_value
    end)
    |> SafeSummary.sanitize_map(output_keys: :preserve)
  end

  defp provider_scope(requests, project_permits, project) do
    cond do
      Enum.any?(requests, &(value(&1, :provider_scope) not in [nil, %{}])) ->
        requests
        |> Enum.find(&(value(&1, :provider_scope) not in [nil, %{}]))
        |> value(:provider_scope)
        |> provider_scope_snapshot()

      is_map(project_permits) and is_map(value(project_permits, :provider_scope)) ->
        provider_scope_snapshot(value(project_permits, :provider_scope))

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

  defp operator_intent_snapshot(intent) when is_map(intent) do
    %{
      action_codes: string_list(value(intent, :action_codes) || value(intent, :actions)),
      risk_codes: string_list(value(intent, :risk_codes) || value(intent, :risks)),
      note_digest: note_digest(value(intent, :operator_note) || value(intent, :note))
    }
    |> compact_map()
  end

  defp operator_intent_snapshot(_intent), do: %{}

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

  defp permits_by_project_operation(readiness_permit) do
    readiness_permit
    |> list_value(:projects)
    |> Enum.flat_map(fn project ->
      project_id = required_string(project, :project_id)
      project |> list_value(:permits) |> Enum.map(&{{project_id, operation_name(value(&1, :operation))}, &1})
    end)
    |> Map.new()
  end

  defp request_list(nil, _now), do: []

  defp request_list(%{} = requests, now) do
    requests
    |> Map.get(:requests, Map.get(requests, "requests", [requests]))
    |> request_list(now)
  end

  defp request_list(requests, now) when is_list(requests), do: Enum.map(requests, &request_snapshot(&1, now))
  defp request_list(request, now), do: [request_snapshot(request, now)]

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

  defp summary_error_project(project_id) do
    project_snapshot(%{
      project_id: project_id || "",
      status: "summary_error",
      authorization_request_count: 0,
      records: [],
      reason_codes: ["cutover_execution_authorization_summary_error"],
      required_operator_actions: action_snapshots(["inspect_summary_error"]),
      safe_evidence: %{summary_error: %{code: "cutover_execution_authorization_summary_error"}},
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

  defp record_fingerprint(record) do
    record
    |> Map.drop([:authorization_record_fingerprint, :evaluated_at])
    |> fingerprint()
  end

  defp request_fingerprint(request) do
    request
    |> Map.drop([:authorization_request_fingerprint])
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
      "" -> "unknown_operation"
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

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp bound?(value), do: not blank?(optional_string(value))
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _result -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _result -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp note_digest(nil), do: nil

  defp note_digest(note) do
    note
    |> optional_string()
    |> case do
      nil -> nil
      value -> fingerprint(%{note: value})
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
end
