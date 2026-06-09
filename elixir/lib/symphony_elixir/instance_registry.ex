defmodule SymphonyElixir.InstanceRegistry do
  @moduledoc """
  Discovers and manages independently deployed Symphony instances.

  This module is intentionally a thin operator surface over the existing
  systemd-template deployment convention. It never dispatches issues or shares
  orchestrator state between instances.
  """

  alias SymphonyElixir.{Config, Workflow}

  @instance_name_pattern ~r/\A[A-Za-z0-9_.-]+\z/
  @default_state_timeout_ms 1_500

  @type instance :: %{
          name: String.t(),
          service: String.t(),
          status: String.t(),
          dashboard_url: String.t() | nil,
          api_url: String.t() | nil,
          tracker: map(),
          counts: map(),
          health: map(),
          workspace_root: String.t() | nil,
          logs_root: String.t() | nil,
          config_path: String.t(),
          env_path: String.t(),
          runtime: map()
        }

  @type action_result ::
          {:ok, %{action: String.t(), service: String.t()}}
          | {:error, %{code: String.t(), message: String.t()}}

  @spec list_instances(keyword()) :: {:ok, [instance()]} | {:error, term()}
  def list_instances(opts \\ []) do
    config_root = config_root(opts)

    case File.ls(config_root) do
      {:ok, entries} ->
        instances =
          entries
          |> Enum.sort()
          |> Enum.map(&Path.join(config_root, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.map(&load_instance(&1, opts))

        {:ok, instances}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:config_root_unavailable, config_root, reason}}
    end
  end

  @spec start_instance(String.t(), keyword()) :: action_result()
  def start_instance(name, opts \\ []), do: lifecycle_action("start", name, opts)

  @spec stop_instance(String.t(), keyword()) :: action_result()
  def stop_instance(name, opts \\ []), do: lifecycle_action("stop", name, opts)

  @spec restart_instance(String.t(), keyword()) :: action_result()
  def restart_instance(name, opts \\ []), do: lifecycle_action("restart", name, opts)

  @spec default_config_root() :: Path.t()
  def default_config_root, do: Path.join([System.user_home!(), ".config", "symphony", "projects"])

  defp load_instance(project_config_root, opts) do
    name = Path.basename(project_config_root)
    workflow_path = Path.join(project_config_root, "WORKFLOW.md")
    env_path = Path.join(project_config_root, "env")
    env = read_env_file(env_path)
    settings = parse_settings(workflow_path)
    service = service_name(name)
    status = service_status(service, opts)
    port = port(env, settings)
    dashboard_url = dashboard_url(settings, port)
    api_url = api_url(dashboard_url)
    state_result = fetch_state(api_url, opts)

    %{
      name: name,
      service: service,
      status: status,
      dashboard_url: dashboard_url,
      api_url: api_url,
      tracker: tracker_summary(settings),
      counts: counts(state_result),
      health: health_summary(status, state_result),
      workspace_root: workspace_root(settings),
      logs_root: Map.get(env, "SYMPHONY_LOGS_ROOT"),
      config_path: workflow_path,
      env_path: env_path,
      runtime: runtime_summary(state_result)
    }
  end

  defp lifecycle_action(action, name, opts) do
    with :ok <- validate_instance_name(name),
         service <- service_name(name) do
      case deps(opts).systemctl_action.(action, service) do
        :ok ->
          {:ok, %{action: action, service: service}}

        {:error, reason} ->
          {:error,
           %{
             code: "systemctl_failed",
             message: "Failed to #{action} #{service}: #{format_systemctl_error(reason)}"
           }}
      end
    end
  end

  defp validate_instance_name(name) when is_binary(name) do
    if Regex.match?(@instance_name_pattern, name) do
      :ok
    else
      invalid_instance_name_error()
    end
  end

  defp validate_instance_name(_name), do: invalid_instance_name_error()

  defp invalid_instance_name_error do
    {:error,
     %{
       code: "invalid_instance_name",
       message: "Instance name may only contain letters, numbers, '.', '_' and '-'."
     }}
  end

  defp config_root(opts), do: Keyword.get(opts, :config_root, default_config_root())

  defp deps(opts) do
    Keyword.get(opts, :deps, %{
      systemctl_status: &systemctl_status/1,
      http_get_state: &http_get_state/1,
      systemctl_action: &systemctl_action/2
    })
  end

  defp read_env_file(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split(["\n", "\r\n"], trim: true)
        |> Enum.reduce(%{}, &put_env_line/2)

      {:error, _reason} ->
        %{}
    end
  end

  defp put_env_line("#" <> _comment, env), do: env

  defp put_env_line(line, env) do
    case String.split(line, "=", parts: 2) do
      [key, value] -> Map.put(env, String.trim(key), String.trim(value))
      _invalid -> env
    end
  end

  defp parse_settings(workflow_path) do
    with {:ok, %{config: config}} <- Workflow.load(workflow_path),
         {:ok, settings} <- Config.Schema.parse(config) do
      settings
    else
      _error -> nil
    end
  end

  defp service_status(service, opts) do
    case deps(opts).systemctl_status.(service) do
      {:ok, raw_status} -> normalize_systemd_status(raw_status)
      {:error, _reason} -> "unknown"
      :error -> "unknown"
    end
  end

  defp normalize_systemd_status(status) when status in ["active", "running"], do: "running"
  defp normalize_systemd_status(status) when status in ["inactive", "stopped"], do: "stopped"
  defp normalize_systemd_status("failed"), do: "failed"
  defp normalize_systemd_status(_status), do: "unknown"

  defp port(env, nil), do: env_port(env)
  defp port(env, settings), do: env_port(env) || settings.server.port

  defp env_port(env) do
    case Integer.parse(Map.get(env, "SYMPHONY_PORT", "")) do
      {port, ""} when port >= 0 -> port
      _invalid -> nil
    end
  end

  defp dashboard_url(_settings, nil), do: nil

  defp dashboard_url(settings, port) do
    host = dashboard_host(settings)
    "http://#{host}:#{port}/"
  end

  defp dashboard_host(nil), do: "127.0.0.1"

  defp dashboard_host(settings) do
    case settings.server.host do
      host when host in [nil, "", "0.0.0.0", "::"] -> "127.0.0.1"
      host -> host
    end
  end

  defp api_url(nil), do: nil
  defp api_url(dashboard_url), do: URI.merge(dashboard_url, "/api/v1/state") |> URI.to_string()

  defp fetch_state(nil, _opts), do: {:error, :missing_dashboard_url}

  defp fetch_state(api_url, opts) do
    case deps(opts).http_get_state.(api_url) do
      {:ok, %{} = payload} -> {:ok, payload}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_state_response, other}}
    end
  end

  defp tracker_summary(nil), do: %{kind: nil, scope: nil, required_labels: []}

  defp tracker_summary(settings) do
    %{
      kind: settings.tracker.kind,
      scope: tracker_scope(settings.tracker),
      required_labels: settings.tracker.required_labels
    }
  end

  defp tracker_scope(%{kind: "github", owner: owner, repo: repo})
       when is_binary(owner) and is_binary(repo),
       do: "#{owner}/#{repo}"

  defp tracker_scope(%{kind: kind, project_slug: project_slug})
       when kind in ["linear", "gitlab"] and is_binary(project_slug),
       do: project_slug

  defp tracker_scope(_tracker), do: nil

  defp counts({:ok, payload}) do
    raw_counts = map_get(payload, :counts, %{})

    %{
      running: integer_value(raw_counts, :running),
      retrying: integer_value(raw_counts, :retrying),
      blocked: integer_value(raw_counts, :blocked)
    }
  end

  defp counts({:error, _reason}), do: %{running: 0, retrying: 0, blocked: 0}

  defp runtime_summary({:ok, payload}) do
    codex_totals = map_get(payload, :codex_totals, %{})
    rate_limits = map_get(payload, :rate_limits, %{})
    primary = map_get(rate_limits, :primary, %{})

    %{
      codex_total_tokens: integer_value(codex_totals, :total_tokens),
      primary_rate_limit_remaining: integer_value(primary, :remaining)
    }
  end

  defp runtime_summary({:error, _reason}) do
    %{codex_total_tokens: 0, primary_rate_limit_remaining: 0}
  end

  defp health_summary(status, {:ok, _payload}) do
    %{
      status: "reachable",
      summary: "state API reachable; service #{status}",
      error: nil
    }
  end

  defp health_summary(status, {:error, reason}) do
    %{
      status: "unreachable",
      summary: "state API unreachable; service #{status}",
      error: inspect(reason)
    }
  end

  defp workspace_root(nil), do: nil
  defp workspace_root(settings), do: settings.workspace.root

  defp service_name(name), do: "symphony@#{name}.service"

  defp systemctl_status(service) do
    case System.cmd("systemctl", ["--user", "is-active", service], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _exit_status} -> {:ok, String.trim(output)}
    end
  rescue
    error -> {:error, error}
  end

  defp systemctl_action(action, service) do
    case System.cmd("systemctl", ["--user", action, service], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, exit_status} -> {:error, %{exit_status: exit_status, output: String.trim(output)}}
    end
  rescue
    error -> {:error, error}
  end

  defp http_get_state(url) do
    case Req.get(url: url, receive_timeout: @default_state_timeout_ms) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp integer_value(map, key) do
    value = map_get(map, key, 0)
    if is_integer(value), do: value, else: 0
  end

  defp map_get(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp map_get(_map, _key, default), do: default

  defp format_systemctl_error(%{output: output}) when is_binary(output) and output != "", do: output
  defp format_systemctl_error(%{exit_status: status}), do: "exit status #{status}"
  defp format_systemctl_error(reason), do: inspect(reason)
end
