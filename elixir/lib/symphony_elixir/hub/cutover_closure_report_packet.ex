defmodule SymphonyElixir.Hub.CutoverClosureReportPacket do
  @moduledoc """
  Read-only Hub cutover closure report packet baseline.

  The packet is a library-level read model over existing
  `CutoverClosureChain` and `CutoverClosureConclusion` safe snapshots. It
  packages device and project closure state for later Runtime/API/Dashboard
  slices, but it never reads raw cutover evidence, calls providers, dispatches
  work, starts workers, writes providers, operates systemd, mutates config, or
  schedules retry/replay work.
  """

  alias SymphonyElixir.Hub.{
    CutoverClosureChain,
    CutoverClosureConclusion,
    SafeSummary
  }

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

  @boundary_flags %{
    read_only: true,
    no_side_effects: true,
    actions_are_advisory: true,
    consumes_safe_snapshots_only: true,
    provider_calls: false,
    authorization_consumption: false,
    dispatch_calls: false,
    worker_start_calls: false,
    writeback_calls: false,
    systemd_calls: false,
    config_mutation: false,
    auto_retry_allowed: false,
    auto_replay_allowed: false,
    queued_replay: false,
    pending_execution: false,
    pending_retry: false,
    legacy_takeover: false
  }

  @type packet :: map()

  @spec build(term(), keyword()) :: packet()
  def build(input, opts \\ []) when is_list(opts) do
    case packet_source(input) do
      %{packet: packet} ->
        normalize_existing_packet(packet, opts)

      source ->
        generated_at = generated_at(input, source, opts)
        chain = chain_snapshot(source.chain, generated_at)
        conclusion = conclusion_snapshot(source, chain, generated_at)
        projects = project_packets(chain, conclusion)
        device = device_packet(chain, conclusion, projects)

        %{
          version: @version,
          report_version: @version,
          generated_at: generated_at,
          read_only_boundary: boundary_flags(),
          boundary_flags: boundary_flags(),
          report_status: device.report_status,
          operator_conclusion: device.operator_conclusion,
          severity: device.severity,
          attention_level: device.attention_level,
          summary_code: device.summary_code,
          required_action_codes: device.required_action_codes,
          blocked_by: device.blocked_by,
          fully_closed: device.fully_closed,
          operation_success: device.operation_success,
          closure_chain: device.closure_chain,
          device: device,
          projects: projects
        }
        |> sanitize_packet()
    end
  end

  @spec to_snapshot(term()) :: packet()
  def to_snapshot(input), do: build(input)

  @spec observability_snapshot(term()) :: packet() | nil
  def observability_snapshot(nil), do: nil
  def observability_snapshot(input) when is_map(input), do: build(input)
  def observability_snapshot(_input), do: nil

  defp packet_source(input) when is_map(input) do
    cond do
      report_packet?(input) ->
        %{packet: input}

      is_map(value(input, :hub_cutover_closure_chain)) or is_map(value(input, :hub_cutover_closure_conclusion)) ->
        %{
          chain: value(input, :hub_cutover_closure_chain),
          conclusion: value(input, :hub_cutover_closure_conclusion),
          chain_present?: is_map(value(input, :hub_cutover_closure_chain))
        }

      is_map(value(input, :cutover_closure_chain)) or is_map(value(input, :cutover_closure_conclusion)) ->
        %{
          chain: value(input, :cutover_closure_chain),
          conclusion: value(input, :cutover_closure_conclusion),
          chain_present?: is_map(value(input, :cutover_closure_chain))
        }

      is_map(value(input, :closure_chain)) or is_map(value(input, :closure_conclusion)) ->
        %{
          chain: value(input, :closure_chain),
          conclusion: value(input, :closure_conclusion),
          chain_present?: is_map(value(input, :closure_chain))
        }

      conclusion_snapshot_like?(input) ->
        %{chain: nil, conclusion: input, chain_present?: false}

      true ->
        %{chain: input, conclusion: nil, chain_present?: true}
    end
  end

  defp packet_source(_input), do: %{chain: %{}, conclusion: nil, chain_present?: false}

  defp report_packet?(input) do
    positive_integer(value(input, :report_version)) != nil and
      (is_map(value(input, :device)) or is_list(value(input, :projects)))
  end

  defp conclusion_snapshot_like?(input) do
    bound?(value(input, :conclusion)) or
      bound?(value(input, :operator_conclusion)) or
      (is_list(value(input, :projects)) and Enum.any?(value(input, :projects), &bound?(value(&1, :conclusion))))
  end

  defp generated_at(input, source, opts) do
    opts
    |> Keyword.get(:now)
    |> iso8601()
    |> Kernel.||(iso8601(value(source.chain, :generated_at)))
    |> Kernel.||(iso8601(value(source.conclusion, :generated_at)))
    |> Kernel.||(iso8601(value(input, :generated_at)))
    |> Kernel.||(DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp chain_snapshot(nil, generated_at), do: CutoverClosureChain.to_snapshot(%{generated_at: generated_at})

  defp chain_snapshot(chain, generated_at) when is_map(chain) do
    normalized =
      chain
      |> Map.put_new(:generated_at, generated_at)
      |> CutoverClosureChain.to_snapshot()

    restore_chain_safe_fields(normalized, chain)
  end

  defp chain_snapshot(_chain, generated_at), do: chain_snapshot(nil, generated_at)

  defp restore_chain_safe_fields(snapshot, source) when is_map(source) do
    source_projects = Map.new(list_value(source, :projects), &project_pair/1)

    projects =
      snapshot
      |> list_value(:projects)
      |> Enum.map(fn project ->
        restore_project_safe_fields(project, Map.get(source_projects, optional_string(project, :project_id) || "", %{}))
      end)

    snapshot
    |> Map.put(:recent_reference_reason_codes, merge_safe_codes(value(snapshot, :recent_reference_reason_codes), value(source, :recent_reference_reason_codes)))
    |> Map.put(:recent_reference_action_codes, merge_safe_codes(value(snapshot, :recent_reference_action_codes), value(source, :recent_reference_action_codes)))
    |> Map.put(:safe_evidence_fingerprints, merge_fingerprints(value(snapshot, :safe_evidence_fingerprints), value(source, :safe_evidence_fingerprints)))
    |> maybe_put_safe(:safe_evidence_fingerprint, optional_string(source, :safe_evidence_fingerprint))
    |> Map.put(:projects, projects)
  end

  defp restore_project_safe_fields(project, source) when is_map(source) do
    project
    |> Map.put(:recent_reference_reason_codes, merge_safe_codes(value(project, :recent_reference_reason_codes), value(source, :recent_reference_reason_codes)))
    |> Map.put(:recent_reference_action_codes, merge_safe_codes(value(project, :recent_reference_action_codes), value(source, :recent_reference_action_codes)))
    |> Map.put(:provider_scope, restore_provider_scope(value(project, :provider_scope), value(source, :provider_scope)))
    |> Map.put(:safe_evidence_fingerprints, merge_fingerprints(value(project, :safe_evidence_fingerprints), value(source, :safe_evidence_fingerprints)))
    |> maybe_put_safe(:safe_evidence_fingerprint, optional_string(source, :safe_evidence_fingerprint))
    |> maybe_put_safe(:evidence_references, safe_maps(value(source, :evidence_references)))
  end

  defp restore_provider_scope(current, source) do
    case sanitize_map(current) do
      scope when scope != %{} -> scope
      _scope -> sanitize_map(source)
    end
  end

  defp merge_safe_codes(left, right), do: safe_codes(List.wrap(left) ++ List.wrap(right))

  defp merge_fingerprints(left, right), do: Map.merge(safe_fingerprint_map(left), safe_fingerprint_map(right))

  defp maybe_put_safe(map, _key, nil), do: map
  defp maybe_put_safe(map, _key, []), do: map
  defp maybe_put_safe(map, key, value), do: Map.put(map, key, value)

  defp conclusion_snapshot(%{chain_present?: true}, chain, generated_at) do
    CutoverClosureConclusion.build(chain, now: generated_at)
  end

  defp conclusion_snapshot(%{conclusion: conclusion}, chain, generated_at) when is_map(conclusion) do
    conclusion
    |> normalize_conclusion_snapshot(CutoverClosureConclusion.build(chain, now: generated_at), generated_at)
  end

  defp conclusion_snapshot(_source, chain, generated_at), do: CutoverClosureConclusion.build(chain, now: generated_at)

  defp normalize_conclusion_snapshot(conclusion, fallback, generated_at) do
    projects =
      conclusion
      |> list_value(:projects)
      |> Enum.map(&project_conclusion_snapshot/1)
      |> Enum.sort_by(&(optional_string(&1, :project_id) || ""))

    fallback =
      fallback
      |> Map.put(:projects, Enum.map(value(fallback, :projects) || [], &project_conclusion_snapshot/1))

    closure_chain_status =
      normalize_status(
        value(conclusion, :closure_chain_status) ||
          value(conclusion, :status) ||
          value(fallback, :closure_chain_status)
      )

    fallback_chain_count = non_negative_integer(value(fallback, :chain_count), 0)

    %{
      version:
        positive_integer(value(conclusion, :version)) ||
          positive_integer(value(fallback, :version)) ||
          @version,
      generated_at:
        iso8601(value(conclusion, :generated_at)) ||
          iso8601(value(fallback, :generated_at)) ||
          generated_at,
      evaluated_at:
        iso8601(value(conclusion, :evaluated_at)) ||
          iso8601(value(fallback, :evaluated_at)) ||
          generated_at,
      closure_chain_status: closure_chain_status,
      conclusion: safe_code(value(conclusion, :conclusion)) || value(fallback, :conclusion),
      severity: safe_code(value(conclusion, :severity)) || value(fallback, :severity),
      attention_level: safe_code(value(conclusion, :attention_level)) || value(fallback, :attention_level),
      summary_code: safe_code(value(conclusion, :summary_code)) || value(fallback, :summary_code),
      required_action_codes:
        safe_codes(value(conclusion, :required_action_codes))
        |> default_list(value(fallback, :required_action_codes) || ["none_required"]),
      blocked_by: safe_maps(value(conclusion, :blocked_by)) |> default_list(value(fallback, :blocked_by) || []),
      evidence_references:
        safe_maps(value(conclusion, :evidence_references))
        |> default_list(value(fallback, :evidence_references) || []),
      closure_status_counts:
        status_counts(
          value(conclusion, :closure_status_counts) ||
            value(fallback, :closure_status_counts),
          closure_chain_status
        ),
      reference_status_counts:
        reference_status_counts(
          value(conclusion, :reference_status_counts) ||
            value(fallback, :reference_status_counts)
        ),
      project_count: length(projects),
      chain_count: non_negative_integer(value(conclusion, :chain_count), fallback_chain_count),
      fully_closed: boolean_value(conclusion, :fully_closed, boolean_value(fallback, :fully_closed, false)),
      operation_success:
        boolean_value(
          conclusion,
          :operation_success,
          boolean_value(fallback, :operation_success, false)
        ),
      read_only: true,
      no_side_effects: true,
      actions_are_advisory: true,
      auto_retry_allowed: false,
      auto_replay_allowed: false,
      queued_replay: false,
      pending_execution: false,
      pending_retry: false,
      legacy_takeover: false,
      projects: if(projects == [], do: value(fallback, :projects) || [], else: projects),
      recent_chains: safe_maps(value(conclusion, :recent_chains)) |> default_list(value(fallback, :recent_chains) || [])
    }
  end

  defp project_conclusion_snapshot(project) do
    status = normalize_status(value(project, :closure_chain_status) || value(project, :status))

    %{
      project_id: optional_string(project, :project_id),
      provider_scope: sanitize_map(value(project, :provider_scope) || %{}),
      closure_chain_status: status,
      conclusion: safe_code(value(project, :conclusion)),
      severity: safe_code(value(project, :severity)),
      attention_level: safe_code(value(project, :attention_level)),
      summary_code: safe_code(value(project, :summary_code)),
      required_action_codes: safe_codes(value(project, :required_action_codes)),
      blocked_by: safe_maps(value(project, :blocked_by)),
      evidence_references: safe_maps(value(project, :evidence_references)),
      closure_status_counts:
        status_counts(
          value(project, :closure_status_counts) ||
            value(project, :counts),
          status
        ),
      reference_status_counts:
        reference_status_counts(
          value(project, :reference_status_counts) ||
            value(project, :counts)
        ),
      safe_evidence_fingerprints:
        safe_fingerprint_map(
          value(project, :safe_evidence_fingerprints) ||
            fingerprints_from_references(value(project, :evidence_references))
        ),
      safe_evidence_fingerprint: optional_string(project, :safe_evidence_fingerprint),
      reason_codes: safe_codes(value(project, :reason_codes)),
      action_codes: safe_codes(value(project, :action_codes)),
      fully_closed: boolean_value(project, :fully_closed, status in @closed_statuses),
      operation_success: boolean_value(project, :operation_success, status == "closed_succeeded"),
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
    |> compact_map()
  end

  defp project_packets(chain, conclusion) do
    chain_projects = Map.new(list_value(chain, :projects), &project_pair/1)
    conclusion_projects = Map.new(list_value(conclusion, :projects), &project_pair/1)

    (Map.keys(chain_projects) ++ Map.keys(conclusion_projects))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn project_id ->
      project_packet(project_id, Map.get(chain_projects, project_id, %{}), Map.get(conclusion_projects, project_id, %{}))
    end)
  end

  defp project_pair(project), do: {optional_string(project, :project_id) || "", project}

  defp project_packet(project_id, chain_project, conclusion_project) do
    status =
      normalize_status(
        value(conclusion_project, :closure_chain_status) ||
          value(chain_project, :status) ||
          value(chain_project, :closure_chain_status)
      )

    chain_section = project_closure_chain_section(chain_project, conclusion_project, status)
    evidence_references = safe_maps(value(conclusion_project, :evidence_references))

    safe_evidence_fingerprints =
      project_safe_evidence_fingerprints(chain_project, conclusion_project, evidence_references)

    safe_evidence_fingerprint =
      optional_string(conclusion_project, :safe_evidence_fingerprint) ||
        optional_string(chain_project, :safe_evidence_fingerprint) ||
        packet_fingerprint(%{
          project_id: project_id,
          status: status,
          evidence: safe_evidence_fingerprints,
          references: evidence_references
        })

    fully_closed =
      status in @closed_statuses and
        boolean_value(conclusion_project, :fully_closed, status in @closed_statuses)

    operation_success =
      status == "closed_succeeded" and
        boolean_value(conclusion_project, :operation_success, status == "closed_succeeded")

    %{
      project_id: project_id,
      provider_scope: project_provider_scope(chain_project, conclusion_project),
      report_status: report_status(status, fully_closed, operation_success),
      closure_chain_status: status,
      operator_conclusion: safe_code(value(conclusion_project, :conclusion)) || conclusion_for_status(status),
      severity: safe_code(value(conclusion_project, :severity)) || severity_for_status(status),
      attention_level: safe_code(value(conclusion_project, :attention_level)) || attention_for_status(status),
      summary_code: safe_code(value(conclusion_project, :summary_code)) || summary_for_status(status),
      required_action_codes:
        value(conclusion_project, :required_action_codes)
        |> safe_codes()
        |> normalize_required_actions(status),
      blocked_by: safe_maps(value(conclusion_project, :blocked_by)),
      evidence_references: evidence_references,
      safe_evidence_fingerprints: safe_evidence_fingerprints,
      safe_evidence_fingerprint: safe_evidence_fingerprint,
      closure_chain: chain_section,
      fully_closed: fully_closed,
      operation_success: operation_success,
      read_only_boundary: boundary_flags(),
      boundary_flags: boundary_flags()
    }
    |> sanitize_packet()
  end

  defp project_closure_chain_section(chain_project, conclusion_project, status) do
    reason_codes =
      [value(chain_project, :recent_reference_reason_codes), value(conclusion_project, :reason_codes)]
      |> List.flatten()
      |> safe_codes()

    action_codes =
      [value(chain_project, :recent_reference_action_codes), value(conclusion_project, :action_codes)]
      |> List.flatten()
      |> safe_codes()

    %{
      status: status,
      closure_status_counts:
        status_counts(
          value(chain_project, :counts) ||
            value(conclusion_project, :closure_status_counts),
          status
        ),
      retained_reference_status_counts:
        reference_status_counts(
          value(chain_project, :counts) ||
            value(conclusion_project, :reference_status_counts)
        ),
      reference_status_counts:
        reference_status_counts(
          value(chain_project, :counts) ||
            value(conclusion_project, :reference_status_counts)
        ),
      recent_reason_codes: reason_codes,
      recent_action_codes: action_codes,
      safe_evidence_fingerprints:
        safe_fingerprint_map(
          value(chain_project, :safe_evidence_fingerprints) ||
            value(conclusion_project, :safe_evidence_fingerprints) ||
            %{}
        ),
      safe_evidence_fingerprint:
        optional_string(chain_project, :safe_evidence_fingerprint) ||
          optional_string(conclusion_project, :safe_evidence_fingerprint)
    }
    |> put_section_fingerprint()
    |> compact_map()
  end

  defp device_packet(chain, conclusion, projects) do
    status = normalize_status(value(conclusion, :closure_chain_status) || value(chain, :status))
    fully_closed = device_fully_closed?(status, conclusion, projects)
    operation_success = device_operation_success?(status, conclusion, projects)
    report_status = report_status(status, fully_closed, operation_success)
    closure_chain = device_closure_chain_section(chain, conclusion, projects, status)

    %{
      report_status: report_status,
      closure_chain_status: status,
      operator_conclusion: safe_code(value(conclusion, :conclusion)) || conclusion_for_status(status),
      severity: safe_code(value(conclusion, :severity)) || severity_for_status(status),
      attention_level: safe_code(value(conclusion, :attention_level)) || attention_for_status(status),
      summary_code: safe_code(value(conclusion, :summary_code)) || summary_for_status(status),
      required_action_codes:
        value(conclusion, :required_action_codes)
        |> safe_codes()
        |> normalize_required_actions(status),
      blocked_by: safe_maps(value(conclusion, :blocked_by)),
      evidence_references: safe_maps(value(conclusion, :evidence_references)),
      closure_chain: closure_chain,
      section_statuses: %{
        closure_chain: status,
        operator_conclusion: safe_code(value(conclusion, :conclusion)) || conclusion_for_status(status)
      },
      project_count: length(projects),
      fully_closed: fully_closed,
      operation_success: operation_success,
      read_only_boundary: boundary_flags(),
      boundary_flags: boundary_flags()
    }
    |> sanitize_packet()
  end

  defp device_fully_closed?(_status, _conclusion, []), do: false

  defp device_fully_closed?(status, conclusion, projects) do
    status in @closed_statuses and
      boolean_value(conclusion, :fully_closed, false) and
      Enum.all?(projects, &(&1.fully_closed == true)) and
      not Enum.any?(projects, &(normalize_status(value(&1, :closure_chain_status)) not in @closed_statuses))
  end

  defp device_operation_success?(status, conclusion, projects) do
    status == "closed_succeeded" and
      boolean_value(conclusion, :operation_success, false) and
      projects != [] and
      Enum.all?(projects, &(&1.operation_success == true))
  end

  defp device_closure_chain_section(chain, conclusion, projects, status) do
    status_counts =
      value(conclusion, :closure_status_counts)
      |> Kernel.||(value(chain, :counts))
      |> status_counts(status)

    reference_counts =
      value(chain, :counts)
      |> Kernel.||(value(conclusion, :reference_status_counts))
      |> reference_status_counts()

    reason_codes =
      [value(chain, :recent_reference_reason_codes), value(conclusion, :reason_codes)]
      |> List.flatten()
      |> safe_codes()

    action_codes =
      [value(chain, :recent_reference_action_codes), value(conclusion, :action_codes)]
      |> List.flatten()
      |> safe_codes()

    %{
      status: normalize_status(value(chain, :status) || status),
      closure_status_counts: status_counts,
      status_counts: status_counts,
      retained_reference_status_counts: reference_counts,
      reference_status_counts: reference_counts,
      recent_reason_codes: reason_codes,
      recent_action_codes: action_codes,
      safe_evidence_fingerprint:
        packet_fingerprint(%{
          status: status,
          counts: status_counts,
          reference_counts: reference_counts,
          reason_codes: reason_codes,
          action_codes: action_codes,
          project_fingerprints: Enum.map(projects, &value(&1, :safe_evidence_fingerprint))
        }),
      read_only_boundary: boundary_flags()
    }
    |> compact_map()
  end

  defp report_status("closed_succeeded", true, true), do: "fully_closed"
  defp report_status("closed_succeeded", true, _operation_success), do: "closed_succeeded_review"
  defp report_status("closed_no_side_effect", true, _operation_success), do: "closed_no_side_effect"
  defp report_status("open_retryable", _fully_closed, _operation_success), do: "retry_consideration_required"
  defp report_status("open_manual_attention", _fully_closed, _operation_success), do: "manual_attention_required"
  defp report_status("stale", _fully_closed, _operation_success), do: "stale_evidence_review_required"
  defp report_status("conflict", _fully_closed, _operation_success), do: "conflict_review_required"
  defp report_status("malformed", _fully_closed, _operation_success), do: "malformed_input_review_required"
  defp report_status("unsupported", _fully_closed, _operation_success), do: "unsupported_report_slice"
  defp report_status("no_request", _fully_closed, _operation_success), do: "no_request"
  defp report_status(_status, _fully_closed, _operation_success), do: "no_chain"

  defp conclusion_for_status("closed_succeeded"), do: "closed_succeeded"
  defp conclusion_for_status("closed_no_side_effect"), do: "closed_no_side_effect"
  defp conclusion_for_status("open_retryable"), do: "waiting_explicit_retry_consideration"
  defp conclusion_for_status("open_manual_attention"), do: "manual_attention_required"
  defp conclusion_for_status("stale"), do: "evidence_stale_reaudit_required"
  defp conclusion_for_status("conflict"), do: "evidence_conflict_reaudit_required"
  defp conclusion_for_status("malformed"), do: "input_malformed"
  defp conclusion_for_status("unsupported"), do: "unsupported_closure_report_slice"
  defp conclusion_for_status("no_request"), do: "no_explicit_cutover_request"
  defp conclusion_for_status(_status), do: "no_explicit_closure_chain"

  defp severity_for_status("closed_succeeded"), do: "info"
  defp severity_for_status("closed_no_side_effect"), do: "notice"
  defp severity_for_status("open_retryable"), do: "warning"
  defp severity_for_status("open_manual_attention"), do: "warning"
  defp severity_for_status("conflict"), do: "error"
  defp severity_for_status("malformed"), do: "error"
  defp severity_for_status("stale"), do: "warning"
  defp severity_for_status("unsupported"), do: "warning"
  defp severity_for_status(_status), do: "none"

  defp attention_for_status("closed_succeeded"), do: "review"
  defp attention_for_status("closed_no_side_effect"), do: "review"
  defp attention_for_status("open_retryable"), do: "retry_consideration"
  defp attention_for_status("open_manual_attention"), do: "manual_attention"
  defp attention_for_status("conflict"), do: "audit_required"
  defp attention_for_status("malformed"), do: "input_fix_required"
  defp attention_for_status("stale"), do: "audit_required"
  defp attention_for_status("unsupported"), do: "unsupported"
  defp attention_for_status(_status), do: "none"

  defp summary_for_status("closed_succeeded"), do: "closure_closed_succeeded"
  defp summary_for_status("closed_no_side_effect"), do: "closure_closed_no_side_effect"
  defp summary_for_status("open_retryable"), do: "closure_open_retryable_waiting_explicit_consideration"
  defp summary_for_status("open_manual_attention"), do: "closure_open_manual_attention_required"
  defp summary_for_status("conflict"), do: "closure_evidence_conflict"
  defp summary_for_status("malformed"), do: "closure_input_malformed"
  defp summary_for_status("stale"), do: "closure_evidence_stale"
  defp summary_for_status("unsupported"), do: "closure_slice_unsupported"
  defp summary_for_status("no_request"), do: "closure_no_request"
  defp summary_for_status(_status), do: "closure_no_chain"

  defp normalize_required_actions([], "closed_succeeded"), do: ["review_success_evidence"]
  defp normalize_required_actions([], "closed_no_side_effect"), do: ["review_no_side_effect_evidence"]
  defp normalize_required_actions([], "open_retryable"), do: ["request_explicit_retry_consideration"]
  defp normalize_required_actions([], "open_manual_attention"), do: ["resolve_manual_attention"]
  defp normalize_required_actions([], "stale"), do: ["refresh_stale_evidence"]
  defp normalize_required_actions([], "conflict"), do: ["resolve_conflict"]
  defp normalize_required_actions([], "malformed"), do: ["fix_malformed_chain_input"]
  defp normalize_required_actions([], "unsupported"), do: ["unsupported_closure_report_slice"]
  defp normalize_required_actions([], _status), do: ["none_required"]

  defp normalize_required_actions(actions, _status) do
    non_none = Enum.reject(actions, &(&1 == "none_required"))
    if non_none == [], do: ["none_required"], else: non_none
  end

  defp project_provider_scope(chain_project, conclusion_project) do
    case sanitize_map(value(chain_project, :provider_scope)) do
      scope when scope != %{} -> scope
      _scope -> sanitize_map(value(conclusion_project, :provider_scope))
    end
  end

  defp project_safe_evidence_fingerprints(chain_project, conclusion_project, evidence_references) do
    [
      value(chain_project, :safe_evidence_fingerprints),
      value(conclusion_project, :safe_evidence_fingerprints),
      fingerprints_from_references(evidence_references)
    ]
    |> Enum.map(&safe_fingerprint_map/1)
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  defp fingerprints_from_references(references) do
    references
    |> List.wrap()
    |> Enum.flat_map(fn reference ->
      reference
      |> value(:safe_evidence_fingerprints)
      |> safe_fingerprint_map()
      |> Enum.to_list()
    end)
    |> Map.new()
  end

  defp put_section_fingerprint(section) do
    if bound?(value(section, :safe_evidence_fingerprint)) do
      section
    else
      Map.put(section, :safe_evidence_fingerprint, packet_fingerprint(Map.delete(section, :safe_evidence_fingerprint)))
    end
  end

  defp status_counts(counts, fallback_status) do
    source = counts || %{}

    counts =
      @statuses
      |> Map.new(fn status ->
        key = String.to_atom(status)

        count =
          non_negative_integer(value(source, "#{status}_count")) ||
            non_negative_integer(value(source, key)) ||
            0

        {key, count}
      end)

    if Enum.all?(counts, fn {_status, count} -> count == 0 end) do
      Map.put(counts, String.to_atom(normalize_status(fallback_status)), 1)
    else
      counts
    end
  end

  defp reference_status_counts(source) do
    source = source || %{}
    nested = value(source, :reference_status_counts) || source

    @reference_types
    |> Map.new(fn type ->
      key = String.to_atom(type)

      counts =
        value(source, "#{type}_reference_status_counts") ||
          value(source, key) ||
          value(nested, key) ||
          value(nested, type) ||
          %{}

      {key, reference_count_snapshot(counts)}
    end)
  end

  defp reference_count_snapshot(counts) do
    @reference_statuses
    |> Map.new(fn status ->
      key = String.to_atom(status)
      {key, non_negative_integer(value(counts, key), 0) || 0}
    end)
  end

  defp safe_maps(values) do
    values
    |> List.wrap()
    |> Enum.map(&sanitize_map/1)
    |> Enum.reject(&blank?/1)
  end

  defp safe_codes(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn
      value when is_list(value) -> value
      %{code: code} -> [code]
      %{"code" => code} -> [code]
      value -> [value]
    end)
    |> Enum.map(&safe_code/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp default_list([], fallback), do: List.wrap(fallback)
  defp default_list(list, _fallback), do: list

  defp normalize_existing_packet(packet, opts) do
    generated_at =
      opts
      |> Keyword.get(:now)
      |> iso8601()
      |> Kernel.||(iso8601(value(packet, :generated_at)))
      |> Kernel.||(DateTime.utc_now() |> DateTime.to_iso8601())

    packet
    |> sanitize_packet()
    |> Map.merge(%{
      version: @version,
      report_version: @version,
      generated_at: generated_at,
      read_only_boundary: boundary_flags(),
      boundary_flags: boundary_flags()
    })
  end

  defp sanitize_packet(value) when is_map(value) do
    value
    |> sanitize_map()
    |> Map.put(:read_only_boundary, boundary_flags())
  end

  defp sanitize_map(value) do
    value
    |> SafeSummary.sanitize_map(output_keys: :preserve, atom_values: :preserve)
    |> drop_unsafe_fields()
    |> drop_private_path_values()
  end

  defp safe_fingerprint_map(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {key, raw_value}, acc ->
      cond do
        unsafe_key?(key) or unsafe_value?(raw_value) ->
          acc

        is_map(raw_value) ->
          nested = safe_fingerprint_map(raw_value)
          if nested == %{}, do: acc, else: Map.put(acc, safe_key(key), nested)

        is_list(raw_value) ->
          values =
            raw_value
            |> Enum.reject(&unsafe_value?/1)
            |> Enum.map(&safe_scalar/1)
            |> Enum.reject(&blank?/1)

          if values == [], do: acc, else: Map.put(acc, safe_key(key), values)

        true ->
          case safe_scalar(raw_value) do
            nil -> acc
            value -> Map.put(acc, safe_key(key), value)
          end
      end
    end)
  end

  defp safe_fingerprint_map(_value), do: %{}

  defp safe_key(key) when is_atom(key), do: key
  defp safe_key(key) when is_binary(key), do: key
  defp safe_key(key), do: to_string(key)

  defp safe_scalar(value) when is_binary(value), do: optional_string(value)
  defp safe_scalar(value) when is_atom(value), do: value |> Atom.to_string() |> optional_string()
  defp safe_scalar(value) when is_number(value) or is_boolean(value), do: value
  defp safe_scalar(_value), do: nil

  defp unsafe_key?(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()

    SafeSummary.sensitive_key?(normalized) or
      Regex.match?(~r/(^|_)(raw_)?provider_?payload$/, normalized) or
      Regex.match?(~r/(^|_)(raw_)?payload$/, normalized)
  end

  defp unsafe_value?(value), do: SafeSummary.sensitive_value?(value) or private_path?(value)

  defp drop_unsafe_fields(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, raw_value} -> unsafe_key?(key) or unsafe_value?(raw_value) end)
    |> Enum.map(fn {key, raw_value} -> {key, drop_unsafe_fields(raw_value)} end)
    |> Map.new()
  end

  defp drop_unsafe_fields(value) when is_list(value) do
    value
    |> Enum.reject(&unsafe_value?/1)
    |> Enum.map(&drop_unsafe_fields/1)
  end

  defp drop_unsafe_fields(value), do: value

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

  defp packet_fingerprint(value) do
    value
    |> sanitize_map()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp boundary_flags, do: @boundary_flags

  defp normalize_status(status) do
    status = safe_code(status)
    if status in @statuses, do: status, else: "no_chain"
  end

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

  defp optional_string(value, key) when is_map(value), do: optional_string(value(value, key))
  defp optional_string(nil), do: nil

  defp optional_string(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      unsafe_value?(value) -> nil
      true -> value
    end
  end

  defp optional_string(value) when is_atom(value), do: value |> Atom.to_string() |> optional_string()
  defp optional_string(value), do: value |> to_string() |> optional_string()

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      _parse -> optional_string(value)
    end
  end

  defp iso8601(_value), do: nil

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

  defp list_value(map, key) do
    case value(map, key) do
      list when is_list(list) -> list
      nil -> []
      value -> List.wrap(value)
    end
  end

  defp boolean_value(map, key, default) do
    case raw_value(map, key) do
      value when is_boolean(value) -> value
      _value -> default
    end
  end

  defp raw_value(map, key) when is_map(map) and is_atom(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end

  defp raw_value(_map, _key), do: nil

  defp non_negative_integer(value), do: non_negative_integer(value, nil)
  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _parse -> default
    end
  end

  defp non_negative_integer(_value, default), do: default

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _parse -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(value) when is_map(value), do: map_size(value) == 0
  defp blank?(_value), do: false

  defp bound?(value), do: not blank?(optional_string(value))

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end
end
