defmodule SymphonyElixir.Hub.Scheduler do
  @moduledoc """
  Pure Hub scheduler timing decisions.

  Real-time worker state uses a short reconciliation interval. Retry records are
  scheduled from their earliest valid `due_at`; malformed records are isolated
  behind a bounded diagnostic backoff instead of forcing a tight loop.
  """

  alias SymphonyElixir.Hub.RuntimeLedger

  @reason_priorities %{
    "poll_due" => 0,
    "retry_due" => 1,
    "runtime_reconciliation" => 2,
    "invalid_retry_backoff" => 3,
    "next_project_due" => 4,
    "default_interval" => 5
  }

  @type decision :: %{
          required(:delay_ms) => non_neg_integer(),
          required(:reason) => String.t(),
          required(:earliest_retry_due_at) => DateTime.t() | nil,
          required(:invalid_retry_count) => non_neg_integer(),
          required(:realtime_count) => non_neg_integer()
        }

  @spec next_schedule(map(), RuntimeLedger.ledger() | map(), DateTime.t(), keyword()) :: decision()
  def next_schedule(plan, runtime_ledger, %DateTime{} = now, opts) when is_map(plan) and is_map(runtime_ledger) do
    realtime_delay_ms = Keyword.fetch!(opts, :realtime_delay_ms)
    invalid_retry_delay_ms = Keyword.fetch!(opts, :invalid_retry_delay_ms)
    default_delay_ms = Keyword.fetch!(opts, :default_delay_ms)
    replay = RuntimeLedger.replay(runtime_ledger)
    realtime_count = realtime_count(replay)
    {earliest_retry_due_at, invalid_retry_count} = retry_schedule(replay)

    candidates =
      []
      |> maybe_add_candidate(due_project?(plan), 0, "poll_due")
      |> maybe_add_datetime_candidate(earliest_retry_due_at, now, "retry_due")
      |> maybe_add_candidate(realtime_count > 0, realtime_delay_ms, "runtime_reconciliation")
      |> maybe_add_candidate(invalid_retry_count > 0, invalid_retry_delay_ms, "invalid_retry_backoff")
      |> add_project_candidate(plan, now, default_delay_ms)

    {delay_ms, reason} = Enum.min_by(candidates, fn {delay_ms, reason} -> {delay_ms, reason_priority(reason)} end)

    %{
      delay_ms: max(delay_ms, 0),
      reason: reason,
      earliest_retry_due_at: earliest_retry_due_at,
      invalid_retry_count: invalid_retry_count,
      realtime_count: realtime_count
    }
  end

  defp realtime_count(replay) do
    Enum.reduce(replay.projects, 0, fn project, count ->
      count + length(list_value(project, :active_attempts)) + length(list_value(project, :pending_start_intents))
    end)
  end

  defp retry_schedule(replay) do
    replay.projects
    |> Enum.flat_map(&list_value(&1, :retry_backoff))
    |> Enum.reduce({[], 0}, fn retry, {due_times, invalid_count} ->
      case parse_datetime(value(retry, :due_at)) do
        %DateTime{} = due_at -> {[due_at | due_times], invalid_count}
        nil -> {due_times, invalid_count + 1}
      end
    end)
    |> then(fn {due_times, invalid_count} ->
      earliest = Enum.min_by(due_times, &DateTime.to_unix(&1, :millisecond), fn -> nil end)
      {earliest, invalid_count}
    end)
  end

  defp due_project?(plan), do: Enum.any?(list_value(plan, :projects), &(value(&1, :allow_poll) == true))

  defp add_project_candidate(candidates, plan, now, default_delay_ms) do
    case earliest_project_due_at(plan, now) do
      nil -> [{default_delay_ms, "default_interval"} | candidates]
      due_at -> [{max(DateTime.diff(due_at, now, :millisecond), 0), "next_project_due"} | candidates]
    end
  end

  defp earliest_project_due_at(plan, now) do
    plan
    |> list_value(:projects)
    |> Enum.filter(&reschedulable_project?/1)
    |> Enum.map(&(value(&1, :backoff_until) || value(&1, :next_due_at)))
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.reject(&(DateTime.compare(&1, now) == :lt))
    |> Enum.min_by(&DateTime.to_unix(&1, :millisecond), fn -> nil end)
  end

  defp reschedulable_project?(project) do
    value(project, :allow_poll) == true or
      status_string(project |> value(:eligibility) |> value(:reason)) in [
        "not_due",
        "backoff",
        "rate_limited",
        "circuit_open",
        "provider_unavailable",
        "scope_concurrency"
      ]
  end

  defp maybe_add_datetime_candidate(candidates, nil, _now, _reason), do: candidates

  defp maybe_add_datetime_candidate(candidates, due_at, now, reason) do
    [{max(DateTime.diff(due_at, now, :millisecond), 0), reason} | candidates]
  end

  defp maybe_add_candidate(candidates, true, delay_ms, reason), do: [{delay_ms, reason} | candidates]
  defp maybe_add_candidate(candidates, false, _delay_ms, _reason), do: candidates

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp status_string(value) when is_atom(value), do: Atom.to_string(value)
  defp status_string(value) when is_binary(value), do: value
  defp status_string(_value), do: nil

  defp reason_priority(reason), do: Map.fetch!(@reason_priorities, reason)

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

  defp value(_map, _key), do: nil
end
