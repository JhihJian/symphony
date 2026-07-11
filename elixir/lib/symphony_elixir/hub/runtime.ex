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
    ActivationPreflight,
    CandidateIntake,
    CutoverAuditHistory,
    CutoverAuthorizationConsumptionGuard,
    CutoverClosureChain,
    CutoverClosureConclusion,
    CutoverClosureReportPacket,
    CutoverExecutionAuthorization,
    CutoverExecutionOutcomeCloseout,
    CutoverExecutionOutcomeLedger,
    CutoverGate,
    CutoverOperationAudit,
    CutoverReadinessPermit,
    CutoverReplayDecision,
    CutoverReplayRequestAudit,
    DeviceObservability,
    DispatchPlanApplication,
    DispatchPlanning,
    HostServiceProbe,
    PollCoordinator,
    ProjectRegistry,
    ProviderExecutor,
    ProviderGovernance,
    RealCandidateScanExecutor,
    RealWorkerLifecycleStore,
    RealWritebackExecutor,
    RuntimeLedger,
    Scheduler,
    WorkerLifecycleReconciliation,
    WorkerStartHandoff
  }

  @env_key :hub_config_file_path
  @scheduler_env_key :hub_scheduler_enabled
  @provider_executor_env_key :hub_provider_executor
  @writeback_executor_env_key :hub_writeback_executor
  @worker_start_starter_env_key :hub_worker_start_starter
  @activation_probe_env_key :hub_activation_probe
  @operator_acknowledgements_env_key :hub_operator_acknowledgements
  @cutover_operation_requests_env_key :hub_cutover_operation_requests
  @cutover_audit_history_entries_env_key :hub_cutover_audit_history_entries
  @manual_attention_closeouts_env_key :hub_manual_attention_closeouts
  @cutover_execution_authorization_requests_env_key :hub_cutover_execution_authorization_requests
  @cutover_execution_outcome_closeouts_env_key :hub_cutover_execution_outcome_closeouts
  @cutover_replay_requests_env_key :hub_cutover_replay_requests
  @worker_lifecycle_result_source_env_key :hub_worker_lifecycle_result_source
  @poll_fact_limit 200
  @scheduler_min_delay_ms 10
  @scheduler_unresolved_delay_ms 1_000
  @scheduler_error_backoff_ms 30_000
  @scheduler_default_delay_ms 30_000
  @activation_probe_interval_ms 60_000
  @snapshot_refresh_interval_ms 600_000
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
          required(:writeback_executor) => module() | function(),
          required(:worker_start_starter) => WorkerStartHandoff.starter(),
          required(:activation_probe) => map() | function() | nil,
          required(:activation_probe_checked_at) => DateTime.t(),
          required(:activation_probe_interval_ms) => pos_integer(),
          required(:activation_probe_count) => non_neg_integer(),
          required(:snapshot_refreshed_at) => DateTime.t(),
          required(:snapshot_refresh_interval_ms) => pos_integer(),
          required(:operator_acknowledgements) => term(),
          required(:cutover_operation_requests) => term(),
          required(:cutover_audit_history_entries) => term(),
          required(:manual_attention_closeouts) => term(),
          required(:cutover_execution_authorization_requests) => term(),
          required(:cutover_replay_requests) => term(),
          required(:cutover_gate) => map(),
          required(:cutover_execution_authorization_ledger) => map(),
          required(:cutover_authorization_consumption_guard) => map(),
          required(:cutover_execution_outcome_ledger) => map(),
          required(:cutover_execution_outcome_closeout) => map(),
          required(:cutover_replay_decision) => map(),
          required(:cutover_replay_request_audit) => map(),
          required(:cutover_closure_chain) => map(),
          required(:cutover_closure_conclusion) => map(),
          required(:cutover_closure_report_packet) => map(),
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

  @spec set_writeback_executor(module() | function() | nil) :: :ok
  def set_writeback_executor(executor) when is_atom(executor) or is_function(executor, 2) or is_nil(executor) do
    Application.put_env(:symphony_elixir, @writeback_executor_env_key, executor)
    :ok
  end

  @spec clear_writeback_executor() :: :ok
  def clear_writeback_executor do
    Application.delete_env(:symphony_elixir, @writeback_executor_env_key)
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

  @spec set_activation_probe(map() | function() | nil) :: :ok
  def set_activation_probe(probe) when is_map(probe) or is_function(probe, 1) or is_nil(probe) do
    Application.put_env(:symphony_elixir, @activation_probe_env_key, probe)
    :ok
  end

  @spec clear_activation_probe() :: :ok
  def clear_activation_probe do
    Application.delete_env(:symphony_elixir, @activation_probe_env_key)
    :ok
  end

  @spec set_operator_acknowledgements(term()) :: :ok
  def set_operator_acknowledgements(acknowledgements) do
    Application.put_env(:symphony_elixir, @operator_acknowledgements_env_key, acknowledgements)
    :ok
  end

  @spec clear_operator_acknowledgements() :: :ok
  def clear_operator_acknowledgements do
    Application.delete_env(:symphony_elixir, @operator_acknowledgements_env_key)
    :ok
  end

  @spec set_cutover_operation_requests(term()) :: :ok
  def set_cutover_operation_requests(requests) do
    Application.put_env(:symphony_elixir, @cutover_operation_requests_env_key, requests)
    :ok
  end

  @spec clear_cutover_operation_requests() :: :ok
  def clear_cutover_operation_requests do
    Application.delete_env(:symphony_elixir, @cutover_operation_requests_env_key)
    :ok
  end

  @spec set_cutover_audit_history_entries(term()) :: :ok
  def set_cutover_audit_history_entries(entries) do
    Application.put_env(:symphony_elixir, @cutover_audit_history_entries_env_key, entries)
    :ok
  end

  @spec clear_cutover_audit_history_entries() :: :ok
  def clear_cutover_audit_history_entries do
    Application.delete_env(:symphony_elixir, @cutover_audit_history_entries_env_key)
    :ok
  end

  @spec set_manual_attention_closeouts(term()) :: :ok
  def set_manual_attention_closeouts(closeouts) do
    Application.put_env(:symphony_elixir, @manual_attention_closeouts_env_key, closeouts)
    :ok
  end

  @spec clear_manual_attention_closeouts() :: :ok
  def clear_manual_attention_closeouts do
    Application.delete_env(:symphony_elixir, @manual_attention_closeouts_env_key)
    :ok
  end

  @spec set_cutover_execution_authorization_requests(term()) :: :ok
  def set_cutover_execution_authorization_requests(requests) do
    Application.put_env(:symphony_elixir, @cutover_execution_authorization_requests_env_key, requests)
    :ok
  end

  @spec clear_cutover_execution_authorization_requests() :: :ok
  def clear_cutover_execution_authorization_requests do
    Application.delete_env(:symphony_elixir, @cutover_execution_authorization_requests_env_key)
    :ok
  end

  @spec set_cutover_execution_outcome_closeouts(term()) :: :ok
  def set_cutover_execution_outcome_closeouts(closeouts) do
    Application.put_env(:symphony_elixir, @cutover_execution_outcome_closeouts_env_key, closeouts)
    :ok
  end

  @spec clear_cutover_execution_outcome_closeouts() :: :ok
  def clear_cutover_execution_outcome_closeouts do
    Application.delete_env(:symphony_elixir, @cutover_execution_outcome_closeouts_env_key)
    :ok
  end

  @spec set_cutover_replay_requests(term()) :: :ok
  def set_cutover_replay_requests(requests) do
    Application.put_env(:symphony_elixir, @cutover_replay_requests_env_key, requests)
    :ok
  end

  @spec clear_cutover_replay_requests() :: :ok
  def clear_cutover_replay_requests do
    Application.delete_env(:symphony_elixir, @cutover_replay_requests_env_key)
    :ok
  end

  @spec load_cutover_operation_requests(Path.t()) :: :ok | {:error, String.t()}
  def load_cutover_operation_requests(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, requests} <- decode_hub_json_or_yaml(content, path) do
      set_cutover_operation_requests(requests)
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "Hub cutover operation request file not found: #{path} (#{reason})"}

      {:error, reason} ->
        {:error, "Failed to load Hub cutover operation request file #{path}: #{inspect(reason)}"}
    end
  end

  @spec load_cutover_audit_history_entries(Path.t()) :: :ok | {:error, String.t()}
  def load_cutover_audit_history_entries(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, entries} <- decode_hub_json_or_yaml(content, path) do
      set_cutover_audit_history_entries(entries)
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "Hub cutover audit history file not found: #{path} (#{reason})"}

      {:error, reason} ->
        {:error, "Failed to load Hub cutover audit history file #{path}: #{inspect(reason)}"}
    end
  end

  @spec load_manual_attention_closeouts(Path.t()) :: :ok | {:error, String.t()}
  def load_manual_attention_closeouts(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, closeouts} <- decode_hub_json_or_yaml(content, path) do
      set_manual_attention_closeouts(closeouts)
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "Hub manual attention closeout file not found: #{path} (#{reason})"}

      {:error, reason} ->
        {:error, "Failed to load Hub manual attention closeout file #{path}: #{inspect(reason)}"}
    end
  end

  @spec load_cutover_execution_authorization_requests(Path.t()) :: :ok | {:error, String.t()}
  def load_cutover_execution_authorization_requests(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, requests} <- decode_hub_json_or_yaml(content, path) do
      set_cutover_execution_authorization_requests(requests)
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "Hub cutover execution authorization request file not found: #{path} (#{reason})"}

      {:error, reason} ->
        {:error, "Failed to load Hub cutover execution authorization request file #{path}: #{inspect(reason)}"}
    end
  end

  @spec load_cutover_execution_outcome_closeouts(Path.t()) :: :ok | {:error, String.t()}
  def load_cutover_execution_outcome_closeouts(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, closeouts} <- decode_hub_json_or_yaml(content, path) do
      set_cutover_execution_outcome_closeouts(closeouts)
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "Hub cutover execution outcome closeout file not found: #{path} (#{reason})"}

      {:error, reason} ->
        {:error, "Failed to load Hub cutover execution outcome closeout file #{path}: #{inspect(reason)}"}
    end
  end

  @spec load_cutover_replay_requests(Path.t()) :: :ok | {:error, String.t()}
  def load_cutover_replay_requests(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, requests} <- decode_hub_json_or_yaml(content, path) do
      set_cutover_replay_requests(requests)
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "Hub cutover replay request file not found: #{path} (#{reason})"}

      {:error, reason} ->
        {:error, "Failed to load Hub cutover replay request file #{path}: #{inspect(reason)}"}
    end
  end

  @spec load_operator_acknowledgements(Path.t()) :: :ok | {:error, String.t()}
  def load_operator_acknowledgements(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, acknowledgements} <- decode_hub_json_or_yaml(content, path) do
      set_operator_acknowledgements(acknowledgements)
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "Hub activation acknowledgement file not found: #{path} (#{reason})"}

      {:error, reason} ->
        {:error, "Failed to load Hub activation acknowledgement file #{path}: #{inspect(reason)}"}
    end
  end

  @spec set_host_service_activation_probe(keyword()) :: :ok
  def set_host_service_activation_probe(opts \\ []) when is_list(opts) do
    set_activation_probe(HostServiceProbe.build_fun(opts))
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
    Application.get_env(
      :symphony_elixir,
      @worker_lifecycle_result_source_env_key,
      RealWorkerLifecycleStore
    )
  end

  @spec provider_executor() :: module() | function()
  def provider_executor do
    case Application.get_env(:symphony_elixir, @provider_executor_env_key) do
      nil -> ProviderExecutor
      executor when is_atom(executor) or is_function(executor, 2) -> executor
      _invalid -> ProviderExecutor
    end
  end

  @spec writeback_executor() :: module() | function()
  def writeback_executor do
    case Application.get_env(:symphony_elixir, @writeback_executor_env_key) do
      nil -> ProviderExecutor
      executor when is_atom(executor) or is_function(executor, 2) -> executor
      _invalid -> ProviderExecutor
    end
  end

  @spec worker_start_starter() :: WorkerStartHandoff.starter()
  def worker_start_starter do
    Application.get_env(:symphony_elixir, @worker_start_starter_env_key)
  end

  @spec activation_probe() :: map() | function() | nil
  def activation_probe do
    Application.get_env(:symphony_elixir, @activation_probe_env_key)
  end

  @spec operator_acknowledgements() :: term()
  def operator_acknowledgements do
    Application.get_env(:symphony_elixir, @operator_acknowledgements_env_key)
  end

  @spec cutover_operation_requests() :: term()
  def cutover_operation_requests do
    Application.get_env(:symphony_elixir, @cutover_operation_requests_env_key)
  end

  @spec cutover_audit_history_entries() :: term()
  def cutover_audit_history_entries do
    Application.get_env(:symphony_elixir, @cutover_audit_history_entries_env_key)
  end

  @spec manual_attention_closeouts() :: term()
  def manual_attention_closeouts do
    Application.get_env(:symphony_elixir, @manual_attention_closeouts_env_key)
  end

  @spec cutover_execution_authorization_requests() :: term()
  def cutover_execution_authorization_requests do
    Application.get_env(:symphony_elixir, @cutover_execution_authorization_requests_env_key)
  end

  @spec cutover_execution_outcome_closeouts() :: term()
  def cutover_execution_outcome_closeouts do
    Application.get_env(:symphony_elixir, @cutover_execution_outcome_closeouts_env_key)
  end

  @spec cutover_replay_requests() :: term()
  def cutover_replay_requests do
    Application.get_env(:symphony_elixir, @cutover_replay_requests_env_key)
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
      writeback_executor = initial_writeback_executor(opts, provider_executor)
      activation_probe = Keyword.get(opts, :activation_probe, activation_probe())
      operator_acknowledgements = Keyword.get(opts, :operator_acknowledgements, operator_acknowledgements())
      cutover_operation_requests = Keyword.get(opts, :cutover_operation_requests, cutover_operation_requests())
      cutover_audit_history_entries = Keyword.get(opts, :cutover_audit_history_entries, cutover_audit_history_entries())
      manual_attention_closeouts = Keyword.get(opts, :manual_attention_closeouts, manual_attention_closeouts())

      cutover_execution_authorization_requests =
        Keyword.get(opts, :cutover_execution_authorization_requests, cutover_execution_authorization_requests())

      cutover_execution_outcome_closeouts =
        Keyword.get(opts, :cutover_execution_outcome_closeouts, cutover_execution_outcome_closeouts())

      cutover_replay_requests =
        Keyword.get(opts, :cutover_replay_requests, cutover_replay_requests())

      worker_start_starter = Keyword.get(opts, :worker_start_starter, worker_start_starter())
      activation_probe_interval_ms = positive_integer(Keyword.get(opts, :activation_probe_interval_ms)) || @activation_probe_interval_ms
      snapshot_refresh_interval_ms = positive_integer(Keyword.get(opts, :snapshot_refresh_interval_ms)) || @snapshot_refresh_interval_ms
      activation_preflight = build_activation_preflight(registry, activation_probe, loaded_at)
      activation_probe_count = if is_function(activation_probe, 1), do: 1, else: 0
      scheduler = Map.put(scheduler, :activation_probe_count, activation_probe_count)

      cutover_gate =
        build_cutover_gate(
          registry,
          loaded_at,
          activation_preflight,
          provider_executor,
          writeback_executor,
          worker_start_starter,
          activation_probe,
          operator_acknowledgements,
          scheduler
        )

      initial_snapshot =
        build_snapshot(config_path, loaded_at, registry,
          now: loaded_at,
          activation_preflight: activation_preflight,
          cutover_gate: cutover_gate,
          activation_probe: activation_probe,
          operator_acknowledgements: operator_acknowledgements,
          cutover_operation_requests: cutover_operation_requests,
          cutover_audit_history_entries: cutover_audit_history_entries,
          manual_attention_closeouts: manual_attention_closeouts,
          cutover_execution_authorization_requests: cutover_execution_authorization_requests,
          cutover_execution_outcome_closeouts: cutover_execution_outcome_closeouts,
          cutover_replay_requests: cutover_replay_requests,
          provider_queue: provider_queue,
          provider_executor: provider_executor,
          writeback_executor: writeback_executor,
          worker_start_starter: worker_start_starter,
          runtime_ledger: runtime_ledger,
          candidate_intake: candidate_intake,
          dispatch_planning: dispatch_planning,
          dispatch_plan_application: dispatch_plan_application,
          worker_start_handoff: worker_start_handoff,
          worker_lifecycle_reconciliation: worker_lifecycle_reconciliation,
          tick: tick,
          scheduler: scheduler
        )

      cutover_execution_authorization_ledger = initial_snapshot.hub_cutover_execution_authorization_ledger
      cutover_authorization_consumption_guard = initial_snapshot.hub_cutover_authorization_consumption_guard
      cutover_execution_outcome_ledger = initial_snapshot.hub_cutover_execution_outcome_ledger
      cutover_execution_outcome_closeout = initial_snapshot.hub_cutover_execution_outcome_closeout
      cutover_replay_decision = initial_snapshot.hub_cutover_replay_decision
      cutover_replay_request_audit = initial_snapshot.hub_cutover_replay_request_audit
      cutover_closure_chain = initial_snapshot.hub_cutover_closure_chain
      cutover_closure_conclusion = initial_snapshot.hub_cutover_closure_conclusion
      cutover_closure_report_packet = initial_snapshot.hub_cutover_closure_report_packet

      state = %{
        config_path: config_path,
        loaded_at: loaded_at,
        registry: registry,
        poll_facts: [],
        provider_queue: provider_queue,
        provider_executor: provider_executor,
        writeback_executor: writeback_executor,
        worker_start_starter: worker_start_starter,
        activation_probe: activation_probe,
        activation_probe_checked_at: loaded_at,
        activation_probe_interval_ms: activation_probe_interval_ms,
        activation_probe_count: activation_probe_count,
        snapshot_refreshed_at: loaded_at,
        snapshot_refresh_interval_ms: snapshot_refresh_interval_ms,
        operator_acknowledgements: operator_acknowledgements,
        cutover_operation_requests: cutover_operation_requests,
        cutover_audit_history_entries: cutover_audit_history_entries,
        manual_attention_closeouts: manual_attention_closeouts,
        cutover_execution_authorization_requests: cutover_execution_authorization_requests,
        cutover_execution_outcome_closeouts: cutover_execution_outcome_closeouts,
        cutover_replay_requests: cutover_replay_requests,
        cutover_execution_authorization_ledger: cutover_execution_authorization_ledger,
        cutover_authorization_consumption_guard: cutover_authorization_consumption_guard,
        cutover_execution_outcome_ledger: cutover_execution_outcome_ledger,
        cutover_execution_outcome_closeout: cutover_execution_outcome_closeout,
        cutover_replay_decision: cutover_replay_decision,
        cutover_replay_request_audit: cutover_replay_request_audit,
        cutover_closure_chain: cutover_closure_chain,
        cutover_closure_conclusion: cutover_closure_conclusion,
        cutover_closure_report_packet: cutover_closure_report_packet,
        activation_preflight: activation_preflight,
        cutover_gate: cutover_gate,
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
        |> schedule_next_tick(now, "error_backoff", @scheduler_error_backoff_ms)
      else
        state
      end

    {:noreply, state}
  end

  defp run_manual_refresh(state, requested_at) do
    case load_registry(state.config_path) do
      {:ok, registry} ->
        activation_preflight = build_activation_preflight(registry, state.activation_probe, requested_at)

        activation_probe_count =
          state.activation_probe_count + if(is_function(state.activation_probe, 1), do: 1, else: 0)

        scheduler = Map.put(state.scheduler, :activation_probe_count, activation_probe_count)

        cutover_gate =
          build_cutover_gate(
            registry,
            requested_at,
            activation_preflight,
            state.provider_executor,
            state.writeback_executor,
            state.worker_start_starter,
            state.activation_probe,
            state.operator_acknowledgements,
            scheduler
          )

        {state, tick_summary} =
          state
          |> Map.merge(%{
            loaded_at: requested_at,
            registry: registry,
            activation_preflight: activation_preflight,
            activation_probe_checked_at: requested_at,
            activation_probe_count: activation_probe_count,
            scheduler: scheduler,
            cutover_gate: cutover_gate
          })
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
             "hub_cutover_operation_audit",
             "hub_cutover_audit_history",
             "hub_cutover_readiness_permit",
             "hub_cutover_execution_authorization_ledger",
             "hub_cutover_authorization_consumption_guard",
             "hub_cutover_execution_outcome_ledger",
             "hub_cutover_execution_outcome_closeout",
             "hub_cutover_replay_decision",
             "hub_cutover_replay_request_audit",
             "hub_cutover_closure_chain",
             "hub_cutover_closure_conclusion",
             "hub_cutover_closure_report_packet",
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
    writeback_executor = Keyword.get(opts, :writeback_executor, provider_executor)
    worker_start_starter = Keyword.get(opts, :worker_start_starter)
    activation_probe = Keyword.get(opts, :activation_probe)
    operator_acknowledgements = Keyword.get(opts, :operator_acknowledgements)
    cutover_operation_requests = Keyword.get(opts, :cutover_operation_requests)
    cutover_audit_history_entries = Keyword.get(opts, :cutover_audit_history_entries)
    manual_attention_closeouts = Keyword.get(opts, :manual_attention_closeouts)
    cutover_execution_authorization_requests = Keyword.get(opts, :cutover_execution_authorization_requests)
    cutover_execution_outcome_closeouts = Keyword.get(opts, :cutover_execution_outcome_closeouts)
    cutover_replay_requests = Keyword.get(opts, :cutover_replay_requests)
    provided_cutover_readiness_permit = Keyword.get(opts, :cutover_readiness_permit)
    provided_cutover_execution_authorization_ledger = Keyword.get(opts, :cutover_execution_authorization_ledger)
    provided_cutover_authorization_consumption_guard = Keyword.get(opts, :cutover_authorization_consumption_guard)
    provided_cutover_execution_outcome_ledger = Keyword.get(opts, :cutover_execution_outcome_ledger)
    provided_cutover_execution_outcome_closeout = Keyword.get(opts, :cutover_execution_outcome_closeout)
    provided_cutover_replay_decision = Keyword.get(opts, :cutover_replay_decision)
    provided_cutover_replay_request_audit = Keyword.get(opts, :cutover_replay_request_audit)

    activation_preflight =
      Keyword.get(opts, :activation_preflight) ||
        ActivationPreflight.empty(registry, now: now)

    cutover_gate = Keyword.get(opts, :cutover_gate)

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

    poll_plan =
      PollCoordinator.build_plan(registry,
        now: now,
        facts: poll_facts,
        queue: provider_queue,
        activation_preflight: activation_preflight,
        cutover_gate: poll_cutover_gate(provider_executor, cutover_gate)
      )

    scheduler = normalize_scheduler(Keyword.get(opts, :scheduler), poll_plan, runtime_ledger, worker_start_handoff, worker_lifecycle_reconciliation, now)
    writeback = writeback_summary(runtime_ledger, provider_queue, writeback_executor)

    runtime_observability =
      hub_runtime_observability(
        read_only: Keyword.get(opts, :read_only, false),
        provider_executor: provider_executor,
        writeback_executor: writeback_executor,
        activation_probe: activation_probe,
        activation_preflight: activation_preflight,
        worker_start_starter: worker_start_starter
      )

    device_observability =
      DeviceObservability.build(
        %{
          hub_runtime: runtime_observability,
          registry: registry,
          poll_coordination: poll_plan,
          runtime_ledger: runtime_ledger,
          activation_preflight: activation_preflight,
          cutover_gate: cutover_gate || %{},
          scheduler: scheduler,
          tick: tick,
          candidate_intake: candidate_intake,
          dispatch_planning: dispatch_planning,
          dispatch_plan_application: dispatch_plan_application,
          worker_start_handoff: worker_start_handoff,
          worker_lifecycle_reconciliation: worker_lifecycle_reconciliation,
          cutover_audit_history: %{},
          cutover_readiness_permit: provided_cutover_readiness_permit || %{},
          cutover_execution_authorization_ledger: %{},
          cutover_authorization_consumption_guard: provided_cutover_authorization_consumption_guard || %{},
          cutover_execution_outcome_ledger: provided_cutover_execution_outcome_ledger || %{},
          cutover_execution_outcome_closeout: provided_cutover_execution_outcome_closeout || %{},
          cutover_replay_decision: provided_cutover_replay_decision || %{},
          cutover_replay_request_audit: provided_cutover_replay_request_audit || %{},
          writeback: writeback,
          migration_boundary: migration_boundary()
        },
        now: now,
        operator_acknowledgements: operator_acknowledgements
      )

    counts = counts(registry, device_observability)
    registry_summary = registry_summary(registry)
    cutover_gate = CutoverGate.to_snapshot(cutover_gate || device_observability.cutover_gate)

    cutover_operation_audit =
      CutoverOperationAudit.build(
        %{
          generated_at: now,
          hub_runtime: runtime_observability,
          projects: device_observability.projects,
          migration_readiness: device_observability.migration_readiness,
          activation_plan: device_observability.activation_plan,
          activation_preflight: activation_preflight,
          cutover_gate: cutover_gate
        },
        now: now,
        requests: cutover_operation_requests
      )

    cutover_audit_history =
      CutoverAuditHistory.build(
        %{
          generated_at: now,
          cutover_operation_audit: cutover_operation_audit,
          history_entries: cutover_audit_history_entries,
          manual_attention_closeouts: manual_attention_closeouts
        },
        now: now
      )

    cutover_readiness_permit =
      if is_map(provided_cutover_readiness_permit) and
           list_value(provided_cutover_readiness_permit, :projects) != [] do
        CutoverReadinessPermit.to_snapshot(provided_cutover_readiness_permit)
      else
        CutoverReadinessPermit.build(
          %{
            generated_at: now,
            hub_runtime: runtime_observability,
            projects: device_observability.projects,
            activation_plan: device_observability.activation_plan,
            cutover_gate: cutover_gate,
            cutover_operation_audit: cutover_operation_audit,
            cutover_audit_history: cutover_audit_history
          },
          now: now
        )
      end

    cutover_execution_authorization_ledger =
      if is_map(provided_cutover_execution_authorization_ledger) and
           list_value(provided_cutover_execution_authorization_ledger, :projects) != [] do
        CutoverExecutionAuthorization.to_snapshot(provided_cutover_execution_authorization_ledger)
      else
        CutoverExecutionAuthorization.build(
          %{
            generated_at: now,
            hub_runtime: runtime_observability,
            projects: device_observability.projects,
            cutover_readiness_permit: cutover_readiness_permit
          },
          now: now,
          requests: cutover_execution_authorization_requests
        )
      end

    cutover_authorization_consumption_guard =
      CutoverAuthorizationConsumptionGuard.build(
        %{
          generated_at: now,
          provider_queue: provider_queue,
          tick: tick,
          dispatch_plan_application: dispatch_plan_application,
          worker_start_handoff: worker_start_handoff,
          cutover_authorization_consumption_guard: provided_cutover_authorization_consumption_guard
        },
        now: now
      )

    cutover_execution_outcome_ledger =
      CutoverExecutionOutcomeLedger.build(
        %{
          generated_at: now,
          previous_ledger: provided_cutover_execution_outcome_ledger,
          provider_queue: provider_queue,
          tick: tick,
          dispatch_plan_application: dispatch_plan_application,
          worker_start_handoff: worker_start_handoff,
          writeback: writeback,
          cutover_authorization_consumption_guard: cutover_authorization_consumption_guard
        },
        now: now
      )

    cutover_execution_outcome_closeout =
      CutoverExecutionOutcomeCloseout.build(
        %{
          generated_at: now,
          cutover_execution_outcome_ledger: cutover_execution_outcome_ledger,
          execution_outcome_closeouts: cutover_execution_outcome_closeouts
        },
        now: now
      )

    cutover_replay_decision =
      CutoverReplayDecision.build(
        %{
          generated_at: now,
          tick: tick,
          dispatch_plan_application: dispatch_plan_application,
          worker_start_handoff: worker_start_handoff,
          writeback: writeback,
          cutover_execution_outcome_ledger: cutover_execution_outcome_ledger,
          cutover_execution_outcome_closeout: cutover_execution_outcome_closeout,
          cutover_authorization_consumption_guard: cutover_authorization_consumption_guard,
          cutover_replay_decision: provided_cutover_replay_decision
        },
        now: now
      )

    cutover_replay_request_audit =
      if is_map(provided_cutover_replay_request_audit) and
           list_value(provided_cutover_replay_request_audit, :projects) != [] do
        CutoverReplayRequestAudit.to_snapshot(provided_cutover_replay_request_audit)
      else
        CutoverReplayRequestAudit.build(
          %{
            generated_at: now,
            projects: device_observability.projects,
            cutover_execution_outcome_ledger: cutover_execution_outcome_ledger,
            cutover_execution_outcome_closeout: cutover_execution_outcome_closeout,
            cutover_replay_decision: cutover_replay_decision,
            cutover_readiness_permit: cutover_readiness_permit,
            cutover_execution_authorization_ledger: cutover_execution_authorization_ledger,
            cutover_authorization_consumption_guard: cutover_authorization_consumption_guard,
            replay_requests: cutover_replay_requests
          },
          now: now
        )
      end

    cutover_closure_chain =
      CutoverClosureChain.build(
        %{
          generated_at: now,
          projects: device_observability.projects,
          cutover_operation_audit: cutover_operation_audit,
          cutover_audit_history: cutover_audit_history,
          cutover_readiness_permit: cutover_readiness_permit,
          cutover_execution_authorization_ledger: cutover_execution_authorization_ledger,
          cutover_authorization_consumption_guard: cutover_authorization_consumption_guard,
          cutover_execution_outcome_ledger: cutover_execution_outcome_ledger,
          cutover_execution_outcome_closeout: cutover_execution_outcome_closeout,
          cutover_replay_decision: cutover_replay_decision,
          cutover_replay_request_audit: cutover_replay_request_audit
        },
        now: now
      )

    cutover_closure_conclusion = CutoverClosureConclusion.build(cutover_closure_chain, now: now)

    cutover_closure_report_packet =
      CutoverClosureReportPacket.build(
        %{
          hub_cutover_closure_chain: cutover_closure_chain,
          hub_cutover_closure_conclusion: cutover_closure_conclusion
        },
        now: now
      )

    device_observability =
      device_observability
      |> Map.put(:cutover_operation_audit, cutover_operation_audit)
      |> Map.put(:cutover_audit_history, cutover_audit_history)
      |> Map.put(:cutover_readiness_permit, cutover_readiness_permit)
      |> Map.put(:cutover_execution_authorization_ledger, cutover_execution_authorization_ledger)
      |> Map.put(:cutover_authorization_consumption_guard, cutover_authorization_consumption_guard)
      |> Map.put(:cutover_execution_outcome_ledger, cutover_execution_outcome_ledger)
      |> Map.put(:cutover_execution_outcome_closeout, cutover_execution_outcome_closeout)
      |> Map.put(:cutover_replay_decision, cutover_replay_decision)
      |> Map.put(:cutover_replay_request_audit, cutover_replay_request_audit)
      |> Map.put(:cutover_closure_chain, cutover_closure_chain)
      |> Map.put(:cutover_closure_conclusion, cutover_closure_conclusion)
      |> Map.put(:cutover_closure_report_packet, cutover_closure_report_packet)
      |> DeviceObservability.to_snapshot()

    %{
      hub_snapshot_contract: 1,
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
        writeback_executor: writeback.executor,
        worker_starter: worker_starter_summary(worker_start_starter),
        activation_probe: activation_probe_summary(activation_probe, activation_preflight),
        activation_preflight: activation_preflight,
        cutover_gate: cutover_gate,
        cutover_operation_audit: cutover_operation_audit,
        cutover_audit_history: cutover_audit_history,
        cutover_readiness_permit: cutover_readiness_permit,
        cutover_execution_authorization_ledger: cutover_execution_authorization_ledger,
        cutover_authorization_consumption_guard: cutover_authorization_consumption_guard,
        cutover_execution_outcome_ledger: cutover_execution_outcome_ledger,
        cutover_execution_outcome_closeout: cutover_execution_outcome_closeout,
        cutover_replay_decision: cutover_replay_decision,
        cutover_replay_request_audit: cutover_replay_request_audit,
        cutover_closure_chain: cutover_closure_chain,
        cutover_closure_conclusion: cutover_closure_conclusion,
        cutover_closure_report_packet: cutover_closure_report_packet,
        writeback: writeback,
        scheduler: scheduler,
        poll_tick: tick,
        candidate_intake: CandidateIntake.tick_summary(candidate_intake),
        dispatch_planning: DispatchPlanning.tick_summary(dispatch_planning),
        dispatch_plan_application: DispatchPlanApplication.tick_summary(dispatch_plan_application),
        worker_start_handoff: WorkerStartHandoff.tick_summary(worker_start_handoff),
        worker_lifecycle_reconciliation: WorkerLifecycleReconciliation.tick_summary(worker_lifecycle_reconciliation),
        migration_boundary: migration_boundary(),
        operator_acknowledgements: operator_acknowledgement_runtime_summary(device_observability.activation_plan),
        registry: registry_summary
      },
      hub_scheduler: scheduler,
      hub_activation_preflight: activation_preflight,
      hub_cutover_gate: cutover_gate,
      hub_cutover_operation_audit: cutover_operation_audit,
      hub_cutover_audit_history: cutover_audit_history,
      hub_cutover_readiness_permit: cutover_readiness_permit,
      hub_cutover_execution_authorization_ledger: cutover_execution_authorization_ledger,
      hub_cutover_authorization_consumption_guard: cutover_authorization_consumption_guard,
      hub_cutover_execution_outcome_ledger: cutover_execution_outcome_ledger,
      hub_cutover_execution_outcome_closeout: cutover_execution_outcome_closeout,
      hub_cutover_replay_decision: cutover_replay_decision,
      hub_cutover_replay_request_audit: cutover_replay_request_audit,
      hub_cutover_closure_chain: cutover_closure_chain,
      hub_cutover_closure_conclusion: cutover_closure_conclusion,
      hub_cutover_closure_report_packet: cutover_closure_report_packet,
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

  defp decode_hub_json_or_yaml(content, path) when is_binary(content) do
    cond do
      String.trim(content) == "" ->
        {:ok, %{}}

      Path.extname(path) == ".json" ->
        Jason.decode(content)

      true ->
        YamlElixir.read_from_string(content)
    end
  end

  defp build_activation_preflight(registry, probe, now) do
    probe =
      case probe do
        fun when is_function(fun, 1) -> safe_activation_probe(fun, registry)
        value when is_map(value) -> value
        _value -> %{}
      end

    ActivationPreflight.build(registry, now: now, probe: probe)
  end

  defp initial_writeback_executor(opts, provider_executor) do
    cond do
      Keyword.has_key?(opts, :writeback_executor) ->
        Keyword.get(opts, :writeback_executor)

      match?({:ok, _value}, Application.fetch_env(:symphony_elixir, @writeback_executor_env_key)) ->
        writeback_executor()

      Keyword.has_key?(opts, :provider_executor) ->
        provider_executor

      true ->
        ProviderExecutor
    end
  end

  defp build_cutover_gate(
         registry,
         now,
         activation_preflight,
         provider_executor,
         writeback_executor,
         worker_start_starter,
         activation_probe,
         operator_acknowledgements,
         scheduler
       ) do
    writeback_summary = writeback_executor_summary(writeback_executor)

    device_projection =
      DeviceObservability.build(
        %{
          hub_runtime:
            hub_runtime_observability(
              provider_executor: provider_executor,
              writeback_executor: writeback_executor,
              activation_probe: activation_probe,
              activation_preflight: activation_preflight,
              worker_start_starter: worker_start_starter
            ),
          registry: registry,
          activation_preflight: activation_preflight,
          scheduler: scheduler,
          runtime_ledger: RuntimeLedger.new(),
          writeback: %{executor: writeback_summary},
          migration_boundary: migration_boundary()
        },
        now: now,
        operator_acknowledgements: operator_acknowledgements
      )

    device_projection.cutover_gate
  end

  defp safe_activation_probe(fun, registry) do
    fun.(registry)
  rescue
    error -> %{status: "unknown", source: "activation_probe", error: Exception.message(error)}
  catch
    kind, reason -> %{status: "unknown", source: "activation_probe", error: "#{kind}: #{safe_error(reason)}"}
  end

  defp maybe_refresh_activation_probe(state, registry, now) do
    refresh? =
      registry_probe_identity(registry) != registry_probe_identity(state.registry) or
        DateTime.diff(now, state.activation_probe_checked_at, :millisecond) >= state.activation_probe_interval_ms

    if refresh? do
      activation_preflight = build_activation_preflight(registry, state.activation_probe, now)
      activation_probe_count = state.activation_probe_count + if(is_function(state.activation_probe, 1), do: 1, else: 0)

      %{
        state
        | activation_preflight: activation_preflight,
          activation_probe_checked_at: now,
          activation_probe_count: activation_probe_count,
          scheduler: Map.put(state.scheduler, :activation_probe_count, activation_probe_count)
      }
    else
      state
    end
  end

  defp registry_probe_identity(registry) do
    registry
    |> list_value(:projects)
    |> Enum.map(fn project ->
      {
        value(project, :project_id),
        value(project, :fingerprint),
        value(project, :snapshot_version),
        status_string(value(project, :status))
      }
    end)
    |> Enum.sort()
  end

  defp activation_preflight_identity(preflight) do
    stable_projection_identity(preflight)
  end

  defp stable_projection_identity(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, _value} -> to_string(key) in ["checked_at", "generated_at", "updated_at"] end)
    |> Map.new(fn {key, item} -> {key, stable_projection_identity(item)} end)
  end

  defp stable_projection_identity(value) when is_list(value), do: Enum.map(value, &stable_projection_identity/1)
  defp stable_projection_identity(value), do: value

  defp run_reconciliation_tick(state, requested_at) do
    started_tick = running_tick(requested_at)

    authorization_consumption_guard =
      authorization_consumption_guard_context(
        state.cutover_execution_authorization_ledger,
        required?: false
      )

    {runtime_ledger, worker_start_handoff} =
      WorkerStartHandoff.run(state.registry, state.runtime_ledger,
        now: requested_at,
        starter: state.worker_start_starter,
        activation_preflight: state.activation_preflight,
        cutover_gate: state.cutover_gate,
        authorization_consumption_guard: authorization_consumption_guard,
        cutover_execution_outcome_ledger: state.cutover_execution_outcome_ledger,
        cutover_execution_outcome_closeout: state.cutover_execution_outcome_closeout
      )

    {runtime_ledger, worker_lifecycle_reconciliation} =
      WorkerLifecycleReconciliation.run(state.registry, runtime_ledger,
        now: requested_at,
        result_source: state.worker_lifecycle_result_source
      )

    finished_at = DateTime.utc_now()

    tick =
      finished_tick(
        started_tick,
        finished_at,
        0,
        [],
        state.candidate_intake,
        state.dispatch_planning,
        state.dispatch_plan_application,
        worker_start_handoff,
        worker_lifecycle_reconciliation
      )
      |> Map.put(:operations, reconciliation_tick_operations())

    ledger_changed? = runtime_ledger != state.runtime_ledger

    state = %{
      state
      | runtime_ledger: runtime_ledger,
        worker_start_handoff: worker_start_handoff,
        worker_lifecycle_reconciliation: worker_lifecycle_reconciliation,
        tick: tick
    }

    state =
      if ledger_changed? do
        refresh_snapshot(state, finished_at)
      else
        refresh_scheduler_snapshot(state, finished_at)
      end

    {state, tick}
  end

  defp run_poll_tick(state, requested_at) do
    started_tick = running_tick(requested_at)

    plan =
      PollCoordinator.build_plan(state.registry,
        now: requested_at,
        facts: state.poll_facts,
        queue: state.provider_queue,
        activation_preflight: state.activation_preflight,
        cutover_gate: poll_cutover_gate(state.provider_executor, state.cutover_gate)
      )

    executable_entries = Enum.filter(plan.projects, &(&1.allow_poll == true))

    authorization_consumption_guard =
      authorization_consumption_guard_context(
        state.cutover_execution_authorization_ledger,
        required?: false
      )

    {poll_facts, provider_queue, result_summaries, intake_sources, poll_results_changed?} =
      Enum.reduce(executable_entries, {state.poll_facts, state.provider_queue, [], [], false}, fn entry, {facts, queue, summaries, intake_sources, changed?} ->
        attempt = PollCoordinator.attempt_fact(entry, attempted_at: requested_at)
        request = request_from_entry(entry)

        {result, queue} =
          request
          |> execute_provider_request(
            state.provider_executor,
            requested_at,
            state.registry,
            state.config_path,
            state.activation_preflight,
            state.cutover_gate,
            authorization_consumption_guard,
            state.cutover_execution_outcome_ledger,
            state.cutover_execution_outcome_closeout
          )
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

        changed? = changed? or poll_result_changed?(facts, result_fact)
        facts = trim_poll_facts([result_fact, attempt | facts])
        summary = poll_result_summary(result, attempt, result_fact, finished_at)
        intake_source = poll_intake_source(entry, request, result, attempt, result_fact, finished_at)

        {facts, queue, [summary | summaries], [intake_source | intake_sources], changed?}
      end)

    finished_at = DateTime.utc_now()

    projection_result =
      if not poll_results_changed? and not runtime_projection_required?(state) do
        {
          state.candidate_intake,
          state.dispatch_planning,
          state.runtime_ledger,
          state.dispatch_plan_application,
          state.worker_start_handoff,
          state.worker_lifecycle_reconciliation
        }
      else
        run_poll_projection_pipeline(state, intake_sources, finished_at, authorization_consumption_guard)
      end

    {
      candidate_intake,
      dispatch_planning,
      runtime_ledger,
      dispatch_plan_application,
      worker_start_handoff,
      worker_lifecycle_reconciliation
    } = projection_result

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
      |> Map.put(:operations, tick_operations())

    next_state = %{
      state
      | poll_facts: poll_facts,
        provider_queue: provider_queue,
        runtime_ledger: runtime_ledger,
        candidate_intake: candidate_intake,
        dispatch_planning: dispatch_planning,
        dispatch_plan_application: dispatch_plan_application,
        worker_start_handoff: worker_start_handoff,
        worker_lifecycle_reconciliation: worker_lifecycle_reconciliation,
        tick: tick
    }

    state =
      if full_poll_snapshot_required?(state, next_state, result_summaries, finished_at) do
        snapshot =
          build_snapshot(next_state.config_path, next_state.loaded_at, next_state.registry,
            now: finished_at,
            poll_facts: next_state.poll_facts,
            activation_preflight: next_state.activation_preflight,
            cutover_gate: next_state.cutover_gate,
            activation_probe: next_state.activation_probe,
            operator_acknowledgements: next_state.operator_acknowledgements,
            cutover_operation_requests: next_state.cutover_operation_requests,
            cutover_audit_history_entries: next_state.cutover_audit_history_entries,
            manual_attention_closeouts: next_state.manual_attention_closeouts,
            cutover_execution_authorization_requests: next_state.cutover_execution_authorization_requests,
            cutover_execution_outcome_closeouts: next_state.cutover_execution_outcome_closeouts,
            cutover_replay_requests: next_state.cutover_replay_requests,
            provider_queue: next_state.provider_queue,
            provider_executor: next_state.provider_executor,
            writeback_executor: next_state.writeback_executor,
            worker_start_starter: next_state.worker_start_starter,
            runtime_ledger: next_state.runtime_ledger,
            candidate_intake: next_state.candidate_intake,
            dispatch_planning: next_state.dispatch_planning,
            dispatch_plan_application: next_state.dispatch_plan_application,
            worker_start_handoff: next_state.worker_start_handoff,
            worker_lifecycle_reconciliation: next_state.worker_lifecycle_reconciliation,
            cutover_execution_outcome_ledger: next_state.cutover_execution_outcome_ledger,
            cutover_execution_outcome_closeout: next_state.cutover_execution_outcome_closeout,
            cutover_replay_request_audit: next_state.cutover_replay_request_audit,
            tick: next_state.tick,
            scheduler: next_state.scheduler
          )

        %{
          next_state
          | cutover_execution_authorization_ledger: snapshot.hub_cutover_execution_authorization_ledger,
            cutover_authorization_consumption_guard: snapshot.hub_cutover_authorization_consumption_guard,
            cutover_execution_outcome_ledger: snapshot.hub_cutover_execution_outcome_ledger,
            cutover_execution_outcome_closeout: snapshot.hub_cutover_execution_outcome_closeout,
            cutover_replay_decision: snapshot.hub_cutover_replay_decision,
            cutover_replay_request_audit: snapshot.hub_cutover_replay_request_audit,
            cutover_closure_chain: snapshot.hub_cutover_closure_chain,
            cutover_closure_conclusion: snapshot.hub_cutover_closure_conclusion,
            cutover_closure_report_packet: snapshot.hub_cutover_closure_report_packet,
            snapshot_refreshed_at: finished_at,
            snapshot: snapshot
        }
      else
        refresh_poll_snapshot(next_state, finished_at)
      end

    {state, tick}
  end

  defp poll_result_changed?(facts, result_fact) do
    project_id = value(result_fact, :project_id)

    previous =
      Enum.find(facts, fn fact ->
        status_string(value(fact, :fact_type)) == "poll_result" and
          value(fact, :project_id) == project_id
      end)

    is_nil(previous) or
      {
        status_string(value(previous, :status)),
        value(previous, :config_fingerprint),
        stable_projection_identity(value(previous, :result_summary) || %{})
      } !=
        {
          status_string(value(result_fact, :status)),
          value(result_fact, :config_fingerprint),
          stable_projection_identity(value(result_fact, :result_summary) || %{})
        }
  end

  defp runtime_projection_required?(state) do
    state.runtime_ledger
    |> RuntimeLedger.replay()
    |> list_value(:projects)
    |> Enum.any?(fn project ->
      list_value(project, :active_attempts) != [] or
        list_value(project, :pending_start_intents) != [] or
        list_value(project, :retry_backoff) != []
    end)
  end

  defp run_poll_projection_pipeline(state, intake_sources, finished_at, authorization_consumption_guard) do
    candidate_intake =
      CandidateIntake.build(state.registry, Enum.reverse(intake_sources),
        now: finished_at,
        runtime_ledger: state.runtime_ledger,
        activation_preflight: state.activation_preflight,
        cutover_gate: state.cutover_gate
      )

    dispatch_planning =
      DispatchPlanning.build(state.registry, candidate_intake,
        now: finished_at,
        runtime_ledger: state.runtime_ledger,
        previous_plan: state.dispatch_planning,
        activation_preflight: state.activation_preflight,
        cutover_gate: state.cutover_gate
      )

    {runtime_ledger, dispatch_plan_application} =
      DispatchPlanApplication.apply_plan(state.registry, dispatch_planning, state.runtime_ledger,
        now: finished_at,
        activation_preflight: state.activation_preflight,
        cutover_gate: state.cutover_gate,
        authorization_consumption_guard: authorization_consumption_guard,
        cutover_execution_outcome_ledger: state.cutover_execution_outcome_ledger,
        cutover_execution_outcome_closeout: state.cutover_execution_outcome_closeout
      )

    {runtime_ledger, worker_start_handoff} =
      WorkerStartHandoff.run(state.registry, runtime_ledger,
        now: finished_at,
        starter: state.worker_start_starter,
        activation_preflight: state.activation_preflight,
        cutover_gate: state.cutover_gate,
        authorization_consumption_guard: authorization_consumption_guard,
        cutover_execution_outcome_ledger: state.cutover_execution_outcome_ledger,
        cutover_execution_outcome_closeout: state.cutover_execution_outcome_closeout
      )

    {runtime_ledger, worker_lifecycle_reconciliation} =
      WorkerLifecycleReconciliation.run(state.registry, runtime_ledger,
        now: finished_at,
        result_source: state.worker_lifecycle_result_source
      )

    {candidate_intake, dispatch_planning} =
      if runtime_ledger == state.runtime_ledger do
        {candidate_intake, dispatch_planning}
      else
        candidate_intake =
          CandidateIntake.build(state.registry, Enum.reverse(intake_sources),
            now: finished_at,
            runtime_ledger: runtime_ledger,
            activation_preflight: state.activation_preflight,
            cutover_gate: state.cutover_gate
          )

        dispatch_planning =
          DispatchPlanning.build(state.registry, candidate_intake,
            now: finished_at,
            runtime_ledger: runtime_ledger,
            previous_plan: dispatch_planning,
            activation_preflight: state.activation_preflight,
            cutover_gate: state.cutover_gate
          )

        {candidate_intake, dispatch_planning}
      end

    {
      candidate_intake,
      dispatch_planning,
      runtime_ledger,
      dispatch_plan_application,
      worker_start_handoff,
      worker_lifecycle_reconciliation
    }
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

        state = state |> Map.put(:scheduler, scheduler) |> refresh_scheduler_snapshot(requested_at)
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

        state = state |> Map.put(:scheduler, scheduler) |> refresh_scheduler_snapshot(requested_at)
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
        "hub_cutover_operation_audit",
        "hub_cutover_audit_history",
        "hub_cutover_readiness_permit",
        "hub_cutover_execution_authorization_ledger",
        "hub_cutover_authorization_consumption_guard",
        "hub_cutover_execution_outcome_ledger",
        "hub_cutover_execution_outcome_closeout",
        "hub_cutover_replay_decision",
        "hub_cutover_replay_request_audit",
        "hub_cutover_closure_chain",
        "hub_cutover_closure_conclusion",
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

    state = state |> Map.put(:scheduler, scheduler) |> refresh_scheduler_snapshot(requested_at)

    task =
      Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        result = run_async_tick(state, requested_at, reason)
        {:hub_scheduler_tick_result, result}
      end)

    scheduler = %{state.scheduler | running_ref: task.ref}
    Map.put(state, :scheduler, scheduler)
  end

  defp run_async_tick(state, requested_at, reason) when reason in ["runtime_reconciliation", "invalid_retry_backoff"] do
    state
    |> run_reconciliation_tick(requested_at)
    |> then(fn {state, tick_summary} -> {:ok, state, tick_summary} end)
  end

  defp run_async_tick(state, requested_at, _reason) do
    case load_registry(state.config_path) do
      {:ok, registry} ->
        previous_activation_preflight = state.activation_preflight
        previous_registry = state.registry
        state = maybe_refresh_activation_probe(state, registry, requested_at)
        activation_preflight = state.activation_preflight

        cutover_gate =
          if registry_probe_identity(previous_registry) != registry_probe_identity(registry) or
               activation_preflight_identity(previous_activation_preflight) !=
                 activation_preflight_identity(activation_preflight) do
            build_cutover_gate(
              registry,
              requested_at,
              activation_preflight,
              state.provider_executor,
              state.writeback_executor,
              state.worker_start_starter,
              state.activation_probe,
              state.operator_acknowledgements,
              state.scheduler
            )
          else
            state.cutover_gate
          end

        state
        |> Map.merge(%{loaded_at: requested_at, registry: registry, activation_preflight: activation_preflight, cutover_gate: cutover_gate})
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
    schedule = next_schedule(tick_state, finished_at)

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
        project_summaries: scheduler_project_summaries(tick_state, finished_at),
        activation_probe_count: tick_state.activation_probe_count,
        earliest_retry_due_at: schedule.earliest_retry_due_at,
        invalid_retry_count: schedule.invalid_retry_count,
        realtime_count: schedule.realtime_count
      })

    tick_state
    |> Map.put(:scheduler, scheduler)
    |> schedule_next_tick(finished_at, schedule.reason, schedule.delay_ms)
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

    state |> Map.put(:scheduler, scheduler) |> refresh_scheduler_snapshot(now)
  end

  defp refresh_snapshot(state, now) do
    snapshot =
      build_snapshot(state.config_path, state.loaded_at, state.registry,
        now: now,
        poll_facts: state.poll_facts,
        activation_preflight: state.activation_preflight,
        cutover_gate: state.cutover_gate,
        activation_probe: state.activation_probe,
        operator_acknowledgements: state.operator_acknowledgements,
        cutover_operation_requests: state.cutover_operation_requests,
        cutover_audit_history_entries: state.cutover_audit_history_entries,
        manual_attention_closeouts: state.manual_attention_closeouts,
        cutover_execution_authorization_requests: state.cutover_execution_authorization_requests,
        cutover_execution_outcome_closeouts: state.cutover_execution_outcome_closeouts,
        cutover_replay_requests: state.cutover_replay_requests,
        cutover_execution_authorization_ledger: state.cutover_execution_authorization_ledger,
        cutover_authorization_consumption_guard: state.cutover_authorization_consumption_guard,
        cutover_execution_outcome_ledger: state.cutover_execution_outcome_ledger,
        cutover_execution_outcome_closeout: state.cutover_execution_outcome_closeout,
        cutover_replay_decision: state.cutover_replay_decision,
        cutover_replay_request_audit: state.cutover_replay_request_audit,
        provider_queue: state.provider_queue,
        provider_executor: state.provider_executor,
        writeback_executor: state.writeback_executor,
        worker_start_starter: state.worker_start_starter,
        runtime_ledger: state.runtime_ledger,
        candidate_intake: state.candidate_intake,
        dispatch_planning: state.dispatch_planning,
        dispatch_plan_application: state.dispatch_plan_application,
        worker_start_handoff: state.worker_start_handoff,
        worker_lifecycle_reconciliation: state.worker_lifecycle_reconciliation,
        tick: state.tick,
        scheduler: state.scheduler
      )

    %{
      state
      | snapshot: snapshot,
        snapshot_refreshed_at: now,
        cutover_closure_chain: snapshot.hub_cutover_closure_chain,
        cutover_closure_conclusion: snapshot.hub_cutover_closure_conclusion,
        cutover_closure_report_packet: snapshot.hub_cutover_closure_report_packet
    }
  end

  defp full_poll_snapshot_required?(previous_state, next_state, result_summaries, now) do
    DateTime.diff(now, previous_state.snapshot_refreshed_at, :millisecond) >=
      previous_state.snapshot_refresh_interval_ms or
      next_state.runtime_ledger != previous_state.runtime_ledger or
      Enum.any?(result_summaries, &(status_string(value(&1, :status)) != "success")) or
      registry_probe_identity(next_state.registry) !=
        registry_probe_identity(value(previous_state.snapshot, :hub_project_registry) || %{}) or
      activation_preflight_identity(next_state.activation_preflight) !=
        activation_preflight_identity(value(previous_state.snapshot, :hub_activation_preflight) || %{}) or
      stable_projection_identity(next_state.cutover_gate) !=
        stable_projection_identity(value(previous_state.snapshot, :hub_cutover_gate) || %{})
  end

  defp refresh_poll_snapshot(state, now) do
    poll_plan =
      PollCoordinator.build_plan(state.registry,
        now: now,
        facts: state.poll_facts,
        queue: state.provider_queue,
        activation_preflight: state.activation_preflight,
        cutover_gate: poll_cutover_gate(state.provider_executor, state.cutover_gate)
      )

    scheduler =
      normalize_scheduler(
        state.scheduler,
        poll_plan,
        state.runtime_ledger,
        state.worker_start_handoff,
        state.worker_lifecycle_reconciliation,
        now
      )

    snapshot =
      state.snapshot
      |> Map.put(:hub_scheduler, scheduler)
      |> Map.put(:hub_activation_preflight, state.activation_preflight)
      |> Map.put(:hub_cutover_gate, state.cutover_gate)
      |> Map.put(:hub_project_registry, registry_summary(state.registry))
      |> Map.put(:hub_poll_coordination, poll_plan)
      |> Map.put(:hub_candidate_intake, state.candidate_intake)
      |> Map.put(:hub_dispatch_planning, state.dispatch_planning)
      |> Map.put(:hub_dispatch_plan_application, state.dispatch_plan_application)
      |> Map.put(:hub_worker_start_handoff, state.worker_start_handoff)
      |> Map.put(:hub_worker_lifecycle_reconciliation, state.worker_lifecycle_reconciliation)
      |> Map.put(:hub_dispatch_boundary, state.runtime_ledger)
      |> Map.update(:hub_runtime, %{}, fn runtime ->
        runtime
        |> Map.put(:generated_at, iso8601(now))
        |> Map.put(:loaded_at, iso8601(state.loaded_at))
        |> Map.put(:scheduler, scheduler)
        |> Map.put(:activation_preflight, state.activation_preflight)
        |> Map.put(:cutover_gate, state.cutover_gate)
        |> Map.put(:poll_tick, state.tick)
        |> Map.put(:candidate_intake, CandidateIntake.tick_summary(state.candidate_intake))
        |> Map.put(:dispatch_planning, DispatchPlanning.tick_summary(state.dispatch_planning))
        |> Map.put(:dispatch_plan_application, DispatchPlanApplication.tick_summary(state.dispatch_plan_application))
        |> Map.put(:worker_start_handoff, WorkerStartHandoff.tick_summary(state.worker_start_handoff))
        |> Map.put(
          :worker_lifecycle_reconciliation,
          WorkerLifecycleReconciliation.tick_summary(state.worker_lifecycle_reconciliation)
        )
        |> Map.put(:registry, registry_summary(state.registry))
      end)
      |> Map.update(:hub_device_observability, %{}, fn device ->
        Map.update(device, :overview, %{}, &Map.put(&1, :scheduler, scheduler_device_overview(scheduler)))
      end)

    %{state | snapshot: snapshot}
  end

  defp refresh_scheduler_snapshot(state, now) do
    scheduler =
      normalize_scheduler(
        state.scheduler,
        PollCoordinator.build_plan(state.registry,
          now: now,
          facts: state.poll_facts,
          queue: state.provider_queue,
          activation_preflight: state.activation_preflight,
          cutover_gate: poll_cutover_gate(state.provider_executor, state.cutover_gate)
        ),
        state.runtime_ledger,
        state.worker_start_handoff,
        state.worker_lifecycle_reconciliation,
        now
      )

    snapshot =
      state.snapshot
      |> Map.put(:hub_scheduler, scheduler)
      |> Map.update(:hub_runtime, %{}, fn runtime ->
        runtime
        |> Map.put(:scheduler, scheduler)
        |> Map.put(:poll_tick, state.tick)
      end)
      |> Map.update(:hub_device_observability, %{}, fn device ->
        Map.update(device, :overview, %{}, &Map.put(&1, :scheduler, scheduler_device_overview(scheduler)))
      end)

    %{state | snapshot: snapshot}
  end

  defp scheduler_device_overview(scheduler) do
    %{
      enabled: scheduler.enabled,
      status: scheduler.status,
      queued: scheduler.queued,
      running: scheduler.running?,
      coalesced: scheduler.coalesced,
      next_tick_at: scheduler.next_tick_at,
      next_reason: scheduler.next_reason,
      last_reason: get_in(scheduler, [:last_tick, :reason]),
      last_error: Map.get(scheduler, :last_error),
      counts: scheduler.counts,
      unresolved_runtime: scheduler.unresolved_runtime
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp next_schedule(state, now) do
    plan =
      PollCoordinator.build_plan(state.registry,
        now: now,
        facts: state.poll_facts,
        queue: state.provider_queue,
        activation_preflight: state.activation_preflight,
        cutover_gate: poll_cutover_gate(state.provider_executor, state.cutover_gate)
      )

    Scheduler.next_schedule(plan, state.runtime_ledger, now,
      realtime_delay_ms: @scheduler_unresolved_delay_ms,
      invalid_retry_delay_ms: @scheduler_error_backoff_ms,
      default_delay_ms: @scheduler_default_delay_ms
    )
  end

  defp scheduler_project_summaries(state, now) do
    plan =
      PollCoordinator.build_plan(state.registry,
        now: now,
        facts: state.poll_facts,
        queue: state.provider_queue,
        activation_preflight: state.activation_preflight,
        cutover_gate: poll_cutover_gate(state.provider_executor, state.cutover_gate)
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

  defp scheduler_duration_ms(nil, _finished_at), do: nil

  defp scheduler_duration_ms(%DateTime{} = started_at, %DateTime{} = finished_at) do
    max(DateTime.diff(finished_at, started_at, :millisecond), 0)
  end

  defp normalize_delay_ms(delay_ms) when is_integer(delay_ms) and delay_ms <= 0, do: 0
  defp normalize_delay_ms(delay_ms) when is_integer(delay_ms) and delay_ms < @scheduler_min_delay_ms, do: @scheduler_min_delay_ms
  defp normalize_delay_ms(delay_ms) when is_integer(delay_ms), do: delay_ms

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

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
      activation_probe_count: 0,
      earliest_retry_due_at: nil,
      invalid_retry_count: 0,
      realtime_count: 0,
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
      earliest_retry_due_at: iso8601(value(scheduler, :earliest_retry_due_at)),
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
        error_count: non_negative_integer(value(scheduler, :error_count)) || 0,
        activation_probe_count: non_negative_integer(value(scheduler, :activation_probe_count)) || 0,
        invalid_retry_count: non_negative_integer(value(scheduler, :invalid_retry_count)) || 0,
        realtime_count: non_negative_integer(value(scheduler, :realtime_count)) || 0
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
      "hub_cutover_operation_audit",
      "hub_cutover_audit_history",
      "hub_cutover_readiness_permit",
      "hub_cutover_execution_authorization_ledger",
      "hub_cutover_authorization_consumption_guard",
      "hub_cutover_execution_outcome_ledger",
      "hub_cutover_execution_outcome_closeout",
      "hub_cutover_replay_decision",
      "hub_cutover_replay_request_audit",
      "hub_cutover_closure_chain",
      "hub_cutover_closure_conclusion",
      "hub_cutover_closure_report_packet",
      "hub_device_observability"
    ]
  end

  defp reconciliation_tick_operations do
    [
      "hub_worker_start_handoff",
      "hub_worker_lifecycle_reconciliation",
      "hub_scheduler_reconciliation"
    ]
  end

  defp writeback_summary(runtime_ledger, provider_queue, writeback_executor) do
    replay = RuntimeLedger.replay(runtime_ledger)
    projects = Enum.map(replay.projects, &project_writeback_summary/1)
    counts = sum_writeback_counts(projects)

    %{
      executor: writeback_executor_summary(writeback_executor),
      counts: counts,
      projects: projects,
      queue: provider_writeback_queue_summary(provider_queue),
      recent_errors: recent_writeback_errors(projects)
    }
  end

  defp poll_cutover_gate(provider_executor, cutover_gate) do
    provider_summary = provider_executor_summary(provider_executor)

    if provider_summary.provider_io == true and "candidate_scan" in list_value(provider_summary, :supported_operations) do
      cutover_gate
    else
      nil
    end
  end

  defp project_writeback_summary(project) do
    writebacks = value(project, :writebacks) || %{}
    counts = value(writebacks, :counts) || %{}
    failed = list_value(writebacks, :failed)
    unknown = list_value(writebacks, :unknown)
    manual_attention = list_value(writebacks, :manual_attention)

    %{
      project_id: value(project, :project_id),
      counts: normalize_writeback_counts(counts),
      pending_count: count_value(counts, :pending),
      failed_count: count_value(counts, :failed),
      unknown_count: count_value(counts, :unknown),
      manual_attention_count: count_value(counts, :manual_attention),
      recent_error_classes: recent_error_classes(failed ++ unknown ++ manual_attention)
    }
  end

  defp normalize_writeback_counts(counts) when is_map(counts) do
    %{
      pending: count_value(counts, :pending),
      succeeded: count_value(counts, :succeeded),
      failed: count_value(counts, :failed),
      unknown: count_value(counts, :unknown),
      manual_attention: count_value(counts, :manual_attention)
    }
  end

  defp normalize_writeback_counts(_counts), do: normalize_writeback_counts(%{})

  defp sum_writeback_counts(projects) do
    Enum.reduce(projects, normalize_writeback_counts(%{}), fn project, totals ->
      counts = value(project, :counts) || %{}

      totals
      |> Map.update!(:pending, &(&1 + count_value(counts, :pending)))
      |> Map.update!(:succeeded, &(&1 + count_value(counts, :succeeded)))
      |> Map.update!(:failed, &(&1 + count_value(counts, :failed)))
      |> Map.update!(:unknown, &(&1 + count_value(counts, :unknown)))
      |> Map.update!(:manual_attention, &(&1 + count_value(counts, :manual_attention)))
    end)
  end

  defp provider_writeback_queue_summary(queue) when is_map(queue) do
    writeback_operations = ["stage_writeback", "comment_workpad_upsert", "pr_create"]
    summary = ProviderGovernance.queue_summary(queue)

    pending =
      summary.pending
      |> Enum.filter(&(status_string(value(&1, :operation_kind)) in writeback_operations))
      |> Enum.map(&Map.take(&1, [:request_id, :logical_key, :project_id, :provider_scope_key, :operation_kind, :wait_ms, :backpressure]))

    recent_results =
      summary.recent_results
      |> Enum.filter(&(status_string(value(&1, :operation_kind)) in writeback_operations))
      |> Enum.map(&Map.take(&1, [:request_id, :logical_key, :project_id, :provider_scope_key, :operation_kind, :status, :error_class, :manual_attention]))

    %{
      pending_count: length(pending),
      recent_result_count: length(recent_results),
      pending: pending,
      recent_results: recent_results
    }
  end

  defp provider_writeback_queue_summary(_queue), do: %{pending_count: 0, recent_result_count: 0, pending: [], recent_results: []}

  defp recent_error_classes(writebacks) do
    writebacks
    |> Enum.map(fn writeback ->
      status_string(value(writeback, :provider_result_status)) ||
        status_string(value(writeback, :manual_attention_reason))
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(5)
  end

  defp recent_writeback_errors(projects) do
    projects
    |> Enum.flat_map(fn project ->
      Enum.map(value(project, :recent_error_classes) || [], fn error_class ->
        %{project_id: value(project, :project_id), error_class: error_class}
      end)
    end)
    |> Enum.take(10)
  end

  defp count_value(map, key) when is_map(map), do: non_negative_integer(value(map, key)) || 0
  defp count_value(_map, _key), do: 0

  defp operator_acknowledgement_runtime_summary(activation_plan) when is_map(activation_plan) do
    %{
      status: value(activation_plan, :status),
      counts: value(activation_plan, :counts) || %{},
      safety_gates: value(activation_plan, :safety_gates) || [],
      global_blocking_risk_count: length(list_value(activation_plan, :global_blocking_risks)),
      global_advisory_risk_count: length(list_value(activation_plan, :global_advisory_risks))
    }
  end

  defp hub_runtime_observability(opts) do
    provider_executor = Keyword.get(opts, :provider_executor, ProviderExecutor)
    writeback_executor = Keyword.get(opts, :writeback_executor, provider_executor)
    activation_probe = Keyword.get(opts, :activation_probe)
    activation_preflight = Keyword.get(opts, :activation_preflight)
    worker_start_starter = Keyword.get(opts, :worker_start_starter)
    provider_summary = provider_executor_summary(provider_executor)
    writeback_summary = writeback_executor_summary(writeback_executor)

    %{
      enabled: true,
      mode: "hub",
      read_only: Keyword.get(opts, :read_only, false) == true,
      provider_executor: provider_summary,
      writeback_executor: writeback_summary,
      worker_starter: worker_starter_summary(worker_start_starter),
      activation_probe: activation_probe_summary(activation_probe, activation_preflight)
    }
  end

  defp worker_starter_summary(nil) do
    %{
      mode: "skeleton",
      starter: "default_skeleton",
      worker_start: false
    }
  end

  defp worker_starter_summary(starter) when is_function(starter, 2) do
    %{
      mode: "real_worker_starter",
      starter: "anonymous_function",
      worker_start: true
    }
  end

  defp worker_starter_summary(starter) when is_atom(starter) do
    case Atom.to_string(starter) do
      "Elixir.SymphonyElixir.Hub.RealWorkerStarter" ->
        %{
          mode: "real_worker_starter",
          starter: "real_worker_starter",
          worker_start: true
        }

      _other ->
        %{
          mode: "custom_module",
          starter: inspect(starter),
          worker_start: "unknown"
        }
    end
  end

  defp worker_starter_summary(_starter) do
    %{
      mode: "invalid",
      starter: "invalid",
      worker_start: false
    }
  end

  defp activation_probe_summary(nil, activation_preflight) do
    %{
      mode: "injected_none",
      source: activation_probe_source(activation_preflight),
      host_service_probe: false
    }
  end

  defp activation_probe_summary(probe, activation_preflight) when is_function(probe, 1) do
    source = activation_probe_source(activation_preflight)

    %{
      mode: activation_probe_mode(source),
      source: source,
      host_service_probe: source == "host_service_probe"
    }
  end

  defp activation_probe_summary(probe, activation_preflight) when is_map(probe) do
    source =
      status_string(value(probe, :source)) ||
        status_string(value(probe, :probe_source)) ||
        activation_probe_source(activation_preflight)

    %{
      mode: activation_probe_mode(source),
      source: source,
      host_service_probe: source == "host_service_probe"
    }
  end

  defp activation_probe_summary(_probe, activation_preflight) do
    %{
      mode: "invalid",
      source: activation_probe_source(activation_preflight),
      host_service_probe: false
    }
  end

  defp activation_probe_source(activation_preflight) do
    activation_preflight
    |> list_value(:projects)
    |> Enum.find_value(&status_string(value(&1, :probe_source)))
    |> case do
      nil -> "injected"
      source -> source
    end
  end

  defp activation_probe_mode("host_service_probe"), do: "host_service"
  defp activation_probe_mode("injected"), do: "injected"
  defp activation_probe_mode(nil), do: "injected_none"
  defp activation_probe_mode(_source), do: "custom"

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

  defp provider_executor_summary(RealWritebackExecutor) do
    %{
      mode: "real_writeback",
      executor: "real_writeback",
      provider_io: true,
      supported_operations: RealWritebackExecutor.supported_operations(),
      supported_logical_actions: RealWritebackExecutor.supported_logical_actions(),
      rejected_operations: RealWritebackExecutor.rejected_operations()
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
      mode: "real_candidate_scan",
      executor: "anonymous_function",
      provider_io: true,
      supported_operations: ["candidate_scan"]
    }
  end

  defp provider_executor_summary(_executor) do
    %{
      mode: "invalid",
      executor: "invalid",
      provider_io: false
    }
  end

  defp writeback_executor_summary(ProviderExecutor), do: provider_executor_summary(ProviderExecutor)

  defp writeback_executor_summary(nil), do: provider_executor_summary(ProviderExecutor)

  defp writeback_executor_summary(RealWritebackExecutor), do: provider_executor_summary(RealWritebackExecutor)

  defp writeback_executor_summary(RealCandidateScanExecutor), do: provider_executor_summary(RealCandidateScanExecutor)

  defp writeback_executor_summary(executor) when is_function(executor, 2) do
    %{
      mode: "custom_writeback_function",
      executor: "anonymous_function",
      provider_io: "unknown",
      supported_operations: []
    }
  end

  defp writeback_executor_summary(executor), do: provider_executor_summary(executor)

  defp authorization_consumption_guard_context(ledger, opts) when is_map(ledger) and is_list(opts) do
    ledger = CutoverExecutionAuthorization.to_snapshot(ledger)
    counts = value(ledger, :counts) || %{}

    if Keyword.get(opts, :required?, false) == true or count_value(counts, :authorization_request_count) > 0 or count_value(counts, :record_count) > 0 do
      %{authorization_ledger: ledger}
    end
  end

  defp authorization_consumption_guard_context(_ledger, opts) when is_list(opts) do
    if Keyword.get(opts, :required?, false) == true do
      %{authorization_ledger: CutoverExecutionAuthorization.to_snapshot(%{})}
    end
  end

  defp execute_provider_request(
         nil,
         _executor,
         _started_at,
         _registry,
         _config_path,
         _activation_preflight,
         _cutover_gate,
         _authorization_consumption_guard,
         _cutover_execution_outcome_ledger,
         _cutover_execution_outcome_closeout
       ) do
    {:error, :missing_provider_request}
  end

  defp execute_provider_request(
         request,
         executor,
         started_at,
         registry,
         config_path,
         activation_preflight,
         cutover_gate,
         authorization_consumption_guard,
         cutover_execution_outcome_ledger,
         cutover_execution_outcome_closeout
       )
       when is_function(executor, 2) do
    safe_execute_provider_request(fn ->
      executor.(request,
        started_at: started_at,
        registry: registry,
        hub_config_path: config_path,
        activation_preflight: activation_preflight,
        cutover_gate: cutover_gate,
        authorization_consumption_guard: authorization_consumption_guard,
        cutover_execution_outcome_ledger: cutover_execution_outcome_ledger,
        cutover_execution_outcome_closeout: cutover_execution_outcome_closeout
      )
    end)
  end

  defp execute_provider_request(
         request,
         executor,
         started_at,
         registry,
         config_path,
         activation_preflight,
         cutover_gate,
         authorization_consumption_guard,
         cutover_execution_outcome_ledger,
         cutover_execution_outcome_closeout
       )
       when is_atom(executor) do
    safe_execute_provider_request(fn ->
      executor.execute(request,
        started_at: started_at,
        registry: registry,
        hub_config_path: config_path,
        activation_preflight: activation_preflight,
        cutover_gate: cutover_gate,
        authorization_consumption_guard: authorization_consumption_guard,
        cutover_execution_outcome_ledger: cutover_execution_outcome_ledger,
        cutover_execution_outcome_closeout: cutover_execution_outcome_closeout
      )
    end)
  end

  defp execute_provider_request(
         _request,
         _executor,
         _started_at,
         _registry,
         _config_path,
         _activation_preflight,
         _cutover_gate,
         _authorization_consumption_guard,
         _cutover_execution_outcome_ledger,
         _cutover_execution_outcome_closeout
       ) do
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
      operations: [],
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
      operations: [],
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
      operations: [],
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
      operations: Map.get(tick, :operations) || Map.get(tick, "operations") || [],
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
      migration_state: Map.get(project, :migration_state),
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
