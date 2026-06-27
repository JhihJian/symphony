defmodule SymphonyElixir.Hub.DispatchBoundary do
  @moduledoc """
  Model-only Hub atomic dispatch boundary.

  This module turns a provider/poll candidate into recoverable claim, attempt,
  workspace lease, start intent, and run context ledger state. It does not start
  workers, mutate trackers, perform provider I/O, or replace the legacy
  `SymphonyElixir.Orchestrator` dispatch path.
  """

  alias SymphonyElixir.Hub.IssueRef
  alias SymphonyElixir.Hub.RuntimeLedger

  @trigger_sources [:poll_plan, :manual_refresh, :webhook, :running_reconciliation, :recovery]
  @failure_statuses [:retry_queued, :blocked, :released, :manual_attention]

  @type dispatch_context :: %{
          required(:project_id) => String.t(),
          required(:config_fingerprint) => String.t() | nil,
          required(:snapshot_version) => String.t() | nil,
          required(:issue_key) => String.t(),
          required(:issue_ref) => map(),
          required(:workflow) => map(),
          required(:tracker) => map(),
          required(:current_stage) => String.t() | nil,
          required(:trigger_source) => atom(),
          required(:governance) => map(),
          required(:correlation_id) => String.t(),
          required(:attempt_number) => non_neg_integer(),
          required(:attempt_seed) => String.t(),
          required(:attempt_id) => String.t(),
          required(:workspace_path) => String.t(),
          required(:workspace_lease_id) => String.t(),
          required(:start_intent_id) => String.t(),
          required(:worker_host) => String.t() | nil,
          required(:runtime_identity) => map(),
          required(:runner) => String.t() | nil,
          required(:start_command_summary) => map(),
          required(:preflight) => preflight()
        }

  @type preflight :: %{
          required(:status) => atom(),
          required(:can_start?) => boolean(),
          required(:reason) => atom() | nil,
          required(:message) => String.t() | nil,
          required(:existing_attempt_id) => String.t() | nil,
          required(:existing_workspace_path) => String.t() | nil,
          required(:retry_due_at) => String.t() | nil,
          required(:blocked_by) => [atom()]
        }

  @type dispatch_result ::
          {:ok, map(), dispatch_context()}
          | {:ignored, preflight(), dispatch_context()}
          | {:error, preflight(), dispatch_context()}

  @spec build_context(map(), map(), keyword()) :: {:ok, dispatch_context()} | {:error, term()}
  def build_context(candidate, ledger \\ RuntimeLedger.new(), opts \\ [])
      when is_map(candidate) and is_map(ledger) and is_list(opts) do
    with {:ok, issue_ref} <- normalize_issue_ref(candidate),
         {:ok, project_id} <- required_string(candidate, :project_id),
         :ok <- validate_issue_project(project_id, issue_ref),
         {:ok, workspace_path} <- required_workspace_path(candidate),
         {:ok, trigger_source} <-
           normalize_trigger_source(value(candidate, :trigger_source) || value(candidate, :source)) do
      ledger = RuntimeLedger.to_snapshot(ledger)
      issue_key = RuntimeLedger.issue_key(issue_ref)
      attempt_number = next_attempt_number(ledger, project_id, issue_key, value(candidate, :attempt_number))

      correlation_id =
        optional_string(candidate, :correlation_id) ||
          default_correlation_id(project_id, issue_key, trigger_source)

      attempt_seed =
        optional_string(candidate, :attempt_seed) ||
          Enum.join([project_id, issue_key, attempt_number, correlation_id], "|")

      attempt_id = optional_string(candidate, :attempt_id) || stable_id("hub-attempt", attempt_seed)

      workspace_lease_id =
        optional_string(candidate, :workspace_lease_id) ||
          stable_id("hub-workspace-lease", Enum.join([attempt_id, workspace_path], "|"))

      start_intent_id = optional_string(candidate, :start_intent_id) || stable_id("hub-start-intent", attempt_id)

      config_fingerprint =
        optional_string(candidate, :config_fingerprint) ||
          optional_string(candidate, :fingerprint)

      context =
        %{
          project_id: project_id,
          config_fingerprint: config_fingerprint,
          snapshot_version: optional_string(candidate, :snapshot_version),
          issue_key: issue_key,
          issue_ref: safe_issue_ref(issue_ref),
          workflow: workflow_summary(candidate),
          tracker: tracker_summary(candidate),
          current_stage:
            optional_string(candidate, :current_stage) ||
              get_in(workflow_summary(candidate), [:start_stage]),
          trigger_source: trigger_source,
          governance: governance_summary(candidate),
          correlation_id: correlation_id,
          attempt_number: attempt_number,
          attempt_seed: attempt_seed,
          attempt_id: attempt_id,
          workspace_path: workspace_path,
          workspace_lease_id: workspace_lease_id,
          start_intent_id: start_intent_id,
          worker_host: optional_string(candidate, :worker_host),
          runtime_identity: sanitize_value(value(candidate, :runtime_identity) || %{}),
          runner: optional_string(candidate, :runner),
          start_command_summary: sanitize_value(value(candidate, :start_command_summary) || %{}),
          preflight: preflight(ledger, project_id, issue_key, workspace_path, candidate)
        }

      {:ok, context}
    end
  end

  @spec dispatch(map(), map(), keyword()) :: dispatch_result()
  def dispatch(ledger, candidate, opts \\ []) when is_map(ledger) and is_map(candidate) and is_list(opts) do
    with {:ok, context} <- build_context(candidate, ledger, opts) do
      cond do
        context.preflight.status == :allowed ->
          {:ok, apply_dispatch(RuntimeLedger.to_snapshot(ledger), context, opts), context}

        context.preflight.status == :already_active ->
          {:ignored, context.preflight, context}

        true ->
          {:error, context.preflight, context}
      end
    end
  end

  @spec acknowledge_start(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def acknowledge_start(ledger, ack, opts \\ []) when is_map(ledger) and is_map(ack) and is_list(opts) do
    now = normalize_time(Keyword.get(opts, :now)) || normalize_time(DateTime.utc_now())
    session_id = optional_string(ack, :session_id)

    ledger =
      ledger
      |> RuntimeLedger.to_snapshot()
      |> update_issue(required_string!(ack, :project_id), required_string!(ack, :issue_key), fn issue ->
        issue
        |> Map.put(:claim_status, :running)
        |> Map.put(:terminal_reason, nil)
      end)
      |> update_attempt(
        required_string!(ack, :project_id),
        required_string!(ack, :issue_key),
        required_string!(ack, :attempt_id),
        fn attempt ->
          run_context =
            attempt.run_context
            |> Map.put(:session_id, session_id || attempt.run_context.session_id)
            |> Map.put(:started_at, normalize_time(value(ack, :started_at)) || now)
            |> Map.put(:last_activity_at, normalize_time(value(ack, :last_activity_at)) || now)
            |> Map.put(:status, "running")

          attempt
          |> Map.put(:status, :running)
          |> Map.put(:started_at, attempt.started_at || now)
          |> Map.put(:worker_host, optional_string(ack, :worker_host) || attempt.worker_host)
          |> Map.put(:agent_session, %{session_id: session_id, last_activity_at: normalize_time(value(ack, :last_activity_at)) || now, usage: sanitize_value(value(ack, :usage) || %{})})
          |> Map.put(:run_context, run_context)
        end
      )
      |> update_start_intent(required_string!(ack, :project_id), required_string!(ack, :start_intent_id), fn intent ->
        intent
        |> Map.put(:status, :acknowledged)
        |> Map.put(:acked_at, normalize_time(value(ack, :acked_at)) || now)
        |> Map.put(:worker_host, optional_string(ack, :worker_host) || intent.worker_host)
        |> Map.put(:manual_attention, false)
      end)

    {:ok, RuntimeLedger.to_snapshot(ledger)}
  end

  @spec record_start_failure(map(), map(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def record_start_failure(ledger, failure, failure_status, opts \\ []) when is_map(ledger) and is_map(failure) and failure_status in @failure_statuses and is_list(opts) do
    now = normalize_time(Keyword.get(opts, :now)) || normalize_time(DateTime.utc_now())
    project_id = required_string!(failure, :project_id)
    issue_key = required_string!(failure, :issue_key)
    attempt_id = required_string!(failure, :attempt_id)
    start_intent_id = required_string!(failure, :start_intent_id)
    error_summary = optional_string(failure, :error_summary) || Atom.to_string(failure_status)

    ledger =
      ledger
      |> RuntimeLedger.to_snapshot()
      |> update_attempt(project_id, issue_key, attempt_id, fn attempt ->
        run_context =
          attempt.run_context
          |> Map.put(:exit_summary, sanitize_value(%{status: Atom.to_string(failure_status), error_summary: error_summary}))
          |> Map.put(:status, Atom.to_string(failure_status))

        attempt
        |> Map.put(:status, failure_attempt_status(failure_status))
        |> Map.put(:ended_at, failure_attempt_ended_at(failure_status, now))
        |> Map.put(:terminal_reason, error_summary)
        |> Map.put(:run_context, run_context)
      end)
      |> update_start_intent(project_id, start_intent_id, fn intent ->
        intent
        |> Map.put(:status, failure_start_intent_status(failure_status))
        |> Map.put(:finished_at, if(failure_status == :manual_attention, do: nil, else: now))
        |> Map.put(:error_summary, error_summary)
        |> Map.put(:manual_attention, failure_status == :manual_attention)
      end)
      |> update_issue(project_id, issue_key, fn issue ->
        issue
        |> Map.put(:claim_status, failure_status)
        |> maybe_put_retry_backoff(failure_status, attempt_id, failure, opts)
        |> maybe_put_released_at(failure_status, now)
        |> Map.put(:terminal_reason, error_summary)
      end)
      |> maybe_release_workspace_on_failure(project_id, issue_key, attempt_id, failure_status, now)

    {:ok, RuntimeLedger.to_snapshot(ledger)}
  end

  @spec release_attempt(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def release_attempt(ledger, release, opts \\ []) when is_map(ledger) and is_map(release) and is_list(opts) do
    now = normalize_time(Keyword.get(opts, :now)) || normalize_time(DateTime.utc_now())
    project_id = required_string!(release, :project_id)
    issue_key = required_string!(release, :issue_key)
    attempt_id = required_string!(release, :attempt_id)
    reason = optional_string(release, :reason) || "released"

    ledger =
      ledger
      |> RuntimeLedger.to_snapshot()
      |> update_attempt(project_id, issue_key, attempt_id, fn attempt ->
        run_context =
          attempt.run_context
          |> Map.put(:exit_summary, sanitize_value(%{status: "released", reason: reason}))
          |> Map.put(:status, "released")

        attempt
        |> Map.put(:status, :succeeded)
        |> Map.put(:ended_at, now)
        |> Map.put(:terminal_reason, reason)
        |> Map.put(:run_context, run_context)
      end)
      |> update_issue(project_id, issue_key, fn issue ->
        issue
        |> Map.put(:claim_status, :released)
        |> Map.put(:released_at, now)
        |> Map.put(:terminal_reason, reason)
      end)
      |> update_workspace_leases(project_id, issue_key, attempt_id, fn lease ->
        lease
        |> Map.put(:status, :released)
        |> Map.put(:released_at, now)
      end)
      |> update_start_intents(project_id, issue_key, attempt_id, fn intent ->
        intent
        |> Map.put(:status, :acknowledged)
        |> Map.put(:finished_at, intent.finished_at || now)
        |> Map.put(:manual_attention, false)
      end)

    {:ok, RuntimeLedger.to_snapshot(ledger)}
  end

  @spec run_context_snapshot(dispatch_context(), keyword()) :: map()
  def run_context_snapshot(context, opts \\ []) when is_map(context) and is_list(opts) do
    %{
      project: %{
        project_id: context.project_id,
        config_fingerprint: context.config_fingerprint,
        snapshot_version: context.snapshot_version
      },
      workflow: sanitize_value(context.workflow),
      tracker: sanitize_value(context.tracker),
      issue_key: context.issue_key,
      issue_ref: safe_issue_ref(context.issue_ref),
      current_stage: context.current_stage,
      attempt_id: context.attempt_id,
      attempt_number: context.attempt_number,
      correlation_id: context.correlation_id,
      workspace_path: context.workspace_path,
      workspace_lease_id: context.workspace_lease_id,
      worker_host: context.worker_host,
      runtime_identity: sanitize_value(context.runtime_identity),
      runner: context.runner,
      start_command_summary: sanitize_value(context.start_command_summary),
      session_id: optional_string(Keyword.get(opts, :session_id)),
      started_at: normalize_time(Keyword.get(opts, :started_at)),
      last_activity_at: normalize_time(Keyword.get(opts, :last_activity_at)),
      exit_summary: sanitize_value(Keyword.get(opts, :exit_summary, %{})),
      status: optional_string(Keyword.get(opts, :status)) || "start_pending"
    }
  end

  defp apply_dispatch(ledger, context, opts) do
    now = normalize_time(Keyword.get(opts, :now)) || normalize_time(DateTime.utc_now())

    ledger
    |> upsert_project(context)
    |> upsert_issue(context, now)
    |> add_workspace_lease(context, now)
    |> add_start_intent(context, now)
    |> RuntimeLedger.to_snapshot()
  end

  defp upsert_project(ledger, context) do
    project =
      ledger.projects
      |> Enum.find(&(&1.project_id == context.project_id))
      |> Kernel.||(%{
        project_id: context.project_id,
        config_fingerprint: context.config_fingerprint,
        snapshot_version: context.snapshot_version,
        issues: [],
        workspace_leases: [],
        start_intents: []
      })
      |> Map.put(:config_fingerprint, context.config_fingerprint)
      |> Map.put(:snapshot_version, context.snapshot_version)

    projects = [project | Enum.reject(ledger.projects, &(&1.project_id == context.project_id))]
    Map.put(ledger, :projects, projects)
  end

  defp upsert_issue(ledger, context, now) do
    update_project(ledger, context.project_id, fn project ->
      issue =
        project.issues
        |> Enum.find(&(&1.issue_key == context.issue_key))
        |> Kernel.||(%{
          issue_key: context.issue_key,
          issue_ref: context.issue_ref,
          claim_status: :unclaimed,
          current_stage: nil,
          claimed_at: nil,
          released_at: nil,
          terminal_reason: nil,
          attempts: [],
          retry_backoff: nil,
          writebacks: []
        })
        |> Map.put(:issue_ref, context.issue_ref)
        |> Map.put(:claim_status, :claimed)
        |> Map.put(:current_stage, context.current_stage)
        |> Map.put(:claimed_at, now)
        |> Map.put(:released_at, nil)
        |> Map.put(:terminal_reason, nil)
        |> Map.put(:retry_backoff, nil)
        |> Map.update!(:attempts, fn attempts -> attempts ++ [attempt_record(context, now)] end)

      Map.put(project, :issues, [issue | Enum.reject(project.issues, &(&1.issue_key == context.issue_key))])
    end)
  end

  defp add_workspace_lease(ledger, context, now) do
    update_project(ledger, context.project_id, fn project ->
      lease = %{
        lease_id: context.workspace_lease_id,
        issue_key: context.issue_key,
        attempt_id: context.attempt_id,
        workspace_path: context.workspace_path,
        status: :active,
        acquired_at: now,
        released_at: nil,
        worker_host: context.worker_host
      }

      Map.update!(project, :workspace_leases, &(&1 ++ [lease]))
    end)
  end

  defp add_start_intent(ledger, context, now) do
    update_project(ledger, context.project_id, fn project ->
      intent = %{
        intent_id: context.start_intent_id,
        issue_key: context.issue_key,
        attempt_id: context.attempt_id,
        workspace_lease_id: context.workspace_lease_id,
        workspace_path: context.workspace_path,
        status: :pending,
        requested_at: now,
        acked_at: nil,
        finished_at: nil,
        worker_host: context.worker_host,
        runtime_identity: sanitize_value(context.runtime_identity),
        runner: context.runner,
        start_command_summary: sanitize_value(context.start_command_summary),
        correlation_id: context.correlation_id,
        error_summary: nil,
        manual_attention: false
      }

      Map.update!(project, :start_intents, &(&1 ++ [intent]))
    end)
  end

  defp attempt_record(context, now) do
    %{
      attempt_id: context.attempt_id,
      attempt_number: context.attempt_number,
      status: :pending,
      started_at: now,
      ended_at: nil,
      terminal_reason: nil,
      current_stage: context.current_stage,
      worker_host: context.worker_host,
      workspace_path: context.workspace_path,
      agent_session: nil,
      run_context: run_context_snapshot(context, started_at: now)
    }
  end

  defp preflight(ledger, project_id, issue_key, workspace_path, candidate) do
    project = Enum.find(ledger.projects, &(&1.project_id == project_id))
    issue = project && Enum.find(project.issues, &(&1.issue_key == issue_key))
    active_attempt = issue && Enum.find(issue.attempts, &active_attempt?/1)

    active_start_intent =
      project && Enum.find(project.start_intents, &(active_start_intent?(&1) and &1.issue_key == issue_key))

    active_workspace =
      project &&
        Enum.find(project.workspace_leases, &(active_lease?(&1) and &1.workspace_path == workspace_path))

    retry = issue && issue.retry_backoff
    blockers = explicit_blockers(candidate)

    cond do
      active_start_intent ->
        preflight_result(
          :already_active,
          :start_intent_unresolved,
          "Issue already has an unresolved worker start intent",
          active_start_intent.attempt_id,
          active_start_intent.workspace_path,
          retry && retry.due_at,
          blockers
        )

      active_attempt ->
        preflight_result(
          :already_active,
          :active_attempt_exists,
          "Issue already has an active attempt",
          active_attempt.attempt_id,
          active_attempt.workspace_path,
          retry && retry.due_at,
          blockers
        )

      active_workspace ->
        preflight_result(
          :workspace_conflict,
          :workspace_already_leased,
          "Workspace is already leased by another active attempt",
          active_workspace.attempt_id,
          active_workspace.workspace_path,
          retry && retry.due_at,
          blockers
        )

      retry ->
        preflight_result(:retry_backoff, :retry_backoff_active, "Issue is waiting for retry/backoff before dispatch", nil, nil, retry.due_at, blockers)

      blockers != [] ->
        status = blocker_status(blockers)
        preflight_result(status, status, "Candidate is blocked by #{Enum.map_join(blockers, ", ", &Atom.to_string/1)}", nil, nil, nil, blockers)

      true ->
        preflight_result(:allowed, nil, nil, nil, nil, nil, [])
    end
  end

  defp preflight_result(status, reason, message, existing_attempt_id, existing_workspace_path, retry_due_at, blockers) do
    %{
      status: status,
      can_start?: status == :allowed,
      reason: reason,
      message: message,
      existing_attempt_id: existing_attempt_id,
      existing_workspace_path: existing_workspace_path,
      retry_due_at: retry_due_at,
      blocked_by: blockers
    }
  end

  defp explicit_blockers(candidate) do
    []
    |> maybe_add_blocker(
      truthy?(value(candidate, :project_paused)) or truthy?(value(candidate, :paused)),
      :project_paused
    )
    |> maybe_add_blocker(not is_nil(optional_string(candidate, :config_error)), :config_error)
    |> maybe_add_blocker(provider_backpressure?(candidate), :provider_backpressure)
    |> maybe_add_blocker(truthy?(value(candidate, :blocked)), :blocked)
  end

  defp maybe_add_blocker(blockers, true, blocker), do: blockers ++ [blocker]
  defp maybe_add_blocker(blockers, false, _blocker), do: blockers

  defp blocker_status([:project_paused | _rest]), do: :project_paused
  defp blocker_status([:config_error | _rest]), do: :config_error
  defp blocker_status([:provider_backpressure | _rest]), do: :provider_backpressure
  defp blocker_status(_blockers), do: :blocked

  defp provider_backpressure?(candidate) do
    governance = value(candidate, :governance) || %{}
    not is_nil(value(governance, :backpressure)) or value(governance, :decision) in [:blocked, "blocked"]
  end

  defp update_project(ledger, project_id, fun) do
    Map.update!(ledger, :projects, fn projects ->
      Enum.map(projects, fn
        %{project_id: ^project_id} = project -> fun.(project)
        project -> project
      end)
    end)
  end

  defp update_issue(ledger, project_id, issue_key, fun) do
    update_project(ledger, project_id, fn project ->
      Map.update!(project, :issues, fn issues ->
        Enum.map(issues, fn
          %{issue_key: ^issue_key} = issue -> fun.(issue)
          issue -> issue
        end)
      end)
    end)
  end

  defp update_attempt(ledger, project_id, issue_key, attempt_id, fun) do
    update_issue(ledger, project_id, issue_key, fn issue ->
      Map.update!(issue, :attempts, fn attempts ->
        Enum.map(attempts, fn
          %{attempt_id: ^attempt_id} = attempt -> fun.(attempt)
          attempt -> attempt
        end)
      end)
    end)
  end

  defp update_start_intent(ledger, project_id, start_intent_id, fun) do
    update_project(ledger, project_id, fn project ->
      Map.update!(project, :start_intents, fn intents ->
        Enum.map(intents, fn
          %{intent_id: ^start_intent_id} = intent -> fun.(intent)
          intent -> intent
        end)
      end)
    end)
  end

  defp update_start_intents(ledger, project_id, issue_key, attempt_id, fun) do
    update_project(ledger, project_id, fn project ->
      Map.update!(project, :start_intents, fn intents ->
        Enum.map(intents, fn
          %{issue_key: ^issue_key, attempt_id: ^attempt_id} = intent -> fun.(intent)
          intent -> intent
        end)
      end)
    end)
  end

  defp update_workspace_leases(ledger, project_id, issue_key, attempt_id, fun) do
    update_project(ledger, project_id, fn project ->
      Map.update!(project, :workspace_leases, fn leases ->
        Enum.map(leases, fn
          %{issue_key: ^issue_key, attempt_id: ^attempt_id} = lease -> fun.(lease)
          lease -> lease
        end)
      end)
    end)
  end

  defp maybe_put_retry_backoff(issue, :retry_queued, attempt_id, failure, opts) do
    due_at = normalize_time(value(failure, :due_at) || Keyword.get(opts, :due_at))

    Map.put(issue, :retry_backoff, %{
      attempt_id: attempt_id,
      due_at: due_at,
      error_summary: optional_string(failure, :error_summary),
      preferred_worker_host: optional_string(failure, :worker_host),
      preferred_workspace_path: optional_string(failure, :workspace_path)
    })
  end

  defp maybe_put_retry_backoff(issue, _status, _attempt_id, _failure, _opts), do: issue

  defp maybe_put_released_at(issue, :released, now), do: Map.put(issue, :released_at, now)
  defp maybe_put_released_at(issue, _status, _now), do: issue

  defp maybe_release_workspace_on_failure(ledger, _project_id, _issue_key, _attempt_id, :manual_attention, _now), do: ledger

  defp maybe_release_workspace_on_failure(ledger, project_id, issue_key, attempt_id, _failure_status, now) do
    update_workspace_leases(ledger, project_id, issue_key, attempt_id, fn lease ->
      lease
      |> Map.put(:status, :released)
      |> Map.put(:released_at, now)
    end)
  end

  defp failure_attempt_status(:manual_attention), do: :pending
  defp failure_attempt_status(_status), do: :failed
  defp failure_attempt_ended_at(:manual_attention, _now), do: nil
  defp failure_attempt_ended_at(_status, now), do: now
  defp failure_start_intent_status(:manual_attention), do: :unknown
  defp failure_start_intent_status(_status), do: :failed

  defp active_attempt?(attempt), do: attempt.status in [:pending, :running] and is_nil(attempt.ended_at)
  defp active_lease?(lease), do: lease.status == :active and is_nil(lease.released_at)
  defp active_start_intent?(intent), do: intent.status in [:pending, :unknown, :manual_attention] and is_nil(intent.acked_at) and is_nil(intent.finished_at)

  defp next_attempt_number(ledger, project_id, issue_key, value) do
    normalize_non_negative_integer(value) ||
      case ledger.projects |> Enum.find(&(&1.project_id == project_id)) |> then(&(&1 && Enum.find(&1.issues, fn issue -> issue.issue_key == issue_key end))) do
        nil -> 1
        issue -> (issue.attempts |> Enum.map(&(&1.attempt_number || 0)) |> Enum.max(fn -> 0 end)) + 1
      end
  end

  defp normalize_issue_ref(candidate) do
    case value(candidate, :issue_ref) do
      %IssueRef{} = issue_ref -> {:ok, issue_ref}
      issue_ref when is_map(issue_ref) -> {:ok, issue_ref}
      _issue_ref -> {:error, :missing_issue_ref}
    end
  end

  defp validate_issue_project(project_id, %IssueRef{project_id: project_id}), do: :ok

  defp validate_issue_project(project_id, %{} = issue_ref) when not is_struct(issue_ref) do
    if optional_string(issue_ref, :project_id) in [nil, project_id] do
      :ok
    else
      {:error, :issue_project_mismatch}
    end
  end

  defp validate_issue_project(_project_id, _issue_ref), do: {:error, :issue_project_mismatch}

  defp required_workspace_path(candidate) do
    case optional_string(candidate, :workspace_path) do
      nil -> {:error, :missing_workspace_path}
      workspace_path -> {:ok, workspace_path}
    end
  end

  defp workflow_summary(candidate), do: sanitize_value(value(candidate, :workflow) || value(candidate, :workflow_summary) || %{})
  defp tracker_summary(candidate), do: sanitize_value(value(candidate, :tracker) || value(candidate, :tracker_summary) || %{})

  defp governance_summary(candidate) do
    case value(candidate, :governance) do
      nil -> %{}
      governance -> sanitize_value(governance)
    end
  end

  defp safe_issue_ref(%IssueRef{} = issue_ref) do
    %{
      project_id: issue_ref.project_id,
      tracker_kind: issue_ref.tracker_kind,
      provider_scope: stringify_nested_keys(issue_ref.provider_scope || %{}),
      provider_scope_key: issue_ref.provider_scope_key,
      provider_issue_id: issue_ref.provider_issue_id,
      provider_local_id: issue_ref.provider_local_id,
      identifier: issue_ref.identifier,
      url: issue_ref.url
    }
  end

  defp safe_issue_ref(issue_ref) when is_map(issue_ref) do
    %{
      project_id: optional_string(issue_ref, :project_id),
      tracker_kind: optional_string(issue_ref, :tracker_kind),
      provider_scope: stringify_nested_keys(value(issue_ref, :provider_scope) || %{}),
      provider_scope_key: optional_string(issue_ref, :provider_scope_key),
      provider_issue_id: optional_string(issue_ref, :provider_issue_id),
      provider_local_id: optional_string(issue_ref, :provider_local_id),
      identifier: optional_string(issue_ref, :identifier),
      url: optional_string(issue_ref, :url)
    }
  end

  defp normalize_trigger_source(value) when value in @trigger_sources, do: {:ok, value}

  defp normalize_trigger_source(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase() |> String.replace("-", "_")
    source = Enum.find(@trigger_sources, &(Atom.to_string(&1) == normalized))
    if source, do: {:ok, source}, else: {:error, :invalid_trigger_source}
  end

  defp normalize_trigger_source(nil), do: {:ok, :poll_plan}
  defp normalize_trigger_source(_value), do: {:error, :invalid_trigger_source}

  defp stable_id(prefix, seed) do
    prefix <> ":" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
  end

  defp default_correlation_id(project_id, issue_key, trigger_source) do
    stable_id("hub-dispatch-correlation", Enum.join([project_id, issue_key, trigger_source], "|"))
  end

  defp required_string(map, key) do
    case optional_string(map, key) do
      nil -> {:error, {:missing_required_string, key}}
      value -> {:ok, value}
    end
  end

  defp required_string!(map, key) do
    case required_string(map, key) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  defp optional_string(map, key), do: map |> value(key) |> optional_string()
  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(_value), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp normalize_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp normalize_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _parse -> nil
    end
  end

  defp normalize_non_negative_integer(_value), do: nil

  defp normalize_time(nil), do: nil
  defp normalize_time(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp normalize_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      {:error, _reason} -> optional_string(value)
    end
  end

  defp normalize_time(_value), do: nil

  defp value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, nil} -> Map.get(map, Atom.to_string(key))
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key)
  defp value(_map, _key), do: nil

  defp stringify_nested_keys(value) when is_map(value), do: Map.new(value, fn {key, raw_value} -> {stringify_key(key), stringify_nested_keys(raw_value)} end)
  defp stringify_nested_keys(value) when is_list(value), do: Enum.map(value, &stringify_nested_keys/1)
  defp stringify_nested_keys(value), do: value

  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key), do: to_string(key)

  defp sanitize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp sanitize_value(%_struct{} = value), do: value

  defp sanitize_value(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, raw_value} -> sensitive_key?(key) or sensitive_value?(raw_value) end)
    |> Map.new(fn {key, raw_value} -> {normalize_output_key(key), sanitize_value(raw_value)} end)
  end

  defp sanitize_value(value) when is_list(value), do: value |> Enum.reject(&sensitive_value?/1) |> Enum.map(&sanitize_value/1)
  defp sanitize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_value(value), do: value

  defp normalize_output_key(key) when is_atom(key), do: key

  defp normalize_output_key(key) when is_binary(key) do
    if Regex.match?(~r/\A[a-z_][a-zA-Z0-9_]*\z/, key) do
      String.to_atom(key)
    else
      key
    end
  end

  defp normalize_output_key(key), do: key

  defp sensitive_key?(key) do
    key =
      key
      |> to_string()
      |> String.downcase()

    String.contains?(key, ["api_key", "apikey", "authorization", "token", "secret", "credential", "cookie", "prompt", "transcript", "raw_config"])
  end

  defp sensitive_value?(value) when is_binary(value) do
    Regex.match?(~r/\$[A-Z0-9_]*(TOKEN|API_KEY|SECRET|CREDENTIAL)[A-Z0-9_]*/, value) or
      Regex.match?(~r/\b(api[_-]?key|authorization|bearer|cookie|credential|secret|token|transcript|full prompt|codex transcript)\b/i, value) or
      Regex.match?(~r/\b(ghp_|github_pat_|glpat-|sk-[A-Za-z0-9])/, value)
  end

  defp sensitive_value?(%_struct{}), do: false
  defp sensitive_value?(value) when is_map(value), do: Enum.any?(value, fn {key, raw_value} -> sensitive_key?(key) or sensitive_value?(raw_value) end)
  defp sensitive_value?(value) when is_list(value), do: Enum.any?(value, &sensitive_value?/1)
  defp sensitive_value?(_value), do: false

  defp truthy?(value), do: value in [true, "true", "1", 1]
end
