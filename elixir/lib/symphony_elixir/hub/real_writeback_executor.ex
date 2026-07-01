defmodule SymphonyElixir.Hub.RealWritebackExecutor do
  @moduledoc """
  Opt-in Hub provider executor for safe real writebacks.

  The executor is intentionally narrow. It executes only writebacks that are
  idempotent or marker-addressed through a project-local Hub registry context:
  status/stage writes, workpad marker upserts, and label additions. Operations
  with high unknown-result risk, such as PR creation and plain append comments,
  are converted to governed manual-attention results without provider I/O.
  """

  @behaviour SymphonyElixir.Hub.ProviderExecutor

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Client, as: GitHubClient

  alias SymphonyElixir.Hub.{
    ActivationPreflight,
    CutoverAuthorizationConsumptionGuard,
    CutoverGate,
    ProviderGovernance,
    ProviderScope,
    RuntimeLedger,
    SafeSummary,
    WritebackProcessor
  }

  alias SymphonyElixir.Tracker

  @supported_operations [:stage_writeback, :comment_workpad_upsert]
  @supported_logical_actions ["status_set", "workpad_upsert", "label_add"]
  @manual_attention_operations [:pr_create]
  @default_backoff_ms 30_000

  @type routed_execution_result ::
          {:ok, term()}
          | {:provider_result, atom(), keyword()}
          | {:provider_result, atom(), map()}
          | {:error, term()}
          | atom()

  @spec execute(ProviderGovernance.request(), keyword()) :: ProviderGovernance.result()
  def execute(request, opts \\ []) when is_map(request) and is_list(opts) do
    with :ok <- validate_operation_kind(request),
         :ok <- authorization_consumption(request, opts),
         :ok <- cutover_gate(request, opts),
         :ok <- activation_preflight(request, opts),
         {:ok, pending_fact} <- pending_fact(request, opts),
         {:ok, decision} <- WritebackProcessor.decide(runtime_ledger(opts), pending_fact),
         :ok <- allow_execution(decision),
         {:ok, context} <- project_context(request, opts),
         :ok <- validate_context_scope(request, context),
         {:ok, execution} <- execute_writeback(request, pending_fact, context, opts) do
      result_from_execution(request, pending_fact, execution)
    else
      {:authorization_blocked, decision} ->
        authorization_blocked_result(request, decision)

      {:manual_attention, reason} ->
        manual_attention_result(request, reason)

      {:activation_blocked, reason} ->
        activation_blocked_result(request, reason)

      {:cutover_blocked, reason} ->
        cutover_blocked_result(request, reason)

      {:decision_blocked, decision} ->
        blocked_decision_result(request, decision)

      {:unsupported_operation, reason} ->
        unsupported_result(request, reason)

      {:unsupported_provider, reason} ->
        unsupported_provider_result(request, reason)

      {:project_config_error, reason} ->
        config_failure_result(request, reason)

      {:scope_mismatch, reason} ->
        scope_failure_result(request, reason)

      {:provider_error, reason} ->
        provider_failure_result(request, reason)

      {:error, reason} ->
        permanent_failure_result(request, :invalid_request, reason)
    end
  end

  @spec execute_routed(map(), keyword()) :: routed_execution_result()
  def execute_routed(routed_call, opts \\ []) when is_map(routed_call) and is_list(opts) do
    request = Map.get(routed_call, :request) || Map.get(routed_call, "request")

    if is_map(request) do
      execute_routed_request(routed_call, request, opts)
    else
      result_summary = failure_summary(nil, :missing_provider_request, :missing_provider_request)
      {:provider_result, :permanent_failure, error_class: :validation, result_summary: result_summary}
    end
  end

  @spec supported_operations() :: [String.t()]
  def supported_operations do
    ["stage_writeback", "comment_workpad_upsert"]
  end

  @spec supported_logical_actions() :: [String.t()]
  def supported_logical_actions, do: @supported_logical_actions

  @spec rejected_operations() :: [String.t()]
  def rejected_operations do
    ["comment_append", "pr_create", "dynamic_tool_provider_call", "candidate_scan"]
  end

  defp execute_routed_request(routed_call, request, opts) do
    runtime_ledger = Keyword.get(opts, :runtime_ledger, RuntimeLedger.new())
    writeback_intent = Map.get(routed_call, :writeback_intent) || Map.get(routed_call, "writeback_intent")
    summary = routed_summary(routed_call, request, writeback_intent)

    opts =
      opts
      |> Keyword.put_new(:runtime_ledger, runtime_ledger)
      |> Keyword.put(:writeback_summary, summary)
      |> Keyword.put(:writeback_intent, writeback_intent)
      |> Keyword.put(:raw_target, Map.get(routed_call, :raw_target) || Map.get(routed_call, "raw_target") || %{})

    result = execute(request, opts)

    {:provider_result, result.status,
     result_opts(result)
     |> Keyword.put(:payload, payload_for_result(result))
     |> Keyword.put(:result_summary, result.result_summary)}
  end

  defp validate_operation_kind(%{operation_kind: operation_kind}) when operation_kind in @supported_operations, do: :ok

  defp validate_operation_kind(%{operation_kind: operation_kind}) when operation_kind in @manual_attention_operations do
    {:manual_attention, {:provider_lookup_required, operation_kind}}
  end

  defp validate_operation_kind(%{operation_kind: :dynamic_tool_provider_call}) do
    {:unsupported_operation, :dynamic_tool_provider_call}
  end

  defp validate_operation_kind(%{operation_kind: operation_kind}), do: {:unsupported_operation, operation_kind}

  defp cutover_gate(request, opts) do
    case Keyword.get(opts, :cutover_gate) do
      gate when is_map(gate) ->
        case CutoverGate.block_reason(gate, request.project_id, :writeback) do
          nil -> :ok
          reason -> {:cutover_blocked, reason}
        end

      _gate ->
        :ok
    end
  end

  defp activation_preflight(request, opts) do
    case Keyword.get(opts, :activation_preflight) do
      preflight when is_map(preflight) ->
        case ActivationPreflight.block_reason(preflight, request.project_id, :writeback) do
          nil -> :ok
          reason -> {:activation_blocked, reason}
        end

      _preflight ->
        :ok
    end
  end

  defp authorization_consumption(request, opts) do
    case Keyword.get(opts, :authorization_consumption_guard) ||
           Keyword.get(opts, :cutover_authorization_consumption_guard) do
      guard when is_map(guard) ->
        input =
          Map.merge(guard, %{
            project_id: request.project_id,
            provider_scope: request.provider_scope,
            operation: "writeback",
            side_effect_source: "writeback_executor",
            execution_mode: %{
              mode: "real_writeback",
              provider_io: true,
              supported_operations: supported_operations(),
              supported_logical_actions: supported_logical_actions()
            }
          })

        case CutoverAuthorizationConsumptionGuard.require_allowed(input) do
          :ok -> :ok
          {:blocked, decision} -> {:authorization_blocked, decision}
        end

      _guard ->
        :ok
    end
  end

  defp pending_fact(request, opts) do
    cond do
      is_map(Keyword.get(opts, :writeback_fact)) ->
        {:ok, Keyword.fetch!(opts, :writeback_fact)}

      is_map(Keyword.get(opts, :writeback_summary)) ->
        WritebackProcessor.normalize(Keyword.fetch!(opts, :writeback_summary))
        |> normalize_writeback_processor_result()

      is_map(Keyword.get(opts, :writeback_intent)) ->
        request
        |> routed_summary_from_request(Keyword.fetch!(opts, :writeback_intent))
        |> WritebackProcessor.normalize()
        |> normalize_writeback_processor_result()

      true ->
        {:error, :missing_writeback_intent}
    end
  end

  defp normalize_writeback_processor_result({:ok, fact}), do: {:ok, fact}
  defp normalize_writeback_processor_result({:error, diagnostics}), do: {:error, {:writeback_normalize_failed, diagnostic_codes(diagnostics)}}

  defp allow_execution(%{action: action}) when action in [:execute_once, :retry_writeback], do: :ok
  defp allow_execution(decision), do: {:decision_blocked, decision}

  defp project_context(request, opts) do
    with :ok <- validate_provider_kind(request.provider_kind),
         {:ok, registry} <- registry(opts),
         {:ok, project} <- registry_project(registry, request.project_id),
         :ok <- validate_project_scope(request, project),
         {:ok, settings} <- project_settings(project),
         :ok <- validate_provider_kind(settings.tracker.kind),
         :ok <- validate_settings_scope(request, settings) do
      {:ok, %{project: project, settings: settings}}
    end
  end

  defp validate_provider_kind(provider_kind) when provider_kind in ["memory", "github", "gitlab", "linear"], do: :ok
  defp validate_provider_kind(provider_kind), do: {:unsupported_provider, provider_kind}

  defp registry(opts) do
    case Keyword.get(opts, :registry) do
      registry when is_map(registry) -> {:ok, registry}
      _registry -> {:error, :missing_hub_registry}
    end
  end

  defp registry_project(registry, project_id) do
    registry
    |> list_value(:projects)
    |> Enum.find(&(optional_string(&1, :project_id) == project_id))
    |> case do
      nil -> {:error, :project_not_found}
      %{status: :error, load_error: load_error} -> {:project_config_error, load_error || "project configuration did not load"}
      %{"status" => "error", "load_error" => load_error} -> {:project_config_error, load_error || "project configuration did not load"}
      project -> {:ok, project}
    end
  end

  defp validate_project_scope(request, project) do
    tracker = value(project, :tracker_summary) || %{}

    cond do
      optional_string(tracker, :kind) != request.provider_kind ->
        {:scope_mismatch, :provider_kind_mismatch}

      optional_string(tracker, :provider_scope_key) != request.provider_scope_key ->
        {:scope_mismatch, :provider_scope_key_mismatch}

      true ->
        :ok
    end
  end

  defp project_settings(project) do
    with {:ok, workflow_path} <- required_path(project, :workflow_path),
         {:ok, tracker_config_path} <- required_path(project, :tracker_config_path),
         {:ok, settings} <- Config.settings_from_files(workflow_path, tracker_config_path) do
      {:ok, settings}
    else
      {:error, reason} -> {:project_config_error, reason}
    end
  end

  defp validate_settings_scope(request, settings) do
    case ProviderScope.from_tracker(request.project_id, settings.tracker) do
      {:ok, scope} ->
        cond do
          settings.tracker.kind != request.provider_kind ->
            {:scope_mismatch, :settings_provider_kind_mismatch}

          scope.key != request.provider_scope_key ->
            {:scope_mismatch, :settings_provider_scope_mismatch}

          true ->
            :ok
        end

      {:error, reason} ->
        {:scope_mismatch, reason}
    end
  end

  defp validate_context_scope(request, %{settings: settings}) do
    if settings.tracker.kind == request.provider_kind do
      :ok
    else
      {:scope_mismatch, :settings_provider_kind_mismatch}
    end
  end

  defp execute_writeback(request, fact, %{settings: settings}, opts) do
    target = fact.writeback.target
    logical_action = fact.writeback.logical_action
    issue_id = issue_id(request, fact)

    if blank?(issue_id) do
      {:error, :missing_issue_id}
    else
      Config.with_settings(settings, fn ->
        execute_project_local_writeback(logical_action, request, issue_id, target, opts)
      end)
      |> normalize_provider_call_result()
    end
  end

  defp execute_project_local_writeback("status_set", request, issue_id, target, opts) do
    state = required_target_string(target, "state")

    cond do
      blank?(state) ->
        {:error, :missing_state}

      request.provider_kind == "github" ->
        update_issue_state = Keyword.get(opts, :github_update_issue_state, &GitHubClient.update_issue_state/2)

        with :ok <- update_issue_state.(issue_id, state) do
          {:ok, %{issue_id: issue_id, state: state, updated: true, provider_io: true}}
        end

      true ->
        update_issue_state = Keyword.get(opts, :tracker_update_issue_state, &Tracker.update_issue_state/2)

        with :ok <- update_issue_state.(issue_id, state) do
          {:ok, %{issue_id: issue_id, state: state, updated: true, provider_io: true}}
        end
    end
  end

  defp execute_project_local_writeback("workpad_upsert", request, issue_id, target, opts) do
    if request.provider_kind == "github" do
      raw_target = Keyword.get(opts, :raw_target, %{})
      body = Keyword.get(opts, :body) || Keyword.get(opts, :comment_body) || value(raw_target, :body)
      header = required_target_string(target, "header") || "## Codex Workpad"

      if blank?(body) do
        {:error, :missing_workpad_body}
      else
        upsert_workpad_comment = Keyword.get(opts, :github_upsert_workpad_comment, &GitHubClient.upsert_workpad_comment/3)

        with {:ok, result} <- upsert_workpad_comment.(issue_id, body, header) do
          {:ok,
           %{
             issue_id: issue_id,
             marker: header,
             comment: result |> value(:comment) |> safe_result_map(),
             external_ref: external_ref(result),
             provider_io: true
           }}
        end
      end
    else
      {:unsupported_provider, request.provider_kind}
    end
  end

  defp execute_project_local_writeback("label_add", request, issue_id, target, opts) do
    if request.provider_kind == "github" do
      labels = list_value(target, "labels")

      if labels == [] do
        {:error, :missing_labels}
      else
        add_labels = Keyword.get(opts, :github_add_labels, &GitHubClient.add_labels/2)

        with {:ok, applied_labels} <- add_labels.(issue_id, labels) do
          {:ok, %{issue_id: issue_id, labels: applied_labels, label_count: length(applied_labels), provider_io: true}}
        end
      end
    else
      {:unsupported_provider, request.provider_kind}
    end
  end

  defp execute_project_local_writeback("pr_create", _request, _issue_id, _target, _opts) do
    {:manual_attention, :provider_lookup_required}
  end

  defp execute_project_local_writeback("comment_append", _request, _issue_id, _target, _opts) do
    {:manual_attention, :append_comment_not_replayable}
  end

  defp execute_project_local_writeback(logical_action, _request, _issue_id, _target, _opts) do
    {:unsupported_operation, logical_action}
  end

  defp normalize_provider_call_result({:ok, payload}), do: {:ok, payload}
  defp normalize_provider_call_result({:error, reason}), do: {:provider_error, reason}
  defp normalize_provider_call_result({:unsupported_provider, reason}), do: {:unsupported_provider, reason}
  defp normalize_provider_call_result({:unsupported_operation, reason}), do: {:unsupported_operation, reason}
  defp normalize_provider_call_result({:manual_attention, reason}), do: {:manual_attention, reason}
  defp normalize_provider_call_result(other), do: {:provider_error, {:unexpected_provider_result, other}}

  defp result_from_execution(request, fact, payload) do
    ProviderGovernance.result(request, :success,
      writeback_intent_key: fact.writeback.intent_key,
      external_ref: external_ref(payload),
      result_summary: success_summary(request, fact, payload)
    )
  end

  defp success_summary(request, fact, payload) do
    payload
    |> safe_result_map()
    |> Map.merge(%{
      boundary: "hub_real_writeback_executor",
      executor: "real_writeback",
      provider_io: true,
      provider_kind: request.provider_kind,
      provider_scope_key: request.provider_scope_key,
      operation_kind: Atom.to_string(request.operation_kind),
      logical_action: fact.writeback.logical_action,
      writeback_intent_key: fact.writeback.intent_key,
      target: fact.writeback.target
    })
    |> SafeSummary.sanitize_map(atom_values: :preserve)
  end

  defp manual_attention_result(request, reason) do
    ProviderGovernance.result(request, :unknown_result,
      error_class: :unknown,
      result_summary: failure_summary(request, :manual_attention, reason)
    )
  end

  defp blocked_decision_result(request, decision) do
    status =
      case decision.decision do
        :completed -> :success
        :retry -> :retryable_failure
        :manual_attention -> :unknown_result
        :conflict -> :permanent_failure
        :failed -> :permanent_failure
        _decision -> :permanent_failure
      end

    ProviderGovernance.result(request, status,
      error_class: error_class_for_decision(decision),
      writeback_intent_key: decision.intent_key,
      result_summary: %{
        boundary: "hub_real_writeback_executor",
        executor: "real_writeback",
        provider_io: false,
        decision: Atom.to_string(decision.decision),
        action: Atom.to_string(decision.action),
        reason: safe_reason(decision.reason),
        writeback_intent_key: decision.intent_key,
        manual_attention: decision.manual_attention == true,
        diagnostics: diagnostic_codes(decision.diagnostics)
      }
    )
  end

  defp activation_blocked_result(request, reason) do
    ProviderGovernance.result(request, :permanent_failure,
      error_class: :conflict,
      result_summary: %{
        boundary: "hub_real_writeback_executor",
        executor: "real_writeback",
        provider_io: false,
        error: "activation_preflight_blocked",
        reason: safe_reason(value(reason, :reason) || :activation_preflight_blocked),
        status: safe_reason(value(reason, :status)),
        blocked_operations: list_value(reason, :blocked_operations),
        sources: list_value(reason, :sources)
      }
    )
  end

  defp cutover_blocked_result(request, reason) do
    ProviderGovernance.result(request, :permanent_failure,
      error_class: :conflict,
      result_summary: %{
        boundary: "hub_real_writeback_executor",
        executor: "real_writeback",
        provider_io: false,
        error: "cutover_gate_blocked",
        reason: safe_reason(value(reason, :reason) || :cutover_gate_blocked),
        status: safe_reason(value(reason, :status)),
        blocked_operations: list_value(reason, :blocked_operations),
        allowed_operations: list_value(reason, :allowed_operations),
        required_operator_actions: list_value(reason, :required_operator_actions),
        sources: list_value(reason, :sources),
        cutover_gate: SafeSummary.sanitize_map(value(reason, :cutover_gate) || %{}, output_keys: :preserve)
      }
    )
  end

  defp authorization_blocked_result(request, decision) do
    ProviderGovernance.result(request, :permanent_failure,
      error_class: authorization_error_class(decision),
      result_summary: %{
        boundary: "hub_real_writeback_executor",
        executor: "real_writeback",
        provider_io: false,
        error: "authorization_consumption_blocked",
        authorization_consumption: decision,
        decision: decision.decision,
        reason: decision.reason_code,
        action: value(decision, :action_code)
      }
    )
  end

  defp authorization_error_class(%{decision: "manual_attention"}), do: :unknown
  defp authorization_error_class(%{decision: "stale"}), do: :conflict
  defp authorization_error_class(%{decision: "no_authorization"}), do: :conflict
  defp authorization_error_class(%{decision: "blocked"}), do: :conflict
  defp authorization_error_class(_decision), do: :validation

  defp error_class_for_decision(%{decision: :conflict}), do: :conflict
  defp error_class_for_decision(%{manual_attention: true}), do: :unknown
  defp error_class_for_decision(_decision), do: :validation

  defp unsupported_result(request, reason) do
    ProviderGovernance.result(request, :permanent_failure,
      error_class: :validation,
      result_summary: failure_summary(request, :unsupported_operation, reason)
    )
  end

  defp unsupported_provider_result(request, reason) do
    ProviderGovernance.result(request, :permanent_failure,
      error_class: :validation,
      result_summary: failure_summary(request, :unsupported_provider, reason)
    )
  end

  defp config_failure_result(request, reason) do
    ProviderGovernance.result(request, :permanent_failure,
      error_class: :auth_config,
      result_summary: failure_summary(request, :project_config_error, reason)
    )
  end

  defp scope_failure_result(request, reason) do
    ProviderGovernance.result(request, :permanent_failure,
      error_class: :validation,
      result_summary: failure_summary(request, :scope_mismatch, reason)
    )
  end

  defp permanent_failure_result(request, error, reason) do
    ProviderGovernance.result(request, :permanent_failure,
      error_class: :validation,
      result_summary: failure_summary(request, error, reason)
    )
  end

  defp provider_failure_result(request, reason) do
    {status, error_class, retry_after_ms} = provider_failure_classification(reason)

    opts =
      [
        error_class: error_class,
        retry_after_ms: retry_after_ms,
        result_summary: failure_summary(request, :provider_error, reason)
      ]
      |> maybe_put_backoff(status, retry_after_ms)

    ProviderGovernance.result(request, status, opts)
  end

  defp provider_failure_classification(reason) do
    cond do
      rate_limited?(reason) ->
        {:rate_limited, :rate_limited, retry_after_ms(reason)}

      retryable?(reason) ->
        {:retryable_failure, retryable_error_class(reason), retry_after_ms(reason) || @default_backoff_ms}

      permanent?(reason) ->
        {:permanent_failure, permanent_error_class(reason), nil}

      unknown?(reason) ->
        {:unknown_result, :unknown, @default_backoff_ms}

      true ->
        {:permanent_failure, :unknown, nil}
    end
  end

  defp maybe_put_backoff(opts, status, retry_after_ms) when status in [:rate_limited, :retryable_failure, :unknown_result] do
    retry_after_ms = retry_after_ms || @default_backoff_ms
    Keyword.put(opts, :backoff_until, DateTime.utc_now() |> DateTime.add(retry_after_ms, :millisecond))
  end

  defp maybe_put_backoff(opts, _status, _retry_after_ms), do: opts

  defp failure_summary(request, error, reason) do
    %{
      boundary: "hub_real_writeback_executor",
      executor: "real_writeback",
      provider_io: error == :provider_error,
      provider_kind: request && request.provider_kind,
      provider_scope_key: request && request.provider_scope_key,
      operation_kind: request && Atom.to_string(request.operation_kind),
      error: Atom.to_string(error),
      reason: safe_reason(reason)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> SafeSummary.sanitize_map(atom_values: :preserve)
  end

  defp routed_summary(routed_call, request, writeback_intent) do
    %{
      request:
        Map.get(routed_call, :request_summary) ||
          Map.get(routed_call, "request_summary") ||
          ProviderGovernance.request_snapshot(request),
      result: %{},
      tool_call: Map.get(routed_call, :tool_call) || Map.get(routed_call, "tool_call") || %{},
      writeback_intent: writeback_intent
    }
  end

  defp routed_summary_from_request(request, writeback_intent) do
    %{
      request: ProviderGovernance.request_snapshot(request),
      result: %{},
      tool_call: %{target: Map.get(writeback_intent, :target) || Map.get(writeback_intent, "target") || %{}},
      writeback_intent: writeback_intent
    }
  end

  defp runtime_ledger(opts) do
    opts
    |> Keyword.get(:runtime_ledger, RuntimeLedger.new())
    |> RuntimeLedger.to_snapshot()
  end

  defp issue_id(request, fact) do
    optional_string(fact.writeback.target, "issue_id") ||
      optional_string(request.issue_ref || %{}, :provider_local_id) ||
      optional_string(request.issue_ref || %{}, :provider_issue_id) ||
      request.issue_key
      |> optional_issue_id_from_key()
  end

  defp optional_issue_id_from_key(nil), do: nil

  defp optional_issue_id_from_key(issue_key) when is_binary(issue_key) do
    issue_key
    |> String.split(":")
    |> List.last()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp result_opts(result) do
    [
      error_class: result.error_class,
      retry_after_ms: result.retry_after_ms,
      backoff_until: result.backoff_until,
      external_ref: result.external_ref
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp payload_for_result(%{status: :success, result_summary: summary}), do: summary
  defp payload_for_result(result), do: %{status: result.status, error_class: result.error_class, manual_attention: result.manual_attention}

  defp external_ref(payload) when is_map(payload) do
    optional_string(payload, :external_ref) ||
      optional_string(payload, :url) ||
      get_in(payload, [:comment, :url]) ||
      get_in(payload, ["comment", "url"])
  end

  defp external_ref(_payload), do: nil

  defp safe_result_map(value) when is_map(value), do: SafeSummary.sanitize_map(value, atom_values: :preserve)
  defp safe_result_map(value) when is_list(value), do: %{items_count: length(value)}
  defp safe_result_map(nil), do: %{}
  defp safe_result_map(value), do: %{value: safe_reason(value)}

  defp required_target_string(target, key) do
    optional_string(target, key) ||
      optional_string(target, String.to_atom(key))
  end

  defp rate_limited?(reason) do
    reason_contains?(reason, ["rate_limit", "rate-limited", "rate limited", "abuse", "quota"]) or
      status_in?(reason, [429])
  end

  defp retryable?(reason) do
    reason_contains?(reason, ["timeout", "timed out", "econnrefused", "closed", "nxdomain", "network"]) or
      status_in?(reason, [408, 409, 425, 500, 502, 503, 504])
  end

  defp permanent?(reason) do
    reason_contains?(reason, [
      "missing_",
      "not_found",
      "not found",
      "unauthorized",
      "forbidden",
      "invalid",
      "validation",
      "state_not_found"
    ]) or
      status_in?(reason, [400, 401, 403, 404, 422])
  end

  defp unknown?(reason) do
    reason_contains?(reason, ["unknown", "ambiguous", "lost acknowledgement", "accepted request"]) or
      reason in [
        :comment_create_failed,
        :comment_update_failed,
        :label_update_failed,
        :pull_request_create_failed,
        :unknown_result
      ]
  end

  defp retryable_error_class(reason) do
    cond do
      reason_contains?(reason, ["timeout", "timed out"]) -> :network_timeout
      status_in?(reason, [500, 502, 503, 504]) -> :provider_5xx
      true -> :unknown
    end
  end

  defp permanent_error_class(reason) do
    cond do
      reason_contains?(reason, ["missing_", "unauthorized", "forbidden"]) or status_in?(reason, [401, 403]) -> :auth_config
      reason_contains?(reason, ["not_found", "not found"]) or status_in?(reason, [404]) -> :not_found
      true -> :validation
    end
  end

  defp retry_after_ms({:retry_after_ms, value}), do: non_negative_integer(value)
  defp retry_after_ms({:rate_limited, value}), do: non_negative_integer(value)
  defp retry_after_ms({:github_api_status, 429}), do: 60_000
  defp retry_after_ms({:gitlab_api_status, 429}), do: 60_000
  defp retry_after_ms({:linear_api_status, 429}), do: 60_000
  defp retry_after_ms(_reason), do: nil

  defp status_in?({_kind, status}, statuses) when is_integer(status), do: status in statuses
  defp status_in?({_kind, %{status: status}}, statuses) when is_integer(status), do: status in statuses
  defp status_in?(%{status: status}, statuses) when is_integer(status), do: status in statuses
  defp status_in?(_reason, _statuses), do: false

  defp reason_contains?(reason, needles) do
    text =
      reason
      |> inspect()
      |> String.downcase()

    Enum.any?(needles, &String.contains?(text, &1))
  end

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(reason) when is_binary(reason), do: safe_reason_text(reason)
  defp safe_reason({kind, status}) when is_atom(kind) and is_integer(status), do: "#{kind}:#{status}"
  defp safe_reason({kind, reason}) when is_atom(kind), do: "#{kind}:#{safe_reason(reason)}"
  defp safe_reason(reason) when is_map(reason), do: safe_type(reason)
  defp safe_reason(reason) when is_list(reason), do: safe_type(reason)
  defp safe_reason(reason), do: safe_type(reason)

  defp safe_reason_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\$[A-Z0-9_]*(TOKEN|API_KEY|SECRET|CREDENTIAL)[A-Z0-9_]*/, "[redacted]")
    |> String.replace(~r/\b(Bearer|token|secret|credential|cookie|authorization)\b[^,\s]*/i, "[redacted]")
    |> String.slice(0, 200)
  end

  defp safe_type(%_struct{} = value), do: value.__struct__ |> inspect() |> safe_reason_text()
  defp safe_type(value) when is_map(value), do: "map"
  defp safe_type(value) when is_list(value), do: "list"
  defp safe_type(value) when is_tuple(value), do: "tuple"
  defp safe_type(value) when is_binary(value), do: "binary"
  defp safe_type(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_type(value) when is_integer(value), do: "integer"
  defp safe_type(value) when is_float(value), do: "float"
  defp safe_type(_value), do: "term"

  defp required_path(project, key) do
    case optional_string(project, key) do
      nil -> {:error, {:missing_project_path, key}}
      path -> {:ok, Path.expand(path)}
    end
  end

  defp list_value(map, key) when is_map(map) do
    case value(map, key) do
      value when is_list(value) -> value
      _value -> []
    end
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) ||
      Map.get(map, Atom.to_string(key)) ||
      if(is_binary(key), do: Map.get(map, String.to_atom(key)), else: nil)
  end

  defp value(_map, _key), do: nil

  defp optional_string(map, key) when is_map(map), do: map |> value(key) |> optional_string()
  defp optional_string(value, _key), do: optional_string(value)

  defp optional_string(nil), do: nil

  defp optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(_value), do: nil

  defp diagnostic_codes(diagnostics) when is_list(diagnostics) do
    Enum.map(diagnostics, fn
      %{code: code} -> code
      %{"code" => code} -> code
      diagnostic -> safe_reason(diagnostic)
    end)
  end

  defp diagnostic_codes(_diagnostics), do: []

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
