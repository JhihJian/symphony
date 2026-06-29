defmodule SymphonyElixir.Hub.DispatchPlanning do
  @moduledoc """
  Model-only Hub dispatch planning boundary.

  This boundary consumes safe candidate-intake summaries and records which
  eligible candidates would become worker start intents. It is intentionally a
  planning projection: it does not start agents, create workspaces, mutate
  providers, or apply the full atomic dispatch ledger transition.
  """

  alias SymphonyElixir.Hub.{CandidateIntake, RuntimeLedger, SafeSummary}

  @version 1
  @active_intent_statuses ["pending", "unknown", "manual_attention"]

  @type summary :: map()

  @spec empty(map(), keyword()) :: summary()
  def empty(registry, opts \\ []) when is_map(registry) and is_list(opts) do
    candidate_intake =
      Keyword.get(opts, :candidate_intake) ||
        CandidateIntake.empty(registry,
          now: Keyword.get(opts, :now),
          runtime_ledger: Keyword.get(opts, :runtime_ledger, RuntimeLedger.new())
        )

    build(registry, candidate_intake, opts)
  end

  @spec build(map(), map(), keyword()) :: summary()
  def build(registry, candidate_intake, opts \\ []) when is_map(registry) and is_map(candidate_intake) and is_list(opts) do
    now = normalize_datetime(Keyword.get(opts, :now)) || DateTime.utc_now()
    now_iso = iso8601(now)
    intake = CandidateIntake.to_snapshot(candidate_intake)
    previous_plan = opts |> Keyword.get(:previous_plan, %{}) |> to_snapshot()
    ledger = opts |> Keyword.get(:runtime_ledger, RuntimeLedger.new()) |> RuntimeLedger.to_snapshot()

    state = %{
      now: now,
      now_iso: now_iso,
      intake_generated_at: intake.generated_at,
      ledger: ledger,
      capacities: capacity_snapshot(registry, ledger, opts),
      projects_by_id: registry_projects_by_id(registry),
      pending_intents: recovered_pending_intents(previous_plan, ledger),
      outcomes_by_issue: %{}
    }

    {projects, state} =
      intake.projects
      |> Enum.map_reduce(state, &project_plan/2)

    pending_intents =
      state.pending_intents
      |> Enum.map(&intent_snapshot/1)
      |> Enum.sort_by(&{&1.project_id || "", &1.issue_key || "", &1.intent_id || ""})

    summary = %{
      version: @version,
      generated_at: now_iso,
      status: "completed",
      counts: counts(projects, pending_intents),
      skipped_reasons: skipped_reason_counts(projects),
      projects: projects,
      pending_intents: pending_intents,
      safety: safety_summary()
    }

    to_snapshot(summary)
  end

  @spec to_snapshot(term()) :: summary()
  def to_snapshot(summary) when is_map(summary) do
    projects =
      summary
      |> list_value(:projects)
      |> Enum.map(&project_snapshot/1)
      |> Enum.sort_by(&{&1.project_id || "", &1.provider_scope_key || ""})

    pending_intents =
      summary
      |> list_value(:pending_intents)
      |> Enum.map(&intent_snapshot/1)
      |> Enum.sort_by(&{&1.project_id || "", &1.issue_key || "", &1.intent_id || ""})

    %{
      version: positive_integer(value(summary, :version)) || @version,
      generated_at: iso8601(value(summary, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601(),
      status: safe_status(value(summary, :status)) || "idle",
      counts: summary_count_snapshot(value(summary, :counts), projects, pending_intents),
      skipped_reasons: reason_count_snapshot(value(summary, :skipped_reasons)),
      projects: projects,
      pending_intents: pending_intents,
      safety: safety_snapshot(value(summary, :safety))
    }
  end

  def to_snapshot(_summary) do
    to_snapshot(%{projects: [], pending_intents: [], status: "idle"})
  end

  @spec observability_snapshot(term()) :: summary() | nil
  def observability_snapshot(nil), do: nil
  def observability_snapshot(summary) when is_map(summary), do: to_snapshot(summary)
  def observability_snapshot(_summary), do: nil

  @spec tick_summary(term()) :: map()
  def tick_summary(%{planned_count: _planned_count} = summary) do
    summarized_tick(summary)
  end

  def tick_summary(%{"planned_count" => _planned_count} = summary) do
    summarized_tick(summary)
  end

  def tick_summary(summary) when is_map(summary) do
    snapshot = to_snapshot(summary)

    %{
      eligible_count: snapshot.counts.eligible_count,
      planned_count: snapshot.counts.planned_count,
      skipped_count: snapshot.counts.skipped_count,
      already_planned_count: snapshot.counts.already_planned_count,
      capacity_unavailable_count: snapshot.counts.capacity_unavailable_count,
      invalid_count: snapshot.counts.invalid_count,
      pending_intent_count: snapshot.counts.pending_intent_count,
      skipped_reasons: snapshot.skipped_reasons
    }
  end

  def tick_summary(_summary), do: tick_summary(%{})

  defp summarized_tick(summary) do
    %{
      eligible_count: non_negative_integer(value(summary, :eligible_count)) || 0,
      planned_count: non_negative_integer(value(summary, :planned_count)) || 0,
      skipped_count: non_negative_integer(value(summary, :skipped_count)) || 0,
      already_planned_count: non_negative_integer(value(summary, :already_planned_count)) || 0,
      capacity_unavailable_count: non_negative_integer(value(summary, :capacity_unavailable_count)) || 0,
      invalid_count: non_negative_integer(value(summary, :invalid_count)) || 0,
      pending_intent_count: non_negative_integer(value(summary, :pending_intent_count)) || 0,
      skipped_reasons: reason_count_snapshot(value(summary, :skipped_reasons))
    }
  end

  defp project_plan(intake_project, state) do
    project_id = optional_string(intake_project, :project_id)
    registry_project = Map.get(state.projects_by_id, project_id, %{})

    {candidate_outcomes, state} =
      intake_project
      |> list_value(:candidates)
      |> Enum.map_reduce(state, fn candidate, state ->
        candidate_plan(candidate, registry_project, state)
      end)

    invalid_outcomes =
      intake_project
      |> list_value(:invalid_candidates)
      |> Enum.map(&invalid_candidate_outcome(&1, state))

    outcomes = candidate_outcomes ++ invalid_outcomes

    pending_intents =
      pending_intents_for_project(
        state.pending_intents,
        project_id,
        optional_string(intake_project, :provider_scope_key)
      )

    project = %{
      project_id: project_id,
      provider_kind: optional_string(intake_project, :provider_kind),
      provider_scope_key: optional_string(intake_project, :provider_scope_key),
      counts: project_counts(outcomes, pending_intents),
      skipped_reasons: outcome_reason_counts(outcomes),
      source_polls: intake_project |> list_value(:source_polls) |> Enum.map(&source_poll_snapshot/1),
      outcomes: outcomes,
      pending_intents: pending_intents
    }

    {project_snapshot(project), state}
  end

  defp candidate_plan(candidate, registry_project, state) do
    eligible? = get_in(candidate, [:dispatch_evaluation, :eligible]) == true

    outcome =
      cond do
        not candidate_identity_complete?(candidate) ->
          skipped_outcome(candidate, "invalid_candidate", "Candidate is missing stable dispatch identity", "invalid_candidate")

        existing = pending_intent_for_candidate(state.pending_intents, candidate) ->
          already_planned_outcome(candidate, existing)

        unresolved = unresolved_ledger_intent_for_candidate(state.pending_intents, candidate) ->
          already_planned_outcome(candidate, unresolved)

        not eligible? ->
          skipped_candidate_outcome(candidate, state)

        active = active_attempt_for_candidate(state.ledger, candidate) ->
          skipped_outcome(candidate, "blocked_by_active_attempt", "Issue already has an active attempt", "duplicate_active_attempt",
            existing_attempt_id: active.attempt_id,
            existing_workspace_path: active.workspace_path
          )

        workspace = workspace_reservation_for_candidate(state, candidate) ->
          skipped_outcome(candidate, "blocked_by_workspace", "Workspace is already reserved", "workspace_busy",
            existing_attempt_id: optional_string(workspace, :attempt_id),
            existing_workspace_path: optional_string(workspace, :workspace_path)
          )

        project_capacity_full?(registry_project, state, candidate.project_id) ->
          skipped_outcome(candidate, "capacity_unavailable", "Project dispatch planning capacity is full", "project_capacity_full")

        global_capacity_full?(state) ->
          skipped_outcome(candidate, "capacity_unavailable", "Hub dispatch planning capacity is full", "global_capacity_full")

        true ->
          planned_outcome(candidate, registry_project, state)
      end

    state =
      case outcome do
        %{status: "planned", intent: intent} ->
          state
          |> Map.update!(:pending_intents, &(&1 ++ [intent]))
          |> Map.update!(:outcomes_by_issue, &Map.put(&1, {intent.project_id, intent.issue_key}, outcome))

        _outcome ->
          state
      end

    {outcome_snapshot(outcome), state}
  end

  defp planned_outcome(candidate, registry_project, state) do
    intent = planned_intent(candidate, registry_project, state)

    %{
      outcome_id: stable_id("hub-dispatch-plan-outcome", Enum.join([candidate.issue_key, intent.intent_id], "|")),
      status: "planned",
      reason: nil,
      message: nil,
      candidate_id: candidate.candidate_id,
      candidate_key: candidate.candidate_key,
      project_id: candidate.project_id,
      provider_kind: candidate.provider_kind,
      provider_scope_key: candidate.provider_scope_key,
      issue_key: candidate.issue_key,
      issue_ref: candidate.issue_ref,
      current_stage: candidate.current_stage,
      workspace_path: candidate.workspace_path,
      source_poll: candidate.source_poll,
      eligible: true,
      intent: intent,
      safety: safety_summary()
    }
  end

  defp already_planned_outcome(candidate, intent) do
    %{
      outcome_id: stable_id("hub-dispatch-plan-outcome", Enum.join([candidate.issue_key, intent.intent_id, "already-planned"], "|")),
      status: "already_planned",
      reason: "already_planned",
      message: "Candidate already has an unresolved dispatch plan or start intent",
      candidate_id: candidate.candidate_id,
      candidate_key: candidate.candidate_key,
      project_id: candidate.project_id,
      provider_kind: candidate.provider_kind,
      provider_scope_key: candidate.provider_scope_key,
      issue_key: candidate.issue_key,
      issue_ref: candidate.issue_ref,
      current_stage: candidate.current_stage,
      workspace_path: candidate.workspace_path,
      source_poll: candidate.source_poll,
      eligible: get_in(candidate, [:dispatch_evaluation, :eligible]) == true,
      intent: intent,
      safety: safety_summary()
    }
  end

  defp skipped_candidate_outcome(candidate, state) do
    evaluation = value(candidate, :dispatch_evaluation) || %{}
    reason = safe_status(value(evaluation, :skipped_reason)) || "skipped"
    status = status_for_skipped_reason(reason, state, candidate)
    message = safe_optional_string(value(evaluation, :message))
    preflight = value(evaluation, :preflight)

    skipped_outcome(candidate, status, message, reason, preflight: preflight)
  end

  defp skipped_outcome(candidate, status, message, reason, extra \\ []) do
    %{
      outcome_id:
        stable_id(
          "hub-dispatch-plan-outcome",
          Enum.join(
            [optional_string(candidate, :issue_key) || optional_string(candidate, :candidate_id) || "candidate", status, reason],
            "|"
          )
        ),
      status: status,
      reason: reason,
      message: safe_optional_string(message),
      candidate_id: optional_string(candidate, :candidate_id),
      candidate_key: optional_string(candidate, :candidate_key),
      project_id: optional_string(candidate, :project_id),
      provider_kind: optional_string(candidate, :provider_kind),
      provider_scope_key: optional_string(candidate, :provider_scope_key),
      issue_key: optional_string(candidate, :issue_key),
      issue_ref: issue_ref_snapshot(value(candidate, :issue_ref) || %{}),
      current_stage: optional_string(candidate, :current_stage),
      workspace_path: optional_string(candidate, :workspace_path),
      source_poll: source_poll_snapshot(value(candidate, :source_poll) || %{}),
      eligible: get_in(candidate, [:dispatch_evaluation, :eligible]) == true,
      intent: nil,
      preflight: preflight_snapshot(Keyword.get(extra, :preflight) || %{}),
      existing_attempt_id: Keyword.get(extra, :existing_attempt_id),
      existing_workspace_path: Keyword.get(extra, :existing_workspace_path),
      safety: safety_summary()
    }
  end

  defp invalid_candidate_outcome(invalid, state) do
    %{
      outcome_id:
        stable_id(
          "hub-dispatch-plan-outcome",
          Enum.join(
            [
              optional_string(invalid, :project_id) || "",
              optional_string(invalid, :provider_scope_key) || "",
              invalid |> value(:candidate_index) |> to_string(),
              "invalid"
            ],
            "|"
          )
        ),
      status: "invalid_candidate",
      reason: "invalid_candidate",
      invalid_reason: safe_status(value(invalid, :invalid_reason)) || "invalid_candidate",
      message: "Candidate was rejected before dispatch planning",
      candidate_index: non_negative_integer(value(invalid, :candidate_index)),
      project_id: optional_string(invalid, :project_id),
      provider_kind: nil,
      provider_scope_key: optional_string(invalid, :provider_scope_key),
      issue_key: nil,
      issue_ref: issue_ref_snapshot(%{}),
      current_stage: nil,
      workspace_path: nil,
      source_poll: source_poll_snapshot(value(invalid, :source_poll) || %{}),
      eligible: false,
      intent: nil,
      preflight: preflight_snapshot(%{}),
      safety: safety_summary(),
      generated_at: state.now_iso
    }
  end

  defp planned_intent(candidate, registry_project, state) do
    issue_key = candidate.issue_key
    intent_seed = Enum.join([candidate.project_id, candidate.provider_scope_key, issue_key], "|")
    attempt_id = stable_id("hub-planned-attempt", intent_seed)
    intent_id = stable_id("hub-planned-start-intent", intent_seed)
    correlation_id = stable_id("hub-dispatch-plan-correlation", Enum.join([intent_seed, candidate.candidate_id || ""], "|"))

    %{
      intent_id: intent_id,
      attempt_id: attempt_id,
      project_id: candidate.project_id,
      provider_kind: candidate.provider_kind,
      provider_scope_key: candidate.provider_scope_key,
      issue_key: issue_key,
      issue_ref: issue_ref_snapshot(candidate.issue_ref),
      candidate_id: candidate.candidate_id,
      candidate_key: candidate.candidate_key,
      current_stage: candidate.current_stage,
      workspace_path: candidate.workspace_path,
      status: "pending",
      requested_at: state.now_iso,
      source_model: "dispatch_planning",
      source_poll: source_poll_snapshot(candidate.source_poll),
      source_intake: %{
        generated_at: state.intake_generated_at,
        candidate_id: candidate.candidate_id,
        candidate_key: candidate.candidate_key
      },
      config_fingerprint:
        optional_string(registry_project, :fingerprint) ||
          optional_string(registry_project, :config_fingerprint),
      snapshot_version: optional_string(registry_project, :snapshot_version),
      correlation_id: correlation_id,
      runtime_identity: %{boundary: "hub_dispatch_planning", model_only: true},
      runner: nil,
      start_command_summary: %{
        planned: true,
        starts_agent: false,
        creates_workspace: false,
        writes_provider: false
      },
      safety: safety_summary()
    }
  end

  defp recovered_pending_intents(previous_plan, ledger) do
    previous =
      previous_plan
      |> list_value(:pending_intents)
      |> Enum.map(&intent_snapshot/1)
      |> Enum.filter(&active_intent?/1)

    ledger_intents = ledger_pending_intents(ledger)

    (previous ++ ledger_intents)
    |> Enum.reverse()
    |> Enum.uniq_by(&{&1.project_id, &1.issue_key})
    |> Enum.reverse()
  end

  defp ledger_pending_intents(ledger) do
    ledger
    |> list_value(:projects)
    |> Enum.flat_map(fn project ->
      issues_by_key = Map.new(list_value(project, :issues), &{required_string(&1, :issue_key), &1})

      project
      |> list_value(:start_intents)
      |> Enum.filter(&active_intent?/1)
      |> Enum.map(fn intent ->
        issue = Map.get(issues_by_key, required_string(intent, :issue_key), %{})
        issue_ref = issue_ref_snapshot(value(issue, :issue_ref) || %{})

        %{
          intent_id: required_string(intent, :intent_id),
          attempt_id: required_string(intent, :attempt_id),
          project_id: required_string(project, :project_id),
          provider_kind: issue_ref.tracker_kind,
          provider_scope_key: issue_ref.provider_scope_key,
          issue_key: required_string(intent, :issue_key),
          issue_ref: issue_ref,
          candidate_id: nil,
          candidate_key: nil,
          current_stage: optional_string(issue, :current_stage),
          workspace_path: optional_string(intent, :workspace_path),
          status: safe_status(value(intent, :status)) || "pending",
          requested_at: iso8601(value(intent, :requested_at)),
          source_model: "runtime_ledger",
          source_poll: source_poll_snapshot(%{}),
          source_intake: %{},
          config_fingerprint: optional_string(project, :config_fingerprint),
          snapshot_version: optional_string(project, :snapshot_version),
          correlation_id: optional_string(intent, :correlation_id),
          runtime_identity: value(intent, :runtime_identity) || %{},
          runner: optional_string(intent, :runner),
          start_command_summary: value(intent, :start_command_summary) || %{},
          safety: safety_summary()
        }
      end)
    end)
  end

  defp pending_intent_for_candidate(pending_intents, candidate) do
    Enum.find(pending_intents, fn intent ->
      intent.source_model == "dispatch_planning" and
        intent.project_id == candidate.project_id and
        intent.provider_scope_key == candidate.provider_scope_key and
        intent.issue_key == candidate.issue_key
    end)
  end

  defp unresolved_ledger_intent_for_candidate(pending_intents, candidate) do
    Enum.find(pending_intents, fn intent ->
      intent.source_model == "runtime_ledger" and
        intent.project_id == candidate.project_id and
        intent.issue_key == candidate.issue_key
    end)
  end

  defp workspace_reservation_for_candidate(state, candidate) do
    workspace_path = optional_string(candidate, :workspace_path)

    cond do
      is_nil(workspace_path) ->
        nil

      pending = Enum.find(state.pending_intents, &(optional_string(&1, :workspace_path) == workspace_path)) ->
        pending

      true ->
        active_workspace_lease(state.ledger, workspace_path)
    end
  end

  defp active_workspace_lease(ledger, workspace_path) do
    Enum.find_value(list_value(ledger, :projects), fn project ->
      project
      |> list_value(:workspace_leases)
      |> Enum.find(&(active_lease?(&1) and optional_string(&1, :workspace_path) == workspace_path))
    end)
  end

  defp active_attempt_for_candidate(ledger, candidate) do
    project = ledger |> list_value(:projects) |> Enum.find(&(required_string(&1, :project_id) == candidate.project_id))
    issue = project && Enum.find(list_value(project, :issues), &(required_string(&1, :issue_key) == candidate.issue_key))

    issue && Enum.find(list_value(issue, :attempts), &active_attempt?/1)
  end

  defp status_for_skipped_reason("duplicate_active_attempt", state, candidate) do
    if unresolved_ledger_intent_for_candidate(state.pending_intents, candidate) do
      "already_planned"
    else
      "blocked_by_active_attempt"
    end
  end

  defp status_for_skipped_reason("workspace_busy", _state, _candidate), do: "blocked_by_workspace"
  defp status_for_skipped_reason("project_capacity_full", _state, _candidate), do: "capacity_unavailable"
  defp status_for_skipped_reason("global_capacity_full", _state, _candidate), do: "capacity_unavailable"
  defp status_for_skipped_reason("manual_attention", _state, _candidate), do: "manual_attention"
  defp status_for_skipped_reason("project_paused", _state, _candidate), do: "project_paused"
  defp status_for_skipped_reason("config_error", _state, _candidate), do: "config_error"
  defp status_for_skipped_reason("provider_rate_limit", _state, _candidate), do: "provider_backoff"
  defp status_for_skipped_reason("provider_backoff", _state, _candidate), do: "provider_backoff"
  defp status_for_skipped_reason("provider_circuit_open", _state, _candidate), do: "provider_backoff"
  defp status_for_skipped_reason("retry_backoff", _state, _candidate), do: "retry_backoff"
  defp status_for_skipped_reason("workspace_unavailable", _state, _candidate), do: "workspace_unavailable"
  defp status_for_skipped_reason("invalid_candidate", _state, _candidate), do: "invalid_candidate"
  defp status_for_skipped_reason(_reason, _state, _candidate), do: "skipped"

  defp project_capacity_full?(registry_project, state, project_id) do
    case project_capacity(registry_project) do
      nil -> false
      capacity -> active_project_attempt_count(state.ledger, project_id) + pending_project_capacity_count(state, project_id) >= capacity
    end
  end

  defp global_capacity_full?(%{capacities: %{global_capacity: nil}}), do: false

  defp global_capacity_full?(state) do
    state.capacities.active_total + pending_global_capacity_count(state) >= state.capacities.global_capacity
  end

  defp pending_project_capacity_count(state, project_id) do
    Enum.count(state.pending_intents, &(optional_string(&1, :source_model) == "dispatch_planning" and optional_string(&1, :project_id) == project_id))
  end

  defp pending_global_capacity_count(state) do
    Enum.count(state.pending_intents, &(optional_string(&1, :source_model) == "dispatch_planning"))
  end

  defp capacity_snapshot(registry, ledger, opts) do
    global_capacity =
      Keyword.get(opts, :max_agent_capacity)
      |> non_negative_integer()
      |> case do
        nil -> registry_capacity(registry)
        capacity -> capacity
      end

    %{global_capacity: global_capacity, active_total: active_total_attempt_count(ledger)}
  end

  defp registry_capacity(registry) do
    capacity =
      registry
      |> list_value(:projects)
      |> Enum.map(&project_capacity/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    if capacity > 0, do: capacity
  end

  defp project_capacity(project) do
    project
    |> map_value(:runtime_summary)
    |> value(:max_concurrent_agents)
    |> non_negative_integer()
  end

  defp active_project_attempt_count(ledger, project_id) do
    ledger
    |> list_value(:projects)
    |> Enum.find(&(required_string(&1, :project_id) == project_id))
    |> case do
      nil ->
        0

      project ->
        project
        |> list_value(:issues)
        |> Enum.flat_map(&list_value(&1, :attempts))
        |> Enum.count(&active_attempt?/1)
    end
  end

  defp active_total_attempt_count(ledger) do
    ledger
    |> list_value(:projects)
    |> Enum.map(&active_project_attempt_count(ledger, required_string(&1, :project_id)))
    |> Enum.sum()
  end

  defp candidate_identity_complete?(candidate) do
    not blank?(optional_string(candidate, :project_id)) and
      not blank?(optional_string(candidate, :provider_scope_key)) and
      not blank?(optional_string(candidate, :issue_key)) and
      is_map(value(candidate, :issue_ref))
  end

  defp pending_intents_for_project(pending_intents, project_id, provider_scope_key) do
    pending_intents
    |> Enum.filter(fn intent ->
      optional_string(intent, :project_id) == project_id and
        (is_nil(provider_scope_key) or optional_string(intent, :provider_scope_key) == provider_scope_key)
    end)
    |> Enum.map(&intent_snapshot/1)
  end

  defp registry_projects_by_id(registry) do
    registry
    |> list_value(:projects)
    |> Map.new(fn project -> {required_string(project, :project_id), project} end)
  end

  defp project_snapshot(project) when is_map(project) do
    outcomes =
      project
      |> list_value(:outcomes)
      |> Enum.map(&outcome_snapshot/1)

    pending_intents =
      project
      |> list_value(:pending_intents)
      |> Enum.map(&intent_snapshot/1)

    %{
      project_id: optional_string(project, :project_id),
      provider_kind: optional_string(project, :provider_kind),
      provider_scope_key: optional_string(project, :provider_scope_key),
      counts: project_count_snapshot(value(project, :counts), outcomes, pending_intents),
      skipped_reasons: reason_count_snapshot(value(project, :skipped_reasons)),
      source_polls: project |> list_value(:source_polls) |> Enum.map(&source_poll_snapshot/1),
      outcomes: outcomes,
      pending_intents: pending_intents
    }
  end

  defp project_snapshot(_project), do: project_snapshot(%{})

  defp outcome_snapshot(outcome) when is_map(outcome) do
    %{
      outcome_id: optional_string(outcome, :outcome_id),
      status: safe_status(value(outcome, :status)) || "skipped",
      reason: safe_status(value(outcome, :reason)),
      invalid_reason: safe_status(value(outcome, :invalid_reason)),
      message: safe_optional_string(value(outcome, :message)),
      candidate_index: non_negative_integer(value(outcome, :candidate_index)),
      candidate_id: optional_string(outcome, :candidate_id),
      candidate_key: optional_string(outcome, :candidate_key),
      project_id: optional_string(outcome, :project_id),
      provider_kind: optional_string(outcome, :provider_kind),
      provider_scope_key: optional_string(outcome, :provider_scope_key),
      issue_key: optional_string(outcome, :issue_key),
      issue_ref: issue_ref_snapshot(value(outcome, :issue_ref) || %{}),
      current_stage: optional_string(outcome, :current_stage),
      workspace_path: optional_string(outcome, :workspace_path),
      source_poll: source_poll_snapshot(value(outcome, :source_poll) || %{}),
      eligible: value(outcome, :eligible) == true,
      intent: maybe_intent_snapshot(value(outcome, :intent)),
      preflight: preflight_snapshot(value(outcome, :preflight) || %{}),
      existing_attempt_id: optional_string(outcome, :existing_attempt_id),
      existing_workspace_path: optional_string(outcome, :existing_workspace_path),
      safety: safety_snapshot(value(outcome, :safety))
    }
  end

  defp outcome_snapshot(_outcome), do: outcome_snapshot(%{})

  defp maybe_intent_snapshot(intent) when is_map(intent), do: intent_snapshot(intent)
  defp maybe_intent_snapshot(_intent), do: nil

  defp intent_snapshot(intent) when is_map(intent) do
    %{
      intent_id: optional_string(intent, :intent_id),
      attempt_id: optional_string(intent, :attempt_id),
      project_id: optional_string(intent, :project_id),
      provider_kind: optional_string(intent, :provider_kind),
      provider_scope_key: optional_string(intent, :provider_scope_key),
      issue_key: optional_string(intent, :issue_key),
      issue_ref: issue_ref_snapshot(value(intent, :issue_ref) || %{}),
      candidate_id: optional_string(intent, :candidate_id),
      candidate_key: optional_string(intent, :candidate_key),
      current_stage: optional_string(intent, :current_stage),
      workspace_path: optional_string(intent, :workspace_path),
      status: safe_status(value(intent, :status)) || "pending",
      requested_at: iso8601(value(intent, :requested_at)),
      source_model: optional_string(intent, :source_model) || "dispatch_planning",
      source_poll: source_poll_snapshot(value(intent, :source_poll) || %{}),
      source_intake: SafeSummary.sanitize_map(value(intent, :source_intake) || %{}, output_keys: :preserve),
      config_fingerprint: optional_string(intent, :config_fingerprint),
      snapshot_version: optional_string(intent, :snapshot_version),
      correlation_id: optional_string(intent, :correlation_id),
      runtime_identity:
        SafeSummary.sanitize_map(value(intent, :runtime_identity) || %{},
          output_keys: :preserve,
          atom_values: :preserve
        ),
      runner: optional_string(intent, :runner),
      start_command_summary:
        SafeSummary.sanitize_map(value(intent, :start_command_summary) || %{},
          output_keys: :preserve,
          atom_values: :preserve
        ),
      safety: safety_snapshot(value(intent, :safety))
    }
  end

  defp intent_snapshot(_intent), do: intent_snapshot(%{})

  defp issue_ref_snapshot(issue_ref) when is_map(issue_ref) do
    %{
      project_id: optional_string(issue_ref, :project_id),
      tracker_kind: optional_string(issue_ref, :tracker_kind),
      provider_scope: SafeSummary.sanitize_map(value(issue_ref, :provider_scope) || %{}, output_keys: :preserve),
      provider_scope_key: optional_string(issue_ref, :provider_scope_key),
      provider_issue_id: optional_string(issue_ref, :provider_issue_id),
      provider_local_id: optional_string(issue_ref, :provider_local_id),
      identifier: optional_string(issue_ref, :identifier),
      url: safe_optional_string(value(issue_ref, :url))
    }
  end

  defp issue_ref_snapshot(_issue_ref), do: issue_ref_snapshot(%{})

  defp source_poll_snapshot(source_poll) when is_map(source_poll) do
    %{
      project_id: optional_string(source_poll, :project_id),
      provider_kind: optional_string(source_poll, :provider_kind),
      provider_scope_key: optional_string(source_poll, :provider_scope_key),
      request_id: optional_string(source_poll, :request_id),
      logical_key: optional_string(source_poll, :logical_key),
      poll_attempt_id: optional_string(source_poll, :poll_attempt_id),
      poll_result_status: safe_status(value(source_poll, :poll_result_status)),
      retry_after_ms: non_negative_integer(value(source_poll, :retry_after_ms)),
      backoff_until: iso8601(value(source_poll, :backoff_until)),
      finished_at: iso8601(value(source_poll, :finished_at))
    }
  end

  defp source_poll_snapshot(_source_poll), do: source_poll_snapshot(%{})

  defp preflight_snapshot(preflight) when is_map(preflight) do
    %{
      status: safe_status(value(preflight, :status)),
      can_start: value(preflight, :can_start?) == true or value(preflight, :can_start) == true,
      reason: safe_status(value(preflight, :reason)),
      existing_attempt_id: optional_string(preflight, :existing_attempt_id),
      existing_workspace_path: optional_string(preflight, :existing_workspace_path),
      retry_due_at: optional_string(preflight, :retry_due_at),
      blocked_by: preflight |> list_value(:blocked_by) |> Enum.map(&safe_status/1) |> Enum.reject(&is_nil/1)
    }
  end

  defp preflight_snapshot(_preflight), do: preflight_snapshot(%{})

  defp safety_summary do
    %{
      model_only: true,
      starts_agent: false,
      creates_workspace: false,
      creates_workspace_lease: false,
      writes_provider: false
    }
  end

  defp safety_snapshot(safety) when is_map(safety) do
    %{
      model_only: value(safety, :model_only) != false,
      starts_agent: value(safety, :starts_agent) == true,
      creates_workspace: value(safety, :creates_workspace) == true,
      creates_workspace_lease: value(safety, :creates_workspace_lease) == true,
      writes_provider: value(safety, :writes_provider) == true
    }
  end

  defp safety_snapshot(_safety), do: safety_summary()

  defp summary_count_snapshot(counts, projects, pending_intents) when is_map(counts) and is_list(projects) and is_list(pending_intents) do
    counts
    |> count_snapshot()
    |> Map.put(:project_count, length(projects))
    |> Map.put(:pending_intent_count, length(pending_intents))
  end

  defp summary_count_snapshot(_counts, projects, pending_intents) when is_list(projects) and is_list(pending_intents) do
    counts(projects, pending_intents)
  end

  defp project_count_snapshot(counts, outcomes, pending_intents) when is_map(counts) and is_list(outcomes) and is_list(pending_intents) do
    counts
    |> count_snapshot()
    |> Map.put(:outcome_count, length(outcomes))
    |> Map.put(:pending_intent_count, length(pending_intents))
  end

  defp project_count_snapshot(_counts, outcomes, pending_intents) when is_list(outcomes) and is_list(pending_intents) do
    project_counts(outcomes, pending_intents)
  end

  defp count_snapshot(counts) when is_map(counts) do
    %{
      eligible_count: non_negative_integer(value(counts, :eligible_count)) || 0,
      outcome_count: non_negative_integer(value(counts, :outcome_count)) || 0,
      planned_count: non_negative_integer(value(counts, :planned_count)) || 0,
      skipped_count: non_negative_integer(value(counts, :skipped_count)) || 0,
      already_planned_count: non_negative_integer(value(counts, :already_planned_count)) || 0,
      capacity_unavailable_count: non_negative_integer(value(counts, :capacity_unavailable_count)) || 0,
      invalid_count: non_negative_integer(value(counts, :invalid_count)) || 0,
      pending_intent_count: non_negative_integer(value(counts, :pending_intent_count)) || 0,
      project_count: non_negative_integer(value(counts, :project_count)) || 0
    }
  end

  defp counts(projects, pending_intents) do
    outcomes = Enum.flat_map(projects, &list_value(&1, :outcomes))

    outcomes
    |> project_counts(pending_intents)
    |> Map.put(:project_count, length(projects))
  end

  defp project_counts(outcomes, pending_intents) do
    %{
      eligible_count: Enum.count(outcomes, &(value(&1, :eligible) == true)),
      outcome_count: length(outcomes),
      planned_count: Enum.count(outcomes, &(safe_status(value(&1, :status)) == "planned")),
      skipped_count: Enum.count(outcomes, &(safe_status(value(&1, :status)) != "planned")),
      already_planned_count: Enum.count(outcomes, &(safe_status(value(&1, :status)) == "already_planned")),
      capacity_unavailable_count: Enum.count(outcomes, &(safe_status(value(&1, :status)) == "capacity_unavailable")),
      invalid_count: Enum.count(outcomes, &(safe_status(value(&1, :status)) == "invalid_candidate")),
      pending_intent_count: length(pending_intents),
      project_count: 0
    }
  end

  defp skipped_reason_counts(projects) do
    projects
    |> Enum.flat_map(&list_value(&1, :outcomes))
    |> outcome_reason_counts()
  end

  defp outcome_reason_counts(outcomes) do
    outcomes
    |> Enum.reject(&(safe_status(value(&1, :status)) == "planned"))
    |> Enum.map(&(safe_status(value(&1, :reason)) || safe_status(value(&1, :status))))
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {reason, _count} -> reason end)
    |> Map.new()
  end

  defp reason_count_snapshot(reasons) when is_map(reasons) do
    reasons
    |> Enum.map(fn {reason, count} -> {safe_status(reason), non_negative_integer(count) || 0} end)
    |> Enum.reject(fn {reason, count} -> blank?(reason) or count <= 0 end)
    |> Map.new()
  end

  defp reason_count_snapshot(_reasons), do: %{}

  defp active_attempt?(attempt) do
    safe_status(value(attempt, :status)) in ["pending", "running"] and is_nil(value(attempt, :ended_at))
  end

  defp active_lease?(lease) do
    safe_status(value(lease, :status)) == "active" and is_nil(value(lease, :released_at))
  end

  defp active_intent?(intent) do
    safe_status(value(intent, :status)) in @active_intent_statuses and
      is_nil(value(intent, :acked_at)) and
      is_nil(value(intent, :finished_at))
  end

  defp stable_id(prefix, seed) do
    prefix <> ":" <> Base.encode16(:crypto.hash(:sha256, to_string(seed)), case: :lower)
  end

  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(%DateTime{} = value), do: value

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp normalize_datetime(_value), do: nil

  defp iso8601(%DateTime{} = datetime), do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> iso8601(datetime)
      {:error, _reason} -> safe_optional_string(value)
    end
  end

  defp iso8601(_value), do: nil

  defp required_string(map, key), do: optional_string(map, key) || ""
  defp optional_string(map, key), do: map |> value(key) |> optional_string()
  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(_value), do: nil

  defp safe_optional_string(nil), do: nil
  defp safe_optional_string(value) when is_binary(value), do: value |> String.trim() |> String.slice(0, 500) |> blank_to_nil()
  defp safe_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_optional_string(_value), do: nil

  defp safe_status(nil), do: nil
  defp safe_status(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_status(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp safe_status(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_status(_value), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _parse -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _parse -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp map_value(map, key) do
    case value(map, key) do
      value when is_map(value) -> value
      _value -> nil
    end
  end

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

  defp value(map, key) when is_map(map), do: Map.get(map, key)
  defp value(_map, _key), do: nil
end
