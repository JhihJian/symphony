defmodule SymphonyElixir.Hub.ActivationPreflight do
  @moduledoc """
  Hub activation preflight and legacy ownership guardrail.

  The preflight evaluates whether a Hub project can be safely managed by the
  Hub-owned path before poll, dispatch, worker start, or writeback operations
  perform real work. Inputs are registry/project snapshots and injectable
  host/service probe summaries; outputs are serializable, redacted summaries.
  """

  alias SymphonyElixir.Hub.SafeSummary

  @version 1
  @operations ["poll", "dispatch", "worker_start", "writeback"]
  @statuses ["safe_to_manage", "blocked_conflict", "unknown_manual_attention", "not_hub_managed", "config_invalid"]
  @conflict_sources [
    "legacy_service",
    "legacy_instance",
    "provider_scope_owner",
    "workspace_owner",
    "runtime_path_owner",
    "log_path_owner",
    "state_path_owner",
    "dashboard_port_owner",
    "api_port_owner",
    "instance_registry",
    "host_probe"
  ]
  @sensitive_path_keys MapSet.new([
                         "config_path",
                         "env_path",
                         "log_path",
                         "logs_path",
                         "logs_root",
                         "path",
                         "root",
                         "runtime_path",
                         "runtime_root",
                         "state_path",
                         "tracker_config_path",
                         "workflow_path",
                         "workspace_path",
                         "workspace_root"
                       ])

  @type summary :: map()

  @spec build(map(), keyword()) :: summary()
  def build(registry_or_project, opts \\ []) when is_map(registry_or_project) and is_list(opts) do
    now = normalize_datetime(Keyword.get(opts, :now)) || DateTime.utc_now()
    probe = Keyword.get(opts, :probe) || Keyword.get(opts, :host_probe) || %{}
    projects = projects_from_input(registry_or_project)

    project_summaries =
      projects
      |> Enum.map(&project_summary(&1, probe, now))
      |> Enum.sort_by(& &1.project_id)

    %{
      version: @version,
      generated_at: iso8601(now),
      status: overall_status(project_summaries),
      counts: counts(project_summaries),
      projects: project_summaries
    }
    |> to_snapshot()
  end

  @spec empty(map(), keyword()) :: summary()
  def empty(registry, opts \\ []) when is_map(registry) and is_list(opts) do
    build(registry, opts)
  end

  @spec to_snapshot(term()) :: summary()
  def to_snapshot(summary) when is_map(summary) do
    projects =
      summary
      |> list_value(:projects)
      |> Enum.map(&project_snapshot/1)
      |> Enum.sort_by(& &1.project_id)

    %{
      version: positive_integer(value(summary, :version)) || @version,
      generated_at: iso8601(value(summary, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601(),
      status: normalize_overall_status(value(summary, :status), projects),
      counts: count_snapshot(value(summary, :counts), projects),
      projects: projects
    }
  end

  def to_snapshot(_summary), do: to_snapshot(%{})

  @spec from_snapshot(term()) :: {:ok, summary()} | {:error, [map()]}
  def from_snapshot(snapshot) when is_map(snapshot) do
    case privacy_diagnostics(snapshot) do
      [] -> {:ok, to_snapshot(snapshot)}
      diagnostics -> {:error, diagnostics}
    end
  end

  def from_snapshot(_snapshot) do
    {:error,
     [
       %{
         level: :error,
         code: :invalid_activation_preflight_snapshot,
         message: "Activation preflight snapshot must be a map"
       }
     ]}
  end

  @spec observability_snapshot(term()) :: summary() | nil
  def observability_snapshot(nil), do: nil
  def observability_snapshot(summary) when is_map(summary), do: to_snapshot(summary)
  def observability_snapshot(_summary), do: nil

  @spec project(summary() | map(), String.t() | nil) :: map() | nil
  def project(summary, project_id) when is_map(summary) and is_binary(project_id) do
    summary
    |> to_snapshot()
    |> list_value(:projects)
    |> Enum.find(&(&1.project_id == project_id))
  end

  def project(_summary, _project_id), do: nil

  @spec safe_to_manage?(summary() | map(), String.t() | nil, String.t() | atom()) :: boolean()
  def safe_to_manage?(summary, project_id, operation) do
    case project(summary, project_id) do
      %{safe_to_manage: true, blocked_operations: blocked} ->
        operation_name(operation) not in blocked

      _project ->
        false
    end
  end

  @spec block_reason(summary() | map(), String.t() | nil, String.t() | atom()) :: map() | nil
  def block_reason(summary, project_id, operation) do
    operation = operation_name(operation)

    case project(summary, project_id) do
      nil ->
        nil

      project ->
        cond do
          operation in project.blocked_operations ->
            %{
              reason: project.reason,
              status: project.status,
              message: project.message,
              blocked_operations: project.blocked_operations,
              sources: Enum.map(project.detected_legacy_ownership, & &1.source)
            }

          project.safe_to_manage == true ->
            nil

          true ->
            nil
        end
    end
  end

  defp project_summary(project, probe, now) do
    project = normalize_project(project)
    project_id = required_string(project, :project_id)
    migration_state = migration_state(project)
    probe_summary = project_probe(probe, project)
    ownership = detected_ownership(project, probe_summary)
    unknowns = unknown_probe_results(probe_summary)

    {status, reason, message, blocked_operations} =
      status_for(project, migration_state, ownership, unknowns)

    %{
      project_id: project_id,
      name: optional_string(project, :name),
      migration_state: migration_state,
      status: status,
      safe_to_manage: status == "safe_to_manage",
      reason: reason,
      message: message,
      blocked_operations: blocked_operations,
      checked_at: iso8601(now),
      probe_source: probe_source(probe_summary),
      provider: provider_summary(project),
      resources: resource_summary(project),
      detected_legacy_ownership: ownership,
      unknown_probe_results: unknowns,
      conflict_count: length(ownership),
      manual_attention_count: manual_attention_count(status, ownership, unknowns)
    }
    |> project_snapshot()
  end

  defp normalize_project(project) when is_map(project), do: project
  defp normalize_project(_project), do: %{}

  defp status_for(project, migration_state, ownership, unknowns) do
    cond do
      config_invalid?(project) ->
        {"config_invalid", "project_config_invalid", "Project configuration is invalid", @operations}

      migration_state != "hub_managed" ->
        {"not_hub_managed", "migration_state_not_hub_managed", "Project is not marked hub_managed", []}

      ownership != [] ->
        {"blocked_conflict", "legacy_ownership_conflict", "Legacy ownership conflict detected", @operations}

      unknowns != [] ->
        {"unknown_manual_attention", "probe_unknown", "Activation preflight could not prove Hub ownership is safe", @operations}

      true ->
        {"safe_to_manage", "hub_managed_no_conflict", "Project is marked hub_managed and no legacy ownership was detected", []}
    end
  end

  defp config_invalid?(project) do
    safe_status(value(project, :status)) in ["error", "config_invalid"] or not blank?(optional_string(project, :load_error))
  end

  defp detected_ownership(project, probe) do
    []
    |> add_service_ownership(project, probe)
    |> add_probe_ownership(project, probe, :legacy_instances, "legacy_instance")
    |> add_probe_ownership(project, probe, :provider_scope_owners, "provider_scope_owner")
    |> add_probe_ownership(project, probe, :workspace_owners, "workspace_owner")
    |> add_probe_ownership(project, probe, :runtime_path_owners, "runtime_path_owner")
    |> add_probe_ownership(project, probe, :log_path_owners, "log_path_owner")
    |> add_probe_ownership(project, probe, :state_path_owners, "state_path_owner")
    |> add_probe_ownership(project, probe, :port_owners, "dashboard_port_owner")
    |> add_probe_ownership(project, probe, :instance_registry, "instance_registry")
    |> Enum.reverse()
    |> Enum.uniq_by(&{&1.source, &1.reason, &1.owner})
  end

  defp add_service_ownership(ownership, project, probe) do
    service = map_value(probe, :legacy_service) || map_value(probe, :service) || %{}
    active = status_value(service, :active)
    enabled = status_value(service, :enabled)
    service_name = optional_string(service, :service) || optional_string(service, :name) || "symphony@#{required_string(project, :project_id)}.service"

    cond do
      truthy?(active) ->
        [ownership_entry("legacy_service", "legacy_service_active", service_name, service) | ownership]

      truthy?(enabled) ->
        [ownership_entry("legacy_service", "legacy_service_enabled", service_name, service) | ownership]

      true ->
        ownership
    end
  end

  defp add_probe_ownership(ownership, project, probe, key, source) do
    probe
    |> list_value(key)
    |> Enum.reduce(ownership, fn owner, acc ->
      if owner_matches_project?(owner, project, source) do
        [ownership_entry(source, ownership_reason(source), owner_name(owner, source), owner) | acc]
      else
        acc
      end
    end)
  end

  defp owner_matches_project?(owner, project, source) do
    project_id = required_string(project, :project_id)
    provider_scope_key = get_in_map(project, [:tracker_summary, :provider_scope_key])
    workspace_root = get_in_map(project, [:runtime_summary, :workspace_root])
    server_port = get_in_map(project, [:runtime_summary, :server_port])

    cond do
      optional_string(owner, :project_id) == project_id ->
        true

      source == "provider_scope_owner" and not blank?(provider_scope_key) ->
        optional_string(owner, :provider_scope_key) == provider_scope_key

      source == "workspace_owner" and not blank?(workspace_root) ->
        same_path?(optional_string(owner, :workspace_root) || optional_string(owner, :path), workspace_root)

      source in ["runtime_path_owner", "log_path_owner", "state_path_owner"] ->
        owner_project_id = optional_string(owner, :project_id)
        not blank?(owner_project_id) and owner_project_id == project_id

      source in ["dashboard_port_owner", "instance_registry"] and not is_nil(non_negative_integer(server_port)) ->
        owner_port = optional_string(owner, :port) || optional_string(owner, :server_port)
        non_negative_integer(owner_port) == non_negative_integer(server_port)

      true ->
        false
    end
  end

  defp same_path?(nil, _right), do: false
  defp same_path?(_left, nil), do: false

  defp same_path?(left, right) do
    Path.expand(left) == Path.expand(right)
  rescue
    _error -> left == right
  end

  defp ownership_reason("legacy_instance"), do: "legacy_instance_registered"
  defp ownership_reason("provider_scope_owner"), do: "legacy_provider_scope_owner"
  defp ownership_reason("workspace_owner"), do: "legacy_workspace_owner"
  defp ownership_reason("runtime_path_owner"), do: "legacy_runtime_path_owner"
  defp ownership_reason("log_path_owner"), do: "legacy_log_path_owner"
  defp ownership_reason("state_path_owner"), do: "legacy_state_path_owner"
  defp ownership_reason("dashboard_port_owner"), do: "legacy_dashboard_port_owner"
  defp ownership_reason("instance_registry"), do: "legacy_instance_registry_owner"
  defp ownership_reason(_source), do: "legacy_ownership"

  defp ownership_entry(source, reason, owner, raw) do
    %{
      source: source,
      reason: reason,
      owner: owner,
      status: safe_status(value(raw, :status) || value(raw, :active) || value(raw, :enabled)),
      evidence: safe_evidence(raw)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == %{} end)
    |> Map.new()
  end

  defp owner_name(owner, source) do
    optional_string(owner, :service) ||
      optional_string(owner, :name) ||
      optional_string(owner, :owner) ||
      optional_string(owner, :project_id) ||
      optional_string(owner, :provider_scope_key) ||
      optional_string(owner, :port) ||
      source
  end

  defp unknown_probe_results(probe) do
    []
    |> add_unknown(probe_unknown?(probe), "host_probe", "probe_unknown", probe)
    |> add_unknown(
      service_unknown?(probe),
      "legacy_service",
      "legacy_service_unknown",
      map_value(probe, :legacy_service) || map_value(probe, :service) || %{}
    )
    |> add_unknown(list_unknown?(probe, :legacy_instances), "legacy_instance", "legacy_instances_unknown", probe)
    |> add_unknown(list_unknown?(probe, :provider_scope_owners), "provider_scope_owner", "provider_scope_owner_unknown", probe)
    |> add_unknown(list_unknown?(probe, :workspace_owners), "workspace_owner", "workspace_owner_unknown", probe)
    |> add_unknown(list_unknown?(probe, :runtime_path_owners), "runtime_path_owner", "runtime_path_owner_unknown", probe)
    |> add_unknown(list_unknown?(probe, :log_path_owners), "log_path_owner", "log_path_owner_unknown", probe)
    |> add_unknown(list_unknown?(probe, :state_path_owners), "state_path_owner", "state_path_owner_unknown", probe)
    |> add_unknown(list_unknown?(probe, :port_owners), "dashboard_port_owner", "dashboard_port_owner_unknown", probe)
    |> add_unknown(list_unknown?(probe, :instance_registry), "instance_registry", "instance_registry_unknown", probe)
    |> Enum.reverse()
    |> Enum.uniq_by(&{&1.source, &1.reason})
  end

  defp add_unknown(unknowns, true, source, reason, raw) do
    [%{source: source, reason: reason, evidence: safe_evidence(raw)} | unknowns]
  end

  defp add_unknown(unknowns, _condition, _source, _reason, _raw), do: unknowns

  defp probe_unknown?(probe) do
    status_value(probe, :status) in ["unknown", "failed", "error", "timeout", "unavailable"] or
      status_value(probe, :result) in ["unknown", "failed", "error", "timeout", "unavailable"]
  end

  defp service_unknown?(probe) do
    service = map_value(probe, :legacy_service) || map_value(probe, :service) || %{}

    status_value(service, :active) == "unknown" or
      status_value(service, :enabled) == "unknown" or
      status_value(service, :status) in ["unknown", "failed", "error"]
  end

  defp list_unknown?(probe, key) do
    value(probe, key) in [:unknown, "unknown", :error, "error", :failed, "failed"]
  end

  defp project_probe(probe, project) do
    project_id = required_string(project, :project_id)

    cond do
      is_map(map_value(probe, :projects)) ->
        map_value(probe, :projects)
        |> value(project_id)
        |> case do
          project_probe when is_map(project_probe) -> project_probe
          _other -> probe
        end

      is_list(value(probe, :projects)) ->
        probe
        |> list_value(:projects)
        |> Enum.find(&(optional_string(&1, :project_id) == project_id))
        |> case do
          project_probe when is_map(project_probe) -> project_probe
          _other -> probe
        end

      true ->
        probe || %{}
    end
  end

  defp probe_source(probe) do
    optional_string(probe, :source) ||
      optional_string(probe, :probe_source) ||
      "injected"
  end

  defp migration_state(project) do
    project
    |> value(:migration_state)
    |> Kernel.||(value(project, :hub_migration_state))
    |> normalize_migration_state()
  end

  defp normalize_migration_state(value) do
    value
    |> optional_string()
    |> case do
      "legacy-only" -> "legacy_only"
      "legacy_only" -> "legacy_only"
      "hub-managed" -> "hub_managed"
      "hub_managed" -> "hub_managed"
      "hub-ready" -> "hub_ready"
      "hub_ready" -> "hub_ready"
      _other -> "hub_ready"
    end
  end

  defp provider_summary(project) do
    tracker = map_value(project, :tracker_summary) || %{}

    %{
      kind: optional_string(tracker, :kind),
      provider_scope_key: optional_string(tracker, :provider_scope_key)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp resource_summary(project) do
    runtime = map_value(project, :runtime_summary) || %{}
    runtime_state_path = optional_string(runtime, :runtime_state_path) || optional_string(runtime, :state_path)

    %{
      workspace_root: path_fingerprint(optional_string(runtime, :workspace_root)),
      runtime_state_path: path_fingerprint(runtime_state_path),
      log_path: path_fingerprint(optional_string(runtime, :log_path) || optional_string(runtime, :logs_root)),
      server_port: non_negative_integer(value(runtime, :server_port))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp path_fingerprint(nil), do: nil

  defp path_fingerprint(path) do
    %{
      present: true,
      basename: Path.basename(path),
      sha256: :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)
    }
  rescue
    _error -> %{present: true, sha256: :crypto.hash(:sha256, to_string(path)) |> Base.encode16(case: :lower)}
  end

  defp safe_evidence(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {key, raw_value}, acc ->
      normalized = key |> to_string() |> String.downcase()

      cond do
        normalized in @sensitive_path_keys and is_map(raw_value) ->
          Map.put(acc, output_key(key), SafeSummary.sanitize_map(raw_value, output_keys: :preserve))

        normalized in @sensitive_path_keys ->
          Map.put(acc, output_key(key), path_fingerprint(optional_string(raw_value)))

        SafeSummary.sensitive_key?(normalized) or SafeSummary.sensitive_value?(raw_value) ->
          acc

        normalized in ["raw", "raw_output", "raw_config", "provider_response"] ->
          acc

        is_map(raw_value) or is_list(raw_value) ->
          Map.put(acc, output_key(key), SafeSummary.sanitize_value(raw_value, output_keys: :preserve))

        true ->
          Map.put(acc, output_key(key), SafeSummary.sanitize_value(raw_value, output_keys: :preserve))
      end
    end)
  end

  defp safe_evidence(_value), do: %{}

  defp output_key(key) when is_atom(key), do: key
  defp output_key(key) when is_binary(key), do: key
  defp output_key(key), do: to_string(key)

  defp safe_string_map(value) when is_map(value) do
    value
    |> SafeSummary.sanitize_map(output_keys: :preserve)
    |> stringify_keys()
  end

  defp safe_string_map(_value), do: %{}

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, raw_value} ->
      {to_string(key), stringify_keys(raw_value)}
    end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_keys(value), do: value

  defp project_snapshot(project) when is_map(project) do
    %{
      project_id: optional_string(project, :project_id) || "",
      name: optional_string(project, :name),
      migration_state: normalize_migration_state(value(project, :migration_state)),
      status: normalize_status(value(project, :status)),
      safe_to_manage: value(project, :safe_to_manage) == true,
      reason: optional_string(project, :reason),
      message: optional_string(project, :message),
      blocked_operations: operation_list(value(project, :blocked_operations)),
      checked_at: iso8601(value(project, :checked_at)),
      probe_source: optional_string(project, :probe_source),
      provider: project |> map_value(:provider) |> safe_string_map(),
      resources: project |> map_value(:resources) |> safe_string_map(),
      detected_legacy_ownership: project |> list_value(:detected_legacy_ownership) |> Enum.map(&ownership_snapshot/1),
      unknown_probe_results: project |> list_value(:unknown_probe_results) |> Enum.map(&unknown_snapshot/1),
      conflict_count: non_negative_integer(value(project, :conflict_count)) || 0,
      manual_attention_count: non_negative_integer(value(project, :manual_attention_count)) || 0
    }
  end

  defp project_snapshot(_project), do: project_snapshot(%{})

  defp ownership_snapshot(ownership) when is_map(ownership) do
    %{
      source: normalized_source(value(ownership, :source)),
      reason: optional_string(ownership, :reason),
      owner: optional_string(ownership, :owner),
      status: safe_status(value(ownership, :status)),
      evidence: safe_evidence(map_value(ownership, :evidence) || ownership)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == %{} end)
    |> Map.new()
  end

  defp ownership_snapshot(_ownership), do: ownership_snapshot(%{})

  defp unknown_snapshot(unknown) when is_map(unknown) do
    %{
      source: normalized_source(value(unknown, :source)),
      reason: optional_string(unknown, :reason),
      evidence: safe_evidence(map_value(unknown, :evidence) || unknown)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == %{} end)
    |> Map.new()
  end

  defp unknown_snapshot(_unknown), do: unknown_snapshot(%{})

  defp normalized_source(value) do
    source = optional_string(value)

    if source in @conflict_sources do
      source
    else
      "host_probe"
    end
  end

  defp count_snapshot(counts, projects) when is_map(counts) do
    %{
      project_count: non_negative_integer(value(counts, :project_count)) || length(projects),
      safe_count: non_negative_integer(value(counts, :safe_count)) || Enum.count(projects, &(&1.status == "safe_to_manage")),
      blocked_count: non_negative_integer(value(counts, :blocked_count)) || Enum.count(projects, &(&1.status == "blocked_conflict")),
      unknown_count: non_negative_integer(value(counts, :unknown_count)) || Enum.count(projects, &(&1.status == "unknown_manual_attention")),
      manual_attention_count:
        non_negative_integer(value(counts, :manual_attention_count)) ||
          Enum.reduce(projects, 0, &(&2 + &1.manual_attention_count)),
      conflict_count:
        non_negative_integer(value(counts, :conflict_count)) ||
          Enum.reduce(projects, 0, &(&2 + &1.conflict_count))
    }
  end

  defp count_snapshot(_counts, projects), do: counts(projects)

  defp counts(projects) do
    count_snapshot(%{}, projects)
  end

  defp overall_status(projects) do
    cond do
      Enum.any?(projects, &(&1.status == "blocked_conflict")) -> "blocked_conflict"
      Enum.any?(projects, &(&1.status == "unknown_manual_attention")) -> "unknown_manual_attention"
      Enum.any?(projects, &(&1.status in ["config_invalid", "not_hub_managed"])) -> "manual_attention"
      true -> "safe_to_manage"
    end
  end

  defp normalize_overall_status(status, projects) do
    status = optional_string(status)

    if status in @statuses or status == "manual_attention" do
      status
    else
      overall_status(projects)
    end
  end

  defp normalize_status(status) do
    status = optional_string(status)

    if status in @statuses do
      status
    else
      "unknown_manual_attention"
    end
  end

  defp manual_attention_count("safe_to_manage", _ownership, _unknowns), do: 0
  defp manual_attention_count(_status, ownership, unknowns), do: max(length(ownership) + length(unknowns), 1)

  defp operation_list(value) when is_list(value) do
    value
    |> Enum.map(&operation_name/1)
    |> Enum.filter(&(&1 in @operations))
    |> Enum.uniq()
  end

  defp operation_list(_value), do: []

  defp operation_name(value) when is_atom(value), do: Atom.to_string(value)

  defp operation_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp operation_name(value), do: to_string(value)

  defp projects_from_input(%{projects: projects}) when is_list(projects), do: projects
  defp projects_from_input(%{"projects" => projects}) when is_list(projects), do: projects
  defp projects_from_input(project), do: [project]

  defp map_value(map, key) do
    case value(map, key) do
      value when is_map(value) -> value
      _value -> nil
    end
  end

  defp get_in_map(map, path) do
    Enum.reduce_while(path, map, fn key, acc ->
      case value(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

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

  defp required_string(map, key), do: optional_string(map, key) || ""
  defp optional_string(map, key), do: map |> value(key) |> optional_string()
  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(value) when is_map(value) or is_list(value), do: nil
  defp optional_string(value), do: to_string(value)

  defp blank?(value), do: optional_string(value) in [nil, ""]
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp truthy?(value) when value in [true, "true", "1", 1, true, "active", :active, "enabled", :enabled], do: true
  defp truthy?(_value), do: false

  defp status_value(map, key) do
    map
    |> value(key)
    |> safe_status()
  end

  defp safe_status(nil), do: nil

  defp safe_status(value) do
    value
    |> optional_string()
    |> case do
      nil -> nil
      status -> status |> String.downcase() |> String.replace("-", "_")
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

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(%DateTime{} = value), do: value

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp normalize_datetime(_value), do: nil

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp iso8601(value) when is_binary(value) do
    value
    |> normalize_datetime()
    |> case do
      nil -> optional_string(value)
      datetime -> DateTime.to_iso8601(datetime)
    end
  end

  defp iso8601(_value), do: nil

  defp privacy_diagnostics(value) do
    value
    |> SafeSummary.collect_sensitive_paths()
    |> Enum.map(fn {path, reason} ->
      %{
        level: :error,
        code: :sensitive_activation_preflight_snapshot_field,
        message: "Activation preflight snapshot contains sensitive #{reason} at #{Enum.join(path, ".")}"
      }
    end)
  end
end
