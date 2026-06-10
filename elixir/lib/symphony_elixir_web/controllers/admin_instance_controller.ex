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

  @spec auto_update(Conn.t(), map()) :: Conn.t()
  def auto_update(conn, _params) do
    json(conn, encode_datetimes(auto_update_module().snapshot(auto_update_opts())))
  end

  @spec check_update(Conn.t(), map()) :: Conn.t()
  def check_update(conn, _params) do
    case auto_update_module().check_now(auto_update_opts()) do
      {:ok, snapshot} ->
        conn
        |> put_status(202)
        |> json(encode_datetimes(snapshot))

      {:error, snapshot} ->
        conn
        |> put_status(503)
        |> json(encode_datetimes(snapshot))
    end
  end

  @spec run_update(Conn.t(), map()) :: Conn.t()
  def run_update(conn, _params) do
    case auto_update_module().update_now(auto_update_opts()) do
      {:ok, snapshot} ->
        conn
        |> put_status(202)
        |> json(encode_datetimes(snapshot))

      {:error, snapshot} ->
        conn
        |> put_status(409)
        |> json(encode_datetimes(snapshot))
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

  defp auto_update_module do
    Endpoint.config(:auto_update) || SymphonyElixir.AutoUpdate
  end

  defp auto_update_opts do
    Endpoint.config(:auto_update_opts) || []
  end

  defp encode_datetimes(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp encode_datetimes(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, encode_datetimes(value)} end)
  end

  defp encode_datetimes(list) when is_list(list), do: Enum.map(list, &encode_datetimes/1)
  defp encode_datetimes(value), do: value
end
