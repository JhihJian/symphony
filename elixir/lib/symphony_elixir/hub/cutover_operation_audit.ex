defmodule SymphonyElixir.Hub.CutoverOperationAudit do
  @moduledoc """
  Read-only Hub cutover operation request and dry-run audit model.

  A request records which Hub-owned operations an operator wants to evaluate for
  a project. The evaluator only consumes safe snapshots that were already built
  by the runtime. It does not call provider executors, start workers, mutate the
  runtime ledger, write provider state, operate systemd, or edit project config.
  """

  alias SymphonyElixir.Hub.{CutoverGate, SafeSummary}

  @version 1
  @operations ["poll", "dispatch", "worker_start", "writeback"]
  @sources ["operator-file", "operator_cli", "test", "api", "hub-startup-option"]
  @decisions ["no_request", "dry_run_ready", "blocked", "manual_attention", "unsupported", "summary_error"]
  @operation_decisions ["would_allow", "would_block", "manual_attention", "unsupported"]

  @type request :: map()
  @type summary :: map()

  @spec build(term(), keyword()) :: summary()
  def build(sources, opts \\ []) when is_list(opts) do
    now =
      opts
      |> Keyword.get(:now)
      |> Kernel.||(value(sources, :generated_at))
      |> Kernel.||(DateTime.utc_now())
      |> iso8601()

    projects = list_value(sources, :projects)
    requests = Keyword.get(opts, :requests, value(sources, :cutover_operation_requests))
    request_snapshots = request_list(requests, now)
    project_ids = project_ids(projects, request_snapshots)
    context = context(sources, projects, request_snapshots, now)

    audit_projects =
      project_ids
      |> Enum.map(&safe_project_audit(&1, context))
      |> Enum.sort_by(& &1.project_id)

    %{
      version: @version,
      generated_at: now,
      status: overall_status(audit_projects),
      operation_set: @operations,
      counts: count_snapshot(%{}, audit_projects),
      projects: audit_projects
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
      operation_set: operation_list(value(summary, :operation_set)),
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
    project_id = optional_string(request, :project_id)
    provider_scope = provider_scope_snapshot(value(request, :provider_scope) || value(request, :provider) || %{})
    operations = operation_list(value(request, :requested_operations) || value(request, :operations))
    source = safe_status(value(request, :source)) |> blank_to_default("unknown")
    requested_at = iso8601(value(request, :requested_at)) || now

    activation_plan =
      %{
        plan_id: optional_string(request, :activation_plan_id) || optional_string(request, :plan_id),
        fingerprint:
          optional_string(request, :activation_plan_fingerprint) ||
            optional_string(request, :plan_fingerprint) ||
            optional_string(request, :fingerprint)
      }
      |> compact_map()

    request_gate = value(request, :cutover_gate) || %{}

    cutover_gate =
      %{
        decision:
          safe_status(
            value(request, :cutover_gate_decision) ||
              value(request_gate, :decision)
          ),
        fingerprint:
          optional_string(request, :cutover_gate_fingerprint) ||
            optional_string(request_gate, :fingerprint),
        staged_ownership_record_id:
          optional_string(request, :staged_ownership_record_id) ||
            optional_string(request_gate, :staged_ownership_record_id) ||
            get_in_value(request, [:staged_ownership_record, :record_id]) ||
            get_in_value(request_gate, [:staged_ownership_record, :record_id])
      }
      |> compact_map()

    snapshot =
      %{
        version: positive_integer(value(request, :version)) || @version,
        request_id: optional_string(request, :request_id) || optional_string(request, :id),
        project_id: project_id,
        provider_scope: provider_scope,
        requested_operations: operations,
        activation_plan: activation_plan,
        cutover_gate: cutover_gate,
        source: source,
        requested_at: requested_at,
        operator_intent:
          operator_intent_snapshot(
            value(request, :operator_intent) ||
              value(request, :intent) ||
              request
          ),
        project_snapshot:
          project_snapshot_evidence(
            value(request, :project_snapshot) ||
              value(request, :safe_project_snapshot)
          )
      }

    snapshot
    |> Map.put(:request_fingerprint, optional_string(request, :request_fingerprint) || request_fingerprint(snapshot))
    |> compact_map()
  end

  def request_snapshot(_request, now) do
    %{
      version: @version,
      requested_at: now,
      source: "malformed",
      requested_operations: [],
      operator_intent: %{},
      project_snapshot: %{},
      request_fingerprint:
        request_fingerprint(%{
          version: @version,
          requested_at: now,
          source: "malformed",
          malformed: true
        })
    }
  end

  defp context(sources, projects, requests, now) do
    %{
      generated_at: now,
      projects_by_id: Map.new(projects, &{required_string(&1, :project_id), &1}),
      requests_by_project: Enum.group_by(requests, &optional_string(&1, :project_id)),
      activation_plan_by_project: index_projects(value(sources, :activation_plan)),
      migration_readiness_by_project: index_projects(value(sources, :migration_readiness)),
      activation_preflight_by_project: index_projects(value(sources, :activation_preflight)),
      cutover_gate: CutoverGate.to_snapshot(value(sources, :cutover_gate)),
      runtime: runtime_snapshot(sources),
      project_count: length(projects)
    }
  end

  defp safe_project_audit(project_id, context) do
    project_audit(project_id, context)
  rescue
    _error -> summary_error_project(project_id)
  catch
    _kind, _reason -> summary_error_project(project_id)
  end

  defp project_audit(nil, context) do
    request =
      context.requests_by_project
      |> Map.get(nil, [])
      |> List.first()

    malformed_project(request, "project_id_missing")
  end

  defp project_audit("", context), do: project_audit(nil, context)

  defp project_audit(project_id, context) do
    project = Map.get(context.projects_by_id, project_id)
    requests = Map.get(context.requests_by_project, project_id, [])
    request = List.first(requests)

    cond do
      request == nil ->
        no_request_project(project_id, project, context)

      length(requests) > 1 ->
        request_blocked_project(project_id, request, project, context, ["multiple_requests_for_project"], ["submit_single_request"])

      project == nil ->
        request_blocked_project(project_id, request, project, context, ["unknown_project"], ["fix_request_project_id"])

      true ->
        evaluate_request(project_id, request, project, context)
    end
  end

  defp evaluate_request(project_id, request, project, context) do
    gate = CutoverGate.project(context.cutover_gate, project_id)
    plan = Map.get(context.activation_plan_by_project, project_id) || value(project, :activation_plan) || %{}
    readiness = Map.get(context.migration_readiness_by_project, project_id) || value(project, :migration_readiness) || %{}
    preflight = Map.get(context.activation_preflight_by_project, project_id) || value(project, :activation_preflight) || %{}
    operations = value(request, :requested_operations) || []

    validation = validation_reasons(request, project, plan, gate)

    operation_results =
      operations
      |> Enum.map(&operation_result(&1, validation, gate, plan, readiness, preflight, context.runtime))
      |> Enum.sort_by(& &1.operation)

    decision = project_decision(validation, operation_results)

    project_snapshot(%{
      project_id: project_id,
      status: decision,
      request: request,
      requested_operations: operations,
      operation_results: operation_results,
      reason_codes: reason_codes(validation, operation_results),
      required_operator_actions: action_snapshots(action_codes(validation, operation_results)),
      safe_evidence: safe_evidence(project, plan, gate, readiness, preflight, context.runtime),
      dry_run_only: true
    })
  end

  defp validation_reasons(request, project, plan, gate) do
    []
    |> add_validation(optional_string(request, :project_id) in [nil, ""], "project_id_missing", "fix_request_project_id", "request")
    |> add_validation(value(request, :source) not in @sources, "unsupported_source", "use_supported_request_source", "request")
    |> add_validation(value(request, :requested_operations) == [], "requested_operations_missing", "choose_supported_operations", "request")
    |> add_validation(invalid_operation?(value(request, :requested_operations)), "unknown_operation", "choose_supported_operations", "request")
    |> add_validation(provider_scope_mismatch?(request, project), "provider_scope_mismatch", "refresh_request_project_snapshot", "request")
    |> add_validation(plan_mismatch?(request, plan), "activation_plan_mismatch", "refresh_cutover_operation_request", "activation_plan")
    |> add_validation(gate == nil, "cutover_gate_missing", "refresh_cutover_gate", "cutover_gate")
    |> add_validation(gate_mismatch?(request, gate), "cutover_gate_mismatch", "refresh_cutover_operation_request", "cutover_gate")
    |> add_validation(staged_record_mismatch?(request, gate), "staged_ownership_record_mismatch", "refresh_cutover_operation_request", "cutover_gate")
    |> add_validation(value(request, :project_snapshot) in [nil, %{}], "safe_project_snapshot_missing", "refresh_request_project_snapshot", "project_registry")
    |> add_validation(project_snapshot_mismatch?(request, project), "safe_project_snapshot_mismatch", "refresh_cutover_operation_request", "project_registry")
  end

  defp operation_result(operation, validation, gate, plan, readiness, preflight, runtime) do
    operation = operation_name(operation)

    cond do
      operation not in @operations ->
        operation_snapshot(%{
          operation: operation,
          decision: "unsupported",
          reason_codes: ["unknown_operation"],
          required_operator_actions: ["choose_supported_operations"],
          safe_evidence: operation_evidence(plan, gate, readiness, preflight, runtime),
          dry_run_only: true
        })

      validation != [] ->
        level = if Enum.any?(validation, &(&1.level == "manual_attention")), do: "manual_attention", else: "would_block"

        operation_snapshot(%{
          operation: operation,
          decision: level,
          reason_codes: Enum.map(validation, & &1.code),
          required_operator_actions: Enum.flat_map(validation, & &1.actions),
          safe_evidence: operation_evidence(plan, gate, readiness, preflight, runtime),
          dry_run_only: true
        })

      gate == nil ->
        operation_snapshot(%{
          operation: operation,
          decision: "would_block",
          reason_codes: ["cutover_gate_missing"],
          required_operator_actions: ["refresh_cutover_gate"],
          safe_evidence: operation_evidence(plan, gate, readiness, preflight, runtime),
          dry_run_only: true
        })

      operation in (value(gate, :allowed_operations) || []) ->
        operation_snapshot(%{
          operation: operation,
          decision: "would_allow",
          reason_codes: [],
          required_operator_actions: [],
          safe_evidence: operation_evidence(plan, gate, readiness, preflight, runtime),
          dry_run_only: true
        })

      true ->
        gate_reasons = gate_reason_codes(gate)
        decision = if value(gate, :decision) == "manual_attention", do: "manual_attention", else: "would_block"

        operation_snapshot(%{
          operation: operation,
          decision: decision,
          reason_codes: ["cutover_gate_blocked" | gate_reasons] |> Enum.uniq(),
          required_operator_actions: action_codes(value(gate, :required_operator_actions)),
          safe_evidence: operation_evidence(plan, gate, readiness, preflight, runtime),
          dry_run_only: true
        })
    end
  end

  defp no_request_project(project_id, project, context) do
    project_snapshot(%{
      project_id: project_id,
      status: "no_request",
      request: nil,
      requested_operations: [],
      operation_results: [],
      reason_codes: [],
      required_operator_actions: [],
      safe_evidence:
        safe_evidence(
          project || %{},
          %{},
          CutoverGate.project(context.cutover_gate, project_id),
          %{},
          %{},
          context.runtime
        ),
      dry_run_only: true
    })
  end

  defp request_blocked_project(project_id, request, project, context, reason_codes, actions) do
    gate = CutoverGate.project(context.cutover_gate, project_id)
    plan = Map.get(context.activation_plan_by_project, project_id) || value(project || %{}, :activation_plan) || %{}

    project_snapshot(%{
      project_id: project_id,
      status: "blocked",
      request: request,
      requested_operations: value(request, :requested_operations) || [],
      operation_results:
        (value(request, :requested_operations) || [])
        |> Enum.map(fn operation ->
          operation_snapshot(%{
            operation: operation_name(operation),
            decision: "would_block",
            reason_codes: reason_codes,
            required_operator_actions: actions,
            safe_evidence: operation_evidence(plan, gate, %{}, %{}, context.runtime),
            dry_run_only: true
          })
        end),
      reason_codes: reason_codes,
      required_operator_actions: action_snapshots(actions),
      safe_evidence: safe_evidence(project || %{}, plan, gate, %{}, %{}, context.runtime),
      dry_run_only: true
    })
  end

  defp malformed_project(request, code) do
    project_snapshot(%{
      project_id: optional_string(request || %{}, :project_id) || "",
      status: "blocked",
      request: request,
      requested_operations: value(request || %{}, :requested_operations) || [],
      operation_results: [],
      reason_codes: [code],
      required_operator_actions: action_snapshots(["fix_cutover_operation_request"]),
      safe_evidence: %{request: %{malformed: true}},
      dry_run_only: true
    })
  end

  defp summary_error_project(project_id) do
    project_snapshot(%{
      project_id: project_id || "",
      status: "summary_error",
      request: nil,
      requested_operations: [],
      operation_results: [],
      reason_codes: ["cutover_operation_audit_summary_error"],
      required_operator_actions: action_snapshots(["inspect_summary_error"]),
      safe_evidence: %{summary_error: %{code: "cutover_operation_audit_summary_error"}},
      dry_run_only: true
    })
  end

  defp project_snapshot(project) when is_map(project) do
    request =
      case value(project, :request) do
        nil -> nil
        request -> request_snapshot(request)
      end

    operation_results =
      project
      |> list_value(:operation_results)
      |> Enum.map(&operation_snapshot/1)
      |> Enum.sort_by(& &1.operation)

    status = normalize_project_status(value(project, :status), request, operation_results)

    %{
      version: positive_integer(value(project, :version)) || @version,
      project_id: required_string(project, :project_id),
      status: status,
      request: request,
      requested_operations: operation_list(value(project, :requested_operations)),
      operation_results: operation_results,
      reason_codes: string_list(value(project, :reason_codes)),
      required_operator_actions: action_snapshots(value(project, :required_operator_actions)),
      safe_evidence: SafeSummary.sanitize_map(value(project, :safe_evidence) || %{}, output_keys: :preserve),
      dry_run_only: value(project, :dry_run_only) != false
    }
  end

  defp project_snapshot(_project), do: project_snapshot(%{})

  defp operation_snapshot(operation) when is_map(operation) do
    decision = safe_status(value(operation, :decision)) |> blank_to_default("would_block")

    %{
      operation: operation_name(value(operation, :operation)),
      decision: if(decision in @operation_decisions, do: decision, else: "would_block"),
      reason_codes: string_list(value(operation, :reason_codes)),
      required_operator_actions: action_snapshots(value(operation, :required_operator_actions)),
      safe_evidence: SafeSummary.sanitize_map(value(operation, :safe_evidence) || %{}, output_keys: :preserve),
      dry_run_only: value(operation, :dry_run_only) != false
    }
  end

  defp operation_snapshot(operation), do: operation_snapshot(%{operation: operation})

  defp project_decision(validation, operation_results) do
    cond do
      validation != [] and Enum.any?(validation, &(&1.code == "unsupported_source" or &1.code == "unknown_operation")) ->
        "unsupported"

      validation != [] and Enum.any?(validation, &(&1.level == "manual_attention")) ->
        "manual_attention"

      validation != [] ->
        "blocked"

      Enum.any?(operation_results, &(&1.decision == "unsupported")) ->
        "unsupported"

      Enum.any?(operation_results, &(&1.decision == "manual_attention")) ->
        "manual_attention"

      Enum.any?(operation_results, &(&1.decision == "would_block")) ->
        "blocked"

      operation_results == [] ->
        "blocked"

      true ->
        "dry_run_ready"
    end
  end

  defp normalize_project_status(status, request, operation_results) do
    normalized = safe_status(status)

    cond do
      normalized in @decisions -> normalized
      request == nil -> "no_request"
      true -> project_decision([], operation_results)
    end
  end

  defp overall_status(projects) do
    requested = Enum.reject(projects, &(&1.status == "no_request"))

    cond do
      requested == [] -> "no_request"
      Enum.any?(requested, &(&1.status == "summary_error")) -> "summary_error"
      Enum.any?(requested, &(&1.status == "unsupported")) -> "unsupported"
      Enum.any?(requested, &(&1.status == "manual_attention")) -> "manual_attention"
      Enum.any?(requested, &(&1.status == "blocked")) -> "blocked"
      Enum.any?(requested, &(&1.status == "dry_run_ready")) -> "dry_run_ready"
      true -> "no_request"
    end
  end

  defp normalize_overall_status(status, projects) do
    normalized = safe_status(status)
    if normalized in @decisions, do: normalized, else: overall_status(projects)
  end

  defp count_snapshot(counts, projects) when is_map(counts) do
    statuses = Map.new(@decisions, &{String.to_atom(&1), 0})

    status_counts =
      Enum.reduce(projects, statuses, fn project, acc ->
        key = project.status |> normalize_status_atom()
        Map.update!(acc, key, &(&1 + 1))
      end)

    %{
      project_count: non_negative_integer(value(counts, :project_count)) || length(projects),
      request_count: non_negative_integer(value(counts, :request_count)) || Enum.count(projects, &(&1.request != nil)),
      no_request_count: non_negative_integer(value(counts, :no_request_count)) || status_counts.no_request,
      dry_run_ready_count: non_negative_integer(value(counts, :dry_run_ready_count)) || status_counts.dry_run_ready,
      blocked_count: non_negative_integer(value(counts, :blocked_count)) || status_counts.blocked,
      manual_attention_count:
        non_negative_integer(value(counts, :manual_attention_count)) ||
          status_counts.manual_attention,
      unsupported_count: non_negative_integer(value(counts, :unsupported_count)) || status_counts.unsupported,
      summary_error_count: non_negative_integer(value(counts, :summary_error_count)) || status_counts.summary_error,
      requested_operation_count:
        non_negative_integer(value(counts, :requested_operation_count)) ||
          Enum.reduce(projects, 0, &(&2 + length(value(&1, :requested_operations) || []))),
      operation_decision_counts:
        value(counts, :operation_decision_counts) ||
          operation_decision_counts(projects)
    }
  end

  defp count_snapshot(_counts, projects), do: count_snapshot(%{}, projects)

  defp operation_decision_counts(projects) do
    base = Map.new(@operation_decisions, &{String.to_atom(&1), 0})

    Enum.reduce(projects, base, fn project, acc ->
      project
      |> list_value(:operation_results)
      |> Enum.reduce(acc, fn operation, inner ->
        key =
          operation
          |> value(:decision)
          |> safe_status()
          |> case do
            "would_allow" -> :would_allow
            "manual_attention" -> :manual_attention
            "unsupported" -> :unsupported
            _other -> :would_block
          end

        Map.update!(inner, key, &(&1 + 1))
      end)
    end)
  end

  defp normalize_status_atom(status) do
    case safe_status(status) do
      "dry_run_ready" -> :dry_run_ready
      "blocked" -> :blocked
      "manual_attention" -> :manual_attention
      "unsupported" -> :unsupported
      "summary_error" -> :summary_error
      _other -> :no_request
    end
  end

  defp validation_reason(code, action, source, level) do
    %{code: code, actions: [action], source: source, level: level}
  end

  defp add_validation(reasons, true, code, action, source) do
    level = if code in ["activation_plan_mismatch", "cutover_gate_mismatch", "staged_ownership_record_mismatch"], do: "manual_attention", else: "blocking"
    [validation_reason(code, action, source, level) | reasons]
  end

  defp add_validation(reasons, _condition, _code, _action, _source), do: reasons

  defp invalid_operation?(operations) when is_list(operations) do
    Enum.any?(operations, &(operation_name(&1) not in @operations))
  end

  defp invalid_operation?(_operations), do: true

  defp provider_scope_mismatch?(request, project) do
    request_scope = value(request, :provider_scope) || %{}

    cond do
      request_scope == %{} ->
        false

      project == nil ->
        false

      optional_string(request_scope, :provider_scope_key) not in [nil, ""] ->
        optional_string(request_scope, :provider_scope_key) != project_provider_scope_key(project)

      optional_string(request_scope, :kind) not in [nil, ""] ->
        optional_string(request_scope, :kind) != project_provider_kind(project)

      true ->
        false
    end
  end

  defp plan_mismatch?(request, plan) do
    requested = value(request, :activation_plan) || %{}
    requested_plan_id = optional_string(requested, :plan_id)
    requested_fingerprint = optional_string(requested, :fingerprint)
    plan_id = optional_string(plan, :plan_id)
    fingerprint = optional_string(plan, :fingerprint) || optional_string(plan, :plan_fingerprint) || plan_id

    cond do
      requested_plan_id not in [nil, ""] and requested_plan_id != plan_id -> true
      requested_fingerprint not in [nil, ""] and requested_fingerprint != fingerprint -> true
      requested_plan_id in [nil, ""] and requested_fingerprint in [nil, ""] -> true
      true -> false
    end
  end

  defp gate_mismatch?(_request, nil), do: false

  defp gate_mismatch?(request, gate) do
    requested = value(request, :cutover_gate) || %{}
    requested_decision = optional_string(requested, :decision)
    requested_fingerprint = optional_string(requested, :fingerprint)

    cond do
      requested_decision not in [nil, ""] and requested_decision != optional_string(gate, :decision) ->
        true

      requested_fingerprint not in [nil, ""] and requested_fingerprint != gate_fingerprint(gate) ->
        true

      true ->
        false
    end
  end

  defp staged_record_mismatch?(_request, nil), do: false

  defp staged_record_mismatch?(request, gate) do
    requested = value(request, :cutover_gate) || %{}
    requested_record_id = optional_string(requested, :staged_ownership_record_id)
    staged_record = value(gate, :staged_ownership_record)
    current_record_id = optional_string(staged_record || %{}, :record_id)

    requested_record_id not in [nil, ""] and requested_record_id != current_record_id
  end

  defp project_snapshot_mismatch?(request, project) do
    snapshot = value(request, :project_snapshot) || %{}

    requested_fingerprint =
      optional_string(snapshot, :config_fingerprint) ||
        optional_string(snapshot, :project_fingerprint)

    requested_fingerprint not in [nil, ""] and requested_fingerprint != project_config_fingerprint(project)
  end

  defp safe_evidence(project, plan, gate, readiness, preflight, runtime) do
    %{
      project: %{
        project_id: optional_string(project || %{}, :project_id),
        migration_state: safe_status(value(project || %{}, :migration_state)),
        status: safe_status(value(project || %{}, :status)),
        provider_scope_key: project_provider_scope_key(project || %{}),
        config_fingerprint: project_config_fingerprint(project || %{})
      },
      activation_plan: plan_evidence(plan),
      cutover_gate: gate_evidence(gate),
      migration_readiness: %{
        decision: safe_status(value(readiness || %{}, :decision))
      },
      activation_preflight: %{
        status: safe_status(value(preflight || %{}, :status)),
        safe_to_manage: value(preflight || %{}, :safe_to_manage),
        probe_source: optional_string(preflight || %{}, :probe_source)
      },
      runtime_modes: runtime
    }
    |> SafeSummary.sanitize_map(output_keys: :preserve)
  end

  defp operation_evidence(plan, gate, readiness, preflight, runtime) do
    %{
      activation_plan: plan_evidence(plan),
      cutover_gate: gate_evidence(gate),
      migration_readiness: %{decision: safe_status(value(readiness || %{}, :decision))},
      activation_preflight: %{
        status: safe_status(value(preflight || %{}, :status)),
        safe_to_manage: value(preflight || %{}, :safe_to_manage),
        blocked_operations: operation_list(value(preflight || %{}, :blocked_operations))
      },
      runtime_modes: runtime
    }
  end

  defp plan_evidence(plan) when is_map(plan) do
    %{
      plan_id: optional_string(plan, :plan_id),
      fingerprint:
        optional_string(plan, :fingerprint) ||
          optional_string(plan, :plan_fingerprint) ||
          optional_string(plan, :plan_id),
      status: safe_status(value(plan, :status)),
      acknowledgement_status: get_in_value(plan, [:operator_acknowledgement, :status])
    }
  end

  defp plan_evidence(_plan), do: %{}

  defp gate_evidence(nil), do: %{}

  defp gate_evidence(gate) do
    %{
      fingerprint: gate_fingerprint(gate),
      decision: safe_status(value(gate, :decision)),
      allowed_operations: operation_list(value(gate, :allowed_operations)),
      blocked_operations: operation_list(value(gate, :blocked_operations)),
      staged_ownership_record_id: get_in_value(gate, [:staged_ownership_record, :record_id]),
      reason_codes: gate_reason_codes(gate)
    }
  end

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
      },
      provider_executor:
        SafeSummary.sanitize_map(value(runtime, :provider_executor) || %{},
          output_keys: :preserve
        ),
      writeback_executor:
        SafeSummary.sanitize_map(value(runtime, :writeback_executor) || %{},
          output_keys: :preserve
        ),
      worker_starter: SafeSummary.sanitize_map(value(runtime, :worker_starter) || %{}, output_keys: :preserve),
      activation_probe: SafeSummary.sanitize_map(value(runtime, :activation_probe) || %{}, output_keys: :preserve)
    }
  end

  defp project_ids(projects, requests) do
    [
      Enum.map(projects, &required_string(&1, :project_id)),
      Enum.map(requests, &(optional_string(&1, :project_id) || ""))
    ]
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp request_list(nil, _now), do: []

  defp request_list(%{} = requests, now) do
    requests
    |> Map.get(:requests, Map.get(requests, "requests", [requests]))
    |> request_list(now)
  end

  defp request_list(requests, now) when is_list(requests), do: Enum.map(requests, &request_snapshot(&1, now))
  defp request_list(request, now), do: [request_snapshot(request, now)]

  defp operation_list(value) when is_list(value) do
    value
    |> Enum.map(&operation_name/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp operation_list(_value), do: []

  defp operation_name(value) do
    case safe_status(value) do
      "candidate_scan" -> "poll"
      "worker-start" -> "worker_start"
      "provider_writeback" -> "writeback"
      other -> other
    end
  end

  defp provider_scope_snapshot(scope) when is_map(scope) do
    %{
      kind: optional_string(scope, :kind),
      provider_scope_key:
        optional_string(scope, :provider_scope_key) ||
          optional_string(scope, :key),
      scope: SafeSummary.sanitize_map(value(scope, :scope) || %{}, output_keys: :preserve)
    }
    |> compact_map()
  end

  defp provider_scope_snapshot(_scope), do: %{}

  defp operator_intent_snapshot(intent) when is_map(intent) do
    %{
      action_codes: string_list(value(intent, :action_codes) || value(intent, :operator_action_codes)),
      risk_codes: string_list(value(intent, :risk_codes) || value(intent, :operator_risk_codes)),
      note_digest: value(intent, :note_digest) || note_digest(value(intent, :note) || value(intent, :operator_note))
    }
    |> compact_map()
  end

  defp operator_intent_snapshot(_intent), do: %{}

  defp project_snapshot_evidence(snapshot) when is_map(snapshot) do
    %{
      migration_state: safe_status(value(snapshot, :migration_state)),
      status: safe_status(value(snapshot, :status)),
      provider_scope_key: optional_string(snapshot, :provider_scope_key),
      config_fingerprint:
        optional_string(snapshot, :config_fingerprint) ||
          optional_string(snapshot, :project_fingerprint)
    }
    |> compact_map()
  end

  defp project_snapshot_evidence(_snapshot), do: %{}

  defp note_digest(note) when is_binary(note) do
    trimmed = String.trim(note)

    if trimmed == "" do
      nil
    else
      %{
        sha256: fingerprint(trimmed),
        bytes: byte_size(trimmed)
      }
    end
  end

  defp note_digest(_note), do: nil

  defp request_fingerprint(request) do
    request
    |> Map.drop([:request_id, :request_fingerprint])
    |> fingerprint()
  end

  defp fingerprint(payload) do
    :crypto.hash(:sha256, :erlang.term_to_binary(payload))
    |> Base.encode16(case: :lower)
  end

  defp gate_reason_codes(nil), do: []

  defp gate_reason_codes(gate) do
    gate
    |> list_value(:blocking_reasons)
    |> Enum.map(&(optional_string(&1, :code) || optional_string(&1, :reason)))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp reason_codes(validation, operation_results) do
    (Enum.map(validation, & &1.code) ++ Enum.flat_map(operation_results, & &1.reason_codes))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp action_codes(validation, operation_results) do
    operation_actions =
      Enum.flat_map(operation_results, fn result ->
        action_codes(value(result, :required_operator_actions))
      end)

    (Enum.flat_map(validation, & &1.actions) ++ operation_actions)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp action_codes(actions) when is_list(actions) do
    actions
    |> Enum.map(fn
      action when is_map(action) -> optional_string(action, :code)
      action -> optional_string(action)
    end)
    |> Enum.reject(&blank?/1)
  end

  defp action_codes(_actions), do: []

  defp action_snapshots(actions) when is_list(actions) do
    actions
    |> action_codes()
    |> Enum.map(&%{code: &1, label: label_for(&1)})
    |> Enum.uniq_by(& &1.code)
    |> Enum.sort_by(& &1.code)
  end

  defp action_snapshots(_actions), do: []

  defp index_projects(summary) do
    summary
    |> list_value(:projects)
    |> Map.new(&{required_string(&1, :project_id), &1})
  end

  defp project_provider_scope_key(project) when is_map(project) do
    optional_string(project, :provider_scope_key) ||
      get_in_value(project, [:provider, :provider_scope_key]) ||
      get_in_value(project, [:provider, :key]) ||
      get_in_value(project, [:detail, :identity, :provider_scope_key])
  end

  defp project_provider_scope_key(_project), do: nil

  defp project_provider_kind(project) when is_map(project) do
    get_in_value(project, [:provider, :kind]) ||
      get_in_value(project, [:detail, :identity, :provider_kind])
  end

  defp project_provider_kind(_project), do: nil

  defp project_config_fingerprint(project) when is_map(project) do
    get_in_value(project, [:detail, :config, :config_fingerprint]) ||
      optional_string(project, :config_fingerprint) ||
      optional_string(project, :fingerprint)
  end

  defp project_config_fingerprint(_project), do: nil

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

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value
end
