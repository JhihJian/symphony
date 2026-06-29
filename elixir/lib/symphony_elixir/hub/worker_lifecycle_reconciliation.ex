defmodule SymphonyElixir.Hub.WorkerLifecycleReconciliation do
  @moduledoc """
  Model-only Hub worker lifecycle reconciliation boundary.

  This boundary starts after worker start acknowledgement. It consumes safe,
  controlled worker/session lifecycle summaries from an injectable result
  source and applies recoverable facts back into the runtime ledger. It does
  not read raw provider payloads, supervise workers, write providers, or replace
  the legacy single-project runtime path.
  """

  alias SymphonyElixir.Hub.{DispatchBoundary, RuntimeLedger, SafeSummary}

  @version 1
  @result_statuses ["running", "succeeded", "failed", "cancelled", "timeout", "stopped", "lost", "unknown", "manual_attention", "skipped"]
  @terminal_statuses ["succeeded", "failed", "cancelled", "timeout", "stopped"]
  @unresolved_statuses ["lost", "unknown", "manual_attention"]

  @type result_source :: module() | function() | nil
  @type summary :: map()

  @spec empty(map(), keyword()) :: summary()
  def empty(registry, opts \\ []) when is_map(registry) and is_list(opts) do
    ledger = opts |> Keyword.get(:runtime_ledger, RuntimeLedger.new()) |> RuntimeLedger.to_snapshot()
    now = normalize_datetime(Keyword.get(opts, :now)) || DateTime.utc_now()
    replay = RuntimeLedger.replay(ledger)

    %{
      version: @version,
      generated_at: iso8601(now),
      status: "idle",
      counts: counts([], replay),
      reason_counts: %{},
      workspace_action_counts: %{},
      results: [],
      running_attempts: running_attempts(replay),
      runtime_ledger_replay: replay,
      safety: safety_summary()
    }
    |> to_snapshot()
  end

  @spec run(map(), map(), keyword()) :: {RuntimeLedger.ledger(), summary()}
  def run(registry, runtime_ledger, opts \\ []) when is_map(registry) and is_map(runtime_ledger) and is_list(opts) do
    now = normalize_datetime(Keyword.get(opts, :now)) || DateTime.utc_now()
    now_iso = iso8601(now)
    source = Keyword.get(opts, :result_source)
    initial_ledger = RuntimeLedger.to_snapshot(runtime_ledger)
    initial_replay = RuntimeLedger.replay(initial_ledger)
    requests = lifecycle_requests(initial_replay)

    {results, ledger, changed?} =
      execute_result_source(source, requests, now)
      |> normalize_source_results(requests)
      |> Enum.reduce({[], initial_ledger, false}, fn source_result, {results, ledger, changed?} ->
        {result, ledger, result_changed?} = process_result(source_result, ledger, now)
        {[result | results], ledger, changed? or result_changed?}
      end)

    ledger =
      if changed? do
        touch_ledger(ledger, now_iso)
      else
        RuntimeLedger.to_snapshot(ledger)
      end

    replay = RuntimeLedger.replay(ledger)

    %{
      version: @version,
      generated_at: now_iso,
      status: "completed",
      counts: counts(results, replay),
      reason_counts: reason_counts(results),
      workspace_action_counts: workspace_action_counts(results),
      results: Enum.reverse(results),
      running_attempts: running_attempts(replay),
      runtime_ledger_replay: replay,
      safety: safety_summary()
    }
    |> to_snapshot()
    |> then(&{ledger, &1})
  end

  @spec to_snapshot(term()) :: summary()
  def to_snapshot(summary) when is_map(summary) do
    replay = runtime_ledger_replay_snapshot(value(summary, :runtime_ledger_replay))
    results = summary |> list_value(:results) |> Enum.map(&result_snapshot/1)

    %{
      version: positive_integer(value(summary, :version)) || @version,
      generated_at: iso8601(value(summary, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601(),
      status: safe_status(value(summary, :status)) || "idle",
      counts: count_snapshot(value(summary, :counts), results, replay),
      reason_counts: reason_count_snapshot(value(summary, :reason_counts)),
      workspace_action_counts: reason_count_snapshot(value(summary, :workspace_action_counts)),
      results:
        Enum.sort_by(
          results,
          &{
            &1.project_id || "",
            &1.issue_key || "",
            &1.attempt_id || "",
            &1.start_intent_id || "",
            &1.status || ""
          }
        ),
      running_attempts:
        summary
        |> list_value(:running_attempts)
        |> Enum.map(&running_attempt_snapshot/1)
        |> Enum.sort_by(&{&1.project_id || "", &1.issue_key || "", &1.attempt_id || ""}),
      runtime_ledger_replay: replay,
      safety: safety_snapshot(value(summary, :safety))
    }
  end

  def to_snapshot(_summary), do: to_snapshot(%{})

  @spec observability_snapshot(term()) :: summary() | nil
  def observability_snapshot(nil), do: nil
  def observability_snapshot(summary) when is_map(summary), do: to_snapshot(summary)
  def observability_snapshot(_summary), do: nil

  @spec tick_summary(term()) :: map()
  def tick_summary(summary) when is_map(summary) do
    snapshot = to_snapshot(summary)

    %{
      selected_count: snapshot.counts.selected_count,
      applied_count: snapshot.counts.applied_count,
      running_count: snapshot.counts.running_count,
      succeeded_count: snapshot.counts.succeeded_count,
      failed_count: snapshot.counts.failed_count,
      cancelled_count: snapshot.counts.cancelled_count,
      timeout_count: snapshot.counts.timeout_count,
      stopped_count: snapshot.counts.stopped_count,
      lost_count: snapshot.counts.lost_count,
      unknown_count: snapshot.counts.unknown_count,
      manual_attention_count: snapshot.counts.manual_attention_count,
      skipped_count: snapshot.counts.skipped_count,
      unresolved_count: snapshot.counts.unresolved_count,
      retained_workspace_count: snapshot.counts.retained_workspace_count,
      released_workspace_count: snapshot.counts.released_workspace_count,
      reason_counts: snapshot.reason_counts,
      workspace_action_counts: snapshot.workspace_action_counts
    }
  end

  def tick_summary(_summary), do: tick_summary(%{})

  defp lifecycle_requests(replay) do
    replay
    |> list_value(:projects)
    |> Enum.flat_map(fn project ->
      project_id = optional_string(project, :project_id)

      project
      |> list_value(:active_attempts)
      |> Enum.filter(&(safe_status(value(&1, :start_intent_status)) == "acknowledged"))
      |> Enum.map(&request_snapshot(Map.put(&1, :project_id, project_id)))
    end)
  end

  defp execute_result_source(nil, _requests, _now), do: []

  defp execute_result_source(source, requests, now) when is_function(source, 2) do
    source.(requests, now: now)
  end

  defp execute_result_source(source, requests, now) when is_atom(source) do
    source.results(requests, now: now)
  end

  defp execute_result_source(_source, _requests, _now), do: []

  defp normalize_source_results({:ok, results}, requests), do: normalize_source_results(results, requests)
  defp normalize_source_results({:error, reason}, _requests), do: [%{status: "skipped", reason: "result_source_error", error_summary: safe_error(reason)}]
  defp normalize_source_results(nil, _requests), do: []
  defp normalize_source_results(results, _requests) when is_list(results), do: Enum.map(results, &normalize_source_result/1)
  defp normalize_source_results(result, _requests) when is_map(result), do: [normalize_source_result(result)]
  defp normalize_source_results(_result, _requests), do: [%{status: "skipped", reason: "invalid_result_source_payload"}]

  defp normalize_source_result(result) when is_map(result) do
    status =
      normalize_status(value(result, :status) || value(result, :result_status) || value(result, :outcome))

    status = if status in @result_statuses, do: status, else: "unknown"

    result
    |> safe_preserved_map()
    |> Map.put(:status, status)
    |> maybe_put(:reason, safe_status(value(result, :reason) || value(result, :compact_reason)))
    |> maybe_put(:error_summary, safe_optional_string(value(result, :error_summary) || value(result, :message)))
    |> maybe_put(:result_id, optional_string(result, :result_id))
    |> maybe_put(:project_id, optional_string(result, :project_id))
    |> maybe_put(:issue_key, optional_string(result, :issue_key))
    |> maybe_put(:attempt_id, optional_string(result, :attempt_id))
    |> maybe_put(:start_intent_id, optional_string(result, :start_intent_id))
    |> maybe_put(
      :workspace_lease_id,
      optional_string(result, :workspace_lease_id) || optional_string(result, :lease_id)
    )
    |> maybe_put(:workspace_path, optional_string(result, :workspace_path))
    |> maybe_put(:session_id, optional_string(result, :session_id))
    |> maybe_put(:worker_host, optional_string(result, :worker_host))
    |> maybe_put(:worker_identity, safe_preserved_map(value(result, :worker_identity) || %{}))
    |> maybe_put(:started_at, iso8601(value(result, :started_at)))
    |> maybe_put(:last_activity_at, iso8601(value(result, :last_activity_at)))
    |> maybe_put(:finished_at, iso8601(value(result, :finished_at)))
    |> maybe_put(:exit_status, safe_optional_string(value(result, :exit_status)))
    |> maybe_put(:exit_category, safe_status(value(result, :exit_category)))
    |> maybe_put(
      :recovery_status,
      normalize_recovery_status(
        value(result, :recovery_status) ||
          value(result, :failure_status) ||
          value(result, :next_status)
      )
    )
    |> maybe_put(:due_at, iso8601(value(result, :due_at)))
    |> maybe_put(:source, safe_status(value(result, :source)))
    |> maybe_put(
      :source_correlation,
      safe_preserved_map(value(result, :source_correlation) || value(result, :correlation) || %{})
    )
    |> maybe_put(:workspace_retained_reason, safe_status(value(result, :workspace_retained_reason)))
    |> maybe_put(:manual_attention, value(result, :manual_attention) == true)
  end

  defp normalize_source_result(_result), do: %{status: "skipped", reason: "invalid_lifecycle_result"}

  defp process_result(%{status: "skipped"} = source_result, ledger, _now) do
    {result_snapshot(Map.put(source_result, :ledger_changed, false)), ledger, false}
  end

  defp process_result(source_result, ledger, now) do
    result = result_snapshot(Map.put(source_result, :ledger_changed, false))
    previous_ledger = RuntimeLedger.to_snapshot(ledger)

    case DispatchBoundary.record_worker_lifecycle(previous_ledger, lifecycle_apply_payload(result), now: now) do
      {:ok, next_ledger} ->
        ledger_changed? = next_ledger != previous_ledger
        {result_snapshot(Map.put(result, :ledger_changed, ledger_changed?)), next_ledger, ledger_changed?}

      {:error, reason} ->
        skipped =
          result
          |> Map.put(:status, "skipped")
          |> Map.put(:reason, "ledger_apply_error")
          |> Map.put(:error_summary, safe_error(reason))
          |> Map.put(:ledger_changed, false)

        {result_snapshot(skipped), ledger, false}
    end
  end

  defp lifecycle_apply_payload(result) do
    result
    |> Map.take([
      :result_id,
      :project_id,
      :issue_key,
      :attempt_id,
      :start_intent_id,
      :workspace_lease_id,
      :workspace_path,
      :session_id,
      :worker_host,
      :worker_identity,
      :status,
      :recovery_status,
      :reason,
      :source,
      :source_correlation,
      :started_at,
      :last_activity_at,
      :finished_at,
      :exit_status,
      :exit_category,
      :due_at,
      :workspace_retained_reason,
      :manual_attention
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp result_snapshot(result) when is_map(result) do
    status = normalize_status(value(result, :status)) || "unknown"

    %{
      status: status,
      reason: safe_status(value(result, :reason)) || default_reason(status),
      error_summary: safe_optional_string(value(result, :error_summary)),
      result_id: optional_string(result, :result_id),
      project_id: optional_string(result, :project_id),
      issue_key: optional_string(result, :issue_key),
      attempt_id: optional_string(result, :attempt_id),
      start_intent_id: optional_string(result, :start_intent_id),
      workspace_lease_id: optional_string(result, :workspace_lease_id),
      workspace_path: optional_string(result, :workspace_path),
      session_id: optional_string(result, :session_id),
      worker_host: optional_string(result, :worker_host),
      worker_identity: safe_preserved_map(value(result, :worker_identity) || %{}),
      started_at: iso8601(value(result, :started_at)),
      last_activity_at: iso8601(value(result, :last_activity_at)),
      finished_at: iso8601(value(result, :finished_at)),
      exit_status: safe_optional_string(value(result, :exit_status)),
      exit_category: safe_status(value(result, :exit_category)),
      recovery_status: normalize_recovery_status(value(result, :recovery_status)),
      due_at: iso8601(value(result, :due_at)),
      source: safe_status(value(result, :source)),
      source_correlation: safe_preserved_map(value(result, :source_correlation) || %{}),
      terminal: status in @terminal_statuses,
      manual_attention: status == "manual_attention" or value(result, :manual_attention) == true,
      workspace_action: workspace_action(status, normalize_recovery_status(value(result, :recovery_status))),
      workspace_retained_reason: safe_status(value(result, :workspace_retained_reason)),
      ledger_changed: value(result, :ledger_changed) == true,
      safety: safety_summary()
    }
  end

  defp result_snapshot(_result), do: result_snapshot(%{})

  defp request_snapshot(request) when is_map(request) do
    %{
      project_id: optional_string(request, :project_id),
      issue_key: optional_string(request, :issue_key),
      attempt_id: optional_string(request, :attempt_id),
      attempt_number: non_negative_integer(value(request, :attempt_number)),
      status: safe_status(value(request, :status)),
      start_intent_id: optional_string(request, :start_intent_id),
      start_intent_status: safe_status(value(request, :start_intent_status)),
      workspace_lease_id: optional_string(request, :workspace_lease_id),
      workspace_path: optional_string(request, :workspace_path),
      worker_host: optional_string(request, :worker_host),
      run_context: compact_runtime_context(value(request, :run_context) || %{})
    }
  end

  defp running_attempt_snapshot(attempt) when is_map(attempt), do: request_snapshot(attempt)
  defp running_attempt_snapshot(_attempt), do: request_snapshot(%{})

  defp runtime_ledger_replay_snapshot(%{projects: projects} = replay) when is_list(projects) do
    %{
      version: positive_integer(value(replay, :version)) || 1,
      generated_at: iso8601(value(replay, :generated_at)),
      updated_at: iso8601(value(replay, :updated_at)),
      projects: Enum.map(projects, &runtime_ledger_project_snapshot/1),
      conflicts: replay |> list_value(:conflicts) |> Enum.map(&safe_preserved_map/1),
      manual_attention: replay |> list_value(:manual_attention) |> Enum.map(&safe_preserved_map/1)
    }
  end

  defp runtime_ledger_replay_snapshot(_replay), do: RuntimeLedger.replay(RuntimeLedger.new())

  defp runtime_ledger_project_snapshot(project) when is_map(project) do
    %{
      project_id: optional_string(project, :project_id),
      config_fingerprint: optional_string(project, :config_fingerprint),
      snapshot_version: optional_string(project, :snapshot_version),
      counts: safe_preserved_map(value(project, :counts) || %{}),
      active_attempts: project |> list_value(:active_attempts) |> Enum.map(&safe_preserved_map/1),
      pending_start_intents: project |> list_value(:pending_start_intents) |> Enum.map(&safe_preserved_map/1),
      workspace_leases: project |> list_value(:workspace_leases) |> Enum.map(&safe_preserved_map/1),
      retry_backoff: project |> list_value(:retry_backoff) |> Enum.map(&safe_preserved_map/1),
      blocked_candidates: project |> list_value(:blocked_candidates) |> Enum.map(&safe_preserved_map/1),
      lifecycle: safe_preserved_map(value(project, :lifecycle) || %{}),
      writebacks: safe_preserved_map(value(project, :writebacks) || %{}),
      active_issues: project |> list_value(:active_issues) |> Enum.map(&safe_preserved_map/1),
      conflicts: project |> list_value(:conflicts) |> Enum.map(&safe_preserved_map/1),
      manual_attention: project |> list_value(:manual_attention) |> Enum.map(&safe_preserved_map/1)
    }
  end

  defp runtime_ledger_project_snapshot(_project), do: runtime_ledger_project_snapshot(%{})

  defp counts(results, replay) do
    results = Enum.map(results, &result_snapshot/1)
    running = running_attempts(replay)

    base = %{
      selected_count: length(results),
      applied_count: Enum.count(results, & &1.ledger_changed),
      running_count: length(running),
      succeeded_count: 0,
      failed_count: 0,
      cancelled_count: 0,
      timeout_count: 0,
      stopped_count: 0,
      lost_count: 0,
      unknown_count: 0,
      manual_attention_count: 0,
      skipped_count: 0,
      unresolved_count: 0,
      retained_workspace_count: 0,
      released_workspace_count: 0,
      project_count: length(list_value(replay, :projects))
    }

    Enum.reduce(results, base, fn result, counts ->
      counts
      |> update_status_count(result.status)
      |> update_unresolved_count(result.status)
      |> update_workspace_action_count(result.workspace_action)
    end)
  end

  defp count_snapshot(counts, results, replay) when is_map(counts) do
    default = counts(results, replay)

    manual_attention_count =
      non_negative_integer(value(counts, :manual_attention_count)) || default.manual_attention_count

    retained_workspace_count =
      non_negative_integer(value(counts, :retained_workspace_count)) || default.retained_workspace_count

    released_workspace_count =
      non_negative_integer(value(counts, :released_workspace_count)) || default.released_workspace_count

    %{
      selected_count: non_negative_integer(value(counts, :selected_count)) || default.selected_count,
      applied_count: non_negative_integer(value(counts, :applied_count)) || default.applied_count,
      running_count: non_negative_integer(value(counts, :running_count)) || default.running_count,
      succeeded_count: non_negative_integer(value(counts, :succeeded_count)) || default.succeeded_count,
      failed_count: non_negative_integer(value(counts, :failed_count)) || default.failed_count,
      cancelled_count: non_negative_integer(value(counts, :cancelled_count)) || default.cancelled_count,
      timeout_count: non_negative_integer(value(counts, :timeout_count)) || default.timeout_count,
      stopped_count: non_negative_integer(value(counts, :stopped_count)) || default.stopped_count,
      lost_count: non_negative_integer(value(counts, :lost_count)) || default.lost_count,
      unknown_count: non_negative_integer(value(counts, :unknown_count)) || default.unknown_count,
      manual_attention_count: manual_attention_count,
      skipped_count: non_negative_integer(value(counts, :skipped_count)) || default.skipped_count,
      unresolved_count: non_negative_integer(value(counts, :unresolved_count)) || default.unresolved_count,
      retained_workspace_count: retained_workspace_count,
      released_workspace_count: released_workspace_count,
      project_count: non_negative_integer(value(counts, :project_count)) || default.project_count
    }
  end

  defp count_snapshot(_counts, results, replay), do: counts(results, replay)

  defp update_status_count(counts, "succeeded"), do: Map.update!(counts, :succeeded_count, &(&1 + 1))
  defp update_status_count(counts, "failed"), do: Map.update!(counts, :failed_count, &(&1 + 1))
  defp update_status_count(counts, "cancelled"), do: Map.update!(counts, :cancelled_count, &(&1 + 1))
  defp update_status_count(counts, "timeout"), do: Map.update!(counts, :timeout_count, &(&1 + 1))
  defp update_status_count(counts, "stopped"), do: Map.update!(counts, :stopped_count, &(&1 + 1))
  defp update_status_count(counts, "lost"), do: Map.update!(counts, :lost_count, &(&1 + 1))
  defp update_status_count(counts, "unknown"), do: Map.update!(counts, :unknown_count, &(&1 + 1))
  defp update_status_count(counts, "manual_attention"), do: Map.update!(counts, :manual_attention_count, &(&1 + 1))
  defp update_status_count(counts, "skipped"), do: Map.update!(counts, :skipped_count, &(&1 + 1))
  defp update_status_count(counts, _status), do: counts

  defp update_unresolved_count(counts, status) when status in @unresolved_statuses, do: Map.update!(counts, :unresolved_count, &(&1 + 1))
  defp update_unresolved_count(counts, _status), do: counts

  defp update_workspace_action_count(counts, "retained"), do: Map.update!(counts, :retained_workspace_count, &(&1 + 1))
  defp update_workspace_action_count(counts, "released"), do: Map.update!(counts, :released_workspace_count, &(&1 + 1))
  defp update_workspace_action_count(counts, _action), do: counts

  defp running_attempts(replay) do
    replay
    |> list_value(:projects)
    |> Enum.flat_map(fn project ->
      project_id = optional_string(project, :project_id)

      project
      |> list_value(:active_attempts)
      |> Enum.map(&Map.put(&1, :project_id, project_id))
    end)
    |> Enum.map(&running_attempt_snapshot/1)
  end

  defp reason_counts(results) do
    results
    |> Enum.map(&(safe_status(value(&1, :reason)) || safe_status(value(&1, :status))))
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {reason, _count} -> reason end)
    |> Map.new()
  end

  defp workspace_action_counts(results) do
    results
    |> Enum.map(&value(&1, :workspace_action))
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {action, _count} -> action end)
    |> Map.new()
  end

  defp reason_count_snapshot(reasons) when is_map(reasons) do
    reasons
    |> Enum.map(fn {reason, count} -> {safe_status(reason), non_negative_integer(count) || 0} end)
    |> Enum.reject(fn {reason, count} -> blank?(reason) or count <= 0 end)
    |> Map.new()
  end

  defp reason_count_snapshot(_reasons), do: %{}

  defp workspace_action("running", _recovery_status), do: nil
  defp workspace_action(status, "manual_attention") when status != "running", do: "retained"
  defp workspace_action(status, _recovery_status) when status in @unresolved_statuses, do: "retained"
  defp workspace_action(status, _recovery_status) when status in @terminal_statuses, do: "released"
  defp workspace_action(_status, _recovery_status), do: nil

  defp default_reason("running"), do: "worker_running"
  defp default_reason("succeeded"), do: "worker_succeeded"
  defp default_reason("failed"), do: "worker_failed"
  defp default_reason("cancelled"), do: "worker_cancelled"
  defp default_reason("timeout"), do: "worker_timeout"
  defp default_reason("stopped"), do: "worker_stopped"
  defp default_reason("lost"), do: "worker_lost"
  defp default_reason("manual_attention"), do: "worker_manual_attention"
  defp default_reason("skipped"), do: "worker_lifecycle_skipped"
  defp default_reason(_status), do: "worker_result_unknown"

  defp normalize_status(value) do
    value
    |> safe_status()
    |> case do
      nil -> nil
      "completed" -> "succeeded"
      "complete" -> "succeeded"
      "success" -> "succeeded"
      "canceled" -> "cancelled"
      "timed_out" -> "timeout"
      "heartbeat_lost" -> "lost"
      "still_running" -> "running"
      status -> status
    end
  end

  defp normalize_recovery_status(value) do
    value
    |> safe_status()
    |> case do
      "retry" -> "retry_queued"
      "backoff" -> "retry_queued"
      status when status in ["retry_queued", "blocked", "released", "manual_attention"] -> status
      _status -> nil
    end
  end

  defp compact_runtime_context(context) when is_map(context) do
    context
    |> safe_preserved_map()
    |> Map.take([
      :project_id,
      :issue_key,
      :attempt_id,
      :start_intent_id,
      :current_stage,
      :workspace_path,
      :workspace_lease_id,
      :worker_host,
      :session_id,
      :started_at,
      :last_activity_at,
      :status,
      "project_id",
      "issue_key",
      "attempt_id",
      "start_intent_id",
      "current_stage",
      "workspace_path",
      "workspace_lease_id",
      "worker_host",
      "session_id",
      "started_at",
      "last_activity_at",
      "status"
    ])
  end

  defp compact_runtime_context(_context), do: %{}

  defp touch_ledger(ledger, now_iso) do
    ledger = RuntimeLedger.to_snapshot(ledger)

    ledger
    |> Map.put(:generated_at, ledger.generated_at || now_iso)
    |> Map.put(:updated_at, now_iso)
    |> RuntimeLedger.to_snapshot()
  end

  defp safety_summary do
    %{
      model_only: true,
      starts_agent: false,
      creates_workspace: false,
      executes_hooks: false,
      writes_provider: false
    }
  end

  defp safety_snapshot(safety) when is_map(safety) do
    %{
      model_only: value(safety, :model_only) != false,
      starts_agent: value(safety, :starts_agent) == true,
      creates_workspace: value(safety, :creates_workspace) == true,
      executes_hooks: value(safety, :executes_hooks) == true,
      writes_provider: value(safety, :writes_provider) == true
    }
  end

  defp safety_snapshot(_safety), do: safety_summary()

  defp safe_preserved_map(value) when is_map(value), do: SafeSummary.sanitize_map(value, output_keys: :preserve, atom_values: :preserve)
  defp safe_preserved_map(_value), do: %{}

  defp safe_status(nil), do: nil

  defp safe_status(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> safe_status()
  end

  defp safe_status(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.:-]+/, "_")
    |> blank_to_nil()
  end

  defp safe_status(value), do: value |> to_string() |> safe_status()

  defp safe_optional_string(nil), do: nil

  defp safe_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> blank_to_nil()
    |> case do
      nil -> nil
      string -> String.slice(string, 0, 200)
    end
  end

  defp safe_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_optional_string(_value), do: nil

  defp safe_error(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
  defp safe_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error(reason), do: inspect(reason, limit: 5, printable_limit: 200)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp optional_string(map, key), do: map |> value(key) |> optional_string()
  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(_value), do: nil

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

  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(%DateTime{} = value), do: value

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp normalize_datetime(_value), do: nil

  defp iso8601(%DateTime{} = datetime), do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> iso8601(datetime)
      {:error, _reason} -> safe_optional_string(value)
    end
  end

  defp iso8601(_value), do: nil

  defp value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, nil} -> Map.get(map, Atom.to_string(key))
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key)
  defp value(_map, _key), do: nil

  defp list_value(map, key) do
    case value(map, key) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
