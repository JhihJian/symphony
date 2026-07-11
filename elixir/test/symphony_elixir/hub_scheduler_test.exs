defmodule SymphonyElixir.HubSchedulerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Hub.{RuntimeLedger, Scheduler}

  @now ~U[2026-07-11 09:00:00Z]
  @opts [realtime_delay_ms: 1_000, invalid_retry_delay_ms: 30_000, default_delay_ms: 30_000]

  test "uses the earliest valid retry due_at instead of one-second reconciliation" do
    decision = Scheduler.next_schedule(plan(DateTime.add(@now, 120, :second)), retry_ledger("2026-07-11T09:01:00Z"), @now, @opts)

    assert decision.reason == "retry_due"
    assert decision.delay_ms == 60_000
    assert decision.earliest_retry_due_at == ~U[2026-07-11 09:01:00Z]
    assert decision.invalid_retry_count == 0
    assert decision.realtime_count == 0
  end

  test "isolates malformed retries behind bounded error backoff" do
    decision = Scheduler.next_schedule(plan(DateTime.add(@now, 120, :second)), retry_ledger("not-a-datetime"), @now, @opts)

    assert decision.reason == "invalid_retry_backoff"
    assert decision.delay_ms == 30_000
    assert decision.earliest_retry_due_at == nil
    assert decision.invalid_retry_count == 1

    missing = Scheduler.next_schedule(plan(DateTime.add(@now, 120, :second)), retry_ledger(nil), @now, @opts)
    assert missing.reason == "invalid_retry_backoff"
    assert missing.invalid_retry_count == 1
  end

  test "only active attempts and pending start intents use short reconciliation" do
    active = Scheduler.next_schedule(plan(DateTime.add(@now, 120, :second)), active_ledger(), @now, @opts)
    manual = Scheduler.next_schedule(paused_plan(), manual_attention_ledger(), @now, @opts)

    assert active.reason == "runtime_reconciliation"
    assert active.delay_ms == 1_000
    assert active.realtime_count == 2

    assert manual.reason == "default_interval"
    assert manual.delay_ms == 30_000
    assert manual.realtime_count == 0
  end

  test "chooses an earlier project poll before a later retry" do
    decision = Scheduler.next_schedule(plan(DateTime.add(@now, 15, :second)), retry_ledger("2026-07-11T09:01:00Z"), @now, @opts)

    assert decision.reason == "next_project_due"
    assert decision.delay_ms == 15_000
  end

  test "normalizes string-key plans and safely defaults malformed project lists" do
    string_plan = %{
      "projects" => [
        %{
          "allow_poll" => false,
          "eligibility" => %{"reason" => "not_due"},
          "next_due_at" => DateTime.add(@now, 5, :second)
        }
      ]
    }

    manual_ledger = manual_attention_ledger()
    string_decision = Scheduler.next_schedule(string_plan, manual_attention_ledger(), @now, @opts)
    malformed_decision = Scheduler.next_schedule(%{projects: :invalid}, manual_ledger, @now, @opts)
    missing_eligibility = Scheduler.next_schedule(%{projects: [%{allow_poll: false}]}, manual_ledger, @now, @opts)

    invalid_eligibility =
      Scheduler.next_schedule(
        %{projects: [%{allow_poll: false, eligibility: %{reason: 123}}]},
        manual_ledger,
        @now,
        @opts
      )

    assert string_decision.reason == "next_project_due"
    assert string_decision.delay_ms == 5_000
    assert malformed_decision.reason == "default_interval"
    assert missing_eligibility.reason == "default_interval"
    assert invalid_eligibility.reason == "default_interval"
  end

  defp plan(next_due_at) do
    %{
      projects: [
        %{
          project_id: "alpha",
          allow_poll: false,
          eligibility: %{reason: :not_due},
          next_due_at: next_due_at,
          backoff_until: nil
        }
      ]
    }
  end

  defp paused_plan do
    %{
      projects: [
        %{project_id: "alpha", allow_poll: false, eligibility: %{reason: :paused}, next_due_at: nil, backoff_until: nil}
      ]
    }
  end

  defp retry_ledger(due_at) do
    ledger_with_issue(%{
      claim_status: :retry_queued,
      attempts: [%{attempt_id: "attempt-1", attempt_number: 1, status: :failed}],
      retry_backoff: %{attempt_id: "attempt-1", due_at: due_at, error_summary: "worker start failed"}
    })
  end

  defp active_ledger do
    ledger_with_issue(%{
      claim_status: :running,
      attempts: [%{attempt_id: "attempt-1", attempt_number: 1, status: :running, workspace_path: "/tmp/alpha"}],
      retry_backoff: nil
    })
    |> Map.update!(:projects, fn [project] ->
      [
        %{
          project
          | workspace_leases: [
              %{lease_id: "lease-1", issue_key: issue_key(), attempt_id: "attempt-1", workspace_path: "/tmp/alpha", status: :active}
            ],
            start_intents: [
              %{intent_id: "intent-1", issue_key: issue_key(), attempt_id: "attempt-1", status: :pending, workspace_path: "/tmp/alpha"}
            ]
        }
      ]
    end)
    |> RuntimeLedger.to_snapshot()
  end

  defp manual_attention_ledger do
    ledger_with_issue(%{claim_status: :manual_attention, attempts: [], retry_backoff: nil})
  end

  defp ledger_with_issue(attrs) do
    RuntimeLedger.to_snapshot(%{
      version: 1,
      projects: [
        %{
          project_id: "alpha",
          issues: [
            Map.merge(
              %{
                issue_key: issue_key(),
                issue_ref: %{
                  project_id: "alpha",
                  tracker_kind: "memory",
                  provider_scope_key: "memory:alpha",
                  provider_issue_id: "1",
                  identifier: "ALPHA-1"
                },
                lifecycle_results: [],
                writebacks: []
              },
              attrs
            )
          ],
          workspace_leases: [],
          start_intents: []
        }
      ]
    })
  end

  defp issue_key, do: "alpha:memory:alpha:1"
end
