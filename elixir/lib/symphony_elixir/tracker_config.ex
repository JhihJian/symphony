defmodule SymphonyElixir.TrackerConfig do
  @moduledoc """
  Loads provider-specific tracker configuration from TRACKER.yaml.
  """

  @tracker_file_name "TRACKER.yaml"
  @legacy_tracker_keys MapSet.new([
                         "kind",
                         "endpoint",
                         "api_key",
                         "project_slug",
                         "owner",
                         "repo",
                         "project_number",
                         "project_status_field_name",
                         "assignee",
                         "required_labels",
                         "state_label_prefix",
                         "provider_states",
                         "active_states",
                         "terminal_states",
                         "stage_states"
                       ])

  @spec tracker_file_path() :: Path.t() | nil
  def tracker_file_path do
    Application.get_env(:symphony_elixir, :tracker_config_file_path)
  end

  @spec default_tracker_file_path(Path.t()) :: Path.t()
  def default_tracker_file_path(workflow_path) when is_binary(workflow_path) do
    Path.join(Path.dirname(Path.expand(workflow_path)), @tracker_file_name)
  end

  @spec set_tracker_file_path(Path.t() | nil) :: :ok
  def set_tracker_file_path(nil) do
    clear_tracker_file_path()
  end

  def set_tracker_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :tracker_config_file_path, path)
    :ok
  end

  @spec clear_tracker_file_path() :: :ok
  def clear_tracker_file_path do
    Application.delete_env(:symphony_elixir, :tracker_config_file_path)
    :ok
  end

  @spec load() :: {:ok, map()} | {:error, term()}
  def load do
    case tracker_file_path() do
      path when is_binary(path) -> load(path)
      nil -> {:error, :tracker_config_path_not_set}
    end
  end

  @spec load(Path.t()) :: {:ok, map()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse(content)

      {:error, reason} ->
        {:error, {:missing_tracker_config_file, path, reason}}
    end
  end

  @spec parse(String.t()) :: {:ok, map()} | {:error, term()}
  def parse(content) when is_binary(content) do
    if String.trim(content) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(content) do
        {:ok, decoded} when is_map(decoded) -> {:ok, normalize_keys(decoded)}
        {:ok, _decoded} -> {:error, :tracker_config_not_a_map}
        {:error, reason} -> {:error, {:tracker_config_parse_error, reason}}
      end
    end
  end

  @spec legacy_tracker_config_error(map()) :: nil | {:legacy_workflow_tracker_config, [String.t()]}
  def legacy_tracker_config_error(config) when is_map(config) do
    config = normalize_keys(config)

    legacy_keys =
      case Map.get(config, "tracker") do
        tracker when is_map(tracker) ->
          tracker
          |> Map.keys()
          |> Enum.filter(&MapSet.member?(@legacy_tracker_keys, &1))
          |> Enum.map(&"tracker.#{&1}")

        _other ->
          []
      end

    case legacy_keys do
      [] -> nil
      keys -> {:legacy_workflow_tracker_config, Enum.sort(keys)}
    end
  end

  @spec normalize_for_settings(map(), map() | nil) :: map()
  def normalize_for_settings(config, workflow_definition \\ nil) when is_map(config) do
    config = normalize_keys(config)
    tracker_config = Map.get(config, "tracker", config)

    tracker =
      tracker_config
      |> maybe_apply_stage_state_compatibility(Map.get(tracker_config, "stage_states"), workflow_definition)

    Map.put(config, "tracker", tracker)
  end

  @spec stage_states(map()) :: map()
  def stage_states(config) when is_map(config) do
    config
    |> normalize_keys()
    |> then(&Map.get(&1, "tracker", &1))
    |> Map.get("stage_states", %{})
    |> normalize_stage_states()
  end

  @spec validate_stage_states(map(), map()) :: :ok | {:error, {:invalid_tracker_config, String.t()}}
  def validate_stage_states(workflow_definition, tracker_config) when is_map(workflow_definition) and is_map(tracker_config) do
    stage_states = stage_states(tracker_config)
    stage_names = workflow_definition |> Map.get("stages", %{}) |> Map.keys()

    unknown_stage_names =
      stage_states
      |> Map.keys()
      |> Enum.reject(&(&1 in stage_names))
      |> Enum.sort()

    missing_stage_names =
      Enum.filter(stage_names, fn stage_name ->
        not match?(%{"state" => state} when is_binary(state), Map.get(stage_states, stage_name))
      end)

    blank_state_names =
      stage_states
      |> Enum.filter(fn {_stage_name, config} -> not match?(%{"state" => state} when is_binary(state), config) end)
      |> Enum.map(fn {stage_name, _config} -> stage_name end)
      |> Enum.sort()

    cond do
      unknown_stage_names != [] ->
        {:error, {:invalid_tracker_config, "TRACKER.yaml tracker.stage_states contains unknown workflow stage keys: #{Enum.join(unknown_stage_names, ", ")}"}}

      blank_state_names != [] ->
        {:error, {:invalid_tracker_config, "TRACKER.yaml tracker.stage_states must map every workflow stage to a provider-visible state; blank state for #{Enum.join(blank_state_names, ", ")}"}}

      missing_stage_names == [] ->
        :ok

      true ->
        {:error, {:invalid_tracker_config, "TRACKER.yaml tracker.stage_states must map every workflow stage to a provider-visible state; missing #{Enum.join(missing_stage_names, ", ")}"}}
    end
  end

  defp maybe_apply_stage_state_compatibility(tracker, stage_states, workflow_definition) do
    stage_states = normalize_stage_states(stage_states)
    terminal_stage_names = terminal_stage_names(workflow_definition)
    stage_order = ordered_stage_names(workflow_definition, stage_states)

    tracker
    |> Map.put("stage_states", stage_states)
    |> Map.put("active_states", active_provider_states(stage_states, terminal_stage_names, stage_order))
    |> Map.put("terminal_states", terminal_provider_states(stage_states, terminal_stage_names, stage_order))
  end

  defp active_provider_states(stage_states, terminal_stage_names, stage_order) do
    stage_order
    |> Enum.map(&{&1, Map.get(stage_states, &1)})
    |> Enum.reject(fn
      {_stage, nil} -> true
      {stage, config} -> terminal_stage?(stage, config, terminal_stage_names)
    end)
    |> Enum.map(fn {_stage, config} -> Map.get(config, "state") end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp terminal_provider_states(stage_states, terminal_stage_names, stage_order) do
    stage_order
    |> Enum.map(&{&1, Map.get(stage_states, &1)})
    |> Enum.reject(fn {_stage, config} -> is_nil(config) end)
    |> Enum.filter(fn {stage, config} -> terminal_stage?(stage, config, terminal_stage_names) end)
    |> Enum.map(fn {_stage, config} -> Map.get(config, "state") end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp terminal_stage?(stage, config, terminal_stage_names) do
    stage in terminal_stage_names or Map.get(config, "terminal", false)
  end

  defp terminal_stage_names(%{"terminal_stages" => stages}) when is_list(stages) do
    stages
    |> Enum.map(&normalize_optional_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp terminal_stage_names(_workflow_definition), do: []

  defp ordered_stage_names(%{"start_stage" => start_stage, "outcomes" => outcomes, "stages" => stages}, stage_states)
       when is_binary(start_stage) and is_list(outcomes) and is_map(stages) do
    stage_names = Map.keys(stages)

    initial_queue =
      if start_stage in stage_names do
        [start_stage]
      else
        []
      end

    {ordered, visited} = walk_stage_graph(initial_queue, [], [], stages, outcomes, stage_names)

    remaining =
      stage_states
      |> Map.keys()
      |> Enum.reject(&(&1 in visited))
      |> Enum.sort()

    ordered ++ remaining
  end

  defp ordered_stage_names(_workflow_definition, stage_states) do
    stage_states |> Map.keys() |> Enum.sort()
  end

  defp walk_stage_graph([], visited, ordered, _stages, _outcomes, _stage_names) do
    {Enum.reverse(ordered), visited}
  end

  defp walk_stage_graph([stage | rest], visited, ordered, stages, outcomes, stage_names) do
    if stage in visited do
      walk_stage_graph(rest, visited, ordered, stages, outcomes, stage_names)
    else
      visited = [stage | visited]
      transitions = stages |> Map.get(stage, %{}) |> Map.get("transitions", %{})

      ordered_targets =
        outcomes
        |> Enum.map(&Map.get(transitions, &1))
        |> Enum.reject(&is_nil/1)

      unordered_targets =
        transitions
        |> Map.values()
        |> Enum.reject(&(&1 in ordered_targets))
        |> Enum.sort()

      targets =
        (ordered_targets ++ unordered_targets)
        |> Enum.filter(&(&1 in stage_names))
        |> Enum.reject(&(&1 in visited))

      walk_stage_graph(rest ++ targets, visited, [stage | ordered], stages, outcomes, stage_names)
    end
  end

  defp normalize_stage_states(stage_states) when is_map(stage_states) do
    Enum.reduce(stage_states, %{}, fn {stage, raw_config}, acc ->
      stage_name = stage |> to_string() |> String.trim()

      if stage_name == "" do
        acc
      else
        Map.put(acc, stage_name, normalize_stage_state(raw_config))
      end
    end)
  end

  defp normalize_stage_states(_stage_states), do: %{}

  defp normalize_stage_state(raw_config) when is_map(raw_config) do
    raw_config = normalize_keys(raw_config)

    %{
      "state" => raw_config |> Map.get("state") |> normalize_optional_string(),
      "terminal" => Map.get(raw_config, "terminal", false) == true
    }
  end

  defp normalize_stage_state(raw_state) do
    %{"state" => normalize_optional_string(raw_state), "terminal" => false}
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
