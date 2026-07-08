defmodule SymphonyElixir.Hub.HostServiceProbe do
  @moduledoc """
  Read-only host/service probe for Hub activation preflight.

  The probe inspects local legacy systemd-template conventions and returns the
  sanitized summary shape consumed by `SymphonyElixir.Hub.ActivationPreflight`.
  It never starts, stops, enables, disables, migrates, or deletes services.
  """

  alias SymphonyElixir.{Config, Tracker, TrackerConfig, Workflow}
  alias SymphonyElixir.Hub.ProviderScope
  alias SymphonyElixir.Workflow.Definition

  @default_source "host_service_probe"
  @default_runtime_root Path.join([System.user_home!(), ".codex", "symphony", "projects"])
  @default_config_root Path.join([System.user_home!(), ".config", "symphony", "projects"])

  @type deps :: %{
          optional(:file_regular?) => (Path.t() -> boolean()),
          optional(:file_dir?) => (Path.t() -> boolean()),
          optional(:read_file) => (Path.t() -> {:ok, binary()} | {:error, term()}),
          optional(:systemctl_show) => (String.t() -> {:ok, binary() | map()} | {:error, term()}),
          optional(:systemctl_enabled) => (String.t() -> {:ok, binary()} | {:error, term()}),
          optional(:listening_ports) => (-> {:ok, [non_neg_integer()]} | {:error, term()})
        }

  @type options :: [
          config_root: Path.t(),
          runtime_root: Path.t(),
          source: String.t(),
          deps: deps()
        ]

  @spec build(map(), options()) :: map()
  def build(registry, opts \\ []) when is_map(registry) and is_list(opts) do
    deps = deps(opts)
    source = opts |> Keyword.get(:source, @default_source) |> safe_status_string(@default_source)
    config_root = opts |> Keyword.get(:config_root, @default_config_root) |> expand_path()
    runtime_root = opts |> Keyword.get(:runtime_root, @default_runtime_root) |> expand_path()
    port_snapshot = safe_port_snapshot(deps)
    projects = registry_projects(registry)

    %{
      status: overall_status(port_snapshot),
      source: source,
      projects:
        projects
        |> Enum.map(&project_probe(&1, config_root, runtime_root, deps, port_snapshot, source))
        |> Map.new(&{&1.project_id, Map.delete(&1, :project_id)})
    }
  end

  @spec build_fun(options()) :: (map() -> map())
  def build_fun(opts \\ []) when is_list(opts) do
    fn registry -> build(registry, opts) end
  end

  defp project_probe(project, config_root, runtime_root, deps, port_snapshot, source) do
    project_id = required_string(project, :project_id)
    service = service_name(project_id)
    config_dir = Path.join(config_root, project_id)
    runtime_dir = Path.join(runtime_root, project_id)
    env_path = Path.join(config_dir, "env")
    workflow_path = Path.join(config_dir, "WORKFLOW.md")
    tracker_config_path = Path.join(config_dir, "TRACKER.yaml")

    service_probe = legacy_service(service, deps)

    config_probe =
      legacy_config_probe(project, project_id, config_dir, env_path, workflow_path, tracker_config_path, deps)

    runtime_probe = runtime_probe(project_id, runtime_dir, config_probe)
    port_probe = port_probe(project, project_id, service, config_probe, port_snapshot)
    legacy_owner? = legacy_owner_present?(service_probe, port_probe)
    unknowns = unknown_sources(service_probe, config_probe, port_snapshot)

    %{
      project_id: project_id,
      source: source,
      status: project_status(service_probe, config_probe, port_snapshot, unknowns),
      legacy_service: service_probe,
      legacy_instances: legacy_instances(project_id, service, service_probe, config_probe, legacy_owner?),
      instance_registry: instance_registry(project_id, service, config_probe, legacy_owner?),
      provider_scope_owners: provider_scope_owners(project, project_id, config_probe, legacy_owner?),
      workspace_owners: workspace_owners(project, project_id, config_probe, legacy_owner?),
      runtime_path_owners: runtime_path_owners(project_id, runtime_probe, legacy_owner?),
      log_path_owners: log_path_owners(project_id, config_probe, legacy_owner?),
      state_path_owners: state_path_owners(project_id, runtime_probe, legacy_owner?),
      port_owners: port_owners(project, port_probe),
      unknown_sources: unknowns
    }
    |> maybe_mark_unknown(:legacy_instances, "config")
    |> maybe_mark_unknown(:legacy_instances, "legacy_config")
    |> maybe_mark_unknown(:instance_registry, "legacy_config")
    |> maybe_mark_unknown(:provider_scope_owners, "legacy_config")
    |> maybe_mark_unknown(:workspace_owners, "legacy_config")
    |> maybe_mark_unknown(:runtime_path_owners, "legacy_config")
    |> maybe_mark_unknown(:log_path_owners, "legacy_config")
    |> maybe_mark_unknown(:state_path_owners, "legacy_config")
    |> maybe_mark_unknown(:port_owners, "port_probe")
  rescue
    _error ->
      fallback_project_id = required_string(project, :project_id)
      fallback_service = service_name(fallback_project_id)

      %{
        project_id: fallback_project_id,
        source: source,
        status: "unknown",
        legacy_service: %{service: fallback_service, active: "unknown", enabled: "unknown", status: "unknown", reason: "project_probe_failed"},
        legacy_instances: "unknown",
        provider_scope_owners: "unknown",
        workspace_owners: "unknown",
        runtime_path_owners: "unknown",
        log_path_owners: "unknown",
        state_path_owners: "unknown",
        port_owners: "unknown",
        unknown_sources: ["project_probe_failed"]
      }
  end

  defp legacy_service(service, deps) do
    show = safe_systemctl_show(service, deps)
    enabled = safe_systemctl_enabled(service, deps)
    active = active_status(show)

    %{
      service: service,
      active: active,
      enabled: enabled_status(enabled),
      status: service_status(active, enabled),
      failed: service_failed?(show, active),
      source: "systemd_user_service"
    }
  end

  defp safe_systemctl_show(service, deps) do
    case deps.systemctl_show.(service) do
      {:ok, %{} = raw} -> normalize_show_map(raw)
      {:ok, raw} when is_binary(raw) -> parse_systemctl_show(raw)
      {:error, _reason} -> %{active: "unknown", sub: nil, failed: false, status: "unknown"}
    end
  rescue
    _error -> %{active: "unknown", sub: nil, failed: false, status: "unknown"}
  end

  defp safe_systemctl_enabled(service, deps) do
    case deps.systemctl_enabled.(service) do
      {:ok, raw} when is_binary(raw) -> String.trim(raw)
      {:error, _reason} -> "unknown"
    end
  rescue
    _error -> "unknown"
  end

  defp active_status(%{active: active}) when active in ["active", "running"], do: true
  defp active_status(%{active: active}) when active in ["inactive", "deactivating", "dead"], do: false
  defp active_status(%{active: "failed"}), do: "failed"
  defp active_status(%{active: active}) when is_binary(active) and active != "", do: "unknown"
  defp active_status(_show), do: "unknown"

  defp enabled_status(value) when is_binary(value) do
    case String.trim(value) do
      status when status in ["enabled", "enabled-runtime", "linked", "linked-runtime"] -> "enabled"
      status when status in ["disabled", "static", "indirect", "masked", "generated", "transient", "not-found"] -> "disabled"
      "" -> "unknown"
      "unknown" -> "unknown"
      _status -> "unknown"
    end
  end

  defp service_status(true, _enabled), do: "active"
  defp service_status(_active, "enabled"), do: "enabled"
  defp service_status("failed", _enabled), do: "failed"
  defp service_status("unknown", _enabled), do: "unknown"
  defp service_status(_active, "unknown"), do: "unknown"
  defp service_status(_active, _enabled), do: "inactive"

  defp service_failed?(%{failed: true}, _active), do: true
  defp service_failed?(_show, "failed"), do: true
  defp service_failed?(_show, _active), do: false

  defp normalize_show_map(raw) do
    active = map_get(raw, :active) || map_get(raw, :ActiveState) || map_get(raw, "ActiveState")
    sub = map_get(raw, :sub) || map_get(raw, :SubState) || map_get(raw, "SubState")
    result = map_get(raw, :result) || map_get(raw, :Result) || map_get(raw, "Result")
    failed = map_get(raw, :failed) == true or result == "failed" or active == "failed"
    %{active: normalize_status(active), sub: optional_string(sub), failed: failed}
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

    normalize_show_map(values)
  end

  defp legacy_config_probe(project, project_id, config_dir, env_path, workflow_path, tracker_config_path, deps) do
    env_result = read_env_file(env_path, deps)
    config_dir_exists? = safe_dir?(config_dir, deps)
    workflow_exists? = deps.file_regular?.(workflow_path)
    tracker_exists? = deps.file_regular?.(tracker_config_path)

    settings_result =
      if workflow_exists? and tracker_exists? do
        parse_settings(workflow_path, tracker_config_path)
      else
        {:error, :legacy_config_missing}
      end

    env = result_value(env_result, %{})
    settings = result_value(settings_result, nil)
    provider_scope = provider_scope(project_id, settings)
    workspace_root = env_string(env, "SYMPHONY_WORKSPACE_ROOT") || workspace_root(settings)
    logs_root = env_string(env, "SYMPHONY_LOGS_ROOT")
    port = env_port(env) || server_port(settings)

    %{
      status: config_status(config_dir_exists?, workflow_exists?, tracker_exists?, env_result, settings_result),
      config_present?: config_dir_exists? or workflow_exists? or tracker_exists?,
      config_dir: config_dir,
      env_path: env_path,
      workflow_path: workflow_path,
      tracker_config_path: tracker_config_path,
      workflow_present?: workflow_exists?,
      tracker_config_present?: tracker_exists?,
      env_status: result_status(env_result),
      settings_status: result_status(settings_result),
      provider_scope_key: provider_scope && provider_scope.key,
      provider_kind: provider_scope && provider_scope.kind,
      workspace_root: workspace_root,
      logs_root: logs_root,
      server_port: port,
      project_id: project_id,
      matches_hub?: legacy_matches_hub?(project, provider_scope, workspace_root, port)
    }
  rescue
    _error ->
      %{
        status: "unknown",
        config_present?: false,
        config_dir: config_dir,
        env_path: env_path,
        workflow_path: workflow_path,
        tracker_config_path: tracker_config_path,
        env_status: "unknown",
        settings_status: "unknown",
        project_id: project_id,
        matches_hub?: false
      }
  end

  defp read_env_file(path, deps) do
    if deps.file_regular?.(path) do
      case deps.read_file.(path) do
        {:ok, content} -> {:ok, parse_env(content)}
        {:error, _reason} -> {:error, :env_unreadable}
      end
    else
      {:ok, %{}}
    end
  rescue
    _error -> {:error, :env_unreadable}
  end

  defp parse_env(content) do
    content
    |> String.split(["\n", "\r\n"], trim: true)
    |> Enum.reduce(%{}, fn line, env ->
      case parse_env_line(line) do
        {key, value} -> Map.put(env, key, value)
        nil -> env
      end
    end)
  end

  defp parse_env_line("#" <> _comment), do: nil

  defp parse_env_line(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)

        if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, key) do
          {key, value |> String.trim() |> trim_quotes()}
        else
          nil
        end

      _invalid ->
        nil
    end
  end

  defp trim_quotes("\"" <> rest), do: String.trim_trailing(rest, "\"")
  defp trim_quotes("'" <> rest), do: String.trim_trailing(rest, "'")
  defp trim_quotes(value), do: value

  defp parse_settings(workflow_path, tracker_config_path) do
    with {:ok, %{config: config, workflow: workflow_definition}} <- Workflow.load(workflow_path),
         {:ok, tracker_config} <- TrackerConfig.load(tracker_config_path) do
      parse_settings_config(config, workflow_definition, tracker_config)
    end
  end

  defp parse_settings_config(config, nil, _tracker_config), do: Config.Schema.parse(config)

  defp parse_settings_config(config, %Definition{} = workflow_definition, tracker_config) do
    workflow_map = Definition.to_map(workflow_definition)

    with :ok <- Tracker.validate_workflow_state_mapping(workflow_map, tracker_config) do
      config
      |> Map.drop(["workflow", "start_stage", "terminal_stages", "outcomes", "missing_outcome", "stages"])
      |> Map.merge(TrackerConfig.normalize_for_settings(tracker_config, workflow_map))
      |> Map.put("workflow", workflow_map)
      |> Map.put("tracker_config", tracker_config)
      |> Config.Schema.parse()
    end
  end

  defp provider_scope(project_id, settings) do
    case ProviderScope.from_tracker(project_id, settings && settings.tracker) do
      {:ok, scope} -> scope
      {:error, _reason} -> nil
    end
  end

  defp config_status(true, _workflow?, _tracker?, {:error, _reason}, _settings), do: "unknown"
  defp config_status(true, _workflow?, _tracker?, _env, {:error, _reason}), do: "unknown"
  defp config_status(true, true, true, _env, {:ok, _settings}), do: "present"
  defp config_status(true, _workflow?, _tracker?, _env, _settings), do: "unknown"
  defp config_status(false, false, false, _env, _settings), do: "absent"
  defp config_status(_config_dir?, _workflow?, _tracker?, _env, _settings), do: "unknown"

  defp legacy_matches_hub?(project, provider_scope, workspace_root, port) do
    provider_scope_key = get_in_map(project, [:tracker_summary, :provider_scope_key])
    hub_workspace_root = get_in_map(project, [:runtime_summary, :workspace_root])
    hub_port = get_in_map(project, [:runtime_summary, :server_port])

    (not is_nil(provider_scope) and not blank?(provider_scope_key) and provider_scope.key == provider_scope_key) or
      same_path?(workspace_root, hub_workspace_root) or
      (not is_nil(non_negative_integer(port)) and non_negative_integer(port) == non_negative_integer(hub_port))
  end

  defp runtime_probe(project_id, runtime_dir, config_probe) do
    %{
      runtime_dir: runtime_dir,
      state_path: Path.join(runtime_dir, "state"),
      project_id: project_id,
      config_status: config_probe.status,
      owner_present?: config_probe.config_present?
    }
  end

  defp port_probe(project, project_id, service, config_probe, %{status: "ok", ports: ports}) do
    hub_port = get_in_map(project, [:runtime_summary, :server_port])
    legacy_port = config_probe.server_port
    port = legacy_port || hub_port

    %{
      status: "ok",
      project_id: project_id,
      service: service,
      port: port,
      listening?: not is_nil(non_negative_integer(port)) and non_negative_integer(port) in ports,
      matches_hub?:
        not is_nil(non_negative_integer(legacy_port)) and
          non_negative_integer(legacy_port) == non_negative_integer(hub_port)
    }
  end

  defp port_probe(_project, project_id, service, _config_probe, %{status: status}) do
    %{
      status: safe_status_string(status, "unknown"),
      project_id: project_id,
      service: service,
      port: nil,
      listening?: false,
      matches_hub?: false
    }
  end

  defp safe_port_snapshot(deps) do
    case deps.listening_ports.() do
      {:ok, ports} when is_list(ports) ->
        %{status: "ok", ports: ports |> Enum.flat_map(&port_list_entry/1) |> Enum.uniq()}

      {:error, _reason} ->
        %{status: "unknown", ports: []}
    end
  rescue
    _error -> %{status: "unknown", ports: []}
  end

  defp port_list_entry(port) when is_integer(port) and port >= 0, do: [port]

  defp port_list_entry(port) when is_binary(port) do
    case Integer.parse(String.trim(port)) do
      {integer, ""} when integer >= 0 -> [integer]
      _invalid -> []
    end
  end

  defp port_list_entry(_port), do: []

  defp legacy_owner_present?(%{status: status}, _port_probe) when status in ["active", "enabled", "failed"], do: true
  defp legacy_owner_present?(_service_probe, %{status: "ok", listening?: true}), do: true
  defp legacy_owner_present?(_service_probe, _port_probe), do: false

  defp legacy_instances(project_id, service, service_probe, config_probe, legacy_owner?) do
    cond do
      service_probe.status in ["active", "enabled", "failed"] ->
        [%{project_id: project_id, service: service, owner: service, status: service_probe.status, reason: "systemd_template_instance"}]

      legacy_owner? and config_probe.config_present? ->
        [%{project_id: project_id, service: service, owner: service, status: config_probe.status, reason: "legacy_config_present"}]

      true ->
        []
    end
  end

  defp instance_registry(project_id, service, %{config_present?: true, status: status}, true) do
    [%{project_id: project_id, service: service, owner: service, status: status, reason: "legacy_project_config"}]
  end

  defp instance_registry(_project_id, _service, _config_probe, _legacy_owner?), do: []

  defp provider_scope_owners(project, project_id, %{provider_scope_key: key, status: status}, true)
       when is_binary(key) do
    hub_key = get_in_map(project, [:tracker_summary, :provider_scope_key])

    if key == hub_key do
      [%{project_id: project_id, provider_scope_key: key, owner: project_id, status: status, reason: "legacy_tracker_config"}]
    else
      []
    end
  end

  defp provider_scope_owners(_project, _project_id, _config_probe, _legacy_owner?), do: []

  defp workspace_owners(project, project_id, %{workspace_root: workspace_root, status: status}, true)
       when is_binary(workspace_root) do
    hub_workspace_root = get_in_map(project, [:runtime_summary, :workspace_root])

    if same_path?(workspace_root, hub_workspace_root) do
      [
        %{
          project_id: project_id,
          workspace_root: path_fingerprint(workspace_root),
          owner: project_id,
          status: status,
          reason: "legacy_tracker_config"
        }
      ]
    else
      []
    end
  end

  defp workspace_owners(_project, _project_id, _config_probe, _legacy_owner?), do: []

  defp runtime_path_owners(project_id, %{runtime_dir: runtime_dir, config_status: status, owner_present?: true}, true) do
    [
      %{
        project_id: project_id,
        runtime_path: path_fingerprint(runtime_dir),
        owner: project_id,
        status: status,
        reason: "legacy_runtime_root"
      }
    ]
  end

  defp runtime_path_owners(_project_id, _runtime_probe, _legacy_owner?), do: []

  defp log_path_owners(project_id, %{logs_root: logs_root, status: status}, true) when is_binary(logs_root) do
    [%{project_id: project_id, log_path: path_fingerprint(logs_root), owner: project_id, status: status, reason: "legacy_env"}]
  end

  defp log_path_owners(_project_id, _config_probe, _legacy_owner?), do: []

  defp state_path_owners(project_id, %{state_path: state_path, config_status: status, owner_present?: true}, true) do
    [
      %{
        project_id: project_id,
        state_path: path_fingerprint(state_path),
        owner: project_id,
        status: status,
        reason: "legacy_runtime_root"
      }
    ]
  end

  defp state_path_owners(_project_id, _runtime_probe, _legacy_owner?), do: []

  defp port_owners(_project, %{status: "ok", listening?: true, matches_hub?: true} = port_probe) do
    [%{project_id: port_probe.project_id, port: port_probe.port, service: port_probe.service, status: "listening", reason: "legacy_dashboard_port"}]
  end

  defp port_owners(_project, %{status: "ok", listening?: true, port: port} = port_probe)
       when not is_nil(port) do
    [%{project_id: port_probe.project_id, port: port_probe.port, service: port_probe.service, status: "listening", reason: "legacy_dashboard_port"}]
  end

  defp port_owners(_project, _port_probe), do: []

  defp unknown_sources(service_probe, config_probe, port_snapshot) do
    []
    |> maybe_unknown(service_probe.status == "unknown", "legacy_service")
    |> maybe_unknown(config_probe.status == "unknown", "legacy_config")
    |> maybe_unknown(port_snapshot.status == "unknown", "port_probe")
  end

  defp maybe_unknown(sources, true, source), do: [source | sources]
  defp maybe_unknown(sources, _condition, _source), do: sources

  defp project_status(_service_probe, _config_probe, _port_snapshot, [_first | _rest]), do: "unknown"
  defp project_status(%{status: status}, _config_probe, _port_snapshot, _unknowns) when status in ["active", "enabled", "failed"], do: "conflict"
  defp project_status(_service_probe, _config_probe, _port_snapshot, _unknowns), do: "ok"

  defp maybe_mark_unknown(%{unknown_sources: unknowns} = probe, key, source) do
    if source in unknowns do
      Map.put(probe, key, "unknown")
    else
      probe
    end
  end

  defp overall_status(%{status: "unknown"}), do: "unknown"
  defp overall_status(_port_snapshot), do: "ok"

  defp result_value({:ok, value}, _default), do: value
  defp result_value({:error, _reason}, default), do: default

  defp result_status({:ok, _value}), do: "ok"
  defp result_status({:error, _reason}), do: "unknown"

  defp registry_projects(%{projects: projects}) when is_list(projects), do: projects
  defp registry_projects(%{"projects" => projects}) when is_list(projects), do: projects
  defp registry_projects(_registry), do: []

  defp service_name(project_id), do: "symphony@#{project_id}.service"

  defp workspace_root(nil), do: nil
  defp workspace_root(settings), do: settings.workspace.root

  defp server_port(nil), do: nil
  defp server_port(settings), do: settings.server.port

  defp env_string(env, key) do
    case Map.get(env, key) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp env_port(env) do
    case Integer.parse(Map.get(env, "SYMPHONY_PORT", "")) do
      {port, ""} when port >= 0 -> port
      _invalid -> nil
    end
  end

  defp path_fingerprint(path) when is_binary(path) do
    %{
      present: true,
      basename: Path.basename(path),
      sha256: :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)
    }
  end

  defp same_path?(nil, _right), do: false
  defp same_path?(_left, nil), do: false

  defp same_path?(left, right) do
    Path.expand(left) == Path.expand(right)
  rescue
    _error -> left == right
  end

  defp safe_dir?(path, deps) do
    deps.file_dir?.(path)
  rescue
    _error -> false
  end

  defp expand_path(path) when is_binary(path), do: Path.expand(path)
  defp expand_path(path), do: Path.expand(to_string(path))

  defp normalize_status(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp normalize_status(value), do: safe_status_string(value, "unknown")

  defp required_string(map, key), do: optional_string(map, key) || ""

  defp optional_string(map, key), do: map |> map_get(key) |> optional_string()
  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(value) when is_map(value) or is_list(value), do: nil
  defp optional_string(value), do: to_string(value)

  defp safe_status_string(value, fallback) do
    value
    |> optional_string()
    |> case do
      nil -> fallback
      "" -> fallback
      status -> status
    end
  end

  defp blank?(value), do: optional_string(value) in [nil, ""]
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _invalid -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp get_in_map(map, path) do
    Enum.reduce_while(path, map, fn key, acc ->
      case map_get(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, nil} -> Map.get(map, Atom.to_string(key))
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp map_get(map, key) when is_map(map), do: Map.get(map, key)
  defp map_get(_value, _key), do: nil

  defp deps(opts) do
    Keyword.get(opts, :deps, %{
      file_regular?: &File.regular?/1,
      file_dir?: &File.dir?/1,
      read_file: &File.read/1,
      systemctl_show: &systemctl_show/1,
      systemctl_enabled: &systemctl_enabled/1,
      listening_ports: &listening_ports/0
    })
    |> Map.new()
    |> Map.put_new(:file_regular?, &File.regular?/1)
    |> Map.put_new(:file_dir?, &File.dir?/1)
    |> Map.put_new(:read_file, &File.read/1)
    |> Map.put_new(:systemctl_show, &systemctl_show/1)
    |> Map.put_new(:systemctl_enabled, &systemctl_enabled/1)
    |> Map.put_new(:listening_ports, &listening_ports/0)
  end

  defp systemctl_show(service) do
    case System.cmd(
           "systemctl",
           ["--user", "show", service, "--property=ActiveState", "--property=SubState", "--property=Result"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {_output, _exit_status} -> {:error, :systemctl_show_failed}
    end
  rescue
    _error -> {:error, :systemctl_unavailable}
  end

  defp systemctl_enabled(service) do
    case System.cmd("systemctl", ["--user", "is-enabled", service], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _exit_status} -> {:ok, String.trim(output)}
    end
  rescue
    _error -> {:error, :systemctl_unavailable}
  end

  defp listening_ports do
    case System.cmd("ss", ["-H", "-ltn"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, parse_listening_ports(output)}
      {_output, _exit_status} -> {:error, :port_probe_unavailable}
    end
  rescue
    _error -> {:error, :port_probe_unavailable}
  end

  defp parse_listening_ports(output) do
    Regex.scan(~r/:(\d+)(?:\s|$)/, output)
    |> Enum.flat_map(fn [_match, port] -> port_list_entry(port) end)
    |> Enum.uniq()
  end
end
