defmodule SymphonyElixir.Hub.CandidateIntake do
  @moduledoc """
  Hub candidate intake projection.

  The intake boundary converts governed provider candidate-scan summaries into
  provider-neutral candidate records and runs a model-only dispatch eligibility
  precheck. It never starts agents, creates workspaces, writes providers, or
  stores raw provider response bodies.
  """

  alias SymphonyElixir.Hub.{DispatchBoundary, RuntimeLedger, SafeSummary}

  @version 1
  @candidate_list_keys [:candidates, :candidate_issues, :issues]
  @scope_identity_keys [:owner, :repo, :repository, :owner_repo, :project_slug, :namespace]

  @type summary :: map()

  @spec build(map(), [map()], keyword()) :: summary()
  def build(registry, poll_sources, opts \\ []) when is_map(registry) and is_list(poll_sources) and is_list(opts) do
    now = normalize_datetime(Keyword.get(opts, :now)) || DateTime.utc_now()
    ledger = opts |> Keyword.get(:runtime_ledger, RuntimeLedger.new()) |> RuntimeLedger.to_snapshot()
    projects_by_id = registry_projects_by_id(registry)
    capacities = capacity_snapshot(registry, ledger, opts)

    source_rows =
      poll_sources
      |> Enum.map(&source_context(&1, now))

    {projects, all_candidates, all_invalid} =
      source_rows
      |> Enum.map(&project_intake(&1, projects_by_id, ledger, capacities, now))
      |> collapse_project_intakes()

    %{
      version: @version,
      generated_at: iso8601(now),
      status: "completed",
      counts: counts(all_candidates, all_invalid),
      skipped_reasons: skipped_reason_counts(all_candidates, all_invalid),
      projects: projects
    }
    |> to_snapshot()
  end

  @spec empty(map(), keyword()) :: summary()
  def empty(registry, opts \\ []) when is_map(registry) and is_list(opts) do
    build(registry, [], opts)
  end

  @spec to_snapshot(term()) :: summary()
  def to_snapshot(summary) when is_map(summary) do
    projects =
      summary
      |> list_value(:projects)
      |> Enum.map(&project_snapshot/1)
      |> Enum.sort_by(&{&1.project_id || "", &1.provider_scope_key || ""})

    %{
      version: positive_integer(value(summary, :version)) || @version,
      generated_at: iso8601(value(summary, :generated_at)) || DateTime.utc_now() |> DateTime.to_iso8601(),
      status: safe_status(value(summary, :status)) || "idle",
      counts: count_snapshot(value(summary, :counts), projects),
      skipped_reasons: reason_count_snapshot(value(summary, :skipped_reasons)),
      projects: projects
    }
  end

  def to_snapshot(_summary) do
    to_snapshot(%{projects: [], status: "idle"})
  end

  @spec observability_snapshot(term()) :: summary() | nil
  def observability_snapshot(nil), do: nil
  def observability_snapshot(summary) when is_map(summary), do: to_snapshot(summary)
  def observability_snapshot(_summary), do: nil

  @spec tick_summary(term()) :: map()
  def tick_summary(%{candidate_count: _candidate_count} = summary) do
    summarized_tick(summary)
  end

  def tick_summary(%{"candidate_count" => _candidate_count} = summary) do
    summarized_tick(summary)
  end

  def tick_summary(summary) when is_map(summary) do
    summary = to_snapshot(summary)

    %{
      candidate_count: summary.counts.candidate_count,
      eligible_count: summary.counts.eligible_count,
      skipped_count: summary.counts.skipped_count,
      invalid_count: summary.counts.invalid_count,
      skipped_reasons: summary.skipped_reasons
    }
  end

  def tick_summary(_summary) do
    tick_summary(%{})
  end

  defp summarized_tick(summary) do
    %{
      candidate_count: integer_or_zero(non_negative_integer(value(summary, :candidate_count))),
      eligible_count: integer_or_zero(non_negative_integer(value(summary, :eligible_count))),
      skipped_count: integer_or_zero(non_negative_integer(value(summary, :skipped_count))),
      invalid_count: integer_or_zero(non_negative_integer(value(summary, :invalid_count))),
      skipped_reasons: reason_count_snapshot(value(summary, :skipped_reasons))
    }
  end

  defp project_intake(source, projects_by_id, ledger, capacities, now) do
    project = Map.get(projects_by_id, source.project_id, %{})
    raw_candidates = candidate_entries(source.result_summary)

    {candidates, invalid_candidates} =
      raw_candidates
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {raw_candidate, index}, {candidates, invalids} ->
        case normalize_candidate(raw_candidate, index, source, project) do
          {:ok, candidate} ->
            evaluated = evaluate_candidate(candidate, project, source, ledger, capacities, now)
            {[evaluated | candidates], invalids}

          {:invalid, invalid} ->
            {candidates, [invalid | invalids]}
        end
      end)

    candidates = Enum.reverse(candidates)
    invalid_candidates = Enum.reverse(invalid_candidates)

    project_summary = %{
      project_id: source.project_id,
      provider_kind: source.provider_kind,
      provider_scope_key: source.provider_scope_key,
      source_polls: [source.source_poll],
      candidates: candidates,
      invalid_candidates: invalid_candidates,
      counts: counts(candidates, invalid_candidates),
      skipped_reasons: skipped_reason_counts(candidates, invalid_candidates)
    }

    {project_summary, candidates, invalid_candidates}
  end

  defp collapse_project_intakes(rows) do
    grouped =
      Enum.reduce(rows, %{}, fn {project, candidates, invalids}, acc ->
        key = {project.project_id, project.provider_scope_key}

        Map.update(acc, key, {project, candidates, invalids}, fn {existing, existing_candidates, existing_invalids} ->
          merged_project =
            existing
            |> Map.update!(:source_polls, &(&1 ++ project.source_polls))
            |> Map.update!(:candidates, &(&1 ++ project.candidates))
            |> Map.update!(:invalid_candidates, &(&1 ++ project.invalid_candidates))

          {merged_project, existing_candidates ++ candidates, existing_invalids ++ invalids}
        end)
      end)

    projects =
      grouped
      |> Map.values()
      |> Enum.map(fn {project, candidates, invalids} ->
        project
        |> Map.put(:counts, counts(candidates, invalids))
        |> Map.put(:skipped_reasons, skipped_reason_counts(candidates, invalids))
      end)

    all_candidates = Enum.flat_map(projects, & &1.candidates)
    all_invalid = Enum.flat_map(projects, & &1.invalid_candidates)

    {projects, all_candidates, all_invalid}
  end

  defp normalize_candidate(raw_candidate, index, source, project) when is_map(raw_candidate) do
    with {:ok, identity} <- candidate_identity(raw_candidate, source, project),
         {:ok, issue_ref} <- issue_ref(identity),
         {:ok, issue_key} <- issue_key(issue_ref) do
      workspace_path =
        optional_string(raw_candidate, :workspace_path) ||
          default_workspace_path(project, issue_ref, issue_key)

      candidate = %{
        candidate_id: stable_id("hub-candidate", issue_key),
        candidate_key: issue_key,
        project_id: issue_ref.project_id,
        provider_kind: issue_ref.tracker_kind,
        provider_scope_key: issue_ref.provider_scope_key,
        issue_key: issue_key,
        issue_ref: issue_ref,
        current_stage: optional_string(raw_candidate, :current_stage) || project_start_stage(project),
        workspace_path: workspace_path,
        source_poll: source.source_poll
      }

      {:ok, candidate}
    else
      {:error, reason} -> {:invalid, invalid_candidate(source, index, reason)}
    end
  end

  defp normalize_candidate(_raw_candidate, index, source, _project) do
    {:invalid, invalid_candidate(source, index, :candidate_not_a_map)}
  end

  defp candidate_identity(candidate, source, project) do
    input_ref = map_value(candidate, :issue_ref)
    project_id = source.project_id
    provider_scope_key = source.provider_scope_key || project_provider_scope_key(project)

    provider_kind =
      source.provider_kind ||
        project_tracker_kind(project) ||
        provider_kind_from_scope_key(provider_scope_key)

    provider_scope = non_empty_map(source.provider_scope) || project_provider_scope(project) || %{}

    issue_key = optional_string(candidate, :issue_key)
    issue_identity = issue_identity(candidate, input_ref, issue_key, project_id, provider_scope_key)

    cond do
      blank?(project_id) ->
        {:error, :missing_project_id}

      candidate_project_mismatch?(candidate, input_ref, project_id) ->
        {:error, :source_project_mismatch}

      blank?(provider_scope_key) ->
        {:error, :missing_provider_scope}

      candidate_provider_scope_key_mismatch?(candidate, input_ref, provider_scope_key) ->
        {:error, :source_provider_scope_mismatch}

      blank?(provider_kind) ->
        {:error, :missing_provider_kind}

      candidate_provider_kind_mismatch?(candidate, input_ref, provider_kind) ->
        {:error, :source_provider_kind_mismatch}

      candidate_provider_scope_mismatch?(candidate, input_ref, provider_scope) ->
        {:error, :source_provider_scope_mismatch}

      is_nil(issue_identity) ->
        {:error, :missing_issue_identity}

      true ->
        {:ok,
         %{
           project_id: project_id,
           tracker_kind: provider_kind,
           provider_scope: provider_scope,
           provider_scope_key: provider_scope_key,
           provider_issue_id: issue_identity.provider_issue_id,
           provider_local_id: issue_identity.provider_local_id,
           identifier: issue_identity.identifier,
           url: safe_optional_string(value(input_ref || %{}, :url) || value(candidate, :url))
         }}
    end
  end

  defp issue_ref(identity) do
    issue_ref = %{
      project_id: identity.project_id,
      tracker_kind: identity.tracker_kind,
      provider_scope: sanitize_value(identity.provider_scope || %{}),
      provider_scope_key: identity.provider_scope_key,
      provider_issue_id: identity.provider_issue_id,
      provider_local_id: identity.provider_local_id,
      identifier: identity.identifier,
      url: identity.url
    }

    cond do
      blank?(issue_ref.project_id) ->
        {:error, :missing_project_id}

      blank?(issue_ref.provider_scope_key) ->
        {:error, :missing_provider_scope}

      blank?(issue_ref.provider_issue_id) and blank?(issue_ref.provider_local_id) and
          blank?(issue_ref.identifier) ->
        {:error, :missing_issue_identity}

      true ->
        {:ok, issue_ref}
    end
  end

  defp issue_key(issue_ref) do
    case RuntimeLedger.issue_key(issue_ref) do
      "" -> {:error, :missing_issue_identity}
      issue_key -> {:ok, issue_key}
    end
  end

  defp issue_identity(candidate, input_ref, issue_key, project_id, provider_scope_key) do
    provider_issue_id =
      safe_optional_string(value(input_ref || %{}, :provider_issue_id)) ||
        safe_optional_string(value(input_ref || %{}, :id)) ||
        safe_optional_string(value(candidate, :provider_issue_id)) ||
        safe_optional_string(value(candidate, :id))

    provider_local_id =
      safe_optional_string(value(input_ref || %{}, :provider_local_id)) ||
        safe_optional_string(value(input_ref || %{}, :number)) ||
        safe_optional_string(value(input_ref || %{}, :issue_number)) ||
        safe_optional_string(value(input_ref || %{}, :iid)) ||
        safe_optional_string(value(candidate, :provider_local_id)) ||
        safe_optional_string(value(candidate, :number)) ||
        safe_optional_string(value(candidate, :issue_number)) ||
        safe_optional_string(value(candidate, :iid))

    identifier =
      safe_optional_string(value(input_ref || %{}, :identifier)) ||
        safe_optional_string(value(candidate, :identifier))

    key_identity = issue_identity_from_key(issue_key, project_id, provider_scope_key)

    cond do
      not blank?(provider_issue_id) or not blank?(provider_local_id) or not blank?(identifier) ->
        %{
          provider_issue_id: provider_issue_id,
          provider_local_id: provider_local_id,
          identifier: identifier
        }

      not blank?(key_identity) ->
        %{
          provider_issue_id: key_identity,
          provider_local_id: nil,
          identifier: nil
        }

      true ->
        nil
    end
  end

  defp issue_identity_from_key(nil, _project_id, _provider_scope_key), do: nil

  defp issue_identity_from_key(issue_key, project_id, provider_scope_key)
       when is_binary(issue_key) and is_binary(project_id) and is_binary(provider_scope_key) do
    prefix = Enum.join([project_id, provider_scope_key, ""], ":")

    if String.starts_with?(issue_key, prefix) do
      issue_key
      |> String.replace_prefix(prefix, "")
      |> safe_optional_string()
    end
  end

  defp issue_identity_from_key(_issue_key, _project_id, _provider_scope_key), do: nil

  defp evaluate_candidate(candidate, project, source, ledger, capacities, now) do
    cond do
      project_config_error?(project) ->
        skip_candidate(candidate, "config_error", optional_string(project, :load_error) || "Project configuration is invalid")

      project_paused?(project) ->
        skip_candidate(candidate, "project_paused", "Project is paused")

      source.manual_attention ->
        skip_candidate(candidate, "manual_attention", "Provider result requires manual attention")

      provider_backpressure_reason(source, now) ->
        reason = provider_backpressure_reason(source, now)
        skip_candidate(candidate, reason, "Provider poll result is under backoff or unavailable")

      ledger_manual_attention?(ledger, candidate.project_id, candidate.issue_key) ->
        skip_candidate(candidate, "manual_attention", "Runtime ledger requires manual attention for this issue")

      blank?(candidate.workspace_path) ->
        skip_candidate(candidate, "workspace_unavailable", "Candidate does not have a dispatch workspace path")

      true ->
        candidate
        |> dispatch_precheck(project, source, ledger, now)
        |> capacity_precheck(project, ledger, capacities)
    end
  end

  defp dispatch_precheck(candidate, project, source, ledger, now) do
    dispatch_candidate =
      %{
        project_id: candidate.project_id,
        config_fingerprint: optional_string(project, :fingerprint) || optional_string(project, :config_fingerprint),
        snapshot_version: optional_string(project, :snapshot_version),
        issue_ref: candidate.issue_ref,
        workflow: map_value(project, :workflow_summary) || %{},
        tracker: map_value(project, :tracker_summary) || %{},
        current_stage: candidate.current_stage,
        trigger_source: :poll_plan,
        governance: %{
          boundary: "hub_candidate_intake",
          source_poll: candidate.source_poll,
          provider_status: source.result_status
        },
        correlation_id: stable_id("hub-candidate-intake", Enum.join([candidate.issue_key, candidate.source_poll.request_id || ""], "|")),
        workspace_path: candidate.workspace_path
      }

    case DispatchBoundary.build_context(dispatch_candidate, ledger, now: now) do
      {:ok, context} ->
        preflight = context.preflight

        if preflight.can_start? do
          ready_candidate(candidate, preflight)
        else
          skip_candidate(candidate, preflight_skip_reason(preflight), preflight.message, preflight_snapshot(preflight))
        end

      {:error, reason} ->
        skip_candidate(candidate, "invalid_candidate", safe_error(reason))
    end
  end

  defp capacity_precheck(candidate, project, ledger, capacities) do
    if get_in(candidate, [:dispatch_evaluation, :eligible]) == true do
      cond do
        project_capacity_full?(project, ledger, candidate.project_id) ->
          skip_candidate(candidate, "project_capacity_full", "Project agent capacity is full")

        global_capacity_full?(capacities) ->
          skip_candidate(candidate, "global_capacity_full", "Hub agent capacity is full")

        true ->
          candidate
      end
    else
      candidate
    end
  end

  defp ready_candidate(candidate, preflight) do
    Map.put(candidate, :dispatch_evaluation, %{
      status: "ready_for_dispatch_evaluation",
      eligible: true,
      skipped_reason: nil,
      preflight: preflight_snapshot(preflight)
    })
  end

  defp skip_candidate(candidate, reason, message, extra \\ %{}) do
    evaluation =
      %{
        status: "skipped",
        eligible: false,
        skipped_reason: reason,
        message: safe_optional_string(message)
      }
      |> Map.merge(extra)

    Map.put(candidate, :dispatch_evaluation, evaluation)
  end

  defp invalid_candidate(source, index, reason) do
    %{
      status: "skipped",
      skipped_reason: "invalid_candidate",
      invalid_reason: Atom.to_string(reason),
      candidate_index: index,
      project_id: source.project_id,
      provider_scope_key: source.provider_scope_key,
      source_poll: source.source_poll
    }
  end

  defp source_context(source, now) when is_map(source) do
    result = map_value(source, :result) || source
    entry = map_value(source, :entry) || %{}
    request = map_value(source, :request) || get_in_map(entry, [:governance, :request]) || %{}
    attempt = map_value(source, :attempt) || %{}
    result_fact = map_value(source, :result_fact) || %{}

    provider_scope =
      map_value(request, :provider_scope) ||
        map_value(entry, :provider_scope) ||
        get_in_map(entry, [:tracker_identity, :provider_scope]) ||
        %{}

    project_id =
      optional_string(request, :project_id) ||
        optional_string(entry, :project_id) ||
        optional_string(result_fact, :project_id) ||
        optional_string(result, :project_id)

    provider_scope_key =
      optional_string(request, :provider_scope_key) ||
        optional_string(entry, :provider_scope_key) ||
        optional_string(result_fact, :provider_scope_key) ||
        optional_string(result, :provider_scope_key)

    provider_kind =
      optional_string(request, :provider_kind) ||
        optional_string(entry, :provider_kind) ||
        get_in_map(entry, [:tracker_identity, :kind]) ||
        optional_string(result_fact, :provider_kind) ||
        provider_kind_from_scope_key(provider_scope_key)

    result_status = safe_status(value(result, :status)) || "unknown_result"
    backoff_until = normalize_datetime(value(result, :backoff_until) || value(result_fact, :backoff_until))
    finished_at = normalize_datetime(value(source, :finished_at) || value(result_fact, :finished_at)) || now

    source_poll = %{
      project_id: project_id,
      provider_kind: provider_kind,
      provider_scope_key: provider_scope_key,
      request_id: optional_string(result, :request_id) || optional_string(request, :request_id),
      logical_key: optional_string(result, :logical_key) || optional_string(request, :logical_key),
      poll_attempt_id: optional_string(attempt, :attempt_id) || optional_string(result_fact, :attempt_id),
      poll_result_status: result_status,
      retry_after_ms: non_negative_integer(value(result, :retry_after_ms)),
      backoff_until: iso8601(backoff_until),
      finished_at: iso8601(finished_at)
    }

    %{
      project_id: project_id,
      provider_kind: provider_kind,
      provider_scope: sanitize_value(provider_scope),
      provider_scope_key: provider_scope_key,
      result_status: result_status,
      result_summary: map_value(result, :result_summary) || %{},
      manual_attention: truthy?(value(result, :manual_attention)),
      retry_after_ms: non_negative_integer(value(result, :retry_after_ms)),
      backoff_until: backoff_until,
      source_poll: source_poll
    }
  end

  defp source_context(_source, now) do
    source_context(%{finished_at: now}, now)
  end

  defp candidate_entries(summary) do
    Enum.find_value(@candidate_list_keys, [], fn key ->
      case value(summary, key) do
        candidates when is_list(candidates) -> candidates
        _value -> nil
      end
    end)
  end

  defp registry_projects_by_id(registry) do
    registry
    |> list_value(:projects)
    |> Map.new(fn project -> {required_string(project, :project_id), project} end)
  end

  defp project_paused?(project) do
    value(project, :paused) == true or value(project, :dispatch_enabled) == false or
      safe_status(value(project, :status)) == "paused"
  end

  defp project_config_error?(project) do
    safe_status(value(project, :status)) in ["error", "config_error", "config_invalid"] or
      not blank?(optional_string(project, :load_error))
  end

  defp provider_backpressure_reason(source, now) do
    cond do
      source.result_status == "rate_limited" ->
        "provider_rate_limit"

      source.result_status == "circuit_open" ->
        "provider_circuit_open"

      future_time?(source.backoff_until, now) ->
        "provider_backoff"

      source.result_status in ["retryable_failure", "timed_out"] ->
        "provider_backoff"

      true ->
        nil
    end
  end

  defp project_capacity_full?(project, ledger, project_id) do
    case project_capacity(project) do
      nil -> false
      capacity -> active_project_attempt_count(ledger, project_id) >= capacity
    end
  end

  defp global_capacity_full?(%{global_capacity: nil}), do: false

  defp global_capacity_full?(%{global_capacity: capacity, active_total: active_total}) do
    active_total >= capacity
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

  defp active_total_attempt_count(ledger) do
    ledger
    |> list_value(:projects)
    |> Enum.map(&active_project_attempt_count(ledger, required_string(&1, :project_id)))
    |> Enum.sum()
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

  defp active_attempt?(attempt) do
    safe_status(value(attempt, :status)) in ["pending", "running"] and is_nil(value(attempt, :ended_at))
  end

  defp ledger_manual_attention?(ledger, project_id, issue_key) do
    project = ledger |> list_value(:projects) |> Enum.find(&(required_string(&1, :project_id) == project_id))
    issue = project && Enum.find(list_value(project, :issues), &(required_string(&1, :issue_key) == issue_key))

    issue_manual_attention?(issue) or
      Enum.any?(list_value(project || %{}, :start_intents), fn intent ->
        required_string(intent, :issue_key) == issue_key and
          (truthy?(value(intent, :manual_attention)) or safe_status(value(intent, :status)) == "manual_attention")
      end)
  end

  defp issue_manual_attention?(nil), do: false

  defp issue_manual_attention?(issue) do
    safe_status(value(issue, :claim_status) || value(issue, :status)) == "manual_attention" or
      Enum.any?(list_value(issue, :writebacks), &truthy?(value(&1, :manual_attention)))
  end

  defp default_workspace_path(project, issue_ref, issue_key) do
    case project |> map_value(:runtime_summary) |> optional_string(:workspace_root) do
      nil -> nil
      root -> Path.join(root, workspace_slug(issue_ref, issue_key))
    end
  end

  defp workspace_slug(issue_ref, issue_key) do
    slug_source =
      issue_ref.provider_local_id ||
        issue_ref.identifier ||
        issue_ref.provider_issue_id ||
        issue_key

    slug =
      slug_source
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 80)

    if slug == "", do: String.slice(stable_id("issue", issue_key), 0, 24), else: slug
  end

  defp preflight_skip_reason(preflight) do
    case {safe_status(value(preflight, :status)), safe_status(value(preflight, :reason))} do
      {"already_active", "active_attempt_exists"} -> "duplicate_active_attempt"
      {"already_active", "start_intent_unresolved"} -> "duplicate_active_attempt"
      {"workspace_conflict", _reason} -> "workspace_busy"
      {"retry_backoff", _reason} -> "retry_backoff"
      {_status, "project_paused"} -> "project_paused"
      {_status, "config_error"} -> "config_error"
      {_status, "provider_backpressure"} -> "provider_backoff"
      {status, _reason} when status in ["project_paused", "config_error", "provider_backpressure"] -> status
      {status, _reason} when not is_nil(status) -> status
      {_status, reason} when not is_nil(reason) -> reason
      _other -> "blocked"
    end
  end

  defp preflight_snapshot(preflight) do
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

  defp counts(candidates, invalid_candidates) do
    eligible_count = Enum.count(candidates, &(get_in(&1, [:dispatch_evaluation, :eligible]) == true))
    skipped_valid_count = length(candidates) - eligible_count
    invalid_count = length(invalid_candidates)

    %{
      candidate_count: length(candidates) + invalid_count,
      valid_candidate_count: length(candidates),
      eligible_count: eligible_count,
      skipped_count: skipped_valid_count + invalid_count,
      invalid_count: invalid_count,
      project_count: 0
    }
  end

  defp skipped_reason_counts(candidates, invalid_candidates) do
    candidate_reasons =
      candidates
      |> Enum.map(&get_in(&1, [:dispatch_evaluation, :skipped_reason]))
      |> Enum.reject(&blank?/1)

    invalid_reasons = Enum.map(invalid_candidates, fn _invalid -> "invalid_candidate" end)

    (candidate_reasons ++ invalid_reasons)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {reason, _count} -> reason end)
    |> Map.new()
  end

  defp project_snapshot(project) when is_map(project) do
    candidates =
      project
      |> list_value(:candidates)
      |> Enum.map(&candidate_snapshot/1)

    invalid_candidates =
      project
      |> list_value(:invalid_candidates)
      |> Enum.map(&invalid_candidate_snapshot/1)

    counts =
      project
      |> value(:counts)
      |> count_snapshot(candidates, invalid_candidates)

    %{
      project_id: optional_string(project, :project_id),
      provider_kind: optional_string(project, :provider_kind),
      provider_scope_key: optional_string(project, :provider_scope_key),
      counts: counts,
      skipped_reasons: reason_count_snapshot(value(project, :skipped_reasons)),
      source_polls: project |> list_value(:source_polls) |> Enum.map(&source_poll_snapshot/1),
      candidates: candidates,
      invalid_candidates: invalid_candidates
    }
  end

  defp project_snapshot(_project), do: project_snapshot(%{})

  defp candidate_snapshot(candidate) when is_map(candidate) do
    %{
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
      dispatch_evaluation: evaluation_snapshot(value(candidate, :dispatch_evaluation) || %{})
    }
  end

  defp candidate_snapshot(_candidate), do: candidate_snapshot(%{})

  defp invalid_candidate_snapshot(invalid) when is_map(invalid) do
    %{
      status: "skipped",
      skipped_reason: "invalid_candidate",
      invalid_reason: safe_status(value(invalid, :invalid_reason)) || "invalid_candidate",
      candidate_index: non_negative_integer(value(invalid, :candidate_index)),
      project_id: optional_string(invalid, :project_id),
      provider_scope_key: optional_string(invalid, :provider_scope_key),
      source_poll: source_poll_snapshot(value(invalid, :source_poll) || %{})
    }
  end

  defp invalid_candidate_snapshot(_invalid), do: invalid_candidate_snapshot(%{})

  defp issue_ref_snapshot(issue_ref) when is_map(issue_ref) do
    %{
      project_id: optional_string(issue_ref, :project_id),
      tracker_kind: optional_string(issue_ref, :tracker_kind),
      provider_scope: sanitize_value(value(issue_ref, :provider_scope) || %{}),
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

  defp evaluation_snapshot(evaluation) when is_map(evaluation) do
    %{
      status: safe_status(value(evaluation, :status)) || "skipped",
      eligible: value(evaluation, :eligible) == true,
      skipped_reason: safe_status(value(evaluation, :skipped_reason)),
      message: safe_optional_string(value(evaluation, :message)),
      preflight: preflight_snapshot(value(evaluation, :preflight) || %{})
    }
  end

  defp evaluation_snapshot(_evaluation), do: evaluation_snapshot(%{})

  defp count_snapshot(counts, projects) when is_map(counts) and is_list(projects) do
    counts
    |> count_snapshot()
    |> Map.put(:project_count, length(projects))
  end

  defp count_snapshot(_counts, projects) when is_list(projects) do
    candidates = Enum.flat_map(projects, &list_value(&1, :candidates))
    invalids = Enum.flat_map(projects, &list_value(&1, :invalid_candidates))

    candidates
    |> counts(invalids)
    |> Map.put(:project_count, length(projects))
  end

  defp count_snapshot(counts, candidates, invalids) when is_map(counts) and is_list(candidates) and is_list(invalids) do
    counts
    |> count_snapshot()
    |> Map.put(:candidate_count, length(candidates) + length(invalids))
    |> Map.put(:valid_candidate_count, length(candidates))
    |> Map.put(:invalid_count, length(invalids))
  end

  defp count_snapshot(_counts, candidates, invalids) when is_list(candidates) and is_list(invalids) do
    counts(candidates, invalids)
  end

  defp count_snapshot(counts) when is_map(counts) do
    %{
      candidate_count: non_negative_integer(value(counts, :candidate_count)) || 0,
      valid_candidate_count: non_negative_integer(value(counts, :valid_candidate_count)) || 0,
      eligible_count: non_negative_integer(value(counts, :eligible_count)) || 0,
      skipped_count: non_negative_integer(value(counts, :skipped_count)) || 0,
      invalid_count: non_negative_integer(value(counts, :invalid_count)) || 0,
      project_count: non_negative_integer(value(counts, :project_count)) || 0
    }
  end

  defp reason_count_snapshot(reasons) when is_map(reasons) do
    reasons
    |> Enum.map(fn {reason, count} -> {safe_status(reason), non_negative_integer(count) || 0} end)
    |> Enum.reject(fn {reason, count} -> blank?(reason) or count <= 0 end)
    |> Map.new()
  end

  defp reason_count_snapshot(_reasons), do: %{}

  defp candidate_project_mismatch?(candidate, input_ref, project_id) do
    [optional_string(candidate, :project_id), optional_string(input_ref || %{}, :project_id)]
    |> Enum.any?(&present_mismatch?(&1, project_id))
  end

  defp candidate_provider_scope_key_mismatch?(candidate, input_ref, provider_scope_key) do
    [optional_string(candidate, :provider_scope_key), optional_string(input_ref || %{}, :provider_scope_key)]
    |> Enum.any?(&present_mismatch?(&1, provider_scope_key))
  end

  defp candidate_provider_kind_mismatch?(candidate, input_ref, provider_kind) do
    [
      optional_string(candidate, :provider_kind),
      optional_string(candidate, :tracker_kind),
      optional_string(input_ref || %{}, :provider_kind),
      optional_string(input_ref || %{}, :tracker_kind)
    ]
    |> Enum.any?(&present_mismatch?(normalize_kind(&1), normalize_kind(provider_kind)))
  end

  defp candidate_provider_scope_mismatch?(candidate, input_ref, provider_scope) do
    expected_scope = stringify_nested_keys(provider_scope || %{})

    [
      map_value(candidate, :provider_scope),
      map_value(input_ref || %{}, :provider_scope),
      provider_scope_from_identity_fields(candidate),
      provider_scope_from_identity_fields(input_ref || %{})
    ]
    |> Enum.reject(&empty_map?/1)
    |> Enum.any?(&provider_scope_mismatch?(&1, expected_scope))
  end

  defp provider_scope_from_identity_fields(map) when is_map(map) do
    @scope_identity_keys
    |> Enum.reduce(%{}, fn key, scope ->
      case optional_string(map, key) do
        nil -> scope
        value -> Map.put(scope, Atom.to_string(key), value)
      end
    end)
  end

  defp provider_scope_from_identity_fields(_map), do: %{}

  defp provider_scope_mismatch?(scope, expected_scope) do
    scope
    |> stringify_nested_keys()
    |> canonical_scope()
    |> Enum.any?(fn {key, actual_value} ->
      expected_value = Map.get(expected_scope, key)

      not blank?(actual_value) and not blank?(expected_value) and
        normalize_scope_value(actual_value) != normalize_scope_value(expected_value)
    end)
  end

  defp canonical_scope(scope) when is_map(scope) do
    owner = optional_string(scope, "owner")
    repo = optional_string(scope, "repo")
    repository = optional_string(scope, "repository")
    owner_repo = optional_string(scope, "owner_repo") || optional_string(scope, "owner/repo")
    project_slug = optional_string(scope, "project_slug")
    namespace = optional_string(scope, "namespace")

    %{}
    |> maybe_put_scope("owner", owner)
    |> maybe_put_scope("repo", repo)
    |> maybe_merge_owner_repo(repository)
    |> maybe_merge_owner_repo(owner_repo)
    |> maybe_put_scope("project_slug", project_slug)
    |> maybe_put_scope("namespace", namespace)
  end

  defp present_mismatch?(nil, _expected), do: false
  defp present_mismatch?(_actual, nil), do: false
  defp present_mismatch?(actual, expected), do: actual != expected

  defp normalize_kind(nil), do: nil
  defp normalize_kind(kind) when is_binary(kind), do: kind |> String.trim() |> String.downcase() |> blank_to_nil()
  defp normalize_kind(kind) when is_atom(kind), do: kind |> Atom.to_string() |> normalize_kind()
  defp normalize_kind(_kind), do: nil

  defp normalize_scope_value(value) when is_binary(value), do: String.downcase(value)
  defp normalize_scope_value(value), do: value

  defp maybe_merge_owner_repo(scope, nil), do: scope

  defp maybe_merge_owner_repo(scope, owner_repo) do
    case String.split(owner_repo, "/", parts: 2) do
      [owner, repo] ->
        scope
        |> maybe_put_scope("owner", owner)
        |> maybe_put_scope("repo", repo)

      _other ->
        scope
    end
  end

  defp maybe_put_scope(scope, _key, nil), do: scope
  defp maybe_put_scope(scope, _key, ""), do: scope
  defp maybe_put_scope(scope, key, value), do: Map.put_new(scope, key, value)

  defp empty_map?(value), do: value == %{} or is_nil(value)

  defp project_start_stage(project), do: project |> map_value(:workflow_summary) |> optional_string(:start_stage)
  defp project_tracker_kind(project), do: project |> map_value(:tracker_summary) |> optional_string(:kind)
  defp project_provider_scope_key(project), do: project |> map_value(:tracker_summary) |> optional_string(:provider_scope_key)
  defp project_provider_scope(project), do: project |> map_value(:tracker_summary) |> map_value(:provider_scope)

  defp provider_kind_from_scope_key(nil), do: nil

  defp provider_kind_from_scope_key(scope_key) when is_binary(scope_key) do
    scope_key
    |> String.split(":", parts: 2)
    |> List.first()
    |> safe_optional_string()
  end

  defp future_time?(nil, _now), do: false

  defp future_time?(datetime, now) do
    case {normalize_datetime(datetime), normalize_datetime(now)} do
      {%DateTime{} = datetime, %DateTime{} = now} -> DateTime.compare(datetime, now) == :gt
      _other -> false
    end
  end

  defp get_in_map(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case map_value(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp get_in_map(_map, _keys), do: nil

  defp map_value(map, key) do
    case value(map, key) do
      value when is_map(value) -> value
      _value -> nil
    end
  end

  defp non_empty_map(value) when is_map(value) and map_size(value) > 0, do: value
  defp non_empty_map(_value), do: nil

  defp list_value(map, key) do
    case value(map, key) do
      value when is_list(value) -> value
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

  defp required_string(map, key), do: optional_string(map, key) || ""

  defp optional_string(map, key), do: map |> value(key) |> optional_string()
  defp optional_string(nil), do: nil

  defp optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> blank_to_nil()
  end

  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(_value), do: nil

  defp safe_optional_string(value) do
    case optional_string(value) do
      nil -> nil
      string -> if SafeSummary.sensitive_value?(string), do: nil, else: String.slice(string, 0, 500)
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _parse -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _parse -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp integer_or_zero(nil), do: 0
  defp integer_or_zero(value), do: value

  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(%DateTime{} = value), do: value

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp normalize_datetime(_value), do: nil

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      {:error, _reason} -> safe_optional_string(value)
    end
  end

  defp iso8601(_value), do: nil

  defp safe_status(nil), do: nil
  defp safe_status(value) when is_atom(value), do: Atom.to_string(value)

  defp safe_status(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> blank_to_nil()
  end

  defp safe_status(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_status(_value), do: nil

  defp safe_error(reason), do: inspect(reason, limit: 5, printable_limit: 200)

  defp stable_id(prefix, seed) do
    prefix <> ":" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
  end

  defp sanitize_value(value), do: SafeSummary.sanitize_value(value, output_keys: :preserve)

  defp stringify_nested_keys(value) when is_map(value) do
    Map.new(value, fn {key, raw_value} -> {to_string(key), stringify_nested_keys(raw_value)} end)
  end

  defp stringify_nested_keys(value) when is_list(value), do: Enum.map(value, &stringify_nested_keys/1)
  defp stringify_nested_keys(value), do: value

  defp truthy?(value), do: value in [true, "true", "1", 1]
end
