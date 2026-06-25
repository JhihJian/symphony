defmodule SymphonyElixir.TrackerConfig do
  @moduledoc """
  Loads provider-specific tracker configuration from TRACKER.yaml.
  """

  @tracker_file_name "TRACKER.yaml"
  @legacy_workflow_tracker_keys MapSet.new([
                                  "tracker",
                                  "active_states",
                                  "terminal_states"
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
    maybe_reload_store()
    :ok
  end

  @spec clear_tracker_file_path() :: :ok
  def clear_tracker_file_path do
    Application.delete_env(:symphony_elixir, :tracker_config_file_path)
    maybe_reload_store()
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
      config
      |> Map.keys()
      |> Enum.filter(&MapSet.member?(@legacy_workflow_tracker_keys, &1))
      |> Enum.flat_map(&legacy_workflow_key_paths(&1, Map.get(config, &1)))

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
      |> maybe_apply_workflow_state_defaults()
      |> maybe_apply_stage_state_compatibility(workflow_definition)

    Map.put(config, "tracker", tracker)
  end

  @spec stage_states(map()) :: map()
  def stage_states(config), do: stage_states(config, nil)

  @spec stage_states(map(), map() | nil) :: map()
  def stage_states(config, workflow_definition) when is_map(config) do
    config
    |> normalize_keys()
    |> then(&Map.get(&1, "tracker", &1))
    |> stage_states_for_tracker(workflow_definition)
  end

  @spec validate_stage_states(map(), map()) :: :ok | {:error, {:invalid_tracker_config, String.t()}}
  def validate_stage_states(workflow_definition, tracker_config) when is_map(workflow_definition) and is_map(tracker_config) do
    stage_states = stage_states(tracker_config, workflow_definition)
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
        {:error, {:invalid_tracker_config, "TRACKER.yaml tracker.stage_states/workflow_state contains unknown workflow stage keys: #{Enum.join(unknown_stage_names, ", ")}"}}

      blank_state_names != [] ->
        {:error,
         {:invalid_tracker_config, "TRACKER.yaml tracker.stage_states/workflow_state must map every workflow stage to a provider-visible state; blank state for #{Enum.join(blank_state_names, ", ")}"}}

      missing_stage_names == [] ->
        :ok

      true ->
        {:error,
         {:invalid_tracker_config, "TRACKER.yaml tracker.stage_states/workflow_state must map every workflow stage to a provider-visible state; missing #{Enum.join(missing_stage_names, ", ")}"}}
    end
  end

  defp maybe_apply_workflow_state_defaults(tracker) do
    workflow_state = workflow_state_config(tracker)

    tracker
    |> maybe_put_from_workflow_state("project_status_field_name", workflow_state, "field_name")
    |> maybe_put_from_workflow_state("state_label_prefix", workflow_state, "label_prefix")
  end

  defp maybe_put_from_workflow_state(tracker, tracker_key, workflow_state, workflow_state_key) do
    case {Map.get(tracker, tracker_key), Map.get(workflow_state, workflow_state_key)} do
      {nil, value} when is_binary(value) and value != "" -> Map.put(tracker, tracker_key, value)
      _ -> tracker
    end
  end

  defp maybe_apply_stage_state_compatibility(tracker, workflow_definition) do
    stage_states = stage_states_for_tracker(tracker, workflow_definition)

    tracker
    |> Map.put("stage_states", stage_states)
  end

  defp stage_states_for_tracker(tracker, workflow_definition) do
    case normalize_stage_states(Map.get(tracker, "stage_states")) do
      stage_states when map_size(stage_states) > 0 ->
        stage_states

      _empty ->
        stage_states_from_workflow_state(tracker, workflow_definition)
    end
  end

  defp stage_states_from_workflow_state(tracker, workflow_definition) do
    workflow_state = workflow_state_config(tracker)

    cond do
      is_map(Map.get(workflow_state, "state_options")) ->
        workflow_state
        |> Map.get("state_options")
        |> normalize_stage_states()

      Map.get(workflow_state, "strategy") == "scoped_label" ->
        scoped_label_stage_states(workflow_state, workflow_definition)

      true ->
        %{}
    end
  end

  defp scoped_label_stage_states(workflow_state, workflow_definition) do
    prefix = workflow_state |> Map.get("label_prefix") |> normalize_optional_string()
    format = Map.get(workflow_state, "state_name_format", "kebab_case")

    workflow_definition
    |> workflow_stage_names()
    |> Enum.reduce(%{}, fn stage_name, acc ->
      case scoped_label_for_stage(stage_name, prefix, format) do
        nil -> acc
        label -> Map.put(acc, stage_name, %{"state" => label, "terminal" => false})
      end
    end)
  end

  defp scoped_label_for_stage(_stage_name, nil, _format), do: nil

  defp scoped_label_for_stage(stage_name, prefix, format) when is_binary(stage_name) do
    prefix <> format_stage_name(stage_name, format)
  end

  defp workflow_stage_names(%{"stages" => stages}) when is_map(stages) do
    stages
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp workflow_stage_names(_workflow_definition), do: []

  defp format_stage_name(stage_name, "snake_case") do
    stage_name
    |> normalize_stage_token()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp format_stage_name(stage_name, "raw"), do: stage_name

  defp format_stage_name(stage_name, _format) do
    stage_name
    |> normalize_stage_token()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp normalize_stage_token(stage_name) do
    stage_name
    |> String.trim()
    |> String.downcase()
  end

  defp workflow_state_config(tracker) when is_map(tracker) do
    case Map.get(tracker, "workflow_state") do
      workflow_state when is_map(workflow_state) -> normalize_keys(workflow_state)
      _other -> %{}
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

  defp legacy_workflow_key_paths("tracker", tracker) when is_map(tracker) do
    tracker
    |> Map.keys()
    |> Enum.map(&"tracker.#{&1}")
  end

  defp legacy_workflow_key_paths(key, _value), do: [key]

  defp maybe_reload_store do
    if Process.whereis(SymphonyElixir.WorkflowStore) do
      _ = SymphonyElixir.WorkflowStore.force_reload()
    end

    :ok
  end
end
