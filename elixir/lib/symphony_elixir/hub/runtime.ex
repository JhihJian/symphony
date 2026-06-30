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

  alias SymphonyElixir.Hub.{
    CandidateIntake,
    DeviceObservability,
    DispatchPlanApplication,
    DispatchPlanning,
    PollCoordinator,
    ProjectRegistry,
    ProviderExecutor,
    ProviderGovernance,
    RealCandidateScanExecutor,
    RuntimeLedger,
    WorkerLifecycleReconciliation,
    WorkerStartHandoff
  }

  @env_key :hub_config_file_path
  @scheduler_env_key :hub_scheduler_enabled
  @provider_executor_env_key :hub_provider_executor
  @worker_start_starter_env_key :hub_worker_start_starter
  @worker_lifecycle_result_source_env_key :hub_worker_lifecycle_result_source
  @poll_fact_limit 200
  @scheduler_min_delay_ms 10
  @scheduler_unresolved_delay_ms 1_000
  @scheduler_error_backoff_ms 30_000
  @scheduler_default_delay_ms 30_000
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
          required(:worker_start_starter) => WorkerStartHandoff.starter(),
          required(:worker_lifecycle_result_source) => WorkerLifecycleReconciliation.result_source(),
          required(:runtime_ledger) => RuntimeLedger.ledger(),
          required(:candidate_intake) => map(),
          required(:dispatch_planning) => map(),
          required(:dispatch_plan_application) => map(),
          required(:worker_start_handoff) => map(),
          required(:worker_lifecycle_reconciliation) => map(),
          required(:tick) => map(),
          required(:scheduler) => map(),
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

  @spec set_scheduler_enabled(boolean()) :: :ok
  def set_scheduler_enabled(enabled?) when is_boolean(enabled?) do
    Application.put_env(:symphony_elixir, @scheduler_env_key, enabled?)
    :ok
  end

  @spec clear_scheduler_enabled() :: :ok
  def clear_scheduler_enabled do
    Application.delete_env(:symphony_elixir, @scheduler_env_key)
    :ok
  end

  @spec set_provider_executor(module() | function() | nil) :: :ok
  def set_provider_executor(executor) when is_atom(executor) or is_function(executor, 2) or is_nil(executor) do
    Application.put_env(:symphony_elixir, @provider_executor_env_key, executor)
    :ok
  end

  @spec clear_provider_executor() :: :ok
  def clear_provider_executor do
    Application.delete_env(:symphony_elixir, @provider_executor_env_key)
    :ok
  end

  @spec set_worker_start_starter(WorkerStartHandoff.starter()) :: :ok
  def set_worker_start_starter(starter) when is_atom(starter) or is_function(starter, 2) or is_nil(starter) do
    Application.put_env(:symphony_elixir, @worker_start_starter_env_key, starter)
    :ok
  end

  @spec clear_worker_start_starter() :: :ok
  def clear_worker_start_starter do
    Application.delete_env(:symphony_elixir, @worker_start_starter_env_key)
    :ok
  end

  @spec set_worker_lifecycle_result_source(WorkerLifecycleReconciliation.result_source()) :: :ok
  def set_worker_lifecycle_result_source(source) when is_atom(source) or is_function(source, 2) or is_nil(source) do
    Application.put_env(:symphony_elixir, @worker_lifecycle_result_source_env_key, source)
    :ok
  end

  @spec clear_worker_lifecycle_result_source() :: :ok
  def clear_worker_lifecycle_result_source do
    Application.delete_env(:symphony_elixir, @worker_lifecycle_result_source_env_key)
    :ok
  end

  @spec worker_lifecycle_result_source() :: WorkerLifecycleReconciliation.result_source()
  def worker_lifecycle_result_source do
    Application.get_env(:symphony_elixir, @worker_lifecycle_result_source_env_key)
  end

  @spec provider_executor() :: module() | function()
  def provider_executor do
    case Application.get_env(:symphony_elixir, @provider_executor_env_key) do
      nil -> ProviderExecutor
      executor when is_atom(executor) or is_function(executor, 2) -> executor
      _invalid -> ProviderExecutor
    end
  end

  @spec worker_start_starter() :: WorkerStartHandoff.starter()
  def worker_start_starter do
    Application.get_env(:symphony_elixir, @worker_start_starter_env_key)
  end

  @spec config_path() :: Path.t() | nil
  def config_path do
    Application.get_env(:symphony_elixir, @env_key)
  end

  @spec scheduler_enabled?() :: boolean()
  def scheduler_enabled? do
    Application.get_env(:symphony_elixir, @scheduler_env_key, false) == true
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
      runtime_ledger = opts |> Keyword.get(:runtime_ledger, RuntimeLedger.new()) |> RuntimeLedger.to_snapshot()
      candidate_intake = CandidateIntake.empty(registry, now: loaded_at, runtime_ledger: runtime_ledger)
      dispatch_planning = DispatchPlanning.empty(registry, now: loaded_at, runtime_ledger: runtime_ledger, candidate_intake: candidate_intake)

      dispatch_plan_application =
        DispatchPlanApplication.empty(registry,
          now: loaded_at,
          runtime_ledger: runtime_ledger,
          dispatch_planning: dispatch_planning
        )

      worker_start_handoff =
        WorkerStartHandoff.empty(registry,
          now: loaded_at,
          runtime_ledger: runtime_ledger
        )

      worker_lifecycle_reconciliation =
        WorkerLifecycleReconciliation.empty(registry,
          now: loaded_at,
          runtime_ledger: runtime_ledger
        )

      tick = idle_tick(loaded_at)
      scheduler = new_scheduler(Keyword.get(opts, :scheduler_enabled, scheduler_enabled?()), loaded_at)
      provider_executor = Keyword.get(opts, :provider_executor, provider_executor())

      initial_snapshot =
        build_snapshot(config_path, loaded_at, registry,
          now: loaded_at,
          provider_queue: provider_queue,
          provider_executor: provider_executor,
          runtime_ledger: runtime_ledger,
          candidate_intake: candidate_intake,
          dispatch_planning: dispatch_planning,
          dispatch_plan_application: dispatch_plan_application,
          worker_start_handoff: worker_start_handoff,
          worker_lifecycle_reconciliation: worker_lifecycle_reconciliation,
          tick: tick,
          scheduler: scheduler
        )

      state = %{
        config_path: config_path,
        loaded_at: loaded_at,
        registry: registry,
        poll_facts: [],
        provider_queue: provider_queue,
        provider_executor: provider_executor,
        worker_start_starter: Keyword.get(opts, :worker_start_starter, worker_start_starter()),
        worker_lifecycle_result_source: Keyword.get(opts, :worker_lifecycle_result_source, worker_lifecycle_result_source()),
        runtime_ledger: runtime_ledger,
        candidate_intake: candidate_intake,
        dispatch_planning: dispatch_planning,
        dispatch_plan_application: dispatch_plan_application,
        worker_start_handoff: worker_start_handoff,
        worker_lifecycle_reconciliation: worker_lifecycle_reconciliation,
        tick: tick,
        scheduler: scheduler,
        snapshot: initial_snapshot
      }

      state =
        if scheduler.enabled do
          schedule_next_tick(state, loaded_at, "startup", 0)
        else
          state
        end

      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state.snapshot, state}
  end

  @impl true
  def handle_call(:request_refresh, _from, state) do
    requested_at = DateTime.utc_now()

    if state.scheduler.enabled do
      {state, reply} = request_scheduled_refresh(state, requested_at)
      {:reply, reply, state}
    else
      run_manual_refresh(state, requested_at)
    end
  end

  @impl true
  def handle_info({:hub_scheduler_tick, token}, state) do
    if state.scheduler.enabled and token == state.scheduler.timer_token do
      requested_at = DateTime.utc_now()
      state = %{state | scheduler: %{state.scheduler | timer_ref: nil, timer_token: nil, tick_queued?: false}}
      state = start_async_tick(state, requested_at, state.scheduler.next_reason || "scheduled")
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, {:hub_scheduler_tick_result, result}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    state =
      if ref == state.scheduler.running_ref do
        finish_async_tick(state, result)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    state =
      if ref == state.scheduler.running_ref do
        now = DateTime.utc_now()

        scheduler =
          state.scheduler
          |> Map.merge(%{
            status: "failed",
            running?: false,
            running_ref: nil,
            running_started_at: nil,
            last_error: safe_error(reason),
            last_finished_at: now,
            last_duration_ms: scheduler_duration_ms(state.scheduler.running_started_at, now),
            error_count: state.scheduler.error_count + 1
          })

        state
        |> Map.put(:scheduler, scheduler)
        |> refresh_snapshot(now)
        |> schedule_next_tick(now, "error_backoff", @scheduler_error_backoff_ms)
      else
        state
      end

    {:noreply, state}
  end

  defp run_manual_refresh(state, requested_at) do
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
           operations: [
             "hub_registry_load",
             "hub_poll_plan",
             "hub_provider_candidate_scan",
             "hub_candidate_intake",
             "hub_dispatch_planning",
             "hub_dispatch_plan_application",
             "hub_worker_start_handoff",
             "hub_worker_lifecycle_reconciliation",
             "hub_device_observability"
           ],
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
    provider_executor = Keyword.get(opts, :provider_executor, ProviderExecutor)
    tick = normalize_tick(Keyword.get(opts, :tick))
    runtime_ledger = Keyword.get(opts, :runtime_ledger, RuntimeLedger.new()) |> RuntimeLedger.to_snapshot()
    candidate_intake = Keyword.get(opts, :candidate_intake, CandidateIntake.empty(registry, now: now, runtime_ledger: runtime_ledger))

    dispatch_planning =
      Keyword.get(
        opts,
        :dispatch_planning,
        DispatchPlanning.empty(registry, now: now, runtime_ledger: runtime_ledger, candidate_intake: candidate_intake)
      )

    dispatch_plan_application =
      Keyword.get(
        opts,
        :dispatch_plan_application,
        DispatchPlanApplication.empty(registry,
          now: now,
          runtime_ledger: runtime_ledger,
          dispatch_planning: dispatch_planning
        )
      )

    worker_start_handoff =
      Keyword.get(opts, :worker_start_handoff, WorkerStartHandoff.empty(registry, now: now, runtime_ledger: runtime_ledger))

    worker_lifecycle_reconciliation =
      Keyword.get(
        opts,
        :worker_lifecycle_reconciliation,
        WorkerLifecycleReconciliation.empty(registry, now: now, runtime_ledger: runtime_ledger)
      )

    poll_plan = PollCoordinator.build_plan(registry, now: now, facts: poll_facts, queue: provider_queue)

    device_observability =
      DeviceObservability.build(
        %{
          registry: registry,
          poll_coordination: poll_plan,
          runtime_ledger: runtime_ledger,
          worker_lifecycle_reconciliation: worker_lifecycle_reconciliation,
          migration_boundary: migration_boundary()
        },
        now: now
      )

    counts = counts(registry, device_observability)
    registry_summary = registry_summary(registry)
    scheduler = normalize_scheduler(Keyword.get(opts, :scheduler), poll_plan, runtime_ledger, worker_start_handoff, worker_lifecycle_reconciliation, now)

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
        provider_executor: provider_executor_summary(provider_executor),
        scheduler: scheduler,
        poll_tick: tick,
        candidate_intake: CandidateIntake.tick_summary(candidate_intake),
        dispatch_planning: DispatchPlanning.tick_summary(dispatch_planning),
        dispatch_plan_application: DispatchPlanApplication.tick_summary(dispatch_plan_application),
        worker_start_handoff: WorkerStartHandoff.tick_summary(worker_start_handoff),
        worker_lifecycle_reconciliation: WorkerLifecycleReconciliation.tick_summary(worker_lifecycle_reconciliation),
        migration_boundary: migration_boundary(),
        registry: registry_summary
      },
      hub_scheduler: scheduler,
      hub_project_registry: registry_summary,
      hub_poll_coordination: poll_plan,
      hub_candidate_intake: candidate_intake,
      hub_dispatch_planning: dispatch_planning,
      hub_dispatch_plan_application: dispatch_plan_application,
      hub_worker_start_handoff: worker_start_handoff,
      hub_worker_lifecycle_reconciliation: worker_lifecycle_reconciliation,
      hub_dispatch_boundary: runtime_ledger,
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

    {poll_facts, provider_queue, result_summaries, intake_sources} =
      Enum.reduce(executable_entries, {state.poll_facts, state.provider_queue, [], []}, fn entry, {facts, queue, summaries, intake_sources} ->
        attempt = PollCoordinator.attempt_fact(entry, attempted_at: requested_at)
        request = request_from_entry(entry)

        {result, queue} =
          request
          |> execute_provider_request(state.provider_executor, requested_at, state.registry, state.config_path)
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
        intake_source = poll_intake_source(entry, request, result, attempt, result_fact, finished_at)

        {facts, queue, [summary | summaries], [intake_source | intake_sources]}
      end)

    finished_at = DateTime.utc_now()

    candidate_intake =
      CandidateIntake.build(state.registry, Enum.reverse(intake_sources),
        now: finished_at,
        runtime_ledger: state.runtime_ledger
      )

    dispatch_planning =
      DispatchPlanning.build(state.registry, candidate_intake,
        now: finished_at,
        runtime_ledger: state.runtime_ledger,
        previous_plan: state.dispatch_planning
      )

    {runtime_ledger, dispatch_plan_application} =
      DispatchPlanApplication.apply_plan(state.registry, dispatch_planning, state.runtime_ledger, now: finished_at)

    {runtime_ledger, worker_start_handoff} =
      WorkerStartHandoff.run(state.registry, runtime_ledger,
        now: finished_at,
        starter: state.worker_start_starter
      )

    {runtime_ledger, worker_lifecycle_reconciliation} =
      WorkerLifecycleReconciliation.run(state.registry, runtime_ledger,
        now: finished_at,
        result_source: state.worker_lifecycle_result_source
      )

    candidate_intake =
      CandidateIntake.build(state.registry, Enum.reverse(intake_sources),
        now: finished_at,
        runtime_ledger: runtime_ledger
      )

    dispatch_planning =
      DispatchPlanning.build(state.registry, candidate_intake,
        now: finished_at,
        runtime_ledger: runtime_ledger,
        previous_plan: dispatch_planning
      )

    tick =
      finished_tick(
        started_tick,
        finished_at,
        length(executable_entries),
        result_summaries,
        candidate_intake,
        dispatch_planning,
        dispatch_plan_application,
        worker_start_handoff,
        worker_lifecycle_reconciliation
      )

    snapshot =
      build_snapshot(state.config_path, state.loaded_at, state.registry,
        now: finished_at,
        poll_facts: poll_facts,
        provider_queue: provider_queue,
        provider_executor: state.provider_executor,
        runtime_ledger: runtime_ledger,
        candidate_intake: candidate_intake,
        dispatch_planning: dispatch_planning,
        dispatch_plan_application: dispatch_plan_application,
        worker_start_handoff: worker_start_handoff,
        worker_lifecycle_reconciliation: worker_lifecycle_reconciliation,
        tick: tick,
        scheduler: state.scheduler
      )

    state = %{
      state
      | poll_facts: poll_facts,
        provider_queue: provider_queue,
        runtime_ledger: runtime_ledger,
        candidate_intake: candidate_intake,
        dispatch_planning: dispatch_planning,
        dispatch_plan_application: dispatch_plan_application,
        worker_start_handoff: worker_start_handoff,
        worker_lifecycle_reconciliation: worker_lifecycle_reconciliation,
        tick: tick,
        snapshot: snapshot
    }

    {state, tick}
  end

  defp request_scheduled_refresh(state, requested_at) do
    cond do
      state.scheduler.running? ->
        scheduler =
          state.scheduler
          |> Map.merge(%{
            status: "coalesced",
            manual_refresh_requested_at: requested_at,
            coalesced?: true,
            coalesced_count: state.scheduler.coalesced_count + 1
          })

        state = state |> Map.put(:scheduler, scheduler) |> refresh_snapshot(requested_at)
        {state, scheduler_reply(state, requested_at, true)}

      state.scheduler.tick_queued? ->
        scheduler =
          state.scheduler
          |> Map.merge(%{
            status: "coalesced",
            manual_refresh_requested_at: requested_at,
            coalesced?: true,
            coalesced_count: state.scheduler.coalesced_count + 1
          })

        state = state |> Map.put(:scheduler, scheduler) |> refresh_snapshot(requested_at)
        {state, scheduler_reply(state, requested_at, true)}

      true ->
        state = schedule_next_tick(state, requested_at, "manual_refresh", 0)
        {state, scheduler_reply(state, requested_at, false)}
    end
  end

  defp scheduler_reply(state, requested_at, coalesced?) do
    %{
      queued: true,
      coalesced: coalesced?,
      requested_at: requested_at,
      next_tick_at: state.scheduler.next_tick_at,
      scheduler: scheduler_observability(state.scheduler),
      operations: [
        "hub_scheduler_queue",
        "hub_registry_load",
        "hub_poll_plan",
        "hub_provider_candidate_scan",
        "hub_candidate_intake",
        "hub_dispatch_planning",
        "hub_dispatch_plan_application",
        "hub_worker_start_handoff",
        "hub_worker_lifecycle_reconciliation",
        "hub_device_observability"
      ]
    }
  end

  defp start_async_tick(state, requested_at, reason) do
    scheduler =
      state.scheduler
      |> Map.merge(%{
        status: "running",
        running?: true,
        running_started_at: requested_at,
        running_ref: nil,
        last_reason: reason,
        last_started_at: requested_at,
        requested_at: requested_at,
        tick_queued?: false,
        coalesced?: false,
        next_tick_at: nil,
        next_delay_ms: nil,
        next_reason: nil,
        run_count: state.scheduler.run_count + 1
      })

    state = state |> Map.put(:scheduler, scheduler) |> refresh_snapshot(requested_at)

    task =
      Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        result = run_async_tick(state, requested_at)
        {:hub_scheduler_tick_result, result}
      end)

    scheduler = %{state.scheduler | running_ref: task.ref}
    state |> Map.put(:scheduler, scheduler) |> refresh_snapshot(requested_at)
  end

  defp run_async_tick(state, requested_at) do
    case load_registry(state.config_path) do
      {:ok, registry} ->
        state
        |> Map.merge(%{loaded_at: requested_at, registry: registry})
        |> run_poll_tick(requested_at)
        |> then(fn {state, tick_summary} -> {:ok, state, tick_summary} end)

      {:error, message} ->
        {:error, message}
    end
  rescue
    error in [ArgumentError, RuntimeError] ->
      {:error, Exception.message(error)}
  catch
    kind, reason ->
      {:error, "#{kind}: #{safe_error(reason)}"}
  end

  defp finish_async_tick(state, {:ok, tick_state, tick_summary}) do
    finished_at = DateTime.utc_now()
    {next_delay_ms, next_reason} = next_schedule_delay(tick_state, finished_at)

    scheduler =
      state.scheduler
      |> Map.merge(%{
        status: "idle",
        running?: false,
        running_ref: nil,
        running_started_at: nil,
        last_finished_at: finished_at,
        last_duration_ms: scheduler_duration_ms(state.scheduler.running_started_at, finished_at),
        last_error: nil,
        last_operations: Map.get(tick_summary, :operations, tick_operations()),
        project_summaries: scheduler_project_summaries(tick_state, finished_at)
      })

    tick_state
    |> Map.put(:scheduler, scheduler)
    |> refresh_snapshot(finished_at)
    |> schedule_next_tick(finished_at, next_reason, next_delay_ms)
  end

  defp finish_async_tick(state, {:error, message}) do
    finished_at = DateTime.utc_now()

    scheduler =
      state.scheduler
      |> Map.merge(%{
        status: "failed",
        running?: false,
        running_ref: nil,
        running_started_at: nil,
        last_finished_at: finished_at,
        last_duration_ms: scheduler_duration_ms(state.scheduler.running_started_at, finished_at),
        last_error: safe_error(message),
        error_count: state.scheduler.error_count + 1
      })

    state
    |> Map.put(:scheduler, scheduler)
    |> refresh_snapshot(finished_at)
    |> schedule_next_tick(finished_at, "error_backoff", @scheduler_error_backoff_ms)
  end

  defp schedule_next_tick(state, now, reason, delay_ms) do
    timer_token = make_ref()
    delay_ms = normalize_delay_ms(delay_ms)
    next_tick_at = DateTime.add(now, delay_ms, :millisecond)
    timer_ref = Process.send_after(self(), {:hub_scheduler_tick, timer_token}, delay_ms)

    scheduler =
      state.scheduler
      |> Map.merge(%{
        status: "scheduled",
        tick_queued?: true,
        timer_ref: timer_ref,
        timer_token: timer_token,
        next_tick_at: next_tick_at,
        next_delay_ms: delay_ms,
        next_reason: reason,
        project_summaries: scheduler_project_summaries(state, now)
      })

    state |> Map.put(:scheduler, scheduler) |> refresh_snapshot(now)
  end

  defp refresh_snapshot(state, now) do
    snapshot =
      build_snapshot(state.config_path, state.loaded_at, state.registry,
        now: now,
        poll_facts: state.poll_facts,
        provider_queue: state.provider_queue,
        provider_executor: state.provider_executor,
        runtime_ledger: state.runtime_ledger,
        candidate_intake: state.candidate_intake,
        dispatch_planning: state.dispatch_planning,
        dispatch_plan_application: state.dispatch_plan_application,
        worker_start_handoff: state.worker_start_handoff,
        worker_lifecycle_reconciliation: state.worker_lifecycle_reconciliation,
        tick: state.tick,
        scheduler: state.scheduler
      )

    %{state | snapshot: snapshot}
  end

  defp next_schedule_delay(state, now) do
    plan =
      PollCoordinator.build_plan(state.registry,
        now: now,
        facts: state.poll_facts,
        queue: state.provider_queue
      )

    cond do
      unresolved_runtime_count(state) > 0 ->
        {@scheduler_unresolved_delay_ms, "runtime_reconciliation"}

      due_project_count(plan) > 0 ->
        {0, "poll_due"}

      true ->
        case earliest_project_due_at(plan, now) do
          nil -> {@scheduler_default_delay_ms, "default_interval"}
          due_at -> {DateTime.diff(due_at, now, :millisecond), "next_project_due"}
        end
    end
  end

  defp scheduler_project_summaries(state, now) do
    plan =
      PollCoordinator.build_plan(state.registry,
        now: now,
        facts: state.poll_facts,
        queue: state.provider_queue
      )

    replay = RuntimeLedger.replay(state.runtime_ledger)
    runtime_by_project = Map.new(replay.projects, &{value(&1, :project_id), &1})

    Enum.map(plan.projects, fn project ->
      runtime = Map.get(runtime_by_project, project.project_id, %{})
      counts = value(runtime, :counts) || %{}

      %{
        project_id: project.project_id,
        allow_poll: project.allow_poll == true,
        eligibility_reason: status_string(value(project.eligibility, :reason)),
        next_due_at: iso8601(project.next_due_at),
        backoff_until: iso8601(project.backoff_until),
        active_attempt_count: length(list_value(runtime, :active_attempts)),
        pending_start_intent_count: length(list_value(runtime, :pending_start_intents)),
        running_count: non_negative_integer(value(counts, :running)) || 0,
        retry_backoff_count: length(list_value(runtime, :retry_backoff)),
        manual_attention_count: length(list_value(runtime, :manual_attention))
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  defp due_project_count(plan), do: Enum.count(plan.projects, &(&1.allow_poll == true))

  defp earliest_project_due_at(plan, now) do
    plan.projects
    |> Enum.map(fn project -> project.backoff_until || project.next_due_at end)
    |> Enum.reject(&(is_nil(&1) or DateTime.compare(&1, now) == :lt))
    |> Enum.min_by(&DateTime.to_unix(&1, :millisecond), fn -> nil end)
  end

  defp unresolved_runtime_count(state) do
    replay = RuntimeLedger.replay(state.runtime_ledger)

    Enum.reduce(replay.projects, 0, fn project, count ->
      count +
        length(list_value(project, :pending_start_intents)) +
        length(list_value(project, :active_attempts)) +
        length(list_value(project, :retry_backoff)) +
        length(list_value(project, :manual_attention))
    end)
  end

  defp scheduler_duration_ms(nil, _finished_at), do: nil

  defp scheduler_duration_ms(%DateTime{} = started_at, %DateTime{} = finished_at) do
    max(DateTime.diff(finished_at, started_at, :millisecond), 0)
  end

  defp normalize_delay_ms(delay_ms) when is_integer(delay_ms) and delay_ms <= 0, do: 0
  defp normalize_delay_ms(delay_ms) when is_integer(delay_ms) and delay_ms < @scheduler_min_delay_ms, do: @scheduler_min_delay_ms
  defp normalize_delay_ms(delay_ms) when is_integer(delay_ms), do: delay_ms

  defp new_scheduler(enabled?, now) do
    %{
      enabled: enabled? == true,
      status: if(enabled? == true, do: "idle", else: "disabled"),
      running?: false,
      tick_queued?: false,
      coalesced?: false,
      timer_ref: nil,
      timer_token: nil,
      running_ref: nil,
      running_started_at: nil,
      requested_at: nil,
      manual_refresh_requested_at: nil,
      next_tick_at: nil,
      next_delay_ms: nil,
      next_reason: nil,
      last_started_at: nil,
      last_finished_at: nil,
      last_duration_ms: nil,
      last_reason: nil,
      last_operations: [],
      last_error: nil,
      run_count: 0,
      coalesced_count: 0,
      skipped_count: 0,
      error_count: 0,
      project_summaries: [],
      updated_at: now
    }
  end

  defp normalize_scheduler(
         scheduler,
         poll_plan,
         runtime_ledger,
         worker_start_handoff,
         worker_lifecycle_reconciliation,
         now
       ) do
    scheduler = if is_map(scheduler), do: scheduler, else: new_scheduler(false, now)

    unresolved_runtime =
      unresolved_runtime_summary(
        runtime_ledger,
        worker_start_handoff,
        worker_lifecycle_reconciliation
      )

    scheduler
    |> Map.merge(%{
      project_summaries: scheduler_project_summaries_or_parts(scheduler, poll_plan, runtime_ledger),
      unresolved_runtime: unresolved_runtime,
      updated_at: now
    })
    |> scheduler_observability()
  end

  defp scheduler_project_summaries_or_parts(scheduler, poll_plan, runtime_ledger) do
    case list_value(scheduler, :project_summaries) do
      [] -> scheduler_project_summaries_from_parts(poll_plan, runtime_ledger)
      projects -> projects
    end
  end

  defp scheduler_observability(scheduler) do
    %{
      enabled: value(scheduler, :enabled) == true,
      status: status_string(value(scheduler, :status)) || "disabled",
      running?: value(scheduler, :running?) == true,
      queued: value(scheduler, :tick_queued?) == true,
      coalesced: value(scheduler, :coalesced?) == true,
      requested_at: iso8601(value(scheduler, :requested_at)),
      manual_refresh_requested_at: iso8601(value(scheduler, :manual_refresh_requested_at)),
      next_tick_at: iso8601(value(scheduler, :next_tick_at)),
      next_delay_ms: non_negative_integer(value(scheduler, :next_delay_ms)),
      next_reason: status_string(value(scheduler, :next_reason)),
      last_tick: %{
        started_at: iso8601(value(scheduler, :last_started_at)),
        finished_at: iso8601(value(scheduler, :last_finished_at)),
        duration_ms: non_negative_integer(value(scheduler, :last_duration_ms)),
        reason: status_string(value(scheduler, :last_reason)),
        operations: list_value(scheduler, :last_operations)
      },
      counts: %{
        run_count: non_negative_integer(value(scheduler, :run_count)) || 0,
        coalesced_count: non_negative_integer(value(scheduler, :coalesced_count)) || 0,
        skipped_count: non_negative_integer(value(scheduler, :skipped_count)) || 0,
        error_count: non_negative_integer(value(scheduler, :error_count)) || 0
      },
      last_error: safe_optional_error(value(scheduler, :last_error)),
      projects: list_value(scheduler, :project_summaries),
      unresolved_runtime: value(scheduler, :unresolved_runtime) || %{}
    }
    |> Enum.reject(fn
      {:last_error, nil} -> true
      {_key, _value} -> false
    end)
    |> Map.new()
  end

  defp scheduler_project_summaries_from_parts(poll_plan, runtime_ledger) do
    replay = RuntimeLedger.replay(runtime_ledger)
    runtime_by_project = Map.new(replay.projects, &{value(&1, :project_id), &1})

    Enum.map(poll_plan.projects, fn project ->
      runtime = Map.get(runtime_by_project, project.project_id, %{})

      %{
        project_id: project.project_id,
        allow_poll: project.allow_poll == true,
        eligibility_reason: status_string(value(project.eligibility, :reason)),
        next_due_at: iso8601(project.next_due_at),
        backoff_until: iso8601(project.backoff_until),
        active_attempt_count: length(list_value(runtime, :active_attempts)),
        pending_start_intent_count: length(list_value(runtime, :pending_start_intents)),
        retry_backoff_count: length(list_value(runtime, :retry_backoff)),
        manual_attention_count: length(list_value(runtime, :manual_attention))
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  defp unresolved_runtime_summary(runtime_ledger, worker_start_handoff, worker_lifecycle_reconciliation) do
    replay = RuntimeLedger.replay(runtime_ledger)

    %{
      active_attempt_count:
        Enum.reduce(replay.projects, 0, fn project, count ->
          count + length(list_value(project, :active_attempts))
        end),
      pending_start_intent_count:
        Enum.reduce(replay.projects, 0, fn project, count ->
          count + length(list_value(project, :pending_start_intents))
        end),
      retry_backoff_count:
        Enum.reduce(replay.projects, 0, fn project, count ->
          count + length(list_value(project, :retry_backoff))
        end),
      manual_attention_count:
        Enum.reduce(replay.projects, 0, fn project, count ->
          count + length(list_value(project, :manual_attention))
        end),
      worker_start_unresolved_count:
        worker_start_handoff
        |> value(:counts)
        |> value(:unresolved_start_intent_count)
        |> non_negative_integer()
        |> Kernel.||(0),
      worker_lifecycle_unresolved_count:
        worker_lifecycle_reconciliation
        |> value(:counts)
        |> value(:unresolved_count)
        |> non_negative_integer()
        |> Kernel.||(0)
    }
  end

  defp safe_optional_error(nil), do: nil
  defp safe_optional_error(error), do: safe_error(error)

  defp tick_operations do
    [
      "hub_registry_load",
      "hub_poll_plan",
      "hub_provider_candidate_scan",
      "hub_candidate_intake",
      "hub_dispatch_planning",
      "hub_dispatch_plan_application",
      "hub_worker_start_handoff",
      "hub_worker_lifecycle_reconciliation",
      "hub_device_observability"
    ]
  end

  defp provider_executor_summary(ProviderExecutor) do
    %{
      mode: "skeleton",
      executor: "default_skeleton",
      provider_io: false,
      candidate_scan: "accepted_without_provider_io"
    }
  end

  defp provider_executor_summary(RealCandidateScanExecutor) do
    %{
      mode: "real_candidate_scan",
      executor: "real_candidate_scan",
      provider_io: true,
      supported_operations: ["candidate_scan"]
    }
  end

  defp provider_executor_summary(executor) when is_atom(executor) do
    %{
      mode: "custom_module",
      executor: inspect(executor),
      provider_io: "unknown"
    }
  end

  defp provider_executor_summary(executor) when is_function(executor, 2) do
    %{
      mode: "custom_function",
      executor: "anonymous_function",
      provider_io: "unknown"
    }
  end

  defp provider_executor_summary(_executor) do
    %{
      mode: "invalid",
      executor: "invalid",
      provider_io: false
    }
  end

  defp execute_provider_request(nil, _executor, _started_at, _registry, _config_path) do
    {:error, :missing_provider_request}
  end

  defp execute_provider_request(request, executor, started_at, registry, config_path) when is_function(executor, 2) do
    safe_execute_provider_request(fn ->
      executor.(request,
        started_at: started_at,
        registry: registry,
        hub_config_path: config_path
      )
    end)
  end

  defp execute_provider_request(request, executor, started_at, registry, config_path) when is_atom(executor) do
    safe_execute_provider_request(fn ->
      executor.execute(request,
        started_at: started_at,
        registry: registry,
        hub_config_path: config_path
      )
    end)
  end

  defp execute_provider_request(_request, _executor, _started_at, _registry, _config_path) do
    {:error, :invalid_provider_executor}
  end

  defp safe_execute_provider_request(fun) do
    fun.()
  rescue
    error in [ArgumentError, RuntimeError] -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, "#{kind}: #{safe_error(reason)}"}
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

  defp poll_intake_source(entry, request, result, attempt, result_fact, finished_at) do
    %{
      entry: entry,
      request: request,
      result: result,
      attempt: attempt,
      result_fact: result_fact,
      finished_at: finished_at
    }
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
      candidate_intake: CandidateIntake.tick_summary(%{}),
      dispatch_planning: DispatchPlanning.tick_summary(%{}),
      dispatch_plan_application: DispatchPlanApplication.tick_summary(%{}),
      worker_start_handoff: WorkerStartHandoff.tick_summary(%{}),
      worker_lifecycle_reconciliation: WorkerLifecycleReconciliation.tick_summary(%{}),
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
      candidate_intake: CandidateIntake.tick_summary(%{}),
      dispatch_planning: DispatchPlanning.tick_summary(%{}),
      dispatch_plan_application: DispatchPlanApplication.tick_summary(%{}),
      worker_start_handoff: WorkerStartHandoff.tick_summary(%{}),
      worker_lifecycle_reconciliation: WorkerLifecycleReconciliation.tick_summary(%{}),
      updated_at: iso8601(started_at)
    }
  end

  defp finished_tick(
         started_tick,
         finished_at,
         selected_count,
         result_summaries,
         candidate_intake,
         dispatch_planning,
         dispatch_plan_application,
         worker_start_handoff,
         worker_lifecycle_reconciliation
       ) do
    results = Enum.reverse(result_summaries)

    %{
      status: "completed",
      running?: false,
      started_at: started_tick.started_at,
      finished_at: iso8601(finished_at),
      selected_count: selected_count,
      result_counts: result_counts(results),
      results: results,
      candidate_intake: CandidateIntake.tick_summary(candidate_intake),
      dispatch_planning: DispatchPlanning.tick_summary(dispatch_planning),
      dispatch_plan_application: DispatchPlanApplication.tick_summary(dispatch_plan_application),
      worker_start_handoff: WorkerStartHandoff.tick_summary(worker_start_handoff),
      worker_lifecycle_reconciliation: WorkerLifecycleReconciliation.tick_summary(worker_lifecycle_reconciliation),
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
      candidate_intake: CandidateIntake.tick_summary(Map.get(tick, :candidate_intake) || Map.get(tick, "candidate_intake") || %{}),
      dispatch_planning: DispatchPlanning.tick_summary(Map.get(tick, :dispatch_planning) || Map.get(tick, "dispatch_planning") || %{}),
      dispatch_plan_application: DispatchPlanApplication.tick_summary(Map.get(tick, :dispatch_plan_application) || Map.get(tick, "dispatch_plan_application") || %{}),
      worker_start_handoff: WorkerStartHandoff.tick_summary(Map.get(tick, :worker_start_handoff) || Map.get(tick, "worker_start_handoff") || %{}),
      worker_lifecycle_reconciliation: WorkerLifecycleReconciliation.tick_summary(Map.get(tick, :worker_lifecycle_reconciliation) || Map.get(tick, "worker_lifecycle_reconciliation") || %{}),
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
  defp value(_value, _key), do: nil

  defp list_value(map, key) do
    case value(map, key) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _other -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

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
      opt_in_hub_capabilities: [
        "project_registry",
        "poll_plan_snapshot",
        "provider_candidate_scan_request",
        "poll_result_snapshot",
        "candidate_intake_snapshot",
        "dispatch_planning_snapshot",
        "dispatch_plan_application_snapshot",
        "dispatch_ledger_model_facts",
        "device_observability_snapshot"
      ]
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
