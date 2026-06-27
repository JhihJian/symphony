defmodule SymphonyElixir.Hub.RuntimeLedger do
  @moduledoc """
  Recoverable Hub runtime ledger facts.

  This module is intentionally model-only. It can build, normalize, validate,
  serialize, deserialize, and replay Hub runtime ledger facts, but it does not
  start poll loops or dispatch agents.
  """

  alias SymphonyElixir.Hub.IssueRef
  alias SymphonyElixir.Hub.ProjectRegistry

  @version 1
  @issue_statuses [:unclaimed, :claimed, :running, :retry_queued, :blocked, :released, :terminal]
  @attempt_statuses [:pending, :running, :succeeded, :failed, :cancelled, :lost]
  @lease_statuses [:active, :released, :lost]
  @replay_policies [:idempotent, :non_idempotent]
  @writeback_statuses [:pending, :succeeded, :failed, :unknown]
  @active_attempt_statuses [:pending, :running]
  @terminal_issue_statuses [:released, :terminal]
  @sensitive_keys MapSet.new(["api_key", "token", "credential", "credentials", "secret", "prompt", "transcript", "raw_config"])
  @sensitive_value_patterns [
    ~r/\$[A-Z0-9_]*(TOKEN|API_KEY|SECRET|CREDENTIAL)[A-Z0-9_]*/,
    ~r/\b(api[_-]?key|credential|secret|transcript|full prompt)\b/i,
    ~r/\b(ghp_|github_pat_|glpat-|sk-[A-Za-z0-9])/
  ]

  @type ledger :: %{
          required(:version) => pos_integer(),
          required(:generated_at) => String.t() | nil,
          required(:updated_at) => String.t() | nil,
          required(:projects) => [project()]
        }

  @type project :: %{
          required(:project_id) => String.t(),
          required(:config_fingerprint) => String.t() | nil,
          required(:snapshot_version) => String.t() | nil,
          required(:issues) => [issue()],
          required(:workspace_leases) => [workspace_lease()]
        }

  @type issue :: %{
          required(:issue_key) => String.t(),
          required(:issue_ref) => map(),
          required(:claim_status) => atom(),
          required(:current_stage) => String.t() | nil,
          required(:claimed_at) => String.t() | nil,
          required(:released_at) => String.t() | nil,
          required(:terminal_reason) => String.t() | nil,
          required(:attempts) => [attempt()],
          required(:retry_backoff) => retry_backoff() | nil,
          required(:writebacks) => [writeback()]
        }

  @type attempt :: %{
          required(:attempt_id) => String.t(),
          required(:attempt_number) => non_neg_integer() | nil,
          required(:status) => atom(),
          required(:started_at) => String.t() | nil,
          required(:ended_at) => String.t() | nil,
          required(:terminal_reason) => String.t() | nil,
          required(:current_stage) => String.t() | nil,
          required(:worker_host) => String.t() | nil,
          required(:workspace_path) => String.t() | nil,
          required(:agent_session) => agent_session() | nil
        }

  @type workspace_lease :: %{
          required(:lease_id) => String.t() | nil,
          required(:issue_key) => String.t(),
          required(:attempt_id) => String.t(),
          required(:workspace_path) => String.t(),
          required(:status) => atom(),
          required(:acquired_at) => String.t() | nil,
          required(:released_at) => String.t() | nil,
          required(:worker_host) => String.t() | nil
        }

  @type retry_backoff :: %{
          required(:attempt_id) => String.t(),
          required(:due_at) => String.t(),
          required(:error_summary) => String.t() | nil,
          required(:preferred_worker_host) => String.t() | nil,
          required(:preferred_workspace_path) => String.t() | nil
        }

  @type agent_session :: %{
          required(:session_id) => String.t() | nil,
          required(:last_activity_at) => String.t() | nil,
          required(:usage) => map()
        }

  @type writeback :: %{
          required(:intent_key) => String.t(),
          required(:logical_action) => String.t() | nil,
          required(:operation_type) => String.t() | nil,
          required(:target) => map(),
          required(:replay_policy) => atom(),
          required(:result_status) => atom(),
          required(:attempt_id) => String.t() | nil,
          required(:provider_marker) => String.t() | nil,
          required(:external_ref) => String.t() | nil,
          required(:error_summary) => String.t() | nil
        }

  @type diagnostic :: %{
          required(:level) => :error | :warning,
          required(:code) => atom(),
          required(:project_id) => String.t() | nil,
          optional(:issue_key) => String.t() | nil,
          optional(:attempt_id) => String.t() | nil,
          optional(:workspace_path) => String.t() | nil,
          optional(:intent_key) => String.t() | nil,
          required(:message) => String.t()
        }

  @type replay_summary :: %{
          required(:version) => pos_integer(),
          required(:generated_at) => String.t() | nil,
          required(:updated_at) => String.t() | nil,
          required(:projects) => [map()],
          required(:conflicts) => [diagnostic()],
          required(:manual_attention) => [diagnostic()]
        }

  @spec new(keyword()) :: ledger()
  def new(opts \\ []) when is_list(opts) do
    %{
      version: Keyword.get(opts, :version, @version),
      generated_at: normalize_time(Keyword.get(opts, :generated_at)),
      updated_at: normalize_time(Keyword.get(opts, :updated_at)),
      projects: opts |> Keyword.get(:projects, []) |> Enum.map(&normalize_project/1) |> Enum.sort_by(& &1.project_id)
    }
  end

  @spec to_snapshot(ledger() | map()) :: ledger()
  def to_snapshot(ledger) when is_map(ledger) do
    ledger
    |> normalize_ledger()
    |> sort_ledger()
  end

  @spec from_snapshot(map()) :: {:ok, ledger()} | {:error, [diagnostic()]}
  def from_snapshot(snapshot) when is_map(snapshot) do
    case privacy_diagnostics(snapshot) do
      [] -> {:ok, to_snapshot(snapshot)}
      diagnostics -> {:error, diagnostics}
    end
  end

  @spec validate(ledger() | map()) :: :ok | {:error, [diagnostic()]}
  def validate(ledger) when is_map(ledger) do
    diagnostics =
      privacy_diagnostics(ledger) ++
        (ledger
         |> to_snapshot()
         |> validation_diagnostics())

    case diagnostics do
      [] -> :ok
      diagnostics -> {:error, diagnostics}
    end
  end

  @spec replay(ledger() | map()) :: replay_summary()
  def replay(ledger) when is_map(ledger) do
    ledger = to_snapshot(ledger)
    conflicts = validation_diagnostics(ledger)
    manual_attention = manual_attention_diagnostics(ledger)

    %{
      version: ledger.version,
      generated_at: ledger.generated_at,
      updated_at: ledger.updated_at,
      projects: Enum.map(ledger.projects, &project_summary(&1, conflicts, manual_attention)),
      conflicts: conflicts,
      manual_attention: manual_attention
    }
  end

  @spec issue_key(IssueRef.t() | map()) :: String.t()
  def issue_key(%IssueRef{} = issue_ref), do: IssueRef.key(issue_ref)

  def issue_key(issue_ref) when is_map(issue_ref) do
    [
      required_string(issue_ref, :project_id),
      required_string(issue_ref, :provider_scope_key),
      optional_string(issue_ref, :provider_issue_id) ||
        optional_string(issue_ref, :provider_local_id) ||
        optional_string(issue_ref, :identifier)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(":")
  end

  @spec writeback_intent_key(IssueRef.t() | map(), String.t()) :: String.t()
  def writeback_intent_key(issue_ref, logical_action) when is_binary(logical_action) do
    issue_ref
    |> issue_key()
    |> Kernel.<>(":writeback:" <> logical_action)
  end

  defp normalize_ledger(ledger) do
    %{
      version: value(ledger, :version) || @version,
      generated_at: normalize_time(value(ledger, :generated_at)),
      updated_at: normalize_time(value(ledger, :updated_at)),
      projects: ledger |> list_value(:projects) |> Enum.map(&normalize_project/1) |> Enum.sort_by(& &1.project_id)
    }
  end

  defp normalize_project(project) when is_map(project) do
    project_id = required_string(project, :project_id)

    %{
      project_id: project_id,
      config_fingerprint: optional_string(project, :config_fingerprint) || optional_string(project, :fingerprint),
      snapshot_version: optional_string(project, :snapshot_version),
      issues:
        project
        |> list_value(:issues)
        |> Enum.map(&normalize_issue(project_id, &1))
        |> Enum.sort_by(& &1.issue_key),
      workspace_leases:
        project
        |> list_value(:workspace_leases)
        |> Enum.map(&normalize_workspace_lease/1)
        |> Enum.sort_by(&{&1.workspace_path, &1.issue_key, &1.attempt_id})
    }
  end

  defp normalize_project(_project), do: normalize_project(%{})

  defp normalize_issue(project_id, issue) when is_map(issue) do
    issue_ref = normalize_issue_ref(project_id, value(issue, :issue_ref) || %{})
    issue_key = optional_string(issue, :issue_key) || issue_key(issue_ref)

    %{
      issue_key: issue_key,
      issue_ref: issue_ref,
      claim_status: normalize_atom(value(issue, :claim_status) || value(issue, :status), :unclaimed, @issue_statuses),
      current_stage: optional_string(issue, :current_stage),
      claimed_at: normalize_time(value(issue, :claimed_at)),
      released_at: normalize_time(value(issue, :released_at)),
      terminal_reason: optional_string(issue, :terminal_reason),
      attempts:
        issue
        |> list_value(:attempts)
        |> Enum.map(&normalize_attempt/1)
        |> Enum.sort_by(&{&1.attempt_number || 0, &1.attempt_id}),
      retry_backoff: normalize_retry_backoff(value(issue, :retry_backoff)),
      writebacks:
        issue
        |> list_value(:writebacks)
        |> Enum.map(&normalize_writeback/1)
        |> Enum.sort_by(&{&1.intent_key, &1.attempt_id || ""})
    }
  end

  defp normalize_issue(project_id, _issue), do: normalize_issue(project_id, %{})

  defp normalize_issue_ref(_project_id, %IssueRef{} = issue_ref) do
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

  defp normalize_issue_ref(project_id, issue_ref) when is_map(issue_ref) do
    %{
      project_id: optional_string(issue_ref, :project_id) || project_id,
      tracker_kind: optional_string(issue_ref, :tracker_kind),
      provider_scope: stringify_nested_keys(value(issue_ref, :provider_scope) || %{}),
      provider_scope_key: optional_string(issue_ref, :provider_scope_key),
      provider_issue_id: optional_string(issue_ref, :provider_issue_id),
      provider_local_id: optional_string(issue_ref, :provider_local_id),
      identifier: optional_string(issue_ref, :identifier),
      url: optional_string(issue_ref, :url)
    }
  end

  defp normalize_issue_ref(project_id, _issue_ref), do: normalize_issue_ref(project_id, %{})

  defp normalize_attempt(attempt) when is_map(attempt) do
    %{
      attempt_id: required_string(attempt, :attempt_id),
      attempt_number: normalize_integer(value(attempt, :attempt_number)),
      status: normalize_atom(value(attempt, :status), :pending, @attempt_statuses),
      started_at: normalize_time(value(attempt, :started_at)),
      ended_at: normalize_time(value(attempt, :ended_at)),
      terminal_reason: optional_string(attempt, :terminal_reason),
      current_stage: optional_string(attempt, :current_stage),
      worker_host: optional_string(attempt, :worker_host),
      workspace_path: optional_string(attempt, :workspace_path),
      agent_session: normalize_agent_session(value(attempt, :agent_session))
    }
  end

  defp normalize_attempt(_attempt), do: normalize_attempt(%{})

  defp normalize_workspace_lease(lease) when is_map(lease) do
    %{
      lease_id: optional_string(lease, :lease_id),
      issue_key: required_string(lease, :issue_key),
      attempt_id: required_string(lease, :attempt_id),
      workspace_path: required_string(lease, :workspace_path),
      status: normalize_atom(value(lease, :status), :active, @lease_statuses),
      acquired_at: normalize_time(value(lease, :acquired_at)),
      released_at: normalize_time(value(lease, :released_at)),
      worker_host: optional_string(lease, :worker_host)
    }
  end

  defp normalize_workspace_lease(_lease), do: normalize_workspace_lease(%{})

  defp normalize_retry_backoff(nil), do: nil

  defp normalize_retry_backoff(retry) when is_map(retry) do
    %{
      attempt_id: required_string(retry, :attempt_id),
      due_at: normalize_time(value(retry, :due_at)),
      error_summary: optional_string(retry, :error_summary),
      preferred_worker_host: optional_string(retry, :preferred_worker_host),
      preferred_workspace_path: optional_string(retry, :preferred_workspace_path)
    }
  end

  defp normalize_retry_backoff(_retry), do: nil

  defp normalize_agent_session(nil), do: nil

  defp normalize_agent_session(session) when is_map(session) do
    %{
      session_id: optional_string(session, :session_id),
      last_activity_at: normalize_time(value(session, :last_activity_at)),
      usage: stringify_nested_keys(value(session, :usage) || %{})
    }
  end

  defp normalize_agent_session(_session), do: nil

  defp normalize_writeback(writeback) when is_map(writeback) do
    %{
      intent_key: required_string(writeback, :intent_key),
      logical_action: optional_string(writeback, :logical_action),
      operation_type: optional_string(writeback, :operation_type),
      target: stringify_nested_keys(value(writeback, :target) || %{}),
      replay_policy: normalize_atom(value(writeback, :replay_policy), :idempotent, @replay_policies),
      result_status: normalize_atom(value(writeback, :result_status), :pending, @writeback_statuses),
      attempt_id: optional_string(writeback, :attempt_id),
      provider_marker: optional_string(writeback, :provider_marker),
      external_ref: optional_string(writeback, :external_ref),
      error_summary: optional_string(writeback, :error_summary)
    }
  end

  defp normalize_writeback(_writeback), do: normalize_writeback(%{})

  defp sort_ledger(ledger) do
    Map.update!(ledger, :projects, fn projects ->
      projects
      |> Enum.map(fn project ->
        project
        |> Map.update!(:issues, &Enum.sort_by(&1, fn issue -> issue.issue_key end))
        |> Map.update!(:workspace_leases, &Enum.sort_by(&1, fn lease -> {lease.workspace_path, lease.issue_key, lease.attempt_id} end))
      end)
      |> Enum.sort_by(& &1.project_id)
    end)
  end

  defp validation_diagnostics(ledger) do
    privacy_diagnostics(ledger) ++
      Enum.flat_map(ledger.projects, fn project ->
        validate_project(project) ++
          issue_identity_conflicts(project) ++
          active_attempt_conflicts(project) ++
          workspace_lease_conflicts(project) ++
          retry_backoff_conflicts(project) ++
          writeback_conflicts(project)
      end)
  end

  defp validate_project(project) do
    case ProjectRegistry.validate_project_id(project.project_id) do
      :ok ->
        []

      {:error, {_code, _project_id, message}} ->
        [diagnostic(:error, :invalid_project_id, project.project_id, nil, message)]
    end
  end

  defp issue_identity_conflicts(project) do
    Enum.flat_map(project.issues, fn issue ->
      issue_ref = issue.issue_ref
      expected_issue_key = issue_key(issue_ref)

      []
      |> maybe_add_diagnostic(
        issue_ref.project_id != project.project_id,
        diagnostic(
          :error,
          :issue_ref_project_mismatch,
          project.project_id,
          issue.issue_key,
          "IssueRef project_id must match the containing ledger project"
        )
      )
      |> maybe_add_diagnostic(
        blank?(issue_ref.provider_scope_key),
        diagnostic(
          :error,
          :issue_ref_missing_provider_scope,
          project.project_id,
          issue.issue_key,
          "IssueRef must include provider_scope_key; provider-local issue ids are not global ledger keys"
        )
      )
      |> maybe_add_diagnostic(
        blank?(provider_issue_identity(issue_ref)),
        diagnostic(
          :error,
          :issue_ref_missing_provider_issue_identity,
          project.project_id,
          issue.issue_key,
          "IssueRef must include provider_issue_id, provider_local_id, or identifier"
        )
      )
      |> maybe_add_diagnostic(
        issue.issue_key != expected_issue_key,
        diagnostic(
          :error,
          :issue_key_mismatch,
          project.project_id,
          issue.issue_key,
          "Issue key must be derived from project_id + IssueRef provider scope and issue identity"
        )
      )
    end)
  end

  defp active_attempt_conflicts(project) do
    project.issues
    |> Enum.flat_map(fn issue ->
      issue.attempts
      |> Enum.filter(&active_attempt?/1)
      |> Enum.map(&{issue.issue_key, &1.attempt_id})
    end)
    |> Enum.group_by(fn {issue_key, _attempt_id} -> issue_key end, fn {_issue_key, attempt_id} -> attempt_id end)
    |> Enum.flat_map(fn
      {_issue_key, [_single]} ->
        []

      {issue_key, attempt_ids} ->
        [
          diagnostic(
            :error,
            :active_attempt_conflict,
            project.project_id,
            issue_key,
            "Issue has more than one active attempt: #{Enum.join(Enum.sort(attempt_ids), ", ")}"
          )
        ]
    end)
  end

  defp workspace_lease_conflicts(project) do
    duplicate_active_workspace_conflicts(project) ++
      orphan_workspace_lease_conflicts(project) ++
      terminal_issue_workspace_conflicts(project)
  end

  defp duplicate_active_workspace_conflicts(project) do
    project.workspace_leases
    |> Enum.filter(&active_lease?/1)
    |> Enum.group_by(& &1.workspace_path)
    |> Enum.flat_map(fn
      {_workspace_path, [_single]} ->
        []

      {workspace_path, leases} ->
        issue_keys = leases |> Enum.map(& &1.issue_key) |> Enum.uniq() |> Enum.sort() |> Enum.join(", ")

        [
          diagnostic(
            :error,
            :workspace_active_lease_conflict,
            project.project_id,
            nil,
            workspace_path,
            "Workspace has more than one active lease: #{issue_keys}"
          )
        ]
    end)
  end

  defp orphan_workspace_lease_conflicts(project) do
    Enum.flat_map(project.workspace_leases, fn lease ->
      if active_lease?(lease) and not active_attempt_exists?(project, lease.issue_key, lease.attempt_id) do
        [
          diagnostic(
            :error,
            :workspace_lease_orphan,
            project.project_id,
            lease.issue_key,
            lease.workspace_path,
            lease.attempt_id,
            "Active workspace lease does not reference an active attempt"
          )
        ]
      else
        []
      end
    end)
  end

  defp terminal_issue_workspace_conflicts(project) do
    terminal_issue_keys =
      project.issues
      |> Enum.filter(&(&1.claim_status in @terminal_issue_statuses))
      |> MapSet.new(& &1.issue_key)

    project.workspace_leases
    |> Enum.filter(&(active_lease?(&1) and MapSet.member?(terminal_issue_keys, &1.issue_key)))
    |> Enum.map(fn lease ->
      diagnostic(
        :error,
        :terminal_issue_has_active_workspace_lease,
        project.project_id,
        lease.issue_key,
        lease.workspace_path,
        lease.attempt_id,
        "Released or terminal issue still has an active workspace lease"
      )
    end)
  end

  defp retry_backoff_conflicts(project) do
    Enum.flat_map(project.issues, fn issue ->
      case issue.retry_backoff do
        nil ->
          []

        %{attempt_id: attempt_id} = retry ->
          cond do
            is_nil(attempt_id) ->
              [
                diagnostic(
                  :error,
                  :retry_backoff_unknown_attempt,
                  project.project_id,
                  issue.issue_key,
                  "Retry/backoff record is missing attempt_id"
                )
              ]

            is_nil(retry.due_at) ->
              [
                diagnostic(
                  :error,
                  :retry_backoff_missing_due_at,
                  project.project_id,
                  issue.issue_key,
                  attempt_id,
                  "Retry/backoff record is missing due_at"
                )
              ]

            Enum.any?(issue.attempts, &(&1.attempt_id == attempt_id)) ->
              []

            true ->
              [
                diagnostic(
                  :error,
                  :retry_backoff_unknown_attempt,
                  project.project_id,
                  issue.issue_key,
                  attempt_id,
                  "Retry/backoff record references an unknown attempt"
                )
              ]
          end
      end
    end)
  end

  defp writeback_conflicts(project) do
    Enum.flat_map(project.issues, fn issue ->
      duplicate_writeback_conflicts(project, issue) ++ unstable_writeback_key_conflicts(project, issue)
    end)
  end

  defp duplicate_writeback_conflicts(project, issue) do
    issue.writebacks
    |> Enum.group_by(& &1.intent_key)
    |> Enum.flat_map(fn
      {_intent_key, [_single]} ->
        []

      {intent_key, writebacks} ->
        signatures =
          writebacks
          |> Enum.map(&writeback_signature/1)
          |> Enum.uniq()

        if length(signatures) > 1 do
          [
            diagnostic(
              :error,
              :writeback_intent_conflict,
              project.project_id,
              issue.issue_key,
              nil,
              nil,
              intent_key,
              "Writeback intent key maps to conflicting provider operations"
            )
          ]
        else
          []
        end
    end)
  end

  defp unstable_writeback_key_conflicts(project, issue) do
    issue.writebacks
    |> Enum.reject(&is_nil(&1.logical_action))
    |> Enum.group_by(&{&1.logical_action, &1.operation_type})
    |> Enum.flat_map(fn
      {_logical_operation, [_single]} ->
        []

      {_logical_operation, writebacks} ->
        intent_keys = writebacks |> Enum.map(& &1.intent_key) |> Enum.uniq()

        if length(intent_keys) > 1 do
          [
            diagnostic(
              :error,
              :writeback_intent_key_unstable,
              project.project_id,
              issue.issue_key,
              nil,
              nil,
              Enum.join(Enum.sort(intent_keys), ", "),
              "Same logical writeback action uses different intent keys across attempts"
            )
          ]
        else
          []
        end
    end)
  end

  defp manual_attention_diagnostics(ledger) do
    Enum.flat_map(ledger.projects, fn project ->
      Enum.flat_map(project.issues, fn issue ->
        issue.writebacks
        |> Enum.filter(&(&1.result_status == :unknown and &1.replay_policy == :non_idempotent))
        |> Enum.map(fn writeback ->
          diagnostic(
            :warning,
            :writeback_unknown_manual_attention,
            project.project_id,
            issue.issue_key,
            nil,
            writeback.attempt_id,
            writeback.intent_key,
            "Non-idempotent writeback result is unknown and requires manual attention"
          )
        end)
      end)
    end)
  end

  defp project_summary(project, conflicts, manual_attention) do
    project_conflicts = Enum.filter(conflicts, &(&1.project_id == project.project_id))
    project_manual_attention = Enum.filter(manual_attention, &(&1.project_id == project.project_id))

    %{
      project_id: project.project_id,
      config_fingerprint: project.config_fingerprint,
      snapshot_version: project.snapshot_version,
      counts: project_counts(project),
      active_issues: active_issue_summaries(project),
      conflicts: project_conflicts,
      manual_attention: project_manual_attention
    }
  end

  defp project_counts(project) do
    base = %{claimed: 0, running: 0, retry: 0, blocked: 0, released: 0, terminal: 0}

    Enum.reduce(project.issues, base, fn issue, counts ->
      case issue.claim_status do
        :claimed -> Map.update!(counts, :claimed, &(&1 + 1))
        :running -> Map.update!(counts, :running, &(&1 + 1))
        :retry_queued -> Map.update!(counts, :retry, &(&1 + 1))
        :blocked -> Map.update!(counts, :blocked, &(&1 + 1))
        :released -> Map.update!(counts, :released, &(&1 + 1))
        :terminal -> Map.update!(counts, :terminal, &(&1 + 1))
        _status -> counts
      end
    end)
  end

  defp active_issue_summaries(project) do
    project.issues
    |> Enum.reject(&(&1.claim_status in @terminal_issue_statuses))
    |> Enum.map(&active_issue_summary(project, &1))
  end

  defp active_issue_summary(project, issue) do
    attempt = active_attempt(issue) || latest_attempt(issue)
    lease = active_lease_for(project, issue.issue_key, attempt && attempt.attempt_id)
    retry = issue.retry_backoff

    %{
      issue_key: issue.issue_key,
      issue_ref: issue.issue_ref,
      status: issue.claim_status,
      stage: issue.current_stage || (attempt && attempt.current_stage),
      attempt_id: attempt && attempt.attempt_id,
      attempt_number: attempt && attempt.attempt_number,
      workspace_path: (lease && lease.workspace_path) || (attempt && attempt.workspace_path),
      worker_host: (lease && lease.worker_host) || (attempt && attempt.worker_host),
      last_error: (retry && retry.error_summary) || (attempt && attempt.terminal_reason),
      backoff_due_at: retry && retry.due_at
    }
  end

  defp active_attempt(issue), do: Enum.find(issue.attempts, &active_attempt?/1)

  defp latest_attempt(issue) do
    issue.attempts
    |> Enum.sort_by(&{&1.attempt_number || 0, &1.started_at || ""}, :desc)
    |> List.first()
  end

  defp active_lease_for(project, issue_key, attempt_id) do
    Enum.find(project.workspace_leases, fn lease ->
      active_lease?(lease) and lease.issue_key == issue_key and (is_nil(attempt_id) or lease.attempt_id == attempt_id)
    end)
  end

  defp active_attempt_exists?(project, issue_key, attempt_id) do
    Enum.any?(project.issues, fn issue ->
      issue.issue_key == issue_key and Enum.any?(issue.attempts, &(&1.attempt_id == attempt_id and active_attempt?(&1)))
    end)
  end

  defp active_attempt?(attempt) do
    attempt.status in @active_attempt_statuses and is_nil(attempt.ended_at)
  end

  defp active_lease?(lease) do
    lease.status == :active and is_nil(lease.released_at)
  end

  defp writeback_signature(writeback) do
    {writeback.operation_type, writeback.replay_policy, writeback.target}
  end

  defp provider_issue_identity(issue_ref) do
    issue_ref.provider_issue_id || issue_ref.provider_local_id || issue_ref.identifier
  end

  defp maybe_add_diagnostic(diagnostics, true, diagnostic), do: diagnostics ++ [diagnostic]
  defp maybe_add_diagnostic(diagnostics, false, _diagnostic), do: diagnostics

  defp privacy_diagnostics(value) do
    value
    |> collect_sensitive_paths([])
    |> Enum.map(fn {path, reason} ->
      diagnostic(
        :error,
        :sensitive_ledger_snapshot_field,
        nil,
        nil,
        "Ledger snapshot contains sensitive #{reason} at #{Enum.join(path, ".")}"
      )
    end)
  end

  defp collect_sensitive_paths(%{} = map, path) do
    Enum.flat_map(map, fn {raw_key, value} ->
      key = raw_key |> normalize_key() |> String.downcase()
      next_path = path ++ [key]

      key_findings =
        if MapSet.member?(@sensitive_keys, key) do
          [{next_path, "field"}]
        else
          []
        end

      key_findings ++ collect_sensitive_paths(value, next_path)
    end)
  end

  defp collect_sensitive_paths(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> collect_sensitive_paths(value, path ++ [Integer.to_string(index)]) end)
  end

  defp collect_sensitive_paths(value, path) when is_binary(value) do
    if Enum.any?(@sensitive_value_patterns, &Regex.match?(&1, value)) do
      [{path, "value"}]
    else
      []
    end
  end

  defp collect_sensitive_paths(_value, _path), do: []

  defp diagnostic(level, code, project_id, issue_key, message) do
    %{
      level: level,
      code: code,
      project_id: project_id,
      issue_key: issue_key,
      message: message
    }
  end

  defp diagnostic(level, code, project_id, issue_key, workspace_path, message) do
    %{
      level: level,
      code: code,
      project_id: project_id,
      issue_key: issue_key,
      workspace_path: workspace_path,
      message: message
    }
  end

  defp diagnostic(level, code, project_id, issue_key, workspace_path, attempt_id, message) do
    %{
      level: level,
      code: code,
      project_id: project_id,
      issue_key: issue_key,
      workspace_path: workspace_path,
      attempt_id: attempt_id,
      message: message
    }
  end

  defp diagnostic(level, code, project_id, issue_key, workspace_path, attempt_id, intent_key, message) do
    %{
      level: level,
      code: code,
      project_id: project_id,
      issue_key: issue_key,
      workspace_path: workspace_path,
      attempt_id: attempt_id,
      intent_key: intent_key,
      message: message
    }
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp list_value(map, key) do
    case value(map, key) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  defp required_string(map, key), do: optional_string(map, key) || ""

  defp optional_string(map, key) do
    map
    |> value(key)
    |> normalize_optional_string()
  end

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_optional_string(_value), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp normalize_time(nil), do: nil
  defp normalize_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_time(value) when is_binary(value), do: normalize_optional_string(value)
  defp normalize_time(_value), do: nil

  defp normalize_integer(value) when is_integer(value) and value >= 0, do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _parse_result -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp normalize_atom(value, default, allowed) when is_atom(value) do
    if value in allowed, do: value, else: default
  end

  defp normalize_atom(value, default, allowed) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "" ->
        default

      normalized ->
        Enum.find(allowed, default, &(Atom.to_string(&1) == normalized))
    end
  end

  defp normalize_atom(_value, default, _allowed), do: default

  defp stringify_nested_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), stringify_nested_keys(raw_value))
    end)
  end

  defp stringify_nested_keys(value) when is_list(value), do: Enum.map(value, &stringify_nested_keys/1)
  defp stringify_nested_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)
end
