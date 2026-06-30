defmodule SymphonyElixir.Hub.WorkerStartHandoff do
  @moduledoc """
  Model-only Hub worker start handoff boundary.

  This boundary reads unresolved start intents from the runtime ledger replay,
  builds a safe request summary, asks an injectable skeleton starter for a
  result, and applies recoverable acknowledgement/failure facts back into the
  runtime ledger. It does not start a real worker, create a workspace, execute
  hooks, or write tracker/provider state.
  """

  alias SymphonyElixir.Hub.{ActivationPreflight, DispatchBoundary, RuntimeLedger, SafeSummary}

  @version 1
  @terminal_start_intent_statuses ["acknowledged", "failed", "cancelled"]
  @result_statuses ["ack", "failed", "unknown", "manual_attention", "already_acked", "skipped"]

  @type summary :: map()
  @type starter :: module() | function() | nil

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
      worker_lifecycle: worker_lifecycle([], replay),
      results: [],
      pending_start_intents: pending_start_intents(replay),
      unresolved_start_intents: pending_start_intents(replay),
      runtime_ledger_replay: replay,
      safety: safety_summary()
    }
    |> to_snapshot()
  end

  @spec run(map(), map(), keyword()) :: {RuntimeLedger.ledger(), summary()}
  def run(registry, runtime_ledger, opts \\ []) when is_map(registry) and is_map(runtime_ledger) and is_list(opts) do
    now = normalize_datetime(Keyword.get(opts, :now)) || DateTime.utc_now()
    now_iso = iso8601(now)
    starter = Keyword.get(opts, :starter)

    activation_preflight =
      opts
      |> Keyword.get(:activation_preflight, ActivationPreflight.empty(registry, now: now))
      |> ActivationPreflight.to_snapshot()

    initial_ledger = RuntimeLedger.to_snapshot(runtime_ledger)
    registry_projects = registry_projects_by_id(registry)
    initial_replay = RuntimeLedger.replay(initial_ledger)
    requests = start_requests(initial_replay, initial_ledger, registry_projects)

    {results, ledger, ledger_changed?} =
      Enum.reduce(requests, {[], initial_ledger, false}, fn request, {results, ledger, ledger_changed?} ->
        {result, ledger, changed?} = process_request(request, ledger, starter, activation_preflight, now)
        {[result | results], ledger, ledger_changed? or changed?}
      end)

    ledger =
      if ledger_changed? do
        touch_ledger(ledger, now_iso)
      else
        RuntimeLedger.to_snapshot(ledger)
      end

    replay = RuntimeLedger.replay(ledger)

    summary =
      %{
        version: @version,
        generated_at: now_iso,
        status: "completed",
        counts: counts(results, replay),
        reason_counts: reason_counts(results),
        worker_lifecycle: worker_lifecycle(results, replay),
        results: Enum.reverse(results),
        pending_start_intents: pending_start_intents(replay),
        unresolved_start_intents: pending_start_intents(replay),
        runtime_ledger_replay: replay,
        safety: safety_summary()
      }
      |> to_snapshot()

    {ledger, summary}
  end

  @spec to_snapshot(term()) :: summary()
  def to_snapshot(summary) when is_map(summary) do
    results =
      summary
      |> list_value(:results)
      |> Enum.map(&result_snapshot/1)
      |> Enum.sort_by(&{&1.project_id || "", &1.issue_key || "", &1.start_intent_id || "", &1.status || ""})

    pending_start_intents =
      summary
      |> list_value(:pending_start_intents)
      |> Enum.map(&pending_start_intent_snapshot/1)
      |> Enum.sort_by(&{&1.project_id || "", &1.issue_key || "", &1.intent_id || ""})

    unresolved_start_intents =
      summary
      |> list_value(:unresolved_start_intents)
      |> Enum.map(&pending_start_intent_snapshot/1)
      |> Enum.sort_by(&{&1.project_id || "", &1.issue_key || "", &1.intent_id || ""})

    replay = runtime_ledger_replay_snapshot(value(summary, :runtime_ledger_replay))

    %{
      version: positive_integer(value(summary, :version)) || @version,
      generated_at: iso8601(value(summary, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601(),
      status: safe_status(value(summary, :status)) || "idle",
      counts: count_snapshot(value(summary, :counts), results, unresolved_start_intents, replay),
      reason_counts: reason_count_snapshot(value(summary, :reason_counts)),
      worker_lifecycle: worker_lifecycle_snapshot(value(summary, :worker_lifecycle), results, replay),
      results: results,
      pending_start_intents: pending_start_intents,
      unresolved_start_intents: unresolved_start_intents,
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
  def tick_summary(%{selected_count: _selected_count} = summary), do: summarized_tick(summary)
  def tick_summary(%{"selected_count" => _selected_count} = summary), do: summarized_tick(summary)

  def tick_summary(summary) when is_map(summary) do
    snapshot = to_snapshot(summary)

    %{
      selected_count: snapshot.counts.selected_count,
      acked_count: snapshot.counts.acked_count,
      failed_count: snapshot.counts.failed_count,
      unknown_count: snapshot.counts.unknown_count,
      manual_attention_count: snapshot.counts.manual_attention_count,
      already_acked_count: snapshot.counts.already_acked_count,
      skipped_count: snapshot.counts.skipped_count,
      unresolved_start_intent_count: snapshot.counts.unresolved_start_intent_count,
      reason_counts: snapshot.reason_counts,
      worker_lifecycle: snapshot.worker_lifecycle
    }
  end

  def tick_summary(_summary), do: tick_summary(%{})

  defp summarized_tick(summary) do
    %{
      selected_count: non_negative_integer(value(summary, :selected_count)) || 0,
      acked_count: non_negative_integer(value(summary, :acked_count)) || 0,
      failed_count: non_negative_integer(value(summary, :failed_count)) || 0,
      unknown_count: non_negative_integer(value(summary, :unknown_count)) || 0,
      manual_attention_count: non_negative_integer(value(summary, :manual_attention_count)) || 0,
      already_acked_count: non_negative_integer(value(summary, :already_acked_count)) || 0,
      skipped_count: non_negative_integer(value(summary, :skipped_count)) || 0,
      unresolved_start_intent_count: non_negative_integer(value(summary, :unresolved_start_intent_count)) || 0,
      reason_counts: reason_count_snapshot(value(summary, :reason_counts)),
      worker_lifecycle: worker_lifecycle_snapshot(value(summary, :worker_lifecycle), [], RuntimeLedger.replay(RuntimeLedger.new()))
    }
  end

  defp start_requests(replay, ledger, registry_projects) do
    ledger_projects = Map.new(list_value(ledger, :projects), &{optional_string(&1, :project_id), &1})

    replay
    |> list_value(:projects)
    |> Enum.flat_map(fn replay_project ->
      project_id = optional_string(replay_project, :project_id)
      ledger_project = Map.get(ledger_projects, project_id, %{})
      registry_project = Map.get(registry_projects, project_id, %{})

      replay_project
      |> list_value(:pending_start_intents)
      |> Enum.reject(&terminal_start_intent?/1)
      |> Enum.map(&request_summary(replay_project, ledger_project, registry_project, &1))
    end)
  end

  defp process_request(request, ledger, starter, activation_preflight, now) do
    cond do
      activation_block = ActivationPreflight.block_reason(activation_preflight, request.project_id, :worker_start) ->
        result = %{
          status: "skipped",
          reason: "activation_preflight_blocked",
          error_summary: optional_string(activation_block, :message) || "Activation preflight blocked worker start"
        }

        {result_summary(request, result, "skipped", false), ledger, false}

      start_intent_terminal?(
        ledger,
        request.project_id,
        request.issue_key,
        request.attempt_id,
        request.start_intent_id
      ) ->
        {already_acked_result(request, "start_intent_already_terminal"), ledger, false}

      request.start_intent_status in ["unknown", "manual_attention"] ->
        result = %{
          status: "skipped",
          reason: "start_intent_unresolved",
          error_summary: "Worker start intent is unresolved"
        }

        {result_summary(request, result, "skipped", false), ledger, false}

      true ->
        case execute_starter(starter, request, now) |> normalize_starter_result() do
          %{status: "ack"} = result ->
            apply_ack_result(ledger, request, result, now)

          %{status: "failed"} = result ->
            apply_failed_result(ledger, request, result, now)

          %{status: "manual_attention"} = result ->
            apply_manual_attention_result(ledger, request, result, now)

          %{status: "unknown"} = result ->
            apply_unknown_result(ledger, request, result, now)

          %{status: "already_acked"} = result ->
            {result_summary(request, result, "already_acked", false), ledger, false}

          %{status: "skipped"} = result ->
            {result_summary(request, result, "skipped", false), ledger, false}
        end
    end
  end

  defp apply_ack_result(ledger, request, result, now) do
    ack =
      %{
        project_id: request.project_id,
        issue_key: request.issue_key,
        attempt_id: request.attempt_id,
        start_intent_id: request.start_intent_id,
        session_id: optional_string(result, :session_id),
        worker_host: optional_string(result, :worker_host),
        worker_identity: safe_preserved_map(value(result, :worker_identity) || %{}),
        runtime_context: safe_preserved_map(value(result, :runtime_context) || %{}),
        usage: value(result, :usage) || %{},
        acked_at: iso8601(value(result, :acked_at)) || iso8601(now),
        started_at: iso8601(value(result, :started_at)) || iso8601(now),
        last_activity_at: iso8601(value(result, :last_activity_at)) || iso8601(now)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case DispatchBoundary.acknowledge_start(ledger, ack, now: now) do
      {:ok, ledger} -> {result_summary(request, result, "ack", true), ledger, true}
      {:error, reason} -> {apply_error_result(request, result, reason), ledger, false}
    end
  end

  defp apply_failed_result(ledger, request, result, now) do
    failure_status = failure_status(result)

    failure =
      %{
        project_id: request.project_id,
        issue_key: request.issue_key,
        attempt_id: request.attempt_id,
        start_intent_id: request.start_intent_id,
        worker_host: optional_string(result, :worker_host),
        workspace_path: request.workspace_path,
        due_at: iso8601(value(result, :due_at)),
        error_summary: error_summary(result, "worker start failed")
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    apply_failure_boundary(ledger, request, result, failure_status, failure, now)
  end

  defp apply_manual_attention_result(ledger, request, result, now) do
    failure =
      %{
        project_id: request.project_id,
        issue_key: request.issue_key,
        attempt_id: request.attempt_id,
        start_intent_id: request.start_intent_id,
        worker_host: optional_string(result, :worker_host),
        workspace_path: request.workspace_path,
        error_summary: error_summary(result, "worker start requires manual attention")
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    apply_failure_boundary(ledger, request, result, :manual_attention, failure, now)
  end

  defp apply_failure_boundary(ledger, request, result, failure_status, failure, now) do
    case DispatchBoundary.record_start_failure(ledger, failure, failure_status,
           now: now,
           due_at: value(result, :due_at)
         ) do
      {:ok, ledger} -> {result_summary(request, result, result.status, true), ledger, true}
      {:error, reason} -> {apply_error_result(request, result, reason), ledger, false}
    end
  end

  defp apply_unknown_result(ledger, request, result, now) do
    unknown =
      %{
        project_id: request.project_id,
        issue_key: request.issue_key,
        attempt_id: request.attempt_id,
        start_intent_id: request.start_intent_id,
        error_summary: error_summary(result, "worker start result unknown")
      }

    case DispatchBoundary.record_start_unknown(ledger, unknown, now: now) do
      {:ok, ledger} -> {result_summary(request, result, "unknown", true), ledger, true}
      {:error, reason} -> {apply_error_result(request, result, reason), ledger, false}
    end
  end

  defp execute_starter(nil, request, _now), do: default_unknown_result(request)

  defp execute_starter(starter, request, now) when is_function(starter, 2) do
    starter.(request, now: now)
  end

  defp execute_starter(starter, request, now) when is_atom(starter) do
    starter.start(request, now: now)
  end

  defp execute_starter(_starter, request, _now) do
    Map.merge(default_unknown_result(request), %{reason: "invalid_starter"})
  end

  defp default_unknown_result(_request) do
    %{
      status: "unknown",
      reason: "default_skeleton_no_worker_started",
      error_summary: "Default Hub start handoff skeleton did not start a worker"
    }
  end

  defp normalize_starter_result({:ok, result}), do: normalize_starter_result(result)
  defp normalize_starter_result({:error, reason}), do: %{status: "failed", reason: "starter_error", error_summary: safe_error(reason), failure_status: :retry_queued}

  defp normalize_starter_result(result) when is_map(result) do
    status = safe_status(value(result, :status) || value(result, :result) || value(result, :outcome)) || "unknown"
    status = if status in @result_statuses, do: status, else: "unknown"

    result
    |> safe_preserved_map()
    |> Map.put(:status, status)
    |> maybe_put(:reason, safe_status(value(result, :reason)))
    |> maybe_put(:error_summary, safe_optional_string(value(result, :error_summary)))
    |> maybe_put(:message, safe_optional_string(value(result, :message)))
    |> maybe_put(:session_id, optional_string(result, :session_id))
    |> maybe_put(:worker_host, optional_string(result, :worker_host))
    |> maybe_put(:due_at, iso8601(value(result, :due_at)))
    |> maybe_put(
      :failure_status,
      safe_status(value(result, :failure_status)) || safe_status(value(result, :start_failure_status))
    )
    |> maybe_put(:usage, safe_preserved_map(value(result, :usage) || %{}))
    |> maybe_put(:worker_identity, safe_preserved_map(value(result, :worker_identity) || %{}))
    |> maybe_put(:runtime_context, safe_preserved_map(value(result, :runtime_context) || %{}))
    |> maybe_put(:workspace_path, optional_string(result, :workspace_path))
    |> maybe_put(:started_at, iso8601(value(result, :started_at)))
    |> maybe_put(:last_activity_at, iso8601(value(result, :last_activity_at)))
  end

  defp normalize_starter_result(result) when is_atom(result), do: normalize_starter_result(%{status: result})
  defp normalize_starter_result(_result), do: normalize_starter_result(%{status: :unknown, reason: :invalid_starter_result})

  defp request_summary(replay_project, ledger_project, registry_project, intent) do
    issue_key = optional_string(intent, :issue_key)
    attempt_id = optional_string(intent, :attempt_id)
    start_intent_id = optional_string(intent, :intent_id)
    issue = ledger_issue(ledger_project, issue_key)
    attempt = ledger_attempt(issue, attempt_id)
    lease = ledger_lease(ledger_project, issue_key, attempt_id, optional_string(intent, :workspace_lease_id))
    active_issue = replay_active_issue(replay_project, issue_key)
    active_attempt = replay_active_attempt(replay_project, issue_key, attempt_id)
    issue_ref = map_value(issue, :issue_ref) || map_value(active_issue, :issue_ref) || %{}
    runtime_identity = safe_preserved_map(value(intent, :runtime_identity) || %{})
    start_command_summary = safe_preserved_map(value(intent, :start_command_summary) || %{})

    workflow_file_path =
      optional_string(start_command_summary, :workflow_file_path) ||
        optional_string(registry_project, :workflow_path)

    tracker_file_path =
      optional_string(start_command_summary, :tracker_file_path) ||
        optional_string(registry_project, :tracker_config_path)

    source_poll = value(runtime_identity, :source_poll) || value(start_command_summary, :source_poll) || %{}
    source_intake = value(runtime_identity, :source_intake) || value(start_command_summary, :source_intake) || %{}
    planning = value(runtime_identity, :planning) || value(start_command_summary, :planning) || %{}

    %{
      project_id: optional_string(replay_project, :project_id),
      provider_scope_key: optional_string(issue_ref, :provider_scope_key),
      provider_kind: optional_string(issue_ref, :tracker_kind),
      provider_scope: safe_preserved_map(value(issue_ref, :provider_scope) || %{}),
      issue_key: issue_key,
      issue_ref: issue_ref_snapshot(issue_ref),
      current_stage:
        optional_string(issue, :current_stage) ||
          optional_string(active_issue, :stage) ||
          optional_string(active_attempt, :stage),
      attempt_id: attempt_id,
      attempt_number:
        non_negative_integer(value(attempt, :attempt_number)) ||
          non_negative_integer(value(active_attempt, :attempt_number)),
      attempt_status: safe_status(value(attempt, :status) || value(active_attempt, :status)),
      start_intent_id: start_intent_id,
      start_intent_status: safe_status(value(intent, :status)) || "pending",
      workspace_lease_id: optional_string(intent, :workspace_lease_id) || optional_string(lease, :lease_id),
      workspace_path:
        optional_string(intent, :workspace_path) ||
          optional_string(lease, :workspace_path) ||
          optional_string(attempt, :workspace_path),
      workspace_lease_status: safe_status(value(lease, :status)),
      worker_host:
        optional_string(intent, :worker_host) ||
          optional_string(lease, :worker_host) ||
          optional_string(attempt, :worker_host),
      runner: optional_string(intent, :runner),
      workflow_file_path: workflow_file_path,
      tracker_file_path: tracker_file_path,
      requested_at: iso8601(value(intent, :requested_at)),
      correlation_id: optional_string(intent, :correlation_id),
      runtime_identity: runtime_identity,
      start_command_summary: start_command_summary,
      source_poll: source_poll_snapshot(source_poll),
      source_intake: safe_preserved_map(source_intake),
      planning: safe_preserved_map(planning),
      config_fingerprint:
        optional_string(replay_project, :config_fingerprint) ||
          optional_string(registry_project, :fingerprint),
      snapshot_version:
        optional_string(replay_project, :snapshot_version) ||
          optional_string(registry_project, :snapshot_version),
      safety: safety_summary()
    }
    |> request_snapshot()
  end

  defp result_summary(request, result, status, ledger_changed?) do
    %{
      status: status,
      reason: safe_status(value(result, :reason)) || default_reason(status),
      message: safe_optional_string(value(result, :message)),
      error_summary: error_summary(result, nil),
      failure_status: safe_status(value(result, :failure_status) || value(result, :start_failure_status)),
      project_id: request.project_id,
      provider_kind: request.provider_kind,
      provider_scope_key: request.provider_scope_key,
      issue_key: request.issue_key,
      issue_ref: request.issue_ref,
      attempt_id: request.attempt_id,
      start_intent_id: request.start_intent_id,
      workspace_lease_id: request.workspace_lease_id,
      workspace_path: request.workspace_path,
      runner: request.runner,
      workflow_file_path: request.workflow_file_path,
      tracker_file_path: request.tracker_file_path,
      correlation_id: request.correlation_id,
      request: request,
      starter_result: safe_preserved_map(result),
      ledger_changed: ledger_changed?,
      safety: safety_summary()
    }
    |> result_snapshot()
  end

  defp already_acked_result(request, reason) do
    result_summary(request, %{status: "already_acked", reason: reason}, "already_acked", false)
  end

  defp apply_error_result(request, result, reason) do
    result
    |> Map.put(:reason, "ledger_apply_error")
    |> Map.put(:error_summary, safe_error(reason))
    |> then(&result_summary(request, &1, "skipped", false))
  end

  defp result_snapshot(result) when is_map(result) do
    status = safe_status(value(result, :status)) || "skipped"

    %{
      status: status,
      reason: safe_status(value(result, :reason)) || default_reason(status),
      message: safe_optional_string(value(result, :message)),
      error_summary: safe_optional_string(value(result, :error_summary)),
      failure_status: safe_status(value(result, :failure_status)),
      project_id: optional_string(result, :project_id),
      provider_kind: optional_string(result, :provider_kind),
      provider_scope_key: optional_string(result, :provider_scope_key),
      issue_key: optional_string(result, :issue_key),
      issue_ref: issue_ref_snapshot(value(result, :issue_ref) || %{}),
      attempt_id: optional_string(result, :attempt_id),
      start_intent_id: optional_string(result, :start_intent_id),
      workspace_lease_id: optional_string(result, :workspace_lease_id),
      workspace_path: optional_string(result, :workspace_path),
      runner: optional_string(result, :runner),
      workflow_file_path: optional_string(result, :workflow_file_path),
      tracker_file_path: optional_string(result, :tracker_file_path),
      correlation_id: optional_string(result, :correlation_id),
      request: maybe_request_snapshot(value(result, :request)),
      starter_result: safe_preserved_map(value(result, :starter_result) || %{}),
      ledger_changed: value(result, :ledger_changed) == true,
      safety: safety_snapshot(value(result, :safety))
    }
  end

  defp result_snapshot(_result), do: result_snapshot(%{})

  defp request_snapshot(request) when is_map(request) do
    %{
      project_id: optional_string(request, :project_id),
      provider_kind: optional_string(request, :provider_kind),
      provider_scope_key: optional_string(request, :provider_scope_key),
      provider_scope: safe_preserved_map(value(request, :provider_scope) || %{}),
      issue_key: optional_string(request, :issue_key),
      issue_ref: issue_ref_snapshot(value(request, :issue_ref) || %{}),
      current_stage: optional_string(request, :current_stage),
      attempt_id: optional_string(request, :attempt_id),
      attempt_number: non_negative_integer(value(request, :attempt_number)),
      attempt_status: safe_status(value(request, :attempt_status)),
      start_intent_id: optional_string(request, :start_intent_id),
      start_intent_status: safe_status(value(request, :start_intent_status)) || "pending",
      workspace_lease_id: optional_string(request, :workspace_lease_id),
      workspace_path: optional_string(request, :workspace_path),
      workspace_lease_status: safe_status(value(request, :workspace_lease_status)),
      worker_host: optional_string(request, :worker_host),
      runner: optional_string(request, :runner),
      workflow_file_path: optional_string(request, :workflow_file_path),
      tracker_file_path: optional_string(request, :tracker_file_path),
      requested_at: iso8601(value(request, :requested_at)),
      correlation_id: optional_string(request, :correlation_id),
      runtime_identity: safe_preserved_map(value(request, :runtime_identity) || %{}),
      start_command_summary: safe_preserved_map(value(request, :start_command_summary) || %{}),
      source_poll: source_poll_snapshot(value(request, :source_poll) || %{}),
      source_intake: safe_preserved_map(value(request, :source_intake) || %{}),
      planning: safe_preserved_map(value(request, :planning) || %{}),
      config_fingerprint: optional_string(request, :config_fingerprint),
      snapshot_version: optional_string(request, :snapshot_version),
      safety: safety_snapshot(value(request, :safety))
    }
  end

  defp maybe_request_snapshot(request) when is_map(request), do: request_snapshot(request)
  defp maybe_request_snapshot(_request), do: nil

  defp pending_start_intents(replay) do
    replay
    |> list_value(:projects)
    |> Enum.flat_map(fn project ->
      project_id = optional_string(project, :project_id)

      project
      |> list_value(:pending_start_intents)
      |> Enum.map(&Map.put(&1, :project_id, project_id))
    end)
    |> Enum.map(&pending_start_intent_snapshot/1)
  end

  defp pending_start_intent_snapshot(intent) when is_map(intent) do
    %{
      project_id: optional_string(intent, :project_id),
      issue_key: optional_string(intent, :issue_key),
      attempt_id: optional_string(intent, :attempt_id),
      intent_id: optional_string(intent, :intent_id),
      status: safe_status(value(intent, :status)) || "pending",
      requested_at: iso8601(value(intent, :requested_at)),
      workspace_path: optional_string(intent, :workspace_path),
      workspace_lease_id: optional_string(intent, :workspace_lease_id),
      worker_host: optional_string(intent, :worker_host),
      runner: optional_string(intent, :runner),
      correlation_id: optional_string(intent, :correlation_id),
      runtime_identity: safe_preserved_map(value(intent, :runtime_identity) || %{}),
      start_command_summary: safe_preserved_map(value(intent, :start_command_summary) || %{}),
      manual_attention: value(intent, :manual_attention) == true
    }
  end

  defp pending_start_intent_snapshot(_intent), do: pending_start_intent_snapshot(%{})

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
      pending_start_intents: project |> list_value(:pending_start_intents) |> Enum.map(&pending_start_intent_snapshot/1),
      workspace_leases: project |> list_value(:workspace_leases) |> Enum.map(&safe_preserved_map/1),
      retry_backoff: project |> list_value(:retry_backoff) |> Enum.map(&safe_preserved_map/1),
      blocked_candidates: project |> list_value(:blocked_candidates) |> Enum.map(&safe_preserved_map/1),
      writebacks: safe_preserved_map(value(project, :writebacks) || %{}),
      active_issues: project |> list_value(:active_issues) |> Enum.map(&safe_preserved_map/1),
      conflicts: project |> list_value(:conflicts) |> Enum.map(&safe_preserved_map/1),
      manual_attention: project |> list_value(:manual_attention) |> Enum.map(&safe_preserved_map/1)
    }
  end

  defp runtime_ledger_project_snapshot(_project), do: runtime_ledger_project_snapshot(%{})

  defp count_snapshot(counts, results, unresolved_start_intents, replay) when is_map(counts) do
    counts
    |> count_snapshot()
    |> Map.put(:selected_count, length(results))
    |> Map.put(:unresolved_start_intent_count, length(unresolved_start_intents))
    |> Map.put(:pending_start_intent_count, length(unresolved_start_intents))
    |> Map.put(:project_count, length(list_value(replay, :projects)))
  end

  defp count_snapshot(_counts, results, unresolved_start_intents, replay) do
    counts(results, replay)
    |> Map.put(:unresolved_start_intent_count, length(unresolved_start_intents))
    |> Map.put(:pending_start_intent_count, length(unresolved_start_intents))
  end

  defp count_snapshot(counts) when is_map(counts) do
    %{
      selected_count: non_negative_integer(value(counts, :selected_count)) || 0,
      acked_count: non_negative_integer(value(counts, :acked_count)) || 0,
      failed_count: non_negative_integer(value(counts, :failed_count)) || 0,
      unknown_count: non_negative_integer(value(counts, :unknown_count)) || 0,
      manual_attention_count: non_negative_integer(value(counts, :manual_attention_count)) || 0,
      already_acked_count: non_negative_integer(value(counts, :already_acked_count)) || 0,
      skipped_count: non_negative_integer(value(counts, :skipped_count)) || 0,
      pending_start_intent_count: non_negative_integer(value(counts, :pending_start_intent_count)) || 0,
      unresolved_start_intent_count: non_negative_integer(value(counts, :unresolved_start_intent_count)) || 0,
      project_count: non_negative_integer(value(counts, :project_count)) || 0
    }
  end

  defp counts(results, replay) do
    results = Enum.map(results, &result_snapshot/1)

    %{
      selected_count: length(results),
      acked_count: Enum.count(results, &(&1.status == "ack")),
      failed_count: Enum.count(results, &(&1.status == "failed")),
      unknown_count: Enum.count(results, &(&1.status == "unknown")),
      manual_attention_count: Enum.count(results, &(&1.status == "manual_attention")),
      already_acked_count: Enum.count(results, &(&1.status == "already_acked")),
      skipped_count: Enum.count(results, &(&1.status == "skipped")),
      pending_start_intent_count: length(pending_start_intents(replay)),
      unresolved_start_intent_count: length(pending_start_intents(replay)),
      project_count: length(list_value(replay, :projects))
    }
  end

  defp worker_lifecycle(results, replay) do
    results = Enum.map(results, &result_snapshot/1)
    replay = runtime_ledger_replay_snapshot(replay)
    active_attempts = replay_active_attempts(replay)

    %{
      counts: %{
        selected_count: length(results),
        acked_count: Enum.count(results, &(&1.status == "ack")),
        failed_count: Enum.count(results, &(&1.status == "failed")),
        manual_attention_count: Enum.count(results, &(&1.status == "manual_attention")),
        unknown_count: Enum.count(results, &(&1.status == "unknown")),
        skipped_count: Enum.count(results, &(&1.status == "skipped")),
        already_acked_count: Enum.count(results, &(&1.status == "already_acked")),
        running_attempt_count: length(active_attempts)
      },
      workers: worker_lifecycle_workers(results, active_attempts),
      failure_reason_counts: failure_reason_counts(results),
      active_attempt_start_intents: active_attempt_start_intents(active_attempts)
    }
  end

  defp worker_lifecycle_snapshot(lifecycle, results, replay) when is_map(lifecycle) do
    %{
      counts: lifecycle_count_snapshot(value(lifecycle, :counts), results, replay),
      workers:
        lifecycle
        |> list_value(:workers)
        |> Enum.map(&worker_snapshot/1)
        |> Enum.sort_by(&{&1.project_id || "", &1.issue_key || "", &1.attempt_id || ""}),
      failure_reason_counts: reason_count_snapshot(value(lifecycle, :failure_reason_counts)),
      active_attempt_start_intents:
        lifecycle
        |> list_value(:active_attempt_start_intents)
        |> Enum.map(&active_attempt_start_intent_snapshot/1)
        |> Enum.sort_by(&{&1.project_id || "", &1.issue_key || "", &1.attempt_id || ""})
    }
  end

  defp worker_lifecycle_snapshot(_lifecycle, results, replay), do: worker_lifecycle(results, replay)

  defp lifecycle_count_snapshot(counts, results, replay) when is_map(counts) do
    replay_active_attempt_count = replay |> runtime_ledger_replay_snapshot() |> replay_active_attempts() |> length()

    %{
      selected_count: non_negative_integer(value(counts, :selected_count)) || length(results),
      acked_count: non_negative_integer(value(counts, :acked_count)) || Enum.count(results, &(&1.status == "ack")),
      failed_count: non_negative_integer(value(counts, :failed_count)) || Enum.count(results, &(&1.status == "failed")),
      manual_attention_count: non_negative_integer(value(counts, :manual_attention_count)) || Enum.count(results, &(&1.status == "manual_attention")),
      unknown_count: non_negative_integer(value(counts, :unknown_count)) || Enum.count(results, &(&1.status == "unknown")),
      skipped_count: non_negative_integer(value(counts, :skipped_count)) || Enum.count(results, &(&1.status == "skipped")),
      already_acked_count: non_negative_integer(value(counts, :already_acked_count)) || Enum.count(results, &(&1.status == "already_acked")),
      running_attempt_count: non_negative_integer(value(counts, :running_attempt_count)) || replay_active_attempt_count
    }
  end

  defp lifecycle_count_snapshot(_counts, results, replay), do: worker_lifecycle(results, replay).counts

  defp worker_lifecycle_workers(results, active_attempts) do
    ack_workers =
      results
      |> Enum.filter(&(&1.status == "ack"))
      |> Enum.map(fn result ->
        starter_result = safe_preserved_map(value(result, :starter_result) || %{})
        identity = safe_preserved_map(value(starter_result, :worker_identity) || %{})
        runtime_context = safe_preserved_map(value(starter_result, :runtime_context) || %{})

        worker_snapshot(%{
          source: "starter_ack",
          project_id: result.project_id,
          issue_key: result.issue_key,
          attempt_id: result.attempt_id,
          start_intent_id: result.start_intent_id,
          start_intent_status: "acknowledged",
          session_id: optional_string(starter_result, :session_id),
          worker_host: optional_string(starter_result, :worker_host) || (result.request && result.request.worker_host),
          workspace_path: optional_string(starter_result, :workspace_path) || result.workspace_path,
          started_at: iso8601(value(starter_result, :started_at)),
          last_activity_at: iso8601(value(starter_result, :last_activity_at)),
          worker_identity: identity,
          runtime_context: runtime_context
        })
      end)

    replay_workers =
      active_attempts
      |> Enum.filter(&(safe_status(value(&1, :start_intent_status)) == "acknowledged"))
      |> Enum.map(fn attempt ->
        run_context = safe_preserved_map(value(attempt, :run_context) || %{})

        worker_snapshot(%{
          source: "runtime_ledger_replay",
          project_id: optional_string(attempt, :project_id),
          issue_key: optional_string(attempt, :issue_key),
          attempt_id: optional_string(attempt, :attempt_id),
          start_intent_id: optional_string(attempt, :start_intent_id),
          start_intent_status: safe_status(value(attempt, :start_intent_status)),
          session_id: optional_string(run_context, :session_id),
          worker_host: optional_string(attempt, :worker_host),
          workspace_path: optional_string(attempt, :workspace_path),
          started_at: iso8601(value(run_context, :started_at)),
          last_activity_at: iso8601(value(run_context, :last_activity_at)),
          worker_identity: safe_preserved_map(value(run_context, :worker_identity) || %{}),
          runtime_context: run_context
        })
      end)

    (ack_workers ++ replay_workers)
    |> Enum.reject(&(is_nil(&1.attempt_id) and is_nil(&1.start_intent_id)))
    |> Enum.uniq_by(&{&1.project_id, &1.issue_key, &1.attempt_id, &1.start_intent_id, &1.source})
  end

  defp worker_snapshot(worker) when is_map(worker) do
    %{
      source: safe_status(value(worker, :source)) || "unknown",
      project_id: optional_string(worker, :project_id),
      issue_key: optional_string(worker, :issue_key),
      attempt_id: optional_string(worker, :attempt_id),
      start_intent_id: optional_string(worker, :start_intent_id),
      start_intent_status: safe_status(value(worker, :start_intent_status)),
      session_id: optional_string(worker, :session_id),
      worker_host: optional_string(worker, :worker_host),
      workspace_path: optional_string(worker, :workspace_path),
      started_at: iso8601(value(worker, :started_at)),
      last_activity_at: iso8601(value(worker, :last_activity_at)),
      worker_identity: safe_preserved_map(value(worker, :worker_identity) || %{}),
      runtime_context: compact_runtime_context(value(worker, :runtime_context) || %{})
    }
  end

  defp worker_snapshot(_worker), do: worker_snapshot(%{})

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

  defp failure_reason_counts(results) do
    results
    |> Enum.filter(&(&1.status in ["failed", "manual_attention"]))
    |> Enum.map(&(safe_status(value(&1, :reason)) || safe_status(value(&1, :failure_status)) || &1.status))
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {reason, _count} -> reason end)
    |> Map.new()
  end

  defp active_attempt_start_intents(active_attempts) do
    Enum.map(active_attempts, &active_attempt_start_intent_snapshot/1)
  end

  defp active_attempt_start_intent_snapshot(attempt) when is_map(attempt) do
    %{
      project_id: optional_string(attempt, :project_id),
      issue_key: optional_string(attempt, :issue_key),
      attempt_id: optional_string(attempt, :attempt_id),
      status: safe_status(value(attempt, :status)),
      start_intent_id: optional_string(attempt, :start_intent_id),
      start_intent_status: safe_status(value(attempt, :start_intent_status)),
      workspace_path: optional_string(attempt, :workspace_path),
      workspace_lease_id: optional_string(attempt, :workspace_lease_id),
      worker_host: optional_string(attempt, :worker_host)
    }
  end

  defp active_attempt_start_intent_snapshot(_attempt), do: active_attempt_start_intent_snapshot(%{})

  defp replay_active_attempts(replay) do
    replay
    |> list_value(:projects)
    |> Enum.flat_map(fn project ->
      project_id = optional_string(project, :project_id)

      project
      |> list_value(:active_attempts)
      |> Enum.map(&Map.put(&1, :project_id, project_id))
    end)
  end

  defp reason_counts(results) do
    results
    |> Enum.map(&(safe_status(value(&1, :reason)) || safe_status(value(&1, :status))))
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {reason, _count} -> reason end)
    |> Map.new()
  end

  defp reason_count_snapshot(reasons) when is_map(reasons) do
    reasons
    |> Enum.map(fn {reason, count} -> {safe_status(reason), non_negative_integer(count) || 0} end)
    |> Enum.reject(fn {reason, count} -> blank?(reason) or count <= 0 end)
    |> Map.new()
  end

  defp reason_count_snapshot(_reasons), do: %{}

  defp ledger_issue(project, issue_key) do
    project
    |> list_value(:issues)
    |> Enum.find(&(optional_string(&1, :issue_key) == issue_key))
  end

  defp ledger_attempt(nil, _attempt_id), do: nil

  defp ledger_attempt(issue, attempt_id) do
    issue
    |> list_value(:attempts)
    |> Enum.find(&(optional_string(&1, :attempt_id) == attempt_id))
  end

  defp ledger_lease(project, issue_key, attempt_id, lease_id) do
    project
    |> list_value(:workspace_leases)
    |> Enum.find(fn lease ->
      optional_string(lease, :issue_key) == issue_key and
        optional_string(lease, :attempt_id) == attempt_id and
        (is_nil(lease_id) or optional_string(lease, :lease_id) == lease_id)
    end)
  end

  defp replay_active_issue(replay_project, issue_key) do
    replay_project
    |> list_value(:active_issues)
    |> Enum.find(&(optional_string(&1, :issue_key) == issue_key))
  end

  defp replay_active_attempt(replay_project, issue_key, attempt_id) do
    replay_project
    |> list_value(:active_attempts)
    |> Enum.find(&(optional_string(&1, :issue_key) == issue_key and optional_string(&1, :attempt_id) == attempt_id))
  end

  defp start_intent_terminal?(ledger, project_id, issue_key, attempt_id, intent_id) do
    ledger
    |> list_value(:projects)
    |> Enum.find(&(optional_string(&1, :project_id) == project_id))
    |> case do
      nil ->
        false

      project ->
        project
        |> list_value(:start_intents)
        |> Enum.find(fn intent ->
          optional_string(intent, :issue_key) == issue_key and
            optional_string(intent, :attempt_id) == attempt_id and
            optional_string(intent, :intent_id) == intent_id
        end)
        |> terminal_start_intent?()
    end
  end

  defp terminal_start_intent?(nil), do: false

  defp terminal_start_intent?(intent) do
    status = safe_status(value(intent, :status))

    status in @terminal_start_intent_statuses or
      not is_nil(value(intent, :acked_at)) or
      not is_nil(value(intent, :finished_at))
  end

  defp failure_status(result) do
    status = safe_status(value(result, :failure_status) || value(result, :start_failure_status))

    case status do
      "retry_queued" -> :retry_queued
      "retry" -> :retry_queued
      "backoff" -> :retry_queued
      "blocked" -> :blocked
      "released" -> :released
      "manual_attention" -> :manual_attention
      _status -> :retry_queued
    end
  end

  defp default_reason("ack"), do: "start_acknowledged"
  defp default_reason("failed"), do: "start_failed"
  defp default_reason("unknown"), do: "start_unknown"
  defp default_reason("manual_attention"), do: "start_manual_attention"
  defp default_reason("already_acked"), do: "start_intent_already_acknowledged"
  defp default_reason("skipped"), do: "start_handoff_skipped"
  defp default_reason(_status), do: "start_handoff_result"

  defp error_summary(result, default) do
    safe_optional_string(value(result, :error_summary)) ||
      safe_optional_string(value(result, :message)) ||
      default
  end

  defp issue_ref_snapshot(issue_ref) when is_map(issue_ref) do
    %{
      project_id: optional_string(issue_ref, :project_id),
      tracker_kind: optional_string(issue_ref, :tracker_kind),
      provider_scope: safe_preserved_map(value(issue_ref, :provider_scope) || %{}),
      provider_scope_key: optional_string(issue_ref, :provider_scope_key),
      provider_issue_id: optional_string(issue_ref, :provider_issue_id),
      provider_local_id: optional_string(issue_ref, :provider_local_id),
      identifier: optional_string(issue_ref, :identifier),
      url: safe_optional_string(value(issue_ref, :url))
    }
  end

  defp issue_ref_snapshot(_issue_ref), do: issue_ref_snapshot(%{})

  defp source_poll_snapshot(source_poll) when is_map(source_poll) do
    %{
      project_id: optional_string(source_poll, :project_id),
      provider_kind: optional_string(source_poll, :provider_kind),
      provider_scope_key: optional_string(source_poll, :provider_scope_key),
      request_id: optional_string(source_poll, :request_id),
      logical_key: optional_string(source_poll, :logical_key),
      poll_attempt_id: optional_string(source_poll, :poll_attempt_id),
      poll_result_status: safe_status(value(source_poll, :poll_result_status)),
      retry_after_ms: non_negative_integer(value(source_poll, :retry_after_ms)),
      backoff_until: iso8601(value(source_poll, :backoff_until)),
      finished_at: iso8601(value(source_poll, :finished_at))
    }
  end

  defp source_poll_snapshot(_source_poll), do: source_poll_snapshot(%{})

  defp registry_projects_by_id(registry) do
    registry
    |> list_value(:projects)
    |> Map.new(fn project -> {optional_string(project, :project_id) || "", project} end)
  end

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

  defp safe_preserved_map(value) when is_map(value) do
    value
    |> SafeSummary.sanitize_map(output_keys: :preserve, atom_values: :preserve)
    |> drop_body_derived_fields()
  end

  defp safe_preserved_map(_value), do: %{}

  defp drop_body_derived_fields(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, sanitized ->
      if body_derived_key?(key) do
        sanitized
      else
        Map.put(sanitized, key, drop_body_derived_fields(raw_value))
      end
    end)
  end

  defp drop_body_derived_fields(values) when is_list(values), do: Enum.map(values, &drop_body_derived_fields/1)
  defp drop_body_derived_fields(value), do: value

  defp body_derived_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.contains?("body")
  end

  defp safe_error(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
  defp safe_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error(reason), do: inspect(reason, limit: 5, printable_limit: 200)

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

  defp map_value(map, key) do
    case value(map, key) do
      value when is_map(value) -> value
      _value -> nil
    end
  end

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

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
