defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  alias SymphonyElixir.Hub.RealWorkerLifecycleStore
  alias SymphonyElixir.Hub.Runtime, as: HubRuntime

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    children = application_children()

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  defp auto_update_child do
    opts = Application.get_env(:symphony_elixir, :auto_update_opts, [])

    if Keyword.get(opts, :enabled?, true) do
      {SymphonyElixir.AutoUpdate, opts}
    end
  end

  defp application_children do
    if HubRuntime.hub_mode?() do
      [
        {Phoenix.PubSub, name: SymphonyElixir.PubSub},
        {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
        RealWorkerLifecycleStore,
        HubRuntime,
        {SymphonyElixir.HttpServer, orchestrator: HubRuntime},
        {SymphonyElixir.StatusDashboard, orchestrator: HubRuntime, mode: :hub}
      ]
    else
      [
        {Phoenix.PubSub, name: SymphonyElixir.PubSub},
        {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
        SymphonyElixir.WorkflowStore,
        SymphonyElixir.Orchestrator,
        auto_update_child(),
        SymphonyElixir.HttpServer,
        SymphonyElixir.StatusDashboard
      ]
      |> Enum.reject(&is_nil/1)
    end
  end
end
