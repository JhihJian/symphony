defmodule SymphonyElixir.Hub.CutoverReplayDecision do
  @moduledoc """
  Closeout-aware Hub cutover execution replay decision baseline.

  The decision is a pre-side-effect summary. It can allow an explicit execution
  path to continue past a matching unresolved outcome only after the current
  authorization consumption guard is already allowed and a matching closeout
  permits retry consideration. It never creates authorization, consumes
  authorization, calls providers, starts workers, writes back, operates systemd,
  or edits configuration.
  """

  alias SymphonyElixir.Hub.{
    CutoverAuthorizationConsumptionGuard,
    CutoverExecutionOutcomeCloseout,
    CutoverExecutionOutcomeLedger,
    SafeSummary
  }

  @version 1
  @operations ["poll", "dispatch", "worker_start", "writeback"]
  @sources ["candidate_scan", "dispatch_application", "worker_start_handoff", "writeback_executor"]
  @decisions [
    "no_unresolved_outcome",
    "blocked_unresolved_outcome",
    "retry_consideration_allowed",
    "retry_consideration_denied",
    "stale_closeout",
    "conflict",
    "manual_attention",
    "malformed",
    "unsupported"
  ]
  @terminal_decisions ["no_unresolved_outcome", "retry_consideration_allowed"]
  @default_recent_limit 20
  @source_operations %{
    "candidate_scan" => "poll",
    "dispatch_application" => "dispatch",
    "worker_start_handoff" => "worker_start",
    "writeback_executor" => "writeback"
  }

  @type decision :: map()
  @type summary :: map()

  @spec evaluate(term()) :: decision()
  def evaluate(input), do: evaluate(input, [])

  @spec evaluate(term(), keyword()) :: decision()
  def evaluate(input, opts) when is_map(input) and is_list(opts) do
    now =
      opts
      |> Keyword.get(:now)
      |> Kernel.||(value(input, :evaluated_at))
      |> Kernel.||(DateTime.utc_now())
      |> iso8601()

    input = Map.put_new(input, :evaluated_at, now)

    try do
      input
      |> safe_evaluate()
      |> decision_snapshot()
    rescue
      _error -> malformed_decision(input, now, "replay_decision_error")
    catch
      _kind, _reason -> malformed_decision(input, now, "replay_decision_error")
    end
  end

  def evaluate(_input, opts) when is_list(opts) do
    now = opts |> Keyword.get(:now) |> Kernel.||(DateTime.utc_now()) |> iso8601()
    malformed_decision(%{evaluated_at: now}, now, "replay_decision_input_malformed")
  end

  @spec require_allowed(map(), keyword()) :: {:ok, decision()} | {:blocked, decision()}
  def require_allowed(input, opts \\ []) when is_list(opts) do
    decision = evaluate(input, opts)

    if decision.allowed do
      {:ok, decision}
    else
      {:blocked, decision}
    end
  end

  @spec to_decision(term()) :: decision()
  def to_decision(decision), do: decision_snapshot(decision)

  @spec build(term(), keyword()) :: summary()
  def build(sources, opts \\ []) when is_list(opts) do
    now =
      opts
      |> Keyword.get(:now)
      |> Kernel.||(value(sources, :generated_at))
      |> Kernel.||(DateTime.utc_now())
      |> iso8601()

    events =
      opts
      |> Keyword.get(:events, [])
      |> List.wrap()
      |> Kernel.++(events_from_sources(sources))
      |> Enum.map(&decision_snapshot/1)
      |> Enum.reject(&blank?(value(&1, :project_id)))
      |> Enum.uniq_by(&decision_identity/1)
      |> Enum.sort_by(&event_sort_key/1)

    %{
      version: @version,
      generated_at: now,
      status: overall_status(events),
      counts: count_snapshot(%{}, events),
      recent_decisions: Enum.take(events, @default_recent_limit),
      blocked_replay: blocked_replay(events),
      projects: project_summaries(events),
      no_side_effects: true,
      auto_replay_allowed: false
    }
    |> to_snapshot()
  end

  @spec to_snapshot(term()) :: summary()
  def to_snapshot(summary) when is_map(summary) do
    recent_decisions =
      summary
      |> list_value(:recent_decisions)
      |> Enum.map(&decision_snapshot/1)
      |> Enum.sort_by(&event_sort_key/1)
      |> Enum.take(@default_recent_limit)

    projects =
      summary
      |> list_value(:projects)
      |> Enum.map(&project_snapshot/1)
      |> Enum.sort_by(& &1.project_id)

    events =
      if recent_decisions == [] and projects != [] do
        Enum.flat_map(projects, & &1.recent_decisions)
      else
        recent_decisions
      end

    projects =
      if projects == [] and events != [] do
        project_summaries(events)
      else
        projects
      end

    generated_at = iso8601(value(summary, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      version: positive_integer(value(summary, :version)) || @version,
      generated_at: generated_at,
      status: normalize_overall_status(value(summary, :status), events),
      counts: count_snapshot(value(summary, :counts), events),
      recent_decisions: recent_decisions,
      blocked_replay: blocked_replay_snapshots(value(summary, :blocked_replay), events),
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

  defp safe_evaluate(input) do
    now = iso8601(value(input, :evaluated_at)) || DateTime.utc_now() |> DateTime.to_iso8601()
    candidate = outcome_candidate(input)
    authorization = authorization_decision(input)
    outcome_ledger = outcome_ledger(input)
    closeout_summary = closeout_summary(input)

    cond do
      blank?(candidate.project_id) ->
        base_decision(input, candidate, authorization, nil, nil, "malformed", "project_id_missing", "fix_replay_decision_input", now)

      candidate.operation not in @operations ->
        base_decision(input, candidate, authorization, nil, nil, "unsupported", "unknown_operation", "choose_supported_operations", now)

      candidate.side_effect_source not in @sources ->
        base_decision(input, candidate, authorization, nil, nil, "unsupported", "unsupported_side_effect_source", "use_supported_side_effect_source", now)

      Map.fetch!(@source_operations, candidate.side_effect_source) != candidate.operation ->
        base_decision(
          input,
          candidate,
          authorization,
          nil,
          nil,
          "unsupported",
          "side_effect_source_operation_mismatch",
          "fix_replay_decision_operation",
          now
        )

      not is_map(outcome_ledger) ->
        base_decision(input, candidate, authorization, nil, nil, "no_unresolved_outcome", "execution_outcome_ledger_missing", nil, now)

      true ->
        decide_with_ledger(input, candidate, authorization, outcome_ledger, closeout_summary, now)
    end
  end

  defp decide_with_ledger(input, candidate, authorization, outcome_ledger, closeout_summary, now) do
    unresolved = CutoverExecutionOutcomeLedger.find_unresolved(outcome_ledger, candidate)

    cond do
      unresolved == nil ->
        base_decision(input, candidate, authorization, nil, nil, "no_unresolved_outcome", "no_matching_unresolved_outcome", nil, now)

      not allowed_authorization?(authorization) ->
        base_decision(
          input,
          candidate,
          authorization,
          unresolved,
          nil,
          "blocked_unresolved_outcome",
          "authorization_consumption_not_allowed",
          "obtain_current_authorization_consumption",
          now
        )

      not is_map(closeout_summary) ->
        base_decision(
          input,
          candidate,
          authorization,
          unresolved,
          nil,
          "blocked_unresolved_outcome",
          "matching_closeout_missing",
          "record_execution_outcome_closeout",
          now
        )

      true ->
        decide_with_closeout(input, candidate, authorization, unresolved, closeout_summary, now)
    end
  end

  defp decide_with_closeout(input, candidate, authorization, unresolved, closeout_summary, now) do
    closeouts = matching_closeouts(closeout_summary, unresolved, candidate)

    cond do
      closeouts == [] ->
        decision_from_related_closeouts(input, candidate, authorization, unresolved, closeout_summary, now)

      multiple_current_closeouts?(closeouts) ->
        base_decision(input, candidate, authorization, unresolved, List.first(closeouts), "conflict", "multiple_matching_closeouts", "resolve_closeout_conflict", now)

      true ->
        closeout = List.first(closeouts)
        closeout_decision(input, candidate, authorization, unresolved, closeout, now)
    end
  end

  defp closeout_decision(input, candidate, authorization, unresolved, closeout, now) do
    cond do
      closeout.status != "resolved" ->
        base_decision(
          input,
          candidate,
          authorization,
          unresolved,
          closeout,
          decision_from_closeout_status(closeout.status),
          reason_from_closeout_status(closeout.status),
          action_from_closeout_status(closeout.status),
          now
        )

      closeout.allow_explicit_retry_consideration != true ->
        base_decision(
          input,
          candidate,
          authorization,
          unresolved,
          closeout,
          "retry_consideration_denied",
          "closeout_resolution_does_not_allow_retry_consideration",
          "record_retry_consideration_closeout",
          now
        )

      reason = evidence_mismatch_reason(closeout, unresolved, authorization) ->
        base_decision(input, candidate, authorization, unresolved, closeout, "stale_closeout", reason, "refresh_closeout_for_current_evidence", now)

      side_effect_safety_conflict?(closeout, unresolved, candidate) ->
        base_decision(input, candidate, authorization, unresolved, closeout, "conflict", "side_effect_safety_conflict", "resolve_replay_safety_conflict", now)

      true ->
        base_decision(
          input,
          candidate,
          authorization,
          unresolved,
          closeout,
          "retry_consideration_allowed",
          "matching_closeout_allows_explicit_retry_consideration",
          nil,
          now
        )
    end
  end

  defp decision_from_related_closeouts(input, candidate, authorization, unresolved, closeout_summary, now) do
    related = related_closeouts(closeout_summary, candidate, unresolved)

    cond do
      related == [] ->
        base_decision(
          input,
          candidate,
          authorization,
          unresolved,
          nil,
          "blocked_unresolved_outcome",
          "matching_closeout_missing",
          "record_execution_outcome_closeout",
          now
        )

      Enum.any?(related, &(&1.status == "malformed")) ->
        base_decision(input, candidate, authorization, unresolved, List.first(related), "malformed", "matching_closeout_malformed", "fix_execution_outcome_closeout", now)

      Enum.any?(related, &(&1.status == "unsupported")) ->
        base_decision(input, candidate, authorization, unresolved, List.first(related), "unsupported", "matching_closeout_unsupported", "fix_execution_outcome_closeout", now)

      Enum.any?(related, &(&1.status == "conflict")) ->
        base_decision(input, candidate, authorization, unresolved, List.first(related), "conflict", "matching_closeout_conflict", "resolve_closeout_conflict", now)

      Enum.any?(related, &(&1.status == "stale")) ->
        base_decision(input, candidate, authorization, unresolved, List.first(related), "stale_closeout", "matching_closeout_stale", "refresh_closeout_for_current_evidence", now)

      Enum.any?(related, &(&1.status == "manual_attention")) ->
        base_decision(input, candidate, authorization, unresolved, List.first(related), "manual_attention", "matching_closeout_requires_follow_up", "resolve_execution_outcome_follow_up", now)

      true ->
        base_decision(
          input,
          candidate,
          authorization,
          unresolved,
          List.first(related),
          "blocked_unresolved_outcome",
          "matching_retry_closeout_missing",
          "record_retry_consideration_closeout",
          now
        )
    end
  end

  defp base_decision(input, candidate, authorization, outcome, closeout, decision, reason, action, now) do
    allowed = decision in @terminal_decisions
    outcome = maybe_outcome_snapshot(outcome)
    closeout = maybe_closeout_snapshot(closeout)
    authorization = maybe_authorization_snapshot(authorization)

    %{
      version: @version,
      project_id: candidate.project_id,
      provider_scope: candidate.provider_scope,
      operation: candidate.operation,
      side_effect_source: candidate.side_effect_source,
      replay_key: candidate.replay_key,
      decision: decision,
      allowed: allowed,
      reason_code: reason,
      action_code: action,
      reason_codes: reason_codes(reason, closeout),
      required_operator_actions: action_snapshots([action]),
      unresolved_outcome: outcome,
      outcome_replay_key: optional_string(outcome || %{}, :replay_key) || candidate.replay_key,
      outcome_fingerprint: optional_string(outcome || %{}, :evidence_fingerprint),
      outcome_status: optional_string(outcome || %{}, :status),
      outcome_side_effect:
        side_effect_snapshot(
          outcome || candidate,
          candidate
        ),
      matching_closeout: closeout,
      closeout_record_fingerprint: optional_string(closeout || %{}, :closeout_record_fingerprint),
      closeout_resolution_code: optional_string(closeout || %{}, :resolution_code),
      closeout_operator_request_fingerprint: optional_string(closeout || %{}, :operator_request_fingerprint),
      closeout_created_at: optional_string(closeout || %{}, :created_at),
      closeout_closed_at: optional_string(closeout || %{}, :closed_at),
      authorization_consumption_guard: authorization,
      guard_decision: optional_string(authorization || %{}, :decision),
      authorization_record_fingerprint:
        optional_string(input, :authorization_record_fingerprint) ||
          optional_string(authorization || %{}, :authorization_record_fingerprint) ||
          optional_string(outcome || %{}, :authorization_record_fingerprint),
      authorization_request_fingerprint:
        optional_string(input, :authorization_request_fingerprint) ||
          optional_string(authorization || %{}, :authorization_request_fingerprint) ||
          optional_string(outcome || %{}, :authorization_request_fingerprint),
      cutover_operation_request_fingerprint:
        optional_string(input, :cutover_operation_request_fingerprint) ||
          safe_fingerprint(authorization, :cutover_operation_request) ||
          optional_string(outcome || %{}, :cutover_operation_request_fingerprint),
      readiness_permit_fingerprint:
        optional_string(input, :readiness_permit_fingerprint) ||
          safe_fingerprint(authorization, :readiness_permit) ||
          optional_string(outcome || %{}, :readiness_permit_fingerprint),
      readiness_permit_decision:
        safe_status(
          value(input, :readiness_permit_decision) ||
            safe_fingerprint(authorization, :readiness_permit_decision) ||
            optional_string(outcome || %{}, :readiness_permit_decision)
        ),
      consumption_guard_fingerprint: safe_fingerprint(outcome, :consumption_guard),
      safe_evidence_fingerprints: safe_evidence_fingerprints(input, authorization, outcome),
      evaluated_at: now,
      no_side_effects: true,
      auto_replay_allowed: false,
      requires_operator_attention: requires_operator_attention?(decision)
    }
    |> compact_map()
  end

  defp malformed_decision(input, now, reason) do
    candidate = %{
      project_id: optional_string(input, :project_id),
      provider_scope: %{},
      operation: "unknown_operation",
      side_effect_source: "unknown_source",
      replay_key: nil
    }

    input
    |> base_decision(
      candidate,
      nil,
      nil,
      nil,
      "malformed",
      reason,
      "fix_replay_decision_input",
      now
    )
    |> decision_snapshot()
  end

  defp decision_snapshot(decision) when is_map(decision) do
    decision_name = normalize_decision(value(decision, :decision))
    allowed = value(decision, :allowed) == true and decision_name in @terminal_decisions
    reason_code = safe_status(value(decision, :reason_code)) |> blank_to_default(default_reason(decision_name))
    action_code = safe_status(value(decision, :action_code)) |> blank_to_nil()
    authorization_guard = value(decision, :authorization_consumption_guard)

    requires_attention? =
      truthy?(value(decision, :requires_operator_attention)) or requires_operator_attention?(decision_name)

    snapshot =
      %{
        version: positive_integer(value(decision, :version)) || @version,
        project_id: optional_string(decision, :project_id),
        provider_scope: provider_scope_snapshot(value(decision, :provider_scope) || %{}),
        operation: operation_name(value(decision, :operation)),
        side_effect_source: source_name(value(decision, :side_effect_source) || value(decision, :source)),
        replay_key: optional_string(decision, :replay_key) || optional_string(decision, :outcome_replay_key),
        decision: decision_name,
        allowed: allowed,
        reason_code: reason_code,
        action_code: action_code,
        reason_codes:
          decision
          |> list_value(:reason_codes)
          |> Kernel.++([reason_code])
          |> string_list()
          |> Enum.uniq()
          |> Enum.sort(),
        required_operator_actions: action_snapshots(value(decision, :required_operator_actions) || List.wrap(action_code)),
        unresolved_outcome: maybe_outcome_snapshot(value(decision, :unresolved_outcome)),
        outcome_replay_key: optional_string(decision, :outcome_replay_key) || optional_string(decision, :replay_key),
        outcome_fingerprint: optional_string(decision, :outcome_fingerprint),
        outcome_status: outcome_status(value(decision, :outcome_status)),
        outcome_side_effect:
          side_effect_snapshot(
            value(decision, :outcome_side_effect),
            value(decision, :unresolved_outcome) || decision
          ),
        matching_closeout: maybe_closeout_snapshot(value(decision, :matching_closeout)),
        closeout_record_fingerprint: optional_string(decision, :closeout_record_fingerprint),
        closeout_resolution_code: optional_string(decision, :closeout_resolution_code),
        closeout_operator_request_fingerprint: optional_string(decision, :closeout_operator_request_fingerprint),
        closeout_created_at: iso8601(value(decision, :closeout_created_at)),
        closeout_closed_at: iso8601(value(decision, :closeout_closed_at)),
        authorization_consumption_guard: maybe_authorization_snapshot(authorization_guard),
        guard_decision: safe_status(value(decision, :guard_decision)) |> blank_to_nil(),
        authorization_record_fingerprint: optional_string(decision, :authorization_record_fingerprint),
        authorization_request_fingerprint: optional_string(decision, :authorization_request_fingerprint),
        cutover_operation_request_fingerprint: optional_string(decision, :cutover_operation_request_fingerprint),
        readiness_permit_fingerprint: optional_string(decision, :readiness_permit_fingerprint),
        readiness_permit_decision: safe_status(value(decision, :readiness_permit_decision)) |> blank_to_nil(),
        consumption_guard_fingerprint: optional_string(decision, :consumption_guard_fingerprint),
        safe_evidence_fingerprints:
          SafeSummary.sanitize_map(value(decision, :safe_evidence_fingerprints) || %{},
            output_keys: :preserve
          ),
        evaluated_at: iso8601(value(decision, :evaluated_at)),
        no_side_effects: value(decision, :no_side_effects) != false,
        auto_replay_allowed: false,
        requires_operator_attention: requires_attention?
      }
      |> compact_map()

    Map.put(
      snapshot,
      :replay_decision_fingerprint,
      optional_string(decision, :replay_decision_fingerprint) ||
        optional_string(decision, :decision_fingerprint) ||
        replay_decision_fingerprint(snapshot)
    )
  end

  defp decision_snapshot(decision), do: decision_snapshot(%{decision: decision})

  defp project_snapshot(project) when is_map(project) do
    decisions =
      project
      |> list_value(:recent_decisions)
      |> Enum.map(&decision_snapshot/1)
      |> Enum.sort_by(&event_sort_key/1)
      |> Enum.take(@default_recent_limit)

    project_id = optional_string(project, :project_id) || decisions |> List.first() |> optional_string(:project_id)

    %{
      version: positive_integer(value(project, :version)) || @version,
      project_id: project_id,
      status: normalize_project_status(value(project, :status), decisions),
      counts: count_snapshot(value(project, :counts), decisions),
      recent_decisions: decisions,
      blocked_replay: blocked_replay_snapshots(value(project, :blocked_replay), decisions),
      recent_reason_codes: recent_codes(decisions, :reason_code),
      recent_action_codes: recent_codes(decisions, :action_code),
      safe_evidence_fingerprints: project_fingerprints(decisions),
      requires_operator_attention: Enum.any?(decisions, & &1.requires_operator_attention),
      no_side_effects: value(project, :no_side_effects) != false,
      auto_replay_allowed: false
    }
  end

  defp project_snapshot(project), do: project_snapshot(%{project_id: project})

  defp outcome_candidate(input) do
    raw =
      value(input, :candidate) ||
        value(input, :execution_outcome) ||
        value(input, :outcome) ||
        input

    CutoverExecutionOutcomeLedger.fact_snapshot(raw)
  end

  defp authorization_decision(input) do
    raw =
      value(input, :authorization_consumption_guard) ||
        value(input, :authorization_consumption) ||
        value(input, :consumption_guard)

    if is_map(raw), do: CutoverAuthorizationConsumptionGuard.to_decision(raw)
  end

  defp outcome_ledger(input) do
    value(input, :cutover_execution_outcome_ledger) || value(input, :execution_outcome_ledger)
  end

  defp closeout_summary(input) do
    raw =
      value(input, :cutover_execution_outcome_closeout) ||
        value(input, :execution_outcome_closeout) ||
        value(input, :closeout_summary)

    if is_map(raw), do: CutoverExecutionOutcomeCloseout.to_snapshot(raw)
  end

  defp maybe_outcome_snapshot(nil), do: nil
  defp maybe_outcome_snapshot(outcome) when is_map(outcome), do: outcome_snapshot(outcome)
  defp maybe_outcome_snapshot(_outcome), do: nil

  defp outcome_snapshot(outcome) when is_map(outcome) do
    outcome = CutoverExecutionOutcomeLedger.fact_snapshot(outcome)

    %{
      outcome_id: optional_string(outcome, :outcome_id),
      attempt_fingerprint: optional_string(outcome, :attempt_fingerprint),
      replay_key: optional_string(outcome, :replay_key),
      project_id: optional_string(outcome, :project_id),
      provider_scope: provider_scope_snapshot(value(outcome, :provider_scope) || %{}),
      operation: operation_name(value(outcome, :operation)),
      side_effect_source: source_name(value(outcome, :side_effect_source)),
      status: outcome_status(value(outcome, :status)),
      reason_code: safe_status(value(outcome, :reason_code)) |> blank_to_nil(),
      action_code: safe_status(value(outcome, :action_code)) |> blank_to_nil(),
      reason_codes: string_list(value(outcome, :reason_codes)),
      authorization_record_fingerprint: optional_string(outcome, :authorization_record_fingerprint),
      authorization_request_fingerprint: optional_string(outcome, :authorization_request_fingerprint),
      cutover_operation_request_fingerprint: optional_string(outcome, :cutover_operation_request_fingerprint),
      readiness_permit_fingerprint: optional_string(outcome, :readiness_permit_fingerprint),
      readiness_permit_decision: safe_status(value(outcome, :readiness_permit_decision)) |> blank_to_nil(),
      cutover_gate_fingerprint: optional_string(outcome, :cutover_gate_fingerprint),
      dry_run_audit_fingerprint: optional_string(outcome, :dry_run_audit_fingerprint),
      audit_history_fingerprint: optional_string(outcome, :audit_history_fingerprint),
      evidence_fingerprint: optional_string(outcome, :evidence_fingerprint),
      safe_evidence_fingerprints:
        SafeSummary.sanitize_map(value(outcome, :safe_evidence_fingerprints) || %{},
          output_keys: :preserve
        ),
      side_effect_entered: value(outcome, :side_effect_entered) == true,
      side_effect_may_have_happened: value(outcome, :side_effect_may_have_happened) == true,
      replay_blocked: value(outcome, :replay_blocked) != false,
      unresolved: value(outcome, :unresolved) == true,
      started_at: iso8601(value(outcome, :started_at)),
      completed_at: iso8601(value(outcome, :completed_at)),
      generated_at: iso8601(value(outcome, :generated_at))
    }
    |> compact_map()
  end

  defp maybe_closeout_snapshot(nil), do: nil
  defp maybe_closeout_snapshot(closeout) when is_map(closeout), do: closeout_snapshot(closeout)
  defp maybe_closeout_snapshot(_closeout), do: nil

  defp maybe_authorization_snapshot(nil), do: nil
  defp maybe_authorization_snapshot(authorization) when is_map(authorization), do: CutoverAuthorizationConsumptionGuard.to_decision(authorization)
  defp maybe_authorization_snapshot(_authorization), do: nil

  defp matching_closeouts(closeout_summary, unresolved, candidate) do
    closeout_summary
    |> all_closeouts()
    |> Enum.filter(fn closeout ->
      same_project_operation_source?(closeout, candidate) and
        optional_string(closeout, :replay_key) == optional_string(unresolved, :replay_key) and
        optional_string(closeout, :outcome_fingerprint) == optional_string(unresolved, :evidence_fingerprint) and
        outcome_status(value(closeout, :outcome_status)) == outcome_status(value(unresolved, :status))
    end)
    |> Enum.sort_by(&closeout_sort_key/1)
  end

  defp related_closeouts(closeout_summary, candidate, unresolved) do
    closeout_summary
    |> all_closeouts()
    |> Enum.filter(fn closeout ->
      same_project_operation_source?(closeout, candidate) and
        (optional_string(closeout, :replay_key) == optional_string(candidate, :replay_key) or
           optional_string(closeout, :replay_key) == optional_string(unresolved, :replay_key) or
           optional_string(closeout, :outcome_fingerprint) == optional_string(unresolved, :evidence_fingerprint))
    end)
    |> Enum.sort_by(&closeout_sort_key/1)
  end

  defp all_closeouts(summary) do
    (list_value(summary, :recent_closeouts) ++
       Enum.flat_map(list_value(summary, :projects), &list_value(&1, :closeouts)))
    |> Enum.map(&closeout_snapshot/1)
    |> Enum.uniq_by(&optional_string(&1, :closeout_record_fingerprint))
  end

  defp closeout_snapshot(closeout) when is_map(closeout) do
    %{
      closeout_id: optional_string(closeout, :closeout_id),
      closeout_record_fingerprint: optional_string(closeout, :closeout_record_fingerprint),
      project_id: optional_string(closeout, :project_id),
      provider_scope: provider_scope_snapshot(value(closeout, :provider_scope) || %{}),
      operation: operation_name(value(closeout, :operation)),
      side_effect_source: source_name(value(closeout, :side_effect_source)),
      replay_key: optional_string(closeout, :replay_key),
      outcome_id: optional_string(closeout, :outcome_id),
      outcome_fingerprint: optional_string(closeout, :outcome_fingerprint),
      outcome_status: outcome_status(value(closeout, :outcome_status)),
      outcome_side_effect:
        value(closeout, :outcome_side_effect)
        |> side_effect_snapshot(closeout),
      cutover_operation_request_fingerprint: optional_string(closeout, :cutover_operation_request_fingerprint),
      authorization_record_fingerprint: optional_string(closeout, :authorization_record_fingerprint),
      authorization_request_fingerprint: optional_string(closeout, :authorization_request_fingerprint),
      readiness_permit_fingerprint: optional_string(closeout, :readiness_permit_fingerprint),
      readiness_permit_decision: safe_status(value(closeout, :readiness_permit_decision)) |> blank_to_nil(),
      cutover_gate_fingerprint: optional_string(closeout, :cutover_gate_fingerprint),
      dry_run_audit_fingerprint: optional_string(closeout, :dry_run_audit_fingerprint),
      audit_history_fingerprint: optional_string(closeout, :audit_history_fingerprint),
      consumption_guard_fingerprint: optional_string(closeout, :consumption_guard_fingerprint),
      safe_evidence_fingerprints:
        SafeSummary.sanitize_map(value(closeout, :safe_evidence_fingerprints) || %{},
          output_keys: :preserve
        ),
      resolution_code: safe_status(value(closeout, :resolution_code)) |> blank_to_nil(),
      reason_code: safe_status(value(closeout, :reason_code)) |> blank_to_nil(),
      action_code: safe_status(value(closeout, :action_code)) |> blank_to_nil(),
      operator_request_fingerprint: optional_string(closeout, :operator_request_fingerprint),
      created_at: iso8601(value(closeout, :created_at)),
      closed_at: iso8601(value(closeout, :closed_at)),
      status: closeout_status(value(closeout, :status)),
      status_reasons: string_list(value(closeout, :status_reasons)),
      allow_explicit_retry_consideration: truthy?(value(closeout, :allow_explicit_retry_consideration)),
      auto_replay_allowed: false,
      no_side_effects: value(closeout, :no_side_effects) != false
    }
    |> compact_map()
  end

  defp same_project_operation_source?(record, candidate) do
    optional_string(record, :project_id) == optional_string(candidate, :project_id) and
      operation_name(value(record, :operation)) == operation_name(value(candidate, :operation)) and
      source_name(value(record, :side_effect_source)) == source_name(value(candidate, :side_effect_source)) and
      provider_scope_matches?(value(record, :provider_scope), value(candidate, :provider_scope))
  end

  defp provider_scope_matches?(record_scope, candidate_scope) do
    record_scope = provider_scope_snapshot(record_scope || %{})
    candidate_scope = provider_scope_snapshot(candidate_scope || %{})

    cond do
      record_scope == %{} or candidate_scope == %{} ->
        true

      optional_string(record_scope, :provider_scope_key) != nil and
          optional_string(candidate_scope, :provider_scope_key) != nil ->
        optional_string(record_scope, :provider_scope_key) == optional_string(candidate_scope, :provider_scope_key)

      true ->
        record_scope == candidate_scope
    end
  end

  defp allowed_authorization?(%{allowed: true, decision: "allowed"}), do: true
  defp allowed_authorization?(_authorization), do: false

  defp multiple_current_closeouts?(closeouts) do
    closeouts
    |> Enum.filter(&(&1.status == "resolved" and &1.allow_explicit_retry_consideration == true))
    |> length()
    |> Kernel.>(1)
  end

  defp evidence_mismatch_reason(closeout, unresolved, authorization) do
    [
      mismatch(
        closeout,
        unresolved,
        :authorization_record_fingerprint,
        :authorization_record_fingerprint,
        "authorization_record_fingerprint_mismatch"
      ),
      mismatch(
        closeout,
        unresolved,
        :authorization_request_fingerprint,
        :authorization_request_fingerprint,
        "authorization_request_fingerprint_mismatch"
      ),
      mismatch(
        closeout,
        unresolved,
        :readiness_permit_fingerprint,
        :readiness_permit_fingerprint,
        "readiness_permit_fingerprint_mismatch"
      ),
      mismatch(
        closeout,
        unresolved,
        :cutover_gate_fingerprint,
        :cutover_gate_fingerprint,
        "cutover_gate_fingerprint_mismatch"
      ),
      mismatch(
        closeout,
        unresolved,
        :cutover_operation_request_fingerprint,
        :cutover_operation_request_fingerprint,
        "cutover_operation_request_fingerprint_mismatch"
      ),
      mismatch(closeout, unresolved, :dry_run_audit_fingerprint, :dry_run_audit_fingerprint, "dry_run_audit_fingerprint_mismatch"),
      mismatch(
        closeout,
        unresolved,
        :audit_history_fingerprint,
        :audit_history_fingerprint,
        "audit_history_fingerprint_mismatch"
      ),
      mismatch_with_value(
        closeout,
        safe_fingerprint(unresolved, :consumption_guard),
        :consumption_guard_fingerprint,
        "consumption_guard_fingerprint_mismatch"
      ),
      mismatch_with_value(
        closeout,
        optional_string(authorization || %{}, :authorization_record_fingerprint),
        :authorization_record_fingerprint,
        "current_authorization_record_fingerprint_mismatch"
      ),
      mismatch_with_value(
        closeout,
        optional_string(authorization || %{}, :authorization_request_fingerprint),
        :authorization_request_fingerprint,
        "current_authorization_request_fingerprint_mismatch"
      ),
      mismatch_with_value(
        closeout,
        safe_fingerprint(authorization, :readiness_permit),
        :readiness_permit_fingerprint,
        "current_readiness_permit_fingerprint_mismatch"
      ),
      mismatch_with_value(
        closeout,
        safe_fingerprint(authorization, :cutover_operation_request),
        :cutover_operation_request_fingerprint,
        "current_cutover_operation_request_fingerprint_mismatch"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> List.first()
  end

  defp mismatch(closeout, outcome, closeout_key, outcome_key, reason) do
    mismatch_with_value(closeout, outcome_value(outcome, outcome_key), closeout_key, reason)
  end

  defp mismatch_with_value(closeout, current_value, closeout_key, reason) do
    closeout_value = optional_string(closeout, closeout_key)

    if bound?(closeout_value) and bound?(current_value) and closeout_value != current_value do
      reason
    end
  end

  defp outcome_value(outcome, key) do
    optional_string(outcome, key) || safe_fingerprint(outcome, key_to_safe_fingerprint(key))
  end

  defp key_to_safe_fingerprint(:authorization_record_fingerprint), do: :authorization_record
  defp key_to_safe_fingerprint(:authorization_request_fingerprint), do: :authorization_request
  defp key_to_safe_fingerprint(:readiness_permit_fingerprint), do: :readiness_permit
  defp key_to_safe_fingerprint(:cutover_operation_request_fingerprint), do: :cutover_operation_request
  defp key_to_safe_fingerprint(:cutover_gate_fingerprint), do: :cutover_gate
  defp key_to_safe_fingerprint(:dry_run_audit_fingerprint), do: :dry_run_audit
  defp key_to_safe_fingerprint(:audit_history_fingerprint), do: :audit_history

  defp side_effect_safety_conflict?(closeout, unresolved, candidate) do
    side_effect_conflict?(closeout, unresolved, :side_effect_entered) or
      side_effect_conflict?(closeout, unresolved, :side_effect_may_have_happened) or
      side_effect_conflict?(closeout, candidate, :side_effect_entered) or
      side_effect_conflict?(closeout, candidate, :side_effect_may_have_happened)
  end

  defp side_effect_conflict?(closeout, current, key) do
    closeout_value =
      case key do
        :side_effect_entered ->
          get_in_value(closeout, [:outcome_side_effect, :entered]) ||
            value(closeout, :side_effect_entered)

        :side_effect_may_have_happened ->
          get_in_value(closeout, [:outcome_side_effect, :may_have_happened]) ||
            value(closeout, :side_effect_may_have_happened)
      end

    current_value = value(current, key)
    closeout_value in [true, false] and current_value in [true, false] and closeout_value != current_value
  end

  defp decision_from_closeout_status("stale"), do: "stale_closeout"
  defp decision_from_closeout_status("conflict"), do: "conflict"
  defp decision_from_closeout_status("manual_attention"), do: "manual_attention"
  defp decision_from_closeout_status("malformed"), do: "malformed"
  defp decision_from_closeout_status("unsupported"), do: "unsupported"
  defp decision_from_closeout_status(_status), do: "blocked_unresolved_outcome"

  defp reason_from_closeout_status("stale"), do: "matching_closeout_stale"
  defp reason_from_closeout_status("conflict"), do: "matching_closeout_conflict"
  defp reason_from_closeout_status("manual_attention"), do: "matching_closeout_requires_follow_up"
  defp reason_from_closeout_status("malformed"), do: "matching_closeout_malformed"
  defp reason_from_closeout_status("unsupported"), do: "matching_closeout_unsupported"
  defp reason_from_closeout_status(_status), do: "matching_closeout_not_resolved"

  defp action_from_closeout_status("stale"), do: "refresh_closeout_for_current_evidence"
  defp action_from_closeout_status("conflict"), do: "resolve_closeout_conflict"
  defp action_from_closeout_status("manual_attention"), do: "resolve_execution_outcome_follow_up"
  defp action_from_closeout_status("malformed"), do: "fix_execution_outcome_closeout"
  defp action_from_closeout_status("unsupported"), do: "fix_execution_outcome_closeout"
  defp action_from_closeout_status(_status), do: "record_retry_consideration_closeout"

  defp safe_evidence_fingerprints(input, authorization, outcome) do
    current =
      value(input, :safe_evidence_fingerprints) ||
        value(input, :current_fingerprints) ||
        value(input, :evidence_fingerprints) ||
        %{}

    outcome_evidence = value(outcome || %{}, :safe_evidence_fingerprints) || %{}
    authorization_evidence = value(authorization || %{}, :safe_evidence_fingerprints) || %{}

    outcome_evidence
    |> Map.merge(authorization_evidence)
    |> Map.merge(current)
    |> SafeSummary.sanitize_map(output_keys: :preserve)
  end

  defp safe_fingerprint(nil, _key), do: nil
  defp safe_fingerprint(map, key) when is_map(map), do: get_in_value(map, [:safe_evidence_fingerprints, key])

  defp reason_codes(reason, nil), do: string_list([reason])

  defp reason_codes(reason, closeout) do
    ([reason] ++ string_list(value(closeout, :status_reasons)))
    |> string_list()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp action_snapshots(actions) do
    actions
    |> string_list()
    |> Enum.map(&%{code: &1})
  end

  defp side_effect_snapshot(side_effect, fallback) when is_map(side_effect) do
    %{
      entered:
        first_boolean([
          boolean_field(side_effect, :entered),
          boolean_field(side_effect, :side_effect_entered),
          boolean_field(fallback, :side_effect_entered)
        ]),
      may_have_happened:
        first_boolean([
          boolean_field(side_effect, :may_have_happened),
          boolean_field(side_effect, :side_effect_may_have_happened),
          boolean_field(fallback, :side_effect_may_have_happened)
        ])
    }
    |> compact_map()
  end

  defp side_effect_snapshot(_side_effect, fallback) do
    side_effect_snapshot(%{}, fallback || %{})
  end

  defp requires_operator_attention?(decision) do
    decision not in ["no_unresolved_outcome", "retry_consideration_allowed"]
  end

  defp events_from_sources(sources) do
    summary_events(value(sources, :cutover_replay_decision) || value(sources, :hub_cutover_replay_decision)) ++
      list_value(sources, :replay_decisions) ++
      list_value(sources, :decisions) ++
      list_value(sources, :events) ++
      unresolved_outcome_events(sources) ++
      tick_events(value(sources, :tick) || value(sources, :poll_tick)) ++
      dispatch_events(value(sources, :dispatch_plan_application) || value(sources, :hub_dispatch_plan_application)) ++
      worker_start_events(value(sources, :worker_start_handoff) || value(sources, :hub_worker_start_handoff)) ++
      writeback_events(value(sources, :writeback) || value(sources, :hub_writeback))
  end

  defp summary_events(summary) when is_map(summary) do
    direct =
      cond do
        is_binary(value(summary, :decision)) -> [summary]
        list_value(summary, :recent_decisions) != [] -> list_value(summary, :recent_decisions)
        true -> []
      end

    project_events =
      summary
      |> list_value(:projects)
      |> Enum.flat_map(&list_value(&1, :recent_decisions))

    direct ++ project_events
  end

  defp summary_events(summary) when is_list(summary), do: summary
  defp summary_events(_summary), do: []

  defp unresolved_outcome_events(sources) do
    outcome_ledger = outcome_ledger(sources)

    if is_map(outcome_ledger) do
      outcome_ledger
      |> CutoverExecutionOutcomeLedger.to_snapshot()
      |> list_value(:unresolved_outcomes)
      |> Enum.map(fn outcome ->
        evaluate(%{
          candidate: outcome,
          authorization_consumption_guard: authorization_for_outcome(sources, outcome),
          cutover_execution_outcome_ledger: outcome_ledger,
          cutover_execution_outcome_closeout: closeout_summary(sources)
        })
      end)
    else
      []
    end
  end

  defp authorization_for_outcome(sources, outcome) do
    inline = value(outcome, :authorization_consumption_guard)

    if is_map(inline) do
      inline
    else
      guard =
        value(sources, :cutover_authorization_consumption_guard) ||
          value(sources, :authorization_consumption_guard)

      guard
      |> all_authorization_decisions()
      |> Enum.find(fn decision ->
        same_project_operation_source?(decision, outcome) and
          provider_scope_matches?(value(decision, :provider_scope), value(outcome, :provider_scope))
      end)
    end
  end

  defp all_authorization_decisions(guard) when is_map(guard) do
    direct =
      cond do
        is_binary(value(guard, :decision)) -> [guard]
        list_value(guard, :recent_decisions) != [] -> list_value(guard, :recent_decisions)
        true -> []
      end

    project_decisions =
      guard
      |> list_value(:projects)
      |> Enum.flat_map(&list_value(&1, :recent_decisions))

    (direct ++ project_decisions)
    |> Enum.map(&CutoverAuthorizationConsumptionGuard.to_decision/1)
  end

  defp all_authorization_decisions(guard) when is_list(guard) do
    Enum.map(guard, &CutoverAuthorizationConsumptionGuard.to_decision/1)
  end

  defp all_authorization_decisions(_guard), do: []

  defp tick_events(tick) do
    tick
    |> list_value(:results)
    |> Enum.map(&value(&1, :replay_decision))
    |> Enum.filter(&is_map/1)
  end

  defp dispatch_events(summary) do
    summary
    |> list_value(:projects)
    |> Enum.flat_map(&list_value(&1, :outcomes))
    |> Enum.map(&value(&1, :replay_decision))
    |> Enum.filter(&is_map/1)
  end

  defp worker_start_events(summary) do
    summary
    |> list_value(:results)
    |> Enum.map(&value(&1, :replay_decision))
    |> Enum.filter(&is_map/1)
  end

  defp writeback_events(writeback) do
    writeback
    |> list_value(:recent_results)
    |> Enum.map(&(get_in_value(&1, [:result_summary, :replay_decision]) || get_in_value(&1, [:result_summary, "replay_decision"])))
    |> Enum.filter(&is_map/1)
  end

  defp project_summaries(events) do
    events
    |> Enum.group_by(& &1.project_id)
    |> Enum.map(fn {project_id, decisions} ->
      %{
        project_id: project_id,
        status: project_status(decisions),
        counts: count_snapshot(%{}, decisions),
        recent_decisions: Enum.take(decisions, @default_recent_limit),
        blocked_replay: blocked_replay(decisions),
        recent_reason_codes: recent_codes(decisions, :reason_code),
        recent_action_codes: recent_codes(decisions, :action_code),
        safe_evidence_fingerprints: project_fingerprints(decisions),
        requires_operator_attention: Enum.any?(decisions, & &1.requires_operator_attention),
        no_side_effects: true,
        auto_replay_allowed: false
      }
      |> project_snapshot()
    end)
  end

  defp count_snapshot(counts, events) when is_map(counts) do
    %{
      decision_count: non_negative_integer(value(counts, :decision_count)) || length(events),
      unresolved_outcome_blocked_count:
        non_negative_integer(value(counts, :unresolved_outcome_blocked_count)) ||
          Enum.count(events, &(&1.decision == "blocked_unresolved_outcome")),
      retry_consideration_allowed_count:
        non_negative_integer(value(counts, :retry_consideration_allowed_count)) ||
          Enum.count(events, &(&1.decision == "retry_consideration_allowed")),
      retry_consideration_denied_count:
        non_negative_integer(value(counts, :retry_consideration_denied_count)) ||
          Enum.count(events, &(&1.decision == "retry_consideration_denied")),
      stale_closeout_count: non_negative_integer(value(counts, :stale_closeout_count)) || Enum.count(events, &(&1.decision == "stale_closeout")),
      conflict_count: non_negative_integer(value(counts, :conflict_count)) || Enum.count(events, &(&1.decision == "conflict")),
      manual_attention_count: non_negative_integer(value(counts, :manual_attention_count)) || Enum.count(events, &(&1.decision == "manual_attention")),
      malformed_count: non_negative_integer(value(counts, :malformed_count)) || Enum.count(events, &(&1.decision == "malformed")),
      unsupported_count: non_negative_integer(value(counts, :unsupported_count)) || Enum.count(events, &(&1.decision == "unsupported")),
      no_unresolved_outcome_count:
        non_negative_integer(value(counts, :no_unresolved_outcome_count)) ||
          Enum.count(events, &(&1.decision == "no_unresolved_outcome")),
      requires_operator_attention_count:
        non_negative_integer(value(counts, :requires_operator_attention_count)) ||
          Enum.count(events, & &1.requires_operator_attention),
      operation_decision_counts:
        value(counts, :operation_decision_counts) ||
          operation_decision_counts(events),
      source_decision_counts:
        value(counts, :source_decision_counts) ||
          source_decision_counts(events)
    }
  end

  defp count_snapshot(_counts, events), do: count_snapshot(%{}, events)

  defp operation_decision_counts(events) do
    base = Map.new(@operations, &{String.to_atom(&1), decision_zero_counts()})

    Enum.reduce(events, base, fn event, acc ->
      operation = operation_name(value(event, :operation)) |> String.to_atom()
      decision = normalize_decision(value(event, :decision)) |> String.to_atom()

      Map.update(acc, operation, Map.update(decision_zero_counts(), decision, 1, &(&1 + 1)), fn counts ->
        Map.update(counts, decision, 1, &(&1 + 1))
      end)
    end)
  end

  defp source_decision_counts(events) do
    base = Map.new(@sources, &{String.to_atom(&1), decision_zero_counts()})

    Enum.reduce(events, base, fn event, acc ->
      source = source_name(value(event, :side_effect_source)) |> String.to_atom()
      decision = normalize_decision(value(event, :decision)) |> String.to_atom()

      Map.update(acc, source, Map.update(decision_zero_counts(), decision, 1, &(&1 + 1)), fn counts ->
        Map.update(counts, decision, 1, &(&1 + 1))
      end)
    end)
  end

  defp decision_zero_counts, do: Map.new(@decisions, &{String.to_atom(&1), 0})

  defp blocked_replay(events) do
    events
    |> Enum.reject(& &1.allowed)
    |> Enum.map(&blocked_replay_snapshot/1)
    |> Enum.take(@default_recent_limit)
  end

  defp blocked_replay_snapshots(blocked_replay, events) do
    case list_value(%{blocked_replay: blocked_replay}, :blocked_replay) do
      [] -> blocked_replay(events)
      values -> values |> Enum.map(&blocked_replay_snapshot/1) |> Enum.take(@default_recent_limit)
    end
  end

  defp blocked_replay_snapshot(event) when is_map(event) do
    %{
      project_id: optional_string(event, :project_id),
      operation: operation_name(value(event, :operation)),
      side_effect_source: source_name(value(event, :side_effect_source)),
      replay_key: optional_string(event, :replay_key) || optional_string(event, :outcome_replay_key),
      decision: normalize_decision(value(event, :decision)),
      reason_code:
        safe_status(value(event, :reason_code))
        |> blank_to_default(default_reason(normalize_decision(value(event, :decision)))),
      action_code: safe_status(value(event, :action_code)) |> blank_to_nil(),
      outcome_fingerprint: optional_string(event, :outcome_fingerprint),
      closeout_record_fingerprint: optional_string(event, :closeout_record_fingerprint),
      authorization_record_fingerprint: optional_string(event, :authorization_record_fingerprint),
      readiness_permit_fingerprint: optional_string(event, :readiness_permit_fingerprint),
      consumption_guard_fingerprint: optional_string(event, :consumption_guard_fingerprint)
    }
    |> compact_map()
  end

  defp blocked_replay_snapshot(event), do: blocked_replay_snapshot(%{decision: event})

  defp overall_status([]), do: "no_replay_decision"

  defp overall_status(events) do
    cond do
      Enum.any?(events, &(&1.decision == "malformed")) -> "malformed"
      Enum.any?(events, &(&1.decision == "unsupported")) -> "unsupported"
      Enum.any?(events, &(&1.decision == "conflict")) -> "conflict"
      Enum.any?(events, &(&1.decision == "manual_attention")) -> "manual_attention"
      Enum.any?(events, &(&1.decision == "stale_closeout")) -> "stale_closeout"
      Enum.any?(events, &(&1.decision == "blocked_unresolved_outcome")) -> "blocked_unresolved_outcome"
      Enum.any?(events, &(&1.decision == "retry_consideration_denied")) -> "retry_consideration_denied"
      Enum.any?(events, &(&1.decision == "retry_consideration_allowed")) -> "retry_consideration_allowed"
      Enum.any?(events, &(&1.decision == "no_unresolved_outcome")) -> "no_unresolved_outcome"
      true -> "no_replay_decision"
    end
  end

  defp project_status(events), do: overall_status(events)

  defp normalize_overall_status(status, events) do
    status = safe_status(status)
    if status in ["no_replay_decision" | @decisions], do: status, else: overall_status(events)
  end

  defp normalize_project_status(status, events) do
    status = safe_status(status)
    if status in ["no_replay_decision" | @decisions], do: status, else: project_status(events)
  end

  defp normalize_decision(decision) do
    decision = safe_status(decision)
    if decision in @decisions, do: decision, else: "blocked_unresolved_outcome"
  end

  defp default_reason("no_unresolved_outcome"), do: "no_matching_unresolved_outcome"
  defp default_reason("retry_consideration_allowed"), do: "matching_closeout_allows_explicit_retry_consideration"
  defp default_reason("retry_consideration_denied"), do: "closeout_resolution_does_not_allow_retry_consideration"
  defp default_reason("stale_closeout"), do: "matching_closeout_stale"
  defp default_reason("conflict"), do: "replay_decision_conflict"
  defp default_reason("manual_attention"), do: "replay_decision_manual_attention"
  defp default_reason("malformed"), do: "replay_decision_malformed"
  defp default_reason("unsupported"), do: "replay_decision_unsupported"
  defp default_reason(_decision), do: "unresolved_execution_outcome"

  defp recent_codes(events, key) do
    events
    |> Enum.map(&safe_status(value(&1, key)))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp project_fingerprints(events) do
    events
    |> Enum.flat_map(fn event ->
      event
      |> value(:safe_evidence_fingerprints)
      |> SafeSummary.sanitize_map(output_keys: :preserve)
      |> Enum.to_list()
    end)
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Enum.uniq()
    |> Map.new()
  end

  defp event_sort_key(event) do
    {
      optional_string(event, :evaluated_at) || "",
      optional_string(event, :project_id) || "",
      operation_name(value(event, :operation)),
      source_name(value(event, :side_effect_source)),
      optional_string(event, :replay_key) || ""
    }
  end

  defp decision_identity(event) do
    {
      optional_string(event, :project_id),
      operation_name(value(event, :operation)),
      source_name(value(event, :side_effect_source)),
      optional_string(event, :replay_key) || optional_string(event, :outcome_replay_key),
      normalize_decision(value(event, :decision)),
      safe_status(value(event, :reason_code))
    }
  end

  defp replay_decision_fingerprint(decision) do
    decision
    |> Map.take([
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
    |> fingerprint()
  end

  defp fingerprint(value) do
    value
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp closeout_sort_key(closeout) do
    {
      optional_string(closeout, :closed_at) || optional_string(closeout, :created_at) || "",
      optional_string(closeout, :project_id) || "",
      operation_name(value(closeout, :operation)),
      source_name(value(closeout, :side_effect_source)),
      optional_string(closeout, :replay_key) || "",
      optional_string(closeout, :closeout_record_fingerprint) || ""
    }
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

  defp closeout_status(status) do
    status = safe_status(status)

    if status in ["resolved", "stale", "conflict", "manual_attention", "malformed", "unsupported"] do
      status
    else
      "malformed"
    end
  end

  defp string_list(value) when is_list(value) do
    value
    |> Enum.map(&safe_status/1)
    |> Enum.reject(&blank?/1)
  end

  defp string_list(nil), do: []
  defp string_list(value), do: value |> safe_status() |> List.wrap() |> Enum.reject(&blank?/1)

  defp safe_status(nil), do: nil
  defp safe_status(value) when is_atom(value), do: value |> Atom.to_string() |> safe_status()

  defp safe_status(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_:-]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> nil
      status -> status
    end
  end

  defp safe_status(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_status(_value), do: nil

  defp value(map, key) when is_map(map) do
    Map.get(map, key) ||
      Map.get(map, Atom.to_string(key)) ||
      if(is_binary(key), do: Map.get(map, String.to_atom(key)), else: nil)
  end

  defp value(_map, _key), do: nil

  defp get_in_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, map, fn key, current ->
      case value(current, key) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
  end

  defp get_in_value(_map, _keys), do: nil

  defp list_value(map, key) when is_map(map) do
    case value(map, key) do
      value when is_list(value) -> value
      _value -> []
    end
  end

  defp list_value(_map, _key), do: []

  defp optional_string(map, key) when is_map(map), do: map |> value(key) |> optional_string()
  defp optional_string(value, _key), do: optional_string(value)
  defp optional_string(nil), do: nil

  defp optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(_value), do: nil

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      _error -> optional_string(value)
    end
  end

  defp iso8601(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp truthy?(value), do: value in [true, "true", "yes", "1", 1]
  defp bound?(value), do: not blank?(value)
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp first_boolean(values), do: Enum.find(List.wrap(values), &is_boolean/1)

  defp boolean_field(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> value
      _other -> boolean_field(map, Atom.to_string(key))
    end
  end

  defp boolean_field(map, key) when is_map(map), do: Map.get(map, key)
  defp boolean_field(_map, _key), do: nil

  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: value)
  defp blank_to_default(value, default), do: if(blank?(value), do: default, else: value)

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
