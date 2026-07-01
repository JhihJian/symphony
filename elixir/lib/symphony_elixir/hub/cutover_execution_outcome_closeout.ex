defmodule SymphonyElixir.Hub.CutoverExecutionOutcomeCloseout do
  @moduledoc """
  Hub cutover execution outcome closeout baseline.

  This model records operator-controlled resolution attempts for unresolved
  cutover execution outcomes. It is read-only: it never calls providers,
  dispatches work, starts workers, writes back, operates systemd, or edits
  Hub/project configuration.
  """

  alias SymphonyElixir.Hub.{CutoverExecutionOutcomeLedger, SafeSummary}

  @version 1
  @operations ["poll", "dispatch", "worker_start", "writeback"]
  @sources ["candidate_scan", "dispatch_application", "worker_start_handoff", "writeback_executor"]
  @resolution_codes [
    "confirmed_resolved",
    "confirmed_failed",
    "abandoned_no_retry",
    "allow_explicit_retry_consideration",
    "requires_follow_up"
  ]
  @closing_resolution_codes ["confirmed_resolved", "confirmed_failed", "abandoned_no_retry"]
  @retry_resolution_codes ["allow_explicit_retry_consideration"]
  @operator_sources ["operator_file", "operator_cli", "test", "api", "hub_startup_option", "operator"]
  @record_statuses ["resolved", "stale", "conflict", "manual_attention", "malformed", "unsupported"]
  @statuses ["no_outcome", "no_closeout" | @record_statuses]
  @unresolved_statuses ["unknown", "manual_attention"]
  @default_recent_limit 20

  @type request :: map()
  @type record :: map()
  @type summary :: map()

  @spec build(term(), keyword()) :: summary()
  def build(sources, opts \\ []) when is_list(opts) do
    now =
      opts
      |> Keyword.get(:now)
      |> Kernel.||(value(sources, :generated_at))
      |> Kernel.||(DateTime.utc_now())
      |> iso8601()

    outcome_ledger =
      sources
      |> value(:cutover_execution_outcome_ledger)
      |> Kernel.||(value(sources, :hub_cutover_execution_outcome_ledger))
      |> Kernel.||(%{})
      |> CutoverExecutionOutcomeLedger.to_snapshot()

    requests =
      opts
      |> Keyword.get(:closeouts, value(sources, :execution_outcome_closeouts))
      |> closeout_list(now)

    unresolved = list_value(outcome_ledger, :unresolved_outcomes)
    outcomes = all_outcomes(outcome_ledger)
    context = %{outcome_ledger: outcome_ledger, unresolved: unresolved, outcomes: outcomes, generated_at: now}

    records =
      requests
      |> Enum.map(&record_snapshot(&1, context))
      |> Enum.uniq_by(& &1.closeout_record_fingerprint)
      |> Enum.sort_by(&record_sort_key/1)

    project_ids =
      [
        project_ids_from(outcome_ledger),
        Enum.map(requests, &optional_string(&1, :project_id))
      ]
      |> List.flatten()
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.sort()

    projects =
      project_ids
      |> Enum.map(&project_summary(&1, outcome_ledger, records))
      |> Enum.sort_by(& &1.project_id)

    %{
      version: @version,
      generated_at: now,
      status: overall_status(unresolved, records),
      no_side_effects: true,
      auto_replay_allowed: false,
      counts: count_snapshot(%{}, projects, records, unresolved),
      recent_closeouts: Enum.take(records, @default_recent_limit),
      projects: projects
    }
    |> to_snapshot()
  end

  @spec to_snapshot(term()) :: summary()
  def to_snapshot(summary) when is_map(summary) do
    records =
      summary
      |> list_value(:recent_closeouts)
      |> Enum.map(&record_snapshot/1)
      |> Enum.sort_by(&record_sort_key/1)
      |> Enum.take(@default_recent_limit)

    projects =
      summary
      |> list_value(:projects)
      |> Enum.map(&project_snapshot/1)
      |> Enum.sort_by(& &1.project_id)

    unresolved =
      projects
      |> Enum.flat_map(&list_value(&1, :unresolved_outcomes))
      |> Enum.uniq_by(&outcome_binding_id/1)

    generated_at = iso8601(value(summary, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      version: positive_integer(value(summary, :version)) || @version,
      generated_at: generated_at,
      status: normalize_status(value(summary, :status), unresolved, records),
      no_side_effects: value(summary, :no_side_effects) != false,
      auto_replay_allowed: false,
      counts: count_snapshot(value(summary, :counts), projects, records, unresolved),
      recent_closeouts: records,
      projects: projects
    }
  end

  def to_snapshot(_summary), do: to_snapshot(%{})

  @spec observability_snapshot(term()) :: summary() | nil
  def observability_snapshot(nil), do: nil
  def observability_snapshot(summary) when is_map(summary), do: to_snapshot(summary)
  def observability_snapshot(_summary), do: nil

  @spec closeout_request_snapshot(term()) :: request()
  def closeout_request_snapshot(request) do
    request
    |> closeout_snapshot(DateTime.utc_now() |> DateTime.to_iso8601())
    |> Map.delete(:status)
    |> Map.delete(:status_reasons)
  end

  @spec retry_consideration_allowed?(term(), term()) :: boolean()
  def retry_consideration_allowed?(summary, candidate) do
    candidate = CutoverExecutionOutcomeLedger.fact_snapshot(candidate)

    summary
    |> to_snapshot()
    |> list_value(:projects)
    |> Enum.flat_map(&list_value(&1, :closeouts))
    |> Enum.any?(fn closeout ->
      closeout.status == "resolved" and
        closeout.allow_explicit_retry_consideration == true and
        closeout.replay_key == candidate.replay_key
    end)
  end

  defp record_snapshot(record, context) when is_map(record) do
    request = closeout_snapshot(record, context.generated_at)
    validation = closeout_validation(request)
    matching_outcome = matching_unresolved_outcome(request, context.unresolved)
    related_outcomes = related_outcomes(request, context.outcomes)
    status_reasons = status_reasons(request, validation, matching_outcome, related_outcomes)
    status = closeout_status(request, validation, status_reasons, matching_outcome)
    outcome = matching_outcome || List.first(related_outcomes) || %{}
    side_effect_entered = boolean_binding(value(outcome, :side_effect_entered), value(request, :side_effect_entered))

    side_effect_may_have_happened =
      boolean_binding(
        value(outcome, :side_effect_may_have_happened),
        value(request, :side_effect_may_have_happened)
      )

    snapshot =
      request
      |> Map.merge(%{
        status: status,
        status_reasons: status_reasons,
        outcome_status: optional_string(outcome, :status) || request.outcome_status,
        outcome_fingerprint: optional_string(outcome, :evidence_fingerprint) || request.outcome_fingerprint,
        side_effect_entered: side_effect_entered,
        side_effect_may_have_happened: side_effect_may_have_happened,
        outcome_binding_id: if(matching_outcome, do: outcome_binding_id(matching_outcome), else: nil),
        outcome_id: optional_string(outcome, :outcome_id) || request.outcome_id,
        allow_explicit_retry_consideration: status == "resolved" and request.resolution_code in @retry_resolution_codes,
        auto_replay_allowed: false,
        replay_blocked: true,
        no_side_effects: true
      })
      |> ensure_record_fingerprint()
      |> compact_map()

    record_snapshot(snapshot)
  rescue
    _error -> record_snapshot(malformed_closeout(context.generated_at))
  catch
    _kind, _reason -> record_snapshot(malformed_closeout(context.generated_at))
  end

  defp record_snapshot(record) when is_map(record) do
    status = safe_status(value(record, :status)) |> blank_to_default("malformed")

    snapshot =
      %{
        version: positive_integer(value(record, :version)) || @version,
        closeout_id: optional_string(record, :closeout_id) || optional_string(record, :id),
        closeout_record_fingerprint: optional_string(record, :closeout_record_fingerprint),
        project_id: optional_string(record, :project_id) || "",
        provider_scope: provider_scope_snapshot(value(record, :provider_scope) || %{}),
        operation: operation_name(value(record, :operation)),
        side_effect_source: source_name(value(record, :side_effect_source)),
        replay_key: optional_string(record, :replay_key),
        outcome_id: optional_string(record, :outcome_id),
        outcome_binding_id: optional_string(record, :outcome_binding_id),
        outcome_fingerprint:
          optional_string(record, :outcome_fingerprint) ||
            optional_string(record, :evidence_fingerprint),
        outcome_status: outcome_status(value(record, :outcome_status) || value(record, :status_bound)),
        outcome_side_effect: side_effect_snapshot(record),
        cutover_operation_request_fingerprint: optional_string(record, :cutover_operation_request_fingerprint),
        authorization_record_fingerprint: optional_string(record, :authorization_record_fingerprint),
        authorization_request_fingerprint: optional_string(record, :authorization_request_fingerprint),
        readiness_permit_fingerprint: optional_string(record, :readiness_permit_fingerprint),
        readiness_permit_decision: safe_status(value(record, :readiness_permit_decision)),
        cutover_gate_fingerprint: optional_string(record, :cutover_gate_fingerprint),
        dry_run_audit_fingerprint: optional_string(record, :dry_run_audit_fingerprint),
        audit_history_fingerprint: optional_string(record, :audit_history_fingerprint),
        consumption_guard_fingerprint: optional_string(record, :consumption_guard_fingerprint),
        safe_evidence_fingerprints:
          SafeSummary.sanitize_map(value(record, :safe_evidence_fingerprints) || %{},
            output_keys: :preserve
          ),
        resolution_code: resolution_code(value(record, :resolution_code)),
        reason_code: safe_status(value(record, :reason_code)) |> blank_to_default("unknown_reason"),
        action_code: safe_status(value(record, :action_code)) |> blank_to_default("operator_closeout_recorded"),
        operator_request_fingerprint: optional_string(record, :operator_request_fingerprint),
        source: safe_status(value(record, :source)) |> blank_to_default("operator_file"),
        created_at: iso8601(value(record, :created_at)),
        closed_at: iso8601(value(record, :closed_at)),
        status: normalize_record_status(status),
        status_reasons: string_list(value(record, :status_reasons)),
        allow_explicit_retry_consideration: truthy?(value(record, :allow_explicit_retry_consideration)),
        auto_replay_allowed: false,
        replay_blocked: value(record, :replay_blocked) != false,
        operator_note_digest:
          value(record, :operator_note_digest)
          |> Kernel.||(%{})
          |> SafeSummary.sanitize_map(output_keys: :preserve),
        no_side_effects: value(record, :no_side_effects) != false
      }
      |> compact_map()

    snapshot =
      snapshot
      |> Map.put(:operator_request_fingerprint, optional_string(snapshot, :operator_request_fingerprint) || operator_request_fingerprint(snapshot))
      |> Map.put(
        :closeout_id,
        optional_string(snapshot, :closeout_id) ||
          "hub-cutover-execution-outcome-closeout:" <> fingerprint(Map.take(snapshot, [:project_id, :operation, :side_effect_source, :replay_key, :operator_request_fingerprint]))
      )

    Map.put(snapshot, :closeout_record_fingerprint, optional_string(snapshot, :closeout_record_fingerprint) || closeout_record_fingerprint(snapshot))
  end

  defp record_snapshot(_record), do: record_snapshot(malformed_closeout(DateTime.utc_now() |> DateTime.to_iso8601()))

  defp closeout_snapshot(closeout, now) when is_map(closeout) do
    outcome = value(closeout, :outcome) || %{}
    evidence = value(closeout, :safe_evidence_fingerprints) || value(closeout, :evidence_fingerprints) || %{}
    side_effect = value(closeout, :outcome_side_effect) || value(closeout, :side_effect) || closeout

    side_effect_entered =
      boolean_binding(value(side_effect, :side_effect_entered), value(closeout, :side_effect_entered))

    readiness_permit_decision =
      safe_status(value(closeout, :readiness_permit_decision) || value(evidence, :readiness_permit_decision))

    %{
      version: positive_integer(value(closeout, :version)) || @version,
      closeout_id: optional_string(closeout, :closeout_id) || optional_string(closeout, :id),
      project_id: optional_string(closeout, :project_id),
      provider_scope:
        provider_scope_snapshot(
          value(closeout, :provider_scope) ||
            value(closeout, :provider) ||
            value(outcome, :provider_scope) ||
            %{}
        ),
      operation: operation_name(value(closeout, :operation) || value(outcome, :operation)),
      side_effect_source:
        source_name(
          value(closeout, :side_effect_source) ||
            value(closeout, :source_boundary) ||
            value(outcome, :side_effect_source)
        ),
      replay_key: optional_string(closeout, :replay_key) || optional_string(outcome, :replay_key),
      outcome_id: optional_string(closeout, :outcome_id) || optional_string(outcome, :outcome_id),
      outcome_fingerprint:
        optional_string(closeout, :outcome_fingerprint) ||
          optional_string(closeout, :evidence_fingerprint) ||
          optional_string(outcome, :evidence_fingerprint),
      outcome_status: outcome_status(value(closeout, :outcome_status) || value(outcome, :status)),
      side_effect_entered: side_effect_entered,
      side_effect_may_have_happened:
        boolean_binding(
          value(side_effect, :side_effect_may_have_happened),
          value(closeout, :side_effect_may_have_happened)
        ),
      cutover_operation_request_fingerprint:
        optional_string(closeout, :cutover_operation_request_fingerprint) ||
          optional_string(evidence, :cutover_operation_request),
      authorization_record_fingerprint:
        optional_string(closeout, :authorization_record_fingerprint) ||
          optional_string(evidence, :authorization_record),
      authorization_request_fingerprint:
        optional_string(closeout, :authorization_request_fingerprint) ||
          optional_string(evidence, :authorization_request),
      readiness_permit_fingerprint:
        optional_string(closeout, :readiness_permit_fingerprint) ||
          optional_string(evidence, :readiness_permit),
      readiness_permit_decision: readiness_permit_decision,
      cutover_gate_fingerprint:
        optional_string(closeout, :cutover_gate_fingerprint) ||
          optional_string(evidence, :cutover_gate),
      dry_run_audit_fingerprint:
        optional_string(closeout, :dry_run_audit_fingerprint) ||
          optional_string(evidence, :dry_run_audit),
      audit_history_fingerprint:
        optional_string(closeout, :audit_history_fingerprint) ||
          optional_string(evidence, :audit_history),
      consumption_guard_fingerprint:
        optional_string(closeout, :consumption_guard_fingerprint) ||
          optional_string(evidence, :consumption_guard),
      safe_evidence_fingerprints: SafeSummary.sanitize_map(evidence, output_keys: :preserve),
      resolution_code:
        resolution_code(
          value(closeout, :resolution_code) ||
            value(closeout, :resolution) ||
            value(closeout, :decision)
        ),
      reason_code: safe_status(value(closeout, :reason_code) || value(closeout, :reason)),
      action_code: safe_status(value(closeout, :action_code) || value(closeout, :action)),
      operator_request_fingerprint:
        optional_string(closeout, :operator_request_fingerprint) ||
          optional_string(closeout, :request_fingerprint),
      source: safe_status(value(closeout, :source)) |> blank_to_default("operator_file"),
      created_at: iso8601(value(closeout, :created_at) || value(closeout, :requested_at)) || now,
      closed_at: iso8601(value(closeout, :closed_at) || value(closeout, :decided_at)) || now,
      operator_note_digest:
        value(closeout, :operator_note_digest) ||
          value(closeout, :note_digest) ||
          note_digest(value(closeout, :operator_note) || value(closeout, :note)),
      no_side_effects: true
    }
    |> compact_map()
    |> ensure_operator_request_fingerprint()
  end

  defp closeout_snapshot(_closeout, now), do: malformed_closeout(now)

  defp malformed_closeout(now) do
    closeout_snapshot(
      %{
        project_id: "",
        operation: "unknown_operation",
        side_effect_source: "unknown_source",
        resolution_code: "requires_follow_up",
        reason_code: "malformed_closeout",
        action_code: "fix_execution_outcome_closeout",
        source: "operator_file",
        created_at: now,
        closed_at: now
      },
      now
    )
  end

  defp closeout_validation(closeout) do
    []
    |> add_validation(blank?(optional_string(closeout, :project_id)), "project_id_missing", "malformed")
    |> add_validation(operation_name(value(closeout, :operation)) not in @operations, "unknown_operation", "unsupported")
    |> add_validation(source_name(value(closeout, :side_effect_source)) not in @sources, "unsupported_side_effect_source", "unsupported")
    |> add_validation(
      source_operation_mismatch?(value(closeout, :operation), value(closeout, :side_effect_source)),
      "side_effect_source_operation_mismatch",
      "unsupported"
    )
    |> add_validation(blank?(optional_string(closeout, :replay_key)), "replay_key_missing", "malformed")
    |> add_validation(blank?(optional_string(closeout, :outcome_fingerprint)), "outcome_fingerprint_missing", "malformed")
    |> add_validation(blank?(outcome_status(value(closeout, :outcome_status))), "outcome_status_missing", "malformed")
    |> add_validation(
      not blank?(outcome_status(value(closeout, :outcome_status))) and
        outcome_status(value(closeout, :outcome_status)) not in @unresolved_statuses,
      "outcome_status_not_unresolved",
      "conflict"
    )
    |> add_validation(
      value(closeout, :side_effect_entered) not in [true, false] and
        value(closeout, :side_effect_may_have_happened) not in [true, false],
      "side_effect_safety_missing",
      "malformed"
    )
    |> add_validation(blank?(optional_string(closeout, :authorization_record_fingerprint)), "authorization_record_fingerprint_missing", "malformed")
    |> add_validation(blank?(optional_string(closeout, :readiness_permit_fingerprint)), "readiness_permit_fingerprint_missing", "malformed")
    |> add_validation(blank?(optional_string(closeout, :cutover_gate_fingerprint)), "cutover_gate_fingerprint_missing", "malformed")
    |> add_validation(blank?(optional_string(closeout, :cutover_operation_request_fingerprint)), "cutover_operation_request_fingerprint_missing", "malformed")
    |> add_validation(blank?(optional_string(closeout, :consumption_guard_fingerprint)), "consumption_guard_fingerprint_missing", "malformed")
    |> add_validation(resolution_code(value(closeout, :resolution_code)) not in @resolution_codes, "unsupported_resolution_code", "unsupported")
    |> add_validation(safe_status(value(closeout, :source)) not in @operator_sources, "unsupported_source", "unsupported")
    |> add_validation(truthy?(value(closeout, :auto_replay_allowed)), "auto_replay_not_allowed", "conflict")
  end

  defp add_validation(reasons, true, code, level), do: [%{code: code, level: level} | reasons]
  defp add_validation(reasons, _condition, _code, _level), do: reasons

  defp status_reasons(_closeout, validation, _matching_outcome, _related_outcomes) when validation != [] do
    validation |> Enum.map(& &1.code) |> Enum.uniq() |> Enum.sort()
  end

  defp status_reasons(closeout, _validation, matching_outcome, related_outcomes) do
    cond do
      matching_outcome == nil and related_outcomes != [] ->
        stale_reason_codes(closeout, List.first(related_outcomes))

      matching_outcome == nil ->
        ["referenced_outcome_missing"]

      side_effect_conflict?(closeout, matching_outcome) ->
        ["side_effect_safety_conflict"]

      evidence_conflicts = evidence_conflicts(closeout, matching_outcome) ->
        evidence_conflicts

      true ->
        []
    end
  end

  defp closeout_status(_closeout, validation, _status_reasons, _matching_outcome) when validation != [] do
    cond do
      Enum.any?(validation, &(&1.level == "malformed")) -> "malformed"
      Enum.any?(validation, &(&1.level == "unsupported")) -> "unsupported"
      true -> "conflict"
    end
  end

  defp closeout_status(closeout, _validation, status_reasons, matching_outcome) do
    cond do
      matching_outcome == nil and Enum.any?(status_reasons, &String.ends_with?(&1, "_mismatch")) -> "stale"
      matching_outcome == nil -> "conflict"
      "side_effect_safety_conflict" in status_reasons -> "conflict"
      status_reasons != [] -> "conflict"
      closeout.resolution_code == "requires_follow_up" -> "manual_attention"
      closeout.resolution_code in @closing_resolution_codes -> "resolved"
      closeout.resolution_code in @retry_resolution_codes -> "resolved"
      true -> "manual_attention"
    end
  end

  defp matching_unresolved_outcome(closeout, unresolved) do
    Enum.find(unresolved, fn outcome ->
      optional_string(outcome, :project_id) == optional_string(closeout, :project_id) and
        operation_name(value(outcome, :operation)) == operation_name(value(closeout, :operation)) and
        source_name(value(outcome, :side_effect_source)) == source_name(value(closeout, :side_effect_source)) and
        optional_string(outcome, :replay_key) == optional_string(closeout, :replay_key) and
        optional_string(outcome, :evidence_fingerprint) == optional_string(closeout, :outcome_fingerprint) and
        outcome_status(value(outcome, :status)) == outcome_status(value(closeout, :outcome_status))
    end)
  end

  defp related_outcomes(closeout, outcomes) do
    outcomes
    |> Enum.filter(fn outcome ->
      optional_string(outcome, :project_id) == optional_string(closeout, :project_id) and
        operation_name(value(outcome, :operation)) == operation_name(value(closeout, :operation)) and
        source_name(value(outcome, :side_effect_source)) == source_name(value(closeout, :side_effect_source)) and
        (optional_string(outcome, :replay_key) == optional_string(closeout, :replay_key) or
           optional_string(outcome, :evidence_fingerprint) == optional_string(closeout, :outcome_fingerprint))
    end)
    |> Enum.sort_by(&outcome_sort_key/1)
  end

  defp side_effect_conflict?(closeout, outcome) do
    side_effect_binding_mismatch?(closeout, outcome, :side_effect_entered) or
      side_effect_binding_mismatch?(closeout, outcome, :side_effect_may_have_happened)
  end

  defp side_effect_binding_mismatch?(closeout, outcome, key) do
    bound = value(closeout, key)
    current = value(outcome, key)

    bound in [true, false] and current in [true, false] and bound != current
  end

  defp evidence_conflicts(closeout, outcome) do
    [
      evidence_conflict(
        closeout,
        outcome,
        :authorization_record_fingerprint,
        :authorization_record_fingerprint,
        "authorization_record_fingerprint_mismatch"
      ),
      evidence_conflict(
        closeout,
        outcome,
        :readiness_permit_fingerprint,
        :readiness_permit_fingerprint,
        "readiness_permit_fingerprint_mismatch"
      ),
      evidence_conflict(
        closeout,
        outcome,
        :cutover_gate_fingerprint,
        :cutover_gate_fingerprint,
        "cutover_gate_fingerprint_mismatch"
      ),
      evidence_conflict(
        closeout,
        outcome,
        :cutover_operation_request_fingerprint,
        :cutover_operation_request_fingerprint,
        "cutover_operation_request_fingerprint_mismatch"
      ),
      evidence_conflict(
        closeout,
        outcome,
        :consumption_guard_fingerprint,
        [:safe_evidence_fingerprints, :consumption_guard],
        "consumption_guard_fingerprint_mismatch"
      ),
      evidence_conflict(
        closeout,
        outcome,
        :authorization_request_fingerprint,
        :authorization_request_fingerprint,
        "authorization_request_fingerprint_mismatch"
      ),
      evidence_conflict(closeout, outcome, :dry_run_audit_fingerprint, :dry_run_audit_fingerprint, "dry_run_audit_fingerprint_mismatch"),
      evidence_conflict(closeout, outcome, :audit_history_fingerprint, :audit_history_fingerprint, "audit_history_fingerprint_mismatch")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      reasons -> Enum.uniq(reasons) |> Enum.sort()
    end
  end

  defp evidence_conflict(closeout, outcome, closeout_key, outcome_key, reason) do
    closeout_value = optional_string(closeout, closeout_key)
    outcome_value = outcome_evidence_value(outcome, outcome_key)

    if bound?(closeout_value) and bound?(outcome_value) and closeout_value != outcome_value do
      reason
    end
  end

  defp stale_reason_codes(closeout, outcome) do
    [
      stale_reason(closeout, outcome, :replay_key, :replay_key, "replay_key_mismatch"),
      stale_reason(closeout, outcome, :outcome_fingerprint, :evidence_fingerprint, "outcome_fingerprint_mismatch"),
      stale_reason(closeout, outcome, :outcome_status, :status, "outcome_status_changed")
    ]
    |> Kernel.++(evidence_conflicts(closeout, outcome) || [])
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ["outcome_evidence_drift"]
      reasons -> Enum.uniq(reasons) |> Enum.sort()
    end
  end

  defp stale_reason(closeout, outcome, closeout_key, outcome_key, reason) do
    closeout_value = optional_string(closeout, closeout_key) || safe_status(value(closeout, closeout_key))
    outcome_value = optional_string(outcome, outcome_key) || safe_status(value(outcome, outcome_key))

    if bound?(closeout_value) and bound?(outcome_value) and closeout_value != outcome_value do
      reason
    end
  end

  defp outcome_evidence_value(outcome, key) when is_list(key), do: get_in_value(outcome, key)

  defp outcome_evidence_value(outcome, key) do
    optional_string(outcome, key) || get_in_value(outcome, [:safe_evidence_fingerprints, evidence_key(key)])
  end

  defp evidence_key(key) do
    Map.get(
      %{
        authorization_record_fingerprint: :authorization_record,
        authorization_request_fingerprint: :authorization_request,
        readiness_permit_fingerprint: :readiness_permit,
        cutover_gate_fingerprint: :cutover_gate,
        cutover_operation_request_fingerprint: :cutover_operation_request,
        dry_run_audit_fingerprint: :dry_run_audit,
        audit_history_fingerprint: :audit_history
      },
      key,
      key
    )
  end

  defp project_summary(project_id, outcome_ledger, records) do
    ledger_project =
      outcome_ledger
      |> list_value(:projects)
      |> Enum.find(&(optional_string(&1, :project_id) == project_id))

    unresolved =
      ledger_project
      |> list_value(:unresolved_outcomes)
      |> Enum.map(&outcome_summary/1)
      |> Enum.sort_by(&outcome_sort_key/1)

    project_records =
      records
      |> Enum.filter(&(optional_string(&1, :project_id) == project_id))
      |> Enum.sort_by(&record_sort_key/1)

    resolved_binding_ids =
      project_records
      |> Enum.filter(&(&1.status == "resolved"))
      |> Enum.map(&optional_string(&1, :outcome_binding_id))
      |> Enum.reject(&blank?/1)
      |> MapSet.new()

    still_required =
      unresolved
      |> Enum.reject(&MapSet.member?(resolved_binding_ids, outcome_binding_id(&1)))

    %{
      version: @version,
      project_id: project_id,
      status: project_status(unresolved, project_records, still_required),
      provider_scope: project_provider_scope(ledger_project, project_records),
      unresolved_outcomes: still_required,
      closeouts: project_records,
      counts: project_count_snapshot(%{}, unresolved, still_required, project_records),
      recent_reason_codes: recent_codes(project_records, :reason_code),
      recent_action_codes: recent_codes(project_records, :action_code),
      allow_explicit_retry_consideration: Enum.any?(project_records, &(&1.allow_explicit_retry_consideration == true and &1.status == "resolved")),
      retry_consideration_reasons: retry_consideration_reasons(project_records),
      requires_operator_attention_reasons: operator_attention_reasons(still_required, project_records),
      no_side_effects: true,
      auto_replay_allowed: false
    }
    |> project_snapshot()
  end

  defp project_snapshot(project) when is_map(project) do
    unresolved =
      project
      |> list_value(:unresolved_outcomes)
      |> Enum.map(&outcome_summary/1)
      |> Enum.sort_by(&outcome_sort_key/1)

    closeouts =
      project
      |> list_value(:closeouts)
      |> Enum.map(&record_snapshot/1)
      |> Enum.sort_by(&record_sort_key/1)

    %{
      version: positive_integer(value(project, :version)) || @version,
      project_id: optional_string(project, :project_id) || "",
      status: normalize_project_status(value(project, :status), unresolved, closeouts),
      provider_scope: provider_scope_snapshot(value(project, :provider_scope) || %{}),
      unresolved_outcomes: unresolved,
      closeouts: closeouts,
      counts: project_count_snapshot(value(project, :counts), unresolved, unresolved, closeouts),
      recent_reason_codes: string_list(value(project, :recent_reason_codes)) |> Enum.take(5),
      recent_action_codes: string_list(value(project, :recent_action_codes)) |> Enum.take(5),
      allow_explicit_retry_consideration: truthy?(value(project, :allow_explicit_retry_consideration)),
      retry_consideration_reasons: string_list(value(project, :retry_consideration_reasons)),
      requires_operator_attention_reasons: string_list(value(project, :requires_operator_attention_reasons)),
      no_side_effects: value(project, :no_side_effects) != false,
      auto_replay_allowed: false
    }
  end

  defp project_snapshot(_project), do: project_snapshot(%{})

  defp outcome_summary(outcome) when is_map(outcome) do
    %{
      outcome_id: optional_string(outcome, :outcome_id),
      outcome_binding_id: outcome_binding_id(outcome),
      replay_key: optional_string(outcome, :replay_key),
      project_id: optional_string(outcome, :project_id),
      operation: operation_name(value(outcome, :operation)),
      side_effect_source: source_name(value(outcome, :side_effect_source)),
      status: outcome_status(value(outcome, :status)),
      reason_code: safe_status(value(outcome, :reason_code)) |> blank_to_default("unknown_reason"),
      action_code: safe_status(value(outcome, :action_code)) |> blank_to_default(nil),
      evidence_fingerprint: optional_string(outcome, :evidence_fingerprint),
      authorization_record_fingerprint: optional_string(outcome, :authorization_record_fingerprint),
      readiness_permit_fingerprint: optional_string(outcome, :readiness_permit_fingerprint),
      consumption_guard_fingerprint: get_in_value(outcome, [:safe_evidence_fingerprints, :consumption_guard]),
      side_effect_entered: value(outcome, :side_effect_entered) == true,
      side_effect_may_have_happened: value(outcome, :side_effect_may_have_happened) == true,
      replay_blocked: value(outcome, :replay_blocked) != false,
      no_side_effects: false?(value(outcome, :side_effect_entered))
    }
    |> compact_map()
  end

  defp outcome_summary(_outcome), do: %{}

  defp all_outcomes(outcome_ledger) do
    (list_value(outcome_ledger, :recent_outcomes) ++
       list_value(outcome_ledger, :unresolved_outcomes) ++
       list_value(outcome_ledger, :terminal_outcomes) ++
       Enum.flat_map(list_value(outcome_ledger, :projects), fn project ->
         list_value(project, :recent_outcomes) ++
           list_value(project, :unresolved_outcomes) ++
           list_value(project, :terminal_outcomes)
       end))
    |> Enum.map(&CutoverExecutionOutcomeLedger.fact_snapshot/1)
    |> Enum.reject(&blank?(optional_string(&1, :project_id)))
    |> Enum.uniq_by(&outcome_binding_id/1)
  end

  defp closeout_list(nil, _now), do: []

  defp closeout_list(%{} = closeouts, now) do
    cond do
      is_list(value(closeouts, :closeouts)) ->
        closeout_list(value(closeouts, :closeouts), now)

      is_list(value(closeouts, :execution_outcome_closeouts)) ->
        closeout_list(value(closeouts, :execution_outcome_closeouts), now)

      true ->
        [closeout_snapshot(closeouts, now)]
    end
  end

  defp closeout_list(closeouts, now) when is_list(closeouts), do: Enum.map(closeouts, &closeout_snapshot(&1, now))
  defp closeout_list(closeout, now), do: [closeout_snapshot(closeout, now)]

  defp overall_status(unresolved, records) do
    cond do
      unresolved == [] and records == [] -> "no_outcome"
      unresolved != [] and records == [] -> "no_closeout"
      Enum.any?(records, &(&1.status == "malformed")) -> "malformed"
      Enum.any?(records, &(&1.status == "unsupported")) -> "unsupported"
      Enum.any?(records, &(&1.status == "conflict")) -> "conflict"
      Enum.any?(records, &(&1.status == "stale")) -> "stale"
      Enum.any?(records, &(&1.status == "manual_attention")) -> "manual_attention"
      unresolved_after_closeout(unresolved, records) != [] -> "manual_attention"
      Enum.any?(records, &(&1.status == "resolved")) -> "resolved"
      true -> "no_closeout"
    end
  end

  defp normalize_status(status, unresolved, records) do
    status = safe_status(status)
    if status in @statuses, do: status, else: overall_status(unresolved, records)
  end

  defp project_status([], records, _still_required) do
    if records == [], do: "no_outcome", else: project_record_status(records)
  end

  defp project_status(_unresolved, [], _still_required), do: "no_closeout"
  defp project_status(_unresolved, records, []), do: project_record_status(records)

  defp project_status(_unresolved, records, _still_required) do
    case project_record_status(records) do
      "resolved" -> "manual_attention"
      status -> status
    end
  end

  defp project_record_status(records) do
    cond do
      records == [] -> "no_closeout"
      Enum.any?(records, &(&1.status == "malformed")) -> "malformed"
      Enum.any?(records, &(&1.status == "unsupported")) -> "unsupported"
      Enum.any?(records, &(&1.status == "conflict")) -> "conflict"
      Enum.any?(records, &(&1.status == "stale")) -> "stale"
      Enum.any?(records, &(&1.status == "manual_attention")) -> "manual_attention"
      Enum.any?(records, &(&1.status == "resolved")) -> "resolved"
      true -> "manual_attention"
    end
  end

  defp normalize_project_status(status, unresolved, closeouts) do
    status = safe_status(status)
    if status in @statuses, do: status, else: project_status(unresolved, closeouts, unresolved)
  end

  defp count_snapshot(counts, projects, records, unresolved) when is_map(counts) do
    project_unresolved =
      projects
      |> Enum.flat_map(&list_value(&1, :unresolved_outcomes))
      |> Enum.uniq_by(&outcome_binding_id/1)

    unresolved = if unresolved == [], do: project_unresolved, else: unresolved

    %{
      project_count: non_negative_integer(value(counts, :project_count)) || length(projects),
      unresolved_outcome_count: non_negative_integer(value(counts, :unresolved_outcome_count)) || length(unresolved),
      closeout_count: non_negative_integer(value(counts, :closeout_count)) || length(records),
      resolved_count: non_negative_integer(value(counts, :resolved_count)) || Enum.count(records, &(&1.status == "resolved")),
      stale_count: non_negative_integer(value(counts, :stale_count)) || Enum.count(records, &(&1.status == "stale")),
      conflict_count: non_negative_integer(value(counts, :conflict_count)) || Enum.count(records, &(&1.status == "conflict")),
      manual_attention_count:
        non_negative_integer(value(counts, :manual_attention_count)) ||
          Enum.count(records, &(&1.status == "manual_attention")),
      malformed_count: non_negative_integer(value(counts, :malformed_count)) || Enum.count(records, &(&1.status == "malformed")),
      unsupported_count: non_negative_integer(value(counts, :unsupported_count)) || Enum.count(records, &(&1.status == "unsupported")),
      no_outcome_count: non_negative_integer(value(counts, :no_outcome_count)) || Enum.count(projects, &(&1.status == "no_outcome")),
      no_closeout_count: non_negative_integer(value(counts, :no_closeout_count)) || Enum.count(projects, &(&1.status == "no_closeout")),
      allow_explicit_retry_consideration_count:
        non_negative_integer(value(counts, :allow_explicit_retry_consideration_count)) ||
          Enum.count(records, &(&1.allow_explicit_retry_consideration == true and &1.status == "resolved")),
      operation_status_counts:
        value(counts, :operation_status_counts) ||
          operation_status_counts(records),
      source_status_counts:
        value(counts, :source_status_counts) ||
          source_status_counts(records)
    }
  end

  defp count_snapshot(_counts, projects, records, unresolved), do: count_snapshot(%{}, projects, records, unresolved)

  defp project_count_snapshot(counts, unresolved, still_required, records) when is_map(counts) do
    %{
      unresolved_outcome_count:
        non_negative_integer(value(counts, :unresolved_outcome_count)) ||
          length(unresolved),
      still_requires_operator_count:
        non_negative_integer(value(counts, :still_requires_operator_count)) ||
          length(still_required),
      closeout_count: non_negative_integer(value(counts, :closeout_count)) || length(records),
      resolved_count: non_negative_integer(value(counts, :resolved_count)) || Enum.count(records, &(&1.status == "resolved")),
      stale_count: non_negative_integer(value(counts, :stale_count)) || Enum.count(records, &(&1.status == "stale")),
      conflict_count: non_negative_integer(value(counts, :conflict_count)) || Enum.count(records, &(&1.status == "conflict")),
      manual_attention_count:
        non_negative_integer(value(counts, :manual_attention_count)) ||
          Enum.count(records, &(&1.status == "manual_attention")),
      malformed_count: non_negative_integer(value(counts, :malformed_count)) || Enum.count(records, &(&1.status == "malformed")),
      unsupported_count: non_negative_integer(value(counts, :unsupported_count)) || Enum.count(records, &(&1.status == "unsupported")),
      allow_explicit_retry_consideration_count:
        non_negative_integer(value(counts, :allow_explicit_retry_consideration_count)) ||
          Enum.count(records, &(&1.allow_explicit_retry_consideration == true and &1.status == "resolved"))
    }
  end

  defp project_count_snapshot(_counts, unresolved, still_required, records), do: project_count_snapshot(%{}, unresolved, still_required, records)

  defp operation_status_counts(records) do
    base = Map.new(@operations, &{String.to_atom(&1), status_zero_counts()})

    Enum.reduce(records, base, fn record, acc ->
      operation = operation_name(value(record, :operation)) |> String.to_atom()
      status = normalize_record_status(value(record, :status)) |> String.to_atom()

      Map.update(acc, operation, Map.update(status_zero_counts(), status, 1, &(&1 + 1)), fn counts ->
        Map.update(counts, status, 1, &(&1 + 1))
      end)
    end)
  end

  defp source_status_counts(records) do
    base = Map.new(@sources, &{String.to_atom(&1), status_zero_counts()})

    Enum.reduce(records, base, fn record, acc ->
      source = source_name(value(record, :side_effect_source)) |> String.to_atom()
      status = normalize_record_status(value(record, :status)) |> String.to_atom()

      Map.update(acc, source, Map.update(status_zero_counts(), status, 1, &(&1 + 1)), fn counts ->
        Map.update(counts, status, 1, &(&1 + 1))
      end)
    end)
  end

  defp status_zero_counts, do: Map.new(@record_statuses, &{String.to_atom(&1), 0})

  defp unresolved_after_closeout(unresolved, records) do
    resolved =
      records
      |> Enum.filter(&(&1.status == "resolved"))
      |> Enum.map(&optional_string(&1, :outcome_binding_id))
      |> Enum.reject(&blank?/1)
      |> MapSet.new()

    Enum.reject(unresolved, &MapSet.member?(resolved, outcome_binding_id(&1)))
  end

  defp retry_consideration_reasons(records) do
    records
    |> Enum.filter(&(&1.status == "resolved" and &1.allow_explicit_retry_consideration == true))
    |> Enum.flat_map(fn record ->
      [record.reason_code, "requires_new_permit_authorization_and_consumption_guard"]
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp operator_attention_reasons(unresolved, records) do
    unresolved_reasons = Enum.map(unresolved, &(safe_status(value(&1, :reason_code)) || ""))

    closeout_reasons =
      records
      |> Enum.reject(&(&1.status == "resolved"))
      |> Enum.flat_map(&string_list(value(&1, :status_reasons)))

    (unresolved_reasons ++ closeout_reasons)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp recent_codes(records, key) do
    records
    |> Enum.map(&safe_status(value(&1, key)))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp project_provider_scope(ledger_project, records) do
    case provider_scope_snapshot(value(ledger_project || %{}, :provider_scope) || %{}) do
      scope when scope != %{} -> scope
      _scope -> records |> List.first() |> value(:provider_scope) |> provider_scope_snapshot()
    end
  end

  defp ensure_operator_request_fingerprint(closeout) do
    Map.put(
      closeout,
      :operator_request_fingerprint,
      optional_string(closeout, :operator_request_fingerprint) || operator_request_fingerprint(closeout)
    )
  end

  defp ensure_record_fingerprint(record) do
    record
    |> ensure_operator_request_fingerprint()
    |> Map.put(:closeout_record_fingerprint, optional_string(record, :closeout_record_fingerprint) || closeout_record_fingerprint(record))
  end

  defp operator_request_fingerprint(closeout) do
    closeout
    |> Map.take([
      :project_id,
      :provider_scope,
      :operation,
      :side_effect_source,
      :replay_key,
      :outcome_fingerprint,
      :outcome_status,
      :resolution_code,
      :reason_code,
      :action_code,
      :created_at,
      :closed_at
    ])
    |> fingerprint()
  end

  defp closeout_record_fingerprint(record) do
    record
    |> Map.take([
      :project_id,
      :provider_scope,
      :operation,
      :side_effect_source,
      :replay_key,
      :outcome_fingerprint,
      :outcome_status,
      :authorization_record_fingerprint,
      :readiness_permit_fingerprint,
      :cutover_gate_fingerprint,
      :cutover_operation_request_fingerprint,
      :consumption_guard_fingerprint,
      :resolution_code,
      :operator_request_fingerprint
    ])
    |> fingerprint()
  end

  defp outcome_binding_id(outcome) do
    fingerprint(%{
      project_id: optional_string(outcome, :project_id),
      operation: operation_name(value(outcome, :operation)),
      side_effect_source: source_name(value(outcome, :side_effect_source)),
      replay_key: optional_string(outcome, :replay_key),
      evidence_fingerprint: optional_string(outcome, :evidence_fingerprint),
      status: outcome_status(value(outcome, :status))
    })
  end

  defp record_sort_key(record) do
    {
      value(record, :closed_at) || value(record, :created_at) || "",
      optional_string(record, :project_id) || "",
      operation_name(value(record, :operation)),
      source_name(value(record, :side_effect_source)),
      optional_string(record, :replay_key) || ""
    }
  end

  defp outcome_sort_key(outcome) do
    {
      value(outcome, :completed_at) || value(outcome, :generated_at) || value(outcome, :started_at) || "",
      optional_string(outcome, :project_id) || "",
      operation_name(value(outcome, :operation)),
      source_name(value(outcome, :side_effect_source)),
      optional_string(outcome, :replay_key) || ""
    }
  end

  defp project_ids_from(summary) when is_map(summary) do
    summary
    |> list_value(:projects)
    |> Enum.map(&optional_string(&1, :project_id))
  end

  defp source_operation_mismatch?(operation, source) do
    case source_name(source) do
      "candidate_scan" -> operation_name(operation) != "poll"
      "dispatch_application" -> operation_name(operation) != "dispatch"
      "worker_start_handoff" -> operation_name(operation) != "worker_start"
      "writeback_executor" -> operation_name(operation) != "writeback"
      _source -> false
    end
  end

  defp side_effect_snapshot(record) do
    %{
      entered: boolean_value(value(record, :side_effect_entered)),
      may_have_happened: boolean_value(value(record, :side_effect_may_have_happened))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp provider_scope_snapshot(scope) when is_map(scope) do
    %{
      kind: optional_string(scope, :kind) || optional_string(scope, :provider_kind),
      key: optional_string(scope, :key) || optional_string(scope, :provider_scope_key),
      provider_scope_key: optional_string(scope, :provider_scope_key) || optional_string(scope, :key),
      scope: SafeSummary.sanitize_map(value(scope, :scope) || scope, output_keys: :preserve)
    }
    |> compact_map()
  end

  defp provider_scope_snapshot(_scope), do: %{}

  defp operation_name(nil), do: "unknown_operation"
  defp operation_name(operation) when is_atom(operation), do: operation |> Atom.to_string() |> operation_name()

  defp operation_name(operation) when is_binary(operation) do
    operation
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "candidate_scan" -> "poll"
      "stage_writeback" -> "writeback"
      "comment_workpad_upsert" -> "writeback"
      "" -> "unknown_operation"
      value -> value
    end
  end

  defp operation_name(operation), do: operation |> to_string() |> operation_name()

  defp source_name(nil), do: "unknown_source"
  defp source_name(source) when is_atom(source), do: source |> Atom.to_string() |> source_name()

  defp source_name(source) when is_binary(source) do
    source
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "" -> "unknown_source"
      value -> value
    end
  end

  defp source_name(source), do: source |> to_string() |> source_name()

  defp outcome_status(status) do
    case safe_status(status) do
      status when status in ["unknown", "unknown_result"] -> "unknown"
      "manual_attention" -> "manual_attention"
      "requires_manual_attention" -> "manual_attention"
      "unresolved_unknown" -> "unknown"
      "unresolved_manual_attention" -> "manual_attention"
      status -> status
    end
  end

  defp resolution_code(code) do
    case safe_status(code) do
      "resolved" -> "confirmed_resolved"
      "failed" -> "confirmed_failed"
      "abandoned" -> "abandoned_no_retry"
      "no_retry" -> "abandoned_no_retry"
      "retry_consideration" -> "allow_explicit_retry_consideration"
      "allow_retry_consideration" -> "allow_explicit_retry_consideration"
      "follow_up" -> "requires_follow_up"
      code -> code
    end
  end

  defp normalize_record_status(status) do
    status = safe_status(status)
    if status in @record_statuses, do: status, else: "malformed"
  end

  defp string_list(value) when is_list(value) do
    value
    |> Enum.map(&safe_status/1)
    |> Enum.reject(&blank?/1)
  end

  defp string_list(nil), do: []
  defp string_list(value), do: value |> List.wrap() |> string_list()

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp list_value(map, key) when is_map(map) do
    case value(map, key) do
      value when is_list(value) -> value
      _value -> []
    end
  end

  defp list_value(_map, _key), do: []

  defp value(map, key) when is_map(map) and is_atom(key) do
    cond do
      Map.has_key?(map, key) ->
        Map.fetch!(map, key)

      Map.has_key?(map, Atom.to_string(key)) ->
        Map.fetch!(map, Atom.to_string(key))

      true ->
        nil
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key)
  defp value(_map, _key), do: nil

  defp get_in_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case value(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp get_in_value(_map, _keys), do: nil

  defp optional_string(map, key) when is_map(map), do: map |> value(key) |> optional_string()
  defp optional_string(value, _key), do: optional_string(value)
  defp optional_string(nil), do: nil

  defp optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      "nil" -> nil
      "null" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(_value), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(%{}), do: true
  defp blank?(_value), do: false

  defp bound?(value), do: not blank?(value)

  defp blank_to_default(nil, default), do: default
  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  defp safe_status(nil), do: nil
  defp safe_status(value) when is_map(value) or is_list(value) or is_tuple(value), do: nil

  defp safe_status(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_:-]+/, "_")
    |> String.replace("-", "_")
    |> String.slice(0, 120)
    |> case do
      "" -> nil
      status -> status
    end
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      _error -> nil
    end
  end

  defp iso8601(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp boolean_value(value) when value in [true, false], do: value
  defp boolean_value(_value), do: nil

  defp boolean_binding(value, _fallback) when value in [true, false], do: value
  defp boolean_binding(_value, fallback) when fallback in [true, false], do: fallback
  defp boolean_binding(_value, _fallback), do: nil

  defp truthy?(value), do: value in [true, "true", "yes", "1", 1]
  defp false?(false), do: true
  defp false?(_value), do: false

  defp note_digest(nil), do: %{}

  defp note_digest(note) when is_binary(note) do
    %{
      sha256: fingerprint(note),
      bytes: byte_size(note)
    }
  end

  defp note_digest(_note), do: %{}

  defp fingerprint(payload) do
    :crypto.hash(:sha256, :erlang.term_to_binary(payload))
    |> Base.encode16(case: :lower)
  end
end
