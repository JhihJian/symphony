defmodule SymphonyElixir.Hub.DispatchPlanApplication do
  @moduledoc """
  Applies Hub dispatch planning summaries to the model-only runtime ledger.

  This boundary is intentionally still a skeleton: it records claim, attempt,
  workspace lease, start intent, and safe run context facts through
  `DispatchBoundary`, but it does not start agents, create real workspaces,
  run workspace hooks, or write provider state.
  """

  alias SymphonyElixir.Hub.{
    ActivationPreflight,
    CutoverAuthorizationConsumptionGuard,
    CutoverExecutionOutcomeLedger,
    CutoverGate,
    CutoverReplayDecision,
    DispatchBoundary,
    DispatchPlanning,
    RuntimeLedger,
    SafeSummary
  }

  @version 1

  @type summary :: map()

  @spec empty(map(), keyword()) :: summary()
  def empty(registry, opts \\ []) when is_map(registry) and is_list(opts) do
    ledger = opts |> Keyword.get(:runtime_ledger, RuntimeLedger.new()) |> RuntimeLedger.to_snapshot()
    planning = Keyword.get(opts, :dispatch_planning, DispatchPlanning.to_snapshot(%{}))
    {_ledger, summary} = apply_plan(registry, planning, ledger, opts)
    summary
  end

  @spec apply_plan(map(), map(), map(), keyword()) :: {RuntimeLedger.ledger(), summary()}
  def apply_plan(registry, dispatch_planning, runtime_ledger, opts \\ [])
      when is_map(registry) and is_map(dispatch_planning) and is_map(runtime_ledger) and is_list(opts) do
    now = normalize_datetime(Keyword.get(opts, :now)) || DateTime.utc_now()
    now_iso = iso8601(now)
    plan = DispatchPlanning.to_snapshot(dispatch_planning)

    activation_preflight =
      opts
      |> Keyword.get(:activation_preflight, ActivationPreflight.empty(registry, now: now))
      |> ActivationPreflight.to_snapshot()

    cutover_gate =
      opts
      |> Keyword.get(:cutover_gate)
      |> CutoverGate.observability_snapshot()

    registry_projects = registry_projects_by_id(registry)
    initial_ledger = RuntimeLedger.to_snapshot(runtime_ledger)

    initial_state = %{
      now: now,
      now_iso: now_iso,
      plan: plan,
      registry_projects: registry_projects,
      activation_preflight: activation_preflight,
      cutover_gate: cutover_gate,
      authorization_consumption_guard:
        Keyword.get(opts, :authorization_consumption_guard) ||
          Keyword.get(opts, :cutover_authorization_consumption_guard),
      cutover_execution_outcome_ledger:
        Keyword.get(opts, :cutover_execution_outcome_ledger) ||
          Keyword.get(opts, :execution_outcome_ledger),
      cutover_execution_outcome_closeout:
        Keyword.get(opts, :cutover_execution_outcome_closeout) ||
          Keyword.get(opts, :execution_outcome_closeout) ||
          Keyword.get(opts, :closeout_summary),
      ledger_changed?: false
    }

    {project_results, ledger, state} =
      plan.projects
      |> Enum.map_reduce({initial_ledger, initial_state}, fn project, {ledger, state} ->
        {project_result, ledger, state} = apply_project(project, ledger, state)
        {project_result, {ledger, state}}
      end)
      |> then(fn {projects, {ledger, state}} -> {projects, ledger, state} end)

    ledger =
      if state.ledger_changed? do
        touch_ledger(ledger, now_iso)
      else
        RuntimeLedger.to_snapshot(ledger)
      end

    ledger_replay = RuntimeLedger.replay(ledger)
    projects = attach_ledger_summaries(project_results, ledger_replay)
    pending_start_intents = pending_start_intents(ledger_replay)

    summary =
      %{
        version: @version,
        generated_at: now_iso,
        status: "completed",
        counts: summary_counts(projects, pending_start_intents),
        reason_counts: reason_counts(projects),
        projects: projects,
        pending_start_intents: pending_start_intents,
        runtime_ledger_replay: ledger_replay,
        safety: safety_summary()
      }
      |> to_snapshot()

    {ledger, summary}
  end

  @spec to_snapshot(term()) :: summary()
  def to_snapshot(summary) when is_map(summary) do
    projects =
      summary
      |> list_value(:projects)
      |> Enum.map(&project_snapshot/1)
      |> Enum.sort_by(&{&1.project_id || "", &1.provider_scope_key || ""})

    pending_start_intents =
      summary
      |> list_value(:pending_start_intents)
      |> Enum.map(&pending_start_intent_snapshot/1)
      |> Enum.sort_by(&{&1.project_id || "", &1.issue_key || "", &1.intent_id || ""})

    %{
      version: positive_integer(value(summary, :version)) || @version,
      generated_at: iso8601(value(summary, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601(),
      status: safe_status(value(summary, :status)) || "idle",
      counts: count_snapshot(value(summary, :counts), projects, pending_start_intents),
      reason_counts: reason_count_snapshot(value(summary, :reason_counts)),
      projects: projects,
      pending_start_intents: pending_start_intents,
      runtime_ledger_replay: runtime_ledger_replay_snapshot(value(summary, :runtime_ledger_replay)),
      safety: safety_snapshot(value(summary, :safety))
    }
  end

  def to_snapshot(_summary), do: to_snapshot(%{})

  @spec observability_snapshot(term()) :: summary() | nil
  def observability_snapshot(nil), do: nil
  def observability_snapshot(summary) when is_map(summary), do: to_snapshot(summary)
  def observability_snapshot(_summary), do: nil

  @spec tick_summary(term()) :: map()
  def tick_summary(%{applied_count: _applied_count} = summary), do: summarized_tick(summary)
  def tick_summary(%{"applied_count" => _applied_count} = summary), do: summarized_tick(summary)

  def tick_summary(summary) when is_map(summary) do
    snapshot = to_snapshot(summary)

    %{
      selected_count: snapshot.counts.selected_count,
      applied_count: snapshot.counts.applied_count,
      already_applied_count: snapshot.counts.already_applied_count,
      already_planned_count: snapshot.counts.already_planned_count,
      blocked_count: snapshot.counts.blocked_count,
      manual_attention_count: snapshot.counts.manual_attention_count,
      skipped_count: snapshot.counts.skipped_count,
      pending_start_intent_count: snapshot.counts.pending_start_intent_count,
      reason_counts: snapshot.reason_counts
    }
  end

  def tick_summary(_summary), do: tick_summary(%{})

  defp summarized_tick(summary) do
    %{
      selected_count: non_negative_integer(value(summary, :selected_count)) || 0,
      applied_count: non_negative_integer(value(summary, :applied_count)) || 0,
      already_applied_count: non_negative_integer(value(summary, :already_applied_count)) || 0,
      already_planned_count: non_negative_integer(value(summary, :already_planned_count)) || 0,
      blocked_count: non_negative_integer(value(summary, :blocked_count)) || 0,
      manual_attention_count: non_negative_integer(value(summary, :manual_attention_count)) || 0,
      skipped_count: non_negative_integer(value(summary, :skipped_count)) || 0,
      pending_start_intent_count: non_negative_integer(value(summary, :pending_start_intent_count)) || 0,
      reason_counts: reason_count_snapshot(value(summary, :reason_counts))
    }
  end

  defp apply_project(project, ledger, state) do
    {outcomes, ledger, state} =
      project
      |> list_value(:outcomes)
      |> Enum.map_reduce({ledger, state}, fn outcome, {ledger, state} ->
        {application_outcome, ledger, state} = apply_outcome(project, outcome, ledger, state)
        {application_outcome, {ledger, state}}
      end)
      |> then(fn {outcomes, {ledger, state}} -> {outcomes, ledger, state} end)

    project_result =
      %{
        project_id: optional_string(project, :project_id),
        provider_kind: optional_string(project, :provider_kind),
        provider_scope_key: optional_string(project, :provider_scope_key),
        counts: project_counts(outcomes, []),
        reason_counts: outcome_reason_counts(outcomes),
        outcomes: outcomes,
        pending_start_intents: []
      }
      |> project_snapshot()

    {project_result, ledger, state}
  end

  defp apply_outcome(project, outcome, ledger, state) do
    outcome = outcome_snapshot(outcome)

    case outcome.status do
      "planned" ->
        apply_planned_outcome(project, outcome, ledger, state)

      "already_planned" ->
        application_outcome = already_planned_outcome(outcome)
        {application_outcome, ledger, state}

      _status ->
        application_outcome = copied_planning_outcome(outcome)
        {application_outcome, ledger, state}
    end
  end

  defp apply_planned_outcome(_project, %{intent: nil} = outcome, ledger, state) do
    application_outcome =
      outcome
      |> base_application_outcome()
      |> Map.merge(%{
        status: "manual_attention",
        reason: "missing_planned_intent",
        message: "Planned outcome did not include a pending start intent"
      })
      |> outcome_snapshot()

    {application_outcome, ledger, state}
  end

  defp apply_planned_outcome(project, outcome, ledger, state) do
    candidate = dispatch_candidate(project, outcome, state)

    case dispatch_preflight(project, ledger, candidate, state) do
      {:blocked, reason, message, extras} ->
        application_outcome =
          outcome
          |> base_application_outcome()
          |> Map.merge(%{
            status: "blocked",
            reason: reason,
            message: message,
            intent_id: optional_string(outcome.intent, :intent_id),
            attempt_id: optional_string(outcome.intent, :attempt_id),
            correlation_id: optional_string(outcome.intent, :correlation_id),
            execution_outcome:
              Map.get(extras, :execution_outcome) ||
                dispatch_execution_outcome(candidate, %{
                  status: "blocked",
                  reason_code: reason,
                  authorization_consumption_guard: value(extras, :authorization_consumption),
                  executor_result: extras,
                  side_effect_entered: false,
                  side_effect_may_have_happened: false
                })
          })
          |> Map.merge(extras)
          |> outcome_snapshot()

        {application_outcome, ledger, state}

      {:blocked, reason, message} ->
        application_outcome =
          outcome
          |> base_application_outcome()
          |> Map.merge(%{
            status: "blocked",
            reason: reason,
            message: message,
            intent_id: optional_string(outcome.intent, :intent_id),
            attempt_id: optional_string(outcome.intent, :attempt_id),
            correlation_id: optional_string(outcome.intent, :correlation_id),
            execution_outcome:
              dispatch_execution_outcome(candidate, %{
                status: "blocked",
                reason_code: reason,
                executor_result: %{message: message},
                side_effect_entered: false,
                side_effect_may_have_happened: false
              })
          })
          |> outcome_snapshot()

        {application_outcome, ledger, state}

      {:ok, authorization_decision, replay_decision} ->
        dispatch_planned_outcome(outcome, ledger, state, candidate, authorization_decision, replay_decision)
    end
  end

  defp dispatch_preflight(project, ledger, candidate, state) do
    with {:ok, authorization_decision} <- authorization_consumption(state, candidate),
         {:ok, replay_decision} <- execution_outcome_replay_guard(state, candidate, authorization_decision),
         :ok <- no_block(cutover_gate(state, candidate)),
         :ok <- no_block(activation_preflight(state, candidate)),
         :ok <- no_block(capacity_preflight(project, ledger, candidate, state)) do
      {:ok, authorization_decision, replay_decision}
    end
  end

  defp no_block(nil), do: :ok
  defp no_block(:ok), do: :ok
  defp no_block(block), do: block

  defp authorization_consumption(state, candidate) do
    guard = Map.get(state, :authorization_consumption_guard)

    case guard do
      guard when is_map(guard) ->
        input =
          Map.merge(guard, %{
            project_id: optional_string(candidate, :project_id),
            provider_scope: provider_scope_from_candidate(candidate),
            operation: "dispatch",
            side_effect_source: "dispatch_application",
            execution_mode: %{
              mode: "dispatch_application",
              dispatch_application: true,
              dispatch_mutation: true
            }
          })

        case CutoverAuthorizationConsumptionGuard.evaluate(input) do
          %{allowed: true} = decision ->
            {:ok, decision}

          decision ->
            message = "Authorization consumption guard blocked dispatch application"

            {:blocked, "authorization_consumption_blocked", message,
             %{
               authorization_consumption: decision,
               preflight:
                 preflight_snapshot(%{
                   status: "blocked",
                   reason: "authorization_consumption_blocked",
                   message: message
                 })
             }}
        end

      _guard ->
        {:ok, nil}
    end
  end

  defp execution_outcome_replay_guard(state, candidate, authorization_decision) do
    outcome =
      dispatch_execution_outcome(candidate, %{
        status: "unknown",
        reason_code: "dispatch_application_replay_check",
        authorization_consumption_guard: authorization_decision,
        side_effect_entered: true,
        side_effect_may_have_happened: true
      })

    replay_decision =
      CutoverReplayDecision.evaluate(%{
        candidate: outcome,
        authorization_consumption_guard: authorization_decision,
        cutover_execution_outcome_ledger: Map.get(state, :cutover_execution_outcome_ledger),
        cutover_execution_outcome_closeout: Map.get(state, :cutover_execution_outcome_closeout)
      })

    if replay_decision.allowed do
      {:ok, replay_decision}
    else
      {:blocked, "execution_outcome_replay_blocked", "Execution outcome ledger has unresolved dispatch application outcome",
       %{
         replay_decision: replay_decision,
         execution_outcome: replay_decision.unresolved_outcome,
         preflight:
           preflight_snapshot(%{
             status: "blocked",
             reason: "execution_outcome_replay_blocked",
             message: "Execution outcome ledger has unresolved dispatch application outcome"
           })
       }}
    end
  end

  defp activation_preflight(state, candidate) do
    project_id = optional_string(candidate, :project_id)

    case ActivationPreflight.block_reason(state.activation_preflight, project_id, :dispatch) do
      nil ->
        nil

      reason ->
        message = optional_string(reason, :message) || "Activation preflight blocked dispatch application"
        {:blocked, "activation_preflight_blocked", message}
    end
  end

  defp cutover_gate(%{cutover_gate: nil}, _candidate), do: nil

  defp cutover_gate(state, candidate) do
    project_id = optional_string(candidate, :project_id)

    case CutoverGate.block_reason(state.cutover_gate, project_id, :dispatch) do
      nil ->
        nil

      reason ->
        message = optional_string(reason, :message) || "Cutover gate blocked dispatch application"
        {:blocked, "cutover_gate_blocked", message}
    end
  end

  defp dispatch_planned_outcome(outcome, ledger, state, candidate, authorization_decision, replay_decision) do
    case safe_dispatch(ledger, candidate, now: state.now) do
      {:ok, applied_ledger, context} ->
        application_outcome =
          outcome
          |> base_application_outcome()
          |> Map.merge(%{
            status: "applied",
            reason: nil,
            message: "Planned dispatch intent was applied to the runtime ledger",
            attempt_id: context.attempt_id,
            intent_id: context.start_intent_id,
            workspace_lease_id: context.workspace_lease_id,
            correlation_id: context.correlation_id,
            preflight: preflight_snapshot(context.preflight),
            authorization_consumption: authorization_decision,
            replay_decision: replay_decision,
            execution_outcome:
              dispatch_execution_outcome(candidate, %{
                status: "succeeded",
                reason_code: "dispatch_application_applied",
                authorization_consumption_guard: authorization_decision,
                executor_result: Map.put(context, :replay_decision, replay_decision),
                side_effect_entered: true,
                side_effect_may_have_happened: true
              })
          })
          |> outcome_snapshot()

        {application_outcome, applied_ledger, %{state | ledger_changed?: true}}

      {:ignored, preflight, context} ->
        application_outcome =
          outcome
          |> base_application_outcome()
          |> Map.merge(%{
            status: "already_applied",
            reason: safe_status(value(preflight, :reason)) || "already_active",
            message: safe_optional_string(value(preflight, :message)) || "Dispatch intent already has active ledger facts",
            attempt_id: optional_string(context, :attempt_id) || optional_string(preflight, :existing_attempt_id),
            intent_id: optional_string(outcome.intent, :intent_id),
            workspace_lease_id: optional_string(outcome.intent, :workspace_lease_id),
            correlation_id: optional_string(context, :correlation_id) || optional_string(outcome.intent, :correlation_id),
            preflight: preflight_snapshot(preflight),
            authorization_consumption: authorization_decision,
            replay_decision: replay_decision,
            execution_outcome:
              dispatch_execution_outcome(candidate, %{
                status: "not_executed",
                reason_code: safe_status(value(preflight, :reason)) || "already_active",
                authorization_consumption_guard: authorization_decision,
                executor_result: Map.put(preflight, :replay_decision, replay_decision),
                side_effect_entered: false,
                side_effect_may_have_happened: false
              })
          })
          |> outcome_snapshot()

        {application_outcome, ledger, state}

      {:error, preflight, context} when is_map(preflight) ->
        application_outcome =
          outcome
          |> base_application_outcome()
          |> Map.merge(%{
            status: "blocked",
            reason: safe_status(value(preflight, :reason)) || safe_status(value(preflight, :status)) || "dispatch_preflight_blocked",
            message: safe_optional_string(value(preflight, :message)) || "Dispatch preflight blocked plan application",
            attempt_id: optional_string(context, :attempt_id) || optional_string(preflight, :existing_attempt_id),
            intent_id: optional_string(outcome.intent, :intent_id),
            workspace_lease_id: optional_string(outcome.intent, :workspace_lease_id),
            correlation_id: optional_string(context, :correlation_id) || optional_string(outcome.intent, :correlation_id),
            preflight: preflight_snapshot(preflight),
            authorization_consumption: authorization_decision,
            replay_decision: replay_decision,
            execution_outcome:
              dispatch_execution_outcome(candidate, %{
                status: "blocked",
                reason_code: safe_status(value(preflight, :reason)) || safe_status(value(preflight, :status)) || "dispatch_preflight_blocked",
                authorization_consumption_guard: authorization_decision,
                executor_result: Map.put(preflight, :replay_decision, replay_decision),
                side_effect_entered: false,
                side_effect_may_have_happened: false
              })
          })
          |> outcome_snapshot()

        {application_outcome, ledger, state}

      {:error, reason} ->
        application_outcome =
          outcome
          |> base_application_outcome()
          |> Map.merge(%{
            status: "manual_attention",
            reason: "dispatch_application_error",
            message: safe_error(reason),
            intent_id: optional_string(outcome.intent, :intent_id),
            attempt_id: optional_string(outcome.intent, :attempt_id),
            correlation_id: optional_string(outcome.intent, :correlation_id),
            authorization_consumption: authorization_decision,
            replay_decision: replay_decision,
            execution_outcome:
              dispatch_execution_outcome(candidate, %{
                status: "manual_attention",
                reason_code: "dispatch_application_error",
                authorization_consumption_guard: authorization_decision,
                executor_result: %{error: safe_error(reason), replay_decision: replay_decision},
                side_effect_entered: false,
                side_effect_may_have_happened: true
              })
          })
          |> outcome_snapshot()

        {application_outcome, ledger, state}
    end
  end

  defp safe_dispatch(ledger, candidate, opts) do
    DispatchBoundary.dispatch(ledger, candidate, opts)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason, limit: 5, printable_limit: 200)}"}
  end

  defp dispatch_candidate(_project, outcome, state) do
    intent = outcome.intent
    project_id = optional_string(outcome, :project_id)
    registry_project = Map.get(state.registry_projects, project_id, %{})
    workflow = map_value(registry_project, :workflow_summary) || %{}
    tracker = map_value(registry_project, :tracker_summary) || %{}
    source_poll = source_poll_snapshot(value(intent, :source_poll) || value(outcome, :source_poll) || %{})
    source_intake = safe_preserved_map(value(intent, :source_intake) || %{})

    planning_correlation = %{
      generated_at: state.plan.generated_at,
      outcome_id: outcome.outcome_id,
      intent_id: intent.intent_id,
      candidate_id: intent.candidate_id,
      candidate_key: intent.candidate_key
    }

    %{
      project_id: project_id,
      config_fingerprint: optional_string(intent, :config_fingerprint),
      snapshot_version: optional_string(intent, :snapshot_version),
      issue_ref: value(intent, :issue_ref) || value(outcome, :issue_ref) || %{},
      workflow: workflow,
      tracker: tracker,
      current_stage: optional_string(intent, :current_stage) || optional_string(outcome, :current_stage),
      trigger_source: :poll_plan,
      governance: %{
        boundary: "hub_dispatch_plan_application",
        source_poll: source_poll,
        source_intake: source_intake,
        planning: planning_correlation
      },
      correlation_id: optional_string(intent, :correlation_id),
      attempt_id: optional_string(intent, :attempt_id),
      start_intent_id: optional_string(intent, :intent_id),
      workspace_path: optional_string(intent, :workspace_path) || optional_string(outcome, :workspace_path),
      runtime_identity: %{
        boundary: "hub_dispatch_plan_application",
        model_only: true,
        source_model: optional_string(intent, :source_model) || "dispatch_planning",
        source_poll: source_poll,
        source_intake: source_intake,
        planning: planning_correlation
      },
      runner: optional_string(intent, :runner),
      start_command_summary: %{
        planned: true,
        applied_to_runtime_ledger: true,
        starts_agent: false,
        creates_workspace: false,
        creates_workspace_lease: true,
        writes_provider: false,
        workflow_file_path: optional_string(registry_project, :workflow_path),
        tracker_file_path: optional_string(registry_project, :tracker_config_path)
      }
    }
    |> maybe_put_project_blockers(registry_project)
  end

  defp maybe_put_project_blockers(candidate, registry_project) do
    candidate
    |> maybe_put(:project_paused, project_paused?(registry_project))
    |> maybe_put(:config_error, project_config_error(registry_project))
  end

  defp project_paused?(project) when is_map(project) do
    value(project, :paused) == true or value(project, :dispatch_enabled) == false or
      safe_status(value(project, :status)) == "paused"
  end

  defp project_paused?(_project), do: false

  defp project_config_error(project) when is_map(project) do
    cond do
      not blank?(optional_string(project, :load_error)) ->
        optional_string(project, :load_error)

      safe_status(value(project, :status)) in ["error", "config_error", "config_invalid"] ->
        "Project configuration is invalid"

      true ->
        nil
    end
  end

  defp project_config_error(_project), do: nil

  defp capacity_preflight(project, ledger, candidate, state) do
    project_id = optional_string(candidate, :project_id)

    cond do
      project_capacity_full?(project, ledger, project_id) ->
        {:blocked, "project_capacity_full", "Project dispatch application capacity is full"}

      global_capacity_full?(state.registry_projects, ledger) ->
        {:blocked, "global_capacity_full", "Hub dispatch application capacity is full"}

      true ->
        :ok
    end
  end

  defp provider_scope_from_candidate(candidate) do
    tracker = value(candidate, :tracker) || %{}
    issue_ref = value(candidate, :issue_ref) || %{}
    tracker_scope_key = optional_string(tracker, :provider_scope_key)
    issue_scope_key = optional_string(issue_ref, :provider_scope_key)
    provider_scope_key = tracker_scope_key || issue_scope_key

    %{
      kind: optional_string(tracker, :kind) || optional_string(issue_ref, :tracker_kind),
      key: provider_scope_key,
      provider_scope_key: provider_scope_key,
      scope: value(tracker, :provider_scope) || value(issue_ref, :provider_scope) || %{}
    }
  end

  defp project_capacity_full?(project, ledger, project_id) do
    case project_capacity(project) do
      nil -> false
      capacity -> active_project_attempt_count(ledger, project_id) >= capacity
    end
  end

  defp global_capacity_full?(registry_projects, ledger) do
    case registry_capacity(Map.values(registry_projects)) do
      nil -> false
      capacity -> active_total_attempt_count(ledger) >= capacity
    end
  end

  defp registry_capacity(projects) do
    capacity =
      projects
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

  defp active_total_attempt_count(ledger) do
    ledger
    |> list_value(:projects)
    |> Enum.map(&active_project_attempt_count(ledger, optional_string(&1, :project_id)))
    |> Enum.sum()
  end

  defp active_project_attempt_count(ledger, project_id) do
    ledger
    |> list_value(:projects)
    |> Enum.find(&(optional_string(&1, :project_id) == project_id))
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

  defp active_attempt?(attempt) do
    safe_status(value(attempt, :status)) in ["pending", "running"] and is_nil(value(attempt, :ended_at))
  end

  defp already_planned_outcome(outcome) do
    intent = outcome.intent || %{}
    source_model = optional_string(intent, :source_model)
    already_applied? = source_model == "runtime_ledger"

    outcome
    |> base_application_outcome()
    |> Map.merge(%{
      status: if(already_applied?, do: "already_applied", else: "already_planned"),
      reason: if(already_applied?, do: "start_intent_unresolved", else: "already_planned"),
      message:
        if(already_applied?,
          do: "Planning found an unresolved runtime ledger start intent",
          else: "Planning already has an unresolved pending intent"
        ),
      intent_id: optional_string(intent, :intent_id),
      attempt_id: optional_string(intent, :attempt_id),
      workspace_lease_id: optional_string(intent, :workspace_lease_id),
      correlation_id: optional_string(intent, :correlation_id)
    })
    |> outcome_snapshot()
  end

  defp copied_planning_outcome(outcome) do
    {status, reason} = planning_application_status(outcome)

    outcome
    |> base_application_outcome()
    |> Map.merge(%{
      status: status,
      reason: reason,
      message: outcome.message,
      preflight: outcome.preflight
    })
    |> outcome_snapshot()
  end

  defp planning_application_status(%{status: "manual_attention", reason: reason}), do: {"manual_attention", reason || "manual_attention"}
  defp planning_application_status(%{status: "capacity_unavailable", reason: reason}), do: {"skipped", reason || "capacity_unavailable"}
  defp planning_application_status(%{status: "invalid_candidate"}), do: {"skipped", "invalid_candidate"}
  defp planning_application_status(%{status: "workspace_unavailable", reason: reason}), do: {"skipped", reason || "workspace_unavailable"}

  defp planning_application_status(%{status: status, reason: reason})
       when status in ["blocked_by_active_attempt", "blocked_by_workspace", "project_paused", "config_error", "provider_backoff", "retry_backoff"] do
    {"blocked", reason || status}
  end

  defp planning_application_status(%{status: status, reason: reason}), do: {"skipped", reason || status || "skipped"}

  defp base_application_outcome(outcome) do
    intent = outcome.intent || %{}

    %{
      outcome_id: stable_id("hub-dispatch-application-outcome", Enum.join([outcome.outcome_id || outcome.issue_key || "", outcome.status || ""], "|")),
      plan_outcome_id: outcome.outcome_id,
      plan_status: outcome.status,
      plan_reason: outcome.reason,
      status: "skipped",
      reason: outcome.reason,
      message: outcome.message,
      candidate_id: outcome.candidate_id,
      candidate_key: outcome.candidate_key,
      project_id: outcome.project_id,
      provider_kind: outcome.provider_kind,
      provider_scope_key: outcome.provider_scope_key,
      issue_key: outcome.issue_key,
      issue_ref: outcome.issue_ref,
      current_stage: outcome.current_stage,
      workspace_path: outcome.workspace_path || optional_string(intent, :workspace_path),
      source_poll: source_poll_snapshot(value(intent, :source_poll) || value(outcome, :source_poll) || %{}),
      source_intake: safe_preserved_map(value(intent, :source_intake) || %{}),
      intent_id: optional_string(intent, :intent_id),
      attempt_id: optional_string(intent, :attempt_id),
      workspace_lease_id: optional_string(intent, :workspace_lease_id),
      correlation_id: optional_string(intent, :correlation_id),
      preflight: preflight_snapshot(value(outcome, :preflight) || %{}),
      safety: safety_summary()
    }
  end

  defp attach_ledger_summaries(projects, ledger_replay) do
    replay_projects = Map.new(list_value(ledger_replay, :projects), &{optional_string(&1, :project_id), &1})

    Enum.map(projects, fn project ->
      pending =
        replay_projects
        |> Map.get(project.project_id, %{})
        |> list_value(:pending_start_intents)
        |> Enum.map(&Map.put(&1, :project_id, project.project_id))

      project
      |> Map.put(:pending_start_intents, Enum.map(pending, &pending_start_intent_snapshot/1))
      |> Map.put(:counts, project_counts(project.outcomes, pending))
      |> project_snapshot()
    end)
  end

  defp pending_start_intents(ledger_replay) do
    ledger_replay
    |> list_value(:projects)
    |> Enum.flat_map(fn project ->
      project_id = optional_string(project, :project_id)

      project
      |> list_value(:pending_start_intents)
      |> Enum.map(&Map.put(&1, :project_id, project_id))
    end)
    |> Enum.map(&pending_start_intent_snapshot/1)
  end

  defp project_snapshot(project) when is_map(project) do
    outcomes =
      project
      |> list_value(:outcomes)
      |> Enum.map(&outcome_snapshot/1)

    pending_start_intents =
      project
      |> list_value(:pending_start_intents)
      |> Enum.map(&pending_start_intent_snapshot/1)

    %{
      project_id: optional_string(project, :project_id),
      provider_kind: optional_string(project, :provider_kind),
      provider_scope_key: optional_string(project, :provider_scope_key),
      counts: project_count_snapshot(value(project, :counts), outcomes, pending_start_intents),
      reason_counts: reason_count_snapshot(value(project, :reason_counts)),
      outcomes: outcomes,
      pending_start_intents: pending_start_intents
    }
  end

  defp project_snapshot(_project), do: project_snapshot(%{})

  defp outcome_snapshot(outcome) when is_map(outcome) do
    %{
      outcome_id: optional_string(outcome, :outcome_id),
      plan_outcome_id: optional_string(outcome, :plan_outcome_id),
      plan_status: safe_status(value(outcome, :plan_status)),
      plan_reason: safe_status(value(outcome, :plan_reason)),
      status: safe_status(value(outcome, :status)) || "skipped",
      reason: safe_status(value(outcome, :reason)),
      message: safe_optional_string(value(outcome, :message)),
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
      source_intake: safe_preserved_map(value(outcome, :source_intake) || %{}),
      intent: maybe_intent_snapshot(value(outcome, :intent)),
      intent_id: optional_string(outcome, :intent_id),
      attempt_id: optional_string(outcome, :attempt_id),
      workspace_lease_id: optional_string(outcome, :workspace_lease_id),
      correlation_id: optional_string(outcome, :correlation_id),
      preflight: preflight_snapshot(value(outcome, :preflight) || %{}),
      safety: safety_snapshot(value(outcome, :safety))
    }
    |> maybe_put(
      :authorization_consumption,
      authorization_consumption_snapshot(value(outcome, :authorization_consumption))
    )
    |> maybe_put(
      :execution_outcome,
      execution_outcome_snapshot(value(outcome, :execution_outcome))
    )
    |> maybe_put(
      :replay_decision,
      replay_decision_snapshot(value(outcome, :replay_decision))
    )
  end

  defp outcome_snapshot(_outcome), do: outcome_snapshot(%{})

  defp maybe_intent_snapshot(intent) when is_map(intent) do
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
      source_model: optional_string(intent, :source_model),
      source_poll: source_poll_snapshot(value(intent, :source_poll) || %{}),
      source_intake: safe_preserved_map(value(intent, :source_intake) || %{}),
      config_fingerprint: optional_string(intent, :config_fingerprint),
      snapshot_version: optional_string(intent, :snapshot_version),
      correlation_id: optional_string(intent, :correlation_id),
      runtime_identity: safe_preserved_map(value(intent, :runtime_identity) || %{}),
      runner: optional_string(intent, :runner),
      start_command_summary: safe_preserved_map(value(intent, :start_command_summary) || %{}),
      safety: safety_snapshot(value(intent, :safety))
    }
  end

  defp maybe_intent_snapshot(_intent), do: nil

  defp pending_start_intent_snapshot(intent) when is_map(intent) do
    %{
      project_id: optional_string(intent, :project_id),
      issue_key: optional_string(intent, :issue_key),
      attempt_id: optional_string(intent, :attempt_id),
      intent_id: optional_string(intent, :intent_id),
      status: safe_status(value(intent, :status)) || "pending",
      requested_at: iso8601(value(intent, :requested_at)),
      workspace_path: optional_string(intent, :workspace_path),
      workspace_lease_id: optional_string(intent, :workspace_lease_id),
      worker_host: optional_string(intent, :worker_host),
      runner: optional_string(intent, :runner),
      correlation_id: optional_string(intent, :correlation_id),
      manual_attention: truthy?(value(intent, :manual_attention)),
      runtime_identity: safe_preserved_map(value(intent, :runtime_identity) || %{}),
      start_command_summary: safe_preserved_map(value(intent, :start_command_summary) || %{})
    }
  end

  defp pending_start_intent_snapshot(_intent), do: pending_start_intent_snapshot(%{})

  defp issue_ref_snapshot(issue_ref) when is_map(issue_ref) do
    %{
      project_id: optional_string(issue_ref, :project_id),
      tracker_kind: optional_string(issue_ref, :tracker_kind),
      provider_scope: safe_preserved_map(value(issue_ref, :provider_scope) || %{}),
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

  defp authorization_consumption_snapshot(consumption) when is_map(consumption) do
    CutoverAuthorizationConsumptionGuard.to_decision(consumption)
  end

  defp authorization_consumption_snapshot(_consumption), do: nil

  defp execution_outcome_snapshot(outcome) when is_map(outcome) do
    CutoverExecutionOutcomeLedger.fact_snapshot(outcome)
  end

  defp execution_outcome_snapshot(_outcome), do: nil

  defp replay_decision_snapshot(decision) when is_map(decision) do
    CutoverReplayDecision.to_decision(decision)
  end

  defp replay_decision_snapshot(_decision), do: nil

  defp dispatch_execution_outcome(candidate, attrs) do
    attrs
    |> Map.new()
    |> Map.merge(%{
      project_id: optional_string(candidate, :project_id),
      provider_scope: provider_scope_from_candidate(candidate),
      operation: "dispatch",
      side_effect_source: "dispatch_application",
      executor_mode: %{
        mode: "dispatch_application",
        dispatch_application: true,
        dispatch_mutation: true
      }
    })
    |> CutoverExecutionOutcomeLedger.fact_snapshot()
  end

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

  defp runtime_ledger_replay_snapshot(%{projects: projects} = replay) when is_list(projects) do
    %{
      version: positive_integer(value(replay, :version)) || 1,
      generated_at: iso8601(value(replay, :generated_at)),
      updated_at: iso8601(value(replay, :updated_at)),
      projects: Enum.map(projects, &runtime_ledger_project_snapshot/1),
      conflicts: replay |> list_value(:conflicts) |> Enum.map(&safe_preserved_map/1),
      manual_attention: replay |> list_value(:manual_attention) |> Enum.map(&safe_preserved_map/1)
    }
  end

  defp runtime_ledger_replay_snapshot(_replay), do: RuntimeLedger.replay(RuntimeLedger.new())

  defp runtime_ledger_project_snapshot(project) when is_map(project) do
    %{
      project_id: optional_string(project, :project_id),
      config_fingerprint: optional_string(project, :config_fingerprint),
      snapshot_version: optional_string(project, :snapshot_version),
      counts: safe_preserved_map(value(project, :counts) || %{}),
      active_attempts: project |> list_value(:active_attempts) |> Enum.map(&safe_preserved_map/1),
      pending_start_intents: project |> list_value(:pending_start_intents) |> Enum.map(&pending_start_intent_snapshot/1),
      workspace_leases: project |> list_value(:workspace_leases) |> Enum.map(&safe_preserved_map/1),
      retry_backoff: project |> list_value(:retry_backoff) |> Enum.map(&safe_preserved_map/1),
      blocked_candidates: project |> list_value(:blocked_candidates) |> Enum.map(&safe_preserved_map/1),
      writebacks: safe_preserved_map(value(project, :writebacks) || %{}),
      active_issues: project |> list_value(:active_issues) |> Enum.map(&safe_preserved_map/1),
      conflicts: project |> list_value(:conflicts) |> Enum.map(&safe_preserved_map/1),
      manual_attention: project |> list_value(:manual_attention) |> Enum.map(&safe_preserved_map/1)
    }
  end

  defp runtime_ledger_project_snapshot(_project), do: runtime_ledger_project_snapshot(%{})

  defp count_snapshot(counts, projects, pending_start_intents) when is_map(counts) do
    counts
    |> count_snapshot()
    |> Map.put(:project_count, length(projects))
    |> Map.put(:pending_start_intent_count, length(pending_start_intents))
  end

  defp count_snapshot(_counts, projects, pending_start_intents), do: summary_counts(projects, pending_start_intents)

  defp project_count_snapshot(counts, outcomes, pending_start_intents) when is_map(counts) do
    counts
    |> count_snapshot()
    |> Map.put(:outcome_count, length(outcomes))
    |> Map.put(:pending_start_intent_count, length(pending_start_intents))
  end

  defp project_count_snapshot(_counts, outcomes, pending_start_intents), do: project_counts(outcomes, pending_start_intents)

  defp count_snapshot(counts) when is_map(counts) do
    %{
      selected_count: non_negative_integer(value(counts, :selected_count)) || 0,
      outcome_count: non_negative_integer(value(counts, :outcome_count)) || 0,
      applied_count: non_negative_integer(value(counts, :applied_count)) || 0,
      already_applied_count: non_negative_integer(value(counts, :already_applied_count)) || 0,
      already_planned_count: non_negative_integer(value(counts, :already_planned_count)) || 0,
      blocked_count: non_negative_integer(value(counts, :blocked_count)) || 0,
      manual_attention_count: non_negative_integer(value(counts, :manual_attention_count)) || 0,
      skipped_count: non_negative_integer(value(counts, :skipped_count)) || 0,
      pending_start_intent_count: non_negative_integer(value(counts, :pending_start_intent_count)) || 0,
      project_count: non_negative_integer(value(counts, :project_count)) || 0
    }
  end

  defp summary_counts(projects, pending_start_intents) do
    projects
    |> Enum.flat_map(&list_value(&1, :outcomes))
    |> project_counts(pending_start_intents)
    |> Map.put(:project_count, length(projects))
  end

  defp project_counts(outcomes, pending_start_intents) do
    %{
      selected_count: Enum.count(outcomes, &(safe_status(value(&1, :plan_status)) == "planned")),
      outcome_count: length(outcomes),
      applied_count: Enum.count(outcomes, &(safe_status(value(&1, :status)) == "applied")),
      already_applied_count: Enum.count(outcomes, &(safe_status(value(&1, :status)) == "already_applied")),
      already_planned_count: Enum.count(outcomes, &(safe_status(value(&1, :status)) == "already_planned")),
      blocked_count: Enum.count(outcomes, &(safe_status(value(&1, :status)) == "blocked")),
      manual_attention_count: Enum.count(outcomes, &(safe_status(value(&1, :status)) == "manual_attention")),
      skipped_count: Enum.count(outcomes, &(safe_status(value(&1, :status)) == "skipped")),
      pending_start_intent_count: length(pending_start_intents),
      project_count: 0
    }
  end

  defp reason_counts(projects) do
    projects
    |> Enum.flat_map(&list_value(&1, :outcomes))
    |> outcome_reason_counts()
  end

  defp outcome_reason_counts(outcomes) do
    outcomes
    |> Enum.reject(&(safe_status(value(&1, :status)) == "applied"))
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

  defp registry_projects_by_id(registry) do
    registry
    |> list_value(:projects)
    |> Map.new(fn project -> {optional_string(project, :project_id) || "", project} end)
  end

  defp touch_ledger(ledger, now_iso) do
    ledger = RuntimeLedger.to_snapshot(ledger)

    ledger
    |> Map.put(:generated_at, ledger.generated_at || now_iso)
    |> Map.put(:updated_at, now_iso)
    |> RuntimeLedger.to_snapshot()
  end

  defp safety_summary do
    %{
      model_only: true,
      starts_agent: false,
      creates_workspace: false,
      creates_workspace_lease: true,
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

  defp safe_preserved_map(value) when is_map(value) do
    SafeSummary.sanitize_map(value, output_keys: :preserve, atom_values: :preserve)
  end

  defp safe_preserved_map(_value), do: %{}

  defp safe_error(reason) do
    reason
    |> to_string()
    |> String.slice(0, 200)
  end

  defp safe_status(nil), do: nil

  defp safe_status(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> safe_status()
  end

  defp safe_status(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.:-]+/, "_")
    |> blank_to_nil()
  end

  defp safe_status(value), do: value |> to_string() |> safe_status()

  defp safe_optional_string(nil), do: nil

  defp safe_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> blank_to_nil()
    |> case do
      nil -> nil
      string -> String.slice(string, 0, 200)
    end
  end

  defp safe_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_optional_string(_value), do: nil

  defp optional_string(map, key), do: map |> value(key) |> optional_string()
  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _parse -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _parse -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

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

  defp list_value(map, key) do
    case value(map, key) do
      value when is_list(value) -> value
      _value -> []
    end
  end

  defp map_value(map, key) do
    case value(map, key) do
      value when is_map(value) -> value
      _value -> nil
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

  defp truthy?(value), do: value in [true, "true", "1", 1]
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stable_id(prefix, seed) do
    prefix <> ":" <> Base.encode16(:crypto.hash(:sha256, to_string(seed)), case: :lower)
  end
end
