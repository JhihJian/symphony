defmodule SymphonyElixir.Hub.RealCandidateScanExecutor do
  @moduledoc """
  Opt-in Hub provider executor for real candidate scans.

  This executor is intentionally narrow: it only handles governed
  `:candidate_scan` requests. It reloads the matching Hub project from the
  registry snapshot paths, temporarily installs that project's parsed settings
  for the current process, calls the existing tracker read adapter, and returns a
  safe candidate summary for `CandidateIntake`.
  """

  @behaviour SymphonyElixir.Hub.ProviderExecutor

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Adapter, as: GitHubAdapter
  alias SymphonyElixir.GitLab.Adapter, as: GitLabAdapter
  alias SymphonyElixir.Hub.{ProviderGovernance, ProviderScope}
  alias SymphonyElixir.Linear.Adapter, as: LinearAdapter
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker.Memory

  @supported_provider_kinds ["memory", "github", "gitlab", "linear"]

  @spec execute(ProviderGovernance.request(), keyword()) :: ProviderGovernance.result()
  def execute(request, opts \\ []) when is_map(request) and is_list(opts) do
    case request.operation_kind do
      :candidate_scan ->
        execute_candidate_scan(request, opts)

      operation_kind ->
        unsupported_operation(request, operation_kind)
    end
  end

  defp execute_candidate_scan(request, opts) do
    with :ok <- validate_provider_kind(request.provider_kind),
         {:ok, registry} <- registry(opts),
         {:ok, project} <- registry_project(registry, request.project_id),
         :ok <- validate_project_scope(request, project),
         {:ok, settings} <- project_settings(project),
         :ok <- validate_provider_kind(settings.tracker.kind),
         :ok <- validate_settings_scope(request, settings),
         {:ok, issues} <- fetch_candidates(settings) do
      candidates = Enum.map(issues, &candidate_summary(&1, request, settings))

      ProviderGovernance.result(request, :success,
        result_summary: %{
          boundary: "hub_real_candidate_scan_executor",
          executor: "real_candidate_scan",
          provider_io: true,
          issue_count: length(candidates),
          candidate_count: length(candidates),
          provider_kind: request.provider_kind,
          provider_scope_key: request.provider_scope_key,
          candidates: candidates
        }
      )
    else
      {:unsupported_provider, provider_kind} ->
        ProviderGovernance.result(request, :permanent_failure,
          error_class: :validation,
          result_summary: failure_summary(request, :unsupported_provider, provider_kind)
        )

      {:scope_mismatch, reason} ->
        ProviderGovernance.result(request, :permanent_failure,
          error_class: :validation,
          result_summary: failure_summary(request, :scope_mismatch, reason)
        )

      {:project_config_error, reason} ->
        ProviderGovernance.result(request, :permanent_failure,
          error_class: :auth_config,
          result_summary: failure_summary(request, :project_config_error, reason)
        )

      {:provider_error, reason} ->
        provider_failure_result(request, reason)

      {:error, reason} ->
        ProviderGovernance.result(request, :permanent_failure,
          error_class: :validation,
          result_summary: failure_summary(request, :invalid_request, reason)
        )
    end
  end

  defp unsupported_operation(request, operation_kind) do
    ProviderGovernance.result(request, :permanent_failure,
      error_class: :validation,
      result_summary: failure_summary(request, :unsupported_operation, operation_kind)
    )
  end

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

  defp validate_provider_kind(provider_kind) when provider_kind in @supported_provider_kinds, do: :ok
  defp validate_provider_kind(provider_kind), do: {:unsupported_provider, provider_kind}

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

  defp fetch_candidates(settings) do
    result =
      Config.with_settings(settings, fn ->
        case settings.tracker.kind do
          "memory" -> Memory.fetch_candidate_issues()
          "github" -> GitHubAdapter.fetch_candidate_issues()
          "gitlab" -> GitLabAdapter.fetch_candidate_issues()
          "linear" -> LinearAdapter.fetch_candidate_issues()
        end
      end)

    case result do
      {:ok, issues} when is_list(issues) -> {:ok, issues}
      {:error, reason} -> {:provider_error, reason}
      other -> {:provider_error, {:unexpected_provider_result, other}}
    end
  end

  defp candidate_summary(%Issue{} = issue, request, settings) do
    local_id =
      issue.id ||
        issue.identifier ||
        issue.url

    %{
      project_id: request.project_id,
      provider_kind: request.provider_kind,
      provider_scope: request.provider_scope,
      provider_scope_key: request.provider_scope_key,
      provider_issue_id: safe_optional_string(issue.id),
      provider_local_id: safe_optional_string(local_id),
      id: safe_optional_string(issue.id) || safe_optional_string(local_id),
      identifier: safe_optional_string(issue.identifier),
      url: safe_optional_string(issue.url),
      title: safe_optional_string(issue.title),
      current_stage: current_stage(issue, settings)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp candidate_summary(issue, request, _settings) when is_map(issue) do
    local_id = value(issue, :identifier) || value(issue, :number) || value(issue, :iid)
    issue_id = value(issue, :id) || local_id

    %{
      project_id: request.project_id,
      provider_kind: request.provider_kind,
      provider_scope: request.provider_scope,
      provider_scope_key: request.provider_scope_key,
      provider_issue_id: safe_optional_string(value(issue, :id)),
      provider_local_id: safe_optional_string(local_id),
      id: safe_optional_string(issue_id),
      identifier: safe_optional_string(value(issue, :identifier)),
      url: safe_optional_string(value(issue, :url)),
      title: safe_optional_string(value(issue, :title)),
      current_stage: safe_optional_string(value(issue, :current_stage) || value(issue, :state))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp candidate_summary(issue, request, _settings) do
    %{
      project_id: request.project_id,
      provider_kind: request.provider_kind,
      provider_scope: request.provider_scope,
      provider_scope_key: request.provider_scope_key,
      id: "unsupported-candidate-shape",
      identifier: safe_type(issue)
    }
  end

  defp current_stage(%Issue{state: provider_state}, settings) do
    settings.tracker.stage_states
    |> Enum.find_value(fn {stage_id, %{"state" => state}} ->
      if normalize_state(state) == normalize_state(provider_state), do: stage_id
    end)
    |> Kernel.||(settings.workflow |> Map.get("start_stage"))
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
        {:retryable_failure, retryable_error_class(reason), retry_after_ms(reason) || 30_000}

      permanent?(reason) ->
        {:permanent_failure, permanent_error_class(reason), nil}

      true ->
        {:unknown_result, :unknown, 30_000}
    end
  end

  defp maybe_put_backoff(opts, status, retry_after_ms) when status in [:rate_limited, :retryable_failure, :unknown_result] do
    retry_after_ms = retry_after_ms || 30_000
    Keyword.put(opts, :backoff_until, DateTime.utc_now() |> DateTime.add(retry_after_ms, :millisecond))
  end

  defp maybe_put_backoff(opts, _status, _retry_after_ms), do: opts

  defp failure_summary(request, error, reason) do
    %{
      boundary: "hub_real_candidate_scan_executor",
      executor: "real_candidate_scan",
      provider_io: request.operation_kind == :candidate_scan and error == :provider_error,
      provider_kind: request.provider_kind,
      provider_scope_key: request.provider_scope_key,
      error: Atom.to_string(error),
      reason: safe_reason(reason)
    }
  end

  defp rate_limited?(reason) do
    reason_contains?(reason, ["rate_limit", "rate-limited", "rate limited", "abuse"]) or
      status_in?(reason, [429])
  end

  defp retryable?(reason) do
    reason_contains?(reason, ["timeout", "timed out", "econnrefused", "closed", "nxdomain", "network"]) or
      status_in?(reason, [408, 409, 425, 500, 502, 503, 504])
  end

  defp permanent?(reason) do
    reason_contains?(reason, ["missing_", "not_found", "not found", "unauthorized", "forbidden", "invalid", "validation"]) or
      status_in?(reason, [400, 401, 404, 422])
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

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp value(_map, _key), do: nil

  defp optional_string(map, key) when is_map(map), do: safe_optional_string(value(map, key))
  defp optional_string(value, _key), do: safe_optional_string(value)

  defp safe_optional_string(nil), do: nil

  defp safe_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp safe_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_optional_string(_value), do: nil

  defp safe_type(%_struct{} = value), do: value.__struct__ |> inspect() |> safe_reason_text()
  defp safe_type(value) when is_map(value), do: "map"
  defp safe_type(value) when is_list(value), do: "list"
  defp safe_type(value) when is_tuple(value), do: "tuple"
  defp safe_type(value) when is_binary(value), do: "binary"
  defp safe_type(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_type(value) when is_integer(value), do: "integer"
  defp safe_type(value) when is_float(value), do: "float"
  defp safe_type(_value), do: "term"

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil
end
