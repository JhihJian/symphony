defmodule SymphonyElixir.InstanceRegistry do
  @moduledoc """
  Discovers and manages independently deployed Symphony instances.

  This module is intentionally a thin operator surface over the existing
  systemd-template deployment convention. It never dispatches issues or shares
  orchestrator state between instances.
  """

  alias SymphonyElixir.{Config, Tracker, TrackerConfig, Workflow}
  alias SymphonyElixir.Workflow.Definition

  @instance_name_pattern ~r/\A[A-Za-z0-9_.-]+\z/
  @env_var_pattern ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @repo_part_pattern ~r/\A[A-Za-z0-9_.-]+\z/
  @default_state_timeout_ms 1_500
  @default_port_start 20_000
  @max_port 65_535

  @type instance :: %{
          name: String.t(),
          service: String.t(),
          status: String.t(),
          systemd: map(),
          port: pos_integer() | nil,
          dashboard_url: String.t() | nil,
          api_url: String.t() | nil,
          tracker: map(),
          counts: map(),
          health: map(),
          workspace_root: String.t() | nil,
          logs_root: String.t() | nil,
          config_path: String.t(),
          tracker_config_path: String.t() | nil,
          env_path: String.t(),
          runtime: map(),
          strategy: String.t()
        }

  @type create_result ::
          {:ok, %{instance: instance(), output: String.t()}}
          | {:error, %{code: String.t(), message: String.t()}}

  @type action_result ::
          {:ok, %{action: String.t(), service: String.t()}}
          | {:error, %{code: String.t(), message: String.t()}}

  @type logs_result ::
          {:ok, %{service: String.t(), logs: String.t()}}
          | {:error, %{code: String.t(), message: String.t()}}

  @type update_timer_status :: %{
          timer: String.t(),
          service: String.t(),
          active: String.t(),
          sub: String.t() | nil,
          enabled: String.t(),
          next_run: String.t() | nil,
          last_trigger: String.t() | nil,
          service_active: String.t(),
          service_sub: String.t() | nil
        }

  @spec list_instances(keyword()) :: {:ok, [instance()]} | {:error, term()}
  def list_instances(opts \\ []) do
    config_root = config_root(opts)

    case discover_instance_names(config_root, opts) do
      {:ok, entries} ->
        instances =
          entries
          |> Enum.sort()
          |> Enum.map(&load_instance(config_root, &1, opts))

        {:ok, instances}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec create_instance(map(), keyword()) :: create_result()
  def create_instance(params, opts \\ []) when is_map(params) do
    config_root = config_root(opts)

    with {:ok, attrs} <- normalize_create_params(params, opts),
         :ok <- ensure_instance_absent(attrs.project, config_root, opts),
         {:ok, port} <- resolve_port(attrs.port, config_root, opts),
         {:ok, command_env} <- command_env(attrs, opts),
         {:ok, output} <- run_install_systemd_template(attrs, port, command_env, opts) do
      {:ok,
       %{
         instance: load_instance(config_root, attrs.project, opts),
         output: redact_sensitive(output, secret_values(command_env))
       }}
    end
  end

  @spec start_instance(String.t(), keyword()) :: action_result()
  def start_instance(name, opts \\ []), do: lifecycle_action("start", name, opts)

  @spec stop_instance(String.t(), keyword()) :: action_result()
  def stop_instance(name, opts \\ []), do: lifecycle_action("stop", name, opts)

  @spec restart_instance(String.t(), keyword()) :: action_result()
  def restart_instance(name, opts \\ []), do: lifecycle_action("restart", name, opts)

  @spec enable_instance(String.t(), keyword()) :: action_result()
  def enable_instance(name, opts \\ []), do: lifecycle_action("enable", name, opts)

  @spec disable_instance(String.t(), keyword()) :: action_result()
  def disable_instance(name, opts \\ []), do: lifecycle_action("disable", name, opts)

  @spec latest_logs(String.t(), keyword()) :: logs_result()
  def latest_logs(name, opts \\ []) do
    lines = opts |> Keyword.get(:lines, 120) |> normalize_log_lines()

    with :ok <- validate_instance_name(name),
         service <- service_name(name) do
      case deps(opts).journalctl_logs.(service, lines) do
        {:ok, logs} ->
          {:ok, %{service: service, logs: redact_sensitive(logs)}}

        {:error, reason} ->
          {:error,
           %{
             code: "journalctl_failed",
             message: "Failed to read logs for #{service}: #{format_systemctl_error(reason)}"
           }}
      end
    end
  end

  @spec update_timer_status(keyword()) :: update_timer_status()
  def update_timer_status(opts \\ []) do
    timer = "symphony-update.timer"
    service = "symphony-update.service"
    timer_show = systemctl_timer_show(opts)
    service_show = systemctl_show(service, opts)

    %{
      timer: timer,
      service: service,
      active: timer_show.active || service_status(timer, opts),
      sub: timer_show.sub,
      enabled: systemctl_enabled(timer, opts),
      next_run: timer_show.next_run,
      last_trigger: timer_show.last_trigger,
      service_active: service_show.active || service_status(service, opts),
      service_sub: service_show.sub
    }
  end

  @spec enable_update_timer(keyword()) :: action_result()
  def enable_update_timer(opts \\ []), do: unit_action("enable --now", "symphony-update.timer", opts)

  @spec disable_update_timer(keyword()) :: action_result()
  def disable_update_timer(opts \\ []), do: unit_action("disable --now", "symphony-update.timer", opts)

  @spec trigger_update_service(keyword()) :: action_result()
  def trigger_update_service(opts \\ []), do: unit_action("start", "symphony-update.service", opts)

  @spec default_config_root() :: Path.t()
  def default_config_root, do: Path.join([System.user_home!(), ".config", "symphony", "projects"])

  @spec default_runtime_root() :: Path.t()
  def default_runtime_root, do: Path.join([System.user_home!(), ".codex", "symphony", "projects"])

  @spec default_source_root() :: Path.t()
  def default_source_root, do: Path.expand("../../..", __DIR__)

  defp discover_instance_names(config_root, opts) do
    with {:ok, config_entries} <- config_instance_names(config_root),
         {:ok, service_entries} <- service_instance_names(opts) do
      {:ok, Enum.uniq(config_entries ++ service_entries)}
    end
  end

  defp config_instance_names(config_root) do
    case File.ls(config_root) do
      {:ok, entries} ->
        names =
          entries
          |> Enum.filter(fn entry ->
            Regex.match?(@instance_name_pattern, entry) and File.dir?(Path.join(config_root, entry))
          end)

        {:ok, names}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:config_root_unavailable, config_root, reason}}
    end
  end

  defp service_instance_names(opts) do
    opts
    |> deps()
    |> Map.get(:list_services, fn -> {:ok, []} end)
    |> then(& &1.())
    |> case do
      {:ok, services} when is_list(services) ->
        {:ok, services |> Enum.flat_map(&instance_name_from_service/1) |> Enum.uniq()}

      {:error, _reason} ->
        {:ok, []}
    end
  end

  defp instance_name_from_service(service) when is_binary(service) do
    case Regex.run(~r/\Asymphony@(.+)\.service\z/, service) do
      [_service, name] -> [name]
      _not_instance -> []
    end
  end

  defp instance_name_from_service(_service), do: []

  defp load_instance(config_root, name, opts) do
    project_config_root = Path.join(config_root, name)
    workflow_path = Path.join(project_config_root, "WORKFLOW.md")
    tracker_config_path = Path.join(project_config_root, "TRACKER.yaml")
    env_path = Path.join(project_config_root, "env")
    env = read_env_file(env_path)
    settings = parse_settings(workflow_path, tracker_config_path)
    service = service_name(name)
    systemd = systemd_summary(service, opts)
    status = normalize_systemd_status(systemd.active)
    port = port(env, settings)
    dashboard_url = dashboard_url(settings, port)
    api_url = api_url(dashboard_url)
    state_result = fetch_state(api_url, opts)

    %{
      name: name,
      service: service,
      status: status,
      systemd: systemd,
      port: port,
      dashboard_url: dashboard_url,
      api_url: api_url,
      tracker: tracker_summary(settings),
      counts: counts(state_result),
      health: health_summary(status, state_result),
      workspace_root: workspace_root(settings),
      logs_root: Map.get(env, "SYMPHONY_LOGS_ROOT"),
      config_path: workflow_path,
      tracker_config_path: existing_file_path(tracker_config_path),
      env_path: env_path,
      runtime: runtime_summary(state_result),
      strategy: update_strategy(env)
    }
  end

  defp normalize_create_params(params, opts) do
    attrs = %{
      project: string_param(params, "project"),
      tracker_kind: string_param(params, "tracker_kind", "github"),
      owner: string_param(params, "owner"),
      repo: string_param(params, "repo"),
      project_number: string_param(params, "project_number"),
      token: string_param(params, "token"),
      token_env: string_param(params, "token_env"),
      port: string_param(params, "port"),
      start?: boolean_param(params, "start", true),
      auto_update?: boolean_param(params, "auto_update", false),
      update_strategy: string_param(params, "update_strategy", "idle_restart"),
      host: string_param(params, "host", "0.0.0.0"),
      max_agents: string_param(params, "max_agents", "2")
    }

    with :ok <- validate_instance_name(attrs.project),
         :ok <- validate_tracker_kind(attrs.tracker_kind),
         :ok <- validate_repo_part("owner", attrs.owner),
         :ok <- validate_repo_part("repo", attrs.repo),
         :ok <- validate_positive_integer("project_number", attrs.project_number),
         :ok <- validate_token_source(attrs.token, attrs.token_env),
         :ok <- validate_optional_env_var("token_env", attrs.token_env),
         :ok <- validate_optional_port(attrs.port),
         :ok <- validate_update_strategy(attrs.update_strategy),
         :ok <- validate_positive_integer("max_agents", attrs.max_agents),
         :ok <- validate_safe_host(attrs.host),
         :ok <- validate_install_script(opts) do
      {:ok, attrs}
    end
  end

  defp string_param(params, key, default \\ "") do
    params
    |> map_get(key, default)
    |> to_string()
    |> String.trim()
  end

  defp boolean_param(params, key, default) do
    case map_get(params, key, default) do
      value when value in [true, "true", "1", "on", "yes"] -> true
      value when value in [false, "false", "0", "off", "no", nil, ""] -> false
      _unknown -> default
    end
  end

  defp validate_tracker_kind("github"), do: :ok

  defp validate_tracker_kind(_kind) do
    {:error,
     %{
       code: "unsupported_tracker_kind",
       message: "Instance creation currently supports GitHub tracker configuration only."
     }}
  end

  defp validate_repo_part(field, value) do
    if Regex.match?(@repo_part_pattern, value) do
      :ok
    else
      {:error,
       %{
         code: "invalid_#{field}",
         message: "#{field} may only contain letters, numbers, '.', '_' and '-'."
       }}
    end
  end

  defp validate_positive_integer(field, value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 ->
        :ok

      _invalid ->
        {:error, %{code: "invalid_#{field}", message: "#{field} must be a positive integer."}}
    end
  end

  defp validate_token_source("", ""), do: :ok
  defp validate_token_source(token, _token_env) when is_binary(token) and token != "", do: :ok
  defp validate_token_source("", token_env) when is_binary(token_env) and token_env != "", do: :ok

  defp validate_optional_env_var(_field, ""), do: :ok

  defp validate_optional_env_var(field, value) do
    if Regex.match?(@env_var_pattern, value) do
      :ok
    else
      {:error,
       %{
         code: "invalid_#{field}",
         message: "#{field} must be a valid environment variable name."
       }}
    end
  end

  defp validate_optional_port(""), do: :ok

  defp validate_optional_port(value) do
    case parse_port(value) do
      {:ok, _port} -> :ok
      {:error, _reason} -> {:error, %{code: "invalid_port", message: "port must be between 1 and #{@max_port}."}}
    end
  end

  defp validate_update_strategy(strategy) do
    if strategy in ["idle_restart", "defer_until_idle", "download_only", "manual_restart", "force_restart"] do
      :ok
    else
      {:error,
       %{
         code: "invalid_update_strategy",
         message: "update_strategy must be one of idle_restart, defer_until_idle, download_only, manual_restart or force_restart."
       }}
    end
  end

  defp validate_safe_host(host) do
    uri = URI.parse("http://#{host}")

    cond do
      host == "" ->
        {:error, %{code: "invalid_host", message: "host is required."}}

      uri.host == nil or uri.host != host ->
        {:error, %{code: "invalid_host", message: "host must be a plain hostname or IP address."}}

      true ->
        :ok
    end
  end

  defp validate_install_script(opts) do
    script = install_script(opts)

    if File.regular?(script) do
      :ok
    else
      {:error, %{code: "install_script_missing", message: "Install script not found: #{script}"}}
    end
  end

  defp ensure_instance_absent(project, config_root, opts) do
    existing_config? = File.exists?(Path.join(config_root, project))

    existing_service? =
      opts
      |> deps()
      |> Map.get(:list_services, fn -> {:ok, []} end)
      |> then(& &1.())
      |> case do
        {:ok, services} -> service_name(project) in services
        _error -> false
      end

    if existing_config? or existing_service? do
      {:error,
       %{
         code: "instance_exists",
         message: "Instance #{project} already exists."
       }}
    else
      :ok
    end
  end

  defp resolve_port("", config_root, opts) do
    used_ports = configured_ports(config_root) ++ listening_ports(opts)
    used = MapSet.new(used_ports)
    free_port = Enum.find(@default_port_start..@max_port, fn candidate -> not MapSet.member?(used, candidate) end)

    case free_port do
      nil -> {:error, %{code: "port_unavailable", message: "No free port found from #{@default_port_start} to #{@max_port}."}}
      port -> {:ok, port}
    end
  end

  defp resolve_port(value, config_root, opts) do
    with {:ok, port} <- parse_port(value),
         :ok <- ensure_port_available(port, config_root, opts) do
      {:ok, port}
    else
      {:error, %{code: _code} = error} -> {:error, error}
      {:error, _reason} -> {:error, %{code: "invalid_port", message: "port must be between 1 and #{@max_port}."}}
    end
  end

  defp parse_port(value) when is_integer(value) and value in 1..@max_port, do: {:ok, value}

  defp parse_port(value) do
    case Integer.parse(to_string(value || "")) do
      {port, ""} when port in 1..@max_port -> {:ok, port}
      _invalid -> {:error, :invalid}
    end
  end

  defp ensure_port_available(port, config_root, opts) do
    used = MapSet.new(configured_ports(config_root) ++ listening_ports(opts))

    if MapSet.member?(used, port) do
      {:error, %{code: "port_in_use", message: "Port #{port} is already configured or currently listening."}}
    else
      :ok
    end
  end

  defp configured_ports(config_root) do
    config_root
    |> Path.join("*/env")
    |> Path.wildcard()
    |> Enum.flat_map(fn env_path ->
      env_path
      |> read_env_file()
      |> Map.get("SYMPHONY_PORT")
      |> case do
        nil ->
          []

        value ->
          case parse_port(value) do
            {:ok, port} -> [port]
            {:error, _reason} -> []
          end
      end
    end)
  end

  defp listening_ports(opts) do
    opts
    |> deps()
    |> Map.get(:listening_ports, fn -> {:ok, []} end)
    |> then(& &1.())
    |> case do
      {:ok, ports} when is_list(ports) -> Enum.filter(ports, &is_integer/1)
      _error -> []
    end
  end

  defp command_env(%{token: token}, _opts) when is_binary(token) and token != "" do
    {:ok, [{"GITHUB_TOKEN", token}]}
  end

  defp command_env(%{token_env: token_env}, _opts) when is_binary(token_env) and token_env != "" do
    case System.fetch_env(token_env) do
      {:ok, token} when token != "" ->
        {:ok, [{"GITHUB_TOKEN", token}]}

      _missing ->
        {:error,
         %{
           code: "missing_token_env",
           message: "Environment variable #{token_env} is not set or empty."
         }}
    end
  end

  defp command_env(_attrs, _opts), do: {:ok, []}

  defp run_install_systemd_template(attrs, port, command_env, opts) do
    args =
      [
        "--project",
        attrs.project,
        "--owner",
        attrs.owner,
        "--repo",
        attrs.repo,
        "--project-number",
        attrs.project_number,
        "--port",
        Integer.to_string(port),
        "--host",
        attrs.host,
        "--max-agents",
        attrs.max_agents,
        "--update-strategy",
        attrs.update_strategy
      ] ++ root_args(opts) ++ start_args(attrs) ++ auto_update_args(attrs)

    case deps(opts).run_install_script.(install_script(opts), args, command_env) do
      {:ok, output} ->
        {:ok, output}

      {:error, reason} ->
        {:error,
         %{
           code: "install_failed",
           message: "Failed to create Symphony instance: #{reason |> format_systemctl_error() |> redact_sensitive(secret_values(command_env))}"
         }}
    end
  end

  defp root_args(opts) do
    [
      "--config-root",
      config_root(opts),
      "--runtime-root",
      Keyword.get(opts, :runtime_root, default_runtime_root()),
      "--source-root",
      Keyword.get(opts, :source_root, default_source_root())
    ]
  end

  defp start_args(%{start?: true}), do: []
  defp start_args(%{start?: false}), do: ["--no-start"]

  defp auto_update_args(%{auto_update?: true}), do: ["--auto-update"]
  defp auto_update_args(%{auto_update?: false}), do: []

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

  defp unit_action(action, unit, opts) do
    case deps(opts).systemctl_action.(action, unit) do
      :ok ->
        {:ok, %{action: action, service: unit}}

      {:error, reason} ->
        {:error,
         %{
           code: "systemctl_failed",
           message: "Failed to #{action} #{unit}: #{format_systemctl_error(reason)}"
         }}
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
      systemctl_show: &systemctl_show/1,
      systemctl_enabled: &systemctl_enabled/1,
      list_services: &list_services/0,
      http_get_state: &http_get_state/1,
      systemctl_action: &systemctl_action/2,
      journalctl_logs: &journalctl_logs/2,
      run_install_script: &run_install_script/3,
      listening_ports: &listening_ports/0
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

  defp parse_settings(workflow_path, tracker_config_path) do
    case Workflow.load(workflow_path) do
      {:ok, %{config: config, workflow: workflow_definition}} ->
        parse_settings_config(config, workflow_definition, tracker_config_path)

      _error ->
        nil
    end
  end

  defp parse_settings_config(config, nil, _tracker_config_path) do
    case Config.Schema.parse(config) do
      {:ok, settings} -> settings
      {:error, _reason} -> nil
    end
  end

  defp parse_settings_config(config, workflow_definition, tracker_config_path) do
    with true <- File.regular?(tracker_config_path),
         {:ok, tracker_config} <- TrackerConfig.load(tracker_config_path),
         workflow_map <- Definition.to_map(workflow_definition),
         :ok <- Tracker.validate_workflow_state_mapping(workflow_map, tracker_config),
         runtime_config <-
           config
           |> Map.drop(["workflow", "start_stage", "terminal_stages", "outcomes", "missing_outcome", "stages"])
           |> Map.merge(TrackerConfig.normalize_for_settings(tracker_config, workflow_map))
           |> Map.put("workflow", workflow_map)
           |> Map.put("tracker_config", tracker_config),
         {:ok, settings} <- Config.Schema.parse(runtime_config) do
      settings
    else
      _error -> nil
    end
  end

  defp existing_file_path(path) do
    if File.regular?(path), do: path, else: nil
  end

  defp systemd_summary(service, opts) do
    raw_show = systemctl_show(service, opts)
    active = raw_show.active || service_status(service, opts)

    %{
      active: active,
      enabled: systemctl_enabled(service, opts),
      sub: raw_show.sub || active,
      failed: raw_show.failed || active == "failed"
    }
  end

  defp systemctl_timer_show(opts) do
    timer = "symphony-update.timer"

    opts
    |> deps()
    |> Map.get(:systemctl_show, fn _service -> {:error, :unsupported} end)
    |> then(& &1.(timer))
    |> case do
      {:ok, %{} = raw} -> normalize_timer_show_map(raw)
      {:ok, raw} when is_binary(raw) -> parse_systemctl_timer_show(raw)
      _error -> %{active: nil, sub: nil, next_run: nil, last_trigger: nil}
    end
  end

  defp normalize_timer_show_map(raw) do
    active = map_get(raw, :active, map_get(raw, :ActiveState, nil))
    sub = map_get(raw, :sub, map_get(raw, :SubState, nil))
    next_run = map_get(raw, :next_run, map_get(raw, :NextElapseUSecRealtime, nil))
    last_trigger = map_get(raw, :last_trigger, map_get(raw, :LastTriggerUSec, nil))
    %{active: active, sub: sub, next_run: empty_to_nil(next_run), last_trigger: empty_to_nil(last_trigger)}
  end

  defp systemctl_show(service, opts) do
    opts
    |> deps()
    |> Map.get(:systemctl_show, fn _service -> {:error, :unsupported} end)
    |> then(& &1.(service))
    |> case do
      {:ok, %{active: active, sub: sub, failed: failed}} -> %{active: active, sub: sub, failed: failed}
      {:ok, %{} = raw} -> normalize_show_map(raw)
      {:ok, raw} when is_binary(raw) -> parse_systemctl_show(raw)
      _error -> %{active: nil, sub: nil, failed: false}
    end
  end

  defp normalize_show_map(raw) do
    active = map_get(raw, :active, map_get(raw, :ActiveState, nil))
    sub = map_get(raw, :sub, map_get(raw, :SubState, nil))
    failed = map_get(raw, :failed, map_get(raw, :Result, nil) == "failed" or active == "failed")
    %{active: active, sub: sub, failed: failed}
  end

  defp parse_systemctl_show(raw) do
    values =
      raw
      |> String.split(["\n", "\r\n"], trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> Map.put(acc, key, value)
          _invalid -> acc
        end
      end)

    active = Map.get(values, "ActiveState")
    sub = Map.get(values, "SubState")
    failed = Map.get(values, "Result") == "failed" or active == "failed"
    %{active: active, sub: sub, failed: failed}
  end

  defp parse_systemctl_timer_show(raw) do
    values =
      raw
      |> String.split(["\n", "\r\n"], trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> Map.put(acc, key, value)
          _invalid -> acc
        end
      end)

    %{
      active: Map.get(values, "ActiveState"),
      sub: Map.get(values, "SubState"),
      next_run: empty_to_nil(Map.get(values, "NextElapseUSecRealtime")),
      last_trigger: empty_to_nil(Map.get(values, "LastTriggerUSec"))
    }
  end

  defp systemctl_enabled(service, opts) do
    opts
    |> deps()
    |> Map.get(:systemctl_enabled, fn _service -> {:error, :unsupported} end)
    |> then(& &1.(service))
    |> case do
      {:ok, enabled} when is_binary(enabled) -> enabled
      _error -> "unknown"
    end
  end

  defp service_status(service, opts) do
    case deps(opts).systemctl_status.(service) do
      {:ok, raw_status} -> raw_status
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

  defp update_strategy(env) do
    case Map.get(env, "SYMPHONY_UPDATE_STRATEGY", "idle_restart") do
      strategy when strategy in ["idle_restart", "defer_until_idle", "download_only", "manual_restart", "force_restart"] ->
        strategy

      _unknown ->
        "idle_restart"
    end
  end

  defp service_name(name), do: "symphony@#{name}.service"

  defp systemctl_status(service) do
    case System.cmd("systemctl", ["--user", "is-active", service], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _exit_status} -> {:ok, String.trim(output)}
    end
  rescue
    error -> {:error, error}
  end

  defp systemctl_show(service) do
    case System.cmd(
           "systemctl",
           [
             "--user",
             "show",
             service,
             "--property=ActiveState",
             "--property=SubState",
             "--property=Result",
             "--property=NextElapseUSecRealtime",
             "--property=LastTriggerUSec"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {output, _exit_status} -> {:error, String.trim(output)}
    end
  rescue
    error -> {:error, error}
  end

  defp systemctl_enabled(service) do
    case System.cmd("systemctl", ["--user", "is-enabled", service], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _exit_status} -> {:ok, String.trim(output)}
    end
  rescue
    error -> {:error, error}
  end

  defp list_services do
    services =
      [systemctl_list_units(), systemd_user_symlinks()]
      |> Enum.flat_map(fn
        {:ok, entries} -> entries
        {:error, _reason} -> []
      end)
      |> Enum.uniq()

    {:ok, services}
  end

  defp systemctl_list_units do
    case System.cmd("systemctl", ["--user", "list-units", "symphony@*.service", "--all", "--no-legend", "--no-pager"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, parse_unit_list(output)}
      {output, _exit_status} -> {:error, String.trim(output)}
    end
  rescue
    error -> {:error, error}
  end

  defp parse_unit_list(output) do
    output
    |> String.split(["\n", "\r\n"], trim: true)
    |> Enum.flat_map(fn line ->
      line
      |> String.split(~r/\s+/, trim: true, parts: 2)
      |> case do
        [unit | _rest] -> [unit]
        _empty -> []
      end
    end)
    |> Enum.filter(&String.match?(&1, ~r/\Asymphony@.+\.service\z/))
  end

  defp systemd_user_symlinks do
    root = Path.join([System.user_home!(), ".config", "systemd", "user"])

    if File.dir?(root) do
      {:ok,
       root
       |> Path.join("**/symphony@*.service")
       |> Path.wildcard()
       |> Enum.map(&Path.basename/1)
       |> Enum.filter(&String.match?(&1, ~r/\Asymphony@.+\.service\z/))}
    else
      {:ok, []}
    end
  end

  defp systemctl_action(action, service) do
    args = ["--user"] ++ String.split(action, " ", trim: true) ++ [service]

    case System.cmd("systemctl", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, exit_status} -> {:error, %{exit_status: exit_status, output: String.trim(output)}}
    end
  rescue
    error -> {:error, error}
  end

  defp journalctl_logs(service, lines) do
    case System.cmd("journalctl", ["--user", "-u", service, "--no-pager", "-n", Integer.to_string(lines)], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, exit_status} -> {:error, %{exit_status: exit_status, output: String.trim(output)}}
    end
  rescue
    error -> {:error, error}
  end

  defp run_install_script(script, args, env) do
    opts = [stderr_to_stdout: true]
    opts = if env == [], do: opts, else: Keyword.put(opts, :env, env)

    case System.cmd(script, args, opts) do
      {output, 0} -> {:ok, output}
      {output, exit_status} -> {:error, %{exit_status: exit_status, output: redact_sensitive(String.trim(output))}}
    end
  rescue
    error -> {:error, error}
  end

  defp listening_ports do
    case System.cmd("ss", ["-H", "-ltn"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, parse_listening_ports(output)}
      {_output, _exit_status} -> {:ok, []}
    end
  rescue
    _error -> {:ok, []}
  end

  defp parse_listening_ports(output) do
    output
    |> String.split(["\n", "\r\n"], trim: true)
    |> Enum.flat_map(fn line ->
      line
      |> String.split(~r/\s+/, trim: true)
      |> Enum.at(3)
      |> port_from_socket()
    end)
    |> Enum.uniq()
  end

  defp port_from_socket(nil), do: []

  defp port_from_socket(socket) do
    socket
    |> String.trim()
    |> String.split(":")
    |> List.last()
    |> parse_port()
    |> case do
      {:ok, port} -> [port]
      {:error, _reason} -> []
    end
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

  defp normalize_log_lines(lines) when is_integer(lines), do: lines |> max(1) |> min(500)

  defp normalize_log_lines(lines) do
    case Integer.parse(to_string(lines || "")) do
      {integer, ""} -> normalize_log_lines(integer)
      _invalid -> 120
    end
  end

  defp install_script(opts) do
    Keyword.get(opts, :install_script, Path.join(default_source_root(), "scripts/install-systemd-template.sh"))
  end

  defp empty_to_nil(value) when value in [nil, "", "n/a", "0"], do: nil
  defp empty_to_nil(value), do: value

  defp secret_values(env) do
    env
    |> Enum.map(fn {_key, value} -> value end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp redact_sensitive(nil), do: nil

  defp redact_sensitive(value) when is_binary(value) do
    redact_sensitive(value, [])
  end

  defp redact_sensitive(value), do: value

  defp redact_sensitive(value, secrets) when is_binary(value) do
    value
    |> String.replace(~r/(GITHUB_TOKEN=)[^\s]+/, "\\1[REDACTED]")
    |> String.replace(~r/(--token\s+)[^\s]+/, "\\1[REDACTED]")
    |> String.replace(~r/(gh[pousr]_[A-Za-z0-9_]+)/, "[REDACTED]")
    |> redact_secret_values(secrets)
  end

  defp redact_sensitive(value, _secrets), do: value

  defp redact_secret_values(value, secrets) do
    Enum.reduce(secrets, value, fn secret, acc -> String.replace(acc, secret, "[REDACTED]") end)
  end

  defp format_systemctl_error(%{output: output}) when is_binary(output) and output != "", do: output
  defp format_systemctl_error(%{exit_status: status}), do: "exit status #{status}"
  defp format_systemctl_error(reason), do: inspect(reason)
end
