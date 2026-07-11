defmodule SymphonyElixir.Hub.RealWorkerStarter do
  @moduledoc """
  Opt-in Hub worker starter that hands safe start intents to the existing
  AgentRunner/Workspace/Codex boundary.

  The default Hub runtime does not use this module. It is selected only by an
  explicit runtime option or CLI flag, so legacy single-project orchestration
  and the Hub skeleton handoff remain unchanged by default.
  """

  require Logger

  alias SymphonyElixir.{AgentRunner, TrackerConfig, Workflow}
  alias SymphonyElixir.Linear.Issue

  @runner_env_key :hub_worker_start_runner
  @start_timeout_ms 30_000
  @retry_delay_ms 30_000

  @type start_result :: %{
          required(:status) => String.t(),
          optional(:reason) => String.t(),
          optional(:error_summary) => String.t(),
          optional(:failure_status) => String.t(),
          optional(:due_at) => String.t(),
          optional(:session_id) => String.t(),
          optional(:worker_host) => String.t() | nil,
          optional(:workspace_path) => String.t() | nil,
          optional(:started_at) => String.t(),
          optional(:last_activity_at) => String.t(),
          optional(:worker_identity) => map(),
          optional(:runtime_context) => map()
        }

  @spec set_runner(module() | function() | nil) :: :ok
  def set_runner(runner) when is_atom(runner) or is_function(runner, 5) or is_nil(runner) do
    Application.put_env(:symphony_elixir, @runner_env_key, runner)
    :ok
  end

  @spec clear_runner() :: :ok
  def clear_runner do
    Application.delete_env(:symphony_elixir, @runner_env_key)
    :ok
  end

  @spec start(map(), keyword()) :: start_result()
  def start(request, opts \\ [])

  @spec start(map(), keyword()) :: start_result()
  def start(request, opts) when is_map(request) and is_list(opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    with {:ok, issue} <- issue_from_request(request),
         {:ok, runtime} <- runtime_from_request(request),
         {:ok, worker} <- start_worker_task(request, issue, runtime) do
      ack_result(request, issue, runtime, worker, now)
    else
      {:error, reason} ->
        failure_result(request, reason, now)
    end
  end

  def start(_request, _opts) do
    %{
      status: "manual_attention",
      reason: "invalid_handoff_request",
      error_summary: "Hub worker starter received an invalid handoff request",
      failure_status: "manual_attention"
    }
  end

  defp start_worker_task(request, issue, runtime) do
    runner = Application.get_env(:symphony_elixir, @runner_env_key, __MODULE__)
    starter = self()

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           install_project_runtime(runtime, fn ->
             execute_runner(runner, issue, request, runtime, starter)
           end)
         end) do
      {:ok, pid} ->
        Logger.info(
          "Hub worker start handoff launched worker project_id=#{safe_log(request, :project_id)} " <>
            "issue_key=#{safe_log(request, :issue_key)} attempt_id=#{safe_log(request, :attempt_id)} " <>
            "pid=#{inspect(pid)} worker_host=#{runtime.worker_host || "local"}"
        )

        await_worker_start(pid, issue.id, request, runtime)

      {:error, reason} ->
        {:error, {:worker_spawn_failed, reason}}
    end
  end

  @doc false
  @spec run_agent(Issue.t(), map(), map(), pid()) :: :ok
  def run_agent(%Issue{} = issue, _request, runtime, recipient) when is_map(runtime) and is_pid(recipient) do
    AgentRunner.run(issue, recipient, worker_host: runtime.worker_host)
  end

  defp execute_runner(__MODULE__, issue, request, runtime, recipient), do: run_agent(issue, request, runtime, recipient)
  defp execute_runner(runner, issue, request, runtime, recipient) when is_function(runner, 5), do: runner.(issue, request, runtime, recipient, [])
  defp execute_runner(runner, issue, request, runtime, recipient) when is_atom(runner), do: runner.run(issue, request, runtime, recipient)
  defp execute_runner(_runner, _issue, _request, _runtime, _recipient), do: raise(ArgumentError, "invalid Hub worker runner")

  defp await_worker_start(pid, issue_id, request, runtime) do
    ref = Process.monitor(pid)
    timeout_ms = start_timeout_ms()

    receive_worker_start(
      pid,
      ref,
      issue_id,
      request,
      runtime,
      %{
        workspace_path: nil,
        worker_host: runtime.worker_host
      },
      timeout_ms
    )
  end

  defp receive_worker_start(pid, ref, issue_id, request, runtime, observed, timeout_ms) do
    receive do
      {:worker_runtime_info, ^issue_id, runtime_info} when is_map(runtime_info) ->
        observed =
          observed
          |> Map.put(:workspace_path, optional_string(runtime_info, :workspace_path))
          |> Map.put(:worker_host, optional_string(runtime_info, :worker_host) || observed.worker_host)

        case validate_observed_workspace(request, observed.workspace_path) do
          :ok ->
            receive_worker_start(pid, ref, issue_id, request, runtime, observed, timeout_ms)

          {:error, reason} ->
            terminate_task(pid, ref)
            {:error, reason}
        end

      {:codex_worker_update, ^issue_id, %{event: :session_started} = update} ->
        Process.demonitor(ref, [:flush])

        {:ok,
         %{
           pid: pid,
           ref: ref,
           session_id: optional_string(update, :session_id),
           codex_app_server_pid: optional_string(update, :codex_app_server_pid),
           workspace_path: observed.workspace_path || runtime.workspace_path,
           worker_host: observed.worker_host,
           started_at: value(update, :timestamp)
         }}

      {:codex_worker_update, ^issue_id, %{event: event} = update}
      when event in [:startup_failed, :turn_ended_with_error, :turn_failed, :turn_cancelled] ->
        terminate_task(pid, ref)
        {:error, {:worker_start_failed, safe_update_reason(update)}}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:worker_exited_before_ack, reason}}
    after
      timeout_ms ->
        terminate_task(pid, ref)
        {:error, {:worker_start_timeout, timeout_ms}}
    end
  end

  defp issue_from_request(request) do
    issue_ref = value(request, :issue_ref) || %{}

    with {:ok, issue_id} <- required_string(issue_ref, :provider_issue_id),
         {:ok, identifier} <- required_string(issue_ref, :identifier),
         {:ok, state} <- required_string(request, :current_stage) do
      {:ok,
       %Issue{
         id: issue_id,
         identifier: identifier,
         title: identifier,
         description: hub_issue_description(request),
         state: state,
         url: optional_string(issue_ref, :url),
         labels: [],
         assigned_to_worker: true
       }}
    end
  end

  defp runtime_from_request(request) do
    with {:ok, workflow_path} <- required_string(request, :workflow_file_path),
         {:ok, tracker_config_path} <- required_string(request, :tracker_file_path),
         {:ok, workspace_path} <- required_string(request, :workspace_path) do
      {:ok,
       %{
         workflow_path: workflow_path,
         tracker_config_path: tracker_config_path,
         workspace_path: workspace_path,
         worker_host: optional_string(request, :worker_host),
         current_stage: optional_string(request, :current_stage)
       }}
    end
  end

  defp install_project_runtime(runtime, fun) when is_map(runtime) and is_function(fun, 0) do
    previous_workflow_path = Workflow.workflow_file_path()
    previous_tracker_config_path = TrackerConfig.tracker_file_path()

    try do
      Workflow.set_workflow_file_path(runtime.workflow_path)
      TrackerConfig.set_tracker_file_path(runtime.tracker_config_path)
      fun.()
    after
      Workflow.set_workflow_file_path(previous_workflow_path)
      TrackerConfig.set_tracker_file_path(previous_tracker_config_path)
    end
  end

  defp ack_result(request, issue, runtime, worker, now) do
    pid_text = inspect(worker.pid)
    ref_text = inspect(worker.ref)
    started_at = iso8601(now)
    last_activity_at = iso8601_or_nil(worker.started_at) || started_at

    %{
      status: "ack",
      reason: "real_worker_started",
      session_id: worker.session_id || "hub-worker:#{safe_token(request, :start_intent_id)}:#{safe_token(pid_text)}",
      worker_host: worker.worker_host,
      workspace_path: worker.workspace_path || runtime.workspace_path,
      started_at: started_at,
      last_activity_at: last_activity_at,
      starts_agent: true,
      creates_workspace: true,
      executes_hooks: true,
      writes_provider: false,
      worker_identity: %{
        pid: pid_text,
        ref: ref_text,
        codex_app_server_pid: worker.codex_app_server_pid,
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        worker_host: worker.worker_host || "local",
        workspace_path: worker.workspace_path || runtime.workspace_path
      },
      runtime_context: %{
        project_id: optional_string(request, :project_id),
        issue_key: optional_string(request, :issue_key),
        attempt_id: optional_string(request, :attempt_id),
        start_intent_id: optional_string(request, :start_intent_id),
        current_stage: runtime.current_stage
      }
    }
  end

  defp failure_result(request, reason, now) do
    status = failure_status(reason)

    %{
      status: if(status == "manual_attention", do: "manual_attention", else: "failed"),
      reason: failure_reason(reason),
      error_summary: safe_error(reason),
      failure_status: status,
      worker_host: optional_string(request, :worker_host),
      workspace_path: optional_string(request, :workspace_path)
    }
    |> maybe_put_retry_due_at(status, now)
  end

  defp maybe_put_retry_due_at(result, "retry_queued", %DateTime{} = now) do
    Map.put(result, :due_at, now |> DateTime.add(@retry_delay_ms, :millisecond) |> iso8601())
  end

  defp maybe_put_retry_due_at(result, _status, _now), do: result

  defp failure_status({:worker_spawn_failed, _reason}), do: "retry_queued"
  defp failure_status({:worker_start_timeout, _timeout_ms}), do: "retry_queued"
  defp failure_status({:worker_exited_before_ack, _reason}), do: "retry_queued"
  defp failure_status({:worker_start_failed, _reason}), do: "retry_queued"
  defp failure_status({:workspace_lease_mismatch, _requested, _actual}), do: "manual_attention"
  defp failure_status(:missing_workflow_file_path), do: "manual_attention"
  defp failure_status(:missing_tracker_file_path), do: "manual_attention"
  defp failure_status(:missing_workspace_path), do: "manual_attention"
  defp failure_status(_reason), do: "manual_attention"

  defp failure_reason({:worker_spawn_failed, _reason}), do: "worker_spawn_failed"
  defp failure_reason({:worker_start_timeout, _timeout_ms}), do: "worker_start_timeout"
  defp failure_reason({:worker_exited_before_ack, _reason}), do: "worker_exited_before_ack"
  defp failure_reason({:worker_start_failed, _reason}), do: "worker_start_failed"
  defp failure_reason({:workspace_lease_mismatch, _requested, _actual}), do: "workspace_lease_mismatch"
  defp failure_reason(:missing_workflow_file_path), do: "missing_workflow_file_path"
  defp failure_reason(:missing_tracker_file_path), do: "missing_tracker_file_path"
  defp failure_reason(:missing_workspace_path), do: "missing_workspace_path"
  defp failure_reason(_reason), do: "real_worker_start_failed"

  defp hub_issue_description(request) do
    [
      "Hub worker start handoff request.",
      "",
      "- project_id: #{optional_string(request, :project_id) || "n/a"}",
      "- issue_key: #{optional_string(request, :issue_key) || "n/a"}",
      "- attempt_id: #{optional_string(request, :attempt_id) || "n/a"}",
      "- start_intent_id: #{optional_string(request, :start_intent_id) || "n/a"}",
      "- current_stage: #{optional_string(request, :current_stage) || "n/a"}"
    ]
    |> Enum.join("\n")
  end

  defp safe_error({:worker_spawn_failed, reason}) do
    "worker task spawn failed: #{safe_error(reason)}"
  end

  defp safe_error({:worker_start_timeout, timeout_ms}) do
    "worker did not acknowledge start within #{timeout_ms}ms"
  end

  defp safe_error({:worker_exited_before_ack, reason}) do
    "worker exited before start acknowledgement: #{safe_exit_reason(reason)}"
  end

  defp safe_error({:worker_start_failed, reason}) do
    "worker start failed before acknowledgement: #{safe_exit_reason(reason)}"
  end

  defp safe_error({:workspace_lease_mismatch, _requested, _actual}) do
    "worker workspace did not match the ledger workspace lease"
  end

  defp safe_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
  defp safe_error(reason), do: reason |> inspect(limit: 5, printable_limit: 200) |> String.slice(0, 200)

  defp safe_exit_reason(:normal), do: "normal_exit"
  defp safe_exit_reason(:shutdown), do: "shutdown"
  defp safe_exit_reason({:shutdown, _reason}), do: "shutdown"
  defp safe_exit_reason(_reason), do: "worker_runtime_error"

  defp safe_log(request, key), do: request |> optional_string(key) |> Kernel.||("n/a")

  defp validate_observed_workspace(_request, nil), do: :ok

  defp validate_observed_workspace(request, observed_workspace) do
    case optional_string(request, :workspace_path) do
      nil ->
        :ok

      requested_workspace ->
        if Path.expand(requested_workspace) == Path.expand(observed_workspace) do
          :ok
        else
          {:error, {:workspace_lease_mismatch, requested_workspace, observed_workspace}}
        end
    end
  end

  defp terminate_task(pid, ref) do
    if Process.whereis(SymphonyElixir.TaskSupervisor) do
      Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid)
    else
      Process.exit(pid, :shutdown)
    end

    Process.demonitor(ref, [:flush])
    :ok
  end

  defp start_timeout_ms do
    case Application.get_env(:symphony_elixir, :hub_worker_start_timeout_ms, @start_timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> timeout_ms
      _timeout_ms -> @start_timeout_ms
    end
  end

  defp safe_update_reason(update) do
    update
    |> value(:reason)
    |> Kernel.||(value(update, :payload))
    |> Kernel.||(value(update, :details))
    |> safe_error()
  end

  defp safe_token(map, key) when is_map(map), do: map |> optional_string(key) |> Kernel.||("none") |> safe_token()

  defp safe_token(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9._:-]+/, "_")
    |> String.slice(0, 96)
  end

  defp safe_token(value), do: value |> to_string() |> safe_token()

  defp iso8601(%DateTime{} = datetime), do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(_value), do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp iso8601_or_nil(%DateTime{} = datetime), do: iso8601(datetime)
  defp iso8601_or_nil(_value), do: nil

  defp required_string(map, key) do
    case optional_string(map, key) do
      nil -> {:error, :"missing_#{key}"}
      value -> {:ok, value}
    end
  end

  defp optional_string(map, key), do: map |> value(key) |> optional_string()
  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(_value), do: nil

  defp value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, nil} -> Map.get(map, Atom.to_string(key))
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(_map, _key), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
