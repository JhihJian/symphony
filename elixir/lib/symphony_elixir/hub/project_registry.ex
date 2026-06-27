defmodule SymphonyElixir.Hub.ProjectRegistry do
  @moduledoc """
  Loads Hub mode project registrations into safe identity/configuration snapshots.

  This module is intentionally model-only. It does not start poll loops or dispatch
  agents; legacy single-project orchestration continues to use `SymphonyElixir.Config`.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Hub.ProviderScope
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.TrackerConfig
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workflow.Definition

  @hub_config_file_name "HUB.yaml"
  @project_id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

  @type project_ref :: %{
          required(:project_id) => String.t(),
          optional(:name) => String.t() | nil,
          required(:workflow_path) => Path.t(),
          required(:tracker_config_path) => Path.t(),
          required(:dispatch_enabled) => boolean()
        }

  @type workflow_summary :: %{
          required(:start_stage) => String.t() | nil,
          required(:terminal_stages) => [String.t()],
          required(:stage_ids) => [String.t()]
        }

  @type tracker_summary :: %{
          required(:kind) => String.t() | nil,
          required(:provider_scope) => map() | nil,
          required(:provider_scope_key) => String.t() | nil,
          required(:required_labels) => [String.t()]
        }

  @type runtime_summary :: %{
          required(:workspace_root) => String.t() | nil,
          required(:max_concurrent_agents) => pos_integer() | nil,
          required(:max_concurrent_agents_by_state) => map(),
          required(:polling_interval_ms) => pos_integer() | nil,
          required(:server_port) => non_neg_integer() | nil
        }

  @type snapshot :: %{
          required(:project_id) => String.t(),
          required(:name) => String.t() | nil,
          required(:dispatch_enabled) => boolean(),
          required(:paused) => boolean(),
          required(:status) => :ready | :paused | :error,
          required(:workflow_path) => String.t() | nil,
          required(:tracker_config_path) => String.t() | nil,
          required(:workflow_summary) => workflow_summary() | nil,
          required(:tracker_summary) => tracker_summary() | nil,
          required(:runtime_summary) => runtime_summary() | nil,
          required(:fingerprint) => String.t() | nil,
          required(:loaded_at) => DateTime.t(),
          required(:load_error) => String.t() | nil
        }

  @type validation_message :: %{
          required(:level) => :warning | :error,
          required(:code) => atom(),
          required(:project_ids) => [String.t()],
          required(:message) => String.t()
        }

  @type registry :: %{
          required(:projects) => [snapshot()],
          required(:warnings) => [validation_message()],
          required(:errors) => [validation_message()]
        }

  @spec default_config_path() :: Path.t()
  def default_config_path do
    Path.join(File.cwd!(), @hub_config_file_name)
  end

  @spec load() :: {:ok, registry()} | {:error, term()}
  def load, do: load(default_config_path())

  @spec load(Path.t()) :: {:ok, registry()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, config} <- load_config(path),
         {:ok, project_refs} <- parse_project_refs(config, path) do
      {:ok, load_project_refs(project_refs)}
    end
  end

  @spec parse(String.t(), Path.t()) :: {:ok, registry()} | {:error, term()}
  def parse(content, base_path \\ default_config_path()) when is_binary(content) and is_binary(base_path) do
    with {:ok, config} <- parse_config(content),
         {:ok, project_refs} <- parse_project_refs(config, base_path) do
      {:ok, load_project_refs(project_refs)}
    end
  end

  @spec validate_project_id(term()) :: :ok | {:error, term()}
  def validate_project_id(project_id) when is_binary(project_id) do
    cond do
      String.trim(project_id) != project_id or project_id == "" ->
        {:error, {:invalid_project_id, project_id, "project_id must not be blank or padded"}}

      String.contains?(project_id, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_project_id, project_id, "project_id must not contain newline or NUL"}}

      String.contains?(project_id, ["..", "/", "\\"]) ->
        {:error, {:invalid_project_id, project_id, "project_id must not contain path separators or traversal"}}

      not Regex.match?(@project_id_pattern, project_id) ->
        {:error, {:invalid_project_id, project_id, "project_id may contain only letters, numbers, dot, underscore, or dash, and must start with a letter or number"}}

      true ->
        :ok
    end
  end

  def validate_project_id(project_id) do
    {:error, {:invalid_project_id, project_id, "project_id must be a string"}}
  end

  defp load_config(path) do
    case File.read(path) do
      {:ok, content} ->
        parse_config(content)

      {:error, reason} ->
        {:error, {:missing_hub_config_file, path, reason}}
    end
  end

  defp parse_config(content) do
    if String.trim(content) == "" do
      {:error, :hub_config_empty}
    else
      case YamlElixir.read_from_string(content) do
        {:ok, decoded} when is_map(decoded) -> {:ok, normalize_keys(decoded)}
        {:ok, _decoded} -> {:error, :hub_config_not_a_map}
        {:error, reason} -> {:error, {:hub_config_parse_error, reason}}
      end
    end
  end

  defp parse_project_refs(config, config_path) when is_map(config) do
    case Map.get(config, "projects") do
      projects when is_list(projects) ->
        projects
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {project, index}, {:ok, acc} ->
          case parse_project_ref(project, index, config_path) do
            {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> then(fn
          {:ok, parsed} -> validate_unique_project_ids(Enum.reverse(parsed))
          {:error, reason} -> {:error, reason}
        end)

      _projects ->
        {:error, :hub_projects_must_be_a_list}
    end
  end

  defp parse_project_ref(project, index, config_path) when is_map(project) do
    project = normalize_keys(project)
    project_id = project |> Map.get("project_id") |> normalize_optional_string()
    workflow_path = project |> Map.get("workflow_path") |> normalize_optional_string()
    tracker_config_path = project |> Map.get("tracker_config_path") |> normalize_optional_string()
    dispatch_enabled = dispatch_enabled?(project)

    with :ok <- validate_project_id(project_id),
         {:ok, expanded_workflow_path} <- require_project_path(project_id, workflow_path, "workflow_path", config_path),
         {:ok, expanded_tracker_config_path} <-
           optional_tracker_path(tracker_config_path, expanded_workflow_path, config_path) do
      {:ok,
       %{
         project_id: project_id,
         name: project |> Map.get("name") |> normalize_optional_string(),
         workflow_path: expanded_workflow_path,
         tracker_config_path: expanded_tracker_config_path,
         dispatch_enabled: dispatch_enabled,
         index: index
       }}
    end
  end

  defp parse_project_ref(_project, index, _config_path) do
    {:error, {:invalid_hub_project, index, "project entry must be a map"}}
  end

  defp validate_unique_project_ids(project_refs) do
    duplicates =
      project_refs
      |> Enum.group_by(& &1.project_id)
      |> Enum.filter(fn {_project_id, refs} -> length(refs) > 1 end)

    case duplicates do
      [] ->
        {:ok, project_refs}

      [{project_id, refs} | _rest] ->
        indexes = refs |> Enum.map(& &1.index) |> Enum.sort()
        {:error, {:duplicate_project_id, project_id, indexes}}
    end
  end

  defp load_project_refs(project_refs) do
    loaded_at = DateTime.utc_now()
    snapshots = Enum.map(project_refs, &load_project_ref(&1, loaded_at))
    {warnings, errors} = validate_resource_conflicts(snapshots)

    %{projects: snapshots, warnings: warnings, errors: errors}
  end

  defp load_project_ref(%{} = project_ref, %DateTime{} = loaded_at) do
    case build_loaded_snapshot(project_ref, loaded_at) do
      {:ok, snapshot} ->
        snapshot

      {:error, reason} ->
        error_snapshot(project_ref, loaded_at, reason)
    end
  end

  defp build_loaded_snapshot(project_ref, loaded_at) do
    with {:ok, %{config: workflow_config, workflow: %Definition{} = workflow_definition}} <-
           Workflow.load(project_ref.workflow_path),
         nil <- TrackerConfig.legacy_tracker_config_error(workflow_config),
         {:ok, tracker_config} <- TrackerConfig.load(project_ref.tracker_config_path),
         workflow_map <- Definition.to_map(workflow_definition),
         :ok <- Tracker.validate_workflow_state_mapping(workflow_map, tracker_config),
         {:ok, settings} <- parse_settings(workflow_config, workflow_map, tracker_config),
         {:ok, provider_scope} <- ProviderScope.from_tracker(project_ref.project_id, settings.tracker) do
      {:ok, loaded_snapshot(project_ref, loaded_at, workflow_definition, settings, provider_scope)}
    else
      {:legacy_workflow_tracker_config, _keys} = reason -> {:error, reason}
      {:ok, %{workflow: nil}} -> {:error, {:invalid_workflow_definition, "WORKFLOW.md must define provider-neutral workflow stages"}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_settings(workflow_config, workflow_map, tracker_config) do
    workflow_config
    |> Map.drop(["workflow", "start_stage", "terminal_stages", "outcomes", "missing_outcome", "stages"])
    |> Map.merge(TrackerConfig.normalize_for_settings(tracker_config, workflow_map))
    |> Map.put("workflow", workflow_map)
    |> Map.put("tracker_config", tracker_config)
    |> Schema.parse()
  end

  defp loaded_snapshot(project_ref, loaded_at, workflow_definition, %Schema{} = settings, provider_scope) do
    %{
      project_id: project_ref.project_id,
      name: project_ref.name,
      dispatch_enabled: project_ref.dispatch_enabled,
      paused: not project_ref.dispatch_enabled,
      status: if(project_ref.dispatch_enabled, do: :ready, else: :paused),
      workflow_path: project_ref.workflow_path,
      tracker_config_path: project_ref.tracker_config_path,
      workflow_summary: workflow_summary(workflow_definition),
      tracker_summary: tracker_summary(settings, provider_scope),
      runtime_summary: runtime_summary(settings),
      fingerprint: fingerprint(project_ref, workflow_definition, settings, provider_scope),
      loaded_at: loaded_at,
      load_error: nil
    }
  end

  defp error_snapshot(project_ref, loaded_at, reason) do
    %{
      project_id: project_ref.project_id,
      name: project_ref.name,
      dispatch_enabled: project_ref.dispatch_enabled,
      paused: true,
      status: :error,
      workflow_path: Map.get(project_ref, :workflow_path),
      tracker_config_path: Map.get(project_ref, :tracker_config_path),
      workflow_summary: nil,
      tracker_summary: nil,
      runtime_summary: nil,
      fingerprint: nil,
      loaded_at: loaded_at,
      load_error: format_load_error(reason)
    }
  end

  defp workflow_summary(%Definition{} = workflow_definition) do
    %{
      start_stage: workflow_definition.start_stage,
      terminal_stages: workflow_definition.terminal_stages,
      stage_ids: workflow_definition.stages |> Map.keys() |> Enum.sort()
    }
  end

  defp tracker_summary(%Schema{} = settings, provider_scope) do
    %{
      kind: settings.tracker.kind,
      provider_scope: provider_scope.scope,
      provider_scope_key: provider_scope.key,
      required_labels: settings.tracker.required_labels
    }
  end

  defp runtime_summary(%Schema{} = settings) do
    %{
      workspace_root: settings.workspace.root,
      max_concurrent_agents: settings.agent.max_concurrent_agents,
      max_concurrent_agents_by_state: settings.agent.max_concurrent_agents_by_state,
      polling_interval_ms: settings.polling.interval_ms,
      server_port: settings.server.port
    }
  end

  defp fingerprint(project_ref, workflow_definition, settings, provider_scope) do
    payload = %{
      project_id: project_ref.project_id,
      name: project_ref.name,
      dispatch_enabled: project_ref.dispatch_enabled,
      workflow_path: project_ref.workflow_path,
      tracker_config_path: project_ref.tracker_config_path,
      workflow_summary: workflow_summary(workflow_definition),
      tracker_summary: tracker_summary(settings, provider_scope),
      runtime_summary: runtime_summary(settings)
    }

    :crypto.hash(:sha256, :erlang.term_to_binary(payload))
    |> Base.encode16(case: :lower)
  end

  defp validate_resource_conflicts(snapshots) do
    loaded_snapshots = Enum.reject(snapshots, &(&1.status == :error))

    warnings =
      []
      |> Kernel.++(
        duplicate_runtime_warning(
          loaded_snapshots,
          [:runtime_summary, :workspace_root],
          :shared_workspace_root,
          "Projects share the same workspace root"
        )
      )
      |> Kernel.++(
        duplicate_runtime_warning(
          loaded_snapshots,
          [:tracker_summary, :provider_scope_key],
          :shared_provider_scope,
          "Projects share the same provider scope"
        )
      )

    errors =
      duplicate_runtime_error(
        loaded_snapshots,
        [:runtime_summary, :server_port],
        :shared_dashboard_port,
        "Projects share the same Dashboard/API port"
      )

    {warnings, errors}
  end

  defp duplicate_runtime_warning(snapshots, path, code, message) do
    duplicate_runtime_message(snapshots, path, code, message, :warning)
  end

  defp duplicate_runtime_error(snapshots, path, code, message) do
    duplicate_runtime_message(snapshots, path, code, message, :error)
  end

  defp duplicate_runtime_message(snapshots, path, code, message, level) do
    snapshots
    |> group_by_in(path)
    |> Enum.flat_map(fn
      {nil, _group} ->
        []

      {_value, [_single]} ->
        []

      {value, group} ->
        project_ids = group |> Enum.map(& &1.project_id) |> Enum.sort()

        [
          %{
            level: level,
            code: code,
            project_ids: project_ids,
            message: "#{message}: #{inspect(value)} (#{Enum.join(project_ids, ", ")})"
          }
        ]
    end)
  end

  defp group_by_in(snapshots, path) do
    Enum.group_by(snapshots, &get_in(&1, path))
  end

  defp dispatch_enabled?(project) do
    cond do
      Map.get(project, "paused") == true -> false
      Map.has_key?(project, "dispatch_enabled") -> Map.get(project, "dispatch_enabled") != false
      Map.has_key?(project, "enabled") -> Map.get(project, "enabled") != false
      true -> true
    end
  end

  defp format_load_error(:missing_tracker_kind), do: "Invalid TRACKER.yaml config: missing tracker.kind"
  defp format_load_error(:missing_github_owner), do: "Invalid TRACKER.yaml config: missing tracker.owner for GitHub"
  defp format_load_error(:missing_github_repo), do: "Invalid TRACKER.yaml config: missing tracker.repo for GitHub"
  defp format_load_error(:missing_gitlab_project_slug), do: "Invalid TRACKER.yaml config: missing tracker.project_slug for GitLab"
  defp format_load_error(:missing_linear_project_slug), do: "Invalid TRACKER.yaml config: missing tracker.project_slug for Linear"
  defp format_load_error({:unsupported_tracker_kind, kind}), do: "Invalid TRACKER.yaml config: unsupported tracker.kind #{inspect(kind)}"
  defp format_load_error(reason), do: Config.format_config_error(reason)

  defp optional_tracker_path(nil, workflow_path, _config_path) do
    {:ok, TrackerConfig.default_tracker_file_path(workflow_path)}
  end

  defp optional_tracker_path(path, _workflow_path, config_path) do
    {:ok, expand_path(path, config_path)}
  end

  defp require_project_path(project_id, nil, field, _config_path) do
    {:error, {:invalid_hub_project, project_id, "#{field} is required"}}
  end

  defp require_project_path(_project_id, path, _field, config_path), do: {:ok, expand_path(path, config_path)}

  defp expand_path(path, config_path) when is_binary(path) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      config_path
      |> Path.dirname()
      |> Path.join(path)
      |> Path.expand()
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)
end
