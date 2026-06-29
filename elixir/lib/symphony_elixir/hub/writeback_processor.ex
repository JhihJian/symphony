defmodule SymphonyElixir.Hub.WritebackProcessor do
  @moduledoc """
  Model-only Hub writeback intent/result processor.

  This module normalizes provider tool routing summaries into runtime ledger
  writeback facts and derives replay/manual-attention decisions from a ledger
  snapshot. It does not perform provider I/O, persist a database, or replace the
  legacy direct provider path.
  """

  alias SymphonyElixir.Hub.RuntimeLedger

  @writeback_conflict_codes [:writeback_intent_conflict, :writeback_intent_key_unstable]
  @retryable_provider_statuses ["retryable_failure", "rate_limited", "circuit_open", "timed_out"]
  @non_replayable_provider_policies ["non_replayable", "unknown_requires_manual_attention"]
  @idempotent_provider_policies ["idempotent", "marker_upsert"]

  @sensitive_keys [
    "api_key",
    "apikey",
    "authorization",
    "cookie",
    "credential",
    "credentials",
    "full_prompt",
    "prompt",
    "raw_config",
    "secret",
    "secret_env",
    "secret_envs",
    "token",
    "transcript"
  ]
  @sensitive_value_patterns [
    ~r/\$[A-Z0-9_]*(TOKEN|API_KEY|SECRET|CREDENTIAL)[A-Z0-9_]*/,
    ~r/\b(api[_-]?key|authorization|bearer|cookie|credential|secret|token|transcript|full prompt|codex transcript)\b/i,
    ~r/\b(ghp_|github_pat_|glpat-|sk-[A-Za-z0-9])/
  ]
  @body_keys ["body", "comment_body", "pull_request_body", "pr_body", "raw_body"]

  @type normalized_fact :: %{
          required(:project_id) => String.t(),
          required(:issue_key) => String.t(),
          required(:issue_ref) => map(),
          required(:writeback) => map(),
          required(:correlation) => map()
        }

  @type diagnostic :: %{
          required(:level) => :error | :warning,
          required(:code) => atom(),
          required(:message) => String.t()
        }

  @type decision :: %{
          required(:decision) => atom(),
          required(:action) => atom(),
          required(:project_id) => String.t(),
          required(:issue_key) => String.t(),
          required(:intent_key) => String.t(),
          required(:replayable) => boolean(),
          required(:manual_attention) => boolean(),
          required(:reason) => atom() | nil,
          required(:target) => map(),
          required(:attempt_id) => String.t() | nil,
          required(:diagnostics) => [diagnostic()]
        }

  @spec normalize(map(), keyword()) :: {:ok, normalized_fact()} | {:error, [diagnostic()]}
  def normalize(input, opts \\ []) when is_map(input) and is_list(opts) do
    summary = governance_summary(input)
    request = map_value(summary, :request)
    result = map_value(summary, :result)

    intent =
      map_value(summary, :writeback_intent) ||
        map_value(summary, :writebackIntent) ||
        map_value(input, :writeback)

    opts_map = Map.new(opts)

    with {:ok, issue_ref} <- normalize_issue_ref(request, opts_map),
         {:ok, project_id} <- project_id(request, issue_ref, opts_map),
         :ok <- validate_issue_ref_project(issue_ref, project_id),
         issue_ref <- Map.put(issue_ref, :project_id, project_id),
         {:ok, issue_key} <- issue_key(request, result, issue_ref, opts_map),
         {:ok, intent_key} <- intent_key(intent, result, opts_map),
         {:ok, logical_action} <- logical_action(intent, opts_map) do
      target = target_summary(intent, result, summary)
      replay_policy = replay_policy(intent, request, opts_map)
      result_status = result_status(intent, result, opts_map)
      provider_result_status = provider_result_status(result, opts_map)
      provider_replayable = provider_replayable(result)
      manual_attention_reason = manual_attention_reason(logical_action, target, replay_policy, result_status, result)
      correlation = correlation_summary(request, result, opts_map)

      writeback = %{
        intent_key: intent_key,
        logical_action: logical_action,
        operation_type: operation_type(intent, request, opts_map),
        target: target,
        replay_policy: replay_policy,
        result_status: result_status,
        attempt_id: attempt_id(correlation, opts_map),
        provider_marker: optional_string(intent, :provider_marker),
        external_ref: external_ref(intent, result, opts_map),
        error_summary: error_summary(result, opts_map),
        provider_result_status: provider_result_status,
        provider_replayable: provider_replayable,
        manual_attention: manual_attention_reason != nil,
        manual_attention_reason: manual_attention_reason && Atom.to_string(manual_attention_reason),
        correlation: correlation
      }

      {:ok,
       %{
         project_id: project_id,
         issue_key: issue_key,
         issue_ref: issue_ref,
         writeback: writeback,
         correlation: correlation
       }}
    else
      {:error, diagnostic} -> {:error, [diagnostic]}
    end
  end

  @spec apply_fact(map(), map(), keyword()) :: {:ok, map()} | {:error, [diagnostic()]}
  def apply_fact(ledger, input, opts \\ []) when is_map(ledger) and is_map(input) and is_list(opts) do
    with {:ok, normalized} <- normalize_input(input, opts) do
      {:ok, ledger |> RuntimeLedger.to_snapshot() |> upsert_writeback(normalized) |> RuntimeLedger.to_snapshot()}
    end
  end

  @spec decide(map(), map(), keyword()) :: {:ok, decision()} | {:error, [diagnostic()]}
  def decide(ledger, input, opts \\ []) when is_map(ledger) and is_map(input) and is_list(opts) do
    with {:ok, normalized} <- normalize_input(input, opts),
         candidate_ledger <-
           ledger
           |> RuntimeLedger.to_snapshot()
           |> upsert_writeback(normalized)
           |> RuntimeLedger.to_snapshot() do
      conflicts = writeback_conflicts(candidate_ledger, normalized)

      decision =
        if conflicts == [] do
          ledger |> RuntimeLedger.to_snapshot() |> writeback_decision(normalized)
        else
          base_decision(normalized, :conflict, :blocked_conflict, false, true, :writeback_conflict)
          |> Map.put(:diagnostics, conflicts)
        end

      {:ok, decision}
    end
  end

  defp governance_summary(input) do
    cond do
      is_map(map_value(input, :providerGovernance)) ->
        map_value(input, :providerGovernance)

      is_map(map_value(input, :provider_governance)) ->
        map_value(input, :provider_governance)

      true ->
        input
    end
  end

  defp normalize_issue_ref(request, opts) do
    issue_ref = map_value(request, :issue_ref) || map_value(opts, :issue_ref)

    if is_map(issue_ref) do
      {:ok,
       %{
         project_id: optional_string(issue_ref, :project_id),
         tracker_kind: optional_string(issue_ref, :tracker_kind),
         provider_scope: sanitize_scope(map_value(issue_ref, :provider_scope) || %{}),
         provider_scope_key: optional_string(issue_ref, :provider_scope_key),
         provider_issue_id: optional_string(issue_ref, :provider_issue_id),
         provider_local_id: optional_string(issue_ref, :provider_local_id),
         identifier: optional_string(issue_ref, :identifier),
         url: optional_string(issue_ref, :url)
       }}
    else
      {:error, diagnostic(:error, :writeback_missing_issue_ref, "Writeback summary must include an IssueRef")}
    end
  end

  defp project_id(request, issue_ref, opts) do
    project_id =
      optional_string(request, :project_id) ||
        optional_string(issue_ref, :project_id) ||
        optional_string(opts, :project_id)

    case project_id do
      nil -> {:error, diagnostic(:error, :writeback_missing_project_id, "Writeback summary must include project_id")}
      value -> {:ok, value}
    end
  end

  defp validate_issue_ref_project(issue_ref, project_id) do
    cond do
      blank?(issue_ref.provider_scope_key) ->
        {:error, diagnostic(:error, :writeback_missing_provider_scope, "Writeback IssueRef must include provider_scope_key")}

      blank?(issue_ref.provider_issue_id) and blank?(issue_ref.provider_local_id) and blank?(issue_ref.identifier) ->
        {:error, diagnostic(:error, :writeback_missing_provider_issue_identity, "Writeback IssueRef must include provider issue identity")}

      issue_ref.project_id not in [nil, project_id] ->
        {:error, diagnostic(:error, :writeback_project_mismatch, "Writeback IssueRef project_id must match project_id")}

      true ->
        :ok
    end
  end

  defp issue_key(request, result, issue_ref, opts) do
    result_ledger = map_value(result, :ledger)

    key =
      optional_string(result_ledger, :issue_key) ||
        optional_string(request, :issue_key) ||
        optional_string(opts, :issue_key) ||
        RuntimeLedger.issue_key(issue_ref)

    if blank?(key) do
      {:error, diagnostic(:error, :writeback_missing_issue_key, "Writeback summary must resolve an issue key")}
    else
      {:ok, key}
    end
  end

  defp intent_key(intent, result, opts) do
    result_ledger = map_value(result, :ledger)

    case optional_string(intent, :intent_key) ||
           optional_string(result_ledger, :writeback_intent_key) ||
           optional_string(opts, :intent_key) do
      nil -> {:error, diagnostic(:error, :writeback_missing_intent_key, "Writeback summary must include a stable intent key")}
      value -> {:ok, value}
    end
  end

  defp logical_action(intent, opts) do
    case optional_string(intent, :logical_action) || optional_string(opts, :logical_action) do
      nil -> {:error, diagnostic(:error, :writeback_missing_logical_action, "Writeback summary must include logical_action")}
      value -> {:ok, value}
    end
  end

  defp operation_type(intent, request, opts) do
    optional_string(intent, :operation_type) ||
      optional_string(request, :operation_kind) ||
      optional_string(opts, :operation_type)
  end

  defp target_summary(intent, result, summary) do
    result_summary = map_value(result, :result_summary)
    tool_call = map_value(summary, :tool_call)

    (map_value(intent, :target) || map_value(result_summary, :target) || map_value(tool_call, :target) || %{})
    |> sanitize_target()
  end

  defp replay_policy(intent, request, opts) do
    policy =
      optional_string(intent, :replay_policy) ||
        optional_string(opts, :replay_policy) ||
        optional_string(request, :replay_policy)

    cond do
      policy in @idempotent_provider_policies -> :idempotent
      policy in @non_replayable_provider_policies -> :non_idempotent
      policy == "non_idempotent" -> :non_idempotent
      true -> :idempotent
    end
  end

  defp result_status(intent, result, opts) do
    status =
      optional_string(intent, :result_status) ||
        optional_string(opts, :result_status) ||
        provider_result_status(result, opts)

    case status do
      status when status in ["success", "succeeded"] -> :succeeded
      status when status in ["unknown", "unknown_result"] -> :unknown
      status when status in ["pending", "queued", "running"] -> :pending
      nil -> :pending
      _status -> :failed
    end
  end

  defp provider_result_status(result, opts) do
    optional_string(result, :status) ||
      optional_string(opts, :provider_result_status)
  end

  defp provider_replayable(result) do
    value = value(result, :replayable)
    value in [true, "true", "1", 1]
  end

  defp manual_attention_reason(logical_action, target, replay_policy, :unknown, result) do
    cond do
      logical_action == "pr_create" or operation_target_pr_create?(target) ->
        :unknown_pr_create_requires_provider_lookup

      logical_action == "comment_append" ->
        :unknown_append_comment_requires_manual_attention

      replay_policy == :non_idempotent ->
        :unknown_non_idempotent_writeback

      truthy?(value(result, :manual_attention)) ->
        :provider_result_requires_manual_attention

      true ->
        nil
    end
  end

  defp manual_attention_reason(_logical_action, _target, _replay_policy, _status, result) do
    if truthy?(value(result, :manual_attention)), do: :provider_result_requires_manual_attention
  end

  defp operation_target_pr_create?(target), do: Map.has_key?(target, "head_ref_name") and Map.has_key?(target, "base_ref_name")

  defp correlation_summary(request, result, opts) do
    correlation = map_value(request, :correlation) || %{}

    %{}
    |> maybe_put("request_id", optional_string(request, :request_id))
    |> maybe_put("logical_key", optional_string(request, :logical_key))
    |> maybe_put("operation_kind", optional_string(request, :operation_kind))
    |> Map.merge(safe_correlation(correlation))
    |> maybe_put("attempt_id", optional_string(opts, :attempt_id))
    |> maybe_put("correlation_id", optional_string(opts, :correlation_id))
    |> maybe_put("result_manual_attention", value(result, :manual_attention))
    |> sanitize_map()
  end

  defp safe_correlation(correlation) when is_map(correlation) do
    allowed = [
      :attempt_id,
      :attempt_number,
      :correlation_id,
      :current_stage,
      :session_id,
      :tool_call_id,
      :tool_name,
      :tool_operation,
      :worker_host,
      :workspace_lease_id
    ]

    Map.new(allowed, fn key -> {to_string(key), value(correlation, key)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> sanitize_map()
  end

  defp safe_correlation(_correlation), do: %{}

  defp attempt_id(correlation, opts), do: optional_string(correlation, :attempt_id) || optional_string(opts, :attempt_id)

  defp external_ref(intent, result, opts) do
    optional_string(intent, :external_ref) ||
      optional_string(result, :external_ref) ||
      optional_string(opts, :external_ref)
  end

  defp error_summary(result, opts) do
    optional_string(opts, :error_summary) ||
      optional_string(result, :error_class) ||
      map_value(result, :result_summary) |> optional_string(:message)
  end

  defp upsert_writeback(ledger, normalized) do
    project =
      ledger.projects
      |> Enum.find(&(&1.project_id == normalized.project_id))
      |> Kernel.||(%{
        project_id: normalized.project_id,
        config_fingerprint: nil,
        snapshot_version: nil,
        issues: [],
        workspace_leases: [],
        start_intents: []
      })

    issue =
      project.issues
      |> Enum.find(&(&1.issue_key == normalized.issue_key))
      |> Kernel.||(%{
        issue_key: normalized.issue_key,
        issue_ref: normalized.issue_ref,
        claim_status: :unclaimed,
        current_stage: nil,
        claimed_at: nil,
        released_at: nil,
        terminal_reason: nil,
        attempts: [],
        retry_backoff: nil,
        writebacks: []
      })
      |> Map.put(:issue_ref, normalized.issue_ref)
      |> Map.update!(:writebacks, &(&1 ++ [normalized.writeback]))

    project = Map.put(project, :issues, [issue | Enum.reject(project.issues, &(&1.issue_key == normalized.issue_key))])
    Map.put(ledger, :projects, [project | Enum.reject(ledger.projects, &(&1.project_id == normalized.project_id))])
  end

  defp writeback_conflicts(ledger, normalized) do
    case RuntimeLedger.validate(ledger) do
      :ok ->
        []

      {:error, diagnostics} ->
        Enum.filter(diagnostics, fn diagnostic ->
          diagnostic.code in @writeback_conflict_codes and
            diagnostic.project_id == normalized.project_id and
            diagnostic.issue_key == normalized.issue_key
        end)
    end
  end

  defp writeback_decision(ledger, normalized) do
    history = existing_writebacks(ledger, normalized)
    all_facts = history ++ [normalized.writeback]

    cond do
      Enum.any?(all_facts, &(&1.result_status == :succeeded)) ->
        base_decision(normalized, :completed, :reuse_completed_result, false, false, :already_succeeded)

      unknown = Enum.find(all_facts, &(&1.result_status == :unknown)) ->
        unknown_decision(normalized, unknown)

      retryable_failure?(all_facts) ->
        retryable_failure_decision(normalized, all_facts)

      normalized.writeback.result_status == :pending and history == [] ->
        base_decision(normalized, :pending, :execute_once, true, false, :pending_first_execution)

      normalized.writeback.result_status == :pending and replay_allowed?(normalized.writeback) ->
        base_decision(normalized, :retry, :retry_writeback, true, false, :pending_retry_allowed)

      normalized.writeback.result_status == :failed ->
        base_decision(normalized, :failed, :do_not_retry, false, false, :terminal_provider_failure)

      true ->
        base_decision(normalized, :manual_attention, :manual_attention, false, true, :pending_non_replayable_writeback)
    end
  end

  defp unknown_decision(normalized, writeback) do
    reason =
      cond do
        writeback.logical_action == "pr_create" ->
          :unknown_pr_create_requires_provider_lookup

        writeback.logical_action == "comment_append" ->
          :unknown_append_comment_requires_manual_attention

        writeback.replay_policy == :non_idempotent ->
          :unknown_non_idempotent_writeback

        replay_allowed?(writeback) ->
          :unknown_idempotent_retry_allowed

        true ->
          :unknown_writeback_requires_manual_attention
      end

    if reason == :unknown_idempotent_retry_allowed do
      base_decision(normalized, :retry, :retry_writeback, true, false, reason)
    else
      normalized
      |> base_decision(:manual_attention, :manual_attention, false, true, reason)
      |> Map.put(:provider_lookup, provider_lookup_hint(writeback))
    end
  end

  defp retryable_failure_decision(normalized, facts) do
    if Enum.any?(facts, &replay_allowed?/1) do
      base_decision(normalized, :retry, :retry_writeback, true, false, :retryable_failure_allowed)
    else
      base_decision(normalized, :manual_attention, :manual_attention, false, true, :retryable_failure_not_replayable)
    end
  end

  defp retryable_failure?(facts) do
    Enum.any?(facts, fn fact ->
      fact.result_status == :failed and
        (fact.provider_result_status in @retryable_provider_statuses or fact.provider_replayable)
    end)
  end

  defp replay_allowed?(writeback), do: writeback.replay_policy == :idempotent or writeback.provider_replayable == true

  defp existing_writebacks(ledger, normalized) do
    ledger.projects
    |> Enum.find_value([], fn project ->
      if project.project_id == normalized.project_id do
        project.issues
        |> Enum.find_value([], fn issue ->
          if issue.issue_key == normalized.issue_key do
            Enum.filter(issue.writebacks, &(&1.intent_key == normalized.writeback.intent_key))
          end
        end)
      end
    end)
  end

  defp provider_lookup_hint(%{logical_action: "pr_create", target: target}) do
    %{
      operation: "pr_lookup_by_head",
      target: Map.take(target, ["head_ref_name", "base_ref_name"])
    }
  end

  defp provider_lookup_hint(_writeback), do: nil

  defp normalize_input(%{project_id: _project_id, issue_key: _issue_key, issue_ref: _issue_ref, writeback: writeback} = normalized, _opts)
       when is_map(writeback),
       do: {:ok, normalized}

  defp normalize_input(input, opts), do: normalize(input, opts)

  defp base_decision(normalized, decision, action, replayable, manual_attention, reason) do
    %{
      decision: decision,
      action: action,
      project_id: normalized.project_id,
      issue_key: normalized.issue_key,
      intent_key: normalized.writeback.intent_key,
      replayable: replayable,
      manual_attention: manual_attention,
      reason: reason,
      target: normalized.writeback.target,
      attempt_id: normalized.writeback.attempt_id,
      diagnostics: []
    }
  end

  defp sanitize_scope(value) when is_map(value), do: sanitize_map(value)
  defp sanitize_scope(_value), do: %{}

  defp sanitize_target(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, target ->
      key = normalize_key(key)

      cond do
        body_key?(key) ->
          target
          |> maybe_put("#{key}_sha256", body_hash(raw_value))
          |> maybe_put("#{key}_bytes", byte_size_or_nil(raw_value))

        sensitive_key?(key) or sensitive_value?(raw_value) ->
          target

        true ->
          Map.put(target, key, sanitize_value(raw_value))
      end
    end)
  end

  defp sanitize_target(_value), do: %{}

  defp sanitize_map(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, raw_value} -> sensitive_key?(key) or sensitive_value?(raw_value) end)
    |> Map.new(fn {key, raw_value} -> {normalize_key(key), sanitize_value(raw_value)} end)
  end

  defp sanitize_map(_value), do: %{}

  defp sanitize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp sanitize_value(%_struct{} = value), do: inspect(value)
  defp sanitize_value(value) when is_map(value), do: sanitize_map(value)
  defp sanitize_value(value) when is_list(value), do: value |> Enum.reject(&sensitive_value?/1) |> Enum.map(&sanitize_value/1)
  defp sanitize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_value(value), do: value

  defp body_key?(key), do: key in @body_keys or String.ends_with?(key, "_body")

  defp body_hash(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp body_hash(_value), do: nil

  defp byte_size_or_nil(value) when is_binary(value), do: byte_size(value)
  defp byte_size_or_nil(_value), do: nil

  defp map_value(map, key) when is_map(map) do
    case value(map, key) do
      value when is_map(value) -> value
      _value -> nil
    end
  end

  defp map_value(_map, _key), do: nil

  defp optional_string(map, key) when is_map(map), do: map |> value(key) |> optional_string()
  defp optional_string(_map, _key), do: nil

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

  defp value(map, key) when is_map(map) do
    Map.get(map, key) ||
      Map.get(map, Atom.to_string(key)) ||
      Map.get(map, camelize_key(key))
  end

  defp value(_map, _key), do: nil

  defp camelize_key(key) when is_atom(key), do: key |> Atom.to_string() |> camelize_key()

  defp camelize_key(key) when is_binary(key) do
    case String.split(key, "_") do
      [first | rest] -> first <> Enum.map_join(rest, "", &String.capitalize/1)
      [] -> key
    end
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp truthy?(value), do: value in [true, "true", "1", 1]
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp sensitive_key?(key) do
    key = key |> to_string() |> String.downcase()

    key in @sensitive_keys or
      String.contains?(key, ["token", "secret", "credential", "cookie", "prompt", "transcript", "authorization", "raw_config"])
  end

  defp sensitive_value?(value) when is_binary(value) do
    Enum.any?(@sensitive_value_patterns, &Regex.match?(&1, value))
  end

  defp sensitive_value?(%_struct{}), do: false
  defp sensitive_value?(value) when is_map(value), do: Enum.any?(value, fn {key, raw_value} -> sensitive_key?(key) or sensitive_value?(raw_value) end)
  defp sensitive_value?(value) when is_list(value), do: Enum.any?(value, &sensitive_value?/1)
  defp sensitive_value?(_value), do: false

  defp diagnostic(level, code, message), do: %{level: level, code: code, message: message}
end
