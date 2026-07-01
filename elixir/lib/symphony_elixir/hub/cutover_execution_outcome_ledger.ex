defmodule SymphonyElixir.Hub.CutoverExecutionOutcomeLedger do
  @moduledoc """
  Hub cutover execution outcome ledger baseline.

  The ledger records safe facts after the authorization consumption boundary:
  guard-blocked attempts that did not enter a side-effect boundary, and safe
  executor/starter/writeback results after an allowed guard. It is model-only
  and does not call providers, start workers, mutate systemd, or edit
  configuration.
  """

  alias SymphonyElixir.Hub.{CutoverAuthorizationConsumptionGuard, ProviderGovernance, SafeSummary}

  # Dialyzer collapses defensive boolean normalization branches in this model-only
  # module into line-1 no_match warnings, without actionable function locations.
  @dialyzer :no_match

  @version 1
  @operations ["poll", "dispatch", "worker_start", "writeback"]
  @sources ["candidate_scan", "dispatch_application", "worker_start_handoff", "writeback_executor"]
  @statuses [
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
  @guard_decisions ["allowed", "blocked", "no_authorization", "stale", "manual_attention", "unsupported", "malformed"]
  @terminal_statuses ["not_executed", "blocked", "succeeded", "failed", "retryable", "unsupported", "malformed"]
  @unresolved_statuses ["unknown", "manual_attention"]
  @default_recent_limit 20
  @source_operations %{
    "candidate_scan" => "poll",
    "dispatch_application" => "dispatch",
    "worker_start_handoff" => "worker_start",
    "writeback_executor" => "writeback"
  }

  @type fact :: map()
  @type summary :: map()

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
      |> Enum.map(&fact_snapshot/1)
      |> Enum.reject(&blank?(value(&1, :project_id)))
      |> dedupe_facts()
      |> Enum.sort_by(&event_sort_key/1)

    %{
      version: @version,
      generated_at: now,
      status: overall_status(events),
      counts: count_snapshot(%{}, events),
      recent_outcomes: Enum.take(events, @default_recent_limit),
      unresolved_outcomes: unresolved_outcomes(events),
      terminal_outcomes: terminal_outcomes(events),
      projects: project_summaries(events),
      no_side_effects: all_no_side_effects?(events)
    }
    |> to_snapshot()
  end

  @spec to_snapshot(term()) :: summary()
  def to_snapshot(summary) when is_map(summary) do
    recent_outcomes =
      summary
      |> list_value(:recent_outcomes)
      |> Enum.map(&fact_snapshot/1)
      |> Enum.sort_by(&event_sort_key/1)
      |> Enum.take(@default_recent_limit)

    projects =
      summary
      |> list_value(:projects)
      |> Enum.map(&project_snapshot/1)
      |> Enum.sort_by(& &1.project_id)

    events =
      if recent_outcomes == [] and projects != [] do
        Enum.flat_map(projects, & &1.recent_outcomes)
      else
        recent_outcomes
      end

    generated_at = iso8601(value(summary, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      version: positive_integer(value(summary, :version)) || @version,
      generated_at: generated_at,
      status: normalize_overall_status(value(summary, :status), events),
      counts: count_snapshot(value(summary, :counts), events),
      recent_outcomes: recent_outcomes,
      unresolved_outcomes: outcome_list(value(summary, :unresolved_outcomes), events, &unresolved?/1),
      terminal_outcomes: outcome_list(value(summary, :terminal_outcomes), events, &terminal?/1),
      projects: projects,
      no_side_effects: not_false?(value(summary, :no_side_effects))
    }
  end

  def to_snapshot(_summary), do: to_snapshot(%{})

  @spec observability_snapshot(term()) :: summary() | nil
  def observability_snapshot(nil), do: nil
  def observability_snapshot(summary) when is_map(summary), do: to_snapshot(summary)
  def observability_snapshot(_summary), do: nil

  @spec fact_snapshot(term()) :: fact()
  def fact_snapshot(input) when is_map(input) do
    raw_guard =
      value(input, :authorization_consumption_guard) ||
        value(input, :authorization_consumption)

    guard = guard_snapshot(raw_guard)

    raw_executor_result =
      value(input, :executor_result) ||
        value(input, :starter_result) ||
        value(input, :result) ||
        %{}

    executor_result = safe_executor_result(raw_executor_result)

    status = normalize_status(value(input, :status) || status_from_inputs(input, guard, executor_result))
    side_effect_entered = side_effect_entered?(input, guard, executor_result, status)
    no_side_effects = false?(side_effect_entered)
    evidence = evidence_fingerprints(input, guard, executor_result)

    started_at =
      iso8601(value(input, :started_at)) ||
        iso8601(value(input, :attempted_at)) ||
        iso8601(value(input, :evaluated_at))

    completed_at =
      iso8601(value(input, :completed_at)) ||
        iso8601(value(input, :finished_at)) ||
        iso8601(value(input, :generated_at))

    project_id = optional_string(input, :project_id) || optional_string(guard || %{}, :project_id)
    operation = operation_name(value(input, :operation) || value(guard || %{}, :operation))

    raw_source =
      value(input, :side_effect_source) ||
        value(input, :source) ||
        value(guard || %{}, :side_effect_source)

    source = source_name(raw_source)

    raw_provider_scope =
      value(input, :provider_scope) ||
        value(guard || %{}, :provider_scope) ||
        %{}

    provider_scope = provider_scope_snapshot(raw_provider_scope)

    raw_reason =
      value(input, :reason_code) ||
        value(input, :reason) ||
        reason_from_status(status, guard, executor_result)

    reason_code = safe_status(raw_reason)

    action_code = safe_status(value(input, :action_code) || value(input, :action) || action_from_status(status, guard))
    mode = executor_mode_snapshot(value(input, :executor_mode) || value(input, :mode) || value(input, :executor))
    stable_evidence_fingerprint = stable_evidence_fingerprint(project_id, provider_scope, operation, source, evidence)

    snapshot =
      %{
        version: positive_integer(value(input, :version)) || @version,
        outcome_id: optional_string(input, :outcome_id),
        attempt_fingerprint: optional_string(input, :attempt_fingerprint),
        replay_key: optional_string(input, :replay_key),
        project_id: project_id,
        provider_scope: provider_scope,
        operation: operation,
        side_effect_source: source,
        status: status,
        reason_code: reason_code || default_reason(status),
        action_code: action_code,
        reason_codes: reason_codes(input, status, reason_code, guard, executor_result),
        required_operator_actions: action_snapshots(value(input, :required_operator_actions) || List.wrap(action_code)),
        authorization_consumption_guard: guard,
        guard_decision: guard_decision(guard),
        authorization_record_fingerprint:
          optional_string(input, :authorization_record_fingerprint) ||
            optional_string(guard || %{}, :authorization_record_fingerprint),
        authorization_request_fingerprint:
          optional_string(input, :authorization_request_fingerprint) ||
            optional_string(guard || %{}, :authorization_request_fingerprint),
        cutover_operation_request_fingerprint:
          optional_string(input, :cutover_operation_request_fingerprint) ||
            optional_string(evidence, :cutover_operation_request),
        readiness_permit_fingerprint:
          optional_string(input, :readiness_permit_fingerprint) ||
            optional_string(evidence, :readiness_permit),
        readiness_permit_decision:
          safe_status(
            value(input, :readiness_permit_decision) ||
              optional_string(evidence, :readiness_permit_decision)
          ),
        cutover_gate_fingerprint:
          optional_string(input, :cutover_gate_fingerprint) ||
            optional_string(evidence, :cutover_gate),
        dry_run_audit_fingerprint:
          optional_string(input, :dry_run_audit_fingerprint) ||
            optional_string(evidence, :dry_run_audit),
        audit_history_fingerprint:
          optional_string(input, :audit_history_fingerprint) ||
            optional_string(evidence, :audit_history),
        evidence_fingerprint:
          optional_string(input, :evidence_fingerprint) ||
            stable_evidence_fingerprint,
        safe_evidence_fingerprints: evidence,
        executor_mode: mode,
        executor_result: executor_result,
        side_effect_entered: side_effect_entered,
        no_side_effects: no_side_effects,
        side_effect_may_have_happened: side_effect_may_have_happened?(input, status, side_effect_entered),
        replay_blocked: unresolved_status?(status),
        unresolved: unresolved_status?(status),
        terminal: terminal_status?(status),
        started_at: started_at,
        completed_at: completed_at,
        generated_at: iso8601(value(input, :generated_at)) || completed_at || started_at
      }

    snapshot =
      snapshot
      |> Map.put(:attempt_fingerprint, optional_string(snapshot, :attempt_fingerprint) || attempt_fingerprint(snapshot))
      |> Map.put(:replay_key, optional_string(snapshot, :replay_key) || replay_key(snapshot))
      |> Map.put(:outcome_id, optional_string(snapshot, :outcome_id) || outcome_id(snapshot))
      |> compact_map()

    snapshot
  rescue
    _error -> malformed_fact(input)
  catch
    _kind, _reason -> malformed_fact(input)
  end

  def fact_snapshot(input), do: malformed_fact(%{result: input})

  @spec from_guard_decision(term(), keyword()) :: fact()
  def from_guard_decision(decision, opts \\ []) when is_list(opts) do
    decision = CutoverAuthorizationConsumptionGuard.to_decision(decision)
    now = opts |> Keyword.get(:now) |> Kernel.||(DateTime.utc_now()) |> iso8601()
    status = status_from_guard_allowed(decision)

    fact_snapshot(%{
      project_id: decision.project_id,
      provider_scope: decision.provider_scope,
      operation: decision.operation,
      side_effect_source: decision.side_effect_source,
      status: status,
      reason_code: decision.reason_code,
      action_code: value(decision, :action_code),
      required_operator_actions: value(decision, :required_operator_actions),
      authorization_consumption_guard: decision,
      executor_mode: Keyword.get(opts, :executor_mode),
      side_effect_entered: false,
      no_side_effects: true,
      side_effect_may_have_happened: false,
      started_at: now,
      completed_at: now,
      generated_at: now
    })
  end

  @spec from_provider_result(term(), keyword()) :: fact()
  def from_provider_result(result, opts \\ []) when is_list(opts) do
    now = opts |> Keyword.get(:now) |> Kernel.||(DateTime.utc_now()) |> iso8601()
    result_summary = value(result, :result_summary) || %{}
    guard = value(result_summary, :authorization_consumption)
    request = value(result, :request) || %{}

    if is_map(value(result_summary, :execution_outcome)) do
      fact_snapshot(value(result_summary, :execution_outcome))
    else
      fact_snapshot(%{
        project_id: Keyword.get(opts, :project_id) || optional_string(result, :project_id) || optional_string(request, :project_id),
        provider_scope:
          Keyword.get(opts, :provider_scope) ||
            value(request, :provider_scope) ||
            %{
              kind: optional_string(result, :provider_kind),
              key: optional_string(result, :provider_scope_key),
              provider_scope_key: optional_string(result, :provider_scope_key),
              scope: %{}
            },
        operation: Keyword.get(opts, :operation) || operation_from_provider_result(result),
        side_effect_source: Keyword.get(opts, :side_effect_source) || source_from_provider_result(result),
        status: status_from_provider_result(result),
        reason_code: reason_from_provider_result(result),
        action_code: action_from_provider_result(result),
        authorization_consumption_guard: guard,
        executor_mode: executor_mode_from_provider_result(result_summary),
        executor_result: provider_result_summary(result),
        side_effect_entered: provider_result_side_effect_entered?(result),
        side_effect_may_have_happened: provider_result_may_have_happened?(result),
        started_at: Keyword.get(opts, :started_at) || now,
        completed_at: Keyword.get(opts, :completed_at) || now,
        generated_at: now
      })
    end
  end

  @spec from_worker_start_result(term(), keyword()) :: fact()
  def from_worker_start_result(result, opts \\ []) when is_list(opts) do
    if is_map(result) do
      now = opts |> Keyword.get(:now) |> Kernel.||(DateTime.utc_now()) |> iso8601()

      fact_snapshot(%{
        project_id: optional_string(result, :project_id),
        provider_scope: %{
          kind: optional_string(result, :provider_kind),
          key: optional_string(result, :provider_scope_key),
          provider_scope_key: optional_string(result, :provider_scope_key),
          scope: get_in_value(result, [:request, :provider_scope]) || %{}
        },
        operation: "worker_start",
        side_effect_source: "worker_start_handoff",
        status: status_from_worker_start(result),
        reason_code: safe_status(value(result, :reason)),
        action_code: action_from_worker_start(result),
        authorization_consumption_guard: value(result, :authorization_consumption),
        executor_mode: %{mode: "real_worker_starter", worker_start: true},
        executor_result: result,
        side_effect_entered: worker_start_side_effect_entered?(result),
        side_effect_may_have_happened: worker_start_may_have_happened?(result),
        started_at: get_in_value(result, [:starter_result, :started_at]) || now,
        completed_at: now,
        generated_at: now
      })
    else
      fact_snapshot(Map.merge(Map.new(opts), %{result: result, status: "malformed"}))
    end
  end

  @spec unresolved_for?(term(), term()) :: boolean()
  def unresolved_for?(ledger, candidate) do
    candidate = fact_snapshot(candidate)

    ledger
    |> to_snapshot()
    |> list_value(:unresolved_outcomes)
    |> Enum.any?(&same_attempt?(&1, candidate))
  end

  @spec find_unresolved(term(), term()) :: fact() | nil
  def find_unresolved(ledger, candidate) do
    candidate = fact_snapshot(candidate)

    ledger
    |> to_snapshot()
    |> list_value(:unresolved_outcomes)
    |> Enum.find(&same_attempt?(&1, candidate))
  end

  defp events_from_sources(sources) do
    direct =
      list_value(sources, :execution_outcomes) ++
        list_value(sources, :outcomes) ++
        list_value(sources, :events)

    previous_ledger = value(sources, :previous_ledger) || value(sources, :cutover_execution_outcome_ledger)

    previous =
      list_value(previous_ledger, :recent_outcomes) ++
        list_value(previous_ledger, :unresolved_outcomes) ++
        list_value(previous_ledger, :terminal_outcomes)

    direct ++
      previous ++
      candidate_scan_events(value(sources, :provider_queue) || value(sources, :hub_provider_queue)) ++
      tick_events(value(sources, :tick) || value(sources, :poll_tick)) ++
      dispatch_events(value(sources, :dispatch_plan_application) || value(sources, :hub_dispatch_plan_application)) ++
      worker_start_events(value(sources, :worker_start_handoff) || value(sources, :hub_worker_start_handoff)) ++
      writeback_events(value(sources, :writeback) || value(sources, :hub_writeback))
  end

  defp candidate_scan_events(provider_queue) do
    provider_queue
    |> list_value(:recent_results)
    |> Enum.filter(&(operation_name(value(&1, :operation_kind)) == "candidate_scan"))
    |> Enum.map(&from_provider_result(&1, operation: "poll", side_effect_source: "candidate_scan"))
  end

  defp tick_events(tick) do
    tick
    |> list_value(:results)
    |> Enum.flat_map(fn result ->
      outcome = value(result, :execution_outcome)
      provider_result = value(result, :provider_result)
      consumption = value(result, :authorization_consumption)

      cond do
        is_map(outcome) -> [outcome]
        is_map(provider_result) -> [from_provider_result(provider_result, operation: "poll", side_effect_source: "candidate_scan")]
        is_map(consumption) -> [from_guard_decision(consumption)]
        true -> []
      end
    end)
  end

  defp dispatch_events(summary) do
    summary
    |> list_value(:projects)
    |> Enum.flat_map(fn project ->
      project
      |> list_value(:outcomes)
      |> Enum.map(&dispatch_outcome(project, &1))
    end)
  end

  defp dispatch_outcome(project, outcome) do
    if is_map(value(outcome, :execution_outcome)) do
      fact_snapshot(value(outcome, :execution_outcome))
    else
      dispatch_outcome_from_summary(project, outcome)
    end
  end

  defp dispatch_outcome_from_summary(project, outcome) do
    status =
      case safe_status(value(outcome, :status)) do
        "applied" -> "succeeded"
        "already_applied" -> "not_executed"
        "manual_attention" -> "manual_attention"
        "blocked" -> "blocked"
        "skipped" -> "not_executed"
        _status -> "not_executed"
      end

    fact_snapshot(%{
      project_id: optional_string(outcome, :project_id) || optional_string(project, :project_id),
      provider_scope: %{
        kind: optional_string(outcome, :provider_kind) || optional_string(project, :provider_kind),
        key: optional_string(outcome, :provider_scope_key) || optional_string(project, :provider_scope_key),
        provider_scope_key:
          optional_string(outcome, :provider_scope_key) ||
            optional_string(project, :provider_scope_key),
        scope: get_in_value(outcome, [:issue_ref, :provider_scope]) || %{}
      },
      operation: "dispatch",
      side_effect_source: "dispatch_application",
      status: status,
      reason_code: safe_status(value(outcome, :reason)) || default_reason(status),
      authorization_consumption_guard: value(outcome, :authorization_consumption),
      executor_mode: %{mode: "dispatch_application", dispatch_application: true, dispatch_mutation: true},
      executor_result: outcome,
      side_effect_entered: status == "succeeded",
      side_effect_may_have_happened: status == "succeeded",
      started_at: get_in_value(outcome, [:intent, :requested_at]),
      completed_at: value(summary = outcome, :generated_at) || value(summary, :completed_at)
    })
  end

  defp worker_start_events(summary) do
    summary
    |> list_value(:results)
    |> Enum.map(&from_worker_start_result/1)
  end

  defp writeback_events(writeback) do
    writeback
    |> list_value(:recent_results)
    |> Enum.filter(&(operation_name(value(&1, :operation_kind)) in ["stage_writeback", "comment_workpad_upsert"]))
    |> Enum.map(&from_provider_result(&1, operation: "writeback", side_effect_source: "writeback_executor"))
  end

  defp guard_snapshot(nil), do: nil

  defp guard_snapshot(value) when is_map(value) do
    CutoverAuthorizationConsumptionGuard.to_decision(value)
  end

  defp guard_snapshot(_value), do: nil

  defp status_from_inputs(input, guard, executor_result) do
    cond do
      is_map(guard) and false?(guard.allowed) ->
        status_from_guard_decision(guard.decision)

      is_map(executor_result) and map_size(executor_result) > 0 ->
        status_from_executor_result(executor_result)

      false?(value(input, :side_effect_entered)) ->
        "not_executed"

      true ->
        "unknown"
    end
  end

  defp status_from_guard_decision("allowed"), do: "unknown"
  defp status_from_guard_decision("manual_attention"), do: "manual_attention"
  defp status_from_guard_decision("unsupported"), do: "unsupported"
  defp status_from_guard_decision("malformed"), do: "malformed"
  defp status_from_guard_decision(_decision), do: "not_executed"

  defp status_from_guard_allowed(%{allowed: true}), do: "unknown"
  defp status_from_guard_allowed(%{decision: decision}), do: status_from_guard_decision(decision)

  defp status_from_executor_result(result) do
    status = safe_status(value(result, :status) || value(result, :result) || value(result, :outcome))

    case status do
      status when status in ["success", "succeeded", "ack", "applied"] -> "succeeded"
      status when status in ["retryable_failure", "rate_limited", "circuit_open", "timed_out", "retryable", "retry"] -> "retryable"
      status when status in ["unknown_result", "unknown"] -> "unknown"
      "manual_attention" -> "manual_attention"
      status when status in ["permanent_failure", "failed", "failure"] -> "failed"
      status when status in ["blocked", "skipped", "canceled", "cancelled"] -> "not_executed"
      "unsupported" -> "unsupported"
      "malformed" -> "malformed"
      _status -> "unknown"
    end
  end

  defp status_from_provider_result(result) do
    status = safe_status(value(result, :status))

    case status do
      "success" -> "succeeded"
      status when status in ["retryable_failure", "rate_limited", "circuit_open", "timed_out"] -> "retryable"
      "unknown_result" -> "unknown"
      "permanent_failure" -> if value(result, :manual_attention) == true, do: "manual_attention", else: "failed"
      "canceled" -> "not_executed"
      _status -> status_from_executor_result(result)
    end
  end

  defp status_from_worker_start(result) do
    case safe_status(value(result, :status)) do
      "ack" -> "succeeded"
      "failed" -> "failed"
      "unknown" -> "unknown"
      "manual_attention" -> "manual_attention"
      "skipped" -> "not_executed"
      "already_acked" -> "not_executed"
      _status -> "unknown"
    end
  end

  defp normalize_status(status) do
    status = safe_status(status)

    cond do
      status in @statuses -> status
      status == "success" -> "succeeded"
      status == "failure" -> "failed"
      status == "retryable_failure" -> "retryable"
      status == "unknown_result" -> "unknown"
      status == "skipped" -> "not_executed"
      true -> "unknown"
    end
  end

  defp operation_from_provider_result(result) do
    case operation_name(value(result, :operation_kind)) do
      "candidate_scan" -> "poll"
      "stage_writeback" -> "writeback"
      "comment_workpad_upsert" -> "writeback"
      operation -> operation
    end
  end

  defp source_from_provider_result(result) do
    case operation_from_provider_result(result) do
      "poll" -> "candidate_scan"
      "writeback" -> "writeback_executor"
      operation -> Map.get(@source_operations, operation, "unknown_source")
    end
  end

  defp reason_from_provider_result(result) do
    result_summary = value(result, :result_summary) || %{}

    safe_status(value(result_summary, :reason) || value(result_summary, :error) || value(result, :error_class)) ||
      default_reason(status_from_provider_result(result))
  end

  defp action_from_provider_result(result) do
    result_summary = value(result, :result_summary) || %{}
    safe_status(value(result_summary, :action))
  end

  defp executor_mode_from_provider_result(summary) do
    %{
      mode: optional_string(summary, :executor),
      boundary: optional_string(summary, :boundary),
      provider_io: value(summary, :provider_io) == true
    }
    |> compact_map()
  end

  defp provider_result_summary(result) when is_map(result) do
    if Map.has_key?(result, :request_id) and Map.has_key?(result, :logical_key) and
         Map.has_key?(result, :operation_kind) do
      ProviderGovernance.result_summary(result)
    else
      SafeSummary.sanitize_map(result, output_keys: :preserve, atom_values: :preserve)
    end
  rescue
    _error -> SafeSummary.sanitize_map(result, output_keys: :preserve, atom_values: :preserve)
  catch
    _kind, _reason -> SafeSummary.sanitize_map(result, output_keys: :preserve, atom_values: :preserve)
  end

  defp provider_result_summary(_result), do: %{}

  defp provider_result_side_effect_entered?(result) do
    summary = value(result, :result_summary) || %{}

    value(summary, :provider_io) == true or value(result, :status) == :success or
      safe_status(value(result, :status)) == "success"
  end

  defp provider_result_may_have_happened?(result) do
    status = status_from_provider_result(result)
    provider_result_side_effect_entered?(result) or status in ["unknown", "retryable"]
  end

  defp worker_start_side_effect_entered?(result) do
    status = safe_status(value(result, :status))
    value(result, :ledger_changed) == true or status in ["ack", "failed", "unknown", "manual_attention"]
  end

  defp worker_start_may_have_happened?(result) do
    status = status_from_worker_start(result)
    worker_start_side_effect_entered?(result) or status in ["unknown", "manual_attention"]
  end

  defp side_effect_entered?(input, guard, executor_result, status) do
    cond do
      value(input, :side_effect_entered) in [true, false] ->
        value(input, :side_effect_entered) == true

      value(input, :no_side_effects) == true ->
        false

      is_map(guard) and false?(guard.allowed) ->
        false

      is_map(executor_result) and map_size(executor_result) > 0 ->
        value(executor_result, :provider_io) == true or
          value(executor_result, :ledger_changed) == true or
          status in ["succeeded", "failed", "retryable", "unknown", "manual_attention"]

      true ->
        status in ["succeeded", "failed", "retryable", "unknown", "manual_attention"]
    end
  end

  defp side_effect_may_have_happened?(input, status, side_effect_entered) do
    cond do
      value(input, :side_effect_may_have_happened) in [true, false] ->
        value(input, :side_effect_may_have_happened) == true

      side_effect_entered ->
        true

      status in ["unknown", "manual_attention", "retryable"] ->
        true

      true ->
        false
    end
  end

  defp reason_from_status(status, guard, executor_result) do
    cond do
      is_map(guard) and not blank?(value(guard, :reason_code)) -> value(guard, :reason_code)
      is_map(executor_result) and not blank?(value(executor_result, :reason)) -> value(executor_result, :reason)
      is_map(executor_result) and not blank?(value(executor_result, :error)) -> value(executor_result, :error)
      true -> default_reason(status)
    end
  end

  defp action_from_status("not_executed", guard) when is_map(guard), do: value(guard, :action_code)
  defp action_from_status("blocked", guard) when is_map(guard), do: value(guard, :action_code)
  defp action_from_status("unknown", _guard), do: "manual_outcome_review"
  defp action_from_status("manual_attention", _guard), do: "resolve_manual_attention"
  defp action_from_status(_status, _guard), do: nil

  defp action_from_worker_start(%{status: "unknown"}), do: "manual_outcome_review"
  defp action_from_worker_start(%{status: "manual_attention"}), do: "resolve_manual_attention"
  defp action_from_worker_start(_result), do: nil

  defp default_reason("not_executed"), do: "side_effect_not_entered"
  defp default_reason("blocked"), do: "execution_blocked"
  defp default_reason("succeeded"), do: "execution_succeeded"
  defp default_reason("failed"), do: "execution_failed"
  defp default_reason("retryable"), do: "execution_retryable"
  defp default_reason("unknown"), do: "execution_result_unknown"
  defp default_reason("manual_attention"), do: "execution_requires_manual_attention"
  defp default_reason("unsupported"), do: "execution_unsupported"
  defp default_reason("malformed"), do: "execution_outcome_malformed"
  defp default_reason(_status), do: "execution_result_unknown"

  defp reason_codes(input, status, reason_code, guard, executor_result) do
    []
    |> Kernel.++(string_list(value(input, :reason_codes)))
    |> Kernel.++(if(is_map(guard), do: string_list(value(guard, :reason_codes)), else: []))
    |> Kernel.++(if(is_map(executor_result), do: string_list(value(executor_result, :reason_codes)), else: []))
    |> Kernel.++([reason_code || default_reason(status)])
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp evidence_fingerprints(input, guard, executor_result) do
    guard_evidence =
      if is_map(guard) do
        value(guard, :safe_evidence_fingerprints) || %{}
      else
        %{}
      end

    base =
      %{
        authorization_record:
          optional_string(input, :authorization_record_fingerprint) ||
            optional_string(guard || %{}, :authorization_record_fingerprint),
        authorization_request:
          optional_string(input, :authorization_request_fingerprint) ||
            optional_string(guard || %{}, :authorization_request_fingerprint),
        cutover_operation_request:
          optional_string(input, :cutover_operation_request_fingerprint) ||
            optional_string(guard_evidence, :cutover_operation_request),
        readiness_permit:
          optional_string(input, :readiness_permit_fingerprint) ||
            optional_string(guard_evidence, :readiness_permit),
        readiness_permit_decision:
          safe_status(
            value(input, :readiness_permit_decision) ||
              value(guard_evidence, :readiness_permit_decision)
          ),
        cutover_gate:
          optional_string(input, :cutover_gate_fingerprint) ||
            optional_string(guard_evidence, :cutover_gate),
        dry_run_audit:
          optional_string(input, :dry_run_audit_fingerprint) ||
            optional_string(guard_evidence, :dry_run_audit),
        audit_history:
          optional_string(input, :audit_history_fingerprint) ||
            optional_string(guard_evidence, :audit_history),
        consumption_guard:
          optional_string(input, :consumption_guard_fingerprint) ||
            guard_fingerprint(guard),
        outcome_evidence:
          optional_string(input, :evidence_fingerprint) ||
            fingerprint(SafeSummary.sanitize_map(executor_result, output_keys: :preserve))
      }

    base
    |> Map.merge(SafeSummary.sanitize_map(value(input, :safe_evidence_fingerprints) || %{}, output_keys: :preserve))
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
    |> SafeSummary.sanitize_map(output_keys: :preserve)
  end

  defp safe_executor_result(result) when is_map(result) do
    result
    |> SafeSummary.sanitize_map(output_keys: :preserve, atom_values: :preserve)
    |> compact_map()
  end

  defp safe_executor_result(_result), do: %{}

  defp executor_mode_snapshot(mode) when is_map(mode), do: SafeSummary.sanitize_map(mode, output_keys: :preserve, atom_values: :preserve)
  defp executor_mode_snapshot(mode) when is_atom(mode), do: %{mode: Atom.to_string(mode)}
  defp executor_mode_snapshot(mode) when is_binary(mode), do: %{mode: mode}
  defp executor_mode_snapshot(_mode), do: %{}

  defp malformed_fact(input) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    fact_snapshot(%{
      project_id: optional_string(input, :project_id),
      operation: operation_name(value(input, :operation)),
      side_effect_source: source_name(value(input, :side_effect_source) || value(input, :source)),
      status: "malformed",
      reason_code: "execution_outcome_input_malformed",
      action_code: "fix_execution_outcome_input",
      side_effect_entered: false,
      no_side_effects: true,
      side_effect_may_have_happened: false,
      generated_at: now,
      completed_at: now
    })
  end

  defp project_summaries(events) do
    events
    |> Enum.group_by(& &1.project_id)
    |> Enum.map(fn {project_id, outcomes} ->
      %{
        project_id: project_id,
        status: project_status(outcomes),
        counts: count_snapshot(%{}, outcomes),
        recent_outcomes: Enum.take(outcomes, @default_recent_limit),
        unresolved_outcomes: unresolved_outcomes(outcomes),
        terminal_outcomes: terminal_outcomes(outcomes),
        safe_evidence_fingerprints: project_fingerprints(outcomes),
        no_side_effects: all_no_side_effects?(outcomes)
      }
      |> project_snapshot()
    end)
  end

  defp project_snapshot(project) when is_map(project) do
    outcomes =
      project
      |> list_value(:recent_outcomes)
      |> Enum.map(&fact_snapshot/1)
      |> Enum.sort_by(&event_sort_key/1)
      |> Enum.take(@default_recent_limit)

    project_id = optional_string(project, :project_id) || outcomes |> List.first() |> optional_string(:project_id)

    %{
      version: positive_integer(value(project, :version)) || @version,
      project_id: project_id,
      status: normalize_project_status(value(project, :status), outcomes),
      counts: count_snapshot(value(project, :counts), outcomes),
      recent_outcomes: outcomes,
      unresolved_outcomes: outcome_list(value(project, :unresolved_outcomes), outcomes, &unresolved?/1),
      terminal_outcomes: outcome_list(value(project, :terminal_outcomes), outcomes, &terminal?/1),
      safe_evidence_fingerprints: project_fingerprints(outcomes),
      no_side_effects: not_false?(value(project, :no_side_effects))
    }
  end

  defp project_snapshot(project), do: project_snapshot(%{project_id: project})

  defp count_snapshot(counts, events) when is_map(counts) do
    side_effect_entered_count =
      count_or_existing_boolean(counts, :side_effect_entered_count, events, :side_effect_entered, true)

    side_effect_not_entered_count =
      count_or_existing_boolean(counts, :side_effect_not_entered_count, events, :side_effect_entered, false)

    %{
      outcome_count: non_negative_integer(value(counts, :outcome_count)) || length(events),
      not_executed_count: count_or_existing(counts, :not_executed_count, events, "not_executed"),
      blocked_count: count_or_existing(counts, :blocked_count, events, "blocked"),
      succeeded_count: count_or_existing(counts, :succeeded_count, events, "succeeded"),
      failed_count: count_or_existing(counts, :failed_count, events, "failed"),
      retryable_count: count_or_existing(counts, :retryable_count, events, "retryable"),
      unknown_count: count_or_existing(counts, :unknown_count, events, "unknown"),
      manual_attention_count: count_or_existing(counts, :manual_attention_count, events, "manual_attention"),
      unsupported_count: count_or_existing(counts, :unsupported_count, events, "unsupported"),
      malformed_count: count_or_existing(counts, :malformed_count, events, "malformed"),
      side_effect_entered_count: side_effect_entered_count,
      side_effect_not_entered_count: side_effect_not_entered_count,
      side_effect_may_have_happened_count:
        count_or_existing_boolean(
          counts,
          :side_effect_may_have_happened_count,
          events,
          :side_effect_may_have_happened,
          true
        ),
      unresolved_count: count_or_existing_boolean(counts, :unresolved_count, events, :unresolved, true),
      terminal_count: count_or_existing_boolean(counts, :terminal_count, events, :terminal, true),
      operation_status_counts: operation_status_counts(value(counts, :operation_status_counts), events),
      source_status_counts: source_status_counts(value(counts, :source_status_counts), events),
      guard_decision_counts: guard_decision_counts(value(counts, :guard_decision_counts), events)
    }
  end

  defp count_snapshot(_counts, events), do: count_snapshot(%{}, events)

  defp count_or_existing(counts, key, events, status) do
    non_negative_integer(value(counts, key)) || Enum.count(events, &(&1.status == status))
  end

  defp count_or_existing_boolean(counts, key, events, field, expected) do
    non_negative_integer(value(counts, key)) || Enum.count(events, &(value(&1, field) == expected))
  end

  defp operation_status_counts(existing, _events) when is_map(existing) and map_size(existing) > 0 do
    SafeSummary.sanitize_map(existing, output_keys: :preserve)
  end

  defp operation_status_counts(_existing, events) do
    base = Map.new(@operations, &{String.to_atom(&1), status_zero_counts()})

    Enum.reduce(events, base, fn event, acc ->
      operation = operation_name(value(event, :operation)) |> String.to_atom()
      status = normalize_status(value(event, :status)) |> String.to_atom()

      Map.update(acc, operation, Map.update(status_zero_counts(), status, 1, &(&1 + 1)), fn counts ->
        Map.update(counts, status, 1, &(&1 + 1))
      end)
    end)
  end

  defp source_status_counts(existing, _events) when is_map(existing) and map_size(existing) > 0 do
    SafeSummary.sanitize_map(existing, output_keys: :preserve)
  end

  defp source_status_counts(_existing, events) do
    base = Map.new(@sources, &{String.to_atom(&1), status_zero_counts()})

    Enum.reduce(events, base, fn event, acc ->
      source = source_name(value(event, :side_effect_source)) |> String.to_atom()
      status = normalize_status(value(event, :status)) |> String.to_atom()

      Map.update(acc, source, Map.update(status_zero_counts(), status, 1, &(&1 + 1)), fn counts ->
        Map.update(counts, status, 1, &(&1 + 1))
      end)
    end)
  end

  defp guard_decision_counts(existing, _events) when is_map(existing) and map_size(existing) > 0 do
    SafeSummary.sanitize_map(existing, output_keys: :preserve)
  end

  defp guard_decision_counts(_existing, events) do
    base = Map.new(@guard_decisions, &{String.to_atom(&1), 0})

    Enum.reduce(events, base, fn event, acc ->
      decision = guard_decision(value(event, :authorization_consumption_guard)) |> String.to_atom()
      Map.update(acc, decision, 1, &(&1 + 1))
    end)
  end

  defp status_zero_counts, do: Map.new(@statuses, &{String.to_atom(&1), 0})

  defp outcome_list(existing, events, predicate) do
    case list_value(%{items: existing}, :items) do
      [] ->
        events
        |> Enum.filter(predicate)
        |> Enum.take(@default_recent_limit)

      values ->
        values
        |> Enum.map(&fact_snapshot/1)
        |> Enum.take(@default_recent_limit)
    end
  end

  defp unresolved_outcomes(events) do
    events
    |> Enum.filter(&unresolved?/1)
    |> Enum.take(@default_recent_limit)
  end

  defp terminal_outcomes(events) do
    events
    |> Enum.filter(&terminal?/1)
    |> Enum.take(@default_recent_limit)
  end

  defp all_no_side_effects?(events) do
    Enum.all?(events, &(value(&1, :no_side_effects) == true))
  end

  defp unresolved?(event), do: unresolved_status?(value(event, :status))
  defp terminal?(event), do: terminal_status?(value(event, :status))
  defp unresolved_status?(status), do: normalize_status(status) in @unresolved_statuses
  defp terminal_status?(status), do: normalize_status(status) in @terminal_statuses

  defp overall_status([]), do: "no_outcome"

  defp overall_status(events) do
    cond do
      Enum.any?(events, &(&1.status == "malformed")) -> "malformed"
      Enum.any?(events, &(&1.status == "manual_attention")) -> "manual_attention"
      Enum.any?(events, &(&1.status == "unknown")) -> "unknown"
      Enum.any?(events, &(&1.status == "retryable")) -> "retryable"
      Enum.any?(events, &(&1.status == "failed")) -> "failed"
      Enum.any?(events, &(&1.status == "blocked")) -> "blocked"
      Enum.any?(events, &(&1.status == "succeeded")) -> "succeeded"
      true -> "not_executed"
    end
  end

  defp normalize_overall_status(status, events) do
    status = safe_status(status)
    allowed = ["no_outcome" | @statuses]

    if status in allowed do
      status
    else
      overall_status(events)
    end
  end

  defp project_status([]), do: "no_outcome"
  defp project_status(outcomes), do: overall_status(outcomes)

  defp normalize_project_status(status, outcomes) do
    status = safe_status(status)
    allowed = ["no_outcome" | @statuses]

    if status in allowed do
      status
    else
      project_status(outcomes)
    end
  end

  defp same_attempt?(left, right) do
    fact_snapshot(left).replay_key == fact_snapshot(right).replay_key
  end

  defp dedupe_facts(events) do
    events
    |> Enum.reduce(%{}, fn event, acc ->
      key = event.replay_key

      Map.update(acc, key, event, fn existing ->
        if outcome_rank(event) >= outcome_rank(existing), do: event, else: existing
      end)
    end)
    |> Map.values()
  end

  defp outcome_rank(%{status: "manual_attention"}), do: 90
  defp outcome_rank(%{status: "unknown"}), do: 80
  defp outcome_rank(%{status: "succeeded"}), do: 70
  defp outcome_rank(%{status: "retryable"}), do: 60
  defp outcome_rank(%{status: "failed"}), do: 50
  defp outcome_rank(%{status: "malformed"}), do: 45
  defp outcome_rank(%{status: "unsupported"}), do: 40
  defp outcome_rank(%{status: "blocked"}), do: 30
  defp outcome_rank(%{status: "not_executed"}), do: 20
  defp outcome_rank(_event), do: 0

  defp replay_side_effect_class(fact) do
    if value(fact, :side_effect_entered) == true or value(fact, :side_effect_may_have_happened) == true do
      "entered"
    else
      "not_entered"
    end
  end

  defp replay_key(fact) do
    Enum.map_join(
      [
        optional_string(fact, :project_id),
        operation_name(value(fact, :operation)),
        source_name(value(fact, :side_effect_source)),
        optional_string(fact, :authorization_record_fingerprint),
        optional_string(fact, :authorization_request_fingerprint),
        optional_string(fact, :cutover_operation_request_fingerprint),
        optional_string(fact, :readiness_permit_fingerprint),
        optional_string(fact, :cutover_gate_fingerprint),
        optional_string(fact, :evidence_fingerprint),
        replay_side_effect_class(fact)
      ],
      "|",
      &(&1 || "none")
    )
  end

  defp attempt_fingerprint(fact) do
    %{
      project_id: optional_string(fact, :project_id),
      provider_scope: value(fact, :provider_scope),
      operation: operation_name(value(fact, :operation)),
      side_effect_source: source_name(value(fact, :side_effect_source)),
      authorization_record_fingerprint: optional_string(fact, :authorization_record_fingerprint),
      authorization_request_fingerprint: optional_string(fact, :authorization_request_fingerprint),
      cutover_operation_request_fingerprint: optional_string(fact, :cutover_operation_request_fingerprint),
      readiness_permit_fingerprint: optional_string(fact, :readiness_permit_fingerprint),
      cutover_gate_fingerprint: optional_string(fact, :cutover_gate_fingerprint),
      dry_run_audit_fingerprint: optional_string(fact, :dry_run_audit_fingerprint),
      audit_history_fingerprint: optional_string(fact, :audit_history_fingerprint),
      evidence_fingerprint: optional_string(fact, :evidence_fingerprint)
    }
    |> fingerprint()
  end

  defp outcome_id(fact), do: "hub-cutover-execution-outcome:" <> fingerprint(Map.take(fact, [:attempt_fingerprint, :status, :reason_code, :completed_at]))

  defp project_fingerprints(outcomes) do
    outcomes
    |> Enum.flat_map(fn outcome -> Map.to_list(value(outcome, :safe_evidence_fingerprints) || %{}) end)
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Enum.uniq_by(fn {key, _value} -> key end)
    |> Map.new()
    |> SafeSummary.sanitize_map(output_keys: :preserve)
  end

  defp stable_evidence_fingerprint(project_id, _provider_scope, operation, source, evidence) do
    evidence
    |> Map.take([
      :authorization_record,
      :authorization_request,
      :cutover_operation_request,
      :readiness_permit,
      :readiness_permit_decision,
      :cutover_gate,
      :dry_run_audit,
      :audit_history,
      :consumption_guard
    ])
    |> Map.merge(%{
      project_id: project_id,
      operation: operation,
      side_effect_source: source
    })
    |> fingerprint()
  end

  defp event_sort_key(event) do
    timestamp = value(event, :completed_at) || value(event, :generated_at) || value(event, :started_at) || ""

    {
      timestamp,
      value(event, :project_id) || "",
      value(event, :operation) || "",
      value(event, :side_effect_source) || ""
    }
  end

  defp guard_decision(nil), do: "no_consumption"

  defp guard_decision(%{decision: decision}) do
    decision = safe_status(decision)

    case decision in @guard_decisions do
      true -> decision
      false -> "malformed"
    end
  end

  defp guard_decision(_guard), do: "malformed"

  defp guard_fingerprint(guard) when is_map(guard), do: fingerprint(guard)
  defp guard_fingerprint(_guard), do: nil

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

  defp action_snapshots(actions) do
    actions
    |> List.wrap()
    |> Enum.map(&action_code/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&%{code: &1})
  end

  defp action_code(action) when is_map(action), do: safe_status(value(action, :code) || value(action, :action) || value(action, :id))
  defp action_code(action), do: safe_status(action)

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

  defp fingerprint(payload) do
    :crypto.hash(:sha256, :erlang.term_to_binary(payload))
    |> Base.encode16(case: :lower)
  end

  defp false?(false), do: true
  defp false?(_value), do: false

  defp not_false?(false), do: false
  defp not_false?(_value), do: true

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
