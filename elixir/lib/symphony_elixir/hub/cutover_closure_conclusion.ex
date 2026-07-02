defmodule SymphonyElixir.Hub.CutoverClosureConclusion do
  @moduledoc """
  Read-only operator conclusion baseline for Hub cutover closure snapshots.

  This module consumes already-safe `CutoverClosureChain` summaries, project
  summaries, recent-chain fixtures, or device observability snapshots and maps
  them into operator-facing conclusions. It never re-aggregates raw cutover
  evidence and never calls provider, dispatch, worker, writeback, systemd, or
  configuration paths.
  """

  alias SymphonyElixir.Hub.{CutoverClosureChain, SafeSummary}

  # Dialyzer collapses defensive boolean normalization branches in this model-only
  # read model into line-1 no_match warnings, without actionable function locations.
  @dialyzer :no_match

  @version 1

  @statuses [
    "malformed",
    "conflict",
    "stale",
    "unsupported",
    "open_manual_attention",
    "open_retryable",
    "no_request",
    "closed_no_side_effect",
    "closed_succeeded",
    "no_chain"
  ]

  @closed_statuses ["closed_succeeded", "closed_no_side_effect"]
  @reference_types ["closeout", "replay_decision", "replay_request_audit"]
  @reference_statuses ["missing", "current", "stale", "conflict", "malformed", "unsupported"]
  @blocking_reference_statuses ["stale", "conflict", "malformed", "unsupported"]

  @type summary :: map()

  @spec build(term(), keyword()) :: summary()
  def build(input, opts \\ []) when is_list(opts) do
    source = closure_source(input, opts)
    closure_chain = CutoverClosureChain.to_snapshot(source.summary)
    project_sources = project_sources(source.projects, closure_chain)
    chain_conclusions = closure_chain |> list_value(:recent_chains) |> Enum.map(&chain_conclusion/1)
    projects = Enum.map(project_sources, &project_conclusion/1)
    rollup = device_rollup(source.summary, closure_chain, projects)

    evaluated_at =
      iso8601(value(closure_chain, :evaluated_at)) ||
        iso8601(value(closure_chain, :generated_at)) ||
        generated_at(opts)

    %{
      version: @version,
      generated_at: iso8601(value(closure_chain, :generated_at)) || generated_at(opts),
      evaluated_at: evaluated_at,
      conclusion: rollup.conclusion,
      severity: rollup.severity,
      attention_level: rollup.attention_level,
      summary_code: rollup.summary_code,
      required_action_codes: rollup.required_action_codes,
      blocked_by: rollup.blocked_by,
      evidence_references: rollup.evidence_references,
      closure_chain_status: rollup.closure_chain_status,
      closure_status_counts: rollup.closure_status_counts,
      reference_status_counts: rollup.reference_status_counts,
      project_count: length(projects),
      chain_count: length(chain_conclusions),
      fully_closed: rollup.fully_closed,
      operation_success: rollup.operation_success,
      read_only: true,
      no_side_effects: true,
      actions_are_advisory: true,
      auto_retry_allowed: false,
      auto_replay_allowed: false,
      queued_replay: false,
      pending_execution: false,
      pending_retry: false,
      legacy_takeover: false,
      device_rollup: rollup,
      projects: projects,
      recent_chains: chain_conclusions
    }
  end

  @spec to_snapshot(term()) :: summary()
  def to_snapshot(input), do: build(input)

  @spec observability_snapshot(term()) :: summary() | nil
  def observability_snapshot(nil), do: nil
  def observability_snapshot(input) when is_map(input), do: build(input)
  def observability_snapshot(_input), do: nil

  defp closure_source(input, opts) when is_map(input) do
    cond do
      is_map(value(input, :hub_cutover_closure_chain)) ->
        closure_source(value(input, :hub_cutover_closure_chain), opts)

      is_map(value(input, :hub_device_observability)) ->
        closure_source(value(input, :hub_device_observability), opts)

      device_observability_snapshot?(input) ->
        device_closure_source(input, opts)

      project_wrapper_with_closure?(input) ->
        project = closure_from_project_wrapper(input)
        %{summary: %{generated_at: generated_at(opts), projects: [project]}, projects: [project]}

      single_chain?(input) ->
        %{summary: %{generated_at: generated_at(opts), recent_chains: [input]}, projects: []}

      project_summary?(input) ->
        %{summary: %{generated_at: generated_at(opts), projects: [input]}, projects: [input]}

      true ->
        %{summary: input, projects: list_value(input, :projects)}
    end
  end

  defp closure_source(_input, opts), do: %{summary: %{generated_at: generated_at(opts)}, projects: []}

  defp device_closure_source(device, opts) do
    overview_closure =
      device
      |> value(:overview)
      |> case do
        overview when is_map(overview) -> value(overview, :cutover_closure_chain) || %{}
        _overview -> %{}
      end

    projects =
      device
      |> list_value(:projects)
      |> Enum.map(&closure_from_project_wrapper/1)
      |> Enum.reject(&(&1 == %{}))

    summary =
      overview_closure
      |> as_map()
      |> Map.put_new(:generated_at, generated_at(opts))
      |> Map.put(:projects, projects)

    %{summary: summary, projects: projects}
  end

  defp project_sources([], closure_chain), do: list_value(closure_chain, :projects)
  defp project_sources(projects, _closure_chain), do: projects

  defp project_wrapper_with_closure?(input) do
    (is_map(value(input, :cutover_closure_chain)) or is_map(get_in_value(input, [:detail, :closure_chain]))) and
      not closure_summary?(input)
  end

  defp closure_from_project_wrapper(project) do
    closure =
      value(project, :cutover_closure_chain) ||
        get_in_value(project, [:detail, :closure_chain]) ||
        if(project_summary?(project), do: project, else: %{})

    closure =
      closure
      |> as_map()
      |> put_if_blank(:project_id, optional_string(project, :project_id))

    case value(project, :provider_scope) || get_in_value(project, [:detail, :provider_scope]) do
      provider_scope when is_map(provider_scope) -> put_if_blank(closure, :provider_scope, sanitize_map(provider_scope))
      _provider_scope -> closure
    end
  end

  defp device_observability_snapshot?(input) do
    is_map(value(input, :overview)) and
      (is_map(get_in_value(input, [:overview, :cutover_closure_chain])) or
         input |> list_value(:projects) |> Enum.any?(&project_wrapper_with_closure?/1))
  end

  defp closure_summary?(input) do
    is_map(input) and
      (is_map(value(input, :counts)) or list_value(input, :projects) != [] or
         list_value(input, :recent_chains) != []) and
      not project_summary?(input)
  end

  defp project_summary?(input) do
    is_map(input) and
      bound?(value(input, :project_id)) and
      (is_map(value(input, :counts)) or is_map(value(input, :closure_status_counts)) or
         list_value(input, :closure_chains) != [] or
         bound?(value(input, :status)))
  end

  defp single_chain?(input) do
    is_map(input) and
      (bound?(value(input, :closure_status)) or is_map(value(input, :outcome)) or
         is_map(value(input, :execution_outcome)))
  end

  defp device_rollup(summary_source, closure_chain, projects) do
    source = if projects == [], do: closure_chain, else: summary_source
    status = rollup_status(projects, effective_status(source))
    base = conclusion_for_status(status)
    reference_blockers = reference_blockers(source)
    project_blockers = Enum.flat_map(projects, &list_value(&1, :blocked_by))
    blocked_by = unique_maps(status_blockers(status, source) ++ reference_blockers ++ project_blockers)

    closure_status_counts =
      if projects == [] do
        closure_status_counts(source)
      else
        aggregate_status_counts(projects)
      end

    fully_closed =
      if projects == [] do
        status in @closed_statuses and blocked_by == []
      else
        projects != [] and Enum.all?(projects, &(&1.fully_closed == true))
      end

    operation_success =
      if projects == [] do
        status == "closed_succeeded" and blocked_by == []
      else
        projects != [] and Enum.all?(projects, &(&1.operation_success == true))
      end

    %{
      conclusion: base.conclusion,
      severity: severity(base.severity, blocked_by),
      attention_level: attention_level(base.attention_level, blocked_by),
      summary_code: base.summary_code,
      required_action_codes: required_actions(base.required_action_codes, source, blocked_by, projects),
      blocked_by: blocked_by,
      evidence_references: evidence_references(source, status, :device, projects),
      closure_chain_status: status,
      closure_status_counts: closure_status_counts,
      reference_status_counts: reference_status_counts(source),
      fully_closed: fully_closed,
      operation_success: operation_success,
      read_only: true,
      no_side_effects: true,
      actions_are_advisory: true,
      auto_retry_allowed: false,
      auto_replay_allowed: false,
      queued_replay: false,
      pending_execution: false,
      pending_retry: false,
      legacy_takeover: false
    }
  end

  defp project_conclusion(project) do
    status = effective_status(project)
    base = conclusion_for_status(status)
    blocked_by = unique_maps(status_blockers(status, project) ++ reference_blockers(project))

    %{
      project_id: optional_string(project, :project_id),
      provider_scope: project_provider_scope(project),
      conclusion: base.conclusion,
      severity: severity(base.severity, blocked_by),
      attention_level: attention_level(base.attention_level, blocked_by),
      summary_code: base.summary_code,
      required_action_codes: required_actions(base.required_action_codes, project, blocked_by, []),
      blocked_by: blocked_by,
      evidence_references: evidence_references(project, status, :project, []),
      closure_chain_status: status,
      closure_status_counts: closure_status_counts(project),
      reference_status_counts: reference_status_counts(project),
      safe_evidence_fingerprints: safe_evidence_fingerprints(project),
      reason_codes: reason_codes(project),
      action_codes: action_codes(project),
      fully_closed: status in @closed_statuses and blocked_by == [],
      operation_success: status == "closed_succeeded" and blocked_by == [],
      read_only: true,
      no_side_effects: true,
      actions_are_advisory: true,
      auto_retry_allowed: false,
      auto_replay_allowed: false,
      queued_replay: false,
      pending_execution: false,
      pending_retry: false,
      legacy_takeover: false
    }
  end

  defp chain_conclusion(chain) do
    status = effective_status(chain)
    base = conclusion_for_status(status)
    blocked_by = unique_maps(status_blockers(status, chain) ++ reference_blockers(chain))

    %{
      closure_chain_id: optional_string(chain, :closure_chain_id),
      project_id: optional_string(chain, :project_id),
      provider_scope: sanitize_map(value(chain, :provider_scope) || %{}),
      operation: safe_code(value(chain, :operation)),
      side_effect_source: safe_code(value(chain, :side_effect_source) || value(chain, :source)),
      conclusion: base.conclusion,
      severity: severity(base.severity, blocked_by),
      attention_level: attention_level(base.attention_level, blocked_by),
      summary_code: base.summary_code,
      required_action_codes: required_actions(base.required_action_codes, chain, blocked_by, []),
      blocked_by: blocked_by,
      evidence_references: evidence_references(chain, status, :chain, []),
      closure_chain_status: status,
      safe_evidence_fingerprint: optional_string(chain, :safe_evidence_fingerprint),
      safe_evidence_fingerprints: safe_evidence_fingerprints(chain),
      reason_codes: reason_codes(chain),
      action_codes: action_codes(chain),
      fully_closed: status in @closed_statuses and blocked_by == [],
      operation_success: status == "closed_succeeded" and blocked_by == [],
      read_only: true,
      no_side_effects: true,
      actions_are_advisory: true,
      auto_retry_allowed: false,
      auto_replay_allowed: false,
      queued_replay: false,
      pending_execution: false,
      pending_retry: false,
      legacy_takeover: false
    }
  end

  defp conclusion_for_status("closed_succeeded") do
    %{
      conclusion: "closed_succeeded",
      severity: "info",
      attention_level: "review",
      summary_code: "closure_closed_succeeded",
      required_action_codes: ["review_success_evidence"]
    }
  end

  defp conclusion_for_status("closed_no_side_effect") do
    %{
      conclusion: "closed_no_side_effect",
      severity: "notice",
      attention_level: "review",
      summary_code: "closure_closed_no_side_effect",
      required_action_codes: ["review_no_side_effect_evidence"]
    }
  end

  defp conclusion_for_status("open_retryable") do
    %{
      conclusion: "waiting_explicit_retry_consideration",
      severity: "warning",
      attention_level: "retry_consideration",
      summary_code: "closure_open_retryable_waiting_explicit_consideration",
      required_action_codes: ["request_explicit_retry_consideration"]
    }
  end

  defp conclusion_for_status("open_manual_attention") do
    %{
      conclusion: "manual_attention_required",
      severity: "warning",
      attention_level: "manual_attention",
      summary_code: "closure_open_manual_attention_required",
      required_action_codes: ["resolve_manual_attention"]
    }
  end

  defp conclusion_for_status("stale") do
    %{
      conclusion: "evidence_stale_reaudit_required",
      severity: "warning",
      attention_level: "audit_required",
      summary_code: "closure_evidence_stale",
      required_action_codes: ["refresh_stale_evidence"]
    }
  end

  defp conclusion_for_status("conflict") do
    %{
      conclusion: "evidence_conflict_reaudit_required",
      severity: "error",
      attention_level: "audit_required",
      summary_code: "closure_evidence_conflict",
      required_action_codes: ["resolve_conflict"]
    }
  end

  defp conclusion_for_status("malformed") do
    %{
      conclusion: "input_malformed",
      severity: "error",
      attention_level: "input_fix_required",
      summary_code: "closure_input_malformed",
      required_action_codes: ["fix_malformed_chain_input"]
    }
  end

  defp conclusion_for_status("unsupported") do
    %{
      conclusion: "unsupported_closure_report_slice",
      severity: "warning",
      attention_level: "unsupported",
      summary_code: "closure_slice_unsupported",
      required_action_codes: ["unsupported_closure_report_slice"]
    }
  end

  defp conclusion_for_status("no_request") do
    %{
      conclusion: "no_explicit_cutover_request",
      severity: "none",
      attention_level: "none",
      summary_code: "closure_no_request",
      required_action_codes: ["none_required"]
    }
  end

  defp conclusion_for_status(_status) do
    %{
      conclusion: "no_explicit_closure_chain",
      severity: "none",
      attention_level: "none",
      summary_code: "closure_no_chain",
      required_action_codes: ["none_required"]
    }
  end

  defp status_blockers(status, source) when status in ["open_retryable", "open_manual_attention", "stale", "conflict", "malformed", "unsupported"] do
    base = conclusion_for_status(status)

    [
      %{
        code: blocker_code(status),
        source: "closure_chain",
        closure_chain_status: status,
        reason_codes: reason_codes(source),
        action_codes: base.required_action_codes,
        closure_action_codes: action_codes(source),
        safe_evidence_fingerprint: optional_string(source, :safe_evidence_fingerprint)
      }
      |> compact_map()
    ]
  end

  defp status_blockers(_status, _source), do: []

  defp blocker_code("open_retryable"), do: "waiting_explicit_retry_consideration"
  defp blocker_code("open_manual_attention"), do: "manual_attention_required"
  defp blocker_code("stale"), do: "stale_evidence_blocks_closure"
  defp blocker_code("conflict"), do: "conflicting_evidence_blocks_closure"
  defp blocker_code("malformed"), do: "malformed_input_blocks_closure"
  defp blocker_code("unsupported"), do: "unsupported_slice_blocks_closure"
  defp blocker_code(status), do: "closure_#{status}"

  defp required_actions(base_actions, _source, blocked_by, projects) do
    project_actions = Enum.flat_map(projects, &list_value(&1, :required_action_codes))

    blocker_actions =
      blocked_by
      |> Enum.flat_map(fn blocker -> value(blocker, :action_codes) || value(blocker, :action_code) end)

    (base_actions ++ project_actions ++ blocker_actions)
    |> Enum.map(&safe_code/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> normalize_none_required()
  end

  defp normalize_none_required([]), do: ["none_required"]

  defp normalize_none_required(actions) do
    non_none = Enum.reject(actions, &(&1 == "none_required"))
    if non_none == [], do: ["none_required"], else: non_none
  end

  defp effective_status(source) do
    counts = closure_status_counts(source)

    Enum.find_value(@statuses, fn status ->
      if Map.get(counts, String.to_atom(status), 0) > 0, do: status
    end) ||
      normalize_status(value(source, :closure_status) || value(source, :status))
  end

  defp rollup_status([], fallback), do: normalize_status(fallback)

  defp rollup_status(projects, _fallback) do
    statuses = Enum.map(projects, &value(&1, :closure_chain_status))

    Enum.find(@statuses, fn status -> status in statuses end) || "no_chain"
  end

  defp closure_status_counts(source) do
    counts = value(source, :counts) || %{}
    direct_counts = value(source, :closure_status_counts) || %{}
    status = normalize_status(value(source, :closure_status) || value(source, :status))

    counts =
      @statuses
      |> Map.new(fn status_name ->
        status_atom = String.to_atom(status_name)

        count =
          non_negative_integer(value(counts, "#{status_name}_count")) ||
            non_negative_integer(value(counts, status_atom)) ||
            non_negative_integer(value(direct_counts, status_atom)) ||
            non_negative_integer(value(direct_counts, status_name)) ||
            0

        {status_atom, count}
      end)

    if Enum.all?(counts, fn {_status, count} -> count == 0 end) and status in @statuses do
      Map.put(counts, String.to_atom(status), 1)
    else
      counts
    end
  end

  defp aggregate_status_counts(projects) do
    Enum.reduce(projects, zero_status_counts(), fn project, acc ->
      project_counts = value(project, :closure_status_counts) || zero_status_counts()

      Enum.reduce(@statuses, acc, fn status, status_acc ->
        key = String.to_atom(status)
        Map.update!(status_acc, key, &(&1 + non_negative_integer(value(project_counts, key), 0)))
      end)
    end)
  end

  defp zero_status_counts, do: Map.new(@statuses, &{String.to_atom(&1), 0})

  defp reference_status_counts(source) do
    counts = value(source, :counts) || %{}
    nested = value(counts, :reference_status_counts) || value(source, :reference_status_counts) || %{}

    @reference_types
    |> Map.new(fn type ->
      type_atom = String.to_atom(type)

      type_counts =
        value(counts, "#{type}_reference_status_counts") ||
          value(source, "#{type}_reference_status_counts") ||
          value(nested, type_atom) ||
          value(nested, type) ||
          %{}

      {type_atom, reference_count_snapshot(type_counts)}
    end)
    |> add_retained_reference_statuses(source)
  end

  defp reference_count_snapshot(counts) do
    @reference_statuses
    |> Map.new(fn status ->
      status_atom = String.to_atom(status)
      count = non_negative_integer(value(counts, status_atom)) || non_negative_integer(value(counts, status)) || 0
      {status_atom, count}
    end)
  end

  defp add_retained_reference_statuses(counts, source) do
    source
    |> retained_reference_statuses()
    |> Enum.reduce(counts, fn {type, status}, acc ->
      type_atom = String.to_atom(type)
      status_atom = String.to_atom(status)

      Map.update(acc, type_atom, reference_count_snapshot(%{status_atom => 1}), fn type_counts ->
        Map.update(type_counts, status_atom, 1, &(&1 + 1))
      end)
    end)
  end

  defp retained_reference_statuses(source) do
    source
    |> value(:retained_reference_statuses)
    |> case do
      statuses when is_map(statuses) ->
        statuses
        |> Enum.flat_map(fn {type, status} ->
          type = reference_type(type)
          status_name = normalize_reference_status(value(status, :status))
          if type in @reference_types and status_name in @reference_statuses, do: [{type, status_name}], else: []
        end)

      _statuses ->
        []
    end
  end

  defp reference_blockers(source) do
    source
    |> reference_status_counts()
    |> Enum.flat_map(fn {type, counts} ->
      @blocking_reference_statuses
      |> Enum.flat_map(fn status ->
        count = non_negative_integer(value(counts, status), 0)

        if count > 0 do
          [
            %{
              code: "reference_status_#{status}",
              source: "closure_chain_reference",
              reference_type: Atom.to_string(type),
              reference_status: status,
              count: count,
              action_codes: [reference_action(status)]
            }
          ]
        else
          []
        end
      end)
    end)
  end

  defp evidence_references(source, status, level, projects) do
    closure_ref =
      %{
        type: "closure_chain",
        level: Atom.to_string(level),
        project_id: optional_string(source, :project_id),
        closure_chain_id: optional_string(source, :closure_chain_id),
        closure_chain_status: status,
        summary_code: conclusion_for_status(status).summary_code,
        reason_codes: reason_codes(source),
        action_codes: action_codes(source),
        safe_evidence_fingerprint: optional_string(source, :safe_evidence_fingerprint),
        safe_evidence_fingerprints: safe_evidence_fingerprints(source),
        closure_status_counts: closure_status_counts(source)
      }
      |> compact_map()

    reference_refs = reference_status_evidence(source)
    project_refs = Enum.map(projects, &project_evidence_reference/1)

    [closure_ref | reference_refs ++ project_refs]
    |> Enum.map(&sanitize_map/1)
    |> restore_closure_reference_fields(source)
    |> Enum.reject(&(&1 == %{}))
    |> Enum.take(30)
  end

  defp restore_closure_reference_fields([], _source), do: []

  defp restore_closure_reference_fields([closure_ref | rest], source) do
    closure_ref =
      closure_ref
      |> put_nonempty(:safe_evidence_fingerprints, safe_evidence_fingerprints(source))
      |> put_nonempty(:closure_status_counts, closure_status_counts(source))

    [closure_ref | rest]
  end

  defp put_nonempty(map, key, value) do
    if blank?(value), do: map, else: Map.put(map, key, value)
  end

  defp reference_status_evidence(source) do
    retained =
      source
      |> value(:retained_reference_statuses)
      |> case do
        statuses when is_map(statuses) ->
          Enum.map(statuses, fn {_type, status} ->
            status
            |> as_map()
            |> Map.put(:type, "retained_reference")
          end)

        _statuses ->
          []
      end

    counted =
      source
      |> reference_status_counts()
      |> Enum.flat_map(fn {type, counts} ->
        counts
        |> Enum.flat_map(fn {status, count} ->
          if count > 0 do
            [
              %{
                type: "retained_reference_count",
                reference_type: Atom.to_string(type),
                reference_status: Atom.to_string(status),
                count: count
              }
            ]
          else
            []
          end
        end)
      end)

    retained ++ counted
  end

  defp project_evidence_reference(project) do
    %{
      type: "project_closure_conclusion",
      project_id: optional_string(project, :project_id),
      conclusion: value(project, :conclusion),
      closure_chain_status: value(project, :closure_chain_status),
      summary_code: value(project, :summary_code),
      required_action_codes: list_value(project, :required_action_codes),
      safe_evidence_fingerprints:
        project
        |> value(:evidence_references)
        |> List.wrap()
        |> Enum.flat_map(fn reference ->
          reference
          |> value(:safe_evidence_fingerprints)
          |> as_map()
          |> Enum.to_list()
        end)
        |> Map.new()
    }
    |> compact_map()
  end

  defp reason_codes(source) do
    [
      value(source, :reason_codes),
      value(source, :reason_code),
      value(source, :recent_reference_reason_codes),
      value(source, :recent_reason_codes)
    ]
    |> List.flatten()
    |> Enum.map(&safe_code/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp action_codes(source) do
    [
      value(source, :required_operator_actions),
      value(source, :action_codes),
      value(source, :action_code),
      value(source, :recent_reference_action_codes),
      value(source, :recent_action_codes)
    ]
    |> List.flatten()
    |> Enum.flat_map(fn
      %{code: code} -> [code]
      %{"code" => code} -> [code]
      action -> [action]
    end)
    |> Enum.map(&safe_code/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp safe_evidence_fingerprints(source) when is_map(source) do
    source
    |> raw_safe_evidence_fingerprints()
    |> safe_fingerprint_map()
  end

  defp raw_safe_evidence_fingerprints(source) when is_map(source) do
    Map.get(source, :safe_evidence_fingerprints) ||
      Map.get(source, "safe_evidence_fingerprints") ||
      Map.get(source, :evidence_fingerprints) ||
      Map.get(source, "evidence_fingerprints") ||
      %{}
  end

  defp project_provider_scope(project) do
    case value(project, :provider_scope) do
      provider_scope when is_map(provider_scope) ->
        sanitize_map(provider_scope)

      _provider_scope ->
        project
        |> list_value(:closure_chains)
        |> Enum.find_value(fn chain ->
          provider_scope = value(chain, :provider_scope)
          if is_map(provider_scope), do: sanitize_map(provider_scope)
        end) || %{}
    end
  end

  defp severity("none", blocked_by) when blocked_by != [], do: "warning"
  defp severity("info", blocked_by) when blocked_by != [], do: "warning"
  defp severity(severity, _blocked_by), do: severity

  defp attention_level("none", blocked_by) when blocked_by != [], do: "evidence_review"
  defp attention_level(level, _blocked_by), do: level

  defp reference_action("stale"), do: "refresh_stale_evidence"
  defp reference_action("conflict"), do: "resolve_conflict"
  defp reference_action("malformed"), do: "fix_malformed_chain_input"
  defp reference_action("unsupported"), do: "unsupported_closure_report_slice"
  defp reference_action(_status), do: "none_required"

  defp normalize_status(status) do
    status = safe_code(status)
    if status in @statuses, do: status, else: "unsupported"
  end

  defp normalize_reference_status(status) do
    status = safe_code(status)
    if status in @reference_statuses, do: status, else: "unsupported"
  end

  defp reference_type(type) do
    type = safe_code(type)
    if type == "replay_request", do: "replay_request_audit", else: type
  end

  defp sanitize_map(value) do
    value
    |> SafeSummary.sanitize_map(output_keys: :preserve)
    |> drop_private_path_values()
  end

  defp as_map(value) when is_map(value), do: value
  defp as_map(_value), do: %{}

  defp put_if_blank(map, _key, nil), do: map
  defp put_if_blank(map, _key, ""), do: map

  defp put_if_blank(map, key, value) do
    if blank?(value(map, key)), do: Map.put(map, key, value), else: map
  end

  defp unique_maps(values), do: Enum.uniq_by(values, &inspect/1)

  defp value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || existing_atom_value(map, key)
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key)
  defp value(_map, _key), do: nil

  defp existing_atom_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp get_in_value(map, keys) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case value(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp list_value(map, key) do
    case value(map, key) do
      list when is_list(list) -> list
      nil -> []
      value -> List.wrap(value)
    end
  end

  defp optional_string(value, key) when is_map(value), do: optional_string(value(value, key))
  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: safe_string(value)
  defp optional_string(value) when is_atom(value), do: value |> Atom.to_string() |> safe_string()
  defp optional_string(value), do: value |> to_string() |> safe_string()

  defp safe_string(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      SafeSummary.sensitive_value?(value) -> nil
      private_path?(value) -> nil
      true -> value
    end
  end

  defp drop_private_path_values(value) when is_map(value) do
    value
    |> Enum.reject(fn {_key, raw_value} -> private_path?(raw_value) end)
    |> Enum.map(fn {key, raw_value} -> {key, drop_private_path_values(raw_value)} end)
    |> Map.new()
  end

  defp drop_private_path_values(value) when is_list(value) do
    value
    |> Enum.reject(&private_path?/1)
    |> Enum.map(&drop_private_path_values/1)
  end

  defp drop_private_path_values(value), do: value

  defp private_path?(value) when is_binary(value) do
    Regex.match?(~r{(^|\s)(/home/|/Users/|[A-Za-z]:\\Users\\)}, value)
  end

  defp private_path?(_value), do: false

  defp safe_code(nil), do: nil

  defp safe_code(value) do
    value
    |> optional_string()
    |> case do
      nil ->
        nil

      code ->
        code
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9_:-]+/, "_")
        |> String.trim("_")
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(value) when is_map(value), do: map_size(value) == 0
  defp blank?(_value), do: false

  defp bound?(value), do: not blank?(optional_string(value))

  defp non_negative_integer(value), do: non_negative_integer(value, nil)

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _parse -> default
    end
  end

  defp non_negative_integer(_value, default), do: default

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp generated_at(opts) do
    opts
    |> Keyword.get(:now)
    |> iso8601()
    |> Kernel.||(DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      _parse -> value |> optional_string()
    end
  end

  defp iso8601(_value), do: nil

  defp safe_fingerprint_map(value) when is_map(value) do
    Enum.reduce(value, %{}, &put_safe_fingerprint/2)
  end

  defp safe_fingerprint_map(_value), do: %{}

  defp put_safe_fingerprint({key, raw_value}, acc) do
    if unsafe_fingerprint_value?(key, raw_value) do
      acc
    else
      put_safe_fingerprint_value(key, raw_value, acc)
    end
  end

  defp put_safe_fingerprint_value(key, raw_value, acc) when is_map(raw_value) do
    case safe_fingerprint_map(raw_value) do
      value when value == %{} -> acc
      value -> Map.put(acc, safe_fingerprint_key(key), value)
    end
  end

  defp put_safe_fingerprint_value(key, raw_value, acc) when is_list(raw_value) do
    values =
      raw_value
      |> Enum.reject(&(private_path?(&1) or SafeSummary.sensitive_value?(&1)))
      |> Enum.map(&safe_fingerprint_value/1)
      |> Enum.reject(&blank?/1)

    if values == [], do: acc, else: Map.put(acc, safe_fingerprint_key(key), values)
  end

  defp put_safe_fingerprint_value(key, raw_value, acc) do
    case safe_fingerprint_value(raw_value) do
      nil -> acc
      value -> Map.put(acc, safe_fingerprint_key(key), value)
    end
  end

  defp unsafe_fingerprint_value?(key, raw_value) do
    SafeSummary.sensitive_key?(key) or private_path?(raw_value) or SafeSummary.sensitive_value?(raw_value)
  end

  defp safe_fingerprint_key(key) when is_atom(key), do: key
  defp safe_fingerprint_key(key) when is_binary(key), do: key
  defp safe_fingerprint_key(key), do: to_string(key)

  defp safe_fingerprint_value(value) when is_binary(value), do: optional_string(value)
  defp safe_fingerprint_value(value) when is_atom(value), do: value |> Atom.to_string() |> optional_string()
  defp safe_fingerprint_value(value) when is_number(value) or is_boolean(value), do: value
  defp safe_fingerprint_value(value), do: optional_string(value)
end
