defmodule Mix.Tasks.Workflow.SplitTrackerConfig do
  use Mix.Task

  alias SymphonyElixir.TrackerConfig
  alias SymphonyElixir.Workflow.Definition

  @shortdoc "Split legacy WORKFLOW.md tracker/runtime config into TRACKER.yaml"

  @moduledoc """
  Splits legacy single-file `WORKFLOW.md` front matter into provider-neutral
  `WORKFLOW.md` and provider/runtime `TRACKER.yaml`.

  Usage:

      mix workflow.split_tracker_config --workflow /path/to/WORKFLOW.md
      mix workflow.split_tracker_config --workflow /path/to/WORKFLOW.md --workflow-out /path/to/WORKFLOW.md --tracker-out /path/to/TRACKER.yaml --force
  """

  @tracker_top_level_keys ["tracker"]
  @runtime_top_level_keys ["polling", "server", "workspace", "hooks", "agent", "codex", "worker", "observability"]
  @workflow_top_level_keys ["workflow", "start_stage", "terminal_stages", "outcomes", "missing_outcome", "stages"]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [workflow: :string, workflow_out: :string, tracker_out: :string, force: :boolean, help: :boolean],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        workflow_path = required_opt(opts, :workflow)
        workflow_out = opts[:workflow_out] || default_workflow_out(workflow_path)
        tracker_out = opts[:tracker_out] || default_tracker_out(workflow_path)
        force? = opts[:force] == true

        with {:ok, content} <- read_file(workflow_path),
             {:ok, front_matter, body} <- parse_workflow(content),
             {:ok, workflow_config, tracker_config} <- split_config(front_matter, body),
             :ok <- ensure_output_available(workflow_out, force?),
             :ok <- ensure_output_available(tracker_out, force?) do
          File.write!(workflow_out, workflow_document(workflow_config))
          File.write!(tracker_out, yaml_document(tracker_config))

          Mix.shell().info("Wrote provider-neutral workflow: #{workflow_out}")
          Mix.shell().info("Wrote tracker/runtime config: #{tracker_out}")
        else
          {:error, message} -> Mix.raise(message)
        end
    end
  end

  defp required_opt(opts, key) do
    case opts[key] do
      nil -> Mix.raise("Missing required option --#{String.replace(to_string(key), "_", "-")}")
      value -> value
    end
  end

  defp default_workflow_out(workflow_path), do: workflow_path <> ".migrated"

  defp default_tracker_out(workflow_path) do
    workflow_path
    |> Path.dirname()
    |> Path.join("TRACKER.yaml")
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Unable to read #{path}: #{inspect(reason)}"}
    end
  end

  defp parse_workflow(content) do
    {front_matter_lines, body_lines} = split_front_matter(content)
    yaml = Enum.join(front_matter_lines, "\n")
    body = Enum.join(body_lines, "\n") |> String.trim()

    if String.trim(yaml) == "" do
      {:ok, %{}, body}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) ->
          {:ok, normalize_keys(decoded), body}

        {:ok, _decoded} ->
          {:error, "WORKFLOW.md front matter must decode to a map"}

        {:error, reason} ->
          {:error, "Failed to parse WORKFLOW.md front matter: #{inspect(reason)}"}
      end
    end
  end

  defp split_front_matter(content) do
    lines = String.split(content, ["\r\n", "\n", "\r"], trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | body_lines] -> {front, body_lines}
          _missing_close -> {front, []}
        end

      _no_front_matter ->
        {[], lines}
    end
  end

  defp split_config(front_matter, body) do
    workflow_config = workflow_config_from(front_matter, body)

    case Definition.parse_config(workflow_config) do
      {:ok, workflow_definition} ->
        workflow_map = Definition.to_map(workflow_definition)
        tracker_config = tracker_config_from(front_matter, workflow_map)

        {:ok, %{"workflow" => workflow_map}, tracker_config}

      {:error, {:invalid_workflow_definition, message}} ->
        {:error, "Cannot split WORKFLOW.md without a valid workflow-stage definition: #{message}"}
    end
  end

  defp workflow_config_from(front_matter, body) do
    if workflow_stage_config?(front_matter) do
      Map.take(front_matter, @workflow_top_level_keys)
    else
      %{"workflow" => default_workflow(body)}
    end
  end

  defp workflow_stage_config?(front_matter) do
    Enum.any?(@workflow_top_level_keys, &Map.has_key?(front_matter, &1))
  end

  defp default_workflow(body) do
    implementation_prompt =
      case String.trim(body) do
        "" -> "Implement and validate the accepted scope for the current issue."
        prompt -> prompt
      end

    %{
      "start_stage" => "ready",
      "terminal_stages" => ["done", "blocked", "protocol_blocked"],
      "outcomes" => ["started", "needs_review", "approved", "changes_requested", "merged", "blocked"],
      "missing_outcome" => %{"max_retries" => 3, "on_exhausted" => "protocol_blocked"},
      "stages" => %{
        "ready" => %{
          "prompt" => "Read the issue, create or update the persistent workpad, record the plan, acceptance criteria, and validation approach, then begin implementation.",
          "transitions" => %{"started" => "in_progress", "blocked" => "blocked"}
        },
        "in_progress" => %{
          "prompt" => implementation_prompt,
          "transitions" => %{"needs_review" => "human_review", "blocked" => "blocked"}
        },
        "human_review" => %{
          "prompt" => "Prepare the completed work for review. Ensure validation, commit, PR, and workpad records are current.",
          "transitions" => %{"approved" => "merging", "changes_requested" => "rework", "blocked" => "blocked"}
        },
        "rework" => %{
          "prompt" => "Address review feedback, update code, tests, and docs, rerun validation, and return to review.",
          "transitions" => %{"needs_review" => "human_review", "blocked" => "blocked"}
        },
        "merging" => %{
          "prompt" => "Land the approved pull request and record the final result.",
          "transitions" => %{"merged" => "done", "blocked" => "blocked"}
        },
        "done" => %{"prompt" => "Terminal completion stage.", "transitions" => %{}},
        "blocked" => %{"prompt" => "Terminal blocked stage.", "transitions" => %{}},
        "protocol_blocked" => %{"prompt" => "Terminal protocol blocked stage.", "transitions" => %{}}
      }
    }
  end

  defp tracker_config_from(front_matter, workflow_map) do
    tracker_config =
      front_matter
      |> Map.take(@tracker_top_level_keys ++ @runtime_top_level_keys)
      |> drop_empty_maps()

    case Map.get(tracker_config, "tracker") do
      tracker when is_map(tracker) ->
        tracker =
          tracker
          |> ensure_stage_states(workflow_map)
          |> maybe_copy_project_status_field()
          |> Map.drop(["active_states", "terminal_states"])

        tracker_config
        |> Map.put("tracker", tracker)
        |> TrackerConfig.normalize_for_settings(workflow_map)
        |> drop_derived_legacy_states()

      _other ->
        tracker_config
    end
  end

  defp ensure_stage_states(tracker, workflow_map) do
    cond do
      is_map(Map.get(tracker, "stage_states")) and map_size(Map.get(tracker, "stage_states")) > 0 ->
        tracker

      is_map(get_in(tracker, ["workflow_state", "state_options"])) ->
        tracker

      true ->
        Map.put(tracker, "stage_states", derived_stage_states(tracker, workflow_map))
    end
  end

  defp derived_stage_states(tracker, workflow_map) do
    terminal_stage_names = Map.get(workflow_map, "terminal_stages", [])
    stage_names = workflow_map |> Map.get("stages", %{}) |> Map.keys() |> Enum.sort()
    active_states = state_list(Map.get(tracker, "active_states"), ["Ready", "In Progress", "Human Review", "Rework", "Merging"])
    terminal_states = state_list(Map.get(tracker, "terminal_states"), ["Done", "Blocked", "Protocol Blocked"])

    {active_stage_names, terminal_stage_names} =
      Enum.split_with(stage_names, fn stage_name -> stage_name not in terminal_stage_names end)

    active_mappings =
      active_stage_names
      |> order_active_stages()
      |> Enum.with_index()
      |> Enum.map(fn {stage_name, index} -> {stage_name, %{"state" => Enum.at(active_states, index) || titleize_stage(stage_name)}} end)

    terminal_mappings =
      terminal_stage_names
      |> order_terminal_stages()
      |> Enum.with_index()
      |> Enum.map(fn {stage_name, index} ->
        {stage_name, %{"state" => Enum.at(terminal_states, index) || titleize_stage(stage_name), "terminal" => true}}
      end)

    Map.new(active_mappings ++ terminal_mappings)
  end

  defp state_list(values, fallback) when is_list(values) do
    values
    |> Enum.map(&string_value/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> fallback
      states -> states
    end
  end

  defp state_list(_values, fallback), do: fallback

  defp order_active_stages(stage_names) do
    preferred = ["ready", "in_progress", "human_review", "rework", "merging"]
    preferred_order(stage_names, preferred)
  end

  defp order_terminal_stages(stage_names) do
    preferred = ["done", "blocked", "protocol_blocked"]
    preferred_order(stage_names, preferred)
  end

  defp preferred_order(stage_names, preferred) do
    preferred_present = Enum.filter(preferred, &(&1 in stage_names))
    preferred_present ++ Enum.reject(stage_names, &(&1 in preferred_present))
  end

  defp titleize_stage(stage_name) do
    stage_name
    |> to_string()
    |> String.split("_", trim: true)
    |> Enum.map_join(" ", fn token ->
      token
      |> String.downcase()
      |> String.capitalize()
    end)
  end

  defp string_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_value(value) when is_integer(value), do: value |> Integer.to_string() |> string_value()
  defp string_value(nil), do: nil

  defp maybe_copy_project_status_field(tracker) do
    case {Map.get(tracker, "project_status_field_name"), get_in(tracker, ["workflow_state", "field_name"])} do
      {field_name, nil} when is_binary(field_name) and field_name != "" ->
        workflow_state = tracker |> Map.get("workflow_state", %{}) |> Map.put("field_name", field_name)
        Map.put(tracker, "workflow_state", workflow_state)

      _other ->
        tracker
    end
  end

  defp drop_derived_legacy_states(config) do
    Map.update!(config, "tracker", &Map.drop(&1, ["active_states", "terminal_states"]))
  end

  defp ensure_output_available(path, true = _force?), do: ensure_parent_dir(path)

  defp ensure_output_available(path, false = _force?) do
    if File.exists?(path) do
      {:error, "Refusing to overwrite #{path}; pass --force to replace it"}
    else
      ensure_parent_dir(path)
    end
  end

  defp ensure_parent_dir(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, "Unable to create output directory for #{path}: #{inspect(reason)}"}
    end
  end

  defp workflow_document(workflow_config), do: yaml_front_matter(workflow_config)

  defp yaml_front_matter(config), do: "---\n" <> yaml_document(config) <> "---\n"

  defp yaml_document(config), do: yaml_lines(config, 0) |> Enum.join("\n") |> Kernel.<>("\n")

  defp yaml_lines(map, indent) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key_order(key) end)
    |> Enum.flat_map(fn {key, value} -> yaml_key_value_lines(to_string(key), value, indent) end)
  end

  defp yaml_key_value_lines(key, value, indent) when is_map(value) do
    [indent(indent) <> key <> ":" | yaml_lines(value, indent + 2)]
  end

  defp yaml_key_value_lines(key, value, indent) when is_list(value) do
    case value do
      [] -> [indent(indent) <> key <> ": []"]
      _ -> [indent(indent) <> key <> ":" | yaml_list_lines(value, indent + 2)]
    end
  end

  defp yaml_key_value_lines(key, value, indent) when is_binary(value) do
    if String.contains?(value, "\n") do
      [indent(indent) <> key <> ": |" | block_string_lines(value, indent + 2)]
    else
      [indent(indent) <> key <> ": " <> scalar(value)]
    end
  end

  defp yaml_key_value_lines(key, value, indent) do
    [indent(indent) <> key <> ": " <> scalar(value)]
  end

  defp yaml_list_lines(values, indent) do
    Enum.flat_map(values, fn
      value when is_map(value) ->
        [indent(indent) <> "-" | yaml_lines(value, indent + 2)]

      value ->
        [indent(indent) <> "- " <> scalar(value)]
    end)
  end

  defp scalar(true), do: "true"
  defp scalar(false), do: "false"
  defp scalar(nil), do: "null"
  defp scalar(value) when is_integer(value), do: Integer.to_string(value)

  defp scalar(value) when is_binary(value) do
    cond do
      value == "" ->
        ~s("")

      safe_plain_scalar?(value) ->
        value

      true ->
        inspect(value)
    end
  end

  defp scalar(value), do: inspect(value)

  defp block_string_lines(value, indent) do
    value
    |> String.split("\n", trim: false)
    |> Enum.map(&(indent(indent) <> &1))
  end

  defp safe_plain_scalar?(value) do
    not String.starts_with?(value, [" ", "-", "{", "}", "[", "]", "#", "&", "*", "!", "|", ">", "@", "`", "\"", "'"]) and
      not String.ends_with?(value, " ") and
      not String.contains?(value, [": ", " #", "\t"]) and
      value not in ["true", "false", "null", "~"]
  end

  defp indent(count), do: String.duplicate(" ", count)

  defp key_order("workflow"), do: {0, "workflow"}
  defp key_order("tracker"), do: {1, "tracker"}
  defp key_order("polling"), do: {2, "polling"}
  defp key_order("server"), do: {3, "server"}
  defp key_order("workspace"), do: {4, "workspace"}
  defp key_order("hooks"), do: {5, "hooks"}
  defp key_order("agent"), do: {6, "agent"}
  defp key_order("codex"), do: {7, "codex"}
  defp key_order("worker"), do: {8, "worker"}
  defp key_order("observability"), do: {9, "observability"}
  defp key_order(key), do: {99, key}

  defp drop_empty_maps(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      value = if is_map(value), do: drop_empty_maps(value), else: value

      if value == %{} do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value), do: to_string(value)
end
