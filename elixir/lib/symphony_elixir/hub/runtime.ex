defmodule SymphonyElixir.Hub.Runtime do
  @moduledoc """
  Hub runtime skeleton.

  The runtime loads a `HUB.yaml` project registry, builds safe Hub poll and
  device-observability snapshots, can execute a small governed poll tick through
  an injectable provider executor, and exposes them through the same snapshot
  call shape used by the legacy orchestrator. It does not dispatch agents,
  create workspaces, write back to trackers, or replace the legacy single-project
  poll loop.
  """

  use GenServer

  alias SymphonyElixir.Hub.{DeviceObservability, PollCoordinator, ProjectRegistry, ProviderExecutor, ProviderGovernance}

  @env_key :hub_config_file_path
  @poll_fact_limit 200
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  @type state :: %{
          required(:config_path) => Path.t(),
          required(:loaded_at) => DateTime.t(),
          required(:registry) => ProjectRegistry.registry(),
          required(:poll_facts) => [PollCoordinator.fact()],
          required(:provider_queue) => ProviderGovernance.queue(),
          required(:provider_executor) => module() | function(),
          required(:tick) => map(),
          required(:snapshot) => map()
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec set_config_path(Path.t()) :: :ok
  def set_config_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, @env_key, path)
    :ok
  end

  @spec clear_config_path() :: :ok
  def clear_config_path do
    Application.delete_env(:symphony_elixir, @env_key)
    :ok
  end

  @spec config_path() :: Path.t() | nil
  def config_path do
    Application.get_env(:symphony_elixir, @env_key)
  end

  @spec hub_mode?() :: boolean()
  def hub_mode?, do: is_binary(config_path())

  @spec validate_config(Path.t()) :: :ok | {:error, String.t()}
  def validate_config(path) when is_binary(path) do
    case load_registry(path) do
      {:ok, _registry} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh, do: request_refresh(__MODULE__)

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @impl true
  def init(opts) do
    config_path = Keyword.get(opts, :config_path) || config_path()

    with {:ok, config_path} <- normalize_config_path(config_path),
         {:ok, registry} <- load_registry(config_path) do
      loaded_at = DateTime.utc_now()
      provider_queue = ProviderGovernance.new_queue()
      tick = idle_tick(loaded_at)

      {:ok,
       %{
         config_path: config_path,
         loaded_at: loaded_at,
         registry: registry,
         poll_facts: [],
         provider_queue: provider_queue,
         provider_executor: Keyword.get(opts, :provider_executor, ProviderExecutor),
         tick: tick,
         snapshot:
           build_snapshot(config_path, loaded_at, registry,
             now: loaded_at,
             provider_queue: provider_queue,
             tick: tick
           )
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state.snapshot, state}
  end

  def handle_call(:request_refresh, _from, state) do
    requested_at = DateTime.utc_now()

    case load_registry(state.config_path) do
      {:ok, registry} ->
        {state, tick_summary} =
          state
          |> Map.merge(%{loaded_at: requested_at, registry: registry})
          |> run_poll_tick(requested_at)

        {:reply,
         %{
           queued: true,
           coalesced: false,
           requested_at: requested_at,
           operations: ["hub_registry_load", "hub_poll_plan", "hub_provider_candidate_scan", "hub_device_observability"],
           poll_tick: tick_summary
         }, state}

      {:error, message} ->
        {:reply,
         %{
           queued: false,
           coalesced: false,
           requested_at: requested_at,
           operations: ["hub_registry_load"],
           error: %{code: "hub_config_invalid", message: message}
         }, state}
    end
  end

  @spec build_snapshot(Path.t(), DateTime.t(), ProjectRegistry.registry()) :: map()
  def build_snapshot(config_path, loaded_at, registry) when is_binary(config_path) and is_map(registry) do
    build_snapshot(config_path, loaded_at, registry, [])
  end

  @spec build_snapshot(Path.t(), DateTime.t(), ProjectRegistry.registry(), keyword()) :: map()
  def build_snapshot(config_path, loaded_at, registry, opts)
      when is_binary(config_path) and is_map(registry) and is_list(opts) do
    generated_at = DateTime.utc_now()
    now = Keyword.get(opts, :now, generated_at)
    provider_queue = Keyword.get(opts, :provider_queue, ProviderGovernance.new_queue())
    poll_facts = Keyword.get(opts, :poll_facts, [])
    tick = normalize_tick(Keyword.get(opts, :tick))
    poll_plan = PollCoordinator.build_plan(registry, now: now, facts: poll_facts, queue: provider_queue)

    device_observability =
      DeviceObservability.build(
        %{
          registry: registry,
          poll_coordination: poll_plan,
          migration_boundary: migration_boundary()
        },
        now: now
      )

    counts = counts(registry, device_observability)
    registry_summary = registry_summary(registry)

    %{
      running: [],
      retrying: [],
      blocked: [],
      codex_totals: @empty_codex_totals,
      rate_limits: nil,
      polling: %{
        checking?: false,
        next_poll_in_ms: nil,
        poll_interval_ms: nil
      },
      hub_runtime: %{
        mode: "hub",
        read_only: Keyword.get(opts, :read_only, false),
        poll_tick_execution: true,
        config_path: config_path,
        loaded_at: iso8601(loaded_at),
        generated_at: iso8601(now),
        counts: counts,
        poll_tick: tick,
        migration_boundary: migration_boundary(),
        registry: registry_summary
      },
      hub_project_registry: registry_summary,
      hub_poll_coordination: poll_plan,
      hub_device_observability: device_observability
    }
  end

  defp normalize_config_path(path) when is_binary(path) do
    case String.trim(path) do
      "" -> {:error, "Hub config path must not be blank"}
      trimmed -> {:ok, Path.expand(trimmed)}
    end
  end

  defp normalize_config_path(_path), do: {:error, "Hub config path is required"}

  defp load_registry(path) do
    with {:ok, path} <- normalize_config_path(path),
         {:ok, registry} <- ProjectRegistry.load(path),
         :ok <- require_projects(registry),
         :ok <- reject_registry_errors(registry) do
      {:ok, registry}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, format_hub_error(reason)}
    end
  end

  defp run_poll_tick(state, requested_at) do
    started_tick = running_tick(requested_at)

    plan =
      PollCoordinator.build_plan(state.registry,
        now: requested_at,
        facts: state.poll_facts,
        queue: state.provider_queue
      )

    executable_entries = Enum.filter(plan.projects, &(&1.allow_poll == true))

    {poll_facts, provider_queue, result_summaries} =
      Enum.reduce(executable_entries, {state.poll_facts, state.provider_queue, []}, fn entry, {facts, queue, summaries} ->
        attempt = PollCoordinator.attempt_fact(entry, attempted_at: requested_at)
        request = request_from_entry(entry)

        {result, queue} =
          request
          |> execute_provider_request(state.provider_executor, requested_at)
          |> normalize_provider_result(request, queue)

        finished_at = DateTime.utc_now()

        result_fact =
          PollCoordinator.result_fact(entry, result,
            attempt_id: attempt.attempt_id,
            finished_at: finished_at,
            poll_interval_ms: entry.poll_interval_ms,
            retry_after_ms: result.retry_after_ms,
            backoff_until: result.backoff_until
          )

        facts = trim_poll_facts([result_fact, attempt | facts])
        summary = poll_result_summary(result, attempt, result_fact, finished_at)

        {facts, queue, [summary | summaries]}
      end)

    finished_at = DateTime.utc_now()
    tick = finished_tick(started_tick, finished_at, length(executable_entries), result_summaries)

    snapshot =
      build_snapshot(state.config_path, state.loaded_at, state.registry,
        now: finished_at,
        poll_facts: poll_facts,
        provider_queue: provider_queue,
        tick: tick
      )

    state = %{state | poll_facts: poll_facts, provider_queue: provider_queue, tick: tick, snapshot: snapshot}

    {state, tick}
  end

  defp execute_provider_request(nil, _executor, _started_at) do
    {:error, :missing_provider_request}
  end

  defp execute_provider_request(request, executor, started_at) when is_function(executor, 2) do
    executor.(request, started_at: started_at)
  end

  defp execute_provider_request(request, executor, started_at) when is_atom(executor) do
    executor.execute(request, started_at: started_at)
  end

  defp execute_provider_request(_request, _executor, _started_at) do
    {:error, :invalid_provider_executor}
  end

  defp normalize_provider_result({:ok, result}, request, queue), do: normalize_provider_result(result, request, queue)

  defp normalize_provider_result({:error, reason}, request, queue) do
    result =
      ProviderGovernance.result(request, :retryable_failure,
        error_class: :unknown,
        backoff_until: DateTime.utc_now() |> DateTime.add(30_000, :millisecond),
        result_summary: %{error: safe_error(reason)}
      )

    queue = record_provider_result(queue, request, result)
    {result, queue}
  end

  defp normalize_provider_result(result, request, queue) when is_map(result) do
    queue = record_provider_result(queue, request, result)
    {result, queue}
  end

  defp normalize_provider_result(_result, request, queue) do
    normalize_provider_result({:error, :invalid_provider_result}, request, queue)
  end

  defp record_provider_result(queue, request, result) do
    queue
    |> ensure_running_request(request)
    |> ProviderGovernance.record_result(result)
    |> update_scope_from_result(request, result)
  end

  defp ensure_running_request(queue, nil), do: queue

  defp ensure_running_request(queue, request) do
    already_running? = Enum.any?(queue.running, &(&1.request_id == request.request_id))

    if already_running? do
      queue
    else
      Map.update!(queue, :running, &(&1 ++ [request]))
    end
  end

  defp update_scope_from_result(queue, request, result) do
    attrs =
      %{
        backoff_until: result.backoff_until,
        circuit_state: circuit_state_for_result(result.status),
        last_error_class: result.error_class,
        updated_at: DateTime.utc_now()
      }
      |> maybe_put_quota(result)

    ProviderGovernance.update_scope_state(queue, request, attrs)
  end

  defp maybe_put_quota(attrs, %{status: :rate_limited}) do
    Map.put(attrs, :quota, %{remaining: 0})
  end

  defp maybe_put_quota(attrs, _result), do: attrs

  defp circuit_state_for_result(:circuit_open), do: :open
  defp circuit_state_for_result(_status), do: :closed

  defp request_from_entry(%{governance: %{request: request}}) when is_map(request) do
    request_from_snapshot(request)
  end

  defp request_from_entry(_entry), do: nil

  defp request_from_snapshot(request) do
    provider_scope =
      %{
        kind: value(request, :provider_kind),
        key: value(request, :provider_scope_key),
        scope: value(request, :provider_scope) || %{}
      }

    attrs =
      %{
        project_id: value(request, :project_id),
        provider_scope: provider_scope,
        config_fingerprint: value(request, :config_fingerprint),
        snapshot_version: value(request, :snapshot_version),
        issue_ref: value(request, :issue_ref),
        operation_kind: value(request, :operation_kind),
        logical_key: value(request, :logical_key),
        fairness_key: value(request, :fairness_key),
        replay_policy: value(request, :replay_policy),
        timeout_ms: value(request, :timeout_ms),
        deadline_at: value(request, :deadline_at),
        correlation: value(request, :correlation) || %{},
        user_initiated: value(request, :user_initiated),
        enqueued_at: value(request, :enqueued_at)
      }

    case ProviderGovernance.new_request(attrs) do
      {:ok, request} -> request
      {:error, _reason} -> nil
    end
  end

  defp poll_result_summary(result, attempt, result_fact, finished_at) do
    %{
      project_id: result.project_id,
      provider_scope_key: result.provider_scope_key,
      request_id: result.request_id,
      logical_key: result.logical_key,
      attempt_id: attempt.attempt_id,
      status: status_string(result.status),
      error_class: status_string(result.error_class),
      retry_after_ms: result.retry_after_ms,
      backoff_until: iso8601(result.backoff_until),
      next_due_at: iso8601(result_fact.next_due_at),
      finished_at: iso8601(finished_at)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp trim_poll_facts(facts) do
    Enum.take(facts, @poll_fact_limit)
  end

  defp idle_tick(now) do
    %{
      status: "idle",
      running?: false,
      started_at: nil,
      finished_at: nil,
      selected_count: 0,
      result_counts: %{},
      results: [],
      updated_at: iso8601(now)
    }
  end

  defp running_tick(started_at) do
    %{
      status: "running",
      running?: true,
      started_at: iso8601(started_at),
      finished_at: nil,
      selected_count: 0,
      result_counts: %{},
      results: [],
      updated_at: iso8601(started_at)
    }
  end

  defp finished_tick(started_tick, finished_at, selected_count, result_summaries) do
    results = Enum.reverse(result_summaries)

    %{
      status: "completed",
      running?: false,
      started_at: started_tick.started_at,
      finished_at: iso8601(finished_at),
      selected_count: selected_count,
      result_counts: result_counts(results),
      results: results,
      updated_at: iso8601(finished_at)
    }
  end

  defp normalize_tick(nil), do: idle_tick(DateTime.utc_now())

  defp normalize_tick(tick) when is_map(tick) do
    %{
      status: status_string(Map.get(tick, :status) || Map.get(tick, "status") || "idle"),
      running?: Map.get(tick, :running?) || Map.get(tick, "running?") || false,
      started_at: Map.get(tick, :started_at) || Map.get(tick, "started_at"),
      finished_at: Map.get(tick, :finished_at) || Map.get(tick, "finished_at"),
      selected_count: Map.get(tick, :selected_count) || Map.get(tick, "selected_count") || 0,
      result_counts: Map.get(tick, :result_counts) || Map.get(tick, "result_counts") || %{},
      results: Map.get(tick, :results) || Map.get(tick, "results") || [],
      updated_at: Map.get(tick, :updated_at) || Map.get(tick, "updated_at")
    }
  end

  defp result_counts(results) do
    Enum.reduce(results, %{}, fn result, counts ->
      status = Map.get(result, :status) || Map.get(result, "status") || "unknown_result"
      Map.update(counts, status, 1, &(&1 + 1))
    end)
  end

  defp safe_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
  defp safe_error(reason), do: inspect(reason, limit: 5, printable_limit: 200)

  defp value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, nil} -> Map.get(map, Atom.to_string(key))
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key)

  defp require_projects(%{projects: projects}) when is_list(projects) and projects != [], do: :ok
  defp require_projects(_registry), do: {:error, "Hub config must define at least one project"}

  defp reject_registry_errors(%{errors: []}), do: :ok

  defp reject_registry_errors(%{errors: errors}) when is_list(errors) do
    {:error, Enum.map_join(errors, "; ", &validation_message/1)}
  end

  defp validation_message(%{message: message}) when is_binary(message), do: message
  defp validation_message(message), do: inspect(message)

  defp format_hub_error(:hub_config_empty), do: "Hub config must not be empty"
  defp format_hub_error(:hub_config_not_a_map), do: "Hub config must decode to a map"
  defp format_hub_error(:hub_projects_must_be_a_list), do: "Hub config projects must be a list"
  defp format_hub_error({:missing_hub_config_file, path, reason}), do: "Hub config file not found: #{path} (#{inspect(reason)})"
  defp format_hub_error({:hub_config_parse_error, reason}), do: "Failed to parse Hub config: #{inspect(reason)}"
  defp format_hub_error({:duplicate_project_id, project_id, indexes}), do: "Duplicate Hub project_id #{inspect(project_id)} at indexes #{inspect(indexes)}"
  defp format_hub_error({:invalid_project_id, project_id, message}), do: "Invalid Hub project_id #{inspect(project_id)}: #{message}"
  defp format_hub_error({:invalid_hub_project, index, message}), do: "Invalid Hub project #{inspect(index)}: #{message}"
  defp format_hub_error(reason), do: "Invalid Hub config: #{inspect(reason)}"

  defp counts(registry, device_observability) do
    projects = Map.get(registry, :projects, [])

    %{
      project_count: length(projects),
      ready_project_count: Enum.count(projects, &(&1.status == :ready)),
      paused_project_count: Enum.count(projects, &(&1.paused == true and &1.status != :error)),
      config_error_count: Enum.count(projects, &(&1.status == :error)),
      active_agent_count: get_in(device_observability, [:device, :active_agent_count]) || 0,
      provider_scope_count: get_in(device_observability, [:device, :provider_scopes_count]) || 0,
      max_agent_capacity: get_in(device_observability, [:device, :max_agent_capacity]),
      registry_warning_count: length(Map.get(registry, :warnings, [])),
      registry_error_count: length(Map.get(registry, :errors, []))
    }
  end

  defp registry_summary(registry) do
    projects = Map.get(registry, :projects, [])

    %{
      project_count: length(projects),
      warning_count: length(Map.get(registry, :warnings, [])),
      error_count: length(Map.get(registry, :errors, [])),
      warnings: Enum.map(Map.get(registry, :warnings, []), &validation_snapshot/1),
      errors: Enum.map(Map.get(registry, :errors, []), &validation_snapshot/1),
      projects: Enum.map(projects, &project_summary/1)
    }
  end

  defp project_summary(project) do
    tracker_summary = Map.get(project, :tracker_summary) || %{}
    runtime_summary = Map.get(project, :runtime_summary) || %{}

    %{
      project_id: Map.get(project, :project_id),
      name: Map.get(project, :name),
      dispatch_enabled: Map.get(project, :dispatch_enabled) == true,
      paused: Map.get(project, :paused) == true,
      status: project |> Map.get(:status) |> status_string(),
      workflow_path: Map.get(project, :workflow_path),
      tracker_config_path: Map.get(project, :tracker_config_path),
      tracker_kind: Map.get(tracker_summary, :kind),
      provider_scope_key: Map.get(tracker_summary, :provider_scope_key),
      workspace_root: Map.get(runtime_summary, :workspace_root),
      polling_interval_ms: Map.get(runtime_summary, :polling_interval_ms),
      server_port: Map.get(runtime_summary, :server_port),
      fingerprint: Map.get(project, :fingerprint),
      loaded_at: iso8601(Map.get(project, :loaded_at)),
      load_error: Map.get(project, :load_error)
    }
  end

  defp validation_snapshot(message) when is_map(message) do
    %{
      level: status_string(Map.get(message, :level)),
      code: status_string(Map.get(message, :code)),
      project_ids: Map.get(message, :project_ids, []),
      message: Map.get(message, :message)
    }
  end

  defp validation_snapshot(message), do: %{message: inspect(message)}

  defp migration_boundary do
    %{
      legacy_service: "symphony@project.service",
      legacy_default_path: "direct_poll_and_writeback",
      hub_projection_model_only: false,
      hub_read_only_runtime_skeleton: false,
      hub_poll_tick_skeleton: true,
      hub_takes_over_legacy_poll_loop: false,
      hub_routing_requires_opt_in: true,
      direct_path_capabilities: ["legacy_poll_loop", "legacy_direct_writeback", "legacy_agent_dispatch"],
      opt_in_hub_capabilities: ["project_registry", "poll_plan_snapshot", "provider_candidate_scan_request", "poll_result_snapshot", "device_observability_snapshot"]
    }
  end

  defp status_string(nil), do: nil
  defp status_string(value) when is_atom(value), do: Atom.to_string(value)
  defp status_string(value) when is_binary(value), do: value
  defp status_string(value), do: to_string(value)

  defp iso8601(%DateTime{} = datetime), do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_value), do: nil
end
