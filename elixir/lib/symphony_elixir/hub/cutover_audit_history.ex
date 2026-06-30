defmodule SymphonyElixir.Hub.CutoverAuditHistory do
  @moduledoc """
  Read-only Hub cutover audit history and manual-attention closeout model.

  This module turns the current cutover operation dry-run audit plus optional
  previously recovered history entries and operator closeouts into a bounded,
  sanitized read model. It never calls providers, starts workers, mutates the
  runtime ledger, operates systemd, or edits Hub/project configuration.
  """

  alias SymphonyElixir.Hub.{CutoverOperationAudit, SafeSummary}

  @version 1
  @operations ["poll", "dispatch", "worker_start", "writeback"]
  @operation_attention_decisions ["would_block", "manual_attention", "unsupported"]
  @sources ["operator_file", "operator_cli", "test", "api", "hub_startup_option", "operator"]
  @closeout_decisions [
    "accepted_risk",
    "resolved_externally",
    "rejected",
    "deferred",
    "stale",
    "conflict",
    "malformed",
    "unsupported"
  ]
  @closing_decisions ["accepted_risk", "resolved_externally", "rejected"]
  @closeout_statuses ["closed", "deferred", "stale", "conflict", "malformed", "unsupported"]
  @statuses [
    "no_history",
    "history_ready",
    "unresolved_manual_attention",
    "closed",
    "deferred",
    "stale",
    "conflict",
    "malformed",
    "unsupported",
    "summary_error"
  ]
  @default_history_limit 20
  @default_project_history_limit 5

  @type summary :: map()

  @spec build(term(), keyword()) :: summary()
  def build(sources, opts \\ []) when is_list(opts) do
    now =
      opts
      |> Keyword.get(:now)
      |> Kernel.||(value(sources, :generated_at))
      |> Kernel.||(DateTime.utc_now())
      |> iso8601()

    audit = CutoverOperationAudit.to_snapshot(value(sources, :cutover_operation_audit) || %{})
    history_limit = positive_integer(Keyword.get(opts, :history_limit)) || @default_history_limit
    project_history_limit = positive_integer(Keyword.get(opts, :project_history_limit)) || @default_project_history_limit

    recovered_entries =
      Keyword.get(opts, :history_entries, value(sources, :history_entries))
      |> entry_list(now)
      |> Enum.map(&history_entry_snapshot(&1, now))
      |> Enum.uniq_by(& &1.entry_id)
      |> Enum.sort_by(&sort_time(&1.evaluated_at), :desc)

    current_entries =
      audit
      |> current_audit_entries(now)
      |> Enum.map(&history_entry_snapshot(&1, now))
      |> Enum.uniq_by(& &1.entry_id)
      |> Enum.sort_by(&sort_time(&1.evaluated_at), :desc)

    entries =
      [recovered_entries, current_entries]
      |> List.flatten()
      |> Enum.uniq_by(& &1.entry_id)
      |> Enum.sort_by(&sort_time(&1.evaluated_at), :desc)

    limited_entries = Enum.take(entries, history_limit)
    truncated? = length(entries) > length(limited_entries)
    closeouts = closeout_list(Keyword.get(opts, :closeouts, value(sources, :manual_attention_closeouts)), now)
    attention_entries = attention_entries(current_entries, limited_entries)
    project_ids = project_ids(attention_entries, closeouts, audit)
    closeout_index = evaluate_closeouts(closeouts, current_entries)

    projects =
      project_ids
      |> Enum.map(&project_summary(&1, limited_entries, attention_entries, closeout_index, project_history_limit))
      |> Enum.sort_by(& &1.project_id)

    %{
      version: @version,
      generated_at: now,
      status: overall_status(projects, closeout_index),
      dry_run_only: true,
      no_side_effects: true,
      limits: %{
        max_history_entries: history_limit,
        max_history_entries_per_project: project_history_limit,
        truncated: truncated?,
        input_history_entry_count: length(entries)
      },
      counts: count_snapshot(%{}, projects, closeout_index),
      closeouts: closeout_index.evaluated,
      projects: projects
    }
    |> to_snapshot()
  end

  @spec to_snapshot(term()) :: summary()
  def to_snapshot(summary) when is_map(summary) do
    closeouts =
      summary
      |> list_value(:closeouts)
      |> Enum.map(&evaluated_closeout_snapshot/1)
      |> Enum.sort_by(&{&1.project_id, &1.status, &1.operation, &1.reason_code, &1.required_operator_action_code})

    projects_input =
      summary
      |> list_value(:projects)
      |> Enum.map(&project_snapshot/1)
      |> Enum.sort_by(& &1.project_id)

    limits = limits_snapshot(value(summary, :limits), projects_input)
    {projects, limits} = limit_project_history_entries(projects_input, limits)

    %{
      version: positive_integer(value(summary, :version)) || @version,
      generated_at: iso8601(value(summary, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601(),
      status: normalize_status(value(summary, :status), projects, closeouts),
      dry_run_only: value(summary, :dry_run_only) != false,
      no_side_effects: value(summary, :no_side_effects) != false,
      limits: limits_snapshot(limits, projects),
      counts:
        count_snapshot(%{}, projects, %{
          evaluated: closeouts,
          closed_item_ids: closed_item_ids(closeouts)
        }),
      closeouts: closeouts,
      projects: projects
    }
  end

  def to_snapshot(_summary), do: to_snapshot(%{})

  @spec observability_snapshot(term()) :: summary() | nil
  def observability_snapshot(nil), do: nil
  def observability_snapshot(summary) when is_map(summary), do: to_snapshot(summary)
  def observability_snapshot(_summary), do: nil

  defp current_audit_entries(audit, now) do
    audit
    |> list_value(:projects)
    |> Enum.filter(&(value(&1, :request) != nil))
    |> Enum.map(&entry_from_audit_project(&1, now))
  end

  defp entry_from_audit_project(project, now) do
    evaluated_at = iso8601(value(project, :evaluated_at) || value(project, :generated_at)) || now
    safe_evidence = safe_evidence_snapshot(value(project, :safe_evidence) || %{})
    request = project |> value(:request) |> audit_request_with_evidence(safe_evidence)

    %{
      entry_id:
        optional_string(project, :entry_id) ||
          fingerprint(%{
            project_id: required_string(project, :project_id),
            request_fingerprint: optional_string(request, :request_fingerprint),
            evaluated_at: evaluated_at,
            operation_results: value(project, :operation_results)
          }),
      project_id: required_string(project, :project_id),
      provider_scope: provider_scope_from_request_or_evidence(request, safe_evidence),
      request: request,
      evaluated_at: evaluated_at,
      requested_operations: operation_list(value(project, :requested_operations)),
      operation_results: list_value(project, :operation_results),
      reason_codes: string_list(value(project, :reason_codes)),
      required_operator_actions: action_snapshots(value(project, :required_operator_actions)),
      safe_evidence: safe_evidence,
      source: "current_dry_run_audit",
      dry_run_only: true,
      no_side_effects: true
    }
  end

  defp audit_request_with_evidence(request, safe_evidence) when is_map(request) do
    request
    |> maybe_put_missing_summary(:activation_plan, value(safe_evidence, :activation_plan))
    |> maybe_put_missing_summary(:cutover_gate, value(safe_evidence, :cutover_gate))
  end

  defp audit_request_with_evidence(_request, _safe_evidence), do: %{}

  defp maybe_put_missing_summary(request, key, summary) when is_map(summary) and summary != %{} do
    case value(request, key) do
      value when is_map(value) and map_size(value) > 0 -> request
      _value -> Map.put(request, key, summary)
    end
  end

  defp maybe_put_missing_summary(request, _key, _summary), do: request

  defp history_entry_snapshot(entry, now) when is_map(entry) do
    request = request_snapshot(value(entry, :request) || entry, now)
    project_id = optional_string(entry, :project_id) || optional_string(request, :project_id) || ""
    operation_results = Enum.map(list_value(entry, :operation_results), &operation_result_snapshot/1)

    evaluated_at =
      iso8601(value(entry, :evaluated_at) || value(entry, :generated_at) || value(request, :requested_at)) ||
        now

    safe_evidence = safe_evidence_snapshot(value(entry, :safe_evidence) || %{})

    snapshot = %{
      version: positive_integer(value(entry, :version)) || @version,
      entry_id:
        optional_string(entry, :entry_id) ||
          fingerprint(%{
            project_id: project_id,
            request_fingerprint: optional_string(request, :request_fingerprint),
            evaluated_at: evaluated_at,
            operation_results: operation_results
          }),
      project_id: project_id,
      provider_scope: provider_scope_snapshot(value(entry, :provider_scope) || value(request, :provider_scope) || %{}),
      request: request,
      evaluated_at: evaluated_at,
      requested_operations:
        first_non_empty_operation_list(
          value(entry, :requested_operations),
          value(request, :requested_operations)
        ),
      operation_results: operation_results,
      reason_codes: string_list(value(entry, :reason_codes)),
      required_operator_actions: action_snapshots(value(entry, :required_operator_actions)),
      safe_evidence: safe_evidence,
      source: safe_status(value(entry, :source)) |> blank_to_default("history"),
      malformed_history_entry: value(entry, :malformed_history_entry) == true,
      dry_run_only: value(entry, :dry_run_only) != false,
      no_side_effects: value(entry, :no_side_effects) != false
    }

    %{snapshot | requested_operations: requested_operations(snapshot)}
  end

  defp history_entry_snapshot(_entry, now) do
    history_entry_snapshot(malformed_history_entry(now, ""), now)
  end

  defp request_snapshot(request, now) when is_map(request) do
    operator_intent = value(request, :operator_intent) || value(request, :intent) || request
    project_snapshot = value(request, :project_snapshot) || value(request, :safe_project_snapshot)

    %{
      request_id: optional_string(request, :request_id) || optional_string(request, :id),
      request_fingerprint: optional_string(request, :request_fingerprint),
      project_id: optional_string(request, :project_id),
      source: safe_status(value(request, :source)) |> blank_to_default("unknown"),
      requested_at: iso8601(value(request, :requested_at)) || now,
      requested_operations: operation_list(value(request, :requested_operations) || value(request, :operations)),
      activation_plan: plan_snapshot(value(request, :activation_plan) || request),
      cutover_gate: gate_snapshot(value(request, :cutover_gate) || request),
      operator_intent: operator_intent_snapshot(operator_intent),
      project_snapshot: project_snapshot_evidence(project_snapshot),
      provider_scope: provider_scope_snapshot(value(request, :provider_scope) || value(request, :provider) || %{})
    }
    |> compact_map()
    |> ensure_request_fingerprint()
  end

  defp request_snapshot(_request, now), do: request_snapshot(%{source: "malformed", requested_at: now}, now)

  defp operation_result_snapshot(result) when is_map(result) do
    %{
      operation: operation_name(value(result, :operation)),
      decision: operation_decision(value(result, :decision)),
      reason_codes: string_list(value(result, :reason_codes)),
      required_operator_actions: action_snapshots(value(result, :required_operator_actions)),
      safe_evidence: safe_evidence_snapshot(value(result, :safe_evidence) || %{}),
      dry_run_only: value(result, :dry_run_only) != false
    }
  end

  defp operation_result_snapshot(result), do: operation_result_snapshot(%{operation: result})

  defp project_summary(project_id, entries, attention_entries, closeout_index, project_history_limit) do
    project_entries =
      entries
      |> Enum.filter(&(required_string(&1, :project_id) == project_id))
      |> Enum.sort_by(&sort_time(&1.evaluated_at), :desc)

    project_attention_entries =
      attention_entries
      |> Enum.filter(&(required_string(&1, :project_id) == project_id))
      |> Enum.sort_by(&sort_time(&1.evaluated_at), :desc)

    latest = List.first(project_attention_entries) || List.first(project_entries)
    attention_items = attention_items(project_attention_entries)
    closed_ids = closeout_index.closed_item_ids
    unresolved_items = Enum.reject(attention_items, &MapSet.member?(closed_ids, &1.item_id))

    project_closeouts =
      closeout_index.evaluated
      |> Enum.filter(&(required_string(&1, :project_id) == project_id))
      |> Enum.sort_by(&{&1.status, &1.operation, &1.reason_code, &1.required_operator_action_code})

    %{
      version: @version,
      project_id: project_id,
      status: project_status(project_attention_entries ++ project_entries, unresolved_items, project_closeouts),
      provider_scope: latest && latest.provider_scope,
      latest_audit: latest && latest_audit_snapshot(latest),
      history_entries: Enum.take(project_entries, project_history_limit),
      unresolved_manual_attention: unresolved_items,
      closeouts: project_closeouts,
      counts: project_counts(project_entries, unresolved_items, project_closeouts),
      safe_evidence: project_history_evidence(latest, unresolved_items),
      dry_run_only: true,
      no_side_effects: true
    }
    |> project_snapshot()
  end

  defp project_snapshot(project) when is_map(project) do
    closeouts =
      project
      |> list_value(:closeouts)
      |> Enum.map(&evaluated_closeout_snapshot/1)
      |> Enum.sort_by(&{&1.status, &1.operation, &1.reason_code, &1.required_operator_action_code})

    unresolved =
      project
      |> list_value(:unresolved_manual_attention)
      |> Enum.map(&attention_item_snapshot/1)
      |> Enum.sort_by(&{&1.operation, &1.reason_code, &1.required_operator_action_code})

    history_entries =
      project
      |> list_value(:history_entries)
      |> Enum.map(&history_entry_snapshot(&1, iso8601(value(project, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601()))
      |> Enum.sort_by(&sort_time(&1.evaluated_at), :desc)

    %{
      version: positive_integer(value(project, :version)) || @version,
      project_id: required_string(project, :project_id),
      status: project_status(history_entries, unresolved, closeouts, value(project, :status)),
      provider_scope: provider_scope_snapshot(value(project, :provider_scope) || %{}),
      latest_audit: latest_audit_snapshot(value(project, :latest_audit)),
      history_entries: history_entries,
      unresolved_manual_attention: unresolved,
      closeouts: closeouts,
      counts: project_counts(history_entries, unresolved, closeouts),
      safe_evidence: safe_evidence_snapshot(value(project, :safe_evidence) || %{}),
      dry_run_only: value(project, :dry_run_only) != false,
      no_side_effects: value(project, :no_side_effects) != false
    }
  end

  defp project_snapshot(_project), do: project_snapshot(%{})

  defp latest_audit_snapshot(nil), do: nil

  defp latest_audit_snapshot(entry) when is_map(entry) do
    activation_plan = get_in_value(entry, [:request, :activation_plan]) || value(entry, :activation_plan) || %{}
    cutover_gate = get_in_value(entry, [:request, :cutover_gate]) || value(entry, :cutover_gate) || %{}

    %{
      entry_id: optional_string(entry, :entry_id),
      request_id: get_in_value(entry, [:request, :request_id]) || optional_string(entry, :request_id),
      request_fingerprint:
        get_in_value(entry, [:request, :request_fingerprint]) ||
          optional_string(entry, :request_fingerprint),
      requested_operations:
        first_non_empty_operation_list(
          value(entry, :requested_operations),
          get_in_value(entry, [:request, :requested_operations])
        ),
      request_source: get_in_value(entry, [:request, :source]) || optional_string(entry, :request_source),
      requested_at: get_in_value(entry, [:request, :requested_at]) || iso8601(value(entry, :requested_at)),
      evaluated_at: iso8601(value(entry, :evaluated_at)),
      activation_plan: plan_snapshot(activation_plan),
      cutover_gate: gate_snapshot(cutover_gate),
      operation_results:
        entry
        |> list_value(:operation_results)
        |> Enum.map(&operation_result_snapshot/1)
        |> Enum.sort_by(& &1.operation),
      reason_codes: string_list(value(entry, :reason_codes)),
      required_operator_actions: action_snapshots(value(entry, :required_operator_actions)),
      safe_evidence: safe_evidence_snapshot(value(entry, :safe_evidence) || %{}),
      dry_run_only: value(entry, :dry_run_only) != false,
      no_side_effects: value(entry, :no_side_effects) != false
    }
    |> compact_map()
  end

  defp latest_audit_snapshot(_entry), do: nil

  defp attention_items(entries) do
    entries
    |> Enum.flat_map(&entry_attention_items/1)
    |> Enum.uniq_by(& &1.item_id)
  end

  defp entry_attention_items(entry) do
    request = value(entry, :request) || %{}
    plan = value(request, :activation_plan) || %{}
    gate = value(request, :cutover_gate) || %{}

    entry
    |> list_value(:operation_results)
    |> Enum.filter(&(value(&1, :decision) in @operation_attention_decisions))
    |> Enum.flat_map(fn operation ->
      operation_evidence = operation_evidence(entry, operation)
      evidence_fingerprint = fingerprint(operation_evidence)
      reason_codes = string_list(value(operation, :reason_codes)) |> default_if_empty("operation_#{value(operation, :decision)}")
      action_codes = action_codes(value(operation, :required_operator_actions)) |> default_if_empty("no_required_action_code")

      for reason_code <- reason_codes, action_code <- action_codes do
        attention_item_snapshot(%{
          project_id: required_string(entry, :project_id),
          request_fingerprint: optional_string(request, :request_fingerprint),
          activation_plan_fingerprint: plan_fingerprint(plan),
          cutover_gate_fingerprint: gate_fingerprint(gate),
          evidence_fingerprint: evidence_fingerprint,
          operation: operation_name(value(operation, :operation)),
          operation_decision: operation_decision(value(operation, :decision)),
          reason_code: reason_code,
          required_operator_action_code: action_code,
          safe_evidence: operation_evidence,
          dry_run_only: true,
          no_side_effects: true
        })
      end
    end)
  end

  defp attention_item_snapshot(item) when is_map(item) do
    snapshot = %{
      project_id: required_string(item, :project_id),
      request_fingerprint: optional_string(item, :request_fingerprint),
      activation_plan_fingerprint: optional_string(item, :activation_plan_fingerprint),
      cutover_gate_fingerprint: optional_string(item, :cutover_gate_fingerprint),
      evidence_fingerprint: optional_string(item, :evidence_fingerprint),
      operation: operation_name(value(item, :operation)),
      operation_decision: operation_decision(value(item, :operation_decision)),
      reason_code: safe_status(value(item, :reason_code)) |> blank_to_default("unknown_reason"),
      required_operator_action_code:
        safe_status(value(item, :required_operator_action_code))
        |> blank_to_default("no_required_action_code"),
      safe_evidence: safe_evidence_snapshot(value(item, :safe_evidence) || %{}),
      dry_run_only: value(item, :dry_run_only) != false,
      no_side_effects: value(item, :no_side_effects) != false
    }

    Map.put(snapshot, :item_id, optional_string(item, :item_id) || binding_fingerprint(snapshot))
  end

  defp attention_item_snapshot(_item), do: attention_item_snapshot(%{})

  defp attention_entries(current_entries, limited_entries) do
    source =
      case current_entries do
        [] -> limited_entries
        entries -> entries
      end

    source
  end

  defp closeout_list(nil, _now), do: []

  defp closeout_list(%{} = closeouts, now) do
    closeouts
    |> Map.get(:closeouts, Map.get(closeouts, "closeouts", [closeouts]))
    |> closeout_list(now)
  end

  defp closeout_list(closeouts, now) when is_list(closeouts), do: Enum.map(closeouts, &closeout_snapshot(&1, now))
  defp closeout_list(closeout, now), do: [closeout_snapshot(closeout, now)]

  defp closeout_snapshot(closeout, now) when is_map(closeout) do
    %{
      version: positive_integer(value(closeout, :version)) || @version,
      closeout_id: optional_string(closeout, :closeout_id) || optional_string(closeout, :id),
      project_id: optional_string(closeout, :project_id),
      request_fingerprint: optional_string(closeout, :request_fingerprint),
      activation_plan_fingerprint:
        optional_string(closeout, :activation_plan_fingerprint) ||
          optional_string(closeout, :plan_fingerprint),
      cutover_gate_fingerprint:
        optional_string(closeout, :cutover_gate_fingerprint) ||
          optional_string(closeout, :gate_fingerprint),
      evidence_fingerprint: optional_string(closeout, :evidence_fingerprint),
      operation: operation_name(value(closeout, :operation)) |> blank_to_default("unknown_operation"),
      reason_code: safe_status(value(closeout, :reason_code)) |> blank_to_default(nil),
      required_operator_action_code:
        safe_status(value(closeout, :required_operator_action_code) || value(closeout, :action_code))
        |> blank_to_default(nil),
      decision: closeout_decision(value(closeout, :decision) || value(closeout, :closeout_decision)),
      source: safe_status(value(closeout, :source)) |> blank_to_default("operator-file"),
      decided_at:
        iso8601(value(closeout, :decided_at) || value(closeout, :closed_at) || value(closeout, :created_at)) ||
          now,
      operator_note_digest:
        value(closeout, :operator_note_digest) ||
          value(closeout, :note_digest) ||
          note_digest(value(closeout, :operator_note) || value(closeout, :note)),
      safe_evidence: safe_evidence_snapshot(value(closeout, :safe_evidence) || %{})
    }
    |> ensure_closeout_id()
  end

  defp closeout_snapshot(_closeout, now) do
    closeout_snapshot(%{decision: "malformed", source: "malformed", decided_at: now}, now)
  end

  defp evaluate_closeouts(closeouts, entries) do
    attention_items = attention_items(entries)
    items_by_id = Map.new(attention_items, &{&1.item_id, &1})

    evaluated =
      closeouts
      |> Enum.map(&evaluate_closeout(&1, attention_items, items_by_id))
      |> Enum.uniq_by(& &1.closeout_id)

    closed_item_ids =
      evaluated
      |> Enum.filter(&(&1.status == "closed"))
      |> Enum.map(& &1.item_id)
      |> Enum.reject(&blank?/1)
      |> MapSet.new()

    %{evaluated: evaluated, closed_item_ids: closed_item_ids, attention_items: attention_items}
  end

  defp evaluate_closeout(closeout, attention_items, items_by_id) do
    validation = closeout_validation(closeout)

    cond do
      validation != [] ->
        evaluated_closeout_snapshot(Map.merge(closeout, %{status: validation_status(validation), status_reasons: validation, item_id: nil}))

      match = exact_closeout_match(closeout, items_by_id) ->
        status = exact_closeout_status(closeout)
        evaluated_closeout_snapshot(Map.merge(closeout, %{status: status, status_reasons: [], item_id: match.item_id}))

      stale_reasons = stale_reasons(closeout, attention_items) ->
        evaluated_closeout_snapshot(Map.merge(closeout, %{status: "stale", status_reasons: stale_reasons, item_id: nil}))

      true ->
        evaluated_closeout_snapshot(Map.merge(closeout, %{status: "conflict", status_reasons: ["unknown_reason_action"], item_id: nil}))
    end
  end

  defp evaluated_closeout_snapshot(closeout) when is_map(closeout) do
    operator_note_digest =
      closeout
      |> value(:operator_note_digest)
      |> Kernel.||(%{})
      |> SafeSummary.sanitize_map(output_keys: :preserve)

    %{
      version: positive_integer(value(closeout, :version)) || @version,
      closeout_id: optional_string(closeout, :closeout_id) || fingerprint(closeout),
      project_id: optional_string(closeout, :project_id) || "",
      request_fingerprint: optional_string(closeout, :request_fingerprint),
      activation_plan_fingerprint: optional_string(closeout, :activation_plan_fingerprint),
      cutover_gate_fingerprint: optional_string(closeout, :cutover_gate_fingerprint),
      evidence_fingerprint: optional_string(closeout, :evidence_fingerprint),
      operation: operation_name(value(closeout, :operation)),
      reason_code: safe_status(value(closeout, :reason_code)) |> blank_to_default("unknown_reason"),
      required_operator_action_code:
        safe_status(value(closeout, :required_operator_action_code))
        |> blank_to_default("no_required_action_code"),
      decision: closeout_decision(value(closeout, :decision)),
      status: closeout_status(value(closeout, :status)),
      status_reasons: string_list(value(closeout, :status_reasons)),
      item_id: optional_string(closeout, :item_id),
      source: safe_status(value(closeout, :source)) |> blank_to_default("operator-file"),
      decided_at: iso8601(value(closeout, :decided_at)),
      operator_note_digest: operator_note_digest,
      safe_evidence: safe_evidence_snapshot(value(closeout, :safe_evidence) || %{}),
      dry_run_only: true,
      no_side_effects: true
    }
    |> compact_map()
  end

  defp evaluated_closeout_snapshot(_closeout), do: evaluated_closeout_snapshot(%{})

  defp closeout_validation(closeout) do
    []
    |> add_validation(optional_string(closeout, :project_id) in [nil, ""], "project_id_missing")
    |> add_validation(optional_string(closeout, :request_fingerprint) in [nil, ""], "request_fingerprint_missing")
    |> add_validation(optional_string(closeout, :activation_plan_fingerprint) in [nil, ""], "activation_plan_fingerprint_missing")
    |> add_validation(optional_string(closeout, :cutover_gate_fingerprint) in [nil, ""], "cutover_gate_fingerprint_missing")
    |> add_validation(optional_string(closeout, :evidence_fingerprint) in [nil, ""], "evidence_fingerprint_missing")
    |> add_validation(operation_name(value(closeout, :operation)) not in @operations, "unknown_operation")
    |> add_validation(safe_status(value(closeout, :reason_code)) == "", "reason_code_missing")
    |> add_validation(safe_status(value(closeout, :required_operator_action_code)) == "", "required_operator_action_code_missing")
    |> add_validation(closeout_decision(value(closeout, :decision)) not in @closeout_decisions, "unsupported_decision")
    |> add_validation(safe_status(value(closeout, :source)) not in @sources, "unsupported_source")
  end

  defp add_validation(reasons, true, code), do: [code | reasons]
  defp add_validation(reasons, _condition, _code), do: reasons

  defp validation_status(reasons) do
    if Enum.any?(reasons, &(&1 in ["unknown_operation", "unsupported_decision", "unsupported_source"])) do
      "unsupported"
    else
      "malformed"
    end
  end

  defp exact_closeout_match(closeout, items_by_id) do
    key = binding_fingerprint(closeout)
    Map.get(items_by_id, key)
  end

  defp exact_closeout_status(closeout) do
    case closeout_decision(value(closeout, :decision)) do
      decision when decision in @closing_decisions -> "closed"
      "deferred" -> "deferred"
      "stale" -> "stale"
      "conflict" -> "conflict"
      "malformed" -> "malformed"
      "unsupported" -> "unsupported"
      _decision -> "conflict"
    end
  end

  defp stale_reasons(closeout, attention_items) do
    similar =
      Enum.filter(attention_items, fn item ->
        item.project_id == required_string(closeout, :project_id) and
          item.operation == operation_name(value(closeout, :operation)) and
          item.reason_code == safe_status(value(closeout, :reason_code)) |> blank_to_default("unknown_reason") and
          item.required_operator_action_code ==
            safe_status(value(closeout, :required_operator_action_code)) |> blank_to_default("no_required_action_code")
      end)

    if similar == [] do
      nil
    else
      current = List.first(similar)

      [
        fingerprint_mismatch(closeout, current, :request_fingerprint, "request_fingerprint_mismatch"),
        fingerprint_mismatch(closeout, current, :activation_plan_fingerprint, "activation_plan_fingerprint_mismatch"),
        fingerprint_mismatch(closeout, current, :cutover_gate_fingerprint, "cutover_gate_fingerprint_mismatch"),
        fingerprint_mismatch(closeout, current, :evidence_fingerprint, "evidence_fingerprint_mismatch")
      ]
      |> Enum.reject(&is_nil/1)
      |> default_if_empty("bound_evidence_changed")
    end
  end

  defp fingerprint_mismatch(closeout, item, key, reason) do
    if optional_string(closeout, key) != optional_string(item, key), do: reason
  end

  defp closed_item_ids(closeouts) do
    closeouts
    |> Enum.filter(&(&1.status == "closed"))
    |> Enum.map(& &1.item_id)
    |> Enum.reject(&blank?/1)
    |> MapSet.new()
  end

  defp project_status(entries, unresolved_items, closeouts, explicit_status \\ nil) do
    explicit = safe_status(explicit_status)

    cond do
      explicit in @statuses -> explicit
      Enum.any?(closeouts, &(&1.status == "malformed")) -> "malformed"
      Enum.any?(closeouts, &(&1.status == "unsupported")) -> "unsupported"
      Enum.any?(closeouts, &(&1.status == "conflict")) -> "conflict"
      Enum.any?(closeouts, &(&1.status == "stale")) -> "stale"
      unresolved_items != [] -> "unresolved_manual_attention"
      Enum.any?(closeouts, &(&1.status == "deferred")) -> "deferred"
      Enum.any?(closeouts, &(&1.status == "closed")) -> "closed"
      entries != [] -> "history_ready"
      true -> "no_history"
    end
  end

  defp overall_status(projects, closeout_index) do
    cond do
      Enum.any?(projects, &(&1.status == "summary_error")) -> "summary_error"
      Enum.any?(closeout_index.evaluated, &(&1.status == "malformed")) -> "malformed"
      Enum.any?(closeout_index.evaluated, &(&1.status == "unsupported")) -> "unsupported"
      Enum.any?(closeout_index.evaluated, &(&1.status == "conflict")) -> "conflict"
      Enum.any?(closeout_index.evaluated, &(&1.status == "stale")) -> "stale"
      Enum.any?(projects, &(&1.counts.unresolved_manual_attention_count > 0)) -> "unresolved_manual_attention"
      Enum.any?(closeout_index.evaluated, &(&1.status == "deferred")) -> "deferred"
      Enum.any?(closeout_index.evaluated, &(&1.status == "closed")) -> "closed"
      Enum.any?(projects, &(&1.counts.history_entry_count > 0)) -> "history_ready"
      true -> "no_history"
    end
  end

  defp normalize_status(status, projects, closeouts) do
    normalized = safe_status(status)

    if normalized in @statuses do
      normalized
    else
      overall_status(projects, %{evaluated: closeouts})
    end
  end

  defp project_counts(entries, unresolved_items, closeouts) do
    %{
      history_entry_count: length(entries),
      unresolved_manual_attention_count: length(unresolved_items),
      closed_count: Enum.count(closeouts, &(&1.status == "closed")),
      deferred_count: Enum.count(closeouts, &(&1.status == "deferred")),
      stale_count: Enum.count(closeouts, &(&1.status == "stale")),
      conflict_count: Enum.count(closeouts, &(&1.status == "conflict")),
      malformed_count: Enum.count(closeouts, &(&1.status == "malformed")),
      unsupported_count: Enum.count(closeouts, &(&1.status == "unsupported")),
      operation_decision_counts: operation_decision_counts(entries)
    }
  end

  defp count_snapshot(counts, projects, closeout_index) when is_map(counts) do
    closeouts = Map.get(closeout_index, :evaluated, [])

    %{
      project_count: non_negative_integer(value(counts, :project_count)) || length(projects),
      history_entry_count:
        non_negative_integer(value(counts, :history_entry_count)) ||
          Enum.reduce(projects, 0, &(&2 + &1.counts.history_entry_count)),
      unresolved_manual_attention_count:
        non_negative_integer(value(counts, :unresolved_manual_attention_count)) ||
          Enum.reduce(projects, 0, &(&2 + &1.counts.unresolved_manual_attention_count)),
      closed_count: non_negative_integer(value(counts, :closed_count)) || Enum.count(closeouts, &(&1.status == "closed")),
      deferred_count: non_negative_integer(value(counts, :deferred_count)) || Enum.count(closeouts, &(&1.status == "deferred")),
      stale_count: non_negative_integer(value(counts, :stale_count)) || Enum.count(closeouts, &(&1.status == "stale")),
      conflict_count: non_negative_integer(value(counts, :conflict_count)) || Enum.count(closeouts, &(&1.status == "conflict")),
      malformed_count: non_negative_integer(value(counts, :malformed_count)) || Enum.count(closeouts, &(&1.status == "malformed")),
      unsupported_count: non_negative_integer(value(counts, :unsupported_count)) || Enum.count(closeouts, &(&1.status == "unsupported")),
      summary_error_count: non_negative_integer(value(counts, :summary_error_count)) || Enum.count(projects, &(&1.status == "summary_error")),
      no_history_count: non_negative_integer(value(counts, :no_history_count)) || Enum.count(projects, &(&1.status == "no_history")),
      dry_run_only_count:
        non_negative_integer(value(counts, :dry_run_only_count)) ||
          Enum.count(projects, &(&1.dry_run_only == true and &1.no_side_effects == true))
    }
  end

  defp operation_decision_counts(entries) do
    base = %{
      would_allow: 0,
      would_block: 0,
      manual_attention: 0,
      unsupported: 0
    }

    Enum.reduce(entries, base, fn entry, acc ->
      entry
      |> list_value(:operation_results)
      |> Enum.reduce(acc, fn operation, inner ->
        key =
          case operation_decision(value(operation, :decision)) do
            "would_allow" -> :would_allow
            "manual_attention" -> :manual_attention
            "unsupported" -> :unsupported
            _decision -> :would_block
          end

        Map.update!(inner, key, &(&1 + 1))
      end)
    end)
  end

  defp limit_project_history_entries(projects, limits) do
    observed_input_count = Enum.reduce(projects, 0, &(&2 + length(list_value(&1, :history_entries))))
    input_count = max(non_negative_integer(value(limits, :input_history_entry_count)) || 0, observed_input_count)

    per_project_limit =
      positive_integer(value(limits, :max_history_entries_per_project)) || @default_project_history_limit

    global_limit = positive_integer(value(limits, :max_history_entries)) || @default_history_limit

    entries_with_project =
      projects
      |> Enum.flat_map(fn project ->
        project
        |> list_value(:history_entries)
        |> Enum.take(per_project_limit)
        |> Enum.map(&{project.project_id, &1})
      end)
      |> Enum.sort_by(fn {_project_id, entry} -> sort_time(value(entry, :evaluated_at)) end, :desc)

    retained_ids =
      entries_with_project
      |> Enum.take(global_limit)
      |> Enum.map(fn {project_id, entry} -> {project_id, entry.entry_id} end)
      |> MapSet.new()

    projects =
      Enum.map(projects, fn project ->
        history_entries =
          project
          |> list_value(:history_entries)
          |> Enum.filter(&MapSet.member?(retained_ids, {project.project_id, &1.entry_id}))
          |> Enum.sort_by(&sort_time(&1.evaluated_at), :desc)

        closeouts = list_value(project, :closeouts)
        unresolved = list_value(project, :unresolved_manual_attention)

        %{
          project
          | history_entries: history_entries,
            counts: project_counts(history_entries, unresolved, closeouts)
        }
      end)

    retained_count = Enum.reduce(projects, 0, &(&2 + length(&1.history_entries)))

    limits =
      limits
      |> Map.put(:input_history_entry_count, input_count)
      |> Map.put(:truncated, value(limits, :truncated) == true or input_count > retained_count)

    {projects, limits}
  end

  defp limits_snapshot(limits, projects) when is_map(limits) do
    %{
      max_history_entries: positive_integer(value(limits, :max_history_entries)) || @default_history_limit,
      max_history_entries_per_project:
        positive_integer(value(limits, :max_history_entries_per_project)) ||
          @default_project_history_limit,
      truncated: value(limits, :truncated) == true,
      input_history_entry_count:
        non_negative_integer(value(limits, :input_history_entry_count)) ||
          Enum.reduce(projects, 0, &(&2 + &1.counts.history_entry_count))
    }
  end

  defp limits_snapshot(_limits, projects), do: limits_snapshot(%{}, projects)

  defp project_history_evidence(nil, _unresolved), do: %{}

  defp project_history_evidence(latest, unresolved) do
    %{
      latest_entry_id: latest.entry_id,
      latest_request_fingerprint: get_in_value(latest, [:request, :request_fingerprint]),
      unresolved_item_ids: Enum.map(unresolved, & &1.item_id),
      dry_run_only: true,
      no_side_effects: true
    }
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

  defp operation_evidence(entry, operation) do
    %{
      entry_id: optional_string(entry, :entry_id),
      request: %{
        request_fingerprint: get_in_value(entry, [:request, :request_fingerprint]),
        request_id: get_in_value(entry, [:request, :request_id]),
        source: get_in_value(entry, [:request, :source])
      },
      activation_plan: plan_snapshot(get_in_value(entry, [:request, :activation_plan]) || %{}),
      cutover_gate: gate_snapshot(get_in_value(entry, [:request, :cutover_gate]) || %{}),
      operation: operation_name(value(operation, :operation)),
      operation_decision: operation_decision(value(operation, :decision)),
      operation_evidence: safe_evidence_snapshot(value(operation, :safe_evidence) || %{}),
      entry_evidence: safe_evidence_snapshot(value(entry, :safe_evidence) || %{}),
      dry_run_only: true,
      no_side_effects: true
    }
    |> SafeSummary.sanitize_map(output_keys: :preserve)
  end

  defp project_ids(entries, closeouts, audit) do
    [
      Enum.map(entries, &required_string(&1, :project_id)),
      Enum.map(closeouts, &required_string(&1, :project_id)),
      audit |> list_value(:projects) |> Enum.map(&required_string(&1, :project_id))
    ]
    |> List.flatten()
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp entry_list(nil, _now), do: []

  defp entry_list(%{} = entries, now) do
    cond do
      is_list(value(entries, :history_entries)) ->
        entry_list(value(entries, :history_entries), now)

      is_list(value(entries, :entries)) ->
        entry_list(value(entries, :entries), now)

      is_list(value(entries, :projects)) ->
        entries
        |> list_value(:projects)
        |> Enum.flat_map(&nested_project_history_entries(&1, now))

      true ->
        [entries]
    end
  end

  defp entry_list(entries, _now) when is_list(entries), do: entries
  defp entry_list(entry, now), do: [history_entry_snapshot(entry, now)]

  defp nested_project_history_entries(project, now) when is_map(project) do
    project_id = required_string(project, :project_id)

    project
    |> list_value(:history_entries)
    |> Enum.map(&history_entry_with_project_id(&1, project_id, now))
  end

  defp nested_project_history_entries(project, now) do
    [malformed_history_entry(now, optional_string(project) || "")]
  end

  defp history_entry_with_project_id(entry, project_id, _now) when is_map(entry) do
    Map.put(entry, :project_id, optional_string(entry, :project_id) || project_id)
  end

  defp history_entry_with_project_id(_entry, project_id, now), do: malformed_history_entry(now, project_id)

  defp malformed_history_entry(now, project_id) do
    %{
      project_id: project_id,
      evaluated_at: now,
      operation_results: [
        %{
          operation: "poll",
          decision: "manual_attention",
          reason_codes: ["malformed_history_entry"],
          required_operator_actions: [%{code: "fix_cutover_audit_history"}]
        }
      ],
      source: "malformed",
      reason_codes: ["malformed_history_entry"],
      required_operator_actions: [%{code: "fix_cutover_audit_history"}],
      malformed_history_entry: true
    }
  end

  defp requested_operations(entry) do
    operations = operation_list(value(entry, :requested_operations))

    case operations do
      [] ->
        entry
        |> list_value(:operation_results)
        |> Enum.map(&operation_name(value(&1, :operation)))
        |> Enum.reject(&blank?/1)
        |> Enum.uniq()
        |> Enum.sort()

      _operations ->
        operations
    end
  end

  defp provider_scope_from_request_or_evidence(request, evidence) do
    request_scope = provider_scope_snapshot(value(request, :provider_scope) || %{})

    if request_scope == %{} do
      provider_scope_snapshot(%{
        provider_scope_key: get_in_value(evidence, [:project, :provider_scope_key]),
        kind: get_in_value(evidence, [:project, :provider_kind])
      })
    else
      request_scope
    end
  end

  defp provider_scope_snapshot(scope) when is_map(scope) do
    %{
      kind: optional_string(scope, :kind),
      provider_scope_key: optional_string(scope, :provider_scope_key) || optional_string(scope, :key),
      scope: SafeSummary.sanitize_map(value(scope, :scope) || %{}, output_keys: :preserve)
    }
    |> compact_map()
  end

  defp provider_scope_snapshot(_scope), do: %{}

  defp plan_snapshot(plan) when is_map(plan) do
    %{
      plan_id: optional_string(plan, :plan_id) || optional_string(plan, :activation_plan_id),
      fingerprint:
        optional_string(plan, :fingerprint) ||
          optional_string(plan, :plan_fingerprint) ||
          optional_string(plan, :activation_plan_fingerprint) ||
          optional_string(plan, :plan_id),
      status: safe_status(value(plan, :status))
    }
    |> compact_map()
  end

  defp plan_snapshot(_plan), do: %{}

  defp gate_snapshot(gate) when is_map(gate) do
    %{
      decision: safe_status(value(gate, :decision) || value(gate, :cutover_gate_decision)),
      fingerprint:
        optional_string(gate, :fingerprint) ||
          optional_string(gate, :cutover_gate_fingerprint) ||
          optional_string(gate, :staged_ownership_record_id),
      staged_ownership_record_id:
        optional_string(gate, :staged_ownership_record_id) ||
          get_in_value(gate, [:staged_ownership_record, :record_id])
    }
    |> compact_map()
  end

  defp gate_snapshot(_gate), do: %{}

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

  defp operator_intent_snapshot(intent) when is_map(intent) do
    %{
      action_codes: string_list(value(intent, :action_codes) || value(intent, :operator_action_codes)),
      risk_codes: string_list(value(intent, :risk_codes) || value(intent, :operator_risk_codes)),
      note_digest:
        value(intent, :note_digest) ||
          note_digest(value(intent, :note) || value(intent, :operator_note))
    }
    |> compact_map()
  end

  defp operator_intent_snapshot(_intent), do: %{}

  defp ensure_request_fingerprint(request) do
    Map.put(request, :request_fingerprint, optional_string(request, :request_fingerprint) || fingerprint(Map.drop(request, [:request_id])))
  end

  defp ensure_closeout_id(closeout) do
    Map.put(closeout, :closeout_id, optional_string(closeout, :closeout_id) || fingerprint(Map.drop(closeout, [:closeout_id])))
  end

  defp plan_fingerprint(plan), do: optional_string(plan, :fingerprint) || optional_string(plan, :plan_id)
  defp gate_fingerprint(gate), do: optional_string(gate, :fingerprint) || optional_string(gate, :staged_ownership_record_id)

  defp binding_fingerprint(binding) do
    fingerprint(%{
      project_id: required_string(binding, :project_id),
      request_fingerprint: optional_string(binding, :request_fingerprint),
      activation_plan_fingerprint: optional_string(binding, :activation_plan_fingerprint),
      cutover_gate_fingerprint: optional_string(binding, :cutover_gate_fingerprint),
      evidence_fingerprint: optional_string(binding, :evidence_fingerprint),
      operation: operation_name(value(binding, :operation)),
      reason_code: safe_status(value(binding, :reason_code)) |> blank_to_default("unknown_reason"),
      required_operator_action_code:
        safe_status(value(binding, :required_operator_action_code))
        |> blank_to_default("no_required_action_code")
    })
  end

  defp action_snapshots(actions) when is_list(actions) do
    actions
    |> action_codes()
    |> Enum.map(&%{code: &1, label: String.replace(&1, "_", " ")})
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

  defp first_non_empty_operation_list(first, second) do
    case operation_list(first) do
      [] -> operation_list(second)
      operations -> operations
    end
  end

  defp operation_name(value) do
    case safe_status(value) do
      "candidate_scan" -> "poll"
      "worker_start" -> "worker_start"
      "worker-start" -> "worker_start"
      "provider_writeback" -> "writeback"
      other -> other
    end
  end

  defp operation_decision(value) do
    case safe_status(value) do
      "would_allow" -> "would_allow"
      "manual_attention" -> "manual_attention"
      "unsupported" -> "unsupported"
      _decision -> "would_block"
    end
  end

  defp closeout_decision(value) do
    decision = safe_status(value)
    if decision in @closeout_decisions, do: decision, else: decision
  end

  defp closeout_status(value) do
    status = safe_status(value)
    if status in @closeout_statuses, do: status, else: "conflict"
  end

  defp note_digest(note) when is_binary(note) do
    trimmed = String.trim(note)

    if trimmed == "" do
      %{}
    else
      %{sha256: fingerprint(trimmed), bytes: byte_size(trimmed)}
    end
  end

  defp note_digest(_note), do: %{}

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

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      {:error, _reason} -> optional_string(value)
    end
  end

  defp iso8601(_value), do: nil

  defp sort_time(nil), do: ""
  defp sort_time(value), do: value

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

  defp default_if_empty([], default), do: [default]
  defp default_if_empty(values, _default), do: values

  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp fingerprint(payload) do
    :crypto.hash(:sha256, :erlang.term_to_binary(payload))
    |> Base.encode16(case: :lower)
  end
end
