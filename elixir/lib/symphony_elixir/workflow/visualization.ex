defmodule SymphonyElixir.Workflow.Visualization do
  @moduledoc """
  Builds read-only workflow graph data for the operator dashboard.
  """

  alias SymphonyElixir.TrackerConfig
  alias SymphonyElixir.Workflow.Definition

  @sensitive_key_pattern ~r/(api[_-]?key|token|secret|password|credential)/i

  @type diagnostic :: %{
          severity: :error | :warning | :info,
          code: atom(),
          message: String.t()
        }

  @type projection :: %{
          workflow: map(),
          stages: [map()],
          transitions: [map()],
          missing_outcome: map(),
          diagnostics: [diagnostic()],
          tracker: map() | nil,
          runtime: map()
        }

  @spec project(Definition.t(), keyword()) :: projection()
  def project(%Definition{} = definition, opts \\ []) do
    tracker_config = Keyword.get(opts, :tracker_config)
    snapshot = Keyword.get(opts, :snapshot)
    workflow_map = Definition.to_map(definition)
    runtime = runtime_summary(definition, snapshot)
    tracker = tracker_summary(workflow_map, tracker_config)

    %{
      workflow: workflow_summary(definition),
      stages: stage_nodes(definition, runtime, tracker),
      transitions: transition_edges(definition),
      missing_outcome: missing_outcome_summary(definition),
      diagnostics: diagnostics(definition, tracker),
      tracker: tracker,
      runtime: runtime
    }
  end

  @spec error_projection(term()) :: map()
  def error_projection(reason) do
    %{
      error: %{
        code: error_code(reason),
        message: SymphonyElixir.Config.format_config_error(reason)
      },
      diagnostics: [
        %{
          severity: :error,
          code: :workflow_unavailable,
          message: SymphonyElixir.Config.format_config_error(reason)
        }
      ]
    }
  end

  @spec runtime_summary(Definition.t(), map() | :timeout | :unavailable | nil) :: map()
  def runtime_summary(%Definition{} = definition, %{} = snapshot) do
    stage_names = stage_names(definition)
    initial_counts = Map.new(stage_names, &{&1, empty_runtime_counts()})

    {counts_by_stage, unknown_entries} =
      snapshot_entries(snapshot)
      |> Enum.reduce({initial_counts, []}, fn entry, {counts, unknown} ->
        status = Map.fetch!(entry, :status)
        current_stage = Map.get(entry, :current_stage)

        if is_binary(current_stage) and current_stage in stage_names do
          {increment_runtime_counts(counts, current_stage, status), unknown}
        else
          {counts, [runtime_issue(entry) | unknown]}
        end
      end)

    %{
      available?: true,
      error: nil,
      counts_by_stage: counts_by_stage,
      unknown_stage_issues: Enum.reverse(unknown_entries)
    }
  end

  def runtime_summary(%Definition{} = definition, :timeout) do
    unavailable_runtime(definition, %{code: "snapshot_timeout", message: "Snapshot timed out"})
  end

  def runtime_summary(%Definition{} = definition, :unavailable) do
    unavailable_runtime(definition, %{code: "snapshot_unavailable", message: "Snapshot unavailable"})
  end

  def runtime_summary(%Definition{} = definition, _snapshot) do
    unavailable_runtime(definition, %{code: "snapshot_not_loaded", message: "Snapshot not loaded"})
  end

  @spec tracker_summary(map(), map() | nil) :: map() | nil
  def tracker_summary(_workflow_map, nil), do: nil

  def tracker_summary(workflow_map, tracker_config) when is_map(workflow_map) and is_map(tracker_config) do
    tracker = tracker_payload(tracker_config)
    stage_states = TrackerConfig.stage_states(tracker_config, workflow_map)
    stage_names = workflow_map |> Map.get("stages", %{}) |> Map.keys() |> Enum.sort()
    mapped_stage_names = stage_states |> Map.keys() |> Enum.sort()
    missing_stage_names = Enum.reject(stage_names, &mapped_state?(stage_states, &1))
    unknown_stage_names = Enum.reject(mapped_stage_names, &(&1 in stage_names))

    %{
      available?: true,
      kind: safe_string(Map.get(tracker, "kind")),
      strategy: tracker_strategy(tracker),
      provider_hint: provider_hint(tracker),
      mappings: tracker_mappings(stage_names, stage_states),
      coverage: %{
        complete?: missing_stage_names == [] and unknown_stage_names == [],
        mapped: Enum.count(stage_names, &mapped_state?(stage_states, &1)),
        total: length(stage_names),
        missing_stages: missing_stage_names,
        unknown_stages: unknown_stage_names
      }
    }
  end

  defp workflow_summary(%Definition{} = definition) do
    %{
      start_stage: definition.start_stage,
      terminal_stages: definition.terminal_stages,
      outcomes: definition.outcomes,
      stage_count: map_size(definition.stages),
      transition_count: transition_count(definition)
    }
  end

  defp stage_nodes(%Definition{} = definition, runtime, tracker) do
    reachable = reachable_stage_set(definition)

    definition.stages
    |> Enum.sort_by(fn {stage_id, _stage} -> stage_id end)
    |> Enum.map(fn {stage_id, stage} ->
      prompt = Map.get(stage, "prompt", "")
      transitions = Map.get(stage, "transitions", %{})

      %{
        id: stage_id,
        prompt: prompt,
        prompt_preview: prompt_preview(prompt),
        start?: stage_id == definition.start_stage,
        terminal?: stage_id in definition.terminal_stages,
        reachable?: stage_id in reachable,
        blocked?: blocked_stage?(stage_id),
        protocol_blocked?: protocol_blocked_stage?(stage_id),
        outgoing_count: map_size(transitions),
        transitions: stage_transition_details(stage_id, transitions, definition),
        runtime: Map.get(runtime.counts_by_stage, stage_id, empty_runtime_counts()),
        tracker_state: tracker_state_for_stage(tracker, stage_id)
      }
    end)
  end

  defp stage_transition_details(stage_id, transitions, %Definition{} = definition) do
    transitions
    |> Enum.sort_by(fn {outcome, target} -> {outcome, target} end)
    |> Enum.map(fn {outcome, target} ->
      %{
        id: transition_id(stage_id, outcome, target),
        from: stage_id,
        outcome: outcome,
        to: target,
        known_outcome?: outcome in definition.outcomes,
        target_exists?: Map.has_key?(definition.stages, target),
        terminal_target?: target in definition.terminal_stages,
        blocked_target?: blocked_stage?(target),
        protocol_blocked_target?: protocol_blocked_stage?(target)
      }
    end)
  end

  defp transition_edges(%Definition{} = definition) do
    definition.stages
    |> Enum.sort_by(fn {stage_id, _stage} -> stage_id end)
    |> Enum.flat_map(fn {stage_id, %{"transitions" => transitions}} ->
      stage_transition_details(stage_id, transitions, definition)
      |> Enum.map(&Map.put(&1, :kind, :transition))
    end)
  end

  defp missing_outcome_summary(%Definition{} = definition) do
    max_retries = Map.get(definition.missing_outcome, "max_retries")
    on_exhausted = Map.get(definition.missing_outcome, "on_exhausted")

    %{
      max_retries: max_retries,
      on_exhausted: on_exhausted,
      target_exists?: Map.has_key?(definition.stages, on_exhausted),
      terminal_target?: on_exhausted in definition.terminal_stages,
      blocked_target?: blocked_stage?(on_exhausted),
      protocol_blocked_target?: protocol_blocked_stage?(on_exhausted)
    }
  end

  defp diagnostics(%Definition{} = definition, tracker) do
    []
    |> Kernel.++(transition_diagnostics(definition))
    |> Kernel.++(stage_shape_warnings(definition))
    |> Kernel.++(reachability_warnings(definition))
    |> Kernel.++(tracker_diagnostics(tracker))
    |> Kernel.++([%{severity: :info, code: :workflow_loaded, message: "WORKFLOW.md workflow-stage definition loaded."}])
  end

  defp transition_diagnostics(%Definition{} = definition) do
    definition.stages
    |> Enum.flat_map(fn {stage_id, %{"transitions" => transitions}} ->
      Enum.flat_map(transitions, fn {outcome, target} ->
        []
        |> maybe_add_diagnostic(
          outcome not in definition.outcomes,
          :error,
          :unknown_outcome,
          "Stage #{stage_id} uses unknown outcome #{inspect(outcome)}."
        )
        |> maybe_add_diagnostic(
          not Map.has_key?(definition.stages, target),
          :error,
          :unknown_transition_target,
          "Stage #{stage_id} outcome #{outcome} targets unknown stage #{inspect(target)}."
        )
      end)
    end)
  end

  defp stage_shape_warnings(%Definition{} = definition) do
    Enum.flat_map(definition.stages, fn {stage_id, %{"transitions" => transitions}} ->
      []
      |> maybe_add_diagnostic(
        stage_id not in definition.terminal_stages and map_size(transitions) == 0,
        :warning,
        :non_terminal_without_transitions,
        "Non-terminal stage #{stage_id} has no outgoing transitions."
      )
    end)
  end

  defp reachability_warnings(%Definition{} = definition) do
    reachable = reachable_stage_set(definition)

    unreachable =
      definition
      |> stage_names()
      |> Enum.reject(&(&1 in reachable))

    reachable_with_missing_outcome =
      [Map.get(definition.missing_outcome, "on_exhausted") | reachable]
      |> Enum.uniq()

    terminal_unreached =
      definition.terminal_stages
      |> Enum.reject(&(&1 in reachable_with_missing_outcome))

    []
    |> Kernel.++(
      Enum.map(unreachable, fn stage_id ->
        %{
          severity: :warning,
          code: :unreachable_stage,
          message: "Stage #{stage_id} is not reachable from start_stage #{definition.start_stage}."
        }
      end)
    )
    |> Kernel.++(
      Enum.map(terminal_unreached, fn stage_id ->
        %{
          severity: :warning,
          code: :terminal_stage_unreached,
          message: "Terminal stage #{stage_id} is not reachable from start_stage #{definition.start_stage} or missing_outcome.on_exhausted."
        }
      end)
    )
  end

  defp tracker_diagnostics(nil) do
    [
      %{
        severity: :warning,
        code: :tracker_config_unavailable,
        message: "TRACKER.yaml is not available; provider-visible stage mapping cannot be checked."
      }
    ]
  end

  defp tracker_diagnostics(%{coverage: %{complete?: true}}) do
    [
      %{
        severity: :info,
        code: :tracker_mapping_complete,
        message: "TRACKER.yaml maps every workflow stage to a provider-visible state."
      }
    ]
  end

  defp tracker_diagnostics(%{coverage: coverage}) do
    []
    |> maybe_add_diagnostic(
      coverage.missing_stages != [],
      :warning,
      :tracker_mapping_missing_stages,
      "TRACKER.yaml is missing provider states for workflow stages: #{Enum.join(coverage.missing_stages, ", ")}."
    )
    |> maybe_add_diagnostic(
      coverage.unknown_stages != [],
      :warning,
      :tracker_mapping_unknown_stages,
      "TRACKER.yaml contains mappings for unknown workflow stages: #{Enum.join(coverage.unknown_stages, ", ")}."
    )
  end

  defp maybe_add_diagnostic(diagnostics, false, _severity, _code, _message), do: diagnostics

  defp maybe_add_diagnostic(diagnostics, true, severity, code, message) do
    [%{severity: severity, code: code, message: message} | diagnostics]
  end

  defp reachable_stage_set(%Definition{} = definition) do
    stage_names = stage_names(definition)
    walk_reachable([definition.start_stage], [], definition, stage_names)
  end

  defp walk_reachable([], visited, _definition, _stage_name_set), do: visited

  defp walk_reachable([stage_id | rest], visited, definition, stage_name_set) do
    cond do
      not is_binary(stage_id) or stage_id not in stage_name_set ->
        walk_reachable(rest, visited, definition, stage_name_set)

      stage_id in visited ->
        walk_reachable(rest, visited, definition, stage_name_set)

      true ->
        targets =
          definition.stages
          |> Map.get(stage_id, %{})
          |> Map.get("transitions", %{})
          |> Map.values()

        walk_reachable(rest ++ targets, [stage_id | visited], definition, stage_name_set)
    end
  end

  defp runtime_issue(entry) do
    %{
      issue_identifier: Map.get(entry, :issue_identifier),
      issue_id: Map.get(entry, :issue_id),
      status: Map.get(entry, :status),
      current_stage: Map.get(entry, :current_stage)
    }
  end

  defp snapshot_entries(snapshot) do
    []
    |> Kernel.++(snapshot_status_entries(Map.get(snapshot, :running, []), :running))
    |> Kernel.++(snapshot_status_entries(Map.get(snapshot, :retrying, []), :retrying))
    |> Kernel.++(snapshot_status_entries(Map.get(snapshot, :blocked, []), :blocked))
  end

  defp snapshot_status_entries(entries, status) when is_list(entries) do
    Enum.map(entries, fn entry ->
      %{
        issue_id: map_get(entry, [:issue_id, "issue_id"]),
        issue_identifier: map_get(entry, [:identifier, "identifier", :issue_identifier, "issue_identifier"]),
        current_stage: map_get(entry, [:current_stage, "current_stage"]),
        status: status
      }
    end)
  end

  defp snapshot_status_entries(_entries, _status), do: []

  defp increment_runtime_counts(counts, stage_id, status) do
    update_in(counts, [stage_id, status], &((&1 || 0) + 1))
    |> update_in([stage_id, :total], &((&1 || 0) + 1))
  end

  defp unavailable_runtime(definition, error) do
    %{
      available?: false,
      error: error,
      counts_by_stage: Map.new(stage_names(definition), &{&1, empty_runtime_counts()}),
      unknown_stage_issues: []
    }
  end

  defp empty_runtime_counts do
    %{running: 0, retrying: 0, blocked: 0, total: 0}
  end

  defp tracker_mappings(stage_names, stage_states) do
    Enum.map(stage_names, fn stage_id ->
      stage_state = Map.get(stage_states, stage_id, %{})

      %{
        stage: stage_id,
        provider_state: Map.get(stage_state, "state"),
        terminal?: Map.get(stage_state, "terminal", false) == true,
        mapped?: mapped_state?(stage_states, stage_id)
      }
    end)
  end

  defp tracker_state_for_stage(nil, _stage_id), do: nil

  defp tracker_state_for_stage(%{mappings: mappings}, stage_id) do
    Enum.find(mappings, &(&1.stage == stage_id))
  end

  defp mapped_state?(stage_states, stage_id) do
    match?(%{"state" => state} when is_binary(state), Map.get(stage_states, stage_id))
  end

  defp tracker_strategy(tracker) do
    workflow_state = map_get(tracker, ["workflow_state", :workflow_state]) || %{}

    cond do
      is_binary(Map.get(workflow_state, "strategy")) -> Map.get(workflow_state, "strategy")
      is_integer(Map.get(tracker, "project_number")) -> "project_v2_status"
      is_binary(Map.get(tracker, "state_label_prefix")) -> "scoped_label"
      true -> "stage_states"
    end
  end

  defp provider_hint(tracker) do
    workflow_state = map_get(tracker, ["workflow_state", :workflow_state]) || %{}

    tracker
    |> Map.take(["owner", "repo", "project_slug", "project_number", "project_status_field_name", "state_label_prefix"])
    |> maybe_put_workflow_state_hint("state_label_prefix", workflow_state, "label_prefix")
    |> maybe_put_workflow_state_hint("project_status_field_name", workflow_state, "field_name")
    |> reject_sensitive_values()
  end

  defp maybe_put_workflow_state_hint(hints, target_key, workflow_state, source_key) do
    case {Map.get(hints, target_key), Map.get(workflow_state, source_key)} do
      {nil, value} when is_binary(value) and value != "" -> Map.put(hints, target_key, value)
      _other -> hints
    end
  end

  defp reject_sensitive_values(map) do
    Map.reject(map, fn {key, value} ->
      sensitive_key?(key) or is_nil(value) or value == ""
    end)
  end

  defp tracker_payload(config) when is_map(config) do
    config = normalize_keys(config)
    Map.get(config, "tracker", config)
  end

  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_string(_value), do: nil

  defp sensitive_key?(key), do: Regex.match?(@sensitive_key_pattern, to_string(key))

  defp transition_count(%Definition{} = definition) do
    Enum.reduce(definition.stages, 0, fn {_stage_id, stage}, total ->
      total + map_size(Map.get(stage, "transitions", %{}))
    end)
  end

  defp prompt_preview(prompt) when is_binary(prompt) do
    prompt
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(220)
  end

  defp prompt_preview(_prompt), do: ""

  defp truncate(value, max_length) do
    if String.length(value) <= max_length do
      value
    else
      value
      |> String.slice(0, max_length)
      |> Kernel.<>("...")
    end
  end

  defp stage_names(%Definition{} = definition), do: definition.stages |> Map.keys() |> Enum.sort()

  defp blocked_stage?(stage_id) when is_binary(stage_id), do: String.contains?(stage_id, "blocked")
  defp blocked_stage?(_stage_id), do: false

  defp protocol_blocked_stage?(stage_id) when is_binary(stage_id), do: String.contains?(stage_id, "protocol")
  defp protocol_blocked_stage?(_stage_id), do: false

  defp transition_id(stage_id, outcome, target), do: "#{stage_id}:#{outcome}:#{target}"

  defp error_code({:invalid_workflow_definition, _message}), do: "invalid_workflow_definition"
  defp error_code({:workflow_parse_error, _reason}), do: "workflow_parse_error"
  defp error_code({:missing_workflow_file, _path, _reason}), do: "missing_workflow_file"
  defp error_code(:workflow_front_matter_not_a_map), do: "workflow_front_matter_not_a_map"
  defp error_code(reason), do: reason |> inspect() |> String.replace(~r/[^a-zA-Z0-9_]+/, "_")

  defp map_get(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp map_get(_map, _keys), do: nil

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
