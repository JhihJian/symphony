defmodule SymphonyElixir.Hub.CutoverReplayRequestAudit do
  @moduledoc """
  Operator-facing Hub cutover replay request audit baseline.

  The audit binds an explicit retry/replay consideration request to the
  unresolved outcome, matching closeout, closeout-aware replay decision, current
  permit/authorization/guard evidence, and any later outcome evidence that
  references the request. It is read-only: it never creates authorization,
  consumes authorization, calls providers, dispatches work, starts workers,
  writes back, operates systemd, or edits configuration.
  """

  alias SymphonyElixir.Hub.{
    CutoverAuthorizationConsumptionGuard,
    CutoverExecutionAuthorization,
    CutoverExecutionOutcomeCloseout,
    CutoverExecutionOutcomeLedger,
    CutoverReadinessPermit,
    CutoverReplayDecision,
    SafeSummary
  }

  @version 1
  @operations ["poll", "dispatch", "worker_start", "writeback"]
  @sources ["candidate_scan", "dispatch_application", "worker_start_handoff", "writeback_executor"]
  @request_sources ["operator_file", "operator_cli", "test", "api", "hub_startup_option", "operator"]
  @statuses [
    "no_request",
    "would_allow_retry_consideration",
    "would_block",
    "stale",
    "conflict",
    "manual_attention",
    "malformed",
    "unsupported"
  ]
  @outcome_link_statuses [
    "not_linked",
    "outcome_recorded",
    "outcome_still_pending",
    "outcome_blocked",
    "outcome_stale",
    "outcome_conflict",
    "outcome_manual_attention"
  ]
  @default_recent_limit 20
  @source_operations %{
    "candidate_scan" => "poll",
    "dispatch_application" => "dispatch",
    "worker_start_handoff" => "worker_start",
    "writeback_executor" => "writeback"
  }

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

    replay_requests = value(sources, :replay_requests) || value(sources, :cutover_replay_requests)

    requests =
      opts
      |> Keyword.get(:requests, replay_requests)
      |> request_list(now)

    context = %{
      generated_at: now,
      projects: project_ids_from_sources(sources),
      outcome_ledger:
        snapshot_or_nil(
          CutoverExecutionOutcomeLedger,
          value(sources, :cutover_execution_outcome_ledger) || value(sources, :execution_outcome_ledger)
        ),
      closeout:
        snapshot_or_nil(
          CutoverExecutionOutcomeCloseout,
          value(sources, :cutover_execution_outcome_closeout) || value(sources, :execution_outcome_closeout)
        ),
      replay_decision:
        snapshot_or_nil(
          CutoverReplayDecision,
          value(sources, :cutover_replay_decision) || value(sources, :replay_decision)
        ),
      readiness_permit:
        snapshot_or_nil(
          CutoverReadinessPermit,
          value(sources, :cutover_readiness_permit) || value(sources, :readiness_permit)
        ),
      authorization_ledger:
        snapshot_or_nil(
          CutoverExecutionAuthorization,
          value(sources, :cutover_execution_authorization_ledger) || value(sources, :authorization_ledger)
        ),
      consumption_guard:
        snapshot_or_nil(
          CutoverAuthorizationConsumptionGuard,
          value(sources, :cutover_authorization_consumption_guard) ||
            value(sources, :authorization_consumption_guard)
        )
    }

    records =
      requests
      |> Enum.map(&record_snapshot(&1, context))
      |> Enum.uniq_by(& &1.audit_record_fingerprint)
      |> Enum.sort_by(&record_sort_key/1)

    project_ids =
      [
        context.projects,
        Enum.map(records, &optional_string(&1, :project_id))
      ]
      |> List.flatten()
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.sort()

    projects =
      project_ids
      |> Enum.map(&project_summary(&1, records))
      |> Enum.sort_by(& &1.project_id)

    %{
      version: @version,
      generated_at: now,
      status: overall_status(records),
      counts: count_snapshot(%{}, records, project_ids),
      recent_requests: Enum.take(records, @default_recent_limit),
      projects: projects,
      no_side_effects: true,
      auto_replay_allowed: false
    }
    |> to_snapshot()
  end

  @spec to_snapshot(term()) :: summary()
  def to_snapshot(summary) when is_map(summary) do
    records =
      summary
      |> list_value(:recent_requests)
      |> Enum.map(&record_snapshot/1)
      |> Enum.sort_by(&record_sort_key/1)
      |> Enum.take(@default_recent_limit)

    projects =
      summary
      |> list_value(:projects)
      |> Enum.map(&project_snapshot/1)
      |> Enum.sort_by(& &1.project_id)

    records =
      if records == [] and projects != [] do
        projects
        |> Enum.flat_map(&list_value(&1, :requests))
        |> Enum.map(&record_snapshot/1)
        |> Enum.sort_by(&record_sort_key/1)
        |> Enum.take(@default_recent_limit)
      else
        records
      end

    generated_at = iso8601(value(summary, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      version: positive_integer(value(summary, :version)) || @version,
      generated_at: generated_at,
      status: normalize_status(value(summary, :status), records),
      counts: count_snapshot(value(summary, :counts), records, project_ids_from_projects(projects, records)),
      recent_requests: records,
      projects: projects,
      no_side_effects: value(summary, :no_side_effects) != false,
      auto_replay_allowed: false
    }
  end

  def to_snapshot(_summary), do: to_snapshot(%{})

  @spec observability_snapshot(term()) :: summary() | nil
  def observability_snapshot(nil), do: nil
  def observability_snapshot(summary) when is_map(summary), do: to_snapshot(summary)
  def observability_snapshot(_summary), do: nil

  @spec request_snapshot(term()) :: request()
  def request_snapshot(request) do
    request
    |> request_snapshot(DateTime.utc_now() |> DateTime.to_iso8601())
    |> Map.delete(:status)
    |> Map.delete(:status_reasons)
  end

  defp record_snapshot(request, context) when is_map(request) do
    request = request_snapshot(request, context.generated_at)
    validation = request_validation(request)
    outcome = matching_outcome(request, context.outcome_ledger)
    closeout = matching_closeout(request, context.closeout)
    replay_decision = matching_replay_decision(request, context.replay_decision)
    permit = matching_permit(request, context.readiness_permit)
    authorization = matching_authorization(request, context.authorization_ledger)
    guard = matching_guard(request, context.consumption_guard)
    later_outcome = linked_later_outcome(request, context.outcome_ledger)

    status_reasons =
      status_reasons(request, validation, outcome, closeout, replay_decision, permit, authorization, guard)

    status =
      record_status(validation, status_reasons, outcome, closeout, replay_decision, permit, authorization, guard)

    request
    |> Map.merge(%{
      status: status,
      status_reasons: status_reasons,
      outcome: outcome_summary(outcome),
      matching_closeout: closeout_summary(closeout),
      replay_decision: replay_decision_summary(replay_decision),
      readiness_permit: permit_summary(permit),
      authorization_record: authorization_summary(authorization),
      consumption_guard: guard_summary(guard),
      linked_outcome: linked_outcome_summary(later_outcome, request),
      outcome_link_status: outcome_link_status(later_outcome, request),
      no_side_effects: true,
      auto_replay_allowed: false,
      requires_operator_attention: status not in ["no_request", "would_allow_retry_consideration"]
    })
    |> ensure_audit_record_fingerprint()
    |> record_snapshot()
  rescue
    _error -> record_snapshot(malformed_request(context.generated_at))
  catch
    _kind, _reason -> record_snapshot(malformed_request(context.generated_at))
  end

  defp record_snapshot(record) when is_map(record) do
    status = normalize_record_status(value(record, :status))

    snapshot =
      %{
        version: positive_integer(value(record, :version)) || @version,
        request_id: optional_string(record, :request_id) || optional_string(record, :id),
        request_fingerprint: optional_string(record, :request_fingerprint),
        audit_record_fingerprint: optional_string(record, :audit_record_fingerprint),
        project_id: optional_string(record, :project_id) || "",
        provider_scope: provider_scope_snapshot(value(record, :provider_scope) || %{}),
        operation: operation_name(value(record, :operation)),
        side_effect_source: source_name(value(record, :side_effect_source) || value(record, :source_boundary)),
        replay_key: optional_string(record, :replay_key) || optional_string(record, :outcome_replay_key),
        outcome_id: optional_string(record, :outcome_id),
        outcome_fingerprint: optional_string(record, :outcome_fingerprint),
        outcome_status: outcome_status(value(record, :outcome_status)),
        outcome_side_effect: side_effect_snapshot(value(record, :outcome_side_effect) || record),
        closeout_record_fingerprint: optional_string(record, :closeout_record_fingerprint),
        closeout_resolution_code:
          safe_status(value(record, :closeout_resolution_code) || value(record, :closeout_resolution))
          |> blank_to_nil(),
        closeout_operator_request_fingerprint: optional_string(record, :closeout_operator_request_fingerprint),
        replay_decision_fingerprint: optional_string(record, :replay_decision_fingerprint),
        replay_decision_status: safe_status(value(record, :replay_decision_status)) |> blank_to_nil(),
        cutover_operation_request_fingerprint: optional_string(record, :cutover_operation_request_fingerprint),
        readiness_permit_fingerprint: optional_string(record, :readiness_permit_fingerprint),
        readiness_permit_decision: safe_status(value(record, :readiness_permit_decision)) |> blank_to_nil(),
        authorization_record_fingerprint: optional_string(record, :authorization_record_fingerprint),
        authorization_request_fingerprint: optional_string(record, :authorization_request_fingerprint),
        consumption_guard_fingerprint: optional_string(record, :consumption_guard_fingerprint),
        guard_decision: safe_status(value(record, :guard_decision)) |> blank_to_nil(),
        cutover_gate_fingerprint: optional_string(record, :cutover_gate_fingerprint),
        dry_run_audit_fingerprint: optional_string(record, :dry_run_audit_fingerprint),
        audit_history_fingerprint: optional_string(record, :audit_history_fingerprint),
        safe_evidence_fingerprints:
          SafeSummary.sanitize_map(value(record, :safe_evidence_fingerprints) || %{},
            output_keys: :preserve
          ),
        source: safe_status(value(record, :source)) |> blank_to_default("operator_file"),
        requested_at: iso8601(value(record, :requested_at)),
        reason_code:
          safe_status(value(record, :reason_code) || value(record, :reason))
          |> blank_to_default(default_reason(status)),
        action_code:
          safe_status(value(record, :action_code) || value(record, :action))
          |> blank_to_default(default_action(status)),
        status: status,
        status_reasons: string_list(value(record, :status_reasons)),
        outcome_link_status: normalize_outcome_link_status(value(record, :outcome_link_status)),
        outcome: maybe_map(value(record, :outcome)),
        matching_closeout: maybe_map(value(record, :matching_closeout)),
        replay_decision: maybe_map(value(record, :replay_decision)),
        readiness_permit: maybe_map(value(record, :readiness_permit)),
        authorization_record: maybe_map(value(record, :authorization_record)),
        consumption_guard: maybe_map(value(record, :consumption_guard)),
        linked_outcome: maybe_map(value(record, :linked_outcome)),
        operator_note_digest:
          value(record, :operator_note_digest)
          |> Kernel.||(%{})
          |> SafeSummary.sanitize_map(output_keys: :preserve),
        no_side_effects: value(record, :no_side_effects) != false,
        auto_replay_allowed: false,
        requires_operator_attention:
          value(record, :requires_operator_attention) == true or
            status not in ["no_request", "would_allow_retry_consideration"]
      }
      |> compact_map()

    snapshot =
      snapshot
      |> Map.put(:request_fingerprint, optional_string(snapshot, :request_fingerprint) || request_fingerprint(snapshot))
      |> Map.put(
        :request_id,
        optional_string(snapshot, :request_id) ||
          "hub-cutover-replay-request:" <>
            fingerprint(
              Map.take(snapshot, [
                :project_id,
                :operation,
                :side_effect_source,
                :replay_key,
                :request_fingerprint
              ])
            )
      )

    Map.put(
      snapshot,
      :audit_record_fingerprint,
      optional_string(snapshot, :audit_record_fingerprint) || audit_record_fingerprint(snapshot)
    )
  end

  defp record_snapshot(_record), do: record_snapshot(malformed_request(DateTime.utc_now() |> DateTime.to_iso8601()))

  defp request_snapshot(request, now) when is_map(request) do
    evidence = value(request, :safe_evidence_fingerprints) || value(request, :evidence_fingerprints) || %{}
    outcome = value(request, :outcome) || %{}
    closeout = value(request, :closeout) || value(request, :matching_closeout) || %{}
    decision = value(request, :replay_decision) || %{}
    side_effect = value(request, :outcome_side_effect) || value(request, :side_effect) || request

    snapshot =
      %{
        version: positive_integer(value(request, :version)) || @version,
        request_id: optional_string(request, :request_id) || optional_string(request, :id),
        request_fingerprint: optional_string(request, :request_fingerprint),
        project_id: optional_string(request, :project_id),
        provider_scope:
          provider_scope_snapshot(
            value(request, :provider_scope) ||
              value(request, :provider) ||
              value(outcome, :provider_scope) ||
              %{}
          ),
        operation: operation_name(value(request, :operation) || value(outcome, :operation)),
        side_effect_source:
          source_name(
            value(request, :side_effect_source) ||
              value(request, :source_boundary) ||
              value(outcome, :side_effect_source)
          ),
        replay_key:
          optional_string(request, :replay_key) ||
            optional_string(request, :outcome_replay_key) ||
            optional_string(outcome, :replay_key),
        outcome_id: optional_string(request, :outcome_id) || optional_string(outcome, :outcome_id),
        outcome_fingerprint:
          optional_string(request, :outcome_fingerprint) ||
            optional_string(request, :evidence_fingerprint) ||
            optional_string(outcome, :evidence_fingerprint),
        outcome_status: outcome_status(value(request, :outcome_status) || value(outcome, :status)),
        outcome_side_effect: side_effect_snapshot(side_effect),
        closeout_record_fingerprint:
          optional_string(request, :closeout_record_fingerprint) ||
            optional_string(closeout, :closeout_record_fingerprint),
        closeout_resolution_code:
          safe_status(
            value(request, :closeout_resolution_code) ||
              value(request, :closeout_resolution) ||
              value(closeout, :resolution_code)
          ),
        closeout_operator_request_fingerprint:
          optional_string(request, :closeout_operator_request_fingerprint) ||
            optional_string(closeout, :operator_request_fingerprint),
        replay_decision_fingerprint:
          optional_string(request, :replay_decision_fingerprint) ||
            optional_string(evidence, :replay_decision),
        replay_decision_status:
          safe_status(
            value(request, :replay_decision_status) ||
              value(request, :decision_status) ||
              value(decision, :decision) ||
              value(decision, :status)
          ),
        cutover_operation_request_fingerprint:
          optional_string(request, :cutover_operation_request_fingerprint) ||
            optional_string(evidence, :cutover_operation_request),
        readiness_permit_fingerprint:
          optional_string(request, :readiness_permit_fingerprint) ||
            optional_string(evidence, :readiness_permit),
        readiness_permit_decision:
          safe_status(
            value(request, :readiness_permit_decision) ||
              value(evidence, :readiness_permit_decision)
          ),
        authorization_record_fingerprint:
          optional_string(request, :authorization_record_fingerprint) ||
            optional_string(evidence, :authorization_record),
        authorization_request_fingerprint:
          optional_string(request, :authorization_request_fingerprint) ||
            optional_string(evidence, :authorization_request),
        consumption_guard_fingerprint:
          optional_string(request, :consumption_guard_fingerprint) ||
            optional_string(evidence, :consumption_guard),
        guard_decision: safe_status(value(request, :guard_decision) || value(evidence, :guard_decision)),
        cutover_gate_fingerprint:
          optional_string(request, :cutover_gate_fingerprint) ||
            optional_string(evidence, :cutover_gate),
        dry_run_audit_fingerprint:
          optional_string(request, :dry_run_audit_fingerprint) ||
            optional_string(evidence, :dry_run_audit),
        audit_history_fingerprint:
          optional_string(request, :audit_history_fingerprint) ||
            optional_string(evidence, :audit_history),
        safe_evidence_fingerprints: SafeSummary.sanitize_map(evidence, output_keys: :preserve),
        source: safe_status(value(request, :source)) |> blank_to_default("operator_file"),
        requested_at: iso8601(value(request, :requested_at)) || now,
        reason_code: safe_status(value(request, :reason_code) || value(request, :reason)),
        action_code: safe_status(value(request, :action_code) || value(request, :action)),
        operator_note_digest:
          value(request, :operator_note_digest) ||
            value(request, :note_digest) ||
            note_digest(value(request, :operator_note) || value(request, :note)),
        no_side_effects: true,
        auto_replay_allowed: false
      }
      |> compact_map()

    Map.put(
      snapshot,
      :request_fingerprint,
      optional_string(snapshot, :request_fingerprint) || request_fingerprint(snapshot)
    )
  end

  defp request_snapshot(_request, now), do: malformed_request(now)

  defp malformed_request(now) do
    request_snapshot(
      %{
        project_id: "",
        operation: "unknown_operation",
        side_effect_source: "unknown_source",
        reason_code: "malformed_replay_request",
        action_code: "fix_cutover_replay_request",
        source: "operator_file",
        requested_at: now
      },
      now
    )
  end

  defp request_validation(request) do
    []
    |> add_validation(blank?(optional_string(request, :project_id)), "project_id_missing", "malformed")
    |> add_validation(operation_name(value(request, :operation)) not in @operations, "unknown_operation", "unsupported")
    |> add_validation(
      source_name(value(request, :side_effect_source)) not in @sources,
      "unsupported_side_effect_source",
      "unsupported"
    )
    |> add_validation(
      source_operation_mismatch?(value(request, :operation), value(request, :side_effect_source)),
      "side_effect_source_operation_mismatch",
      "unsupported"
    )
    |> add_validation(blank?(optional_string(request, :replay_key)), "replay_key_missing", "malformed")
    |> add_validation(
      blank?(optional_string(request, :outcome_fingerprint)),
      "outcome_fingerprint_missing",
      "malformed"
    )
    |> add_validation(blank?(outcome_status(value(request, :outcome_status))), "outcome_status_missing", "malformed")
    |> add_validation(
      not blank?(outcome_status(value(request, :outcome_status))) and
        outcome_status(value(request, :outcome_status)) not in ["unknown", "manual_attention"],
      "outcome_status_not_unresolved",
      "conflict"
    )
    |> add_validation(
      get_in_value(request, [:outcome_side_effect, :entered]) not in [true, false] and
        get_in_value(request, [:outcome_side_effect, :may_have_happened]) not in [true, false],
      "side_effect_safety_missing",
      "malformed"
    )
    |> add_validation(
      blank?(optional_string(request, :closeout_record_fingerprint)),
      "closeout_record_fingerprint_missing",
      "malformed"
    )
    |> add_validation(
      safe_status(value(request, :closeout_resolution_code)) != "allow_explicit_retry_consideration",
      "closeout_retry_resolution_missing",
      "manual_attention"
    )
    |> add_validation(
      blank?(optional_string(request, :replay_decision_fingerprint)),
      "replay_decision_fingerprint_missing",
      "malformed"
    )
    |> add_validation(
      safe_status(value(request, :replay_decision_status)) != "retry_consideration_allowed",
      "replay_decision_not_allowing_retry_consideration",
      "manual_attention"
    )
    |> add_validation(
      blank?(optional_string(request, :cutover_operation_request_fingerprint)),
      "cutover_operation_request_fingerprint_missing",
      "malformed"
    )
    |> add_validation(
      blank?(optional_string(request, :readiness_permit_fingerprint)),
      "readiness_permit_fingerprint_missing",
      "malformed"
    )
    |> add_validation(
      blank?(optional_string(request, :authorization_record_fingerprint)),
      "authorization_record_fingerprint_missing",
      "malformed"
    )
    |> add_validation(
      blank?(optional_string(request, :consumption_guard_fingerprint)),
      "consumption_guard_fingerprint_missing",
      "malformed"
    )
    |> add_validation(safe_status(value(request, :source)) not in @request_sources, "unsupported_source", "unsupported")
    |> add_validation(truthy?(value(request, :auto_replay_allowed)), "auto_replay_not_allowed", "conflict")
  end

  defp add_validation(reasons, true, code, level), do: [%{code: code, level: level} | reasons]
  defp add_validation(reasons, _condition, _code, _level), do: reasons

  defp status_reasons(
         _request,
         validation,
         _outcome,
         _closeout,
         _decision,
         _permit,
         _authorization,
         _guard
       )
       when validation != [] do
    validation |> Enum.map(& &1.code) |> Enum.uniq() |> Enum.sort()
  end

  defp status_reasons(request, _validation, outcome, closeout, replay_decision, permit, authorization, guard) do
    []
    |> add_reason(outcome == nil, "referenced_outcome_missing")
    |> add_reason(
      outcome != nil and outcome_mismatch?(request, outcome, :outcome_fingerprint, :evidence_fingerprint),
      "outcome_fingerprint_mismatch"
    )
    |> add_reason(
      outcome != nil and outcome_mismatch?(request, outcome, :outcome_status, :status),
      "outcome_status_changed"
    )
    |> add_reason(outcome != nil and side_effect_conflict?(request, outcome), "side_effect_safety_conflict")
    |> add_reason(closeout == nil, "matching_closeout_missing")
    |> add_reason(
      closeout != nil and safe_status(value(closeout, :status)) != "resolved",
      "matching_closeout_not_resolved"
    )
    |> add_reason(
      closeout != nil and value(closeout, :allow_explicit_retry_consideration) != true,
      "matching_closeout_retry_not_allowed"
    )
    |> add_reason(replay_decision == nil, "matching_replay_decision_missing")
    |> add_reason(
      replay_decision != nil and safe_status(value(replay_decision, :decision)) != "retry_consideration_allowed",
      "current_replay_decision_not_allowed"
    )
    |> add_reason(permit == nil, "readiness_permit_missing")
    |> add_reason(
      permit != nil and safe_status(value(permit, :decision)) != "ready_for_execution_consideration",
      "readiness_permit_not_ready"
    )
    |> add_reason(authorization == nil, "authorization_record_missing")
    |> add_reason(
      authorization != nil and safe_status(value(authorization, :status)) != "authorized_for_explicit_execution",
      "authorization_record_not_authorized"
    )
    |> add_reason(guard == nil, "consumption_guard_missing")
    |> add_reason(
      guard != nil and not (value(guard, :allowed) == true and safe_status(value(guard, :decision)) == "allowed"),
      "consumption_guard_not_allowed"
    )
    |> Kernel.++(evidence_mismatch_reasons(request, outcome, closeout, replay_decision, permit, authorization, guard))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp add_reason(reasons, true, reason), do: [reason | reasons]
  defp add_reason(reasons, _condition, _reason), do: reasons

  defp record_status(validation, status_reasons, outcome, closeout, replay_decision, permit, authorization, guard) do
    cond do
      validation != [] and Enum.any?(validation, &(&1.level == "malformed")) ->
        "malformed"

      validation != [] and Enum.any?(validation, &(&1.level == "unsupported")) ->
        "unsupported"

      validation != [] and Enum.any?(validation, &(&1.level == "manual_attention")) ->
        "manual_attention"

      validation != [] ->
        "conflict"

      "side_effect_safety_conflict" in status_reasons ->
        "conflict"

      Enum.any?(status_reasons, &(String.ends_with?(&1, "_mismatch") or String.ends_with?(&1, "_changed"))) ->
        "stale"

      "current_replay_decision_not_allowed" in status_reasons ->
        "would_block"

      "readiness_permit_not_ready" in status_reasons ->
        "would_block"

      "authorization_record_not_authorized" in status_reasons ->
        "would_block"

      "consumption_guard_not_allowed" in status_reasons ->
        "would_block"

      Enum.any?(status_reasons, &String.contains?(&1, "missing")) ->
        "would_block"

      manual_attention_source?(outcome, closeout, replay_decision) ->
        "manual_attention"

      is_map(outcome) and is_map(closeout) and is_map(replay_decision) and is_map(permit) and
        is_map(authorization) and is_map(guard) ->
        "would_allow_retry_consideration"

      true ->
        "would_block"
    end
  end

  defp manual_attention_source?(outcome, closeout, replay_decision) do
    safe_status(value(outcome || %{}, :status)) == "manual_attention" or
      safe_status(value(closeout || %{}, :status)) == "manual_attention" or
      safe_status(value(replay_decision || %{}, :decision)) == "manual_attention"
  end

  defp evidence_mismatch_reasons(request, outcome, closeout, replay_decision, permit, authorization, guard) do
    [
      mismatch(request, outcome, :replay_key, :replay_key, "replay_key_mismatch"),
      mismatch(
        request,
        closeout,
        :closeout_record_fingerprint,
        :closeout_record_fingerprint,
        "closeout_record_fingerprint_mismatch"
      ),
      mismatch(request, closeout, :closeout_resolution_code, :resolution_code, "closeout_resolution_mismatch"),
      mismatch(
        request,
        replay_decision,
        :replay_decision_fingerprint,
        :decision_fingerprint,
        "replay_decision_fingerprint_mismatch"
      ),
      mismatch(request, replay_decision, :replay_decision_status, :decision, "replay_decision_status_mismatch"),
      mismatch(
        request,
        permit,
        :readiness_permit_fingerprint,
        :permit_fingerprint,
        "readiness_permit_fingerprint_mismatch"
      ),
      mismatch(request, permit, :readiness_permit_decision, :decision, "readiness_permit_decision_mismatch"),
      mismatch(
        request,
        authorization,
        :authorization_record_fingerprint,
        :authorization_record_fingerprint,
        "authorization_record_fingerprint_mismatch"
      ),
      mismatch_with_value(
        request,
        :authorization_request_fingerprint,
        authorization_request_fingerprint(authorization),
        "authorization_request_fingerprint_mismatch"
      ),
      mismatch_with_value(
        request,
        :consumption_guard_fingerprint,
        guard_fingerprint(guard),
        "consumption_guard_fingerprint_mismatch"
      ),
      mismatch(request, guard, :guard_decision, :decision, "guard_decision_mismatch"),
      mismatch_with_value(
        request,
        :cutover_operation_request_fingerprint,
        evidence_value(outcome, :cutover_operation_request_fingerprint),
        "outcome_cutover_operation_request_fingerprint_mismatch"
      ),
      mismatch_with_value(
        request,
        :cutover_operation_request_fingerprint,
        get_in_value(permit || %{}, [:request, :request_fingerprint]),
        "permit_cutover_operation_request_fingerprint_mismatch"
      ),
      mismatch_with_value(
        request,
        :cutover_operation_request_fingerprint,
        get_in_value(authorization || %{}, [:cutover_operation_request, :request_fingerprint]),
        "authorization_cutover_operation_request_fingerprint_mismatch"
      ),
      mismatch_with_value(
        request,
        :cutover_operation_request_fingerprint,
        safe_fingerprint(guard, :cutover_operation_request),
        "guard_cutover_operation_request_fingerprint_mismatch"
      ),
      mismatch_with_value(
        request,
        :cutover_gate_fingerprint,
        evidence_value(outcome, :cutover_gate_fingerprint),
        "cutover_gate_fingerprint_mismatch"
      ),
      mismatch_with_value(
        request,
        :dry_run_audit_fingerprint,
        evidence_value(outcome, :dry_run_audit_fingerprint),
        "dry_run_audit_fingerprint_mismatch"
      ),
      mismatch_with_value(
        request,
        :audit_history_fingerprint,
        evidence_value(outcome, :audit_history_fingerprint),
        "audit_history_fingerprint_mismatch"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp mismatch(request, current, request_key, current_key, reason) do
    mismatch_with_value(request, request_key, comparable_value(current, current_key), reason)
  end

  defp outcome_mismatch?(request, outcome, request_key, outcome_key) do
    mismatch(request, outcome, request_key, outcome_key, "mismatch") != nil
  end

  defp mismatch_with_value(request, request_key, current_value, reason) do
    request_value = comparable_value(request, request_key)

    if bound?(request_value) and bound?(current_value) and request_value != current_value do
      reason
    end
  end

  defp comparable_value(nil, _key), do: nil

  defp comparable_value(map, key) when is_map(map) do
    optional_string(map, key) || safe_status(value(map, key)) |> blank_to_nil()
  end

  defp authorization_request_fingerprint(nil), do: nil

  defp authorization_request_fingerprint(record) when is_map(record) do
    optional_string(record, :authorization_request_fingerprint) ||
      get_in_value(record, [:authorization_request, :authorization_request_fingerprint])
  end

  defp evidence_value(nil, _key), do: nil

  defp evidence_value(map, key) when is_map(map) do
    optional_string(map, key) || safe_fingerprint(map, evidence_key(key))
  end

  defp evidence_key(key) do
    Map.get(
      %{
        cutover_operation_request_fingerprint: :cutover_operation_request,
        readiness_permit_fingerprint: :readiness_permit,
        cutover_gate_fingerprint: :cutover_gate,
        dry_run_audit_fingerprint: :dry_run_audit,
        audit_history_fingerprint: :audit_history
      },
      key,
      key
    )
  end

  defp matching_outcome(request, ledger) when is_map(ledger) do
    ledger
    |> all_outcomes()
    |> Enum.find(fn outcome ->
      same_project_scope_operation_source?(request, outcome) and
        optional_string(outcome, :replay_key) == optional_string(request, :replay_key) and
        optional_string(outcome, :evidence_fingerprint) == optional_string(request, :outcome_fingerprint) and
        outcome_status(value(outcome, :status)) == outcome_status(value(request, :outcome_status))
    end)
  end

  defp matching_outcome(_request, _ledger), do: nil

  defp matching_closeout(request, closeout_summary) when is_map(closeout_summary) do
    closeout_summary
    |> all_closeouts()
    |> Enum.find(fn closeout ->
      same_project_scope_operation_source?(request, closeout) and
        optional_string(closeout, :replay_key) == optional_string(request, :replay_key) and
        optional_string(closeout, :outcome_fingerprint) == optional_string(request, :outcome_fingerprint) and
        optional_string(closeout, :closeout_record_fingerprint) ==
          optional_string(request, :closeout_record_fingerprint)
    end)
  end

  defp matching_closeout(_request, _closeout), do: nil

  defp matching_replay_decision(request, decision_summary) when is_map(decision_summary) do
    decision_summary
    |> all_replay_decisions()
    |> Enum.find(fn decision ->
      same_project_scope_operation_source?(request, decision) and
        optional_string(decision, :replay_key) == optional_string(request, :replay_key) and
        decision_fingerprint(decision) == optional_string(request, :replay_decision_fingerprint)
    end)
  end

  defp matching_replay_decision(_request, _decision), do: nil

  defp matching_permit(request, permit_summary) when is_map(permit_summary) do
    permit_summary
    |> all_permits()
    |> Enum.find(fn permit ->
      optional_string(permit, :project_id) == optional_string(request, :project_id) and
        operation_name(value(permit, :operation)) == operation_name(value(request, :operation)) and
        optional_string(permit, :permit_fingerprint) == optional_string(request, :readiness_permit_fingerprint) and
        provider_scope_matches?(value(permit, :provider_scope), value(request, :provider_scope))
    end)
  end

  defp matching_permit(_request, _permit), do: nil

  defp matching_authorization(request, authorization_summary) when is_map(authorization_summary) do
    authorization_summary
    |> all_authorizations()
    |> Enum.find(fn authorization ->
      optional_string(authorization, :project_id) == optional_string(request, :project_id) and
        operation_name(value(authorization, :operation)) == operation_name(value(request, :operation)) and
        optional_string(authorization, :authorization_record_fingerprint) ==
          optional_string(request, :authorization_record_fingerprint) and
        provider_scope_matches?(value(authorization, :provider_scope), value(request, :provider_scope))
    end)
  end

  defp matching_authorization(_request, _authorization), do: nil

  defp matching_guard(request, guard_summary) when is_map(guard_summary) do
    guard_summary
    |> all_guards()
    |> Enum.find(fn guard ->
      same_project_scope_operation_source?(request, guard) and
        guard_fingerprint(guard) == optional_string(request, :consumption_guard_fingerprint)
    end)
  end

  defp matching_guard(_request, _guard), do: nil

  defp linked_later_outcome(request, ledger) when is_map(ledger) do
    ledger
    |> all_outcomes()
    |> Enum.find(fn outcome ->
      same_project_scope_operation_source?(request, outcome) and
        (bound_equal?(
           optional_string(outcome, :replay_request_fingerprint),
           optional_string(request, :request_fingerprint)
         ) or
           bound_equal?(safe_fingerprint(outcome, :replay_request), optional_string(request, :request_fingerprint)) or
           bound_equal?(
             safe_fingerprint(outcome, :replay_request_audit),
             optional_string(request, :audit_record_fingerprint)
           ))
    end)
  end

  defp linked_later_outcome(_request, _ledger), do: nil

  defp all_outcomes(ledger) do
    (list_value(ledger, :recent_outcomes) ++
       list_value(ledger, :unresolved_outcomes) ++
       list_value(ledger, :terminal_outcomes) ++
       Enum.flat_map(list_value(ledger, :projects), fn project ->
         list_value(project, :recent_outcomes) ++
           list_value(project, :unresolved_outcomes) ++
           list_value(project, :terminal_outcomes)
       end))
    |> Enum.map(&CutoverExecutionOutcomeLedger.fact_snapshot/1)
    |> Enum.reject(&blank?(optional_string(&1, :project_id)))
    |> Enum.uniq_by(&outcome_identity/1)
  end

  defp all_closeouts(closeout) do
    (list_value(closeout, :recent_closeouts) ++
       Enum.flat_map(list_value(closeout, :projects), &list_value(&1, :closeouts)))
    |> Enum.reject(&blank?(optional_string(&1, :closeout_record_fingerprint)))
    |> Enum.uniq_by(&optional_string(&1, :closeout_record_fingerprint))
  end

  defp all_replay_decisions(summary) do
    (list_value(summary, :recent_decisions) ++
       Enum.flat_map(list_value(summary, :projects), &list_value(&1, :recent_decisions)))
    |> Enum.map(&CutoverReplayDecision.to_decision/1)
    |> Enum.uniq_by(&decision_fingerprint/1)
  end

  defp all_permits(summary) do
    Enum.flat_map(list_value(summary, :projects), &list_value(&1, :permits))
  end

  defp all_authorizations(summary) do
    Enum.flat_map(list_value(summary, :projects), &list_value(&1, :records))
  end

  defp all_guards(summary) do
    (list_value(summary, :recent_decisions) ++
       Enum.flat_map(list_value(summary, :projects), &list_value(&1, :recent_decisions)))
    |> Enum.map(&CutoverAuthorizationConsumptionGuard.to_decision/1)
    |> Enum.uniq_by(&decision_fingerprint/1)
  end

  defp same_project_scope_operation_source?(left, right) do
    optional_string(left, :project_id) == optional_string(right, :project_id) and
      operation_name(value(left, :operation)) == operation_name(value(right, :operation)) and
      source_name(value(left, :side_effect_source)) == source_name(value(right, :side_effect_source)) and
      provider_scope_matches?(value(left, :provider_scope), value(right, :provider_scope))
  end

  defp provider_scope_matches?(left, right) do
    left = provider_scope_snapshot(left || %{})
    right = provider_scope_snapshot(right || %{})

    cond do
      left == %{} or right == %{} ->
        true

      optional_string(left, :provider_scope_key) != nil and optional_string(right, :provider_scope_key) != nil ->
        optional_string(left, :provider_scope_key) == optional_string(right, :provider_scope_key)

      true ->
        left == right
    end
  end

  defp side_effect_conflict?(request, outcome) do
    side_effect = value(request, :outcome_side_effect) || %{}

    side_effect_mismatch?(value(side_effect, :entered), value(outcome, :side_effect_entered)) or
      side_effect_mismatch?(value(side_effect, :may_have_happened), value(outcome, :side_effect_may_have_happened))
  end

  defp side_effect_mismatch?(left, right), do: left in [true, false] and right in [true, false] and left != right

  defp outcome_summary(nil), do: nil

  defp outcome_summary(outcome) do
    %{
      outcome_id: optional_string(outcome, :outcome_id),
      replay_key: optional_string(outcome, :replay_key),
      outcome_fingerprint: optional_string(outcome, :evidence_fingerprint),
      status: outcome_status(value(outcome, :status)),
      side_effect_entered: value(outcome, :side_effect_entered) == true,
      side_effect_may_have_happened: value(outcome, :side_effect_may_have_happened) == true,
      replay_request_fingerprint: optional_string(outcome, :replay_request_fingerprint),
      evidence_fingerprint: optional_string(outcome, :evidence_fingerprint),
      safe_evidence_fingerprints:
        SafeSummary.sanitize_map(value(outcome, :safe_evidence_fingerprints) || %{},
          output_keys: :preserve
        )
    }
    |> compact_map()
  end

  defp closeout_summary(nil), do: nil

  defp closeout_summary(closeout) do
    %{
      closeout_id: optional_string(closeout, :closeout_id),
      closeout_record_fingerprint: optional_string(closeout, :closeout_record_fingerprint),
      resolution_code: safe_status(value(closeout, :resolution_code)) |> blank_to_nil(),
      status: safe_status(value(closeout, :status)) |> blank_to_nil(),
      allow_explicit_retry_consideration: value(closeout, :allow_explicit_retry_consideration) == true,
      operator_request_fingerprint: optional_string(closeout, :operator_request_fingerprint),
      created_at: iso8601(value(closeout, :created_at)),
      closed_at: iso8601(value(closeout, :closed_at))
    }
    |> compact_map()
  end

  defp replay_decision_summary(nil), do: nil

  defp replay_decision_summary(decision) do
    %{
      decision: safe_status(value(decision, :decision)) |> blank_to_nil(),
      allowed: value(decision, :allowed) == true,
      decision_fingerprint: decision_fingerprint(decision),
      reason_code: safe_status(value(decision, :reason_code)) |> blank_to_nil(),
      action_code: safe_status(value(decision, :action_code)) |> blank_to_nil(),
      evaluated_at: iso8601(value(decision, :evaluated_at)),
      safe_evidence_fingerprints:
        SafeSummary.sanitize_map(value(decision, :safe_evidence_fingerprints) || %{},
          output_keys: :preserve
        )
    }
    |> compact_map()
  end

  defp permit_summary(nil), do: nil

  defp permit_summary(permit) do
    %{
      permit_fingerprint: optional_string(permit, :permit_fingerprint),
      decision: safe_status(value(permit, :decision)) |> blank_to_nil(),
      operation: operation_name(value(permit, :operation)),
      request_fingerprint: get_in_value(permit, [:request, :request_fingerprint]),
      evidence_fingerprints:
        SafeSummary.sanitize_map(value(permit, :evidence_fingerprints) || %{},
          output_keys: :preserve
        )
    }
    |> compact_map()
  end

  defp authorization_summary(nil), do: nil

  defp authorization_summary(record) do
    %{
      authorization_record_id: optional_string(record, :authorization_record_id),
      authorization_record_fingerprint: optional_string(record, :authorization_record_fingerprint),
      authorization_request_fingerprint: optional_string(record, :authorization_request_fingerprint),
      status: safe_status(value(record, :status)) |> blank_to_nil(),
      operation: operation_name(value(record, :operation)),
      evidence_fingerprints:
        SafeSummary.sanitize_map(value(record, :evidence_fingerprints) || %{},
          output_keys: :preserve
        )
    }
    |> compact_map()
  end

  defp guard_summary(nil), do: nil

  defp guard_summary(guard) do
    %{
      decision: safe_status(value(guard, :decision)) |> blank_to_nil(),
      allowed: value(guard, :allowed) == true,
      decision_fingerprint: guard_fingerprint(guard),
      authorization_record_fingerprint: optional_string(guard, :authorization_record_fingerprint),
      authorization_request_fingerprint: optional_string(guard, :authorization_request_fingerprint),
      reason_code: safe_status(value(guard, :reason_code)) |> blank_to_nil(),
      safe_evidence_fingerprints:
        SafeSummary.sanitize_map(value(guard, :safe_evidence_fingerprints) || %{},
          output_keys: :preserve
        )
    }
    |> compact_map()
  end

  defp linked_outcome_summary(nil, _request), do: nil

  defp linked_outcome_summary(outcome, request) do
    summary = outcome_summary(outcome)

    if linked_outcome_drift?(outcome, request) do
      Map.put(summary, :link_conflict, true)
    else
      summary
    end
  end

  defp outcome_link_status(nil, _request), do: "not_linked"

  defp outcome_link_status(outcome, request) do
    cond do
      linked_outcome_drift?(outcome, request) -> "outcome_conflict"
      outcome_status(value(outcome, :status)) in ["unknown", "manual_attention"] -> "outcome_still_pending"
      outcome_status(value(outcome, :status)) in ["not_executed", "blocked"] -> "outcome_blocked"
      outcome_status(value(outcome, :status)) in ["succeeded", "failed", "retryable"] -> "outcome_recorded"
      true -> "outcome_stale"
    end
  end

  defp linked_outcome_drift?(outcome, request) do
    not same_project_scope_operation_source?(request, outcome) or
      mismatch_with_value(
        request,
        :authorization_record_fingerprint,
        optional_string(outcome, :authorization_record_fingerprint),
        "mismatch"
      ) != nil or
      mismatch_with_value(
        request,
        :readiness_permit_fingerprint,
        optional_string(outcome, :readiness_permit_fingerprint),
        "mismatch"
      ) != nil
  end

  defp project_summary(project_id, records) do
    project_records =
      records
      |> Enum.filter(&(optional_string(&1, :project_id) == project_id))
      |> Enum.sort_by(&record_sort_key/1)

    %{
      version: @version,
      project_id: project_id,
      status: project_status(project_records),
      counts: project_count_snapshot(%{}, project_records),
      requests: project_records,
      recent_reason_codes: recent_codes(project_records, :reason_code),
      recent_action_codes: recent_codes(project_records, :action_code),
      recent_evidence_fingerprints: recent_evidence_fingerprints(project_records),
      outcome_link_statuses: outcome_link_statuses(project_records),
      no_side_effects: true,
      auto_replay_allowed: false
    }
    |> project_snapshot()
  end

  defp project_snapshot(project) when is_map(project) do
    requests =
      project
      |> list_value(:requests)
      |> Enum.map(&record_snapshot/1)
      |> Enum.sort_by(&record_sort_key/1)
      |> Enum.take(@default_recent_limit)

    recent_evidence_fingerprints =
      value(project, :recent_evidence_fingerprints) || recent_evidence_fingerprints(requests)

    %{
      version: positive_integer(value(project, :version)) || @version,
      project_id: optional_string(project, :project_id) || "",
      status: normalize_record_status(value(project, :status) || project_status(requests)),
      counts: project_count_snapshot(value(project, :counts), requests),
      requests: requests,
      recent_reason_codes: string_list(value(project, :recent_reason_codes)) |> Enum.take(5),
      recent_action_codes: string_list(value(project, :recent_action_codes)) |> Enum.take(5),
      recent_evidence_fingerprints: sanitize_list(recent_evidence_fingerprints),
      outcome_link_statuses: sanitize_value(value(project, :outcome_link_statuses) || outcome_link_statuses(requests)),
      no_side_effects: value(project, :no_side_effects) != false,
      auto_replay_allowed: false
    }
  end

  defp project_snapshot(project), do: project_snapshot(%{project_id: project})

  defp request_list(nil, _now), do: []

  defp request_list(%{} = requests, now) do
    cond do
      is_list(value(requests, :requests)) ->
        request_list(value(requests, :requests), now)

      is_list(value(requests, :replay_requests)) ->
        request_list(value(requests, :replay_requests), now)

      is_list(value(requests, :cutover_replay_requests)) ->
        request_list(value(requests, :cutover_replay_requests), now)

      true ->
        [request_snapshot(requests, now)]
    end
  end

  defp request_list(requests, now) when is_list(requests), do: Enum.map(requests, &request_snapshot(&1, now))
  defp request_list(request, now), do: [request_snapshot(request, now)]

  defp overall_status([]), do: "no_request"

  defp overall_status(records) do
    cond do
      Enum.any?(records, &(&1.status == "malformed")) -> "malformed"
      Enum.any?(records, &(&1.status == "unsupported")) -> "unsupported"
      Enum.any?(records, &(&1.status == "conflict")) -> "conflict"
      Enum.any?(records, &(&1.status == "stale")) -> "stale"
      Enum.any?(records, &(&1.status == "manual_attention")) -> "manual_attention"
      Enum.any?(records, &(&1.status == "would_block")) -> "would_block"
      Enum.any?(records, &(&1.status == "would_allow_retry_consideration")) -> "would_allow_retry_consideration"
      true -> "no_request"
    end
  end

  defp normalize_status(status, records) do
    status = safe_status(status)
    if status in @statuses, do: status, else: overall_status(records)
  end

  defp normalize_record_status(status) do
    status = safe_status(status)
    if status in @statuses, do: status, else: "malformed"
  end

  defp project_status([]), do: "no_request"
  defp project_status(records), do: overall_status(records)

  defp count_snapshot(counts, records, project_ids) when is_map(counts) do
    %{
      project_count: non_negative_integer(value(counts, :project_count)) || length(project_ids),
      request_count: non_negative_integer(value(counts, :request_count)) || length(records),
      no_request_count: no_request_count(counts, records, project_ids),
      allow_count: record_count(counts, :allow_count, records, "would_allow_retry_consideration"),
      block_count: record_count(counts, :block_count, records, "would_block"),
      stale_count: record_count(counts, :stale_count, records, "stale"),
      conflict_count: record_count(counts, :conflict_count, records, "conflict"),
      manual_attention_count: record_count(counts, :manual_attention_count, records, "manual_attention"),
      malformed_count: record_count(counts, :malformed_count, records, "malformed"),
      unsupported_count: record_count(counts, :unsupported_count, records, "unsupported"),
      linked_outcome_recorded_count: outcome_link_count(counts, :linked_outcome_recorded_count, records, "outcome_recorded"),
      linked_outcome_pending_count: outcome_link_count(counts, :linked_outcome_pending_count, records, "outcome_still_pending"),
      linked_outcome_blocked_count: outcome_link_count(counts, :linked_outcome_blocked_count, records, "outcome_blocked"),
      linked_outcome_stale_count:
        non_negative_integer(value(counts, :linked_outcome_stale_count)) ||
          Enum.count(records, &(&1.outcome_link_status in ["outcome_stale", "outcome_conflict"])),
      operation_status_counts: operation_status_counts(value(counts, :operation_status_counts), records),
      source_status_counts: source_status_counts(value(counts, :source_status_counts), records)
    }
  end

  defp count_snapshot(_counts, records, project_ids), do: count_snapshot(%{}, records, project_ids)

  defp project_count_snapshot(counts, records) when is_map(counts) do
    %{
      request_count: non_negative_integer(value(counts, :request_count)) || length(records),
      allow_count: record_count(counts, :allow_count, records, "would_allow_retry_consideration"),
      block_count: record_count(counts, :block_count, records, "would_block"),
      stale_count: record_count(counts, :stale_count, records, "stale"),
      conflict_count: record_count(counts, :conflict_count, records, "conflict"),
      manual_attention_count: record_count(counts, :manual_attention_count, records, "manual_attention"),
      malformed_count: record_count(counts, :malformed_count, records, "malformed"),
      unsupported_count: record_count(counts, :unsupported_count, records, "unsupported"),
      linked_outcome_recorded_count: outcome_link_count(counts, :linked_outcome_recorded_count, records, "outcome_recorded"),
      linked_outcome_pending_count: outcome_link_count(counts, :linked_outcome_pending_count, records, "outcome_still_pending")
    }
  end

  defp project_count_snapshot(_counts, records), do: project_count_snapshot(%{}, records)

  defp no_request_count(counts, records, project_ids) do
    non_negative_integer(value(counts, :no_request_count)) ||
      Enum.count(project_ids, fn project_id ->
        not Enum.any?(records, &(optional_string(&1, :project_id) == project_id))
      end)
  end

  defp record_count(counts, key, records, status) do
    non_negative_integer(value(counts, key)) || Enum.count(records, &(&1.status == status))
  end

  defp outcome_link_count(counts, key, records, status) do
    non_negative_integer(value(counts, key)) || Enum.count(records, &(&1.outcome_link_status == status))
  end

  defp operation_status_counts(existing, _records) when is_map(existing) and map_size(existing) > 0 do
    SafeSummary.sanitize_map(existing, output_keys: :preserve)
  end

  defp operation_status_counts(_existing, records) do
    base = Map.new(@operations, &{String.to_atom(&1), status_zero_counts()})

    Enum.reduce(records, base, fn record, acc ->
      operation = operation_name(value(record, :operation)) |> String.to_atom()
      status = normalize_record_status(value(record, :status)) |> String.to_atom()

      Map.update(acc, operation, Map.update(status_zero_counts(), status, 1, &(&1 + 1)), fn counts ->
        Map.update(counts, status, 1, &(&1 + 1))
      end)
    end)
  end

  defp source_status_counts(existing, _records) when is_map(existing) and map_size(existing) > 0 do
    SafeSummary.sanitize_map(existing, output_keys: :preserve)
  end

  defp source_status_counts(_existing, records) do
    base = Map.new(@sources, &{String.to_atom(&1), status_zero_counts()})

    Enum.reduce(records, base, fn record, acc ->
      source = source_name(value(record, :side_effect_source)) |> String.to_atom()
      status = normalize_record_status(value(record, :status)) |> String.to_atom()

      Map.update(acc, source, Map.update(status_zero_counts(), status, 1, &(&1 + 1)), fn counts ->
        Map.update(counts, status, 1, &(&1 + 1))
      end)
    end)
  end

  defp status_zero_counts, do: Map.new(@statuses, &{String.to_atom(&1), 0})

  defp recent_codes(records, key) do
    records
    |> Enum.map(&value(&1, key))
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.map(&safe_status/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp recent_evidence_fingerprints(records) do
    records
    |> Enum.map(fn record ->
      %{
        request: optional_string(record, :request_fingerprint),
        audit: optional_string(record, :audit_record_fingerprint),
        outcome: optional_string(record, :outcome_fingerprint),
        closeout: optional_string(record, :closeout_record_fingerprint),
        replay_decision: optional_string(record, :replay_decision_fingerprint),
        readiness_permit: optional_string(record, :readiness_permit_fingerprint),
        authorization_record: optional_string(record, :authorization_record_fingerprint),
        consumption_guard: optional_string(record, :consumption_guard_fingerprint)
      }
      |> compact_map()
    end)
    |> Enum.reject(&(map_size(&1) == 0))
    |> Enum.take(5)
  end

  defp outcome_link_statuses(records) do
    base = Map.new(@outcome_link_statuses, &{String.to_atom(&1), 0})

    Enum.reduce(records, base, fn record, acc ->
      status = normalize_outcome_link_status(value(record, :outcome_link_status)) |> String.to_atom()
      Map.update(acc, status, 1, &(&1 + 1))
    end)
  end

  defp normalize_outcome_link_status(status) do
    status = safe_status(status)
    if status in @outcome_link_statuses, do: status, else: "not_linked"
  end

  defp project_ids_from_sources(sources) do
    [
      source_project_ids(value(sources, :projects)),
      source_project_ids(value(sources, :registry) || value(sources, :hub_project_registry)),
      source_project_ids(value(sources, :cutover_execution_outcome_ledger)),
      source_project_ids(value(sources, :cutover_execution_outcome_closeout)),
      source_project_ids(value(sources, :cutover_replay_decision)),
      source_project_ids(value(sources, :cutover_readiness_permit)),
      source_project_ids(value(sources, :cutover_execution_authorization_ledger)),
      source_project_ids(value(sources, :cutover_authorization_consumption_guard))
    ]
    |> List.flatten()
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp source_project_ids(%{projects: projects}), do: source_project_ids(projects)
  defp source_project_ids(projects) when is_list(projects), do: Enum.map(projects, &optional_string(&1, :project_id))
  defp source_project_ids(_projects), do: []

  defp project_ids_from_projects(projects, records) do
    [
      Enum.map(projects, &optional_string(&1, :project_id)),
      Enum.map(records, &optional_string(&1, :project_id))
    ]
    |> List.flatten()
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp snapshot_or_nil(_module, nil), do: nil

  defp snapshot_or_nil(module, value) when is_map(value) do
    module.to_snapshot(value)
  end

  defp snapshot_or_nil(_module, _value), do: nil

  defp ensure_audit_record_fingerprint(record) do
    Map.put(
      record,
      :audit_record_fingerprint,
      optional_string(record, :audit_record_fingerprint) || audit_record_fingerprint(record)
    )
  end

  defp request_fingerprint(request) do
    request
    |> Map.take([
      :project_id,
      :provider_scope,
      :operation,
      :side_effect_source,
      :replay_key,
      :outcome_fingerprint,
      :outcome_status,
      :closeout_record_fingerprint,
      :replay_decision_fingerprint,
      :authorization_record_fingerprint,
      :consumption_guard_fingerprint,
      :requested_at,
      :source,
      :action_code,
      :reason_code,
      :operator_note_digest
    ])
    |> fingerprint()
  end

  defp audit_record_fingerprint(record) do
    record
    |> Map.take([
      :request_fingerprint,
      :project_id,
      :operation,
      :side_effect_source,
      :replay_key,
      :outcome_fingerprint,
      :closeout_record_fingerprint,
      :replay_decision_fingerprint,
      :readiness_permit_fingerprint,
      :authorization_record_fingerprint,
      :consumption_guard_fingerprint,
      :status,
      :outcome_link_status
    ])
    |> fingerprint()
  end

  defp decision_fingerprint(nil), do: nil

  defp decision_fingerprint(decision) when is_map(decision) do
    optional_string(decision, :decision_fingerprint) ||
      optional_string(decision, :fingerprint) ||
      fingerprint(
        Map.take(decision, [
          :project_id,
          :provider_scope,
          :operation,
          :side_effect_source,
          :replay_key,
          :decision,
          :allowed,
          :outcome_fingerprint,
          :closeout_record_fingerprint,
          :authorization_record_fingerprint,
          :readiness_permit_fingerprint,
          :consumption_guard_fingerprint,
          :safe_evidence_fingerprints
        ])
      )
  end

  defp guard_fingerprint(nil), do: nil
  defp guard_fingerprint(guard) when is_map(guard), do: fingerprint(guard)

  defp outcome_identity(outcome) do
    [
      optional_string(outcome, :outcome_id),
      optional_string(outcome, :project_id),
      operation_name(value(outcome, :operation)),
      source_name(value(outcome, :side_effect_source)),
      optional_string(outcome, :replay_key),
      optional_string(outcome, :evidence_fingerprint),
      optional_string(outcome, :replay_request_fingerprint)
    ]
    |> Enum.join("|")
  end

  defp record_sort_key(record) do
    {
      iso8601(value(record, :requested_at)) || "",
      optional_string(record, :project_id) || "",
      operation_name(value(record, :operation)),
      source_name(value(record, :side_effect_source)),
      optional_string(record, :request_fingerprint) || ""
    }
  end

  defp default_reason("no_request"), do: "no_explicit_replay_request"
  defp default_reason("would_allow_retry_consideration"), do: "replay_request_evidence_matches"
  defp default_reason("would_block"), do: "replay_request_evidence_blocked"
  defp default_reason("stale"), do: "replay_request_evidence_stale"
  defp default_reason("conflict"), do: "replay_request_evidence_conflict"
  defp default_reason("manual_attention"), do: "replay_request_requires_manual_attention"
  defp default_reason("unsupported"), do: "replay_request_unsupported"
  defp default_reason("malformed"), do: "replay_request_malformed"
  defp default_reason(_status), do: "replay_request_malformed"

  defp default_action("would_block"), do: "refresh_replay_request_evidence"
  defp default_action("stale"), do: "refresh_replay_request_evidence"
  defp default_action("conflict"), do: "resolve_replay_request_conflict"
  defp default_action("manual_attention"), do: "resolve_replay_request_manual_attention"
  defp default_action("unsupported"), do: "fix_cutover_replay_request"
  defp default_action("malformed"), do: "fix_cutover_replay_request"
  defp default_action(_status), do: nil

  defp operation_name(value) do
    case safe_status(value) do
      "poll" -> "poll"
      "candidate_scan" -> "poll"
      "dispatch" -> "dispatch"
      "dispatch_plan_application" -> "dispatch"
      "dispatch_application" -> "dispatch"
      "worker_start" -> "worker_start"
      "worker" -> "worker_start"
      "writeback" -> "writeback"
      "stage_writeback" -> "writeback"
      "comment_workpad_upsert" -> "writeback"
      nil -> "unknown_operation"
      other -> other
    end
  end

  defp source_name(value) do
    case safe_status(value) do
      "candidate_scan" -> "candidate_scan"
      "poll" -> "candidate_scan"
      "dispatch_application" -> "dispatch_application"
      "dispatch_plan_application" -> "dispatch_application"
      "worker_start_handoff" -> "worker_start_handoff"
      "worker_start" -> "worker_start_handoff"
      "writeback_executor" -> "writeback_executor"
      "writeback" -> "writeback_executor"
      nil -> "unknown_source"
      other -> other
    end
  end

  defp source_operation_mismatch?(operation, source) do
    operation = operation_name(operation)
    source = source_name(source)

    source in @sources and operation in @operations and Map.fetch!(@source_operations, source) != operation
  end

  defp outcome_status(value) do
    status = safe_status(value)

    if status in [
         "unknown",
         "manual_attention",
         "not_executed",
         "blocked",
         "succeeded",
         "failed",
         "retryable",
         "unsupported",
         "malformed"
       ],
       do: status,
       else: nil
  end

  defp provider_scope_snapshot(scope) when is_map(scope) do
    scope = SafeSummary.sanitize_map(scope, output_keys: :preserve)

    %{
      kind: optional_string(scope, :kind) || optional_string(scope, :provider_kind),
      key: optional_string(scope, :key) || optional_string(scope, :provider_scope_key),
      provider_scope_key:
        optional_string(scope, :provider_scope_key) ||
          optional_string(scope, :key),
      scope:
        scope
        |> value(:scope)
        |> Kernel.||(%{})
        |> SafeSummary.sanitize_map(output_keys: :preserve)
    }
    |> compact_map()
  end

  defp provider_scope_snapshot(_scope), do: %{}

  defp side_effect_snapshot(value) when is_map(value) do
    may_have_happened =
      first_bound(value(value, :may_have_happened), value(value, :side_effect_may_have_happened))

    %{
      entered: boolean_value(first_bound(value(value, :entered), value(value, :side_effect_entered))),
      may_have_happened: boolean_value(may_have_happened)
    }
    |> compact_map()
  end

  defp side_effect_snapshot(_value), do: %{}

  defp note_digest(nil), do: %{}

  defp note_digest(note) when is_binary(note) do
    %{
      sha256: fingerprint(%{operator_note: note}),
      byte_size: byte_size(note)
    }
  end

  defp note_digest(note), do: note |> inspect() |> note_digest()

  defp fingerprint(value) do
    value
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp safe_fingerprint(nil, _key), do: nil

  defp safe_fingerprint(map, key) when is_map(map) do
    get_in_value(map, [:safe_evidence_fingerprints, key]) ||
      get_in_value(map, [:evidence_fingerprints, key])
  end

  defp value(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end

  defp value(_map, _key), do: nil

  defp get_in_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case value(acc, key) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
  end

  defp get_in_value(_map, _keys), do: nil

  defp list_value(map, key) do
    case value(map || %{}, key) do
      list when is_list(list) -> list
      nil -> []
      value -> List.wrap(value)
    end
  end

  defp sanitize_list(value) do
    value
    |> List.wrap()
    |> Enum.map(&SafeSummary.sanitize_map(&1, output_keys: :preserve))
  end

  defp sanitize_value(value), do: SafeSummary.sanitize_map(value || %{}, output_keys: :preserve)

  defp maybe_map(nil), do: nil
  defp maybe_map(map) when is_map(map), do: sanitize_value(map)
  defp maybe_map(_map), do: nil

  defp optional_string(map, key) when is_map(map) do
    case value(map, key) do
      nil ->
        nil

      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_atom(value) ->
        value |> Atom.to_string() |> optional_nonblank()

      value when is_integer(value) ->
        Integer.to_string(value)

      _value ->
        nil
    end
  end

  defp optional_string(_map, _key), do: nil

  defp optional_nonblank(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_list(value) do
    value
    |> List.wrap()
    |> Enum.map(fn
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end)
    |> Enum.reject(&blank?/1)
  end

  defp safe_status(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_:-]+/, "_")
    |> String.trim("_")
    |> blank_to_nil()
  end

  defp safe_status(nil), do: nil
  defp safe_status(value) when is_atom(value), do: value |> Atom.to_string() |> safe_status()
  defp safe_status(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_status(_value), do: nil

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp iso8601(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value)) ->
        {:ok, datetime, _offset} = DateTime.from_iso8601(value)
        DateTime.to_iso8601(datetime)

      true ->
        nil
    end
  end

  defp iso8601(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp boolean_value(value) when value in [true, false], do: value
  defp boolean_value(_value), do: nil

  defp first_bound(left, _right) when left in [true, false], do: left
  defp first_bound(nil, right), do: right
  defp first_bound("", right), do: right
  defp first_bound(left, _right), do: left

  defp truthy?(value), do: value in [true, "true", true, 1, "1", "yes", :yes]
  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
  defp bound?(value), do: not blank?(value)
  defp bound_equal?(left, right), do: bound?(left) and bound?(right) and left == right

  defp blank_to_nil(value) do
    cond do
      is_nil(value) -> nil
      is_binary(value) -> if(String.trim(value) == "", do: nil, else: value)
      true -> value
    end
  end

  defp blank_to_default(nil, default), do: default
  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == %{} or value == [] end)
    |> Map.new()
  end
end
