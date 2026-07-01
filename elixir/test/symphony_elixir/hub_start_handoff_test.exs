defmodule SymphonyElixir.HubStartHandoffTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{
    ActivationPreflight,
    DispatchBoundary,
    IssueRef,
    RealWorkerStarter,
    RuntimeLedger,
    WorkerStartHandoff
  }

  @now ~U[2026-06-29 09:00:00Z]

  setup do
    previous_runner = Application.get_env(:symphony_elixir, :hub_worker_start_runner)
    previous_timeout = Application.get_env(:symphony_elixir, :hub_worker_start_timeout_ms)

    on_exit(fn ->
      restore_app_env(:hub_worker_start_runner, previous_runner)
      restore_app_env(:hub_worker_start_timeout_ms, previous_timeout)
    end)

    :ok
  end

  defmodule ModuleAckRunner do
    @moduledoc false

    def run(issue, request, runtime, recipient) do
      if parent = Map.get(request, :test_recipient) do
        send(parent, {:module_ack_runner, issue, request, runtime})
      end

      send(recipient, {
        :worker_runtime_info,
        issue.id,
        %{
          workspace_path: runtime.workspace_path,
          worker_host: runtime.worker_host
        }
      })

      send(recipient, {
        :codex_worker_update,
        issue.id,
        %{
          event: :session_started,
          codex_app_server_pid: 12_345,
          timestamp: "not-a-datetime"
        }
      })

      Process.sleep(20)
      :ok
    end
  end

  test "acknowledges a pending start intent and links the running attempt in replay" do
    assert {:ok, ledger, context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)

    starter = fn request, _opts ->
      assert request.project_id == "alpha"
      assert request.provider_scope_key == "github:jhihjian/symphony"
      assert request.issue_ref.provider_issue_id == "123"
      assert request.attempt_id == context.attempt_id
      assert request.start_intent_id == context.start_intent_id
      assert request.workspace_lease_id == context.workspace_lease_id
      assert request.source_poll.request_id == "provider-request-alpha"
      assert request.source_intake.candidate_key == context.issue_key
      assert request.planning.intent_id == context.start_intent_id
      assert request.start_command_summary.starts_agent in [false, "false"]

      %{
        status: :ack,
        reason: :starter_acknowledged,
        session_id: "session-alpha",
        worker_host: "worker-ack",
        usage: %{input_tokens: 12, authorization: "Bearer should-not-leak"}
      }
    end

    assert {acked_ledger, handoff} = WorkerStartHandoff.run(registry(), ledger, now: @now, starter: starter)

    assert handoff.counts.selected_count == 1
    assert handoff.counts.acked_count == 1
    assert handoff.counts.unresolved_start_intent_count == 0
    assert handoff.reason_counts == %{"starter_acknowledged" => 1}
    assert handoff.worker_lifecycle.counts.acked_count == 1
    assert [%{start_intent_status: "acknowledged", session_id: "session-alpha"} | _] = handoff.worker_lifecycle.workers
    assert [%{start_intent_status: "acknowledged"}] = handoff.worker_lifecycle.active_attempt_start_intents
    assert [%{status: "ack", request: request}] = handoff.results
    assert request.project_id == "alpha"
    assert request.source_poll.request_id == "provider-request-alpha"
    assert handoff.pending_start_intents == []

    [project] = RuntimeLedger.replay(acked_ledger).projects
    assert project.counts.running == 1
    assert project.pending_start_intents == []

    assert [
             %{status: :running, start_intent_id: start_intent_id, start_intent_status: :acknowledged}
           ] = project.active_attempts

    assert start_intent_id == context.start_intent_id
    assert [%{status: :running, start_intent_status: :acknowledged}] = project.active_issues

    safe_text = inspect({acked_ledger, handoff})
    refute safe_text =~ "Bearer"
    refute safe_text =~ "authorization"
  end

  test "records start failure as retry backoff with observable reason" do
    assert {:ok, ledger, context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)

    starter = fn _request, _opts ->
      %{
        status: "failed",
        failure_status: "retry_queued",
        reason: "worker_capacity_missing",
        error_summary: "worker unavailable",
        due_at: "2026-06-29T09:05:00Z"
      }
    end

    assert {failed_ledger, handoff} = WorkerStartHandoff.run(registry(), ledger, now: @now, starter: starter)

    assert handoff.counts.failed_count == 1
    assert handoff.reason_counts == %{"worker_capacity_missing" => 1}
    assert [%{status: "failed", failure_status: "retry_queued", error_summary: "worker unavailable"}] = handoff.results

    [project] = RuntimeLedger.replay(failed_ledger).projects
    assert project.counts.retry == 1
    assert project.pending_start_intents == []
    assert [%{attempt_id: attempt_id, due_at: "2026-06-29T09:05:00Z", error_summary: "worker unavailable"}] = project.retry_backoff
    assert attempt_id == context.attempt_id
    assert project.workspace_leases == []
  end

  test "activation preflight skips real worker start handoff without calling starter" do
    assert {:ok, ledger, _context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)

    preflight =
      ActivationPreflight.build(registry(),
        now: @now,
        probe: %{
          projects: %{
            "alpha" => %{legacy_service: %{service: "symphony@alpha.service", active: true}}
          }
        }
      )

    fail_if_called = fn _request, _opts ->
      flunk("starter must not be called when activation preflight blocks worker_start")
    end

    assert {same_ledger, handoff} =
             WorkerStartHandoff.run(registry(), ledger,
               now: @now,
               starter: fail_if_called,
               activation_preflight: preflight
             )

    assert same_ledger == ledger
    assert handoff.counts.selected_count == 1
    assert handoff.counts.skipped_count == 1
    assert handoff.counts.unresolved_start_intent_count == 1
    assert handoff.reason_counts == %{"activation_preflight_blocked" => 1}
    assert [%{status: "skipped", reason: "activation_preflight_blocked"}] = handoff.results
  end

  test "cutover gate skips real worker start handoff without calling starter" do
    assert {:ok, ledger, _context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)

    cutover_gate = cutover_gate("alpha", "blocked", blocked_operations: ["worker_start"], reasons: ["operator_acknowledgement_missing"])

    fail_if_called = fn _request, _opts ->
      flunk("starter must not be called when cutover gate blocks worker_start")
    end

    assert {same_ledger, handoff} =
             WorkerStartHandoff.run(registry(), ledger,
               now: @now,
               starter: fail_if_called,
               cutover_gate: cutover_gate
             )

    assert same_ledger == ledger
    assert handoff.counts.selected_count == 1
    assert handoff.counts.skipped_count == 1
    assert handoff.counts.unresolved_start_intent_count == 1
    assert handoff.reason_counts == %{"cutover_gate_blocked" => 1}
    assert [%{status: "skipped", reason: "cutover_gate_blocked"}] = handoff.results
  end

  test "authorization consumption guard skips real worker start handoff without calling starter" do
    assert {:ok, ledger, _context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)

    fail_if_called = fn _request, _opts ->
      flunk("starter must not be called when authorization consumption guard blocks worker_start")
    end

    assert {same_ledger, handoff} =
             WorkerStartHandoff.run(registry(), ledger,
               now: @now,
               starter: fail_if_called,
               authorization_consumption_guard: %{authorization_ledger: %{projects: []}}
             )

    assert same_ledger == ledger
    assert handoff.counts.selected_count == 1
    assert handoff.counts.skipped_count == 1
    assert handoff.counts.unresolved_start_intent_count == 1
    assert handoff.reason_counts == %{"authorization_consumption_blocked" => 1}

    assert [
             %{
               status: "skipped",
               reason: "authorization_consumption_blocked",
               authorization_consumption: %{decision: "no_authorization", side_effect_source: "worker_start_handoff"}
             }
           ] = handoff.results
  end

  test "real worker starter opt-in launches through injectable runner and returns safe ack" do
    parent = self()
    previous_runner = Application.get_env(:symphony_elixir, :hub_worker_start_runner)
    previous_timeout = Application.get_env(:symphony_elixir, :hub_worker_start_timeout_ms)

    on_exit(fn ->
      restore_app_env(:hub_worker_start_runner, previous_runner)
      restore_app_env(:hub_worker_start_timeout_ms, previous_timeout)
    end)

    RealWorkerStarter.set_runner(fn issue, request, runtime, recipient, _opts ->
      send(parent, {:real_worker_runner, issue, request, runtime})
      send(recipient, {:worker_runtime_info, issue.id, %{workspace_path: runtime.workspace_path, worker_host: runtime.worker_host}})

      send(recipient, {
        :codex_worker_update,
        issue.id,
        %{
          event: :session_started,
          session_id: "session-real",
          codex_app_server_pid: "12345",
          timestamp: ~U[2026-06-29 09:00:05Z]
        }
      })

      Process.sleep(:infinity)
    end)

    Application.put_env(:symphony_elixir, :hub_worker_start_timeout_ms, 1_000)

    assert {:ok, ledger, _context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)
    assert {acked_ledger, handoff} = WorkerStartHandoff.run(registry(), ledger, now: @now, starter: RealWorkerStarter)

    assert_receive {:real_worker_runner, issue, request, runtime}, 1_000
    assert issue.id == "123"
    assert issue.identifier == "jhihjian/symphony#123"
    assert request.workflow_file_path == "/tmp/symphony-alpha/WORKFLOW.md"
    assert request.tracker_file_path == "/tmp/symphony-alpha/TRACKER.yaml"
    assert runtime.workspace_path == "/workspaces/alpha/123"

    assert handoff.counts.acked_count == 1
    assert [%{status: "ack", starter_result: starter_result}] = handoff.results
    assert starter_result.session_id == "session-real"
    assert starter_result.worker_identity.codex_app_server_pid == "12345"
    assert handoff.worker_lifecycle.counts.acked_count == 1
    assert [%{session_id: "session-real", worker_identity: %{codex_app_server_pid: "12345"}} | _] = handoff.worker_lifecycle.workers

    [project] = RuntimeLedger.replay(acked_ledger).projects
    assert [%{status: :running, start_intent_status: :acknowledged, run_context: run_context}] = project.active_attempts
    assert run_context.session_id == "session-real"
    assert run_context.worker_identity.codex_app_server_pid == "12345"

    safe_text = inspect(handoff)
    refute safe_text =~ "Authorization"
    refute safe_text =~ "cookie"
  end

  test "real worker starter controls runner env and rejects invalid handoff requests" do
    runner = fn _issue, _request, _runtime, _recipient, _opts -> :ok end

    assert :ok = RealWorkerStarter.set_runner(runner)
    assert Application.get_env(:symphony_elixir, :hub_worker_start_runner) == runner

    assert :ok = RealWorkerStarter.set_runner(nil)
    assert Application.get_env(:symphony_elixir, :hub_worker_start_runner) == nil

    assert :ok = RealWorkerStarter.clear_runner()
    assert Application.get_env(:symphony_elixir, :hub_worker_start_runner) == nil

    assert %{
             status: "manual_attention",
             reason: "invalid_handoff_request",
             failure_status: "manual_attention"
           } = RealWorkerStarter.start(:not_a_request)
  end

  test "real worker starter supports module runners and restores project runtime paths" do
    previous_workflow_path = Workflow.workflow_file_path()
    previous_tracker_path = TrackerConfig.tracker_file_path()

    RealWorkerStarter.set_runner(ModuleAckRunner)
    Application.put_env(:symphony_elixir, :hub_worker_start_timeout_ms, :invalid_timeout)

    request =
      real_worker_request(%{
        :test_recipient => self(),
        :start_intent_id => %{opaque: "not a scalar"},
        :worker_host => nil,
        "worker_host" => "worker-module"
      })

    assert %{
             status: "ack",
             reason: "real_worker_started",
             worker_host: "worker-module",
             session_id: session_id,
             worker_identity: %{codex_app_server_pid: "12345", worker_host: "worker-module"},
             runtime_context: %{start_intent_id: nil}
           } = RealWorkerStarter.start(request, now: @now)

    assert session_id =~ "hub-worker:none:"

    assert_receive {:module_ack_runner, issue, runner_request, runtime}, 1_000
    assert issue.id == "123"
    assert runner_request.project_id == "alpha"
    assert runtime.workflow_path == request.workflow_file_path
    assert runtime.tracker_config_path == request.tracker_file_path

    Process.sleep(50)
    assert Workflow.workflow_file_path() == previous_workflow_path
    assert TrackerConfig.tracker_file_path() == previous_tracker_path
  end

  test "real worker starter reports manual attention when handoff request lacks project runtime paths" do
    result =
      RealWorkerStarter.start(%{
        project_id: "alpha",
        issue_ref: issue_ref("alpha", "123", "jhihjian/symphony#123"),
        current_stage: "ready",
        workspace_path: "/workspaces/alpha/123",
        start_intent_id: "start-intent-alpha-123"
      })

    assert result.status == "manual_attention"
    assert result.reason == "missing_workflow_file_path"
    assert result.failure_status == "manual_attention"

    assert %{
             status: "manual_attention",
             reason: "missing_tracker_file_path",
             failure_status: "manual_attention"
           } = RealWorkerStarter.start(real_worker_request(%{tracker_file_path: nil}))

    assert %{
             status: "manual_attention",
             reason: "missing_workspace_path",
             failure_status: "manual_attention"
           } = RealWorkerStarter.start(real_worker_request(%{workspace_path: nil}))
  end

  test "real worker starter reports workspace lease mismatch as manual attention" do
    RealWorkerStarter.set_runner(fn issue, _request, _runtime, recipient, _opts ->
      send(recipient, {
        :worker_runtime_info,
        issue.id,
        %{workspace_path: "/tmp/symphony-wrong-workspace", worker_host: "worker-mismatch"}
      })

      Process.sleep(:infinity)
    end)

    assert %{
             status: "manual_attention",
             reason: "workspace_lease_mismatch",
             failure_status: "manual_attention",
             error_summary: "worker workspace did not match the ledger workspace lease"
           } = RealWorkerStarter.start(real_worker_request())
  end

  test "real worker starter reports startup failures as retryable facts" do
    for {field, value} <- [payload: "app server failed", details: {:codex, :crashed}] do
      RealWorkerStarter.set_runner(fn issue, _request, _runtime, recipient, _opts ->
        send(recipient, {
          :codex_worker_update,
          issue.id,
          Map.put(%{event: :startup_failed}, field, value)
        })

        Process.sleep(:infinity)
      end)

      assert %{
               status: "failed",
               reason: "worker_start_failed",
               failure_status: "retry_queued",
               error_summary: "worker start failed before acknowledgement: worker_runtime_error"
             } = RealWorkerStarter.start(real_worker_request())
    end
  end

  test "real worker starter reports worker exits before acknowledgement without raw error details" do
    for {exit_reason, allowed_summaries} <- [
          {:return_ok,
           [
             "worker exited before start acknowledgement: normal_exit",
             "worker exited before start acknowledgement: worker_runtime_error"
           ]},
          {:normal,
           [
             "worker exited before start acknowledgement: normal_exit",
             "worker exited before start acknowledgement: worker_runtime_error"
           ]},
          {{:shutdown, :stopping},
           [
             "worker exited before start acknowledgement: shutdown",
             "worker exited before start acknowledgement: worker_runtime_error"
           ]},
          {:boom, ["worker exited before start acknowledgement: worker_runtime_error"]}
        ] do
      RealWorkerStarter.set_runner(fn _issue, _request, _runtime, _recipient, _opts ->
        case exit_reason do
          :return_ok -> :ok
          :normal -> exit(:normal)
          other -> exit(other)
        end
      end)

      assert %{
               status: "failed",
               reason: "worker_exited_before_ack",
               failure_status: "retry_queued",
               error_summary: error_summary
             } = RealWorkerStarter.start(real_worker_request())

      assert error_summary in allowed_summaries
    end
  end

  test "real worker starter times out workers that never acknowledge start" do
    Application.put_env(:symphony_elixir, :hub_worker_start_timeout_ms, 10)

    RealWorkerStarter.set_runner(fn _issue, _request, _runtime, _recipient, _opts ->
      Process.sleep(:infinity)
    end)

    assert %{
             status: "failed",
             reason: "worker_start_timeout",
             failure_status: "retry_queued",
             error_summary: "worker did not acknowledge start within 10ms"
           } = RealWorkerStarter.start(real_worker_request())
  end

  test "records manual attention while preserving unresolved start intent" do
    assert {:ok, ledger, _context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)

    starter = fn _request, _opts ->
      %{
        status: :manual_attention,
        reason: :requires_operator_check,
        error_summary: "ack ambiguous"
      }
    end

    assert {manual_ledger, handoff} = WorkerStartHandoff.run(registry(), ledger, now: @now, starter: starter)

    assert handoff.counts.manual_attention_count == 1
    assert handoff.counts.unresolved_start_intent_count == 1
    assert handoff.reason_counts == %{"requires_operator_check" => 1}
    assert [%{status: "manual_attention"}] = handoff.results
    assert [%{status: "unknown", manual_attention: true}] = handoff.unresolved_start_intents

    [project] = RuntimeLedger.replay(manual_ledger).projects
    assert project.counts.manual_attention == 1
    assert [%{status: :unknown, manual_attention: true}] = project.pending_start_intents
    assert [%{code: :start_intent_unknown_manual_attention}] = project.manual_attention
    assert length(project.workspace_leases) == 1
  end

  test "unknown result remains unresolved and repeat handoff does not call starter again" do
    parent = self()
    assert {:ok, ledger, context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)

    unknown_starter = fn _request, _opts ->
      send(parent, :starter_called)
      %{status: "unknown", reason: "lost_ack", error_summary: "ack result lost"}
    end

    assert {unknown_ledger, first_handoff} = WorkerStartHandoff.run(registry(), ledger, now: @now, starter: unknown_starter)
    assert_receive :starter_called

    assert first_handoff.counts.unknown_count == 1
    assert first_handoff.counts.unresolved_start_intent_count == 1
    assert [%{status: "unknown", reason: "lost_ack"}] = first_handoff.results

    [first_project] = RuntimeLedger.replay(unknown_ledger).projects
    assert [%{status: :unknown, intent_id: intent_id}] = first_project.pending_start_intents
    assert intent_id == context.start_intent_id
    assert length(first_project.active_attempts) == 1
    assert length(first_project.workspace_leases) == 1

    fail_if_called = fn _request, _opts ->
      flunk("starter must not be called for an unresolved unknown start intent")
    end

    assert {repeat_ledger, repeat_handoff} = WorkerStartHandoff.run(registry(), unknown_ledger, now: DateTime.add(@now, 60, :second), starter: fail_if_called)
    assert repeat_ledger == unknown_ledger
    assert repeat_handoff.counts.selected_count == 1
    assert repeat_handoff.counts.skipped_count == 1
    assert repeat_handoff.reason_counts == %{"start_intent_unresolved" => 1}

    [repeat_project] = RuntimeLedger.replay(repeat_ledger).projects
    assert length(repeat_project.active_attempts) == 1
    assert length(repeat_project.workspace_leases) == 1
    assert [%{intent_id: ^intent_id, status: :unknown}] = repeat_project.pending_start_intents
  end

  test "already acknowledged ledgers are idempotent and report no selected start intents" do
    assert {:ok, ledger, _context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate(), now: @now)

    ack_starter = fn _request, _opts ->
      %{status: "ack", reason: "worker_ack", session_id: "session-alpha"}
    end

    assert {acked_ledger, first_handoff} = WorkerStartHandoff.run(registry(), ledger, now: @now, starter: ack_starter)
    assert first_handoff.counts.acked_count == 1

    fail_if_called = fn _request, _opts ->
      flunk("starter must not be called after start intent is acknowledged")
    end

    assert {same_ledger, second_handoff} = WorkerStartHandoff.run(registry(), acked_ledger, now: DateTime.add(@now, 60, :second), starter: fail_if_called)
    assert same_ledger == acked_ledger
    assert second_handoff.counts.selected_count == 0
    assert second_handoff.counts.already_acked_count == 0
    assert second_handoff.pending_start_intents == []
  end

  test "handoff summaries redact secrets, raw provider config, prompts, transcripts and bodies" do
    unsafe =
      candidate(
        runtime_identity: %{
          boundary: "hub_dispatch_plan_application",
          source_poll: %{request_id: "provider-request-alpha", raw_provider_config: %{token: "ghp_should_not_leak"}},
          source_intake: %{candidate_key: "alpha:github:jhihjian/symphony:123", comment_body: "complete comment body"},
          planning: %{intent_id: "planning-intent", transcript: "complete transcript"}
        },
        start_command_summary: %{
          runner: "codex",
          argv: ["codex", "exec"],
          secret_env: ["GITHUB_TOKEN"],
          prompt: "full prompt should not leak",
          pull_request_body: "full pr body should not leak"
        }
      )

    assert {:ok, ledger, _context} = DispatchBoundary.dispatch(RuntimeLedger.new(), unsafe, now: @now)

    starter = fn _request, _opts ->
      %{
        status: :ack,
        reason: :safe_ack,
        session_id: "session-alpha",
        token: "ghp_starter_secret",
        cookie: "session=secret",
        comment_body: "starter comment body"
      }
    end

    assert {_ledger, handoff} = WorkerStartHandoff.run(registry(), ledger, now: @now, starter: starter)
    safe_text = inspect(handoff)

    refute safe_text =~ "ghp_should_not_leak"
    refute safe_text =~ "ghp_starter_secret"
    refute safe_text =~ "session=secret"
    refute safe_text =~ "GITHUB_TOKEN"
    refute safe_text =~ "complete comment body"
    refute safe_text =~ "complete transcript"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "full pr body"
    refute safe_text =~ "raw_provider_config"
    refute safe_text =~ "secret_env"
    refute safe_text =~ "prompt"
    refute safe_text =~ "transcript"
    refute safe_text =~ "comment_body"
    refute safe_text =~ "pull_request_body"
  end

  defp registry do
    %{
      projects: [
        %{
          project_id: "alpha",
          name: "Alpha",
          migration_state: "hub_managed",
          dispatch_enabled: true,
          paused: false,
          status: :ready,
          workflow_summary: %{
            start_stage: "ready",
            terminal_stages: ["done", "blocked"],
            stage_ids: ["ready", "in_progress", "done", "blocked"]
          },
          tracker_summary: %{
            kind: "github",
            provider_scope: %{owner: "jhihjian", repo: "symphony"},
            provider_scope_key: "github:jhihjian/symphony"
          },
          runtime_summary: %{
            workspace_root: "/workspaces/alpha",
            max_concurrent_agents: 5,
            max_concurrent_agents_by_state: %{},
            polling_interval_ms: 30_000,
            server_port: nil
          },
          workflow_path: "/tmp/symphony-alpha/WORKFLOW.md",
          tracker_config_path: "/tmp/symphony-alpha/TRACKER.yaml",
          fingerprint: "alpha-fingerprint",
          snapshot_version: "hub-project:alpha:1",
          loaded_at: @now
        }
      ],
      warnings: [],
      errors: []
    }
  end

  defp candidate(overrides \\ []) do
    ref = Keyword.get(overrides, :issue_ref, issue_ref("alpha", "123", "jhihjian/symphony#123"))
    issue_key = RuntimeLedger.issue_key(ref)
    attempt_id = "attempt-alpha-123"
    start_intent_id = "start-intent-alpha-123"

    %{
      project_id: "alpha",
      config_fingerprint: "alpha-fingerprint",
      snapshot_version: "hub-project:alpha:1",
      issue_ref: ref,
      workflow: %{start_stage: "ready", terminal_stages: ["done", "blocked"], stage_ids: ["ready", "in_progress", "done", "blocked"]},
      tracker: %{kind: "github", provider_scope_key: "github:jhihjian/symphony", required_labels: ["symphony"]},
      current_stage: "ready",
      trigger_source: :poll_plan,
      governance: %{request: %{request_id: "poll-request-1"}, decision: :selected},
      correlation_id: "correlation-alpha-123",
      attempt_id: attempt_id,
      start_intent_id: start_intent_id,
      workspace_path: "/workspaces/alpha/123",
      worker_host: "worker-1",
      runtime_identity: %{
        boundary: "hub_dispatch_plan_application",
        model_only: true,
        source_poll: %{
          request_id: "provider-request-alpha",
          logical_key: "hub-poll:alpha:candidate_scan",
          poll_attempt_id: "poll-attempt-alpha",
          poll_result_status: "success"
        },
        source_intake: %{candidate_key: issue_key, candidate_id: "candidate-alpha-123"},
        planning: %{intent_id: start_intent_id, candidate_key: issue_key}
      },
      runner: "codex",
      start_command_summary: %{
        runner: "codex",
        starts_agent: false,
        creates_workspace: false,
        writes_provider: false,
        workflow_file_path: "/tmp/symphony-alpha/WORKFLOW.md",
        tracker_file_path: "/tmp/symphony-alpha/TRACKER.yaml",
        planning: %{intent_id: start_intent_id},
        source_intake: %{candidate_key: issue_key}
      }
    }
    |> Map.merge(Map.new(overrides))
  end

  defp issue_ref(project_id, provider_issue_id, identifier) do
    %IssueRef{
      project_id: project_id,
      tracker_kind: "github",
      provider_scope: %{owner: "jhihjian", repo: "symphony"},
      provider_scope_key: "github:jhihjian/symphony",
      provider_issue_id: provider_issue_id,
      provider_local_id: identifier,
      identifier: identifier,
      url: "https://example.test/#{provider_issue_id}"
    }
  end

  defp real_worker_request(overrides \\ %{}) do
    workflow_file_path = Workflow.workflow_file_path()
    tracker_file_path = TrackerConfig.tracker_file_path() || TrackerConfig.default_tracker_file_path(workflow_file_path)

    base = %{
      project_id: "alpha",
      issue_key: "alpha:github:jhihjian/symphony:123",
      attempt_id: "attempt-alpha-123",
      start_intent_id: "start-intent-alpha-123",
      issue_ref: %{
        provider_issue_id: "123",
        identifier: "jhihjian/symphony#123",
        url: "https://example.test/123"
      },
      current_stage: "ready",
      workflow_file_path: workflow_file_path,
      tracker_file_path: tracker_file_path,
      workspace_path: "/workspaces/alpha/123",
      worker_host: "worker-1"
    }

    Map.merge(base, overrides)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp cutover_gate(project_id, decision, opts) do
    %{
      projects: [
        %{
          project_id: project_id,
          migration_state: "hub_managed",
          decision: decision,
          allowed_operations: Keyword.get(opts, :allowed_operations, []),
          blocked_operations: Keyword.get(opts, :blocked_operations, ["poll", "dispatch", "worker_start", "writeback"]),
          blocking_reasons:
            opts
            |> Keyword.get(:reasons, [])
            |> Enum.map(&%{code: &1, source: "cutover_gate", level: "blocking"}),
          required_operator_actions: [%{code: "accept_activation_plan"}]
        }
      ]
    }
  end
end
