defmodule SymphonyElixir.Hub.CutoverAuthorizationConsumptionGuard do
  @moduledoc """
  Hub cutover execution authorization consumption guard.

  This guard is the shared pre-side-effect boundary for explicit Hub cutover
  execution paths. It consumes the read-only execution authorization ledger and
  returns a stable, sanitized decision summary for one project, operation, and
  side-effect source. It does not call providers, mutate the runtime ledger,
  start workers, write providers, operate systemd, or edit configuration.
  """

  alias SymphonyElixir.Hub.{CutoverExecutionAuthorization, SafeSummary}

  @version 1
  @operations ["poll", "dispatch", "worker_start", "writeback"]
  @sources ["candidate_scan", "dispatch_application", "worker_start_handoff", "writeback_executor"]
  @decisions ["allowed", "blocked", "no_authorization", "stale", "manual_attention", "unsupported", "malformed"]
  @blocked_record_statuses %{
    "blocked" => "blocked",
    "no_ready_permit" => "no_authorization",
    "stale" => "stale",
    "manual_attention" => "manual_attention",
    "unsupported" => "unsupported",
    "malformed" => "malformed",
    "summary_error" => "malformed"
  }
  @source_operations %{
    "candidate_scan" => "poll",
    "dispatch_application" => "dispatch",
    "worker_start_handoff" => "worker_start",
    "writeback_executor" => "writeback"
  }
  @default_recent_limit 20

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
      _error -> malformed_decision(input, now, "authorization_consumption_guard_error")
    catch
      _kind, _reason -> malformed_decision(input, now, "authorization_consumption_guard_error")
    end
  end

  def evaluate(_input, opts) when is_list(opts) do
    now = opts |> Keyword.get(:now) |> Kernel.||(DateTime.utc_now()) |> iso8601()
    malformed_decision(%{evaluated_at: now}, now, "authorization_consumption_input_malformed")
  end

  @spec require_allowed(map()) :: :ok | {:blocked, decision()}
  def require_allowed(input), do: require_allowed(input, [])

  @spec require_allowed(map(), keyword()) :: :ok | {:blocked, decision()}
  def require_allowed(input, opts) when is_list(opts) do
    decision = evaluate(input, opts)

    if decision.allowed do
      :ok
    else
      {:blocked, decision}
    end
  end

  @spec to_decision(term()) :: decision()
  def to_decision(decision), do: decision_snapshot(decision)

  @spec build(term()) :: summary()
  def build(sources), do: build(sources, [])

  @spec build(term(), keyword()) :: summary()
  def build(sources, opts) when is_list(opts) do
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
      |> Enum.reject(&drop_summary_event?/1)
      |> Enum.sort_by(&event_sort_key/1)

    %{
      version: @version,
      generated_at: now,
      status: overall_status(events),
      counts: count_snapshot(%{}, events),
      recent_decisions: Enum.take(events, @default_recent_limit),
      blocked_sources: blocked_sources(events),
      projects: project_summaries(events),
      no_side_effects: true
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

    generated_at = iso8601(value(summary, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      version: positive_integer(value(summary, :version)) || @version,
      generated_at: generated_at,
      status: normalize_overall_status(value(summary, :status), events),
      counts: count_snapshot(value(summary, :counts), events),
      recent_decisions: recent_decisions,
      blocked_sources: blocked_source_snapshots(value(summary, :blocked_sources), events),
      projects: projects,
      no_side_effects: value(summary, :no_side_effects) != false
    }
  end

  def to_snapshot(_summary), do: to_snapshot(%{})

  @spec observability_snapshot(term()) :: summary() | nil
  def observability_snapshot(nil), do: nil
  def observability_snapshot(summary) when is_map(summary), do: to_snapshot(summary)
  def observability_snapshot(_summary), do: nil

  defp safe_evaluate(input) do
    now = iso8601(value(input, :evaluated_at)) || DateTime.utc_now() |> DateTime.to_iso8601()
    project_id = optional_string(input, :project_id)
    operation = operation_name(value(input, :operation))
    source = source_name(value(input, :side_effect_source) || value(input, :source))
    provider_scope = provider_scope_snapshot(value(input, :provider_scope) || %{})
    ledger = value(input, :authorization_ledger) || value(input, :cutover_execution_authorization_ledger)

    cond do
      blank?(project_id) ->
        base_decision(input, "malformed", "project_id_missing", "fix_consumption_input_project_id", now)

      operation not in @operations ->
        base_decision(input, "unsupported", "unknown_operation", "choose_supported_operations", now)

      source not in @sources ->
        base_decision(input, "unsupported", "unsupported_side_effect_source", "use_supported_side_effect_source", now)

      Map.fetch!(@source_operations, source) != operation ->
        base_decision(input, "unsupported", "side_effect_source_operation_mismatch", "fix_consumption_operation", now)

      not is_map(ledger) ->
        base_decision(input, "no_authorization", "authorization_ledger_missing", "submit_execution_authorization_request", now)

      true ->
        evaluate_record(input, ledger, project_id, operation, source, provider_scope, now)
    end
  end

  defp evaluate_record(input, ledger, project_id, operation, source, provider_scope, now) do
    ledger = CutoverExecutionAuthorization.to_snapshot(ledger)
    project = Enum.find(list_value(ledger, :projects), &(optional_string(&1, :project_id) == project_id))
    records = list_value(project || %{}, :records)
    operation_records = Enum.filter(records, &(operation_name(value(&1, :operation)) == operation))
    matching_record = Enum.find(operation_records, &provider_scope_matches?(&1, provider_scope))

    cond do
      project == nil or records == [] ->
        base_decision(input, "no_authorization", "authorization_record_missing", "submit_execution_authorization_request", now)

      operation_records == [] ->
        base_decision(input, "no_authorization", "authorization_record_operation_missing", "submit_matching_execution_authorization_request", now)

      matching_record == nil ->
        base_decision(input, "no_authorization", "authorization_record_scope_mismatch", "submit_matching_execution_authorization_request", now)

      normalize_record_status(value(matching_record, :status)) != "authorized_for_explicit_execution" ->
        record_block_decision(input, matching_record, now)

      drift = current_drift(input, matching_record) ->
        record_decision(input, matching_record, "stale", drift, "refresh_execution_authorization_request", now)

      not mode_compatible?(
        operation,
        source,
        value(input, :execution_mode) || value(input, :mode) || value(input, :executor_modes)
      ) ->
        record_decision(input, matching_record, "blocked", "execution_mode_incompatible", "confirm_hub_executor_modes", now)

      true ->
        record_decision(input, matching_record, "allowed", "authorization_consumed", nil, now)
    end
  end

  defp current_drift(input, record) do
    current = current_fingerprints(input)
    record_request = get_in_value(record, [:cutover_operation_request, :request_fingerprint])
    record_permit = get_in_value(record, [:readiness_permit, :permit_fingerprint])
    record_permit_decision = get_in_value(record, [:readiness_permit, :decision])
    record_activation_plan = get_in_value(record, [:activation_plan, :fingerprint])
    record_acknowledgement = get_in_value(record, [:operator_acknowledgement, :fingerprint])
    record_gate = get_in_value(record, [:cutover_gate, :fingerprint])
    record_audit = get_in_value(record, [:evidence_fingerprints, :dry_run_audit])
    record_history = get_in_value(record, [:evidence_fingerprints, :audit_history])

    record_executor_modes =
      get_in_value(record, [:evidence_fingerprints, :executor_modes]) ||
        get_in_value(record, [:evidence_fingerprints, :runtime_modes])

    [
      {"cutover_operation_request_fingerprint_drift", optional_string(current, :cutover_operation_request), record_request},
      {"readiness_permit_fingerprint_drift", optional_string(current, :readiness_permit), record_permit},
      {"readiness_permit_decision_drift", safe_status(value(current, :readiness_permit_decision)), record_permit_decision},
      {"activation_plan_fingerprint_drift", optional_string(current, :activation_plan), record_activation_plan},
      {"operator_acknowledgement_fingerprint_drift", optional_string(current, :operator_acknowledgement), record_acknowledgement},
      {"cutover_gate_fingerprint_drift", optional_string(current, :cutover_gate), record_gate},
      {"dry_run_audit_fingerprint_drift", optional_string(current, :dry_run_audit), record_audit},
      {"audit_history_fingerprint_drift", optional_string(current, :audit_history), record_history},
      {"executor_mode_fingerprint_drift", explicit_current_executor_modes(input, current), record_executor_modes}
    ]
    |> Enum.find_value(fn {code, current_value, record_value} ->
      if bound?(current_value) and bound?(record_value) and current_value != record_value do
        code
      end
    end)
  end

  defp explicit_current_executor_modes(input, current) do
    fingerprints = value(input, :current_fingerprints) || value(input, :evidence_fingerprints) || %{}

    if bound?(optional_string(fingerprints, :executor_modes)) do
      optional_string(current, :executor_modes)
    end
  end

  defp current_fingerprints(input) do
    fingerprints = value(input, :current_fingerprints) || value(input, :evidence_fingerprints) || %{}
    permit = value(input, :current_readiness_permit) || value(input, :readiness_permit) || %{}
    readiness_permit_decision = safe_status(value(fingerprints, :readiness_permit_decision) || value(permit, :decision))

    runtime_modes =
      optional_string(fingerprints, :executor_modes) ||
        optional_string(fingerprints, :runtime_modes) ||
        get_in_value(permit, [:evidence_fingerprints, :runtime_modes]) ||
        get_in_value(permit, [:evidence_fingerprints, :executor_modes])

    %{
      cutover_operation_request:
        optional_string(fingerprints, :cutover_operation_request) ||
          optional_string(fingerprints, :operation_request) ||
          get_in_value(permit, [:request, :request_fingerprint]),
      readiness_permit:
        optional_string(fingerprints, :readiness_permit) ||
          optional_string(permit, :permit_fingerprint),
      readiness_permit_decision: readiness_permit_decision,
      activation_plan:
        optional_string(fingerprints, :activation_plan) ||
          get_in_value(permit, [:activation_plan, :fingerprint]),
      operator_acknowledgement:
        optional_string(fingerprints, :operator_acknowledgement) ||
          get_in_value(permit, [:operator_acknowledgement, :fingerprint]),
      cutover_gate:
        optional_string(fingerprints, :cutover_gate) ||
          get_in_value(permit, [:cutover_gate, :fingerprint]),
      dry_run_audit:
        optional_string(fingerprints, :dry_run_audit) ||
          get_in_value(permit, [:evidence_fingerprints, :dry_run_audit]),
      audit_history:
        optional_string(fingerprints, :audit_history) ||
          get_in_value(permit, [:evidence_fingerprints, :audit_history]),
      executor_modes: runtime_modes,
      runtime_modes: runtime_modes
    }
  end

  defp mode_compatible?("poll", "candidate_scan", nil), do: true

  defp mode_compatible?("poll", "candidate_scan", mode) when is_map(mode) do
    truthy?(value(mode, :provider_io)) and
      safe_status(value(mode, :mode)) in ["real_candidate_scan", "custom_module"] and
      "candidate_scan" in string_list(value(mode, :supported_operations))
  end

  defp mode_compatible?("dispatch", "dispatch_application", nil), do: true

  defp mode_compatible?("dispatch", "dispatch_application", mode) when is_map(mode) do
    value(mode, :dispatch_application) != false and
      value(mode, :dispatch_mutation) != false and
      truthy?(value(mode, :unsupported_mode)) == false
  end

  defp mode_compatible?("worker_start", "worker_start_handoff", nil), do: true

  defp mode_compatible?("worker_start", "worker_start_handoff", mode) when is_map(mode) do
    truthy?(value(mode, :worker_start)) and safe_status(value(mode, :mode)) == "real_worker_starter"
  end

  defp mode_compatible?("writeback", "writeback_executor", nil), do: true

  defp mode_compatible?("writeback", "writeback_executor", mode) when is_map(mode) do
    truthy?(value(mode, :provider_io)) and safe_status(value(mode, :mode)) == "real_writeback" and
      string_list(value(mode, :supported_operations)) != []
  end

  defp mode_compatible?(_operation, _source, _mode), do: false

  defp record_block_decision(input, record, now) do
    record_status = normalize_record_status(value(record, :status))
    decision = Map.get(@blocked_record_statuses, record_status, "blocked")
    reason = record |> list_value(:reason_codes) |> List.first() || "authorization_record_not_allowed"
    action = record |> list_value(:required_operator_actions) |> action_codes() |> List.first()
    record_decision(input, record, decision, reason, action || action_for_decision(decision), now)
  end

  defp base_decision(input, decision, reason, action, now) do
    safe_evidence_fingerprints =
      SafeSummary.sanitize_map(value(input, :current_fingerprints) || %{}, output_keys: :preserve)

    %{
      version: @version,
      project_id: optional_string(input, :project_id),
      operation: operation_name(value(input, :operation)),
      side_effect_source: source_name(value(input, :side_effect_source) || value(input, :source)),
      provider_scope: provider_scope_snapshot(value(input, :provider_scope) || %{}),
      decision: decision,
      allowed: false,
      reason_code: reason,
      action_code: action,
      reason_codes: [reason],
      required_operator_actions: action_snapshots([action]),
      safe_evidence_fingerprints: safe_evidence_fingerprints,
      evaluated_at: now,
      no_side_effects: true
    }
  end

  defp record_decision(input, record, decision, reason, action, now) do
    allowed = decision == "allowed"
    record_fingerprint = optional_string(record, :authorization_record_fingerprint)
    request_fingerprint = get_in_value(record, [:authorization_request, :authorization_request_fingerprint])

    reason_codes =
      ([reason] ++ string_list(value(record, :reason_codes)))
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.sort()

    action_codes =
      ([action] ++ action_codes(value(record, :required_operator_actions)))
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      version: @version,
      project_id: optional_string(input, :project_id) || optional_string(record, :project_id),
      operation: operation_name(value(input, :operation) || value(record, :operation)),
      side_effect_source: source_name(value(input, :side_effect_source) || value(input, :source)),
      provider_scope: provider_scope_snapshot(value(input, :provider_scope) || value(record, :provider_scope) || %{}),
      decision: decision,
      allowed: allowed,
      reason_code: reason,
      action_code: action,
      reason_codes: reason_codes,
      required_operator_actions: action_snapshots(action_codes),
      authorization_record_fingerprint: record_fingerprint,
      authorization_request_fingerprint: request_fingerprint,
      authorization_record_status: normalize_record_status(value(record, :status)),
      safe_evidence_fingerprints: safe_evidence_fingerprints(record),
      evaluated_at: now,
      no_side_effects: true
    }
  end

  defp malformed_decision(input, now, reason) do
    input
    |> base_decision("malformed", reason, "fix_authorization_consumption_input", now)
    |> decision_snapshot()
  end

  defp safe_evidence_fingerprints(record) do
    %{
      authorization_record: optional_string(record, :authorization_record_fingerprint),
      authorization_request: get_in_value(record, [:authorization_request, :authorization_request_fingerprint]),
      cutover_operation_request: get_in_value(record, [:cutover_operation_request, :request_fingerprint]),
      readiness_permit: get_in_value(record, [:readiness_permit, :permit_fingerprint]),
      readiness_permit_decision: get_in_value(record, [:readiness_permit, :decision]),
      activation_plan: get_in_value(record, [:activation_plan, :fingerprint]),
      operator_acknowledgement: get_in_value(record, [:operator_acknowledgement, :fingerprint]),
      cutover_gate: get_in_value(record, [:cutover_gate, :fingerprint]),
      dry_run_audit: get_in_value(record, [:evidence_fingerprints, :dry_run_audit]),
      audit_history: get_in_value(record, [:evidence_fingerprints, :audit_history]),
      executor_modes: get_in_value(record, [:evidence_fingerprints, :executor_modes])
    }
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
    |> SafeSummary.sanitize_map(output_keys: :preserve)
  end

  defp decision_snapshot(decision) when is_map(decision) do
    decision_name = normalize_decision(value(decision, :decision))
    allowed = value(decision, :allowed) == true and decision_name == "allowed"
    reason_code = safe_status(value(decision, :reason_code)) |> blank_to_default(default_reason(decision_name))
    action_code = safe_status(value(decision, :action_code)) |> blank_to_nil()

    %{
      version: positive_integer(value(decision, :version)) || @version,
      project_id: optional_string(decision, :project_id),
      operation: operation_name(value(decision, :operation)),
      side_effect_source: source_name(value(decision, :side_effect_source) || value(decision, :source)),
      provider_scope: provider_scope_snapshot(value(decision, :provider_scope) || %{}),
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
      authorization_record_fingerprint: optional_string(decision, :authorization_record_fingerprint),
      authorization_request_fingerprint: optional_string(decision, :authorization_request_fingerprint),
      authorization_record_status: safe_status(value(decision, :authorization_record_status)) |> blank_to_nil(),
      safe_evidence_fingerprints:
        SafeSummary.sanitize_map(value(decision, :safe_evidence_fingerprints) || %{},
          output_keys: :preserve
        ),
      evaluated_at: iso8601(value(decision, :evaluated_at)),
      no_side_effects: value(decision, :no_side_effects) != false
    }
    |> compact_map()
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
      blocked_sources: blocked_source_snapshots(value(project, :blocked_sources), decisions),
      safe_evidence_fingerprints: project_fingerprints(decisions),
      no_side_effects: value(project, :no_side_effects) != false
    }
  end

  defp project_snapshot(project), do: project_snapshot(%{project_id: project})

  defp project_summaries(events) do
    events
    |> Enum.reject(&(optional_string(&1, :project_id) |> blank?()))
    |> Enum.group_by(& &1.project_id)
    |> Enum.map(fn {project_id, decisions} ->
      %{
        project_id: project_id,
        status: project_status(decisions),
        counts: count_snapshot(%{}, decisions),
        recent_decisions: Enum.take(decisions, @default_recent_limit),
        blocked_sources: blocked_sources(decisions),
        safe_evidence_fingerprints: project_fingerprints(decisions),
        no_side_effects: true
      }
      |> project_snapshot()
    end)
  end

  defp count_snapshot(counts, events) when is_map(counts) do
    %{
      consumption_count: non_negative_integer(value(counts, :consumption_count)) || length(events),
      allowed_count: count_or_existing(counts, :allowed_count, events, "allowed"),
      blocked_count: count_or_existing(counts, :blocked_count, events, "blocked"),
      no_authorization_count: count_or_existing(counts, :no_authorization_count, events, "no_authorization"),
      stale_count: count_or_existing(counts, :stale_count, events, "stale"),
      manual_attention_count: count_or_existing(counts, :manual_attention_count, events, "manual_attention"),
      unsupported_count: count_or_existing(counts, :unsupported_count, events, "unsupported"),
      malformed_count: count_or_existing(counts, :malformed_count, events, "malformed"),
      operation_decision_counts: operation_decision_counts(value(counts, :operation_decision_counts), events),
      source_decision_counts: source_decision_counts(value(counts, :source_decision_counts), events)
    }
  end

  defp count_snapshot(_counts, events), do: count_snapshot(%{}, events)

  defp count_or_existing(counts, key, events, decision) do
    non_negative_integer(value(counts, key)) || Enum.count(events, &(&1.decision == decision))
  end

  defp operation_decision_counts(existing, _events) when is_map(existing) and map_size(existing) > 0 do
    SafeSummary.sanitize_map(existing, output_keys: :preserve)
  end

  defp operation_decision_counts(_existing, events) do
    base = Map.new(@operations, &{String.to_atom(&1), decision_zero_counts()})

    Enum.reduce(events, base, fn event, acc ->
      operation = operation_name(value(event, :operation)) |> String.to_atom()
      decision = normalize_decision(value(event, :decision)) |> String.to_atom()

      Map.update(acc, operation, Map.update(decision_zero_counts(), decision, 1, &(&1 + 1)), fn counts ->
        Map.update(counts, decision, 1, &(&1 + 1))
      end)
    end)
  end

  defp source_decision_counts(existing, _events) when is_map(existing) and map_size(existing) > 0 do
    SafeSummary.sanitize_map(existing, output_keys: :preserve)
  end

  defp source_decision_counts(_existing, events) do
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

  defp blocked_sources(events) do
    events
    |> Enum.reject(& &1.allowed)
    |> Enum.map(&blocked_source_snapshot/1)
    |> Enum.take(@default_recent_limit)
  end

  defp blocked_source_snapshots(blocked_sources, events) do
    case list_value(%{blocked_sources: blocked_sources}, :blocked_sources) do
      [] -> blocked_sources(events)
      values -> values |> Enum.map(&blocked_source_snapshot/1) |> Enum.take(@default_recent_limit)
    end
  end

  defp blocked_source_snapshot(event) when is_map(event) do
    %{
      project_id: optional_string(event, :project_id),
      operation: operation_name(value(event, :operation)),
      side_effect_source: source_name(value(event, :side_effect_source) || value(event, :source)),
      decision: normalize_decision(value(event, :decision)),
      reason_code:
        safe_status(value(event, :reason_code))
        |> blank_to_default(default_reason(normalize_decision(value(event, :decision)))),
      action_code: safe_status(value(event, :action_code)) |> blank_to_nil(),
      authorization_record_fingerprint: optional_string(event, :authorization_record_fingerprint),
      safe_evidence_fingerprints:
        SafeSummary.sanitize_map(value(event, :safe_evidence_fingerprints) || %{},
          output_keys: :preserve
        )
    }
    |> compact_map()
  end

  defp blocked_source_snapshot(event), do: blocked_source_snapshot(%{decision: event})

  defp events_from_sources(sources) do
    direct_events =
      list_value(sources, :authorization_consumptions) ++
        list_value(sources, :consumptions) ++
        list_value(sources, :events)

    direct_events ++
      tick_events(value(sources, :tick) || value(sources, :poll_tick)) ++
      dispatch_events(value(sources, :dispatch_plan_application) || value(sources, :hub_dispatch_plan_application)) ++
      worker_start_events(value(sources, :worker_start_handoff) || value(sources, :hub_worker_start_handoff)) ++
      provider_queue_events(value(sources, :provider_queue))
  end

  defp tick_events(tick) do
    tick
    |> list_value(:results)
    |> Enum.map(&value(&1, :authorization_consumption))
    |> Enum.filter(&is_map/1)
  end

  defp dispatch_events(dispatch_plan_application) do
    dispatch_plan_application
    |> list_value(:projects)
    |> Enum.flat_map(&list_value(&1, :outcomes))
    |> Enum.map(&value(&1, :authorization_consumption))
    |> Enum.filter(&is_map/1)
  end

  defp worker_start_events(worker_start_handoff) do
    worker_start_handoff
    |> list_value(:results)
    |> Enum.map(&value(&1, :authorization_consumption))
    |> Enum.filter(&is_map/1)
  end

  defp provider_queue_events(provider_queue) do
    provider_queue
    |> value(:recent_results)
    |> List.wrap()
    |> Enum.map(&(get_in_value(&1, [:result_summary, :authorization_consumption]) || get_in_value(&1, [:result_summary, "authorization_consumption"])))
    |> Enum.filter(&is_map/1)
  end

  defp overall_status([]), do: "no_consumption"

  defp overall_status(events) do
    cond do
      Enum.any?(events, &(&1.decision == "malformed")) -> "malformed"
      Enum.any?(events, &(&1.decision == "unsupported")) -> "unsupported"
      Enum.any?(events, &(&1.decision == "manual_attention")) -> "manual_attention"
      Enum.any?(events, &(&1.decision == "stale")) -> "stale"
      Enum.any?(events, &(&1.decision == "blocked")) -> "blocked"
      Enum.any?(events, &(&1.decision == "no_authorization")) -> "no_authorization"
      Enum.any?(events, &(&1.decision == "allowed")) -> "allowed"
      true -> "no_consumption"
    end
  end

  defp project_status(events), do: overall_status(events)

  defp normalize_overall_status(status, events) do
    status = safe_status(status)
    if status in ["no_consumption" | @decisions], do: status, else: overall_status(events)
  end

  defp normalize_project_status(status, events) do
    status = safe_status(status)
    if status in ["no_consumption" | @decisions], do: status, else: project_status(events)
  end

  defp provider_scope_matches?(_record, scope) when scope in [%{}, nil], do: true

  defp provider_scope_matches?(record, scope) do
    record_scope = provider_scope_snapshot(value(record, :provider_scope) || %{})
    scope = provider_scope_snapshot(scope)

    cond do
      scope == %{} ->
        true

      record_scope == %{} ->
        false

      optional_string(record_scope, :provider_scope_key) != nil and
          optional_string(scope, :provider_scope_key) != nil ->
        optional_string(record_scope, :provider_scope_key) == optional_string(scope, :provider_scope_key)

      true ->
        record_scope == scope
    end
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
      source_name(value(event, :side_effect_source))
    }
  end

  defp drop_summary_event?(event) do
    blank?(value(event, :project_id)) and normalize_decision(value(event, :decision)) != "malformed"
  end

  defp action_for_decision("allowed"), do: nil
  defp action_for_decision("no_authorization"), do: "submit_execution_authorization_request"
  defp action_for_decision("stale"), do: "refresh_execution_authorization_request"
  defp action_for_decision("manual_attention"), do: "resolve_manual_attention"
  defp action_for_decision("unsupported"), do: "choose_supported_operations"
  defp action_for_decision("malformed"), do: "fix_authorization_consumption_input"
  defp action_for_decision(_decision), do: "resolve_authorization_consumption_block"

  defp default_reason("allowed"), do: "authorization_consumed"
  defp default_reason("no_authorization"), do: "authorization_record_missing"
  defp default_reason("stale"), do: "authorization_evidence_stale"
  defp default_reason("manual_attention"), do: "authorization_manual_attention"
  defp default_reason("unsupported"), do: "authorization_consumption_unsupported"
  defp default_reason("malformed"), do: "authorization_consumption_malformed"
  defp default_reason(_decision), do: "authorization_consumption_blocked"

  defp normalize_decision(decision) do
    decision = safe_status(decision)
    if decision in @decisions, do: decision, else: "blocked"
  end

  defp normalize_record_status(status) do
    status = safe_status(status)

    if status in ["authorized_for_explicit_execution", "blocked", "no_ready_permit", "stale", "manual_attention", "unsupported", "malformed", "summary_error"] do
      status
    else
      "blocked"
    end
  end

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

  defp provider_scope_snapshot(scope) when is_map(scope) do
    %{
      kind: optional_string(scope, :kind) || optional_string(scope, :provider_kind),
      provider_scope_key: optional_string(scope, :provider_scope_key) || optional_string(scope, :key),
      key: optional_string(scope, :key) || optional_string(scope, :provider_scope_key),
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

  defp safe_status(nil), do: ""
  defp safe_status(value) when is_atom(value), do: value |> Atom.to_string() |> String.replace("-", "_")
  defp safe_status(value) when is_binary(value), do: value |> String.trim() |> String.replace("-", "_")
  defp safe_status(value), do: value |> to_string() |> String.trim() |> String.replace("-", "_")

  defp string_list(values) when is_list(values) do
    values |> Enum.map(&safe_status/1) |> Enum.reject(&blank?/1)
  end

  defp string_list(value), do: string_list(List.wrap(value))

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

  defp optional_string(map, key) do
    case value(map, key) do
      nil ->
        nil

      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_atom(value) ->
        Atom.to_string(value)

      value when is_integer(value) ->
        Integer.to_string(value)

      _value ->
        nil
    end
  end

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

  defp truthy?(value), do: value in [true, "true", "1", 1, true]
  defp bound?(value), do: not blank?(value)
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(%{}), do: true
  defp blank?(_value), do: false
  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: value)
  defp blank_to_default(value, default), do: if(blank?(value), do: default, else: value)

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end
end
