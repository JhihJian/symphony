defmodule SymphonyElixir.Hub.ActivationPlan do
  @moduledoc """
  Builds safe Hub migration activation plan and operator acknowledgement summaries.

  This module is read-only. It consumes migration readiness/device summaries that
  are already safe for Dashboard/API output plus an explicit operator
  acknowledgement structure. It does not execute migration steps, edit config, or
  change Hub ownership.
  """

  @version 1
  @ack_version 1
  @plan_statuses [
    "plan_ready",
    "ack_required",
    "ack_stale",
    "ack_conflict",
    "blocked",
    "unknown_manual_attention",
    "already_managed"
  ]
  @ack_statuses ["missing", "accepted", "stale", "conflict", "malformed", "unsupported", "manual_attention"]
  @safety_gates [
    "activation_preflight",
    "legacy_ownership_guardrail",
    "provider_governance",
    "runtime_ledger",
    "executor_mode",
    "workspace_lease",
    "lifecycle_reconciliation"
  ]
  @sensitive_value_patterns [
    ~r/\$[A-Z0-9_]*(TOKEN|API_KEY|SECRET|CREDENTIAL)[A-Z0-9_]*/,
    ~r/\b(api[_-]?key|authorization|bearer|cookie|credential|secret|token|transcript|full prompt|codex transcript|raw provider response|raw systemd output|stacktrace|stack trace)\b/i,
    ~r/\b(ghp_|github_pat_|glpat-|sk-[A-Za-z0-9])/
  ]

  @type summary :: map()
  @type project_summary :: map()

  @spec build(term(), term(), term(), keyword()) :: summary()
  def build(readiness, projects, overview, opts \\ []) do
    generated_at =
      opts
      |> Keyword.get(:now)
      |> Kernel.||(value(readiness, :generated_at))
      |> Kernel.||(DateTime.utc_now())
      |> iso8601()

    readiness = readiness_snapshot(readiness)
    projects = safe_projects(projects)
    overview = map_or_empty(overview)
    hub_runtime = hub_runtime_snapshot(value(readiness, :hub_runtime), value(overview, :scheduler))
    ack_index = acknowledgement_index(Keyword.get(opts, :operator_acknowledgements) || Keyword.get(opts, :acknowledgements))

    project_plans =
      readiness
      |> list_value(:projects)
      |> Enum.map(fn readiness_project ->
        project = Enum.find(projects, &(required_string(&1, :project_id) == readiness_project.project_id)) || %{}
        safe_project_plan(readiness_project, project, hub_runtime, ack_index)
      end)
      |> Enum.sort_by(& &1.project_id)

    risks = global_risks(readiness, hub_runtime, project_plans, ack_index)

    %{
      version: @version,
      generated_at: generated_at,
      status: activation_status(project_plans, risks.blocking),
      hub_runtime: hub_runtime,
      counts: counts_snapshot(%{}, project_plans),
      global_blocking_risks: Enum.sort_by(risks.blocking, &{&1.code, &1.source || ""}),
      global_advisory_risks: Enum.sort_by(risks.advisory, &{&1.code, &1.source || ""}),
      safety_gates: @safety_gates,
      projects: project_plans
    }
    |> to_snapshot()
  end

  @spec to_snapshot(term()) :: summary()
  def to_snapshot(summary) when is_map(summary) do
    projects =
      summary
      |> list_value(:projects)
      |> Enum.map(&project_plan_snapshot/1)
      |> Enum.sort_by(& &1.project_id)

    %{
      version: positive_integer(value(summary, :version)) || @version,
      generated_at: iso8601(value(summary, :generated_at)) || iso8601(DateTime.utc_now()),
      status:
        normalize_plan_status(
          value(summary, :status),
          projects,
          reason_snapshots(value(summary, :global_blocking_risks), "blocking")
        ),
      hub_runtime: hub_runtime_snapshot(value(summary, :hub_runtime), %{}),
      counts: counts_snapshot(value(summary, :counts), projects),
      global_blocking_risks: reason_snapshots(value(summary, :global_blocking_risks), "blocking"),
      global_advisory_risks: reason_snapshots(value(summary, :global_advisory_risks), "advisory"),
      safety_gates: string_list(value(summary, :safety_gates)) |> Enum.reject(&blank?/1),
      projects: projects
    }
  end

  def to_snapshot(_summary), do: to_snapshot(%{})

  @spec project_plan_snapshot(term()) :: project_summary()
  def project_plan_snapshot(plan) when is_map(plan) do
    acknowledgement = acknowledgement_snapshot(value(plan, :operator_acknowledgement) || value(plan, :acknowledgement))
    required_acknowledgements = action_snapshots(value(plan, :required_acknowledgements))
    blocking = reason_snapshots(value(plan, :blocking_reasons), "blocking")
    advisory = reason_snapshots(value(plan, :advisory_reasons), "advisory")
    decision = normalize_readiness_decision(value(plan, :readiness_decision) || value(plan, :decision))
    migration_state = normalize_migration_state(value(plan, :migration_state))

    base = %{
      version: positive_integer(value(plan, :version)) || @version,
      project_id: required_string(plan, :project_id),
      provider: provider_snapshot(value(plan, :provider)),
      migration_state: migration_state,
      readiness_decision: decision,
      status:
        value(plan, :status)
        |> safe_status()
        |> case do
          status when status in @plan_statuses -> status
          _status -> project_plan_status(decision, acknowledgement.status)
        end,
      plan_id:
        optional_string(plan, :plan_id) ||
          fingerprint(%{
            project_id: required_string(plan, :project_id),
            provider: provider_snapshot(value(plan, :provider)),
            migration_state: migration_state,
            readiness_decision: decision,
            proposed_next_state: proposed_next_state(decision),
            required_acknowledgements: Enum.map(required_acknowledgements, & &1.code),
            blocking_reasons: fingerprint_reasons(blocking),
            advisory_reasons: fingerprint_reasons(advisory),
            evidence: stable_plan_evidence(sanitize_value(value(plan, :evidence) || %{}))
          }),
      proposed_next_state: normalize_proposed_next_state(value(plan, :proposed_next_state), decision),
      acknowledgement_required: value(plan, :acknowledgement_required) == true,
      required_acknowledgements: required_acknowledgements,
      blocking_reasons: blocking,
      advisory_reasons: advisory,
      evidence: sanitize_value(value(plan, :evidence) || %{}),
      hub_owned_actions_allowed: false,
      hub_owned_actions_remain_guarded_by: @safety_gates,
      operator_acknowledgement: acknowledgement
    }

    base
  end

  def project_plan_snapshot(_plan), do: project_plan_snapshot(%{})

  @spec activation_plan_only(term()) :: map()
  def activation_plan_only(plan) do
    plan
    |> project_plan_snapshot()
    |> Map.delete(:operator_acknowledgement)
  end

  @spec acknowledgement_snapshot(term()) :: map()
  def acknowledgement_snapshot(acknowledgement) when is_map(acknowledgement) do
    status = normalize_ack_status(value(acknowledgement, :status))

    %{
      status: status,
      required: value(acknowledgement, :required) == true,
      project_id: optional_string(acknowledgement, :project_id),
      plan_id: optional_string(acknowledgement, :plan_id),
      plan_id_matches: value(acknowledgement, :plan_id_matches) == true,
      source: safe_public_string(value(acknowledgement, :source)),
      created_at: iso8601(value(acknowledgement, :created_at)),
      acknowledged_codes: code_list(value(acknowledgement, :acknowledged_codes)),
      acknowledged_action_codes: code_list(value(acknowledgement, :acknowledged_action_codes)),
      acknowledged_risk_codes: code_list(value(acknowledgement, :acknowledged_risk_codes)),
      missing_acknowledgements: code_list(value(acknowledgement, :missing_acknowledgements)),
      stale_reasons: code_list(value(acknowledgement, :stale_reasons)),
      conflict_reasons: code_list(value(acknowledgement, :conflict_reasons)),
      malformed_reasons: code_list(value(acknowledgement, :malformed_reasons)),
      unsupported_reasons: code_list(value(acknowledgement, :unsupported_reasons)),
      manual_attention_reasons: code_list(value(acknowledgement, :manual_attention_reasons)),
      note_summary:
        normalize_note_summary(value(acknowledgement, :note_summary)) ||
          normalize_note_summary(value(acknowledgement, :note))
    }
  end

  def acknowledgement_snapshot(_acknowledgement) do
    %{
      status: "missing",
      required: false,
      project_id: nil,
      plan_id: nil,
      plan_id_matches: false,
      source: nil,
      created_at: nil,
      acknowledged_codes: [],
      acknowledged_action_codes: [],
      acknowledged_risk_codes: [],
      missing_acknowledgements: [],
      stale_reasons: [],
      conflict_reasons: [],
      malformed_reasons: [],
      unsupported_reasons: [],
      manual_attention_reasons: [],
      note_summary: nil
    }
  end

  defp safe_project_plan(readiness_project, project, hub_runtime, ack_index) do
    project_plan(readiness_project, project, hub_runtime, ack_index)
  rescue
    _error ->
      summary_error_plan(required_string(readiness_project, :project_id), "activation_plan_summary_error")
  end

  defp project_plan(readiness_project, project, hub_runtime, ack_index) do
    project_id = required_string(readiness_project, :project_id)
    decision = normalize_readiness_decision(value(readiness_project, :decision))
    migration_state = normalize_migration_state(value(readiness_project, :migration_state))
    provider = provider_snapshot(value(project, :provider) || get_in_map(project, [:detail, :identity]))
    blocking = reason_snapshots(value(readiness_project, :blocking_reasons), "blocking")
    advisory = reason_snapshots(value(readiness_project, :advisory_reasons), "advisory")
    required_acknowledgements = action_snapshots(value(readiness_project, :required_operator_actions))
    evidence = sanitize_value(value(readiness_project, :evidence) || %{})
    proposed_next_state = proposed_next_state(decision)

    plan_id =
      fingerprint(%{
        version: @version,
        project_id: project_id,
        provider: provider,
        migration_state: migration_state,
        readiness_decision: decision,
        proposed_next_state: proposed_next_state,
        required_acknowledgements: Enum.map(required_acknowledgements, & &1.code),
        blocking_reasons: fingerprint_reasons(blocking),
        advisory_reasons: fingerprint_reasons(advisory),
        evidence: stable_plan_evidence(evidence),
        hub_runtime: runtime_fingerprint(hub_runtime)
      })

    acknowledgement_required = decision == "ready_for_hub_management"

    plan = %{
      version: @version,
      project_id: project_id,
      provider: provider,
      migration_state: migration_state,
      readiness_decision: decision,
      plan_id: plan_id,
      proposed_next_state: proposed_next_state,
      acknowledgement_required: acknowledgement_required,
      required_acknowledgements: required_acknowledgements,
      blocking_reasons: blocking,
      advisory_reasons: advisory,
      evidence: evidence,
      hub_owned_actions_allowed: false,
      hub_owned_actions_remain_guarded_by: @safety_gates
    }

    acknowledgement = evaluate_acknowledgement(plan, Map.get(ack_index.by_project, project_id), acknowledgement_required)
    Map.merge(plan, %{status: project_plan_status(decision, acknowledgement.status), operator_acknowledgement: acknowledgement})
  end

  defp summary_error_plan(project_id, code) do
    reason = reason_snapshot(%{code: code, source: "activation_plan", evidence: %{project_id: project_id}}, "blocking")

    project_plan_snapshot(%{
      project_id: project_id,
      readiness_decision: "unknown_manual_attention",
      status: "unknown_manual_attention",
      blocking_reasons: [reason],
      required_acknowledgements: [%{code: "inspect_summary_error"}],
      evidence: %{summary_error: %{code: code, source: "activation_plan"}},
      operator_acknowledgement: %{status: "manual_attention", manual_attention_reasons: [code]}
    })
  end

  defp evaluate_acknowledgement(plan, nil, required?) do
    acknowledgement_snapshot(%{
      status: "missing",
      required: required?,
      project_id: plan.project_id,
      missing_acknowledgements: if(required?, do: Enum.map(plan.required_acknowledgements, & &1.code), else: [])
    })
  end

  defp evaluate_acknowledgement(plan, ack, required?) do
    ack = normalize_acknowledgement(ack)

    status_and_reasons =
      cond do
        ack.status == "unsupported" or ack.unsupported_reasons != [] ->
          {"unsupported", %{unsupported_reasons: ack.unsupported_reasons}}

        ack.status == "malformed" or ack.malformed_reasons != [] ->
          {"malformed", %{malformed_reasons: ack.malformed_reasons}}

        ack.status == "manual_attention" or ack.manual_attention_reasons != [] ->
          {"manual_attention", %{manual_attention_reasons: ack.manual_attention_reasons}}

        ack.project_id != plan.project_id ->
          {"conflict", %{conflict_reasons: ["project_id_mismatch"]}}

        not blank?(ack.provider_scope_key) and ack.provider_scope_key != provider_scope_key(plan.provider) ->
          {"conflict", %{conflict_reasons: ["provider_scope_mismatch"]}}

        not blank?(ack.migration_state) and ack.migration_state != plan.migration_state ->
          {"conflict", %{conflict_reasons: ["migration_state_mismatch"]}}

        not blank?(ack.readiness_decision) and ack.readiness_decision != plan.readiness_decision ->
          {"conflict", %{conflict_reasons: ["readiness_decision_mismatch"]}}

        ack.plan_id != plan.plan_id ->
          {"stale", %{stale_reasons: ["plan_id_mismatch"]}}

        plan.readiness_decision in ["blocked", "unknown_manual_attention"] ->
          {"manual_attention", %{manual_attention_reasons: ["plan_not_ready_for_ack_acceptance"]}}

        missing_acknowledgement_codes(plan, ack) != [] ->
          {"conflict", %{conflict_reasons: ["acknowledged_codes_incomplete"], missing_acknowledgements: missing_acknowledgement_codes(plan, ack)}}

        true ->
          {"accepted", %{}}
      end

    {status, reason_fields} = status_and_reasons

    ack
    |> Map.merge(%{
      status: status,
      required: required?,
      plan_id_matches: ack.plan_id == plan.plan_id,
      missing_acknowledgements: []
    })
    |> Map.merge(reason_fields)
    |> acknowledgement_snapshot()
  end

  defp missing_acknowledgement_codes(plan, ack) do
    required_codes =
      plan.required_acknowledgements
      |> Enum.map(& &1.code)
      |> MapSet.new()

    acknowledged_codes =
      (ack.acknowledged_codes ++ ack.acknowledged_action_codes)
      |> MapSet.new()

    required_codes
    |> MapSet.difference(acknowledged_codes)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp normalize_acknowledgement(raw_ack) when is_map(raw_ack) do
    raw_version = value(raw_ack, :version)
    version = positive_integer(raw_version) || @ack_version
    explicit_status = normalize_ack_status(value(raw_ack, :status))
    project_id = required_string(raw_ack, :project_id)
    plan_id = optional_string(raw_ack, :plan_id) || optional_string(raw_ack, :readiness_fingerprint)
    source = safe_public_string(value(raw_ack, :source))
    created_at = parse_datetime(value(raw_ack, :created_at) || value(raw_ack, :acknowledged_at))

    acknowledged_action_codes =
      code_list(value(raw_ack, :acknowledged_action_codes)) ++
        code_list(value(raw_ack, :action_codes)) ++
        code_list(value(raw_ack, :confirmed_action_codes))

    acknowledged_risk_codes =
      code_list(value(raw_ack, :acknowledged_risk_codes)) ++
        code_list(value(raw_ack, :risk_codes)) ++
        code_list(value(raw_ack, :confirmed_risk_codes))

    acknowledged_codes =
      code_list(value(raw_ack, :acknowledged_codes)) ++
        code_list(value(raw_ack, :confirmed_codes)) ++
        acknowledged_action_codes ++
        acknowledged_risk_codes

    malformed_reasons =
      []
      |> add_code_reason(blank?(project_id), "project_id_missing")
      |> add_code_reason(blank?(plan_id), "plan_id_missing")
      |> add_code_reason(blank?(source), "source_missing")
      |> add_code_reason(is_nil(created_at), "created_at_invalid")

    unsupported_reasons =
      []
      |> add_code_reason(version > @ack_version or unsupported_version_value?(raw_version), "acknowledgement_version_unsupported")
      |> Kernel.++(code_list(value(raw_ack, :unsupported_reasons)))

    malformed_reasons = malformed_reasons ++ code_list(value(raw_ack, :malformed_reasons))
    manual_attention_reasons = code_list(value(raw_ack, :manual_attention_reasons))

    status =
      cond do
        explicit_status in ["malformed", "unsupported", "manual_attention"] ->
          explicit_status

        unsupported_reasons != [] ->
          "unsupported"

        malformed_reasons != [] ->
          "malformed"

        true ->
          "accepted"
      end

    acknowledgement_snapshot(%{
      status: status,
      project_id: project_id,
      plan_id: plan_id,
      source: source,
      created_at: created_at,
      acknowledged_codes: acknowledged_codes,
      acknowledged_action_codes: acknowledged_action_codes,
      acknowledged_risk_codes: acknowledged_risk_codes,
      malformed_reasons: malformed_reasons,
      unsupported_reasons: unsupported_reasons,
      manual_attention_reasons: manual_attention_reasons,
      note_summary: normalize_note_summary(value(raw_ack, :note_summary)) || note_summary(value(raw_ack, :note)),
      provider_scope_key: optional_string(raw_ack, :provider_scope_key),
      migration_state: normalize_optional_migration_state(value(raw_ack, :migration_state)),
      readiness_decision: normalize_optional_readiness_decision(value(raw_ack, :readiness_decision))
    })
    |> Map.put(:provider_scope_key, optional_string(raw_ack, :provider_scope_key))
    |> Map.put(:migration_state, normalize_optional_migration_state(value(raw_ack, :migration_state)))
    |> Map.put(:readiness_decision, normalize_optional_readiness_decision(value(raw_ack, :readiness_decision)))
  end

  defp normalize_acknowledgement(_raw_ack) do
    acknowledgement_snapshot(%{status: "malformed", malformed_reasons: ["acknowledgement_not_map"]})
  end

  defp unsupported_version_value?(value) when is_integer(value), do: value > @ack_version

  defp unsupported_version_value?(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number > @ack_version
      _parse -> true
    end
  end

  defp unsupported_version_value?(nil), do: false
  defp unsupported_version_value?(_value), do: true

  defp acknowledgement_index(raw) do
    entries = acknowledgement_entries(raw)

    {by_project, global_errors} =
      Enum.reduce(entries, {%{}, []}, fn entry, {projects, errors} ->
        ack = normalize_acknowledgement(entry)

        if blank?(ack.project_id) do
          {projects, [reason_snapshot(%{code: "operator_acknowledgement_unscoped", source: "operator_acknowledgement"}, "advisory") | errors]}
        else
          {Map.update(projects, ack.project_id, ack, &newer_ack(&1, ack)), errors}
        end
      end)

    %{by_project: by_project, global_errors: global_errors}
  end

  defp acknowledgement_entries(nil), do: []

  defp acknowledgement_entries(raw) when is_list(raw), do: raw

  defp acknowledgement_entries(raw) when is_map(raw) do
    cond do
      is_list(value(raw, :acknowledgements)) ->
        value(raw, :acknowledgements)

      is_list(value(raw, :projects)) ->
        value(raw, :projects)

      not blank?(optional_string(raw, :project_id)) ->
        [raw]

      true ->
        raw
        |> Enum.flat_map(fn {project_id, value} ->
          if is_map(value) do
            [Map.put_new(value, "project_id", optional_string(project_id))]
          else
            []
          end
        end)
    end
  end

  defp acknowledgement_entries(_raw), do: [%{status: "malformed"}]

  defp newer_ack(current, candidate) do
    case {parse_datetime(current.created_at), parse_datetime(candidate.created_at)} do
      {%DateTime{} = current_at, %DateTime{} = candidate_at} ->
        if DateTime.compare(candidate_at, current_at) == :gt, do: candidate, else: current

      {_current_at, %DateTime{}} ->
        candidate

      _other ->
        current
    end
  end

  defp global_risks(readiness, hub_runtime, _project_plans, ack_index) do
    blocking =
      readiness
      |> list_value(:global_blocking_risks)
      |> reason_snapshots("blocking")
      |> Kernel.++(runtime_blocking_risks(hub_runtime))

    advisory =
      readiness
      |> list_value(:global_advisory_risks)
      |> reason_snapshots("advisory")
      |> Kernel.++(ack_index.global_errors)

    %{
      blocking: Enum.uniq_by(blocking, &{&1.code, &1.source, inspect(&1.evidence)}),
      advisory: Enum.uniq_by(advisory, &{&1.code, &1.source, inspect(&1.evidence)})
    }
  end

  defp runtime_blocking_risks(hub_runtime) do
    []
    |> add_reason(hub_runtime.enabled != true, "hub_runtime_not_enabled", "hub_runtime", %{mode: hub_runtime.mode})
    |> add_reason(hub_runtime.scheduler_enabled != true, "scheduler_disabled", "scheduler", %{status: hub_runtime.scheduler_status})
    |> add_reason(not host_service_probe_enabled?(hub_runtime.activation_probe), "activation_probe_not_host_service", "activation_preflight", hub_runtime.activation_probe)
  end

  defp activation_status(project_plans, global_blocking_risks) do
    cond do
      global_blocking_risks != [] or Enum.any?(project_plans, &(&1.status == "blocked")) ->
        "blocked"

      Enum.any?(project_plans, &(&1.status == "unknown_manual_attention")) ->
        "unknown_manual_attention"

      Enum.any?(project_plans, &(&1.status == "ack_conflict")) ->
        "ack_conflict"

      Enum.any?(project_plans, &(&1.status == "ack_stale")) ->
        "ack_stale"

      Enum.any?(project_plans, &(&1.status == "ack_required")) ->
        "ack_required"

      Enum.any?(project_plans, &(&1.status == "plan_ready")) ->
        "plan_ready"

      Enum.any?(project_plans, &(&1.status == "already_managed")) ->
        "already_managed"

      true ->
        "unknown_manual_attention"
    end
  end

  defp normalize_plan_status(status, projects, global_blocking_risks) do
    normalized = safe_status(status)

    if normalized in @plan_statuses do
      normalized
    else
      activation_status(projects, global_blocking_risks)
    end
  end

  defp project_plan_status("blocked", _ack_status), do: "blocked"
  defp project_plan_status("unknown_manual_attention", _ack_status), do: "unknown_manual_attention"
  defp project_plan_status("already_hub_managed", _ack_status), do: "already_managed"
  defp project_plan_status("ready_for_hub_management", "accepted"), do: "plan_ready"
  defp project_plan_status("ready_for_hub_management", "missing"), do: "ack_required"
  defp project_plan_status("ready_for_hub_management", "stale"), do: "ack_stale"
  defp project_plan_status("ready_for_hub_management", "conflict"), do: "ack_conflict"
  defp project_plan_status("ready_for_hub_management", _ack_status), do: "unknown_manual_attention"
  defp project_plan_status(_decision, "stale"), do: "ack_stale"
  defp project_plan_status(_decision, "conflict"), do: "ack_conflict"
  defp project_plan_status(_decision, _ack_status), do: "plan_ready"

  defp counts_snapshot(counts, projects) when is_map(counts) do
    plan_status_counts =
      Enum.reduce(projects, Map.new(@plan_statuses, &{String.to_atom(&1), 0}), fn project, acc ->
        key = project.status |> normalize_project_status_key() |> String.to_existing_atom()
        Map.update!(acc, key, &(&1 + 1))
      end)

    ack_status_counts =
      Enum.reduce(projects, Map.new(@ack_statuses, &{String.to_atom(&1), 0}), fn project, acc ->
        key = project.operator_acknowledgement.status |> normalize_ack_status() |> String.to_existing_atom()
        Map.update!(acc, key, &(&1 + 1))
      end)

    %{
      project_count: non_negative_integer(value(counts, :project_count)) || length(projects),
      plan_statuses: plan_status_counts,
      acknowledgement_statuses: ack_status_counts,
      plan_ready_count: plan_status_counts.plan_ready,
      ack_required_count: plan_status_counts.ack_required,
      ack_stale_count: plan_status_counts.ack_stale,
      ack_conflict_count: plan_status_counts.ack_conflict,
      blocked_count: plan_status_counts.blocked,
      unknown_manual_attention_count: plan_status_counts.unknown_manual_attention,
      already_managed_count: plan_status_counts.already_managed,
      ack_accepted_count: ack_status_counts.accepted,
      ack_missing_count: ack_status_counts.missing,
      ack_malformed_count: ack_status_counts.malformed,
      ack_unsupported_count: ack_status_counts.unsupported,
      ack_manual_attention_count: ack_status_counts.manual_attention
    }
  end

  defp counts_snapshot(_counts, projects), do: counts_snapshot(%{}, projects)

  defp normalize_project_status_key(status) do
    status = safe_status(status)
    if status in @plan_statuses, do: status, else: "unknown_manual_attention"
  end

  defp readiness_snapshot(readiness) when is_map(readiness) do
    %{
      version: positive_integer(value(readiness, :version)) || 1,
      generated_at: iso8601(value(readiness, :generated_at)),
      status: normalize_readiness_decision(value(readiness, :status)),
      hub_runtime: value(readiness, :hub_runtime) || %{},
      counts: sanitize_value(value(readiness, :counts) || %{}),
      global_blocking_risks: reason_snapshots(value(readiness, :global_blocking_risks), "blocking"),
      global_advisory_risks: reason_snapshots(value(readiness, :global_advisory_risks), "advisory"),
      projects:
        readiness
        |> list_value(:projects)
        |> Enum.map(fn project ->
          %{
            project_id: required_string(project, :project_id),
            migration_state: normalize_migration_state(value(project, :migration_state)),
            decision: normalize_readiness_decision(value(project, :decision)),
            blocking_reasons: reason_snapshots(value(project, :blocking_reasons), "blocking"),
            advisory_reasons: reason_snapshots(value(project, :advisory_reasons), "advisory"),
            required_operator_actions: action_snapshots(value(project, :required_operator_actions)),
            evidence: sanitize_value(value(project, :evidence) || %{})
          }
        end)
    }
  end

  defp readiness_snapshot(_readiness), do: readiness_snapshot(%{})

  defp safe_projects(projects) when is_list(projects), do: Enum.filter(projects, &is_map/1)
  defp safe_projects(_projects), do: []

  defp hub_runtime_snapshot(runtime, scheduler) do
    runtime = map_or_empty(runtime)
    scheduler = map_or_empty(scheduler)

    %{
      enabled: value(runtime, :enabled) != false,
      mode: optional_string(runtime, :mode) || "hub",
      read_only: truthy?(value(runtime, :read_only)),
      scheduler_enabled: value(runtime, :scheduler_enabled) == true or value(scheduler, :enabled) == true,
      scheduler_status:
        runtime
        |> value(:scheduler_status)
        |> Kernel.||(value(scheduler, :status))
        |> safe_status()
        |> blank_to_default("disabled"),
      provider_executor: sanitize_value(value(runtime, :provider_executor) || %{}),
      writeback_executor: sanitize_value(value(runtime, :writeback_executor) || %{}),
      worker_starter: sanitize_value(value(runtime, :worker_starter) || %{}),
      activation_probe: sanitize_value(value(runtime, :activation_probe) || %{})
    }
  end

  defp runtime_fingerprint(runtime) do
    %{
      enabled: runtime.enabled,
      mode: runtime.mode,
      read_only: runtime.read_only,
      scheduler_enabled: runtime.scheduler_enabled,
      provider_executor: value(runtime.provider_executor, :mode),
      writeback_executor: value(runtime.writeback_executor, :mode),
      worker_starter: value(runtime.worker_starter, :mode),
      activation_probe: value(runtime.activation_probe, :mode) || value(runtime.activation_probe, :source)
    }
  end

  defp provider_snapshot(provider) when is_map(provider) do
    %{
      kind: optional_string(provider, :kind) || optional_string(provider, :provider_kind),
      provider_scope_key: optional_string(provider, :provider_scope_key),
      scope: sanitize_value(value(provider, :scope) || value(provider, :provider_scope) || %{})
    }
  end

  defp provider_snapshot(_provider), do: provider_snapshot(%{})

  defp provider_scope_key(provider), do: optional_string(provider, :provider_scope_key)

  defp proposed_next_state("legacy_only"), do: "keep_legacy_only"
  defp proposed_next_state("ready_for_dry_run"), do: "continue_dry_run"
  defp proposed_next_state("ready_for_hub_management"), do: "operator_may_mark_hub_managed_after_checks"
  defp proposed_next_state("already_hub_managed"), do: "already_managed"
  defp proposed_next_state("blocked"), do: "blocked_manual_attention"
  defp proposed_next_state("unknown_manual_attention"), do: "manual_attention_required"

  defp normalize_proposed_next_state(value, decision) do
    value
    |> safe_status()
    |> case do
      "" -> proposed_next_state(decision)
      state -> state
    end
  end

  defp reason_snapshots(reasons, default_level) when is_list(reasons) do
    reasons
    |> Enum.map(&reason_snapshot(&1, default_level))
    |> Enum.reject(&blank?(&1.code))
    |> Enum.uniq_by(&{&1.code, &1.source, inspect(&1.evidence)})
    |> Enum.sort_by(&{&1.code, &1.source || ""})
  end

  defp reason_snapshots(_reasons, _default_level), do: []

  defp reason_snapshot(reason, default_level) when is_map(reason) do
    %{
      code: safe_status(value(reason, :code) || value(reason, :reason)) |> blank_to_default("unknown"),
      label: optional_string(reason, :label) || label_for(value(reason, :code) || value(reason, :reason)),
      source: optional_string(reason, :source),
      level: normalize_level(value(reason, :level), default_level),
      blocks_hub_management: value(reason, :blocks_hub_management) != false,
      evidence: sanitize_value(value(reason, :evidence) || %{})
    }
  end

  defp reason_snapshot(reason, default_level), do: reason_snapshot(%{code: reason}, default_level)

  defp action_snapshots(actions) when is_list(actions) do
    actions
    |> Enum.map(&action_snapshot/1)
    |> Enum.reject(&blank?(&1.code))
    |> Enum.uniq_by(& &1.code)
    |> Enum.sort_by(& &1.code)
  end

  defp action_snapshots(_actions), do: []

  defp action_snapshot(action) when is_map(action) do
    code = safe_status(value(action, :code))
    %{code: code, label: optional_string(action, :label) || label_for(code)}
  end

  defp action_snapshot(action), do: action_snapshot(%{code: action})

  defp normalize_level(value, default_level) do
    value
    |> safe_status()
    |> blank_to_default(default_level)
    |> case do
      "blocking" -> "blocking"
      "advisory" -> "advisory"
      _other -> default_level
    end
  end

  defp normalize_readiness_decision(value) do
    case safe_status(value) do
      "legacy_only" -> "legacy_only"
      "ready_for_dry_run" -> "ready_for_dry_run"
      "ready_for_hub_management" -> "ready_for_hub_management"
      "already_hub_managed" -> "already_hub_managed"
      "blocked" -> "blocked"
      "unknown_manual_attention" -> "unknown_manual_attention"
      "manual_attention" -> "unknown_manual_attention"
      _other -> "unknown_manual_attention"
    end
  end

  defp normalize_optional_readiness_decision(nil), do: nil
  defp normalize_optional_readiness_decision(value), do: normalize_readiness_decision(value)

  defp normalize_migration_state(value) do
    case safe_status(value) do
      "legacy_only" -> "legacy_only"
      "hub_managed" -> "hub_managed"
      "hub_ready" -> "hub_ready"
      _other -> "hub_ready"
    end
  end

  defp normalize_optional_migration_state(nil), do: nil
  defp normalize_optional_migration_state(value), do: normalize_migration_state(value)

  defp normalize_ack_status(value) do
    value = safe_status(value)
    if value in @ack_statuses, do: value, else: "missing"
  end

  defp host_service_probe_enabled?(probe) when is_map(probe) do
    truthy?(value(probe, :host_service_probe)) or optional_string(probe, :source) == "host_service_probe" or
      optional_string(probe, :mode) == "host_service"
  end

  defp host_service_probe_enabled?(_probe), do: false

  defp add_reason(reasons, true, code, source, evidence), do: [reason_snapshot(%{code: code, source: source, evidence: evidence}, "blocking") | reasons]
  defp add_reason(reasons, _condition, _code, _source, _evidence), do: reasons

  defp add_code_reason(reasons, true, code), do: [code | reasons]
  defp add_code_reason(reasons, _condition, _code), do: reasons

  defp label_for(value) do
    value
    |> safe_status()
    |> String.replace("_", " ")
  end

  defp fingerprint(payload) do
    :crypto.hash(:sha256, :erlang.term_to_binary(payload))
    |> Base.encode16(case: :lower)
  end

  defp fingerprint_evidence(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, _value} -> volatile_fingerprint_key?(normalize_key(key)) end)
    |> Map.new(fn {key, nested_value} -> {key, fingerprint_evidence(nested_value)} end)
  end

  defp fingerprint_evidence(value) when is_list(value), do: Enum.map(value, &fingerprint_evidence/1)
  defp fingerprint_evidence(value), do: value

  defp stable_plan_evidence(evidence) when is_map(evidence) do
    %{
      "activation_preflight" =>
        evidence
        |> value(:activation_preflight)
        |> take_fingerprint_keys([
          "status",
          "safe_to_manage",
          "reason",
          "probe_source",
          "blocked_operations",
          "conflict_count",
          "manual_attention_count",
          "detected_legacy_ownership_count",
          "unknown_probe_result_count"
        ]),
      "config" =>
        evidence
        |> value(:config)
        |> take_fingerprint_keys(["config_fingerprint", "snapshot_version", "load_error"]),
      "hub_runtime" => stable_runtime_evidence(value(evidence, :hub_runtime)),
      "registry" =>
        evidence
        |> value(:registry)
        |> take_fingerprint_keys(["dispatch_enabled", "migration_state"])
    }
    |> fingerprint_evidence()
  end

  defp stable_plan_evidence(_evidence), do: %{}

  defp stable_runtime_evidence(runtime) when is_map(runtime) do
    %{
      "mode" => value(runtime, :mode),
      "read_only" => value(runtime, :read_only),
      "scheduler_enabled" => value(runtime, :scheduler_enabled),
      "provider_executor" => executor_fingerprint_evidence(value(runtime, :provider_executor)),
      "writeback_executor" => executor_fingerprint_evidence(value(runtime, :writeback_executor)),
      "worker_starter" => take_fingerprint_keys(value(runtime, :worker_starter), ["mode", "worker_start"]),
      "activation_probe" => take_fingerprint_keys(value(runtime, :activation_probe), ["mode", "source", "host_service_probe"])
    }
  end

  defp stable_runtime_evidence(_runtime), do: %{}

  defp executor_fingerprint_evidence(executor) do
    take_fingerprint_keys(executor, [
      "mode",
      "provider_io",
      "supported_operations",
      "supported_logical_actions",
      "rejected_operations"
    ])
  end

  defp take_fingerprint_keys(map, keys) when is_map(map) do
    Map.new(keys, fn key -> {key, value(map, key)} end)
  end

  defp take_fingerprint_keys(_map, keys), do: Map.new(keys, &{&1, nil})

  defp fingerprint_reasons(reasons) do
    Enum.map(reasons, fn reason ->
      Map.update(reason, :evidence, %{}, &fingerprint_evidence/1)
    end)
  end

  defp volatile_fingerprint_key?(key) do
    key in ["generated_at", "loaded_at", "checked_at", "next_due_at", "backoff_until", "created_at", "scheduler_status"] or
      String.ends_with?(key, "_at")
  end

  defp sanitize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp sanitize_value(%_struct{} = value), do: value |> Map.from_struct() |> sanitize_value()

  defp sanitize_value(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {raw_key, raw_value}, sanitized ->
      key = normalize_key(raw_key)

      if sensitive_key?(key) or sensitive_string?(raw_value) do
        sanitized
      else
        Map.put(sanitized, key, sanitize_value(raw_value))
      end
    end)
  end

  defp sanitize_value(value) when is_list(value) do
    value
    |> Enum.reject(&sensitive_string?/1)
    |> Enum.map(&sanitize_value/1)
  end

  defp sanitize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_value(value), do: value

  defp sensitive_key?(key) do
    key = String.downcase(key)

    String.contains?(key, "raw_") or String.contains?(key, "token") or String.contains?(key, "secret") or
      String.contains?(key, "authorization") or String.contains?(key, "cookie") or String.contains?(key, "transcript") or
      String.contains?(key, "prompt") or String.contains?(key, "stack")
  end

  defp sensitive_string?(value) when is_binary(value) do
    Enum.any?(@sensitive_value_patterns, &Regex.match?(&1, value))
  end

  defp sensitive_string?(_value), do: false

  defp note_summary(nil), do: nil

  defp note_summary(%{note_sha256: hash, note_bytes: bytes}) do
    %{note_sha256: optional_string(hash), note_bytes: non_negative_integer(bytes)}
  end

  defp note_summary(%{"note_sha256" => hash, "note_bytes" => bytes}) do
    %{note_sha256: optional_string(hash), note_bytes: non_negative_integer(bytes)}
  end

  defp note_summary(note) when is_binary(note) do
    %{
      note_sha256: fingerprint(note),
      note_bytes: byte_size(note)
    }
  end

  defp note_summary(_note), do: nil

  defp normalize_note_summary(note) when is_map(note) do
    case {optional_string(note, :note_sha256), non_negative_integer(value(note, :note_bytes))} do
      {hash, bytes} when is_binary(hash) and is_integer(bytes) -> %{note_sha256: hash, note_bytes: bytes}
      _other -> note_summary(note)
    end
  end

  defp normalize_note_summary(note), do: note_summary(note)

  defp code_list(value) when is_list(value) do
    value
    |> Enum.map(&safe_status/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp code_list(value) do
    case safe_status(value) do
      "" -> []
      code -> [code]
    end
  end

  defp string_list(value) when is_list(value) do
    value
    |> Enum.map(&optional_string/1)
    |> Enum.reject(&blank?/1)
  end

  defp string_list(_value), do: []

  defp get_in_map(map, keys) do
    Enum.reduce_while(keys, map, fn key, current ->
      case value(current, key) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
  end

  defp map_or_empty(map) when is_map(map), do: map
  defp map_or_empty(_map), do: %{}

  defp list_value(map, key) do
    case value(map, key) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  defp value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, nil} -> Map.get(map, Atom.to_string(key))
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key)
  end

  defp value(_map, _key), do: nil

  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp iso8601(value) when is_binary(value) do
    case parse_datetime(value) do
      nil -> optional_string(value)
      datetime -> DateTime.to_iso8601(datetime)
    end
  end

  defp iso8601(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _parse_result -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _parse_result -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp safe_public_string(value) do
    case optional_string(value) do
      nil -> nil
      string -> if sensitive_string?(string), do: nil, else: string
    end
  end

  defp safe_status(value) do
    value
    |> optional_string()
    |> case do
      nil -> ""
      string -> string |> String.trim() |> String.downcase() |> String.replace("-", "_") |> String.replace(" ", "_")
    end
  end

  defp required_string(map, key), do: optional_string(map, key) || ""
  defp optional_string(map, key), do: map |> value(key) |> optional_string()
  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(_value), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp truthy?(value), do: value in [true, "true", "1", 1]
end
