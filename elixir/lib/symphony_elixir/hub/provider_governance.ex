defmodule SymphonyElixir.Hub.ProviderGovernance do
  @moduledoc """
  Model-only Hub provider request governance baseline.

  This module defines the request boundary, queue/scheduling contract, scope-level
  availability state, and result classifications for the future Hub provider exit.
  It does not start a GenServer, perform provider I/O, or change the legacy
  single-project `SymphonyElixir.Orchestrator` path.
  """

  alias SymphonyElixir.Hub.IssueRef
  alias SymphonyElixir.Hub.RuntimeLedger

  @default_recent_limit 10
  @default_max_running_per_scope 1

  @operation_priorities %{
    manual_refresh: 5,
    running_reconciliation: 10,
    stage_writeback: 20,
    comment_workpad_upsert: 25,
    pr_lookup: 30,
    pr_create: 30,
    dynamic_tool_provider_call: 50,
    candidate_scan: 100
  }

  @replay_policies [:idempotent, :marker_upsert, :non_replayable, :unknown_requires_manual_attention]
  @result_statuses [
    :success,
    :retryable_failure,
    :permanent_failure,
    :rate_limited,
    :circuit_open,
    :canceled,
    :timed_out,
    :unknown_result
  ]

  @circuit_states [:closed, :half_open, :open]
  @error_classes [
    :auth_config,
    :rate_limited,
    :network_timeout,
    :provider_5xx,
    :validation,
    :not_found,
    :conflict,
    :unknown
  ]

  @sensitive_keys MapSet.new([
                    "api_key",
                    "apikey",
                    "authorization",
                    "cookie",
                    "credential",
                    "credentials",
                    "prompt",
                    "raw_config",
                    "secret",
                    "token",
                    "transcript"
                  ])
  @sensitive_value_patterns [
    ~r/\$[A-Z0-9_]*(TOKEN|API_KEY|SECRET|CREDENTIAL)[A-Z0-9_]*/,
    ~r/\b(api[_-]?key|authorization|bearer|cookie|credential|secret|token|transcript|full prompt|codex transcript)\b/i,
    ~r/\b(ghp_|github_pat_|glpat-|sk-[A-Za-z0-9])/
  ]

  @type provider_scope :: %{
          required(:kind) => String.t(),
          required(:scope) => map(),
          required(:key) => String.t()
        }

  @type request :: %{
          required(:request_id) => String.t(),
          required(:logical_key) => String.t(),
          required(:provider_kind) => String.t(),
          required(:provider_scope) => map(),
          required(:provider_scope_key) => String.t(),
          required(:project_id) => String.t(),
          required(:config_fingerprint) => String.t() | nil,
          required(:snapshot_version) => String.t() | nil,
          required(:issue_ref) => IssueRef.t() | map() | nil,
          required(:issue_key) => String.t() | nil,
          required(:operation_kind) => atom(),
          required(:priority) => integer(),
          required(:fairness_key) => String.t(),
          required(:replay_policy) => atom(),
          required(:timeout_ms) => non_neg_integer() | nil,
          required(:deadline_at) => DateTime.t() | nil,
          required(:cancel_token_present) => boolean(),
          required(:correlation) => map(),
          required(:user_initiated) => boolean(),
          required(:enqueued_at) => DateTime.t() | nil
        }

  @type scope_state :: %{
          required(:provider_kind) => String.t() | nil,
          required(:provider_scope_key) => String.t(),
          required(:quota) => map() | nil,
          required(:backoff_until) => DateTime.t() | nil,
          required(:circuit_state) => atom(),
          required(:last_error_class) => atom() | nil,
          required(:updated_at) => DateTime.t() | nil
        }

  @type result :: %{
          required(:request_id) => String.t(),
          required(:logical_key) => String.t(),
          required(:project_id) => String.t(),
          required(:provider_scope_key) => String.t(),
          required(:operation_kind) => atom(),
          required(:status) => atom(),
          required(:error_class) => atom() | nil,
          required(:retry_after_ms) => non_neg_integer() | nil,
          required(:backoff_until) => DateTime.t() | nil,
          required(:result_summary) => map(),
          required(:external_ref) => String.t() | nil,
          required(:manual_attention) => boolean(),
          required(:replayable) => boolean(),
          required(:ledger) => map()
        }

  @type queue :: %{
          required(:pending) => [request()],
          required(:running) => [request()],
          required(:recent_results) => [result()],
          required(:scope_states) => %{optional(String.t()) => scope_state()},
          required(:last_served_by_scope) => %{optional(String.t()) => String.t()},
          required(:max_running_per_scope) => pos_integer(),
          required(:recent_limit) => pos_integer()
        }

  @type next_result :: {:ok, request(), queue()} | {:blocked, map()} | {:empty, map()}

  @spec new_request(map()) :: {:ok, request()} | {:error, term()}
  def new_request(attrs) when is_map(attrs) do
    with {:ok, project_id} <- required_string(attrs, :project_id),
         {:ok, provider_scope} <- normalize_provider_scope(value(attrs, :provider_scope)),
         {:ok, operation_kind} <- normalize_operation_kind(value(attrs, :operation_kind)),
         {:ok, replay_policy} <- normalize_replay_policy(value(attrs, :replay_policy)),
         {:ok, issue_ref} <- normalize_issue_ref(value(attrs, :issue_ref)),
         {:ok, priority} <- normalize_priority(value(attrs, :priority), operation_kind) do
      logical_key =
        normalize_optional_string(value(attrs, :logical_key)) ||
          default_logical_key(project_id, provider_scope, issue_ref, operation_kind)

      issue_key = issue_ref && RuntimeLedger.issue_key(issue_ref)
      fairness_key = normalize_optional_string(value(attrs, :fairness_key)) || project_id

      {:ok,
       %{
         request_id: request_id(project_id, provider_scope.key, logical_key, issue_key),
         logical_key: logical_key,
         provider_kind: provider_scope.kind,
         provider_scope: stringify_nested_keys(provider_scope.scope),
         provider_scope_key: provider_scope.key,
         project_id: project_id,
         config_fingerprint: normalize_optional_string(value(attrs, :config_fingerprint)),
         snapshot_version: normalize_optional_string(value(attrs, :snapshot_version)),
         issue_ref: issue_ref,
         issue_key: issue_key,
         operation_kind: operation_kind,
         priority: priority,
         fairness_key: fairness_key,
         replay_policy: replay_policy,
         timeout_ms: normalize_non_negative_integer(value(attrs, :timeout_ms)),
         deadline_at: normalize_datetime(value(attrs, :deadline_at)),
         cancel_token_present: present?(value(attrs, :cancel_token)),
         correlation: sanitize_map(value(attrs, :correlation) || %{}),
         user_initiated: truthy?(value(attrs, :user_initiated)),
         enqueued_at: normalize_datetime(value(attrs, :enqueued_at))
       }}
    end
  end

  @spec request_snapshot(request()) :: map()
  def request_snapshot(request) when is_map(request) do
    %{
      request_id: request.request_id,
      logical_key: request.logical_key,
      provider_kind: request.provider_kind,
      provider_scope: stringify_nested_keys(request.provider_scope),
      provider_scope_key: request.provider_scope_key,
      project_id: request.project_id,
      config_fingerprint: request.config_fingerprint,
      snapshot_version: request.snapshot_version,
      issue_key: request.issue_key,
      issue_ref: safe_issue_ref(request.issue_ref),
      operation_kind: Atom.to_string(request.operation_kind),
      priority: request.priority,
      fairness_key: request.fairness_key,
      replay_policy: Atom.to_string(request.replay_policy),
      timeout_ms: request.timeout_ms,
      deadline_at: request.deadline_at && DateTime.to_iso8601(request.deadline_at),
      cancellation_boundary_present: request.cancel_token_present,
      correlation: sanitize_map(request.correlation),
      user_initiated: request.user_initiated,
      enqueued_at: request.enqueued_at && DateTime.to_iso8601(request.enqueued_at)
    }
  end

  @spec new_queue(keyword()) :: queue()
  def new_queue(opts \\ []) when is_list(opts) do
    %{
      pending: [],
      running: [],
      recent_results: [],
      scope_states: %{},
      last_served_by_scope: %{},
      max_running_per_scope: Keyword.get(opts, :max_running_per_scope, @default_max_running_per_scope),
      recent_limit: Keyword.get(opts, :recent_limit, @default_recent_limit)
    }
  end

  @spec enqueue(queue(), request(), DateTime.t() | nil) :: {:ok, queue()} | {:error, term()}
  def enqueue(queue, request, now \\ nil) when is_map(queue) and is_map(request) do
    request = Map.put(request, :enqueued_at, request.enqueued_at || normalize_datetime(now) || DateTime.utc_now())
    {:ok, Map.update!(queue, :pending, &(&1 ++ [request]))}
  end

  @spec next_request(queue(), DateTime.t() | nil) :: next_result()
  def next_request(queue, now \\ nil) when is_map(queue) do
    now = normalize_datetime(now) || DateTime.utc_now()

    case eligible_request(queue, now) do
      {:ok, request} ->
        pending = List.delete(queue.pending, request)

        queue =
          queue
          |> Map.put(:pending, pending)
          |> Map.update!(:running, &(&1 ++ [request]))
          |> put_in([:last_served_by_scope, request.provider_scope_key], request.fairness_key)

        {:ok, request, queue}

      {:blocked, _blocked} ->
        {:blocked, blocked_queue_summary(queue, now)}

      :empty ->
        {:empty, queue_summary(queue, now)}
    end
  end

  @spec update_scope_state(queue(), provider_scope() | request() | map() | String.t(), map()) :: queue()
  def update_scope_state(queue, scope_like, attrs) when is_map(queue) and is_map(attrs) do
    scope_key = provider_scope_key(scope_like)
    provider_kind = provider_kind(scope_like)
    state = normalize_scope_state(scope_key, provider_kind, attrs)
    Map.update!(queue, :scope_states, &Map.put(&1, scope_key, state))
  end

  @spec record_result(queue(), result()) :: queue()
  def record_result(queue, result) when is_map(queue) and is_map(result) do
    running = Enum.reject(queue.running, &(&1.request_id == result.request_id))

    recent_results =
      [result | queue.recent_results]
      |> Enum.take(queue.recent_limit)

    queue
    |> Map.put(:running, running)
    |> Map.put(:recent_results, recent_results)
  end

  @spec queue_summary(queue(), DateTime.t() | nil) :: map()
  def queue_summary(queue, now \\ nil) when is_map(queue) do
    now = normalize_datetime(now) || DateTime.utc_now()

    %{
      pending_count: length(queue.pending),
      running_count: length(queue.running),
      provider_scopes: scope_summaries(queue),
      pending: Enum.map(queue.pending, &pending_summary(queue, &1, now)),
      running: Enum.map(queue.running, &running_summary(&1, now)),
      recent_results: Enum.map(queue.recent_results, &result_summary/1),
      backpressure: blocked_requests(queue, now)
    }
  end

  @spec result(request(), atom(), keyword()) :: result()
  def result(request, status, opts \\ []) when is_map(request) and is_atom(status) do
    status = normalize_result_status!(status)
    error_class = normalize_error_class(Keyword.get(opts, :error_class))
    result_summary = sanitize_map(Keyword.get(opts, :result_summary, %{}))
    external_ref = normalize_optional_string(Keyword.get(opts, :external_ref))
    writeback_intent_key = normalize_optional_string(Keyword.get(opts, :writeback_intent_key))
    manual_attention = manual_attention?(request, status)

    %{
      request_id: request.request_id,
      logical_key: request.logical_key,
      project_id: request.project_id,
      provider_scope_key: request.provider_scope_key,
      operation_kind: request.operation_kind,
      status: status,
      error_class: error_class,
      retry_after_ms: normalize_non_negative_integer(Keyword.get(opts, :retry_after_ms)),
      backoff_until: normalize_datetime(Keyword.get(opts, :backoff_until)),
      result_summary: result_summary,
      external_ref: external_ref,
      manual_attention: manual_attention,
      replayable: replayable?(request, status),
      ledger: ledger_link(request, writeback_intent_key, manual_attention)
    }
  end

  @spec result_summary(result()) :: map()
  def result_summary(result) when is_map(result) do
    %{
      request_id: result.request_id,
      logical_key: result.logical_key,
      project_id: result.project_id,
      provider_scope_key: result.provider_scope_key,
      operation_kind: Atom.to_string(result.operation_kind),
      status: result.status,
      error_class: result.error_class,
      retry_after_ms: result.retry_after_ms,
      backoff_until: result.backoff_until && DateTime.to_iso8601(result.backoff_until),
      result_summary: sanitize_map(result.result_summary),
      external_ref: result.external_ref,
      manual_attention: result.manual_attention,
      replayable: result.replayable,
      ledger: result.ledger
    }
  end

  defp eligible_request(queue, now) do
    queue.pending
    |> Enum.map(&{&1, backpressure_for(queue, &1, now)})
    |> then(fn candidates ->
      eligible = Enum.filter(candidates, fn {_request, backpressure} -> is_nil(backpressure) end)

      cond do
        eligible != [] ->
          {:ok, pick_next_request(queue, Enum.map(eligible, fn {request, _backpressure} -> request end))}

        candidates != [] ->
          {:blocked, candidates}

        true ->
          :empty
      end
    end)
  end

  defp pick_next_request(queue, requests) do
    min_priority = requests |> Enum.map(& &1.priority) |> Enum.min()
    top_priority = Enum.filter(requests, &(&1.priority == min_priority))

    top_priority
    |> Enum.group_by(& &1.provider_scope_key)
    |> Enum.map(fn {scope_key, scope_requests} ->
      last_served = Map.get(queue.last_served_by_scope, scope_key)

      scope_requests
      |> Enum.group_by(& &1.fairness_key)
      |> rotate_fairness_group(last_served)
      |> Enum.sort_by(&request_order_key/1)
      |> List.first()
    end)
    |> Enum.sort_by(&request_order_key/1)
    |> List.first()
  end

  defp request_order_key(request) do
    enqueued_at = request.enqueued_at || ~U[1970-01-01 00:00:00Z]
    {DateTime.to_unix(enqueued_at, :microsecond), request.provider_scope_key, request.request_id}
  end

  defp rotate_fairness_group(grouped, last_served) do
    fairness_keys = grouped |> Map.keys() |> Enum.sort()

    selected_key =
      case fairness_keys do
        [] ->
          nil

        keys ->
          index = Enum.find_index(keys, &(&1 == last_served))

          cond do
            is_nil(index) -> List.first(keys)
            index + 1 < length(keys) -> Enum.at(keys, index + 1)
            true -> List.first(keys)
          end
      end

    Map.get(grouped, selected_key, [])
  end

  defp blocked_queue_summary(queue, now) do
    %{
      pending_count: length(queue.pending),
      running_count: length(queue.running),
      backpressure: blocked_requests(queue, now)
    }
  end

  defp blocked_requests(queue, now) do
    queue.pending
    |> Enum.map(fn request -> backpressure_for(queue, request, now) end)
    |> Enum.reject(&is_nil/1)
  end

  defp pending_summary(queue, request, now) do
    request
    |> request_snapshot()
    |> Map.merge(%{
      wait_ms: elapsed_ms(request.enqueued_at, now),
      backpressure: backpressure_for(queue, request, now)
    })
  end

  defp running_summary(request, now) do
    request
    |> request_snapshot()
    |> Map.merge(%{
      running_ms: elapsed_ms(request.enqueued_at, now)
    })
  end

  defp scope_summaries(queue) do
    scope_keys =
      (Map.keys(queue.scope_states) ++ Enum.map(queue.pending ++ queue.running, & &1.provider_scope_key))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(scope_keys, fn scope_key ->
      running_count = Enum.count(queue.running, &(&1.provider_scope_key == scope_key))
      pending_count = Enum.count(queue.pending, &(&1.provider_scope_key == scope_key))

      %{
        provider_scope_key: scope_key,
        running_count: running_count,
        pending_count: pending_count,
        state: queue.scope_states |> Map.get(scope_key) |> safe_scope_state()
      }
    end)
  end

  defp backpressure_for(queue, request, now) do
    running_count = Enum.count(queue.running, &(&1.provider_scope_key == request.provider_scope_key))
    scope_state = Map.get(queue.scope_states, request.provider_scope_key)

    cond do
      running_count >= queue.max_running_per_scope ->
        backpressure(request, :scope_concurrency, nil)

      scope_state && scope_state.circuit_state == :open ->
        backpressure(request, :circuit_open, scope_state)

      scope_state && scope_state.backoff_until && DateTime.compare(scope_state.backoff_until, now) == :gt ->
        reason = if scope_state.last_error_class == :rate_limited, do: :rate_limited, else: :backoff
        backpressure(request, reason, scope_state)

      quota_exhausted?(scope_state) ->
        backpressure(request, :rate_limited, scope_state)

      true ->
        nil
    end
  end

  defp backpressure(request, reason, scope_state) do
    %{
      request_id: request.request_id,
      logical_key: request.logical_key,
      project_id: request.project_id,
      provider_kind: request.provider_kind,
      provider_scope_key: request.provider_scope_key,
      operation_kind: request.operation_kind,
      reason: reason,
      backoff_until: scope_state && scope_state.backoff_until && DateTime.to_iso8601(scope_state.backoff_until),
      circuit_state: scope_state && scope_state.circuit_state,
      error_class: scope_state && scope_state.last_error_class,
      quota: scope_state && sanitize_map(scope_state.quota || %{})
    }
  end

  defp normalize_provider_scope(%{kind: kind, scope: scope, key: key}) do
    with {:ok, kind} <- required_string(%{kind: kind}, :kind),
         {:ok, key} <- required_string(%{key: key}, :key) do
      {:ok, %{kind: String.downcase(kind), scope: stringify_nested_keys(scope || %{}), key: key}}
    end
  end

  defp normalize_provider_scope(%{"kind" => kind, "scope" => scope, "key" => key}), do: normalize_provider_scope(%{kind: kind, scope: scope, key: key})
  defp normalize_provider_scope(_scope), do: {:error, :missing_provider_scope}

  defp normalize_issue_ref(nil), do: {:ok, nil}
  defp normalize_issue_ref(%IssueRef{} = issue_ref), do: {:ok, issue_ref}
  defp normalize_issue_ref(issue_ref) when is_map(issue_ref), do: {:ok, issue_ref}
  defp normalize_issue_ref(_issue_ref), do: {:error, :invalid_issue_ref}

  defp safe_issue_ref(nil), do: nil

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
      project_id: normalize_optional_string(value(issue_ref, :project_id)),
      tracker_kind: normalize_optional_string(value(issue_ref, :tracker_kind)),
      provider_scope: stringify_nested_keys(value(issue_ref, :provider_scope) || %{}),
      provider_scope_key: normalize_optional_string(value(issue_ref, :provider_scope_key)),
      provider_issue_id: normalize_optional_string(value(issue_ref, :provider_issue_id)),
      provider_local_id: normalize_optional_string(value(issue_ref, :provider_local_id)),
      identifier: normalize_optional_string(value(issue_ref, :identifier)),
      url: normalize_optional_string(value(issue_ref, :url))
    }
  end

  defp normalize_operation_kind(nil), do: {:ok, :candidate_scan}

  defp normalize_operation_kind(operation_kind) when is_atom(operation_kind) do
    {:ok, operation_kind}
  end

  defp normalize_operation_kind(operation_kind) when is_binary(operation_kind) do
    {:ok, operation_kind |> String.trim() |> String.replace("-", "_") |> String.to_atom()}
  end

  defp normalize_operation_kind(_operation_kind), do: {:error, :invalid_operation_kind}

  defp normalize_replay_policy(nil), do: {:ok, :idempotent}

  defp normalize_replay_policy(policy) when is_atom(policy) and policy in @replay_policies do
    {:ok, policy}
  end

  defp normalize_replay_policy(policy) when is_binary(policy) do
    policy
    |> String.trim()
    |> String.replace("-", "_")
    |> String.to_existing_atom()
    |> normalize_replay_policy()
  rescue
    ArgumentError -> {:error, :invalid_replay_policy}
  end

  defp normalize_replay_policy(_policy), do: {:error, :invalid_replay_policy}

  defp normalize_priority(nil, operation_kind), do: {:ok, Map.get(@operation_priorities, operation_kind, 50)}
  defp normalize_priority(priority, _operation_kind) when is_integer(priority), do: {:ok, priority}
  defp normalize_priority(_priority, _operation_kind), do: {:error, :invalid_priority}

  defp normalize_result_status!(status) when status in @result_statuses, do: status
  defp normalize_result_status!(status), do: raise(ArgumentError, "unsupported provider governance result status: #{inspect(status)}")

  defp normalize_error_class(nil), do: nil
  defp normalize_error_class(error_class) when error_class in @error_classes, do: error_class
  defp normalize_error_class(error_class) when is_binary(error_class), do: error_class |> String.replace("-", "_") |> String.to_existing_atom() |> normalize_error_class()
  defp normalize_error_class(_error_class), do: :unknown

  defp normalize_scope_state(scope_key, provider_kind, attrs) do
    circuit_state = normalize_circuit_state(value(attrs, :circuit_state))

    %{
      provider_kind: provider_kind,
      provider_scope_key: scope_key,
      quota: sanitize_map(value(attrs, :quota) || %{}),
      backoff_until: normalize_datetime(value(attrs, :backoff_until)),
      circuit_state: circuit_state,
      last_error_class: normalize_error_class(value(attrs, :last_error_class)),
      updated_at: normalize_datetime(value(attrs, :updated_at))
    }
  end

  defp normalize_circuit_state(nil), do: :closed
  defp normalize_circuit_state(state) when state in @circuit_states, do: state
  defp normalize_circuit_state(state) when is_binary(state), do: state |> String.replace("-", "_") |> String.to_existing_atom() |> normalize_circuit_state()
  defp normalize_circuit_state(_state), do: :closed

  defp safe_scope_state(nil), do: nil

  defp safe_scope_state(state) do
    %{
      provider_kind: state.provider_kind,
      provider_scope_key: state.provider_scope_key,
      quota: sanitize_map(state.quota || %{}),
      backoff_until: state.backoff_until && DateTime.to_iso8601(state.backoff_until),
      circuit_state: state.circuit_state,
      last_error_class: state.last_error_class,
      updated_at: state.updated_at && DateTime.to_iso8601(state.updated_at)
    }
  end

  defp quota_exhausted?(nil), do: false
  defp quota_exhausted?(%{quota: nil}), do: false
  defp quota_exhausted?(%{quota: quota}) when is_map(quota), do: Map.get(quota, :remaining) == 0 or Map.get(quota, "remaining") == 0

  defp manual_attention?(request, :unknown_result) do
    request.replay_policy in [:non_replayable, :unknown_requires_manual_attention]
  end

  defp manual_attention?(_request, _status), do: false

  defp replayable?(request, status) do
    cond do
      status in [:success, :permanent_failure, :canceled] ->
        false

      status == :unknown_result ->
        request.replay_policy in [:idempotent, :marker_upsert]

      request.replay_policy in [:non_replayable, :unknown_requires_manual_attention] ->
        false

      true ->
        true
    end
  end

  defp ledger_link(request, writeback_intent_key, manual_attention) do
    %{
      issue_key: request.issue_key,
      writeback_intent_key: writeback_intent_key,
      manual_attention: manual_attention
    }
  end

  defp default_logical_key(project_id, provider_scope, issue_ref, operation_kind) do
    issue_part =
      case issue_ref do
        nil -> "scope"
        issue_ref -> RuntimeLedger.issue_key(issue_ref)
      end

    Enum.join([project_id, provider_scope.key, Atom.to_string(operation_kind), issue_part], ":")
  end

  defp request_id(project_id, scope_key, logical_key, issue_key) do
    stable = Enum.join([project_id, scope_key, issue_key || "scope", logical_key], "|")
    "provider-request:" <> Base.encode16(:crypto.hash(:sha256, stable), case: :lower)
  end

  defp provider_scope_key(scope_key) when is_binary(scope_key), do: scope_key
  defp provider_scope_key(%{provider_scope_key: scope_key}), do: scope_key
  defp provider_scope_key(%{key: scope_key}), do: scope_key
  defp provider_scope_key(%{"provider_scope_key" => scope_key}), do: scope_key
  defp provider_scope_key(%{"key" => scope_key}), do: scope_key

  defp provider_kind(%{provider_kind: kind}), do: kind
  defp provider_kind(%{kind: kind}), do: kind
  defp provider_kind(%{"provider_kind" => kind}), do: kind
  defp provider_kind(%{"kind" => kind}), do: kind
  defp provider_kind(_scope_like), do: nil

  defp required_string(map, key) do
    case normalize_optional_string(value(map, key)) do
      nil -> {:error, {:missing_required_string, key}}
      value -> {:ok, value}
    end
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

  defp normalize_non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_negative_integer(_value), do: nil

  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(%DateTime{} = value), do: value

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp normalize_datetime(_value), do: nil

  defp elapsed_ms(nil, _now), do: nil
  defp elapsed_ms(%DateTime{} = start, %DateTime{} = now), do: max(DateTime.diff(now, start, :millisecond), 0)

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp truthy?(value), do: value in [true, "true", "1", 1]
  defp present?(nil), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: true

  defp stringify_nested_keys(value) when is_map(value) do
    Map.new(value, fn {key, raw_value} -> {stringify_key(key), stringify_nested_keys(raw_value)} end)
  end

  defp stringify_nested_keys(value) when is_list(value), do: Enum.map(value, &stringify_nested_keys/1)
  defp stringify_nested_keys(value), do: value

  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key), do: to_string(key)

  defp sanitize_map(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, raw_value} -> sensitive_key?(key) or sensitive_value?(raw_value) end)
    |> Map.new(fn {key, raw_value} -> {normalize_output_key(key), sanitize_value(raw_value)} end)
  end

  defp sanitize_map(_value), do: %{}

  defp sanitize_value(%_struct{} = value), do: value
  defp sanitize_value(value) when is_map(value), do: sanitize_map(value)
  defp sanitize_value(value) when is_list(value), do: value |> Enum.reject(&sensitive_value?/1) |> Enum.map(&sanitize_value/1)
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
    key
    |> to_string()
    |> String.downcase()
    |> then(&(MapSet.member?(@sensitive_keys, &1) or String.contains?(&1, ["token", "secret", "credential", "cookie", "prompt", "transcript"])))
  end

  defp sensitive_value?(value) when is_binary(value) do
    Enum.any?(@sensitive_value_patterns, &Regex.match?(&1, value))
  end

  defp sensitive_value?(%_struct{}), do: false

  defp sensitive_value?(value) when is_map(value) do
    Enum.any?(value, fn {key, raw_value} -> sensitive_key?(key) or sensitive_value?(raw_value) end)
  end

  defp sensitive_value?(value) when is_list(value), do: Enum.any?(value, &sensitive_value?/1)
  defp sensitive_value?(_value), do: false
end
