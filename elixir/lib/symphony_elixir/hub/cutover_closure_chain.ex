defmodule SymphonyElixir.Hub.CutoverClosureChain do
  @moduledoc """
  Minimal read-only Hub cutover closure chain contract.

  The chain binds one explicit cutover attempt or replay attempt to the safe
  request, permit, authorization, consumption guard, and outcome evidence that
  already exists in other Hub summaries or tests. It is deliberately model-only:
  it never creates or consumes authorization, calls providers, dispatches work,
  starts workers, writes providers, operates systemd, or edits configuration.
  """

  alias SymphonyElixir.Hub.{
    CutoverAuthorizationConsumptionGuard,
    CutoverExecutionOutcomeLedger,
    SafeSummary
  }

  @version 1
  @operations ["poll", "dispatch", "worker_start", "writeback"]
  @sources ["candidate_scan", "dispatch_application", "worker_start_handoff", "writeback_executor"]
  @statuses [
    "no_chain",
    "no_request",
    "closed_succeeded",
    "closed_no_side_effect",
    "open_retryable",
    "open_manual_attention",
    "conflict",
    "stale",
    "malformed",
    "unsupported"
  ]
  @source_operations %{
    "candidate_scan" => "poll",
    "dispatch_application" => "dispatch",
    "worker_start_handoff" => "worker_start",
    "writeback_executor" => "writeback"
  }
  @blocking_guard_decisions ["blocked", "no_authorization", "stale", "manual_attention", "unsupported", "malformed"]
  @blocking_authorization_statuses ["blocked", "no_ready_permit", "stale", "manual_attention", "unsupported", "malformed"]
  @blocking_permit_decisions ["blocked", "stale", "manual_attention", "unsupported", "malformed"]
  @open_retryable_outcome_statuses ["retryable"]
  @open_manual_attention_outcome_statuses ["unknown", "manual_attention"]
  @future_open_outcome_statuses ["failed"]
  @reference_statuses ["missing", "current", "stale", "conflict", "malformed", "unsupported"]
  @reference_types ["closeout", "replay_decision", "replay_request_audit"]
  @closeout_record_statuses ["resolved", "stale", "conflict", "manual_attention", "malformed", "unsupported"]
  @closeout_resolution_codes [
    "confirmed_resolved",
    "confirmed_failed",
    "abandoned_no_retry",
    "allow_explicit_retry_consideration",
    "requires_follow_up"
  ]
  @retry_closeout_resolution_codes ["allow_explicit_retry_consideration"]
  @operator_sources ["operator_file", "operator_cli", "test", "api", "hub_startup_option", "operator"]
  @replay_decisions [
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
  @replay_request_statuses [
    "no_request",
    "would_allow_retry_consideration",
    "would_block",
    "stale",
    "conflict",
    "manual_attention",
    "malformed",
    "unsupported"
  ]
  @replay_outcome_link_statuses [
    "not_linked",
    "outcome_recorded",
    "outcome_still_pending",
    "outcome_blocked",
    "outcome_stale",
    "outcome_conflict",
    "outcome_manual_attention"
  ]
  @default_recent_limit 20

  @type chain :: map()
  @type summary :: map()

  @spec build(term(), keyword()) :: summary()
  def build(sources, opts \\ []) when is_list(opts) do
    now =
      opts
      |> Keyword.get(:now)
      |> Kernel.||(value(sources, :generated_at))
      |> Kernel.||(DateTime.utc_now())
      |> iso8601()

    project_ids_from_sources = project_ids_from_sources(sources)

    chains =
      sources
      |> events_from_sources(opts)
      |> Enum.map(&chain_snapshot(&1, now))
      |> Enum.reject(&drop_chain?/1)
      |> Enum.uniq_by(&chain_identity/1)
      |> Enum.sort_by(&chain_sort_key/1)

    project_ids =
      [project_ids_from_sources, Enum.map(chains, &optional_string(&1, :project_id))]
      |> List.flatten()
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.sort()

    projects =
      project_ids
      |> Enum.map(&project_summary(&1, chains))
      |> Enum.sort_by(& &1.project_id)

    %{
      version: @version,
      generated_at: now,
      evaluated_at: now,
      status: overall_status(chains, project_ids),
      operation_set: @operations,
      source_set: @sources,
      read_only: true,
      no_side_effects: true,
      auto_replay_allowed: false,
      counts: count_snapshot(%{}, chains, project_ids),
      recent_chains: Enum.take(chains, @default_recent_limit),
      recent_reference_reason_codes: recent_reference_codes(chains, :reason_code),
      recent_reference_action_codes: recent_reference_codes(chains, :action_code),
      projects: projects
    }
    |> to_snapshot()
  end

  @spec to_snapshot(term()) :: summary()
  def to_snapshot(summary) when is_map(summary) do
    generated_at = iso8601(value(summary, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601()

    chains =
      summary
      |> list_value(:recent_chains)
      |> Enum.map(&chain_snapshot(&1, generated_at))
      |> Enum.sort_by(&chain_sort_key/1)
      |> Enum.take(@default_recent_limit)

    projects =
      summary
      |> list_value(:projects)
      |> Enum.map(&project_snapshot/1)
      |> Enum.sort_by(& &1.project_id)

    chains =
      if chains == [] and projects != [] do
        projects
        |> Enum.flat_map(&list_value(&1, :closure_chains))
        |> Enum.map(&chain_snapshot(&1, generated_at))
        |> Enum.sort_by(&chain_sort_key/1)
        |> Enum.take(@default_recent_limit)
      else
        chains
      end

    project_ids =
      projects
      |> Enum.map(&optional_string(&1, :project_id))
      |> Kernel.++(Enum.map(chains, &optional_string(&1, :project_id)))
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.sort()

    projects =
      if projects == [] and project_ids != [] do
        Enum.map(project_ids, &project_summary(&1, chains))
      else
        projects
      end

    %{
      version: positive_integer(value(summary, :version)) || @version,
      generated_at: generated_at,
      evaluated_at: iso8601(value(summary, :evaluated_at)) || generated_at,
      status: normalize_overall_status(value(summary, :status), chains, project_ids),
      operation_set: operation_list(value(summary, :operation_set)) |> default_operations(),
      source_set: source_list(value(summary, :source_set)) |> default_sources(),
      read_only: value(summary, :read_only) != false,
      no_side_effects: value(summary, :no_side_effects) != false,
      auto_replay_allowed: false,
      counts: count_snapshot(value(summary, :counts), chains, project_ids),
      recent_chains: chains,
      recent_reference_reason_codes: recent_reference_codes(chains, :reason_code),
      recent_reference_action_codes: recent_reference_codes(chains, :action_code),
      projects: projects
    }
  end

  def to_snapshot(_summary), do: to_snapshot(%{})

  @spec observability_snapshot(term()) :: summary() | nil
  def observability_snapshot(nil), do: nil
  def observability_snapshot(summary) when is_map(summary), do: to_snapshot(summary)
  def observability_snapshot(_summary), do: nil

  @spec chain_snapshot(term()) :: chain()
  def chain_snapshot(input), do: chain_snapshot(input, DateTime.utc_now() |> DateTime.to_iso8601())

  defp chain_snapshot(input, now) do
    input
    |> chain_input()
    |> safe_chain_snapshot(now)
  rescue
    _error -> malformed_chain(input, now)
  catch
    _kind, _reason -> malformed_chain(input, now)
  end

  defp chain_input(input) when is_map(input) do
    cond do
      is_map(value(input, :outcome)) or is_map(value(input, :execution_outcome)) ->
        input

      outcome_like?(input) and blank?(value(input, :closure_status)) ->
        %{outcome: input}

      true ->
        input
    end
  end

  defp chain_input(input), do: %{malformed_input: input}

  defp safe_chain_snapshot(input, now) do
    outcome = outcome_snapshot(value(input, :outcome) || value(input, :execution_outcome))

    guard =
      guard_snapshot(
        value(input, :consumption_guard) ||
          value(input, :authorization_consumption_guard) ||
          value(outcome || %{}, :authorization_consumption_guard)
      )

    provider_scope =
      provider_scope_snapshot(
        value(input, :provider_scope) ||
          value(outcome || %{}, :provider_scope) ||
          value(guard || %{}, :provider_scope) ||
          %{}
      )

    operation =
      operation_name(
        value(input, :operation) ||
          value(outcome || %{}, :operation) ||
          value(guard || %{}, :operation)
      )

    side_effect_source =
      source_name(
        value(input, :side_effect_source) ||
          value(input, :source_boundary) ||
          value(input, :source) ||
          value(outcome || %{}, :side_effect_source) ||
          value(guard || %{}, :side_effect_source)
      )

    request = request_binding(input, outcome)
    readiness_permit = readiness_permit_binding(input, outcome)
    authorization = authorization_binding(input, outcome)
    consumption_guard = guard_binding(input, guard, outcome)
    outcome_binding = outcome_binding(outcome)
    evidence = evidence_fingerprints(input, outcome, request, readiness_permit, authorization, consumption_guard)

    snapshot = %{
      version: positive_integer(value(input, :version)) || @version,
      closure_chain_id: optional_string(input, :closure_chain_id),
      project_id:
        optional_string(input, :project_id) ||
          optional_string(outcome || %{}, :project_id) ||
          optional_string(guard || %{}, :project_id),
      provider_scope: provider_scope,
      operation: operation,
      source: side_effect_source,
      side_effect_source: side_effect_source,
      execution_key:
        execution_key_snapshot(
          optional_string(input, :attempt_fingerprint) ||
            optional_string(outcome || %{}, :attempt_fingerprint),
          optional_string(input, :replay_key) || optional_string(outcome || %{}, :replay_key)
        ),
      attempt_fingerprint:
        optional_string(input, :attempt_fingerprint) ||
          optional_string(outcome || %{}, :attempt_fingerprint),
      replay_key: optional_string(input, :replay_key) || optional_string(outcome || %{}, :replay_key),
      request: request,
      readiness_permit: readiness_permit,
      authorization: authorization,
      consumption_guard: consumption_guard,
      outcome: outcome_binding,
      retained_references: retained_references(input),
      safe_evidence_fingerprints: evidence,
      safe_evidence_fingerprint: nil,
      time_summary: time_summary(input, outcome, request, readiness_permit, authorization, consumption_guard, now),
      read_only: true,
      no_side_effects: true,
      auto_replay_allowed: false
    }

    validation = validation_reasons(snapshot, input, outcome, guard)
    status = closure_status(snapshot, outcome, guard, validation)

    snapshot =
      snapshot
      |> Map.merge(status)
      |> Map.put(:safe_evidence_fingerprint, optional_string(input, :safe_evidence_fingerprint) || safe_evidence_fingerprint(snapshot))
      |> compact_map()

    snapshot =
      snapshot
      |> Map.put(:retained_reference_statuses, retained_reference_statuses(snapshot))
      |> compact_map()

    snapshot
    |> Map.put(:closure_chain_id, optional_string(snapshot, :closure_chain_id) || closure_chain_id(snapshot))
    |> compact_map()
  end

  defp malformed_chain(input, now) do
    %{
      version: @version,
      project_id: optional_string(input, :project_id),
      provider_scope: provider_scope_snapshot(value(input, :provider_scope) || %{}),
      operation: operation_name(value(input, :operation)),
      source: source_name(value(input, :side_effect_source) || value(input, :source)),
      side_effect_source: source_name(value(input, :side_effect_source) || value(input, :source)),
      closure_status: "malformed",
      reason_code: "closure_chain_input_malformed",
      action_code: "fix_closure_chain_input",
      reason_codes: ["closure_chain_input_malformed"],
      required_operator_actions: action_snapshots(["fix_closure_chain_input"]),
      retained_references: %{},
      safe_evidence_fingerprints: %{},
      time_summary: %{generated_at: now, evaluated_at: now},
      read_only: true,
      no_side_effects: true,
      auto_replay_allowed: false
    }
    |> Map.put(:safe_evidence_fingerprint, safe_evidence_fingerprint(%{}))
    |> Map.put(:closure_chain_id, "hub-cutover-closure-chain:" <> fingerprint(%{generated_at: now, malformed: true}))
  end

  defp closure_status(snapshot, outcome, guard, validation) do
    cond do
      reason = first_level(validation, "malformed") ->
        status_snapshot("malformed", reason.code, reason.action, validation, snapshot, outcome, guard)

      reason = first_level(validation, "unsupported") ->
        status_snapshot("unsupported", reason.code, reason.action, validation, snapshot, outcome, guard)

      reason = first_level(validation, "conflict") ->
        status_snapshot("conflict", reason.code, reason.action, validation, snapshot, outcome, guard)

      reason = first_level(validation, "stale") ->
        status_snapshot("stale", reason.code, reason.action, validation, snapshot, outcome, guard)

      blank?(get_in_value(snapshot, [:request, :request_fingerprint])) ->
        status_snapshot("no_request", "cutover_operation_request_missing", "submit_cutover_operation_request", validation, snapshot, outcome, guard)

      blank?(snapshot.attempt_fingerprint) and blank?(snapshot.replay_key) ->
        status_snapshot(
          "malformed",
          "attempt_or_replay_key_missing",
          "refresh_execution_outcome",
          validation,
          snapshot,
          outcome,
          guard
        )

      outcome == nil ->
        status_snapshot(
          "unsupported",
          "execution_outcome_required",
          "record_matching_execution_outcome",
          validation,
          snapshot,
          outcome,
          guard
        )

      value(outcome, :status) == "succeeded" ->
        succeeded_status(snapshot, outcome, guard, validation)

      value(outcome, :status) in @open_retryable_outcome_statuses ->
        open_outcome_status("open_retryable", snapshot, outcome, guard, validation)

      value(outcome, :status) in @open_manual_attention_outcome_statuses ->
        open_outcome_status("open_manual_attention", snapshot, outcome, guard, validation)

      closed_no_side_effect?(snapshot, outcome, guard) ->
        status_snapshot(
          "closed_no_side_effect",
          no_side_effect_reason(snapshot, outcome, guard),
          no_side_effect_action(snapshot, outcome, guard),
          validation,
          snapshot,
          outcome,
          guard
        )

      value(outcome, :status) in @future_open_outcome_statuses ->
        status_snapshot(
          "unsupported",
          "open_outcome_closure_not_in_minimal_contract",
          "wait_for_followup_closure_slice",
          validation,
          snapshot,
          outcome,
          guard
        )

      value(outcome, :status) in ["unsupported", "malformed"] ->
        status_snapshot(
          value(outcome, :status),
          outcome_reason(outcome, "execution_outcome_#{value(outcome, :status)}"),
          outcome_action(outcome),
          validation,
          snapshot,
          outcome,
          guard
        )

      true ->
        status_snapshot(
          "unsupported",
          "execution_outcome_status_not_supported",
          "wait_for_followup_closure_slice",
          validation,
          snapshot,
          outcome,
          guard
        )
    end
  end

  defp open_outcome_status(status, snapshot, outcome, guard, validation) do
    case missing_open_evidence(snapshot, outcome, guard) do
      nil ->
        status_snapshot(
          status,
          open_outcome_reason(status, outcome),
          open_outcome_action(status, outcome),
          validation,
          snapshot,
          outcome,
          guard
        )

      missing ->
        status_snapshot("malformed", missing, "refresh_closure_chain_evidence", validation, snapshot, outcome, guard)
    end
  end

  defp succeeded_status(snapshot, outcome, guard, validation) do
    cond do
      value(outcome, :side_effect_entered) == false ->
        status_snapshot("conflict", "succeeded_outcome_without_side_effect_entry", "resolve_outcome_side_effect_conflict", validation, snapshot, outcome, guard)

      is_map(guard) and value(guard, :decision) not in ["allowed", nil, ""] ->
        status_snapshot("conflict", "succeeded_outcome_guard_not_allowed", "resolve_closure_guard_conflict", validation, snapshot, outcome, guard)

      missing = missing_success_evidence(snapshot, outcome, guard) ->
        status_snapshot("malformed", missing, "refresh_closure_chain_evidence", validation, snapshot, outcome, guard)

      true ->
        status_snapshot("closed_succeeded", outcome_reason(outcome, "execution_succeeded"), outcome_action(outcome), validation, snapshot, outcome, guard)
    end
  end

  defp closed_no_side_effect?(snapshot, outcome, guard) when is_map(outcome) do
    side_effect_clear? =
      value(outcome, :side_effect_entered) == false and
        value(outcome, :side_effect_may_have_happened) != true and
        value(outcome, :no_side_effects) == true

    blocked_before_side_effect? =
      value(outcome, :status) in ["not_executed", "blocked"] or
        (is_map(guard) and value(guard, :decision) in @blocking_guard_decisions) or
        get_in_value(snapshot, [:authorization, :status]) in @blocking_authorization_statuses or
        get_in_value(snapshot, [:readiness_permit, :decision]) in @blocking_permit_decisions or
        Enum.any?(list_value(snapshot, :reason_codes), &String.contains?(&1, "validation"))

    side_effect_clear? and blocked_before_side_effect?
  end

  defp closed_no_side_effect?(_snapshot, _outcome, _guard), do: false

  defp missing_success_evidence(snapshot, outcome, guard) do
    cond do
      blank?(get_in_value(snapshot, [:request, :request_fingerprint])) ->
        "cutover_operation_request_fingerprint_missing"

      blank?(get_in_value(snapshot, [:readiness_permit, :permit_fingerprint])) ->
        "readiness_permit_fingerprint_missing"

      blank?(get_in_value(snapshot, [:authorization, :authorization_record_fingerprint])) ->
        "authorization_record_fingerprint_missing"

      blank?(get_in_value(snapshot, [:authorization, :authorization_request_fingerprint])) ->
        "authorization_request_fingerprint_missing"

      blank?(get_in_value(snapshot, [:consumption_guard, :decision_fingerprint])) and not is_map(guard) ->
        "consumption_guard_fingerprint_missing"

      blank?(value(outcome, :evidence_fingerprint)) ->
        "outcome_evidence_fingerprint_missing"

      true ->
        nil
    end
  end

  defp missing_open_evidence(snapshot, outcome, guard), do: missing_success_evidence(snapshot, outcome, guard)

  defp validation_reasons(snapshot, input, outcome, guard) do
    []
    |> add_validation(blank?(snapshot.project_id), "project_id_missing", "fix_closure_chain_project_id", "malformed")
    |> add_validation(snapshot.operation not in @operations, "unknown_operation", "choose_supported_operations", "unsupported")
    |> add_validation(snapshot.side_effect_source not in @sources, "unsupported_side_effect_source", "use_supported_side_effect_source", "unsupported")
    |> add_validation(source_operation_mismatch?(snapshot), "side_effect_source_operation_mismatch", "fix_closure_chain_operation_source", "unsupported")
    |> add_validation(snapshot.provider_scope == %{}, "provider_scope_missing", "refresh_closure_chain_provider_scope", "malformed")
    |> add_component_mismatches(snapshot, input, outcome, guard)
    |> add_evidence_drift(snapshot, input, outcome, guard)
  end

  defp add_component_mismatches(reasons, snapshot, input, outcome, guard) do
    explicit_provider_scope = provider_scope_snapshot(value(input, :provider_scope) || %{})
    explicit_operation = operation_name(value(input, :operation))
    explicit_source = source_name(value(input, :side_effect_source) || value(input, :source))

    reasons
    |> add_validation(
      explicit_provider_scope != %{} and not provider_scope_matches?(explicit_provider_scope, snapshot.provider_scope),
      "provider_scope_mismatch",
      "refresh_closure_chain_scope",
      "conflict"
    )
    |> add_validation(
      bound?(value(input, :operation)) and explicit_operation != snapshot.operation,
      "operation_mismatch",
      "refresh_closure_chain_operation",
      "conflict"
    )
    |> add_validation(
      bound?(value(input, :side_effect_source) || value(input, :source)) and
        explicit_source != snapshot.side_effect_source,
      "source_mismatch",
      "refresh_closure_chain_source",
      "conflict"
    )
    |> add_outcome_mismatches(snapshot, outcome)
    |> add_guard_mismatches(snapshot, guard)
  end

  defp add_outcome_mismatches(reasons, _snapshot, nil), do: reasons

  defp add_outcome_mismatches(reasons, snapshot, outcome) do
    reasons
    |> add_validation(
      bound?(value(outcome, :project_id)) and optional_string(outcome, :project_id) != snapshot.project_id,
      "outcome_project_mismatch",
      "refresh_matching_execution_outcome",
      "conflict"
    )
    |> add_validation(
      value(outcome, :provider_scope) != %{} and
        not provider_scope_matches?(value(outcome, :provider_scope), snapshot.provider_scope),
      "outcome_provider_scope_mismatch",
      "refresh_matching_execution_outcome",
      "conflict"
    )
    |> add_validation(
      value(outcome, :operation) != snapshot.operation,
      "outcome_operation_mismatch",
      "refresh_matching_execution_outcome",
      "conflict"
    )
    |> add_validation(
      value(outcome, :side_effect_source) != snapshot.side_effect_source,
      "outcome_source_mismatch",
      "refresh_matching_execution_outcome",
      "conflict"
    )
    |> add_validation(
      bound?(snapshot.attempt_fingerprint) and bound?(value(outcome, :attempt_fingerprint)) and
        snapshot.attempt_fingerprint != value(outcome, :attempt_fingerprint),
      "attempt_fingerprint_mismatch",
      "refresh_matching_execution_outcome",
      "stale"
    )
    |> add_validation(
      bound?(snapshot.replay_key) and bound?(value(outcome, :replay_key)) and
        snapshot.replay_key != value(outcome, :replay_key),
      "replay_key_mismatch",
      "refresh_matching_execution_outcome",
      "stale"
    )
  end

  defp add_guard_mismatches(reasons, _snapshot, nil), do: reasons

  defp add_guard_mismatches(reasons, snapshot, guard) do
    reasons
    |> add_validation(
      bound?(value(guard, :project_id)) and optional_string(guard, :project_id) != snapshot.project_id,
      "guard_project_mismatch",
      "refresh_authorization_consumption_guard",
      "conflict"
    )
    |> add_validation(
      value(guard, :provider_scope) != %{} and
        not provider_scope_matches?(value(guard, :provider_scope), snapshot.provider_scope),
      "guard_provider_scope_mismatch",
      "refresh_authorization_consumption_guard",
      "conflict"
    )
    |> add_validation(
      value(guard, :operation) != snapshot.operation,
      "guard_operation_mismatch",
      "refresh_authorization_consumption_guard",
      "conflict"
    )
    |> add_validation(
      value(guard, :side_effect_source) != snapshot.side_effect_source,
      "guard_source_mismatch",
      "refresh_authorization_consumption_guard",
      "conflict"
    )
  end

  defp add_evidence_drift(reasons, snapshot, input, _outcome, _guard) do
    explicit = SafeSummary.sanitize_map(value(input, :safe_evidence_fingerprints) || %{}, output_keys: :preserve)
    evidence = value(snapshot, :safe_evidence_fingerprints) || %{}

    drift_keys = [
      {:cutover_operation_request, get_in_value(snapshot, [:request, :request_fingerprint])},
      {:readiness_permit, get_in_value(snapshot, [:readiness_permit, :permit_fingerprint])},
      {:authorization_record, get_in_value(snapshot, [:authorization, :authorization_record_fingerprint])},
      {:authorization_request, get_in_value(snapshot, [:authorization, :authorization_request_fingerprint])},
      {:consumption_guard, get_in_value(snapshot, [:consumption_guard, :decision_fingerprint])},
      {:outcome, get_in_value(snapshot, [:outcome, :evidence_fingerprint])}
    ]

    Enum.reduce(drift_keys, reasons, fn {key, expected}, acc ->
      explicit_value = optional_string(explicit, key) || optional_string(evidence, key)

      add_validation(
        acc,
        bound?(explicit_value) and bound?(expected) and explicit_value != expected,
        "#{key}_fingerprint_drift",
        "refresh_closure_chain_evidence",
        "stale"
      )
    end)
  end

  defp add_validation(reasons, true, code, action, level), do: [%{code: code, action: action, level: level} | reasons]
  defp add_validation(reasons, _condition, _code, _action, _level), do: reasons

  defp first_level(reasons, level) do
    reasons
    |> Enum.reverse()
    |> Enum.find(&(&1.level == level))
  end

  defp status_snapshot(status, reason, action, validation, snapshot, outcome, guard) do
    reason_code = safe_status(reason) |> blank_to_default(default_reason(status))
    action_code = safe_status(action) |> blank_to_nil()

    reason_codes =
      validation
      |> Enum.map(& &1.code)
      |> Kernel.++(list_value(snapshot, :reason_codes))
      |> Kernel.++(outcome_reason_codes(outcome))
      |> Kernel.++(guard_reason_codes(guard))
      |> Kernel.++([reason_code])
      |> string_list()
      |> Enum.uniq()
      |> Enum.sort()

    actions =
      validation
      |> Enum.map(& &1.action)
      |> Kernel.++(action_codes(value(snapshot, :required_operator_actions)))
      |> Kernel.++(outcome_actions(outcome))
      |> Kernel.++(guard_actions(guard))
      |> Kernel.++([action_code])
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      closure_status: normalize_status(status),
      reason_code: reason_code,
      action_code: action_code,
      reason_codes: reason_codes,
      required_operator_actions: action_snapshots(actions)
    }
  end

  defp events_from_sources(sources, opts) do
    direct =
      list_value(sources, :closure_chains) ++
        list_value(sources, :chains) ++
        list_value(sources, :events) ++
        List.wrap(Keyword.get(opts, :chains, [])) ++
        List.wrap(Keyword.get(opts, :events, []))

    outcomes =
      list_value(sources, :execution_outcomes) ++
        list_value(sources, :outcomes) ++
        List.wrap(Keyword.get(opts, :outcomes, [])) ++
        outcomes_from_ledger(
          value(sources, :cutover_execution_outcome_ledger) ||
            value(sources, :execution_outcome_ledger)
        )

    direct ++ Enum.map(outcomes, &%{outcome: &1})
  end

  defp outcomes_from_ledger(nil), do: []

  defp outcomes_from_ledger(ledger) when is_map(ledger) do
    snapshot = CutoverExecutionOutcomeLedger.to_snapshot(ledger)

    list_value(snapshot, :recent_outcomes) ++
      list_value(snapshot, :terminal_outcomes) ++
      list_value(snapshot, :unresolved_outcomes) ++
      Enum.flat_map(list_value(snapshot, :projects), fn project ->
        list_value(project, :recent_outcomes) ++
          list_value(project, :terminal_outcomes) ++
          list_value(project, :unresolved_outcomes)
      end)
  end

  defp outcomes_from_ledger(_ledger), do: []

  defp outcome_snapshot(nil), do: nil

  defp outcome_snapshot(value) when is_map(value) do
    CutoverExecutionOutcomeLedger.fact_snapshot(value)
  end

  defp outcome_snapshot(_value), do: nil

  defp guard_snapshot(nil), do: nil

  defp guard_snapshot(value) when is_map(value) do
    CutoverAuthorizationConsumptionGuard.to_decision(value)
  end

  defp guard_snapshot(_value), do: nil

  defp request_binding(input, outcome) do
    request = value(input, :request) || value(input, :cutover_operation_request) || %{}

    %{
      request_id: optional_string(request, :request_id) || optional_string(input, :request_id),
      request_fingerprint:
        optional_string(request, :request_fingerprint) ||
          optional_string(input, :cutover_operation_request_fingerprint) ||
          optional_string(input, :request_fingerprint) ||
          optional_string(outcome || %{}, :cutover_operation_request_fingerprint),
      source: safe_status(value(request, :source) || value(input, :request_source)) |> blank_to_nil(),
      requested_at: iso8601(value(request, :requested_at) || value(input, :requested_at))
    }
    |> compact_map()
  end

  defp readiness_permit_binding(input, outcome) do
    permit = value(input, :readiness_permit) || value(input, :permit) || %{}

    %{
      permit_fingerprint:
        optional_string(permit, :permit_fingerprint) ||
          optional_string(input, :readiness_permit_fingerprint) ||
          optional_string(outcome || %{}, :readiness_permit_fingerprint),
      decision:
        safe_status(
          value(permit, :decision) ||
            value(input, :readiness_permit_decision) ||
            value(outcome || %{}, :readiness_permit_decision)
        )
        |> blank_to_nil(),
      reason_codes: string_list(value(permit, :reason_codes)),
      required_operator_actions: action_snapshots(value(permit, :required_operator_actions))
    }
    |> compact_map()
  end

  defp authorization_binding(input, outcome) do
    authorization = value(input, :authorization) || value(input, :authorization_record) || %{}

    %{
      authorization_record_fingerprint:
        optional_string(authorization, :authorization_record_fingerprint) ||
          optional_string(input, :authorization_record_fingerprint) ||
          optional_string(outcome || %{}, :authorization_record_fingerprint),
      authorization_request_fingerprint:
        optional_string(authorization, :authorization_request_fingerprint) ||
          get_in_value(authorization, [:authorization_request, :authorization_request_fingerprint]) ||
          optional_string(input, :authorization_request_fingerprint) ||
          optional_string(outcome || %{}, :authorization_request_fingerprint),
      status:
        safe_status(value(authorization, :status) || value(input, :authorization_record_status))
        |> blank_to_nil(),
      source: safe_status(value(authorization, :source)) |> blank_to_nil(),
      requested_at: iso8601(value(authorization, :requested_at))
    }
    |> compact_map()
  end

  defp guard_binding(input, guard, outcome) do
    raw = value(input, :consumption_guard) || value(input, :authorization_consumption_guard) || %{}

    fingerprint =
      optional_string(raw, :decision_fingerprint) ||
        optional_string(raw, :consumption_guard_fingerprint) ||
        optional_string(input, :consumption_guard_fingerprint) ||
        get_in_value(outcome || %{}, [:safe_evidence_fingerprints, :consumption_guard]) ||
        if(is_map(guard), do: fingerprint(guard), else: nil)

    if not is_map(guard) and raw == %{} and blank?(fingerprint) do
      %{}
    else
      do_guard_binding(raw, guard, fingerprint)
    end
  end

  defp do_guard_binding(raw, guard, fingerprint) do
    %{
      project_id: optional_string(guard || raw, :project_id),
      provider_scope: provider_scope_snapshot(value(guard || raw, :provider_scope) || %{}),
      operation: operation_name(value(guard || raw, :operation)),
      side_effect_source: source_name(value(guard || raw, :side_effect_source) || value(guard || raw, :source)),
      decision: safe_status(value(guard || raw, :decision)) |> blank_to_nil(),
      allowed: if(is_map(guard), do: value(guard, :allowed) == true, else: nil),
      decision_fingerprint: fingerprint,
      reason_code: safe_status(value(guard || raw, :reason_code)) |> blank_to_nil(),
      action_code: safe_status(value(guard || raw, :action_code)) |> blank_to_nil(),
      no_side_effects: value(guard || raw, :no_side_effects) != false,
      evaluated_at: iso8601(value(guard || raw, :evaluated_at))
    }
    |> compact_map()
  end

  defp outcome_binding(nil), do: %{}

  defp outcome_binding(outcome) do
    %{
      outcome_id: optional_string(outcome, :outcome_id),
      project_id: optional_string(outcome, :project_id),
      provider_scope: provider_scope_snapshot(value(outcome, :provider_scope) || %{}),
      operation: operation_name(value(outcome, :operation)),
      side_effect_source: source_name(value(outcome, :side_effect_source) || value(outcome, :source)),
      attempt_fingerprint: optional_string(outcome, :attempt_fingerprint),
      replay_key: optional_string(outcome, :replay_key),
      status: safe_status(value(outcome, :status)) |> blank_to_nil(),
      reason_code: safe_status(value(outcome, :reason_code)) |> blank_to_nil(),
      action_code: safe_status(value(outcome, :action_code)) |> blank_to_nil(),
      evidence_fingerprint: optional_string(outcome, :evidence_fingerprint),
      cutover_operation_request_fingerprint: optional_string(outcome, :cutover_operation_request_fingerprint),
      readiness_permit_fingerprint: optional_string(outcome, :readiness_permit_fingerprint),
      readiness_permit_decision: safe_status(value(outcome, :readiness_permit_decision)) |> blank_to_nil(),
      authorization_record_fingerprint: optional_string(outcome, :authorization_record_fingerprint),
      authorization_request_fingerprint: optional_string(outcome, :authorization_request_fingerprint),
      cutover_gate_fingerprint: optional_string(outcome, :cutover_gate_fingerprint),
      dry_run_audit_fingerprint: optional_string(outcome, :dry_run_audit_fingerprint),
      audit_history_fingerprint: optional_string(outcome, :audit_history_fingerprint),
      safe_evidence_fingerprints:
        SafeSummary.sanitize_map(value(outcome, :safe_evidence_fingerprints) || %{},
          output_keys: :preserve
        ),
      side_effect_entered: value(outcome, :side_effect_entered),
      side_effect_may_have_happened: value(outcome, :side_effect_may_have_happened),
      no_side_effects: value(outcome, :no_side_effects) == true,
      started_at: iso8601(value(outcome, :started_at)),
      completed_at: iso8601(value(outcome, :completed_at)),
      generated_at: iso8601(value(outcome, :generated_at))
    }
    |> compact_map()
  end

  defp retained_references(input) do
    existing = value(input, :retained_references) || %{}

    %{
      closeout:
        closeout_reference(
          value(input, :closeout) ||
            value(input, :execution_outcome_closeout) ||
            value(existing, :closeout)
        ),
      replay_decision:
        replay_decision_reference(
          value(input, :replay_decision) ||
            value(existing, :replay_decision)
        ),
      replay_request_audit:
        replay_request_reference(
          value(input, :replay_request_audit) ||
            value(input, :replay_request) ||
            value(existing, :replay_request_audit)
        )
    }
    |> Enum.reject(fn {_key, value} -> value == %{} end)
    |> Map.new()
  end

  defp closeout_reference(value) when is_map(value) do
    evidence =
      SafeSummary.sanitize_map(
        value(value, :safe_evidence_fingerprints) || value(value, :evidence_fingerprints) || %{},
        output_keys: :preserve
      )

    side_effect = value(value, :outcome_side_effect) || value(value, :side_effect) || %{}

    %{
      closeout_record_fingerprint: optional_string(value, :closeout_record_fingerprint),
      closeout_id: optional_string(value, :closeout_id) || optional_string(value, :id),
      project_id: optional_string(value, :project_id),
      provider_scope: provider_scope_snapshot(value(value, :provider_scope) || value(value, :provider) || %{}),
      operation: operation_name(value(value, :operation)),
      side_effect_source: source_name(value(value, :side_effect_source) || value(value, :source_boundary)),
      replay_key: optional_string(value, :replay_key),
      attempt_fingerprint: optional_string(value, :attempt_fingerprint),
      outcome_id: optional_string(value, :outcome_id),
      status: safe_status(value(value, :status)) |> blank_to_nil(),
      resolution_code:
        safe_status(value(value, :resolution_code) || value(value, :resolution) || value(value, :decision))
        |> blank_to_nil(),
      outcome_fingerprint:
        optional_string(value, :outcome_fingerprint) ||
          optional_string(value, :evidence_fingerprint),
      outcome_status: safe_status(value(value, :outcome_status) || value(value, :status_bound)) |> blank_to_nil(),
      side_effect_entered:
        first_boolean([
          value(value, :side_effect_entered),
          value(side_effect, :entered),
          value(side_effect, :side_effect_entered)
        ]),
      side_effect_may_have_happened:
        first_boolean([
          value(value, :side_effect_may_have_happened),
          value(side_effect, :may_have_happened),
          value(side_effect, :side_effect_may_have_happened)
        ]),
      cutover_operation_request_fingerprint:
        optional_string(value, :cutover_operation_request_fingerprint) ||
          optional_string(evidence, :cutover_operation_request),
      authorization_record_fingerprint:
        optional_string(value, :authorization_record_fingerprint) ||
          optional_string(evidence, :authorization_record),
      authorization_request_fingerprint:
        optional_string(value, :authorization_request_fingerprint) ||
          optional_string(evidence, :authorization_request),
      readiness_permit_fingerprint:
        optional_string(value, :readiness_permit_fingerprint) ||
          optional_string(evidence, :readiness_permit),
      readiness_permit_decision:
        safe_status(value(value, :readiness_permit_decision) || value(evidence, :readiness_permit_decision))
        |> blank_to_nil(),
      cutover_gate_fingerprint:
        optional_string(value, :cutover_gate_fingerprint) ||
          optional_string(evidence, :cutover_gate),
      dry_run_audit_fingerprint:
        optional_string(value, :dry_run_audit_fingerprint) ||
          optional_string(evidence, :dry_run_audit),
      audit_history_fingerprint:
        optional_string(value, :audit_history_fingerprint) ||
          optional_string(evidence, :audit_history),
      consumption_guard_fingerprint:
        optional_string(value, :consumption_guard_fingerprint) ||
          optional_string(evidence, :consumption_guard),
      safe_evidence_fingerprints: evidence,
      reason_code: safe_status(value(value, :reason_code) || value(value, :reason)) |> blank_to_nil(),
      action_code: safe_status(value(value, :action_code) || value(value, :action)) |> blank_to_nil(),
      status_reasons: string_list(value(value, :status_reasons)),
      operator_request_fingerprint:
        optional_string(value, :operator_request_fingerprint) ||
          optional_string(value, :request_fingerprint),
      source: safe_status(value(value, :source)) |> blank_to_nil(),
      no_side_effects: value(value, :no_side_effects) != false,
      auto_replay_allowed: truthy?(value(value, :auto_replay_allowed))
    }
    |> compact_map()
  end

  defp closeout_reference(_value), do: %{}

  defp replay_decision_reference(value) when is_map(value) do
    evidence =
      SafeSummary.sanitize_map(
        value(value, :safe_evidence_fingerprints) || value(value, :evidence_fingerprints) || %{},
        output_keys: :preserve
      )

    side_effect = value(value, :outcome_side_effect) || value(value, :side_effect) || %{}

    %{
      replay_decision_fingerprint:
        optional_string(value, :replay_decision_fingerprint) ||
          optional_string(value, :decision_fingerprint),
      project_id: optional_string(value, :project_id),
      provider_scope: provider_scope_snapshot(value(value, :provider_scope) || value(value, :provider) || %{}),
      operation: operation_name(value(value, :operation)),
      side_effect_source: source_name(value(value, :side_effect_source) || value(value, :source_boundary)),
      replay_key: optional_string(value, :replay_key) || optional_string(value, :outcome_replay_key),
      decision: safe_status(value(value, :decision)) |> blank_to_nil(),
      allowed: value(value, :allowed) == true,
      reason_code: safe_status(value(value, :reason_code) || value(value, :reason)) |> blank_to_nil(),
      action_code: safe_status(value(value, :action_code) || value(value, :action)) |> blank_to_nil(),
      reason_codes: string_list(value(value, :reason_codes)),
      outcome_fingerprint: optional_string(value, :outcome_fingerprint),
      outcome_status: safe_status(value(value, :outcome_status)) |> blank_to_nil(),
      side_effect_entered:
        first_boolean([
          value(value, :side_effect_entered),
          value(side_effect, :entered),
          value(side_effect, :side_effect_entered)
        ]),
      side_effect_may_have_happened:
        first_boolean([
          value(value, :side_effect_may_have_happened),
          value(side_effect, :may_have_happened),
          value(side_effect, :side_effect_may_have_happened)
        ]),
      closeout_record_fingerprint: optional_string(value, :closeout_record_fingerprint),
      closeout_resolution_code: safe_status(value(value, :closeout_resolution_code)) |> blank_to_nil(),
      closeout_operator_request_fingerprint: optional_string(value, :closeout_operator_request_fingerprint),
      cutover_operation_request_fingerprint:
        optional_string(value, :cutover_operation_request_fingerprint) ||
          optional_string(evidence, :cutover_operation_request),
      authorization_record_fingerprint:
        optional_string(value, :authorization_record_fingerprint) ||
          optional_string(evidence, :authorization_record),
      authorization_request_fingerprint:
        optional_string(value, :authorization_request_fingerprint) ||
          optional_string(evidence, :authorization_request),
      readiness_permit_fingerprint:
        optional_string(value, :readiness_permit_fingerprint) ||
          optional_string(evidence, :readiness_permit),
      readiness_permit_decision:
        safe_status(value(value, :readiness_permit_decision) || value(evidence, :readiness_permit_decision))
        |> blank_to_nil(),
      consumption_guard_fingerprint:
        optional_string(value, :consumption_guard_fingerprint) ||
          optional_string(evidence, :consumption_guard),
      guard_decision: safe_status(value(value, :guard_decision) || value(evidence, :guard_decision)) |> blank_to_nil(),
      safe_evidence_fingerprints: evidence,
      no_side_effects: value(value, :no_side_effects) != false,
      auto_replay_allowed: truthy?(value(value, :auto_replay_allowed))
    }
    |> compact_map()
  end

  defp replay_decision_reference(_value), do: %{}

  defp replay_request_reference(value) when is_map(value) do
    evidence =
      SafeSummary.sanitize_map(
        value(value, :safe_evidence_fingerprints) || value(value, :evidence_fingerprints) || %{},
        output_keys: :preserve
      )

    side_effect = value(value, :outcome_side_effect) || value(value, :side_effect) || %{}

    %{
      request_fingerprint: optional_string(value, :request_fingerprint),
      audit_record_fingerprint: optional_string(value, :audit_record_fingerprint),
      request_id: optional_string(value, :request_id) || optional_string(value, :id),
      project_id: optional_string(value, :project_id),
      provider_scope: provider_scope_snapshot(value(value, :provider_scope) || value(value, :provider) || %{}),
      operation: operation_name(value(value, :operation)),
      side_effect_source: source_name(value(value, :side_effect_source) || value(value, :source_boundary)),
      replay_key: optional_string(value, :replay_key) || optional_string(value, :outcome_replay_key),
      status: safe_status(value(value, :status)) |> blank_to_nil(),
      outcome_link_status: safe_status(value(value, :outcome_link_status)) |> blank_to_nil(),
      outcome_fingerprint:
        optional_string(value, :outcome_fingerprint) ||
          optional_string(value, :evidence_fingerprint),
      outcome_status: safe_status(value(value, :outcome_status)) |> blank_to_nil(),
      side_effect_entered:
        first_boolean([
          value(value, :side_effect_entered),
          value(side_effect, :entered),
          value(side_effect, :side_effect_entered)
        ]),
      side_effect_may_have_happened:
        first_boolean([
          value(value, :side_effect_may_have_happened),
          value(side_effect, :may_have_happened),
          value(side_effect, :side_effect_may_have_happened)
        ]),
      closeout_record_fingerprint: optional_string(value, :closeout_record_fingerprint),
      closeout_resolution_code: safe_status(value(value, :closeout_resolution_code)) |> blank_to_nil(),
      closeout_operator_request_fingerprint: optional_string(value, :closeout_operator_request_fingerprint),
      replay_decision_fingerprint: optional_string(value, :replay_decision_fingerprint),
      replay_decision_status:
        safe_status(value(value, :replay_decision_status) || value(value, :decision_status))
        |> blank_to_nil(),
      cutover_operation_request_fingerprint:
        optional_string(value, :cutover_operation_request_fingerprint) ||
          optional_string(evidence, :cutover_operation_request),
      authorization_record_fingerprint:
        optional_string(value, :authorization_record_fingerprint) ||
          optional_string(evidence, :authorization_record),
      authorization_request_fingerprint:
        optional_string(value, :authorization_request_fingerprint) ||
          optional_string(evidence, :authorization_request),
      readiness_permit_fingerprint:
        optional_string(value, :readiness_permit_fingerprint) ||
          optional_string(evidence, :readiness_permit),
      readiness_permit_decision:
        safe_status(value(value, :readiness_permit_decision) || value(evidence, :readiness_permit_decision))
        |> blank_to_nil(),
      consumption_guard_fingerprint:
        optional_string(value, :consumption_guard_fingerprint) ||
          optional_string(evidence, :consumption_guard),
      guard_decision: safe_status(value(value, :guard_decision) || value(evidence, :guard_decision)) |> blank_to_nil(),
      safe_evidence_fingerprints: evidence,
      reason_code: safe_status(value(value, :reason_code) || value(value, :reason)) |> blank_to_nil(),
      action_code: safe_status(value(value, :action_code) || value(value, :action)) |> blank_to_nil(),
      status_reasons: string_list(value(value, :status_reasons)),
      source: safe_status(value(value, :source)) |> blank_to_nil(),
      no_side_effects: value(value, :no_side_effects) != false,
      auto_replay_allowed: truthy?(value(value, :auto_replay_allowed))
    }
    |> compact_map()
  end

  defp replay_request_reference(_value), do: %{}

  defp evidence_fingerprints(input, outcome, request, permit, authorization, guard) do
    outcome_evidence =
      if is_map(outcome) do
        SafeSummary.sanitize_map(value(outcome, :safe_evidence_fingerprints) || %{}, output_keys: :preserve)
      else
        %{}
      end

    base =
      %{
        cutover_operation_request: optional_string(request, :request_fingerprint),
        readiness_permit: optional_string(permit, :permit_fingerprint),
        readiness_permit_decision: safe_status(value(permit, :decision)) |> blank_to_nil(),
        authorization_record: optional_string(authorization, :authorization_record_fingerprint),
        authorization_request: optional_string(authorization, :authorization_request_fingerprint),
        consumption_guard: optional_string(guard, :decision_fingerprint),
        outcome: if(is_map(outcome), do: optional_string(outcome, :evidence_fingerprint), else: nil),
        outcome_evidence: if(is_map(outcome), do: optional_string(outcome, :evidence_fingerprint), else: nil),
        cutover_gate:
          optional_string(input, :cutover_gate_fingerprint) ||
            optional_string(outcome_evidence, :cutover_gate),
        dry_run_audit:
          optional_string(input, :dry_run_audit_fingerprint) ||
            optional_string(outcome_evidence, :dry_run_audit),
        audit_history:
          optional_string(input, :audit_history_fingerprint) ||
            optional_string(outcome_evidence, :audit_history),
        replay_request:
          optional_string(input, :replay_request_fingerprint) ||
            optional_string(outcome_evidence, :replay_request),
        replay_request_audit:
          optional_string(input, :replay_request_audit_fingerprint) ||
            optional_string(outcome_evidence, :replay_request_audit)
      }

    base
    |> Map.merge(outcome_evidence)
    |> Map.merge(SafeSummary.sanitize_map(value(input, :safe_evidence_fingerprints) || %{}, output_keys: :preserve))
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
    |> SafeSummary.sanitize_map(output_keys: :preserve)
  end

  defp time_summary(input, outcome, request, permit, authorization, guard, now) do
    %{
      requested_at:
        iso8601(value(request, :requested_at)) ||
          iso8601(value(input, :requested_at)),
      permit_evaluated_at: iso8601(value(permit, :evaluated_at)),
      authorized_at: iso8601(value(authorization, :requested_at)),
      guard_evaluated_at: iso8601(value(guard, :evaluated_at)),
      outcome_started_at: if(is_map(outcome), do: iso8601(value(outcome, :started_at)), else: nil),
      outcome_completed_at: if(is_map(outcome), do: iso8601(value(outcome, :completed_at)), else: nil),
      outcome_generated_at: if(is_map(outcome), do: iso8601(value(outcome, :generated_at)), else: nil),
      generated_at: iso8601(value(input, :generated_at)) || now,
      evaluated_at: iso8601(value(input, :evaluated_at)) || now
    }
    |> compact_map()
  end

  defp execution_key_snapshot(attempt_fingerprint, replay_key) do
    %{
      key_type:
        cond do
          bound?(attempt_fingerprint) -> "attempt_fingerprint"
          bound?(replay_key) -> "replay_key"
          true -> nil
        end,
      attempt_fingerprint: attempt_fingerprint,
      replay_key: replay_key
    }
    |> compact_map()
  end

  defp source_operation_mismatch?(snapshot) do
    snapshot.side_effect_source in @sources and
      snapshot.operation in @operations and
      Map.fetch!(@source_operations, snapshot.side_effect_source) != snapshot.operation
  end

  defp outcome_reason(outcome, default), do: safe_status(value(outcome || %{}, :reason_code)) |> blank_to_default(default)
  defp outcome_action(outcome), do: safe_status(value(outcome || %{}, :action_code)) |> blank_to_nil()

  defp open_outcome_reason("open_retryable", _outcome), do: "retryable_outcome_waiting_for_explicit_consideration"

  defp open_outcome_reason("open_manual_attention", outcome) do
    case safe_status(value(outcome || %{}, :status)) do
      "unknown" -> "unknown_outcome_requires_manual_attention"
      _status -> "manual_attention_outcome_requires_closeout"
    end
  end

  defp open_outcome_action("open_retryable", _outcome), do: "re_evaluate_explicit_retry_consideration"
  defp open_outcome_action("open_manual_attention", _outcome), do: "perform_operator_closeout"

  defp no_side_effect_reason(_snapshot, outcome, guard) do
    safe_status(value(guard || %{}, :reason_code))
    |> blank_to_default(outcome_reason(outcome, "side_effect_not_entered"))
  end

  defp no_side_effect_action(_snapshot, outcome, guard) do
    safe_status(value(guard || %{}, :action_code))
    |> blank_to_default(outcome_action(outcome))
  end

  defp outcome_reason_codes(nil), do: []
  defp outcome_reason_codes(outcome), do: string_list(value(outcome, :reason_codes) || value(outcome, :reason_code))

  defp outcome_actions(nil), do: []
  defp outcome_actions(outcome), do: action_codes(value(outcome, :required_operator_actions) || value(outcome, :action_code))

  defp guard_reason_codes(nil), do: []
  defp guard_reason_codes(guard), do: string_list(value(guard, :reason_codes) || value(guard, :reason_code))

  defp guard_actions(nil), do: []
  defp guard_actions(guard), do: action_codes(value(guard, :required_operator_actions) || value(guard, :action_code))

  defp project_summary(project_id, chains) do
    project_chains =
      chains
      |> Enum.filter(&(optional_string(&1, :project_id) == project_id))
      |> Enum.take(@default_recent_limit)

    %{
      version: @version,
      project_id: project_id,
      status: project_status(project_chains),
      counts: count_snapshot(%{}, project_chains, [project_id]),
      closure_chains: project_chains,
      recent_reference_reason_codes: recent_reference_codes(project_chains, :reason_code),
      recent_reference_action_codes: recent_reference_codes(project_chains, :action_code),
      safe_evidence_fingerprints: project_fingerprints(project_chains),
      read_only: true,
      no_side_effects: true,
      auto_replay_allowed: false
    }
    |> project_snapshot()
  end

  defp project_snapshot(project) when is_map(project) do
    chains =
      project
      |> list_value(:closure_chains)
      |> Enum.map(&chain_snapshot/1)
      |> Enum.sort_by(&chain_sort_key/1)
      |> Enum.take(@default_recent_limit)

    project_id = optional_string(project, :project_id) || chains |> List.first() |> optional_string(:project_id)

    %{
      version: positive_integer(value(project, :version)) || @version,
      project_id: project_id,
      status: normalize_project_status(value(project, :status), chains),
      counts: count_snapshot(value(project, :counts), chains, [project_id]),
      closure_chains: chains,
      recent_reference_reason_codes: recent_reference_codes(chains, :reason_code),
      recent_reference_action_codes: recent_reference_codes(chains, :action_code),
      safe_evidence_fingerprints: project_fingerprints(chains),
      read_only: value(project, :read_only) != false,
      no_side_effects: value(project, :no_side_effects) != false,
      auto_replay_allowed: false
    }
  end

  defp project_snapshot(project), do: project_snapshot(%{project_id: project})

  defp count_snapshot(counts, chains, project_ids) when is_map(counts) do
    closeout_reference_status_counts =
      reference_type_status_counts(value(counts, :closeout_reference_status_counts), chains, :closeout)

    replay_decision_reference_status_counts =
      reference_type_status_counts(
        value(counts, :replay_decision_reference_status_counts),
        chains,
        :replay_decision
      )

    replay_request_audit_reference_status_counts =
      reference_type_status_counts(
        value(counts, :replay_request_audit_reference_status_counts),
        chains,
        :replay_request_audit
      )

    %{
      chain_count: non_negative_integer(value(counts, :chain_count)) || length(chains),
      no_chain_count:
        non_negative_integer(value(counts, :no_chain_count)) ||
          if(chains == [] and project_ids == [], do: 1, else: 0),
      no_request_count:
        non_negative_integer(value(counts, :no_request_count)) ||
          if(chains == [] and project_ids != [], do: length(project_ids), else: Enum.count(chains, &(&1.closure_status == "no_request"))),
      closed_succeeded_count: count_or_existing(counts, :closed_succeeded_count, chains, "closed_succeeded"),
      closed_no_side_effect_count: count_or_existing(counts, :closed_no_side_effect_count, chains, "closed_no_side_effect"),
      open_retryable_count: count_or_existing(counts, :open_retryable_count, chains, "open_retryable"),
      open_manual_attention_count: count_or_existing(counts, :open_manual_attention_count, chains, "open_manual_attention"),
      conflict_count: count_or_existing(counts, :conflict_count, chains, "conflict"),
      stale_count: count_or_existing(counts, :stale_count, chains, "stale"),
      malformed_count: count_or_existing(counts, :malformed_count, chains, "malformed"),
      unsupported_count: count_or_existing(counts, :unsupported_count, chains, "unsupported"),
      reference_status_counts: reference_status_counts(value(counts, :reference_status_counts), chains),
      closeout_reference_status_counts: closeout_reference_status_counts,
      replay_decision_reference_status_counts: replay_decision_reference_status_counts,
      replay_request_audit_reference_status_counts: replay_request_audit_reference_status_counts,
      operation_status_counts: operation_status_counts(value(counts, :operation_status_counts), chains),
      source_status_counts: source_status_counts(value(counts, :source_status_counts), chains)
    }
  end

  defp count_snapshot(_counts, chains, project_ids), do: count_snapshot(%{}, chains, project_ids)

  defp count_or_existing(counts, key, chains, status) do
    non_negative_integer(value(counts, key)) || Enum.count(chains, &(&1.closure_status == status))
  end

  defp operation_status_counts(existing, _chains) when is_map(existing) and map_size(existing) > 0 do
    SafeSummary.sanitize_map(existing, output_keys: :preserve)
  end

  defp operation_status_counts(_existing, chains) do
    base = Map.new(@operations, &{String.to_atom(&1), status_zero_counts()})

    Enum.reduce(chains, base, fn chain, acc ->
      operation = operation_name(value(chain, :operation)) |> String.to_atom()
      status = normalize_status(value(chain, :closure_status)) |> String.to_atom()

      Map.update(acc, operation, Map.update(status_zero_counts(), status, 1, &(&1 + 1)), fn counts ->
        Map.update(counts, status, 1, &(&1 + 1))
      end)
    end)
  end

  defp source_status_counts(existing, _chains) when is_map(existing) and map_size(existing) > 0 do
    SafeSummary.sanitize_map(existing, output_keys: :preserve)
  end

  defp source_status_counts(_existing, chains) do
    base = Map.new(@sources, &{String.to_atom(&1), status_zero_counts()})

    Enum.reduce(chains, base, fn chain, acc ->
      source = source_name(value(chain, :side_effect_source) || value(chain, :source)) |> String.to_atom()
      status = normalize_status(value(chain, :closure_status)) |> String.to_atom()

      Map.update(acc, source, Map.update(status_zero_counts(), status, 1, &(&1 + 1)), fn counts ->
        Map.update(counts, status, 1, &(&1 + 1))
      end)
    end)
  end

  defp retained_reference_statuses(chain) do
    @reference_types
    |> Enum.map(fn type -> {String.to_atom(type), reference_status_for(chain, String.to_atom(type))} end)
    |> Enum.reject(fn {_type, status} -> status == %{} end)
    |> Map.new()
  end

  defp reference_status_for(chain, :closeout), do: closeout_reference_status(chain)
  defp reference_status_for(chain, :replay_decision), do: replay_decision_reference_status(chain)
  defp reference_status_for(chain, :replay_request_audit), do: replay_request_audit_reference_status(chain)

  defp closeout_reference_status(chain) do
    reference = get_in_value(chain, [:retained_references, :closeout]) || %{}

    cond do
      reference == %{} and closeout_reference_required?(chain) ->
        reference_status_snapshot(
          :closeout,
          "missing",
          "closeout_reference_missing",
          "record_execution_outcome_closeout",
          chain,
          reference
        )

      reference == %{} ->
        %{}

      true ->
        classify_closeout_reference(chain, reference)
    end
  end

  defp replay_decision_reference_status(chain) do
    reference = get_in_value(chain, [:retained_references, :replay_decision]) || %{}

    cond do
      reference == %{} and replay_reference_required?(chain) ->
        reference_status_snapshot(
          :replay_decision,
          "missing",
          "replay_decision_reference_missing",
          "evaluate_cutover_replay_decision",
          chain,
          reference
        )

      reference == %{} ->
        %{}

      true ->
        classify_replay_decision_reference(chain, reference)
    end
  end

  defp replay_request_audit_reference_status(chain) do
    reference = get_in_value(chain, [:retained_references, :replay_request_audit]) || %{}

    cond do
      reference == %{} and replay_reference_required?(chain) ->
        reference_status_snapshot(
          :replay_request_audit,
          "missing",
          "replay_request_audit_reference_missing",
          "record_cutover_replay_request_audit",
          chain,
          reference
        )

      reference == %{} ->
        %{}

      true ->
        classify_replay_request_audit_reference(chain, reference)
    end
  end

  defp closeout_reference_required?(chain) do
    value(chain, :closure_status) == "open_manual_attention" or
      get_in_value(chain, [:outcome, :status]) in @open_manual_attention_outcome_statuses
  end

  defp replay_reference_required?(chain) do
    value(chain, :closure_status) == "open_retryable" or
      get_in_value(chain, [:outcome, :status]) in @open_retryable_outcome_statuses or
      retry_closeout_reference?(get_in_value(chain, [:retained_reference_statuses, :closeout])) or
      retry_closeout_reference?(get_in_value(chain, [:retained_references, :closeout]))
  end

  defp retry_closeout_reference?(reference) when is_map(reference) do
    safe_status(value(reference, :resolution_code)) in @retry_closeout_resolution_codes or
      safe_status(value(reference, :closeout_resolution_code)) in @retry_closeout_resolution_codes
  end

  defp retry_closeout_reference?(_reference), do: false

  defp classify_closeout_reference(chain, reference) do
    status = safe_status(value(reference, :status))
    resolution_code = safe_status(value(reference, :resolution_code))

    cond do
      blank?(status) ->
        malformed_reference(:closeout, "closeout_reference_status_missing", chain, reference)

      status == "malformed" ->
        malformed_reference(:closeout, reference_reason(reference, "closeout_reference_malformed"), chain, reference)

      status == "unsupported" ->
        unsupported_reference(:closeout, reference_reason(reference, "closeout_reference_unsupported"), chain, reference)

      status == "stale" ->
        stale_reference(:closeout, reference_reason(reference, "closeout_reference_stale"), chain, reference)

      status == "conflict" ->
        conflict_reference(:closeout, reference_reason(reference, "closeout_reference_conflict"), chain, reference)

      status not in @closeout_record_statuses ->
        unsupported_reference(:closeout, "closeout_reference_status_unsupported", chain, reference)

      bound?(resolution_code) and resolution_code not in @closeout_resolution_codes ->
        unsupported_reference(:closeout, "closeout_reference_resolution_unsupported", chain, reference)

      validation = common_reference_validation(:closeout, reference) ->
        reference_validation_status(validation, :closeout, chain, reference)

      blank?(optional_string(reference, :closeout_record_fingerprint)) ->
        malformed_reference(:closeout, "closeout_record_fingerprint_missing", chain, reference)

      status in ["resolved", "manual_attention"] and blank?(resolution_code) ->
        malformed_reference(:closeout, "closeout_resolution_code_missing", chain, reference)

      blank?(optional_string(reference, :replay_key)) and blank?(optional_string(reference, :attempt_fingerprint)) ->
        malformed_reference(:closeout, "closeout_execution_key_missing", chain, reference)

      reason = side_effect_safety_missing_reason(:closeout, chain, reference) ->
        malformed_reference(:closeout, reason, chain, reference)

      reason = required_reference_evidence_missing_reason(:closeout, chain, reference, closeout_evidence_keys()) ->
        malformed_reference(:closeout, reason, chain, reference)

      reason = common_reference_conflict_reason(:closeout, chain, reference) ->
        conflict_reference(:closeout, reason, chain, reference)

      reason = side_effect_safety_mismatch_reason(:closeout, chain, reference) ->
        conflict_reference(:closeout, reason, chain, reference)

      reason = execution_key_mismatch_reason(:closeout, chain, reference) ->
        stale_reference(:closeout, reason, chain, reference)

      reason = outcome_binding_mismatch_reason(:closeout, chain, reference) ->
        stale_reference(:closeout, reason, chain, reference)

      reason = reference_evidence_mismatch_reason(:closeout, chain, reference, closeout_evidence_keys()) ->
        stale_reference(:closeout, reason, chain, reference)

      true ->
        current_reference(
          :closeout,
          reference_reason(reference, "closeout_reference_current"),
          reference_action(reference),
          chain,
          reference,
          %{closeout_status: status, resolution_code: resolution_code}
        )
    end
  end

  defp classify_replay_decision_reference(chain, reference) do
    decision = safe_status(value(reference, :decision))

    cond do
      blank?(decision) ->
        malformed_reference(:replay_decision, "replay_decision_reference_decision_missing", chain, reference)

      decision == "malformed" ->
        malformed_reference(:replay_decision, reference_reason(reference, "replay_decision_reference_malformed"), chain, reference)

      decision == "unsupported" ->
        unsupported_reference(:replay_decision, reference_reason(reference, "replay_decision_reference_unsupported"), chain, reference)

      decision == "stale_closeout" ->
        stale_reference(:replay_decision, reference_reason(reference, "replay_decision_reference_stale"), chain, reference)

      decision == "conflict" ->
        conflict_reference(:replay_decision, reference_reason(reference, "replay_decision_reference_conflict"), chain, reference)

      decision not in @replay_decisions ->
        unsupported_reference(:replay_decision, "replay_decision_reference_decision_unsupported", chain, reference)

      validation = common_reference_validation(:replay_decision, reference) ->
        reference_validation_status(validation, :replay_decision, chain, reference)

      blank?(optional_string(reference, :replay_decision_fingerprint)) ->
        malformed_reference(:replay_decision, "replay_decision_fingerprint_missing", chain, reference)

      blank?(optional_string(reference, :replay_key)) ->
        malformed_reference(:replay_decision, "replay_decision_replay_key_missing", chain, reference)

      reason = side_effect_safety_missing_reason(:replay_decision, chain, reference) ->
        malformed_reference(:replay_decision, reason, chain, reference)

      reason =
          required_reference_evidence_missing_reason(
            :replay_decision,
            chain,
            reference,
            replay_decision_evidence_keys()
          ) ->
        malformed_reference(:replay_decision, reason, chain, reference)

      reason = common_reference_conflict_reason(:replay_decision, chain, reference) ->
        conflict_reference(:replay_decision, reason, chain, reference)

      reason = side_effect_safety_mismatch_reason(:replay_decision, chain, reference) ->
        conflict_reference(:replay_decision, reason, chain, reference)

      reason = execution_key_mismatch_reason(:replay_decision, chain, reference) ->
        stale_reference(:replay_decision, reason, chain, reference)

      reason = outcome_binding_mismatch_reason(:replay_decision, chain, reference) ->
        stale_reference(:replay_decision, reason, chain, reference)

      reason = closeout_binding_missing_reason(:replay_decision, chain, reference) ->
        malformed_reference(:replay_decision, reason, chain, reference)

      reason = closeout_binding_mismatch_reason(:replay_decision, chain, reference) ->
        stale_reference(:replay_decision, reason, chain, reference)

      reason =
          reference_evidence_mismatch_reason(
            :replay_decision,
            chain,
            reference,
            replay_decision_evidence_keys()
          ) ->
        stale_reference(:replay_decision, reason, chain, reference)

      true ->
        current_reference(
          :replay_decision,
          reference_reason(reference, "replay_decision_reference_current"),
          reference_action(reference),
          chain,
          reference,
          %{decision: decision}
        )
    end
  end

  defp classify_replay_request_audit_reference(chain, reference) do
    status = safe_status(value(reference, :status))
    outcome_link_status = safe_status(value(reference, :outcome_link_status))

    cond do
      blank?(status) ->
        malformed_reference(:replay_request_audit, "replay_request_audit_reference_status_missing", chain, reference)

      status == "no_request" ->
        reference_status_snapshot(
          :replay_request_audit,
          "missing",
          reference_reason(reference, "replay_request_audit_reference_missing"),
          reference_action(reference) || "record_cutover_replay_request_audit",
          chain,
          reference,
          %{request_status: status}
        )

      status == "malformed" ->
        malformed_reference(:replay_request_audit, reference_reason(reference, "replay_request_audit_reference_malformed"), chain, reference)

      status == "unsupported" ->
        unsupported_reference(:replay_request_audit, reference_reason(reference, "replay_request_audit_reference_unsupported"), chain, reference)

      status == "stale" ->
        stale_reference(:replay_request_audit, reference_reason(reference, "replay_request_audit_reference_stale"), chain, reference)

      status == "conflict" ->
        conflict_reference(:replay_request_audit, reference_reason(reference, "replay_request_audit_reference_conflict"), chain, reference)

      status not in @replay_request_statuses ->
        unsupported_reference(:replay_request_audit, "replay_request_audit_reference_status_unsupported", chain, reference)

      bound?(outcome_link_status) and outcome_link_status not in @replay_outcome_link_statuses ->
        unsupported_reference(:replay_request_audit, "replay_request_audit_outcome_link_status_unsupported", chain, reference)

      validation = common_reference_validation(:replay_request_audit, reference) ->
        reference_validation_status(validation, :replay_request_audit, chain, reference)

      blank?(optional_string(reference, :request_fingerprint)) ->
        malformed_reference(:replay_request_audit, "replay_request_fingerprint_missing", chain, reference)

      blank?(optional_string(reference, :audit_record_fingerprint)) ->
        malformed_reference(:replay_request_audit, "replay_request_audit_record_fingerprint_missing", chain, reference)

      blank?(optional_string(reference, :replay_key)) ->
        malformed_reference(:replay_request_audit, "replay_request_replay_key_missing", chain, reference)

      reason = side_effect_safety_missing_reason(:replay_request_audit, chain, reference) ->
        malformed_reference(:replay_request_audit, reason, chain, reference)

      reason =
          required_reference_evidence_missing_reason(
            :replay_request_audit,
            chain,
            reference,
            replay_request_evidence_keys()
          ) ->
        malformed_reference(:replay_request_audit, reason, chain, reference)

      reason = common_reference_conflict_reason(:replay_request_audit, chain, reference) ->
        conflict_reference(:replay_request_audit, reason, chain, reference)

      reason = side_effect_safety_mismatch_reason(:replay_request_audit, chain, reference) ->
        conflict_reference(:replay_request_audit, reason, chain, reference)

      reason = execution_key_mismatch_reason(:replay_request_audit, chain, reference) ->
        stale_reference(:replay_request_audit, reason, chain, reference)

      reason = outcome_binding_mismatch_reason(:replay_request_audit, chain, reference) ->
        stale_reference(:replay_request_audit, reason, chain, reference)

      reason = closeout_binding_missing_reason(:replay_request_audit, chain, reference) ->
        malformed_reference(:replay_request_audit, reason, chain, reference)

      reason = closeout_binding_mismatch_reason(:replay_request_audit, chain, reference) ->
        stale_reference(:replay_request_audit, reason, chain, reference)

      reason = replay_decision_binding_missing_reason(:replay_request_audit, chain, reference) ->
        malformed_reference(:replay_request_audit, reason, chain, reference)

      reason = replay_decision_binding_mismatch_reason(:replay_request_audit, chain, reference) ->
        stale_reference(:replay_request_audit, reason, chain, reference)

      reason =
          reference_evidence_mismatch_reason(
            :replay_request_audit,
            chain,
            reference,
            replay_request_evidence_keys()
          ) ->
        stale_reference(:replay_request_audit, reason, chain, reference)

      true ->
        current_reference(
          :replay_request_audit,
          reference_reason(reference, "replay_request_audit_reference_current"),
          reference_action(reference),
          chain,
          reference,
          %{request_status: status, outcome_link_status: blank_to_nil(outcome_link_status)}
        )
    end
  end

  defp current_reference(type, reason, action, chain, reference, extra) do
    reference_status_snapshot(type, "current", reason, action, chain, reference, extra)
  end

  defp stale_reference(type, reason, chain, reference) do
    reference_status_snapshot(type, "stale", reason, stale_reference_action(type), chain, reference)
  end

  defp conflict_reference(type, reason, chain, reference) do
    reference_status_snapshot(type, "conflict", reason, conflict_reference_action(type), chain, reference)
  end

  defp malformed_reference(type, reason, chain, reference) do
    reference_status_snapshot(type, "malformed", reason, malformed_reference_action(type), chain, reference)
  end

  defp unsupported_reference(type, reason, chain, reference) do
    reference_status_snapshot(type, "unsupported", reason, unsupported_reference_action(type), chain, reference)
  end

  defp reference_status_snapshot(type, status, reason, action, chain, reference, extra \\ %{}) do
    type_name = reference_type_name(type)
    status = normalize_reference_status(status)
    reference = if is_map(reference), do: reference, else: %{}

    %{
      reference_type: type_name,
      status: status,
      reason_code: safe_status(reason) |> blank_to_default("#{type_name}_reference_#{status}"),
      action_code: safe_status(action) |> blank_to_nil(),
      closure_status: safe_status(value(chain, :closure_status)) |> blank_to_nil(),
      replay_key: optional_string(reference, :replay_key) || optional_string(chain, :replay_key),
      attempt_fingerprint: optional_string(reference, :attempt_fingerprint),
      closeout_record_fingerprint: optional_string(reference, :closeout_record_fingerprint),
      replay_decision_fingerprint: optional_string(reference, :replay_decision_fingerprint),
      request_fingerprint: optional_string(reference, :request_fingerprint),
      audit_record_fingerprint: optional_string(reference, :audit_record_fingerprint),
      outcome_fingerprint: optional_string(reference, :outcome_fingerprint),
      outcome_status: safe_status(value(reference, :outcome_status)) |> blank_to_nil(),
      safe_evidence_fingerprint: reference_status_fingerprint(type_name, status, chain, reference, reason)
    }
    |> Map.merge(extra)
    |> compact_map()
  end

  defp reference_status_fingerprint(type_name, status, chain, reference, reason) do
    %{
      reference_type: type_name,
      status: status,
      reason_code: safe_status(reason),
      project_id: optional_string(chain, :project_id),
      operation: operation_name(value(chain, :operation)),
      side_effect_source: source_name(value(chain, :side_effect_source)),
      replay_key: optional_string(reference, :replay_key) || optional_string(chain, :replay_key),
      closeout_record_fingerprint: optional_string(reference, :closeout_record_fingerprint),
      replay_decision_fingerprint: optional_string(reference, :replay_decision_fingerprint),
      request_fingerprint: optional_string(reference, :request_fingerprint),
      audit_record_fingerprint: optional_string(reference, :audit_record_fingerprint),
      outcome_fingerprint: optional_string(reference, :outcome_fingerprint),
      safe_evidence_fingerprints:
        reference
        |> value(:safe_evidence_fingerprints)
        |> SafeSummary.sanitize_map(output_keys: :preserve)
    }
    |> fingerprint()
  end

  defp reference_reason(reference, default) do
    safe_status(value(reference, :reason_code) || value(reference, :reason))
    |> blank_to_default(default)
  end

  defp reference_action(reference) do
    safe_status(value(reference, :action_code) || value(reference, :action))
    |> blank_to_nil()
  end

  defp stale_reference_action(:closeout), do: "refresh_execution_outcome_closeout"
  defp stale_reference_action(:replay_decision), do: "refresh_cutover_replay_decision"
  defp stale_reference_action(:replay_request_audit), do: "refresh_cutover_replay_request_audit"

  defp conflict_reference_action(:closeout), do: "resolve_closeout_reference_conflict"
  defp conflict_reference_action(:replay_decision), do: "resolve_replay_decision_reference_conflict"
  defp conflict_reference_action(:replay_request_audit), do: "resolve_replay_request_audit_reference_conflict"

  defp malformed_reference_action(:closeout), do: "fix_execution_outcome_closeout_reference"
  defp malformed_reference_action(:replay_decision), do: "fix_cutover_replay_decision_reference"
  defp malformed_reference_action(:replay_request_audit), do: "fix_cutover_replay_request_audit_reference"

  defp unsupported_reference_action(:closeout), do: "use_supported_execution_outcome_closeout_reference"
  defp unsupported_reference_action(:replay_decision), do: "use_supported_cutover_replay_decision_reference"
  defp unsupported_reference_action(:replay_request_audit), do: "use_supported_cutover_replay_request_audit_reference"

  defp common_reference_validation(type, reference) do
    operation = operation_name(value(reference, :operation))
    source = source_name(value(reference, :side_effect_source))
    source_operation_mismatch? = operation in @operations and source in @sources and Map.fetch!(@source_operations, source) != operation

    cond do
      blank?(optional_string(reference, :project_id)) ->
        {:malformed, "#{reference_type_name(type)}_project_id_missing"}

      provider_scope_snapshot(value(reference, :provider_scope) || %{}) == %{} ->
        {:malformed, "#{reference_type_name(type)}_provider_scope_missing"}

      operation == "unknown_operation" ->
        {:malformed, "#{reference_type_name(type)}_operation_missing"}

      operation not in @operations ->
        {:unsupported, "#{reference_type_name(type)}_operation_unsupported"}

      source == "unknown_source" ->
        {:malformed, "#{reference_type_name(type)}_source_missing"}

      source not in @sources ->
        {:unsupported, "#{reference_type_name(type)}_source_unsupported"}

      source_operation_mismatch? ->
        {:unsupported, "#{reference_type_name(type)}_source_operation_mismatch"}

      source = value(reference, :source) ->
        if safe_status(source) in @operator_sources do
          nil
        else
          {:unsupported, "#{reference_type_name(type)}_operator_source_unsupported"}
        end

      true ->
        nil
    end
  end

  defp reference_validation_status({:malformed, reason}, type, chain, reference), do: malformed_reference(type, reason, chain, reference)

  defp reference_validation_status({:unsupported, reason}, type, chain, reference) do
    unsupported_reference(type, reason, chain, reference)
  end

  defp common_reference_conflict_reason(type, chain, reference) do
    type_name = reference_type_name(type)

    cond do
      bound?(optional_string(reference, :project_id)) and
          optional_string(reference, :project_id) != optional_string(chain, :project_id) ->
        "#{type_name}_project_mismatch"

      value(reference, :provider_scope) != %{} and
          not provider_scope_matches?(value(reference, :provider_scope), value(chain, :provider_scope)) ->
        "#{type_name}_provider_scope_mismatch"

      operation_name(value(reference, :operation)) != operation_name(value(chain, :operation)) ->
        "#{type_name}_operation_mismatch"

      source_name(value(reference, :side_effect_source)) != source_name(value(chain, :side_effect_source)) ->
        "#{type_name}_source_mismatch"

      true ->
        nil
    end
  end

  defp execution_key_mismatch_reason(type, chain, reference) do
    type_name = reference_type_name(type)
    reference_replay_key = optional_string(reference, :replay_key)
    chain_replay_key = optional_string(chain, :replay_key)
    reference_attempt = optional_string(reference, :attempt_fingerprint)
    chain_attempt = optional_string(chain, :attempt_fingerprint)

    cond do
      bound?(reference_replay_key) and bound?(chain_replay_key) and reference_replay_key != chain_replay_key ->
        "#{type_name}_replay_key_mismatch"

      bound?(reference_attempt) and bound?(chain_attempt) and reference_attempt != chain_attempt ->
        "#{type_name}_attempt_fingerprint_mismatch"

      true ->
        nil
    end
  end

  defp outcome_binding_mismatch_reason(type, chain, reference) do
    type_name = reference_type_name(type)
    reference_outcome = optional_string(reference, :outcome_fingerprint)
    chain_outcome = get_in_value(chain, [:outcome, :evidence_fingerprint])
    reference_status = safe_status(value(reference, :outcome_status))
    chain_status = safe_status(get_in_value(chain, [:outcome, :status]))

    cond do
      bound?(reference_outcome) and bound?(chain_outcome) and reference_outcome != chain_outcome ->
        "#{type_name}_outcome_fingerprint_mismatch"

      bound?(reference_status) and bound?(chain_status) and reference_status != chain_status ->
        "#{type_name}_outcome_status_mismatch"

      true ->
        nil
    end
  end

  defp closeout_binding_mismatch_reason(type, chain, reference) do
    closeout = get_in_value(chain, [:retained_references, :closeout]) || %{}
    type_name = reference_type_name(type)
    expected_fingerprint = optional_string(closeout, :closeout_record_fingerprint)
    expected_resolution = safe_status(value(closeout, :resolution_code))
    actual_fingerprint = optional_string(reference, :closeout_record_fingerprint)
    actual_resolution = safe_status(value(reference, :closeout_resolution_code))

    cond do
      closeout == %{} ->
        nil

      bound?(actual_fingerprint) and bound?(expected_fingerprint) and actual_fingerprint != expected_fingerprint ->
        "#{type_name}_closeout_record_fingerprint_mismatch"

      bound?(actual_resolution) and bound?(expected_resolution) and actual_resolution != expected_resolution ->
        "#{type_name}_closeout_resolution_mismatch"

      true ->
        nil
    end
  end

  defp closeout_binding_missing_reason(type, chain, reference) do
    closeout = get_in_value(chain, [:retained_references, :closeout]) || %{}
    type_name = reference_type_name(type)
    expected_fingerprint = optional_string(closeout, :closeout_record_fingerprint)
    expected_resolution = safe_status(value(closeout, :resolution_code))
    actual_fingerprint = optional_string(reference, :closeout_record_fingerprint)
    actual_resolution = safe_status(value(reference, :closeout_resolution_code))

    cond do
      closeout == %{} ->
        nil

      bound?(expected_fingerprint) and blank?(actual_fingerprint) ->
        "#{type_name}_closeout_record_fingerprint_missing"

      bound?(expected_resolution) and blank?(actual_resolution) ->
        "#{type_name}_closeout_resolution_missing"

      true ->
        nil
    end
  end

  defp replay_decision_binding_mismatch_reason(type, chain, reference) do
    decision = get_in_value(chain, [:retained_references, :replay_decision]) || %{}
    type_name = reference_type_name(type)
    expected_fingerprint = optional_string(decision, :replay_decision_fingerprint)
    expected_decision = safe_status(value(decision, :decision))
    actual_fingerprint = optional_string(reference, :replay_decision_fingerprint)
    actual_decision = safe_status(value(reference, :replay_decision_status))

    cond do
      decision == %{} ->
        nil

      bound?(actual_fingerprint) and bound?(expected_fingerprint) and actual_fingerprint != expected_fingerprint ->
        "#{type_name}_replay_decision_fingerprint_mismatch"

      bound?(actual_decision) and bound?(expected_decision) and actual_decision != expected_decision ->
        "#{type_name}_replay_decision_status_mismatch"

      true ->
        nil
    end
  end

  defp replay_decision_binding_missing_reason(type, chain, reference) do
    decision = get_in_value(chain, [:retained_references, :replay_decision]) || %{}
    type_name = reference_type_name(type)
    expected_fingerprint = optional_string(decision, :replay_decision_fingerprint)
    expected_decision = safe_status(value(decision, :decision))
    actual_fingerprint = optional_string(reference, :replay_decision_fingerprint)
    actual_decision = safe_status(value(reference, :replay_decision_status))

    cond do
      decision == %{} ->
        nil

      bound?(expected_fingerprint) and blank?(actual_fingerprint) ->
        "#{type_name}_replay_decision_fingerprint_missing"

      bound?(expected_decision) and blank?(actual_decision) ->
        "#{type_name}_replay_decision_status_missing"

      true ->
        nil
    end
  end

  defp side_effect_safety_missing_reason(type, chain, reference) do
    type_name = reference_type_name(type)
    expected_entered = get_in_value(chain, [:outcome, :side_effect_entered])
    expected_may = get_in_value(chain, [:outcome, :side_effect_may_have_happened])

    cond do
      is_boolean(expected_entered) and not is_boolean(value(reference, :side_effect_entered)) ->
        "#{type_name}_side_effect_entered_missing"

      is_boolean(expected_may) and not is_boolean(value(reference, :side_effect_may_have_happened)) ->
        "#{type_name}_side_effect_may_have_happened_missing"

      true ->
        nil
    end
  end

  defp side_effect_safety_mismatch_reason(type, chain, reference) do
    type_name = reference_type_name(type)
    expected_entered = get_in_value(chain, [:outcome, :side_effect_entered])
    expected_may = get_in_value(chain, [:outcome, :side_effect_may_have_happened])
    actual_entered = value(reference, :side_effect_entered)
    actual_may = value(reference, :side_effect_may_have_happened)

    cond do
      is_boolean(expected_entered) and is_boolean(actual_entered) and expected_entered != actual_entered ->
        "#{type_name}_side_effect_entered_mismatch"

      is_boolean(expected_may) and is_boolean(actual_may) and expected_may != actual_may ->
        "#{type_name}_side_effect_may_have_happened_mismatch"

      true ->
        nil
    end
  end

  defp required_reference_evidence_missing_reason(type, chain, reference, keys) do
    type_name = reference_type_name(type)

    Enum.find_value(keys, fn key ->
      expected = expected_reference_evidence(chain, key)
      actual = actual_reference_evidence(reference, key)

      if bound?(expected) and blank?(actual) do
        "#{type_name}_#{key}_missing"
      end
    end)
  end

  defp reference_evidence_mismatch_reason(type, chain, reference, keys) do
    type_name = reference_type_name(type)

    Enum.find_value(keys, fn key ->
      expected = expected_reference_evidence(chain, key)
      actual = actual_reference_evidence(reference, key)

      if bound?(expected) and bound?(actual) and safe_comparable(expected) != safe_comparable(actual) do
        "#{type_name}_#{key}_mismatch"
      end
    end)
  end

  defp closeout_evidence_keys do
    [
      :cutover_operation_request,
      :readiness_permit,
      :readiness_permit_decision,
      :authorization_record,
      :authorization_request,
      :consumption_guard,
      :cutover_gate,
      :dry_run_audit,
      :audit_history
    ]
  end

  defp replay_decision_evidence_keys do
    [
      :cutover_operation_request,
      :readiness_permit,
      :readiness_permit_decision,
      :authorization_record,
      :authorization_request,
      :consumption_guard
    ]
  end

  defp replay_request_evidence_keys do
    replay_decision_evidence_keys()
  end

  defp expected_reference_evidence(chain, :cutover_operation_request),
    do:
      get_in_value(chain, [:request, :request_fingerprint]) ||
        safe_chain_fingerprint(chain, :cutover_operation_request)

  defp expected_reference_evidence(chain, :readiness_permit),
    do:
      get_in_value(chain, [:readiness_permit, :permit_fingerprint]) ||
        safe_chain_fingerprint(chain, :readiness_permit)

  defp expected_reference_evidence(chain, :readiness_permit_decision),
    do:
      get_in_value(chain, [:readiness_permit, :decision]) ||
        safe_chain_fingerprint(chain, :readiness_permit_decision)

  defp expected_reference_evidence(chain, :authorization_record),
    do:
      get_in_value(chain, [:authorization, :authorization_record_fingerprint]) ||
        safe_chain_fingerprint(chain, :authorization_record)

  defp expected_reference_evidence(chain, :authorization_request),
    do:
      get_in_value(chain, [:authorization, :authorization_request_fingerprint]) ||
        safe_chain_fingerprint(chain, :authorization_request)

  defp expected_reference_evidence(chain, :consumption_guard),
    do:
      get_in_value(chain, [:consumption_guard, :decision_fingerprint]) ||
        safe_chain_fingerprint(chain, :consumption_guard)

  defp expected_reference_evidence(chain, :cutover_gate),
    do: get_in_value(chain, [:outcome, :cutover_gate_fingerprint]) || safe_chain_fingerprint(chain, :cutover_gate)

  defp expected_reference_evidence(chain, :dry_run_audit),
    do: get_in_value(chain, [:outcome, :dry_run_audit_fingerprint]) || safe_chain_fingerprint(chain, :dry_run_audit)

  defp expected_reference_evidence(chain, :audit_history),
    do: get_in_value(chain, [:outcome, :audit_history_fingerprint]) || safe_chain_fingerprint(chain, :audit_history)

  defp expected_reference_evidence(_chain, _key), do: nil

  defp actual_reference_evidence(reference, :cutover_operation_request),
    do:
      optional_string(reference, :cutover_operation_request_fingerprint) ||
        safe_reference_fingerprint(reference, :cutover_operation_request)

  defp actual_reference_evidence(reference, :readiness_permit),
    do:
      optional_string(reference, :readiness_permit_fingerprint) ||
        safe_reference_fingerprint(reference, :readiness_permit)

  defp actual_reference_evidence(reference, :readiness_permit_decision),
    do:
      safe_status(
        value(reference, :readiness_permit_decision) ||
          safe_reference_fingerprint(reference, :readiness_permit_decision)
      )
      |> blank_to_nil()

  defp actual_reference_evidence(reference, :authorization_record),
    do:
      optional_string(reference, :authorization_record_fingerprint) ||
        safe_reference_fingerprint(reference, :authorization_record)

  defp actual_reference_evidence(reference, :authorization_request),
    do:
      optional_string(reference, :authorization_request_fingerprint) ||
        safe_reference_fingerprint(reference, :authorization_request)

  defp actual_reference_evidence(reference, :consumption_guard),
    do:
      optional_string(reference, :consumption_guard_fingerprint) ||
        safe_reference_fingerprint(reference, :consumption_guard)

  defp actual_reference_evidence(reference, :cutover_gate),
    do: optional_string(reference, :cutover_gate_fingerprint) || safe_reference_fingerprint(reference, :cutover_gate)

  defp actual_reference_evidence(reference, :dry_run_audit),
    do: optional_string(reference, :dry_run_audit_fingerprint) || safe_reference_fingerprint(reference, :dry_run_audit)

  defp actual_reference_evidence(reference, :audit_history),
    do: optional_string(reference, :audit_history_fingerprint) || safe_reference_fingerprint(reference, :audit_history)

  defp actual_reference_evidence(_reference, _key), do: nil

  defp safe_chain_fingerprint(chain, key), do: optional_string(value(chain, :safe_evidence_fingerprints) || %{}, key)

  defp safe_reference_fingerprint(reference, key) do
    evidence = value(reference, :safe_evidence_fingerprints) || reference || %{}
    optional_string(evidence, key)
  end

  defp safe_comparable(value) when is_boolean(value), do: value
  defp safe_comparable(value), do: safe_status(value)

  defp reference_status_counts(existing, []) when is_map(existing) and map_size(existing) > 0 do
    @reference_types
    |> Map.new(fn type ->
      type_atom = String.to_atom(type)
      existing_counts = value(existing, type_atom) || value(existing, type) || %{}
      {type_atom, reference_count_snapshot(existing_counts, [])}
    end)
  end

  defp reference_status_counts(_existing, chains) do
    base = Map.new(@reference_types, &{String.to_atom(&1), reference_zero_counts()})

    Enum.reduce(chains, base, fn chain, acc ->
      chain
      |> reference_status_entries()
      |> Enum.reduce(acc, fn {type, status}, type_acc ->
        status_name = status |> value(:status) |> normalize_reference_status() |> String.to_atom()

        Map.update(type_acc, type, Map.update(reference_zero_counts(), status_name, 1, &(&1 + 1)), fn counts ->
          Map.update(counts, status_name, 1, &(&1 + 1))
        end)
      end)
    end)
  end

  defp reference_type_status_counts(existing, [], _type) when is_map(existing) and map_size(existing) > 0 do
    reference_count_snapshot(existing, [])
  end

  defp reference_type_status_counts(_existing, chains, type) do
    type = reference_type_atom(type)

    chains
    |> Enum.flat_map(&reference_status_entries/1)
    |> Enum.filter(fn {entry_type, _status} -> entry_type == type end)
    |> Enum.reduce(reference_zero_counts(), fn {_type, status}, acc ->
      status_name = status |> value(:status) |> normalize_reference_status() |> String.to_atom()
      Map.update(acc, status_name, 1, &(&1 + 1))
    end)
  end

  defp reference_count_snapshot(existing, []) when is_map(existing) do
    @reference_statuses
    |> Map.new(fn status ->
      status_atom = String.to_atom(status)
      {status_atom, non_negative_integer(value(existing, status_atom)) || 0}
    end)
  end

  defp reference_zero_counts, do: Map.new(@reference_statuses, &{String.to_atom(&1), 0})

  defp reference_status_entries(chain) do
    case value(chain, :retained_reference_statuses) do
      statuses when is_map(statuses) ->
        statuses
        |> Enum.map(fn {type, status} -> {reference_type_atom(type), status} end)
        |> Enum.filter(fn {type, status} -> Atom.to_string(type) in @reference_types and is_map(status) end)

      _statuses ->
        []
    end
  end

  defp recent_reference_codes(chains, key) do
    chains
    |> Enum.flat_map(fn chain ->
      chain
      |> reference_status_entries()
      |> Enum.map(fn {_type, status} -> value(status, key) end)
    end)
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.map(&safe_status/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp reference_type_atom(type) do
    type_name = reference_type_name(type)

    if type_name in @reference_types do
      String.to_atom(type_name)
    else
      :unsupported
    end
  end

  defp reference_type_name(type) do
    type
    |> safe_status()
    |> case do
      "replay_request" -> "replay_request_audit"
      type_name -> type_name
    end
  end

  defp normalize_reference_status(status) do
    status = safe_status(status)
    if status in @reference_statuses, do: status, else: "unsupported"
  end

  defp status_zero_counts, do: Map.new(@statuses, &{String.to_atom(&1), 0})

  defp overall_status([], []), do: "no_chain"
  defp overall_status([], _project_ids), do: "no_request"

  defp overall_status(chains, _project_ids) do
    cond do
      Enum.any?(chains, &(&1.closure_status == "malformed")) -> "malformed"
      Enum.any?(chains, &(&1.closure_status == "conflict")) -> "conflict"
      Enum.any?(chains, &(&1.closure_status == "stale")) -> "stale"
      Enum.any?(chains, &(&1.closure_status == "unsupported")) -> "unsupported"
      Enum.any?(chains, &(&1.closure_status == "open_manual_attention")) -> "open_manual_attention"
      Enum.any?(chains, &(&1.closure_status == "open_retryable")) -> "open_retryable"
      Enum.any?(chains, &(&1.closure_status == "no_request")) -> "no_request"
      Enum.any?(chains, &(&1.closure_status == "closed_no_side_effect")) -> "closed_no_side_effect"
      Enum.any?(chains, &(&1.closure_status == "closed_succeeded")) -> "closed_succeeded"
      true -> "no_chain"
    end
  end

  defp project_status([]), do: "no_request"
  defp project_status(chains), do: overall_status(chains, ["project"])

  defp normalize_overall_status(status, chains, project_ids) do
    status = safe_status(status)

    if status in @statuses do
      status
    else
      overall_status(chains, project_ids)
    end
  end

  defp normalize_project_status(status, chains) do
    status = safe_status(status)

    if status in @statuses do
      status
    else
      project_status(chains)
    end
  end

  defp project_ids_from_sources(sources) do
    [
      sources |> list_value(:projects) |> Enum.map(&optional_string(&1, :project_id)),
      project_ids_from_ledger(
        value(sources, :cutover_execution_outcome_ledger) ||
          value(sources, :execution_outcome_ledger)
      )
    ]
    |> List.flatten()
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp project_ids_from_ledger(nil), do: []

  defp project_ids_from_ledger(ledger) when is_map(ledger) do
    ledger
    |> CutoverExecutionOutcomeLedger.to_snapshot()
    |> list_value(:projects)
    |> Enum.map(&optional_string(&1, :project_id))
  end

  defp project_ids_from_ledger(_ledger), do: []

  defp project_fingerprints(chains) do
    chains
    |> Enum.flat_map(fn chain ->
      chain
      |> value(:safe_evidence_fingerprints)
      |> SafeSummary.sanitize_map(output_keys: :preserve)
      |> Enum.to_list()
    end)
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Enum.uniq()
    |> Map.new()
  end

  defp drop_chain?(chain), do: blank?(value(chain, :project_id)) and value(chain, :closure_status) != "malformed"

  defp chain_identity(chain) do
    [
      optional_string(chain, :closure_chain_id),
      optional_string(chain, :project_id),
      optional_string(chain, :operation),
      optional_string(chain, :side_effect_source),
      optional_string(chain, :attempt_fingerprint),
      optional_string(chain, :replay_key),
      optional_string(chain, :safe_evidence_fingerprint)
    ]
    |> Enum.map_join("|", &(&1 || "none"))
  end

  defp chain_sort_key(chain) do
    time =
      get_in_value(chain, [:time_summary, :outcome_completed_at]) ||
        get_in_value(chain, [:time_summary, :generated_at]) ||
        ""

    {
      time,
      optional_string(chain, :project_id) || "",
      operation_name(value(chain, :operation)),
      source_name(value(chain, :side_effect_source)),
      optional_string(chain, :replay_key) || optional_string(chain, :attempt_fingerprint) || ""
    }
  end

  defp closure_chain_id(chain) do
    "hub-cutover-closure-chain:" <>
      fingerprint(Map.take(chain, [:project_id, :operation, :side_effect_source, :attempt_fingerprint, :replay_key, :safe_evidence_fingerprint]))
  end

  defp safe_evidence_fingerprint(chain) do
    chain
    |> Map.take([
      :project_id,
      :provider_scope,
      :operation,
      :side_effect_source,
      :attempt_fingerprint,
      :replay_key,
      :safe_evidence_fingerprints
    ])
    |> fingerprint()
  end

  defp provider_scope_matches?(left, right) do
    left = provider_scope_snapshot(left)
    right = provider_scope_snapshot(right)

    cond do
      left == %{} or right == %{} ->
        false

      optional_string(left, :provider_scope_key) != nil and optional_string(right, :provider_scope_key) != nil ->
        optional_string(left, :provider_scope_key) == optional_string(right, :provider_scope_key)

      true ->
        left == right
    end
  end

  defp provider_scope_snapshot(scope) when is_map(scope) do
    %{
      kind: optional_string(scope, :kind) || optional_string(scope, :provider_kind),
      key: optional_string(scope, :key) || optional_string(scope, :provider_scope_key),
      provider_scope_key: optional_string(scope, :provider_scope_key) || optional_string(scope, :key),
      scope:
        scope
        |> value(:scope)
        |> Kernel.||(%{})
        |> SafeSummary.sanitize_map(output_keys: :preserve)
    }
    |> compact_map()
  end

  defp provider_scope_snapshot(_scope), do: %{}

  defp operation_name(operation) do
    case safe_status(operation) do
      "candidate_scan" -> "poll"
      "poll" -> "poll"
      "dispatch" -> "dispatch"
      "dispatch_application" -> "dispatch"
      "worker-start" -> "worker_start"
      "worker_start" -> "worker_start"
      "worker_start_handoff" -> "worker_start"
      "writeback" -> "writeback"
      "writeback_executor" -> "writeback"
      "" -> "unknown_operation"
      value -> value
    end
  end

  defp source_name(source) do
    case safe_status(source) do
      "candidate_scan" -> "candidate_scan"
      "poll" -> "candidate_scan"
      "dispatch" -> "dispatch_application"
      "dispatch_application" -> "dispatch_application"
      "worker_start" -> "worker_start_handoff"
      "worker_start_handoff" -> "worker_start_handoff"
      "writeback" -> "writeback_executor"
      "writeback_executor" -> "writeback_executor"
      "" -> "unknown_source"
      value -> value
    end
  end

  defp operation_list(values) do
    values
    |> List.wrap()
    |> Enum.map(&operation_name/1)
    |> Enum.filter(&(&1 in @operations))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp source_list(values) do
    values
    |> List.wrap()
    |> Enum.map(&source_name/1)
    |> Enum.filter(&(&1 in @sources))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp default_operations([]), do: @operations
  defp default_operations(values), do: values

  defp default_sources([]), do: @sources
  defp default_sources(values), do: values

  defp normalize_status(status) do
    status = safe_status(status)
    if status in @statuses, do: status, else: "unsupported"
  end

  defp default_reason("no_chain"), do: "closure_chain_missing"
  defp default_reason("no_request"), do: "cutover_operation_request_missing"
  defp default_reason("closed_succeeded"), do: "execution_succeeded"
  defp default_reason("closed_no_side_effect"), do: "side_effect_not_entered"
  defp default_reason("open_retryable"), do: "retryable_outcome_waiting_for_explicit_consideration"
  defp default_reason("open_manual_attention"), do: "open_outcome_requires_manual_attention"
  defp default_reason("conflict"), do: "closure_chain_conflict"
  defp default_reason("stale"), do: "closure_chain_evidence_stale"
  defp default_reason("malformed"), do: "closure_chain_malformed"
  defp default_reason("unsupported"), do: "closure_chain_unsupported"
  defp default_reason(_status), do: "closure_chain_unsupported"

  defp action_snapshots(actions) do
    actions
    |> action_codes()
    |> Enum.map(&%{code: &1})
  end

  defp action_codes(actions) when is_list(actions) do
    actions
    |> Enum.flat_map(fn
      %{code: code} -> [safe_status(code)]
      %{"code" => code} -> [safe_status(code)]
      action -> [safe_status(action)]
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp action_codes(action), do: action_codes(List.wrap(action))

  defp string_list(values) when is_list(values) do
    values
    |> Enum.map(&safe_status/1)
    |> Enum.reject(&blank?/1)
  end

  defp string_list(value), do: string_list(List.wrap(value))

  defp outcome_like?(input) when is_map(input) do
    bound?(value(input, :outcome_id)) or
      bound?(value(input, :evidence_fingerprint)) or
      safe_status(value(input, :status)) in [
        "not_executed",
        "blocked",
        "succeeded",
        "failed",
        "retryable",
        "unknown",
        "manual_attention",
        "unsupported",
        "malformed"
      ]
  end

  defp safe_status(nil), do: ""
  defp safe_status(value) when is_atom(value), do: value |> Atom.to_string() |> String.replace("-", "_")
  defp safe_status(value) when is_binary(value), do: value |> String.trim() |> String.replace("-", "_")
  defp safe_status(value), do: value |> to_string() |> String.trim() |> String.replace("-", "_")

  defp value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, nil} -> Map.get(map, Atom.to_string(key))
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key)
  defp value(_value, _key), do: nil

  defp list_value(map, key) do
    case value(map, key) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  defp get_in_value(map, path) when is_map(map) and is_list(path) do
    Enum.reduce_while(path, map, fn key, acc ->
      case value(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp get_in_value(_map, _path), do: nil

  defp optional_string(map, key) when is_map(map) do
    case value(map, key) do
      nil ->
        nil

      value when is_binary(value) ->
        value = String.trim(value)
        if value in ["", "nil", "null"], do: nil, else: value

      value when is_atom(value) ->
        Atom.to_string(value)

      value when is_integer(value) ->
        Integer.to_string(value)

      _value ->
        nil
    end
  end

  defp optional_string(value, _key), do: optional_string(value)
  defp optional_string(nil), do: nil

  defp optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value in ["", "nil", "null"], do: nil, else: value
  end

  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _other -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp iso8601(%DateTime{} = datetime), do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_value), do: nil

  defp fingerprint(value) do
    value
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp bound?(value), do: not blank?(value)
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(%{}), do: true
  defp blank?(_value), do: false
  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: value)
  defp blank_to_default(value, default), do: if(blank?(value), do: default, else: value)

  defp first_boolean(values) do
    Enum.find(List.wrap(values), &is_boolean/1)
  end

  defp truthy?(value) when value in [true, "true", "1", 1, true], do: true
  defp truthy?(_value), do: false

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
