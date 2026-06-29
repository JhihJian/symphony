defmodule SymphonyElixir.Hub.Runtime do
  @moduledoc """
  Read-only Hub runtime skeleton.

  The runtime loads a `HUB.yaml` project registry, builds safe Hub poll and
  device-observability snapshots, and exposes them through the same snapshot
  call shape used by the legacy orchestrator. It does not poll providers,
  dispatch agents, create workspaces, or write back to trackers.
  """

  use GenServer

  alias SymphonyElixir.Hub.{DeviceObservability, PollCoordinator, ProjectRegistry}

  @env_key :hub_config_file_path
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  @type state :: %{
          required(:config_path) => Path.t(),
          required(:loaded_at) => DateTime.t(),
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

      {:ok,
       %{
         config_path: config_path,
         loaded_at: loaded_at,
         snapshot: build_snapshot(config_path, loaded_at, registry)
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
        state = %{state | loaded_at: requested_at, snapshot: build_snapshot(state.config_path, requested_at, registry)}

        {:reply,
         %{
           queued: true,
           coalesced: false,
           requested_at: requested_at,
           operations: ["hub_registry_load", "hub_poll_plan", "hub_device_observability"]
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
  def build_snapshot(config_path, loaded_at, registry)
      when is_binary(config_path) and is_map(registry) do
    generated_at = DateTime.utc_now()
    poll_plan = PollCoordinator.build_plan(registry, now: generated_at)

    device_observability =
      DeviceObservability.build(
        %{
          registry: registry,
          poll_coordination: poll_plan,
          migration_boundary: migration_boundary()
        },
        now: generated_at
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
        read_only: true,
        config_path: config_path,
        loaded_at: iso8601(loaded_at),
        generated_at: iso8601(generated_at),
        counts: counts,
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
      hub_projection_model_only: true,
      hub_read_only_runtime_skeleton: true,
      hub_takes_over_legacy_poll_loop: false,
      hub_routing_requires_opt_in: true,
      direct_path_capabilities: ["legacy_poll_loop", "legacy_direct_writeback", "legacy_agent_dispatch"],
      opt_in_hub_capabilities: ["project_registry", "poll_plan_snapshot", "device_observability_snapshot"]
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
