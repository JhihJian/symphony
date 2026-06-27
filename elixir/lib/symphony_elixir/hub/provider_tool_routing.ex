defmodule SymphonyElixir.Hub.ProviderToolRouting do
  @moduledoc """
  Opt-in Hub provider routing boundary for dynamic tool provider calls.

  The module builds `ProviderGovernance` requests for structured dynamic tools,
  executes the provider operation through an injectable executor, and returns a
  safe request/result summary alongside a response payload compatible with the
  existing dynamic tool shape.

  It is intentionally narrow: callers must opt in by passing routing context and
  an operation function. The legacy direct dynamic tool path remains unchanged
  when this boundary is not enabled.
  """

  alias SymphonyElixir.Hub.ProviderGovernance
  alias SymphonyElixir.Hub.RuntimeLedger

  @provider_tools ["github_issue", "github_pr", "tracker_issue"]
  @writeback_operations %{
    {"github_issue", "upsert_workpad_comment"} => :workpad_upsert,
    {"github_issue", "set_status"} => :status_set,
    {"github_issue", "add_labels"} => :label_add,
    {"github_pr", "create_pr"} => :pr_create,
    {"tracker_issue", "create_comment"} => :comment_append,
    {"tracker_issue", "set_status"} => :status_set
  }

  @type routing_context :: %{
          optional(:project_id) => String.t(),
          optional(:provider_scope) => ProviderGovernance.provider_scope(),
          optional(:issue_ref) => map(),
          optional(:run_context) => map(),
          optional(:config_fingerprint) => String.t(),
          optional(:snapshot_version) => String.t(),
          optional(:correlation) => map()
        }

  @type routed_call :: %{
          required(:request) => ProviderGovernance.request(),
          required(:request_summary) => map(),
          required(:tool_call) => map(),
          required(:writeback_intent) => map() | nil
        }

  @type execution_result :: %{
          required(:success) => boolean(),
          required(:payload) => map(),
          required(:request) => ProviderGovernance.request(),
          required(:result) => ProviderGovernance.result(),
          required(:summary) => map()
        }

  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts) when is_list(opts) do
    case Keyword.get(opts, :hub_provider_routing) do
      nil -> false
      false -> false
      %{enabled: false} -> false
      %{"enabled" => false} -> false
      context when is_map(context) or is_list(context) -> true
      _context -> false
    end
  end

  @spec build_request(String.t(), String.t(), map(), keyword()) :: {:ok, routed_call()} | {:error, term()}
  def build_request(tool_name, operation, target, opts)
      when is_binary(tool_name) and is_binary(operation) and is_map(target) and is_list(opts) do
    with :ok <- validate_tool(tool_name),
         {:ok, context} <- routing_context(opts),
         {:ok, project_id} <- required_string(context, :project_id),
         {:ok, provider_scope} <- provider_scope(context),
         {:ok, issue_ref} <- issue_ref(project_id, provider_scope, tool_name, target, context),
         operation_kind <- operation_kind(tool_name, operation),
         replay_policy <- replay_policy(tool_name, operation),
         logical_key <- logical_key(project_id, provider_scope, issue_ref, tool_name, operation, target),
         writeback_intent <- writeback_intent(issue_ref, tool_name, operation, target),
         correlation <- correlation(context, tool_name, operation, target) do
      with {:ok, request} <-
             ProviderGovernance.new_request(%{
               project_id: project_id,
               provider_scope: provider_scope,
               issue_ref: issue_ref,
               operation_kind: operation_kind,
               replay_policy: replay_policy,
               logical_key: logical_key,
               config_fingerprint: optional_string(context, :config_fingerprint),
               snapshot_version: optional_string(context, :snapshot_version),
               correlation: correlation,
               user_initiated: truthy?(value(context, :user_initiated)),
               timeout_ms: non_negative_integer(value(context, :timeout_ms)),
               deadline_at: value(context, :deadline_at),
               cancel_token: value(context, :cancel_token)
             }) do
        request_summary = ProviderGovernance.request_snapshot(request)

        {:ok,
         %{
           request: request,
           request_summary: request_summary,
           tool_call: safe_tool_call(tool_name, operation, target),
           writeback_intent: writeback_intent
         }}
      end
    end
  end

  @spec execute(String.t(), String.t(), map(), (-> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, execution_result()} | {:error, term()}
  def execute(tool_name, operation, target, provider_call, opts)
      when is_binary(tool_name) and is_binary(operation) and is_map(target) and
             is_function(provider_call, 0) and is_list(opts) do
    with {:ok, routed_call} <- build_request(tool_name, operation, target, opts) do
      executor = Keyword.get(opts, :hub_provider_executor, &direct_executor/1)
      execution = executor.(Map.put(routed_call, :provider_call, provider_call))
      {:ok, execution_result(routed_call, execution)}
    end
  end

  @spec direct_executor(map()) :: term()
  def direct_executor(%{provider_call: provider_call}) when is_function(provider_call, 0) do
    provider_call.()
  end

  @spec summary(execution_result()) :: map()
  def summary(%{summary: summary}) when is_map(summary), do: summary

  defp execution_result(routed_call, execution) do
    request = routed_call.request
    {status, payload, result_opts} = normalize_execution(execution)
    writeback_intent_key = routed_call.writeback_intent && routed_call.writeback_intent.intent_key

    result =
      ProviderGovernance.result(
        request,
        status,
        result_opts
        |> Keyword.put(:writeback_intent_key, writeback_intent_key)
        |> Keyword.put_new(:result_summary, result_summary(payload, routed_call))
        |> Keyword.put_new(:external_ref, external_ref(payload))
      )

    success = status == :success
    governance_summary = governance_summary(routed_call, result)

    %{
      success: success,
      payload: routed_payload(success, payload, governance_summary, result),
      request: request,
      result: result,
      summary: governance_summary
    }
  end

  defp routed_payload(true, payload, governance_summary, _result) when is_map(payload) do
    Map.put(payload, "providerGovernance", stringify_keys(governance_summary))
  end

  defp routed_payload(true, payload, governance_summary, _result) do
    %{
      "result" => payload,
      "providerGovernance" => stringify_keys(governance_summary)
    }
  end

  defp routed_payload(false, payload, governance_summary, result) do
    %{
      "error" => %{
        "message" => provider_failure_message(result),
        "providerStatus" => Atom.to_string(result.status),
        "errorClass" => result.error_class && Atom.to_string(result.error_class),
        "retryable" => result.replayable,
        "manualAttention" => result.manual_attention
      },
      "providerGovernance" => stringify_keys(governance_summary),
      "providerResult" => stringify_keys(safe_result_payload(payload))
    }
  end

  defp provider_failure_message(%{status: :rate_limited}), do: "Hub provider routing delayed the tool call because the provider scope is rate limited."
  defp provider_failure_message(%{status: :circuit_open}), do: "Hub provider routing rejected the tool call because the provider scope circuit is open."
  defp provider_failure_message(%{status: :unknown_result}), do: "Hub provider routing could not confirm the provider result."
  defp provider_failure_message(%{status: :timed_out}), do: "Hub provider routing timed out before confirming the provider result."
  defp provider_failure_message(%{status: :canceled}), do: "Hub provider routing canceled the provider request."
  defp provider_failure_message(%{status: :permanent_failure}), do: "Hub provider routing observed a permanent provider failure."
  defp provider_failure_message(_result), do: "Hub provider routing observed a retryable provider failure."

  defp normalize_execution({:ok, payload}), do: {:success, payload, []}

  defp normalize_execution({:error, reason}) do
    {status, error_class, retry_after_ms} = classify_error(reason)
    {status, error_payload(reason), Keyword.reject([error_class: error_class, retry_after_ms: retry_after_ms], fn {_key, value} -> is_nil(value) end)}
  end

  defp normalize_execution({:provider_result, status, opts}) when is_atom(status) and is_list(opts) do
    payload = Keyword.get(opts, :payload, Keyword.get(opts, :result_summary, %{}))

    result_opts =
      opts
      |> Keyword.take([:error_class, :retry_after_ms, :backoff_until, :result_summary, :external_ref])

    {status, payload, result_opts}
  end

  defp normalize_execution({:provider_result, status, attrs}) when is_atom(status) and is_map(attrs) do
    normalize_execution({:provider_result, status, Map.to_list(attrs)})
  end

  defp normalize_execution(:rate_limited), do: {:rate_limited, %{}, [error_class: :rate_limited]}
  defp normalize_execution(:circuit_open), do: {:circuit_open, %{}, [error_class: :auth_config]}
  defp normalize_execution(:timed_out), do: {:timed_out, %{}, [error_class: :network_timeout]}
  defp normalize_execution(:canceled), do: {:canceled, %{}, []}
  defp normalize_execution(:unknown_result), do: {:unknown_result, %{}, [error_class: :unknown]}
  defp normalize_execution(other), do: normalize_execution({:error, other})

  defp classify_error({:github_api_status, status}) when status in [401, 403], do: {:permanent_failure, :auth_config, nil}
  defp classify_error({:github_api_status, status}) when status in [408, 429], do: {:rate_limited, :rate_limited, nil}
  defp classify_error({:github_api_status, status}) when status >= 500, do: {:retryable_failure, :provider_5xx, nil}
  defp classify_error({:github_api_status, 404}), do: {:permanent_failure, :not_found, nil}
  defp classify_error({:github_api_status, 409}), do: {:permanent_failure, :conflict, nil}
  defp classify_error({:github_api_status, _status}), do: {:permanent_failure, :validation, nil}
  defp classify_error({:linear_api_status, status}) when status in [401, 403], do: {:permanent_failure, :auth_config, nil}
  defp classify_error({:linear_api_status, status}) when status in [408, 429], do: {:rate_limited, :rate_limited, nil}
  defp classify_error({:linear_api_status, status}) when status >= 500, do: {:retryable_failure, :provider_5xx, nil}
  defp classify_error({:linear_api_status, 404}), do: {:permanent_failure, :not_found, nil}
  defp classify_error({:linear_api_status, _status}), do: {:permanent_failure, :validation, nil}
  defp classify_error({:github_api_request, :timeout}), do: {:retryable_failure, :network_timeout, nil}
  defp classify_error({:linear_api_request, :timeout}), do: {:retryable_failure, :network_timeout, nil}
  defp classify_error({:github_api_request, _reason}), do: {:retryable_failure, :unknown, nil}
  defp classify_error({:linear_api_request, _reason}), do: {:retryable_failure, :unknown, nil}
  defp classify_error(:timeout), do: {:retryable_failure, :network_timeout, nil}
  defp classify_error(:timed_out), do: {:timed_out, :network_timeout, nil}
  defp classify_error(:rate_limited), do: {:rate_limited, :rate_limited, nil}
  defp classify_error(:circuit_open), do: {:circuit_open, :auth_config, nil}
  defp classify_error(:missing_github_api_token), do: {:permanent_failure, :auth_config, nil}
  defp classify_error(:missing_linear_api_token), do: {:permanent_failure, :auth_config, nil}
  defp classify_error(:issue_not_found), do: {:permanent_failure, :not_found, nil}
  defp classify_error(:github_project_item_not_found), do: {:permanent_failure, :not_found, nil}
  defp classify_error(:pull_request_create_failed), do: {:unknown_result, :unknown, nil}
  defp classify_error(:comment_create_failed), do: {:unknown_result, :unknown, nil}
  defp classify_error(:comment_update_failed), do: {:unknown_result, :unknown, nil}
  defp classify_error(:label_update_failed), do: {:unknown_result, :unknown, nil}
  defp classify_error(_reason), do: {:permanent_failure, :unknown, nil}

  defp error_payload(reason) do
    %{
      "reason" => inspect(reason)
    }
  end

  defp governance_summary(routed_call, result) do
    %{
      request: routed_call.request_summary,
      result: ProviderGovernance.result_summary(result),
      tool_call: routed_call.tool_call,
      writeback_intent: routed_call.writeback_intent
    }
  end

  defp result_summary(payload, routed_call) do
    safe_result_payload(payload)
    |> Map.put(:target, routed_call.tool_call.target)
  end

  defp safe_result_payload(payload) when is_map(payload) do
    payload
    |> summarize_known_result_fields()
    |> sanitize_map()
  end

  defp safe_result_payload(payload) when is_list(payload), do: %{items_count: length(payload)}
  defp safe_result_payload(nil), do: %{}
  defp safe_result_payload(payload), do: %{value: inspect(payload)}

  defp summarize_known_result_fields(payload) do
    %{}
    |> maybe_put(:action, string_value(payload, "action"))
    |> maybe_put(:issue_id, string_value(payload, "issueId"))
    |> maybe_put(:pr_number, nested_string_value(payload, ["pullRequest", "number"]))
    |> maybe_put(:state, string_value(payload, "state"))
    |> maybe_put(:updated, Map.get(payload, "updated") || Map.get(payload, :updated))
    |> maybe_put(:comment_id, nested_string_value(payload, ["comment", "id"]))
    |> maybe_put(:comment_url, nested_string_value(payload, ["comment", "url"]))
    |> maybe_put(:pull_request_url, nested_string_value(payload, ["pullRequest", "url"]))
    |> maybe_put(:comments_count, count_value(payload, "comments"))
    |> maybe_put(:reviews_count, count_value(payload, "reviews"))
    |> maybe_put(:pull_requests_count, count_value(payload, "pullRequests"))
  end

  defp external_ref(payload) when is_map(payload) do
    nested_string_value(payload, ["comment", "url"]) ||
      nested_string_value(payload, ["pullRequest", "url"]) ||
      string_value(payload, "url")
  end

  defp external_ref(_payload), do: nil

  defp validate_tool(tool_name) when tool_name in @provider_tools, do: :ok
  defp validate_tool(tool_name), do: {:error, {:unsupported_provider_tool_routing, tool_name}}

  defp routing_context(opts) do
    case Keyword.get(opts, :hub_provider_routing) do
      context when is_list(context) -> {:ok, Map.new(context)}
      context when is_map(context) -> {:ok, context}
      _context -> {:error, :missing_hub_provider_routing_context}
    end
  end

  defp provider_scope(context) do
    case value(context, :provider_scope) do
      %{kind: kind, scope: scope, key: key} ->
        {:ok, %{kind: to_string(kind), scope: stringify_keys(scope || %{}), key: to_string(key)}}

      %{"kind" => kind, "scope" => scope, "key" => key} ->
        {:ok, %{kind: to_string(kind), scope: stringify_keys(scope || %{}), key: to_string(key)}}

      _scope ->
        {:error, :missing_hub_provider_scope}
    end
  end

  defp issue_ref(project_id, provider_scope, tool_name, target, context) do
    cond do
      is_map(value(context, :issue_ref)) ->
        {:ok, value(context, :issue_ref)}

      Map.has_key?(target, :issue_id) ->
        {:ok, issue_ref_from_target(project_id, provider_scope, tool_name, target)}

      true ->
        {:ok, nil}
    end
  end

  defp issue_ref_from_target(project_id, provider_scope, tool_name, target) do
    issue_id = to_string(Map.get(target, :issue_id))

    %{
      project_id: project_id,
      tracker_kind: provider_scope.kind,
      provider_scope: provider_scope.scope,
      provider_scope_key: provider_scope.key,
      provider_issue_id: nil,
      provider_local_id: issue_id,
      identifier: issue_identifier(provider_scope, tool_name, issue_id),
      url: nil
    }
  end

  defp issue_identifier(provider_scope, "github_issue", issue_id) do
    owner = provider_scope.scope["owner"] || provider_scope.scope[:owner]
    repo = provider_scope.scope["repo"] || provider_scope.scope[:repo]

    if owner && repo do
      "#{owner}/#{repo}##{issue_id}"
    else
      "#{provider_scope.key}:#{issue_id}"
    end
  end

  defp issue_identifier(provider_scope, _tool_name, issue_id), do: "#{provider_scope.key}:#{issue_id}"

  defp operation_kind("github_issue", "upsert_workpad_comment"), do: :comment_workpad_upsert
  defp operation_kind("github_issue", operation) when operation in ["set_status", "add_labels"], do: :stage_writeback
  defp operation_kind("github_pr", "create_pr"), do: :pr_create
  defp operation_kind("github_pr", _operation), do: :pr_lookup
  defp operation_kind("tracker_issue", _operation), do: :stage_writeback
  defp operation_kind(_tool_name, _operation), do: :dynamic_tool_provider_call

  defp replay_policy("github_issue", "upsert_workpad_comment"), do: :marker_upsert
  defp replay_policy("github_issue", operation) when operation in ["get_issue", "list_comments", "set_status", "add_labels"], do: :idempotent
  defp replay_policy("github_pr", "create_pr"), do: :unknown_requires_manual_attention
  defp replay_policy("github_pr", _operation), do: :idempotent
  defp replay_policy("tracker_issue", "set_status"), do: :idempotent
  defp replay_policy("tracker_issue", "create_comment"), do: :unknown_requires_manual_attention
  defp replay_policy(_tool_name, _operation), do: :unknown_requires_manual_attention

  defp logical_key(project_id, provider_scope, issue_ref, tool_name, operation, target) do
    target_key = target_key(tool_name, operation, target)

    case writeback_intent(issue_ref, tool_name, operation, target) do
      %{intent_key: intent_key} -> intent_key
      nil -> Enum.join([project_id, provider_scope.key, tool_name, operation, target_key], ":")
    end
  end

  defp writeback_intent(nil, _tool_name, _operation, _target), do: nil

  defp writeback_intent(issue_ref, tool_name, operation, target) do
    case Map.get(@writeback_operations, {tool_name, operation}) do
      nil ->
        nil

      logical_action ->
        logical_action_key = logical_action_key(logical_action, target)

        %{
          intent_key: RuntimeLedger.writeback_intent_key(issue_ref, logical_action_key),
          logical_action: Atom.to_string(logical_action),
          operation_type: operation_type(tool_name, operation),
          target: safe_target_summary(tool_name, operation, target),
          provider_marker: provider_marker(logical_action, target),
          replay_policy: ledger_replay_policy(tool_name, operation)
        }
    end
  end

  defp logical_action_key(:workpad_upsert, target), do: "workpad_upsert:" <> stable_fragment(target[:header] || "## Codex Workpad")
  defp logical_action_key(:status_set, target), do: "status_set:" <> stable_fragment(target[:state])
  defp logical_action_key(:label_add, target), do: "label_add:" <> stable_fragment(Enum.join(target[:labels] || [], ","))
  defp logical_action_key(:pr_create, target), do: "pr_create:" <> stable_fragment("#{target[:head_ref_name]}:#{target[:base_ref_name]}")
  defp logical_action_key(:comment_append, target), do: "comment_append:" <> stable_fragment(target[:body])
  defp logical_action_key(action, target), do: Atom.to_string(action) <> ":" <> stable_fragment(inspect(target))

  defp operation_type("github_pr", "create_pr"), do: "pull_request_create"
  defp operation_type(_tool_name, "set_status"), do: "status_set"
  defp operation_type(_tool_name, "upsert_workpad_comment"), do: "comment_upsert"
  defp operation_type(_tool_name, "create_comment"), do: "comment_append"
  defp operation_type(_tool_name, "add_labels"), do: "label_add"
  defp operation_type(tool_name, operation), do: tool_name <> ":" <> operation

  defp ledger_replay_policy(tool_name, operation) do
    case replay_policy(tool_name, operation) do
      policy when policy in [:idempotent, :marker_upsert] -> :idempotent
      _policy -> :non_idempotent
    end
  end

  defp provider_marker(:workpad_upsert, target), do: to_string(target[:header] || "## Codex Workpad")
  defp provider_marker(:status_set, target), do: "state:" <> to_string(target[:state])
  defp provider_marker(:pr_create, target), do: "head:" <> to_string(target[:head_ref_name])
  defp provider_marker(_logical_action, _target), do: nil

  defp target_key("github_pr", "list_for_head", target), do: "head:" <> stable_fragment(target[:head_ref_name])
  defp target_key("github_pr", "create_pr", target), do: "head:" <> stable_fragment("#{target[:head_ref_name]}:#{target[:base_ref_name]}")
  defp target_key("github_pr", _operation, target), do: "pr:" <> stable_fragment(target[:pr_number])
  defp target_key(_tool_name, _operation, target), do: "target:" <> stable_fragment(inspect(safe_target_summary("", "", target)))

  defp correlation(context, tool_name, operation, target) do
    run_context = value(context, :run_context) || %{}
    context_correlation = value(context, :correlation) || %{}

    %{
      correlation_id: optional_string(run_context, :correlation_id) || optional_string(context, :correlation_id),
      attempt_id: optional_string(run_context, :attempt_id) || optional_string(context, :attempt_id),
      attempt_number: value(run_context, :attempt_number) || value(context, :attempt_number),
      session_id: optional_string(run_context, :session_id) || optional_string(context, :session_id),
      current_stage: optional_string(run_context, :current_stage) || optional_string(context, :current_stage),
      workspace_lease_id:
        optional_string(run_context, :workspace_lease_id) ||
          optional_string(context, :workspace_lease_id),
      tool_name: tool_name,
      tool_operation: operation,
      tool_call_id: optional_string(context, :tool_call_id),
      target: safe_target_summary(tool_name, operation, target)
    }
    |> Map.merge(sanitize_map(context_correlation))
    |> sanitize_map()
  end

  defp safe_tool_call(tool_name, operation, target) do
    %{
      tool_name: tool_name,
      operation: operation,
      target: safe_target_summary(tool_name, operation, target)
    }
  end

  defp safe_target_summary("github_issue", _operation, target) do
    %{}
    |> maybe_put(:issue_id, target[:issue_id])
    |> maybe_put(:header, target[:header])
    |> maybe_put(:state, target[:state])
    |> maybe_put(:labels, target[:labels])
    |> maybe_put(:body_sha256, body_hash(target[:body]))
    |> maybe_put(:body_bytes, byte_size_or_nil(target[:body]))
  end

  defp safe_target_summary("tracker_issue", _operation, target) do
    %{}
    |> maybe_put(:issue_id, target[:issue_id])
    |> maybe_put(:state, target[:state])
    |> maybe_put(:body_sha256, body_hash(target[:body]))
    |> maybe_put(:body_bytes, byte_size_or_nil(target[:body]))
  end

  defp safe_target_summary("github_pr", "create_pr", target) do
    %{}
    |> maybe_put(:head_ref_name, target[:head_ref_name])
    |> maybe_put(:base_ref_name, target[:base_ref_name])
    |> maybe_put(:title, target[:title])
    |> maybe_put(:draft, target[:draft])
    |> maybe_put(:body_sha256, body_hash(target[:body]))
    |> maybe_put(:body_bytes, byte_size_or_nil(target[:body]))
  end

  defp safe_target_summary("github_pr", "list_for_head", target), do: %{head_ref_name: target[:head_ref_name]}
  defp safe_target_summary("github_pr", _operation, target), do: %{pr_number: target[:pr_number]}

  defp safe_target_summary(_tool_name, _operation, target) do
    target
    |> Map.drop([:body])
    |> sanitize_map()
  end

  defp body_hash(nil), do: nil

  defp body_hash(body) when is_binary(body) do
    :crypto.hash(:sha256, body)
    |> Base.encode16(case: :lower)
  end

  defp body_hash(_body), do: nil

  defp byte_size_or_nil(value) when is_binary(value), do: byte_size(value)
  defp byte_size_or_nil(_value), do: nil

  defp stable_fragment(nil), do: "none"

  defp stable_fragment(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp required_string(map, key) do
    case optional_string(map, key) do
      nil -> {:error, {:missing_required_string, key}}
      value -> {:ok, value}
    end
  end

  defp optional_string(map, key) when is_map(map), do: map |> value(key) |> optional_string()
  defp optional_string(_map, _key), do: nil

  defp optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(nil), do: nil
  defp optional_string(value) when is_boolean(value), do: nil
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp string_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp nested_string_value(map, keys) do
    Enum.reduce_while(keys, map, fn key, current ->
      if is_map(current) do
        {:cont, string_value(current, key)}
      else
        {:halt, nil}
      end
    end)
    |> optional_string()
  end

  defp count_value(map, key) when is_map(map) do
    case string_value(map, key) do
      value when is_list(value) -> length(value)
      _value -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

  defp sensitive_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.contains?(["token", "secret", "credential", "cookie", "prompt", "transcript", "authorization", "api_key", "raw_config"])
  end

  defp sensitive_value?(value) when is_binary(value) do
    Regex.match?(~r/\$[A-Z0-9_]*(TOKEN|API_KEY|SECRET|CREDENTIAL)[A-Z0-9_]*/, value) or
      Regex.match?(~r/\b(api[_-]?key|authorization|bearer|cookie|credential|secret|transcript|full prompt|codex transcript)\b/i, value) or
      Regex.match?(~r/\b(ghp_|github_pat_|glpat-|sk-[A-Za-z0-9])/, value)
  end

  defp sensitive_value?(%_struct{}), do: false
  defp sensitive_value?(value) when is_map(value), do: Enum.any?(value, fn {key, raw_value} -> sensitive_key?(key) or sensitive_value?(raw_value) end)
  defp sensitive_value?(value) when is_list(value), do: Enum.any?(value, &sensitive_value?/1)
  defp sensitive_value?(_value), do: false

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, raw_value} -> {to_string(key), stringify_keys(raw_value)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(nil), do: nil
  defp stringify_keys(value) when is_boolean(value), do: value
  defp stringify_keys(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_keys(value), do: value

  defp normalize_output_key(key) when is_atom(key), do: key

  defp normalize_output_key(key) when is_binary(key) do
    if Regex.match?(~r/\A[a-z_][a-zA-Z0-9_]*\z/, key) do
      String.to_atom(key)
    else
      key
    end
  end

  defp normalize_output_key(key), do: key

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp value(_map, _key), do: nil

  defp truthy?(value), do: value in [true, "true", "1", 1]
end