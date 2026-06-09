defmodule SymphonyElixirWeb.AdminInstanceController do
  @moduledoc """
  JSON API for multi-instance operator management.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.Endpoint

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, _params) do
    case registry().list_instances(registry_opts()) do
      {:ok, instances} ->
        json(conn, %{instances: instances})

      {:error, reason} ->
        error_response(conn, 500, "instance_registry_unavailable", inspect(reason))
    end
  end

  @spec start(Conn.t(), map()) :: Conn.t()
  def start(conn, %{"name" => name}), do: run_action(conn, "start", name)

  @spec stop(Conn.t(), map()) :: Conn.t()
  def stop(conn, %{"name" => name}), do: run_action(conn, "stop", name)

  @spec restart(Conn.t(), map()) :: Conn.t()
  def restart(conn, %{"name" => name}), do: run_action(conn, "restart", name)

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  defp run_action(conn, action, name) do
    action_result =
      case action do
        "start" -> registry().start_instance(name, registry_opts())
        "stop" -> registry().stop_instance(name, registry_opts())
        "restart" -> registry().restart_instance(name, registry_opts())
      end

    case action_result do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, %{code: code, message: message}} ->
        error_response(conn, error_status(code), code, message)
    end
  end

  defp error_status("invalid_instance_name"), do: 400
  defp error_status(_code), do: 500

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp registry do
    Endpoint.config(:instance_registry) || SymphonyElixir.InstanceRegistry
  end

  defp registry_opts do
    Endpoint.config(:instance_registry_opts) || []
  end
end
