defmodule SymphonyElixir.Hub.PollCoordinator do
  @moduledoc """
  Model-only Hub poll coordination baseline.

  The coordinator builds a provider-neutral poll plan from Hub project snapshots,
  provider governance scope state, and recoverable poll facts. It does not perform
  provider I/O, claim work, start workers, or replace the legacy single-project
  `SymphonyElixir.Orchestrator` poll loop.
  """

  alias SymphonyElixir.Hub.ProviderGovernance

  @version 1
  @default_poll_interval_ms 30_000
  @fact_types [:poll_plan, :poll_attempt, :poll_result]
  @provider_result_statuses [
    :success,
    :retryable_failure,
    :permanent_failure,
    :rate_limited,
    :circuit_open,
    :canceled,
    :timed_out,
    :unknown_result
  ]
  @eligibility_reasons [
    :ready,
    :not_due,
    :paused,
    :config_error,
    :backoff,
    :rate_limited,
    :circuit_open,
    :scope_concurrency,
    :provider_unavailable
  ]
  @sensitive_keys MapSet.new([
                    "api_key",
                    "apikey",
                    "authorization",
                    "cookie",
                    "credential",
                    "credentials",
                    "prompt",
                    "raw_config",
                    "secret",
                    "token",
                    "transcript"
                  ])
  @sensitive_value_patterns [
    ~r/\$[A-Z0-9_]*(TOKEN|API_KEY|SECRET|CREDENTIAL)[A-Z0-9_]*/,
    ~r/\b(api[_-]?key|authorization|bearer|cookie|credential|secret|token|transcript|full prompt|codex transcript)\b/i,
    ~r/\b(ghp_|github_pat_|glpat-|sk-[A-Za-z0-9])/
  ]

  @type fact :: %{
          required(:fact_type) => atom(),
          required(:project_id) => String.t() | nil,
          required(:provider_scope_key) => String.t() | nil,
          required(:provider_kind) => String.t() | nil,
          required(:request_id) => String.t() | nil,
          required(:logical_key) => String.t() | nil,
          required(:attempt_id) => String.t() | nil,
          required(:operation_kind) => atom(),
          required(:config_fingerprint) => String.t() | nil,
          required(:snapshot_version) => String.t() | nil,
          required(:status) => atom() | nil,
          required(:error_class) => atom() | nil,
          required(:retry_after_ms) => non_neg_integer() | nil,
          required(:backoff_until) => DateTime.t() | nil,
          required(:next_due_at) => DateTime.t() | nil,
          required(:result_summary) => map(),
          required(:attempted_at) => DateTime.t() | nil,
          required(:finished_at) => DateTime.t() | nil,
          required(:recorded_at) => DateTime.t() | nil
        }

  @type plan_entry :: %{
          required(:project_id) => String.t(),
          required(:name) => String.t() | nil,
          required(:project_status) => atom(),
          required(:config_fingerprint) => String.t() | nil,
          required(:snapshot_version) => String.t() | nil,
          required(:workflow_identity) => map(),
          required(:tracker_identity) => map(),
          required(:provider_scope) => map() | nil,
          required(:provider_scope_key) => String.t() | nil,
          required(:poll_interval_ms) => pos_integer(),
          required(:allow_poll) => boolean(),
          required(:eligibility) => map(),
          required(:next_due_at) => DateTime.t() | nil,
          required(:backoff_until) => DateTime.t() | nil,
          required(:last_poll) => map() | nil,
          required(:governance) => map() | nil
        }

  @type plan :: %{
          required(:version) => pos_integer(),
          required(:generated_at) => DateTime.t(),
          required(:registry) => map(),
          required(:projects) => [plan_entry()],
          required(:poll_order) => [String.t()],
          required(:provider_queue) => map(),
          required(:facts) => [fact()]
        }

  @type diagnostic :: %{
          required(:level) => :error,
          required(:code) => atom(),
          required(:project_id) => String.t() | nil,
          required(:message) => String.t()
        }

  @spec build_plan(map(), keyword()) :: plan()
  def build_plan(registry, opts \\ []) when is_map(registry) and is_list(opts) do
    now = normalize_datetime(Keyword.get(opts, :now)) || DateTime.utc_now()
    input_facts = opts |> Keyword.get(:facts, []) |> normalize_facts()

    queue =
      opts
      |> Keyword.get(:queue, ProviderGovernance.new_queue())
      |> poll_queue()

    projects = registry |> list_value(:projects) |> Enum.sort_by(&required_string(&1, :project_id))
    base_entries = Enum.map(projects, &base_entry(&1, input_facts, now))

    {planned_entries, planned_queue, poll_order} =
      base_entries
      |> enqueue_due_entries(restore_last_served(queue, base_entries, input_facts), now)
      |> apply_governance_decisions(now)

    plan = %{
      version: @version,
      generated_at: now,
      registry: registry_summary(registry, projects),
      projects: planned_entries,
      poll_order: poll_order,
      provider_queue: ProviderGovernance.queue_summary(planned_queue, now),
      facts: input_facts
    }

    %{plan | facts: [plan_fact(plan, now: now) | input_facts]}
  end

  @spec plan_fact(map(), keyword()) :: fact()
  def plan_fact(plan, opts \\ []) when is_map(plan) and is_list(opts) do
    now = normalize_datetime(Keyword.get(opts, :now)) || DateTime.utc_now()
    projects = list_value(plan, :projects)

    normalize_fact(%{
      fact_type: :poll_plan,
      project_id: nil,
      provider_scope_key: nil,
      operation_kind: :candidate_scan,
      recorded_at: now,
      result_summary: %{
        project_count: length(projects),
        allowed_count: Enum.count(projects, &(value(&1, :allow_poll) == true)),
        blocked_count: Enum.count(projects, &(value(&1, :allow_poll) != true))
      }
    })
  end

  @spec attempt_fact(map(), keyword()) :: fact()
  def attempt_fact(source, opts \\ []) when is_map(source) and is_list(opts) do
    attempted_at = normalize_datetime(Keyword.get(opts, :attempted_at) || Keyword.get(opts, :now)) || DateTime.utc_now()
    request = request_source(source)
    project_id = optional_string(request, :project_id) || optional_string(source, :project_id)
    provider_scope_key = optional_string(request, :provider_scope_key) || optional_string(source, :provider_scope_key)
    request_id = optional_string(request, :request_id) || optional_string(source, :request_id)

    normalize_fact(%{
      fact_type: :poll_attempt,
      project_id: project_id,
      provider_scope_key: provider_scope_key,
      provider_kind: optional_string(request, :provider_kind) || optional_string(source, :provider_kind),
      request_id: request_id,
      logical_key: optional_string(request, :logical_key) || optional_string(source, :logical_key),
      attempt_id: optional_string(Keyword.get(opts, :attempt_id)) || default_attempt_id(project_id, provider_scope_key, request_id, attempted_at),
      operation_kind: normalize_operation_kind(value(request, :operation_kind) || value(source, :operation_kind)),
      config_fingerprint: optional_string(request, :config_fingerprint) || optional_string(source, :config_fingerprint),
      snapshot_version: optional_string(request, :snapshot_version) || optional_string(source, :snapshot_version),
      attempted_at: attempted_at,
      recorded_at: attempted_at
    })
  end

  @spec result_fact(map(), atom() | String.t() | map(), keyword()) :: fact()
  def result_fact(source, status_or_result, opts \\ []) when is_map(source) and is_list(opts) do
    finished_at = normalize_datetime(Keyword.get(opts, :finished_at) || Keyword.get(opts, :now)) || DateTime.utc_now()
    result = if is_map(status_or_result), do: status_or_result, else: %{}
    status = normalize_result_status(value(result, :status) || status_or_result)
    retry_after_ms = non_negative_integer(value(result, :retry_after_ms) || Keyword.get(opts, :retry_after_ms))
    backoff_until = normalize_datetime(value(result, :backoff_until) || Keyword.get(opts, :backoff_until))
    next_due_at = normalize_datetime(Keyword.get(opts, :next_due_at)) || backoff_until || next_due_at_from_result(finished_at, opts)
    request = request_source(source)

    normalize_fact(%{
      fact_type: :poll_result,
      project_id: optional_string(request, :project_id) || optional_string(source, :project_id),
      provider_scope_key: optional_string(request, :provider_scope_key) || optional_string(source, :provider_scope_key),
      provider_kind: optional_string(request, :provider_kind) || optional_string(source, :provider_kind),
      request_id: optional_string(request, :request_id) || optional_string(source, :request_id),
      logical_key: optional_string(request, :logical_key) || optional_string(source, :logical_key),
      attempt_id: optional_string(source, :attempt_id) || optional_string(Keyword.get(opts, :attempt_id)),
      operation_kind: normalize_operation_kind(value(request, :operation_kind) || value(source, :operation_kind)),
      config_fingerprint: optional_string(request, :config_fingerprint) || optional_string(source, :config_fingerprint),
      snapshot_version: optional_string(request, :snapshot_version) || optional_string(source, :snapshot_version),
      status: status,
      error_class: normalize_output_atom(value(result, :error_class) || Keyword.get(opts, :error_class)),
      retry_after_ms: retry_after_ms,
      backoff_until: backoff_until,
      next_due_at: next_due_at,
      result_summary: value(result, :result_summary) || Keyword.get(opts, :result_summary, %{}),
      finished_at: finished_at,
      recorded_at: finished_at
    })
  end

  @spec to_snapshot(map()) :: map()
  def to_snapshot(plan) when is_map(plan) do
    %{
      version: normalize_positive_integer(value(plan, :version)) || @version,
      generated_at: iso8601(value(plan, :generated_at)),
      registry: sanitize_map(value(plan, :registry) || %{}),
      poll_order: list_value(plan, :poll_order) |> Enum.map(&safe_optional_string/1) |> Enum.reject(&is_nil/1),
      projects: plan |> list_value(:projects) |> Enum.map(&entry_snapshot/1),
      provider_queue: sanitize_value(value(plan, :provider_queue) || %{}),
      facts: plan |> list_value(:facts) |> Enum.map(&fact_snapshot/1)
    }
  end

  @spec from_snapshot(map()) :: {:ok, map()} | {:error, [diagnostic()]}
  def from_snapshot(snapshot) when is_map(snapshot) do
    case privacy_diagnostics(snapshot) do
      [] -> {:ok, to_snapshot(snapshot)}
      diagnostics -> {:error, diagnostics}
    end
  end

  @spec observability_snapshot(term()) :: map() | nil
  def observability_snapshot(nil), do: nil

  def observability_snapshot(snapshot) when is_map(snapshot) do
    snapshot
    |> to_snapshot()
    |> Map.take([:version, :generated_at, :registry, :poll_order, :projects, :provider_queue])
  end

  def observability_snapshot(_snapshot), do: nil

  defp base_entry(project, facts, now) do
    project_id = required_string(project, :project_id)
    workflow_summary = value(project, :workflow_summary)
    tracker_summary = value(project, :tracker_summary)
    runtime_summary = value(project, :runtime_summary)
    project_status = normalize_project_status(value(project, :status))

    poll_interval_ms =
      normalize_positive_integer(value(runtime_summary || %{}, :polling_interval_ms)) ||
        @default_poll_interval_ms

    last_poll = last_poll_for_project(facts, project_id)
    next_due_at = next_due_at(project, last_poll, poll_interval_ms, now)
    backoff_until = normalize_datetime(value(last_poll || %{}, :backoff_until))

    eligibility =
      base_eligibility(project, tracker_summary, runtime_summary, workflow_summary, next_due_at, backoff_until, now)

    %{
      project_id: project_id,
      name: optional_string(project, :name),
      project_status: project_status,
      config_fingerprint: optional_string(project, :fingerprint) || optional_string(project, :config_fingerprint),
      snapshot_version: snapshot_version(project),
      workflow_identity: workflow_identity(workflow_summary),
      tracker_identity: tracker_identity(tracker_summary),
      provider_scope: provider_scope(tracker_summary),
      provider_scope_key: optional_string(tracker_summary || %{}, :provider_scope_key),
      poll_interval_ms: poll_interval_ms,
      allow_poll: false,
      eligibility: eligibility,
      next_due_at: next_due_at,
      backoff_until: backoff_until,
      last_poll: last_poll && fact_summary(last_poll),
      governance: nil
    }
  end

  defp enqueue_due_entries(entries, queue, now) do
    Enum.reduce(entries, {entries, queue, %{}}, fn entry, {entries, queue, requests_by_project} ->
      if due_candidate?(entry) do
        case poll_request(entry, now) do
          {:ok, request} ->
            {:ok, queue} = ProviderGovernance.enqueue(queue, request, now)
            entries = replace_entry(entries, entry.project_id, Map.put(entry, :governance, %{request: ProviderGovernance.request_snapshot(request)}))
            {entries, queue, Map.put(requests_by_project, request.request_id, request)}

          {:error, reason} ->
            entry =
              entry
              |> Map.put(:eligibility, eligibility(false, :config_error, inspect(reason)))
              |> Map.put(:governance, %{error: inspect(reason)})

            {replace_entry(entries, entry.project_id, entry), queue, requests_by_project}
        end
      else
        {entries, queue, requests_by_project}
      end
    end)
  end

  defp apply_governance_decisions({entries, queue, requests_by_project}, now) do
    {selected_requests, queue} = select_poll_requests(queue, now, [])
    selected_request_ids = MapSet.new(selected_requests, & &1.request_id)
    poll_order = Enum.map(selected_requests, & &1.project_id)
    queue_summary = ProviderGovernance.queue_summary(queue, now)
    backpressure_by_request = backpressure_by_request_id(queue_summary)

    entries =
      entries
      |> Enum.map(fn entry ->
        request = request_for_entry(entry, requests_by_project)

        cond do
          is_nil(request) ->
            entry

          MapSet.member?(selected_request_ids, request.request_id) ->
            entry
            |> Map.put(:allow_poll, true)
            |> Map.put(:eligibility, eligibility(true, :ready, nil))
            |> put_in([:governance, :decision], :selected)

          backpressure = Map.get(backpressure_by_request, request.request_id) ->
            entry
            |> Map.put(:allow_poll, false)
            |> Map.put(:eligibility, eligibility(false, normalize_backpressure_reason(backpressure.reason), backpressure_message(backpressure)))
            |> Map.put(:backoff_until, normalize_datetime(backpressure.backoff_until) || entry.backoff_until)
            |> put_in([:governance, :decision], :blocked)
            |> put_in([:governance, :backpressure], backpressure)

          true ->
            entry
            |> Map.put(:allow_poll, false)
            |> Map.put(:eligibility, eligibility(false, :provider_unavailable, "provider governance did not select this poll request"))
            |> put_in([:governance, :decision], :not_selected)
        end
      end)
      |> Enum.sort_by(& &1.project_id)

    {entries, queue, poll_order}
  end

  defp select_poll_requests(queue, now, selected) do
    case ProviderGovernance.next_request(queue, now) do
      {:ok, request, queue} ->
        select_poll_requests(queue, now, selected ++ [request])

      {:blocked, _summary} ->
        {selected, queue}

      {:empty, _summary} ->
        {selected, queue}
    end
  end

  defp poll_request(entry, _now) do
    ProviderGovernance.new_request(%{
      project_id: entry.project_id,
      provider_scope: %{
        kind: entry.tracker_identity.kind,
        scope: entry.provider_scope || %{},
        key: entry.provider_scope_key
      },
      config_fingerprint: entry.config_fingerprint,
      snapshot_version: entry.snapshot_version,
      operation_kind: :candidate_scan,
      logical_key: "hub-poll:#{entry.project_id}:candidate_scan",
      fairness_key: entry.project_id,
      replay_policy: :idempotent,
      correlation: %{
        boundary: "hub_poll_coordination",
        workflow_start_stage: entry.workflow_identity.start_stage
      }
    })
  end

  defp base_eligibility(project, tracker_summary, runtime_summary, workflow_summary, next_due_at, backoff_until, now) do
    cond do
      normalize_project_status(value(project, :status)) == :error ->
        eligibility(false, :config_error, optional_string(project, :load_error) || "project configuration did not load")

      paused_project?(project) ->
        eligibility(false, :paused, nil)

      is_nil(tracker_summary) or is_nil(runtime_summary) or is_nil(workflow_summary) ->
        eligibility(false, :config_error, "project snapshot is missing workflow, tracker, or runtime summary")

      is_nil(optional_string(tracker_summary, :provider_scope_key)) ->
        eligibility(false, :config_error, "project snapshot is missing provider scope key")

      future?(backoff_until, now) ->
        eligibility(false, :backoff, "poll backoff is active")

      future?(next_due_at, now) ->
        eligibility(false, :not_due, nil)

      true ->
        eligibility(true, :ready, nil)
    end
  end

  defp due_candidate?(entry), do: entry.eligibility.eligible? == true and entry.eligibility.reason == :ready

  defp paused_project?(project) do
    value(project, :paused) == true or
      value(project, :dispatch_enabled) == false or
      normalize_project_status(value(project, :status)) == :paused
  end

  defp eligibility(eligible?, reason, message) do
    %{
      eligible?: eligible?,
      reason: normalize_eligibility_reason(reason),
      message: message
    }
  end

  defp replace_entry(entries, project_id, replacement) do
    Enum.map(entries, fn
      %{project_id: ^project_id} -> replacement
      entry -> entry
    end)
  end

  defp request_for_entry(%{governance: %{request: %{request_id: request_id}}}, requests_by_project), do: Map.get(requests_by_project, request_id)
  defp request_for_entry(%{governance: %{request: %{"request_id" => request_id}}}, requests_by_project), do: Map.get(requests_by_project, request_id)
  defp request_for_entry(_entry, _requests_by_project), do: nil

  defp backpressure_by_request_id(queue_summary) do
    queue_summary
    |> list_value(:backpressure)
    |> Map.new(fn backpressure -> {required_string(backpressure, :request_id), backpressure} end)
  end

  defp backpressure_message(%{reason: reason, backoff_until: backoff_until}) when not is_nil(backoff_until) do
    "#{reason} until #{backoff_until}"
  end

  defp backpressure_message(%{reason: reason}), do: Atom.to_string(reason)

  defp poll_queue(queue) when is_map(queue) do
    queue
    |> Map.put(:pending, [])
    |> Map.put_new(:running, [])
    |> Map.put_new(:recent_results, [])
    |> Map.put_new(:scope_states, %{})
    |> Map.put_new(:last_served_by_scope, %{})
    |> Map.put_new(:max_running_per_scope, 1)
    |> Map.put_new(:recent_limit, 10)
  end

  defp poll_queue(_queue), do: ProviderGovernance.new_queue()

  defp restore_last_served(queue, entries, facts) do
    restored =
      facts
      |> Enum.filter(&restorable_poll_result?/1)
      |> Enum.group_by(&optional_string(&1, :provider_scope_key))
      |> Map.new(fn {scope_key, scope_facts} ->
        latest =
          Enum.max_by(scope_facts, &unix_time(value(&1, :finished_at) || value(&1, :recorded_at)), fn -> nil end)

        {scope_key, latest && optional_string(latest, :project_id)}
      end)
      |> Enum.reject(fn {_scope_key, project_id} -> is_nil(project_id) end)
      |> Map.new()

    active_scope_keys = entries |> Enum.map(& &1.provider_scope_key) |> Enum.reject(&is_nil/1) |> MapSet.new()

    restored =
      restored
      |> Enum.filter(fn {scope_key, _project_id} -> MapSet.member?(active_scope_keys, scope_key) end)
      |> Map.new()

    Map.update(queue, :last_served_by_scope, restored, &Map.merge(restored, &1))
  end

  defp restorable_poll_result?(fact) do
    value(fact, :fact_type) == :poll_result and
      not is_nil(optional_string(fact, :provider_scope_key)) and
      not is_nil(optional_string(fact, :project_id))
  end

  defp next_due_at(_project, nil, _poll_interval_ms, now), do: now

  defp next_due_at(_project, last_poll, poll_interval_ms, _now) do
    normalize_datetime(value(last_poll, :next_due_at)) ||
      normalize_datetime(value(last_poll, :backoff_until)) ||
      case normalize_datetime(value(last_poll, :finished_at) || value(last_poll, :recorded_at)) do
        nil -> nil
        finished_at -> DateTime.add(finished_at, poll_interval_ms, :millisecond)
      end
  end

  defp last_poll_for_project(facts, project_id) do
    facts
    |> Enum.filter(&(value(&1, :fact_type) == :poll_result and optional_string(&1, :project_id) == project_id))
    |> Enum.max_by(&unix_time(value(&1, :finished_at) || value(&1, :recorded_at)), fn -> nil end)
  end

  defp registry_summary(registry, projects) do
    %{
      project_count: length(projects),
      warning_count: registry |> list_value(:warnings) |> length(),
      error_count: registry |> list_value(:errors) |> length()
    }
  end

  defp workflow_identity(nil), do: %{start_stage: nil, terminal_stages: [], stage_ids: []}

  defp workflow_identity(workflow_summary) do
    %{
      start_stage: optional_string(workflow_summary, :start_stage),
      terminal_stages: workflow_summary |> list_value(:terminal_stages) |> Enum.map(&optional_string/1) |> Enum.reject(&is_nil/1),
      stage_ids: workflow_summary |> list_value(:stage_ids) |> Enum.map(&optional_string/1) |> Enum.reject(&is_nil/1)
    }
  end

  defp tracker_identity(nil), do: %{kind: nil, provider_scope_key: nil, required_labels: []}

  defp tracker_identity(tracker_summary) do
    %{
      kind: optional_string(tracker_summary, :kind),
      provider_scope_key: optional_string(tracker_summary, :provider_scope_key),
      required_labels: tracker_summary |> list_value(:required_labels) |> Enum.map(&optional_string/1) |> Enum.reject(&is_nil/1)
    }
  end

  defp provider_scope(nil), do: nil
  defp provider_scope(tracker_summary), do: sanitize_map(value(tracker_summary, :provider_scope) || %{})

  defp snapshot_version(project) do
    optional_string(project, :snapshot_version) ||
      case {optional_string(project, :project_id), optional_string(project, :fingerprint)} do
        {project_id, fingerprint} when not is_nil(project_id) and not is_nil(fingerprint) -> "hub-project:#{project_id}:#{fingerprint}"
        _other -> nil
      end
  end

  defp normalize_facts(facts) when is_list(facts), do: Enum.map(facts, &normalize_fact/1)
  defp normalize_facts(_facts), do: []

  defp normalize_fact(fact) when is_map(fact) do
    fact_type = normalize_fact_type(value(fact, :fact_type) || value(fact, :type))

    %{
      fact_type: fact_type,
      project_id: optional_string(fact, :project_id),
      provider_scope_key: optional_string(fact, :provider_scope_key),
      provider_kind: optional_string(fact, :provider_kind),
      request_id: optional_string(fact, :request_id),
      logical_key: optional_string(fact, :logical_key),
      attempt_id: optional_string(fact, :attempt_id),
      operation_kind: normalize_operation_kind(value(fact, :operation_kind)),
      config_fingerprint: optional_string(fact, :config_fingerprint),
      snapshot_version: optional_string(fact, :snapshot_version),
      status: normalize_optional_result_status(value(fact, :status)),
      error_class: normalize_output_atom(value(fact, :error_class)),
      retry_after_ms: non_negative_integer(value(fact, :retry_after_ms)),
      backoff_until: normalize_datetime(value(fact, :backoff_until)),
      next_due_at: normalize_datetime(value(fact, :next_due_at)),
      result_summary: sanitize_map(value(fact, :result_summary) || %{}),
      attempted_at: normalize_datetime(value(fact, :attempted_at)),
      finished_at: normalize_datetime(value(fact, :finished_at)),
      recorded_at: normalize_datetime(value(fact, :recorded_at))
    }
  end

  defp normalize_fact(_fact), do: normalize_fact(%{})

  defp entry_snapshot(entry) do
    last_poll = value(entry, :last_poll)

    %{
      project_id: safe_optional_string(entry, :project_id) || "",
      name: safe_optional_string(entry, :name),
      project_status: entry |> value(:project_status) |> normalize_project_status() |> Atom.to_string(),
      config_fingerprint: safe_optional_string(entry, :config_fingerprint),
      snapshot_version: safe_optional_string(entry, :snapshot_version),
      workflow_identity: sanitize_value(value(entry, :workflow_identity) || %{}),
      tracker_identity: sanitize_value(value(entry, :tracker_identity) || %{}),
      provider_scope: sanitize_value(value(entry, :provider_scope) || %{}),
      provider_scope_key: safe_optional_string(entry, :provider_scope_key),
      poll_interval_ms: normalize_positive_integer(value(entry, :poll_interval_ms)) || @default_poll_interval_ms,
      allow_poll: value(entry, :allow_poll) == true,
      eligibility: eligibility_snapshot(value(entry, :eligibility) || %{}),
      next_due_at: entry |> value(:next_due_at) |> iso8601(),
      backoff_until: entry |> value(:backoff_until) |> iso8601(),
      last_poll: last_poll_snapshot(last_poll),
      governance: sanitize_value(value(entry, :governance))
    }
  end

  defp last_poll_snapshot(last_poll) when is_map(last_poll), do: fact_snapshot(last_poll)
  defp last_poll_snapshot(_last_poll), do: nil

  defp eligibility_snapshot(eligibility) do
    %{
      "eligible?" => value(eligibility, :eligible?) == true,
      reason: eligibility |> value(:reason) |> normalize_eligibility_reason() |> Atom.to_string(),
      message: optional_string(eligibility, :message)
    }
  end

  defp fact_snapshot(fact) do
    normalized = normalize_fact(fact)

    %{
      fact_type: Atom.to_string(normalized.fact_type),
      project_id: normalized.project_id,
      provider_scope_key: normalized.provider_scope_key,
      provider_kind: normalized.provider_kind,
      request_id: normalized.request_id,
      logical_key: normalized.logical_key,
      attempt_id: normalized.attempt_id,
      operation_kind: Atom.to_string(normalized.operation_kind),
      config_fingerprint: normalized.config_fingerprint,
      snapshot_version: normalized.snapshot_version,
      status: normalized.status && Atom.to_string(normalized.status),
      error_class: normalized.error_class && Atom.to_string(normalized.error_class),
      retry_after_ms: normalized.retry_after_ms,
      backoff_until: iso8601(normalized.backoff_until),
      next_due_at: iso8601(normalized.next_due_at),
      result_summary: sanitize_value(normalized.result_summary),
      attempted_at: iso8601(normalized.attempted_at),
      finished_at: iso8601(normalized.finished_at),
      recorded_at: iso8601(normalized.recorded_at)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp fact_summary(fact) do
    fact
    |> normalize_fact()
    |> Map.take([:fact_type, :project_id, :provider_scope_key, :request_id, :attempt_id, :operation_kind, :status, :error_class, :backoff_until, :next_due_at, :finished_at, :recorded_at])
  end

  defp request_source(%{governance: %{request: request}}), do: request
  defp request_source(%{"governance" => %{"request" => request}}), do: request
  defp request_source(source), do: source

  defp next_due_at_from_result(finished_at, opts) do
    case normalize_positive_integer(Keyword.get(opts, :poll_interval_ms)) do
      nil -> nil
      poll_interval_ms -> DateTime.add(finished_at, poll_interval_ms, :millisecond)
    end
  end

  defp default_attempt_id(project_id, provider_scope_key, request_id, attempted_at) do
    stable = Enum.join([project_id, provider_scope_key, request_id, iso8601(attempted_at)], "|")
    "poll-attempt:" <> Base.encode16(:crypto.hash(:sha256, stable), case: :lower)
  end

  defp normalize_fact_type(value) when value in @fact_types, do: value

  defp normalize_fact_type(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase() |> String.replace("-", "_")
    Enum.find(@fact_types, :poll_result, &(Atom.to_string(&1) == normalized))
  end

  defp normalize_fact_type(_value), do: :poll_result

  defp normalize_project_status(value) when is_atom(value), do: value

  defp normalize_project_status(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "paused" -> :paused
      "error" -> :error
      "ready" -> :ready
      _other -> :unknown
    end
  end

  defp normalize_project_status(_value), do: :unknown

  defp normalize_operation_kind(nil), do: :candidate_scan
  defp normalize_operation_kind(value) when is_atom(value), do: value

  defp normalize_operation_kind(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "" -> :candidate_scan
      "candidate_scan" -> :candidate_scan
      "manual_refresh" -> :manual_refresh
      "running_reconciliation" -> :running_reconciliation
      other -> String.to_atom(other)
    end
  end

  defp normalize_operation_kind(_value), do: :candidate_scan

  defp normalize_result_status(value) do
    normalize_optional_result_status(value) || :unknown_result
  end

  defp normalize_optional_result_status(nil), do: nil
  defp normalize_optional_result_status(value) when value in @provider_result_statuses, do: value

  defp normalize_optional_result_status(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase() |> String.replace("-", "_")
    Enum.find(@provider_result_statuses, &(Atom.to_string(&1) == normalized))
  end

  defp normalize_optional_result_status(_value), do: :unknown_result

  defp normalize_eligibility_reason(value) when value in @eligibility_reasons, do: value

  defp normalize_eligibility_reason(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase() |> String.replace("-", "_")
    Enum.find(@eligibility_reasons, :provider_unavailable, &(Atom.to_string(&1) == normalized))
  end

  defp normalize_eligibility_reason(_value), do: :provider_unavailable

  defp normalize_backpressure_reason(:backoff), do: :backoff
  defp normalize_backpressure_reason(:rate_limited), do: :rate_limited
  defp normalize_backpressure_reason(:circuit_open), do: :circuit_open
  defp normalize_backpressure_reason(:scope_concurrency), do: :scope_concurrency
  defp normalize_backpressure_reason(_reason), do: :provider_unavailable

  defp normalize_output_atom(nil), do: nil
  defp normalize_output_atom(value) when is_atom(value), do: value

  defp normalize_output_atom(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "" -> nil
      normalized -> String.to_atom(normalized)
    end
  end

  defp normalize_output_atom(_value), do: nil

  defp future?(nil, _now), do: false
  defp future?(%DateTime{} = datetime, %DateTime{} = now), do: DateTime.compare(datetime, now) == :gt
  defp future?(_datetime, _now), do: false

  defp unix_time(value) do
    case normalize_datetime(value) do
      nil -> -1
      datetime -> DateTime.to_unix(datetime, :microsecond)
    end
  end

  defp privacy_diagnostics(value) do
    value
    |> collect_sensitive_paths([])
    |> Enum.map(fn {path, reason} ->
      %{
        level: :error,
        code: :sensitive_poll_coordination_snapshot_field,
        project_id: nil,
        message: "Poll coordination snapshot contains sensitive #{reason} at #{Enum.join(path, ".")}"
      }
    end)
  end

  defp collect_sensitive_paths(%_struct{}, _path), do: []

  defp collect_sensitive_paths(%{} = map, path) do
    Enum.flat_map(map, fn {raw_key, value} ->
      key = raw_key |> normalize_key() |> String.downcase()
      next_path = path ++ [key]

      key_findings =
        if sensitive_key?(key) do
          [{next_path, "field"}]
        else
          []
        end

      key_findings ++ collect_sensitive_paths(value, next_path)
    end)
  end

  defp collect_sensitive_paths(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> collect_sensitive_paths(value, path ++ [Integer.to_string(index)]) end)
  end

  defp collect_sensitive_paths(value, path) when is_binary(value) do
    if sensitive_value?(value) do
      [{path, "value"}]
    else
      []
    end
  end

  defp collect_sensitive_paths(_value, _path), do: []

  defp sanitize_map(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, raw_value} -> sensitive_key?(key) or sensitive_value?(raw_value) end)
    |> Map.new(fn {key, raw_value} -> {normalize_output_key(key), sanitize_value(raw_value)} end)
  end

  defp sanitize_map(_value), do: %{}

  defp sanitize_value(%DateTime{} = value), do: iso8601(value)
  defp sanitize_value(%_struct{} = value), do: value
  defp sanitize_value(value) when is_map(value), do: sanitize_map(value)
  defp sanitize_value(value) when is_list(value), do: value |> Enum.reject(&sensitive_value?/1) |> Enum.map(&sanitize_value/1)
  defp sanitize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_value(value), do: value

  defp sensitive_key?(key) do
    key =
      key
      |> to_string()
      |> String.downcase()

    MapSet.member?(@sensitive_keys, key) or String.contains?(key, ["token", "secret", "credential", "cookie", "prompt", "transcript"])
  end

  defp sensitive_value?(value) when is_binary(value) do
    Enum.any?(@sensitive_value_patterns, &Regex.match?(&1, value))
  end

  defp sensitive_value?(%_struct{}), do: false

  defp sensitive_value?(value) when is_map(value) do
    Enum.any?(value, fn {key, raw_value} -> sensitive_key?(key) or sensitive_value?(raw_value) end)
  end

  defp sensitive_value?(value) when is_list(value), do: Enum.any?(value, &sensitive_value?/1)
  defp sensitive_value?(_value), do: false

  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(%DateTime{} = value), do: value

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp normalize_datetime(_value), do: nil

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp iso8601(value) when is_binary(value) do
    value
    |> normalize_datetime()
    |> case do
      nil -> optional_string(value)
      datetime -> DateTime.to_iso8601(datetime)
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

  defp required_string(map, key), do: optional_string(map, key) || ""
  defp optional_string(map, key), do: map |> value(key) |> optional_string()
  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(_value), do: nil

  defp safe_optional_string(map, key), do: map |> value(key) |> safe_optional_string()

  defp safe_optional_string(value) do
    case optional_string(value) do
      nil -> nil
      string -> if sensitive_value?(string), do: nil, else: string
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _parse_result -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _parse_result -> nil
    end
  end

  defp normalize_positive_integer(_value), do: nil

  defp normalize_output_key(key) when is_atom(key), do: key

  defp normalize_output_key(key) when is_binary(key) do
    if Regex.match?(~r/\A[a-z_][a-zA-Z0-9_]*\z/, key) do
      String.to_atom(key)
    else
      key
    end
  end

  defp normalize_output_key(key), do: key

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)
end
