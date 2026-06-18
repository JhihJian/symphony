defmodule SymphonyElixirWeb.AdminInstanceController do
  @moduledoc """
  JSON API for multi-instance operator management.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.Endpoint

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, _params) do
    with :ok <- authorize_admin_request(conn) do
      case registry().list_instances(registry_opts()) do
        {:ok, instances} ->
          json(conn, %{instances: instances})

        {:error, reason} ->
          error_response(conn, 500, "instance_registry_unavailable", inspect(reason))
      end
    end
  end

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, params) do
    with :ok <- authorize_admin_request(conn) do
      case registry().create_instance(params, registry_opts()) do
        {:ok, payload} ->
          conn
          |> put_status(201)
          |> json(payload)

        {:error, %{code: code, message: message}} ->
          error_response(conn, error_status(code), code, message)
      end
    end
  end

  @spec auto_update(Conn.t(), map()) :: Conn.t()
  def auto_update(conn, _params) do
    with :ok <- authorize_admin_request(conn) do
      json(conn, encode_datetimes(auto_update_module().snapshot(auto_update_opts())))
    end
  end

  @spec check_update(Conn.t(), map()) :: Conn.t()
  def check_update(conn, _params) do
    with :ok <- authorize_admin_request(conn) do
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
  end

  @spec run_update(Conn.t(), map()) :: Conn.t()
  def run_update(conn, _params) do
    with :ok <- authorize_admin_request(conn) do
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
  end

  @spec start(Conn.t(), map()) :: Conn.t()
  def start(conn, %{"name" => name}), do: run_action(conn, "start", name)

  @spec stop(Conn.t(), map()) :: Conn.t()
  def stop(conn, %{"name" => name}), do: run_action(conn, "stop", name)

  @spec restart(Conn.t(), map()) :: Conn.t()
  def restart(conn, %{"name" => name}), do: run_action(conn, "restart", name)

  @spec enable(Conn.t(), map()) :: Conn.t()
  def enable(conn, %{"name" => name}), do: run_action(conn, "enable", name)

  @spec disable(Conn.t(), map()) :: Conn.t()
  def disable(conn, %{"name" => name}), do: run_action(conn, "disable", name)

  @spec logs(Conn.t(), map()) :: Conn.t()
  def logs(conn, %{"name" => name} = params) do
    with :ok <- authorize_admin_request(conn) do
      opts = Keyword.put(registry_opts(), :lines, Map.get(params, "lines", 120))

      case registry().latest_logs(name, opts) do
        {:ok, payload} ->
          json(conn, payload)

        {:error, %{code: code, message: message}} ->
          error_response(conn, error_status(code), code, message)
      end
    end
  end

  @spec update_timer(Conn.t(), map()) :: Conn.t()
  def update_timer(conn, _params) do
    with :ok <- authorize_admin_request(conn) do
      json(conn, registry().update_timer_status(registry_opts()))
    end
  end

  @spec enable_update_timer(Conn.t(), map()) :: Conn.t()
  def enable_update_timer(conn, _params), do: run_update_timer_action(conn, "enable")

  @spec disable_update_timer(Conn.t(), map()) :: Conn.t()
  def disable_update_timer(conn, _params), do: run_update_timer_action(conn, "disable")

  @spec trigger_update_timer(Conn.t(), map()) :: Conn.t()
  def trigger_update_timer(conn, _params), do: run_update_timer_action(conn, "trigger")

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  defp run_action(conn, action, name) do
    with :ok <- authorize_admin_request(conn) do
      action_result =
        case action do
          "start" -> registry().start_instance(name, registry_opts())
          "stop" -> registry().stop_instance(name, registry_opts())
          "restart" -> registry().restart_instance(name, registry_opts())
          "enable" -> registry().enable_instance(name, registry_opts())
          "disable" -> registry().disable_instance(name, registry_opts())
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
  end

  defp run_update_timer_action(conn, action) do
    with :ok <- authorize_admin_request(conn) do
      action_result =
        case action do
          "enable" -> registry().enable_update_timer(registry_opts())
          "disable" -> registry().disable_update_timer(registry_opts())
          "trigger" -> registry().trigger_update_service(registry_opts())
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
  end

  defp authorize_admin_request(conn) do
    if local_request?(conn) do
      :ok
    else
      error_response(conn, 403, "admin_forbidden", "Admin endpoints are restricted to local clients.")
    end
  end

  defp local_request?(conn) do
    case conn.remote_ip do
      {127, 0, 0, 1} -> true
      {0, 0, 0, 0, 0, 0, 0, 1} -> true
      {0, 0, 0, 0, 0, 65_535, 32_512, 1} -> true
      _remote -> false
    end
  end

  defp error_status("invalid_instance_name"), do: 400
  defp error_status("unsupported_tracker_kind"), do: 400
  defp error_status("invalid_owner"), do: 400
  defp error_status("invalid_repo"), do: 400
  defp error_status("invalid_project_number"), do: 400
  defp error_status("invalid_token_env"), do: 400
  defp error_status("invalid_port"), do: 400
  defp error_status("invalid_update_strategy"), do: 400
  defp error_status("invalid_max_agents"), do: 400
  defp error_status("invalid_host"), do: 400
  defp error_status("missing_token_env"), do: 400
  defp error_status("instance_exists"), do: 409
  defp error_status("port_in_use"), do: 409
  defp error_status("port_unavailable"), do: 409
  defp error_status("install_script_missing"), do: 500
  defp error_status("install_failed"), do: 500
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
