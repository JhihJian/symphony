defmodule SymphonyElixir.HubDispatchPlanApplicationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{CandidateIntake, DispatchPlanApplication, DispatchPlanning, RuntimeLedger}

  @now ~U[2026-06-29 08:00:00Z]

  test "applies planned intents into runtime ledger facts with safe source correlation" do
    registry = registry([project("alpha", max_concurrent_agents: 2)])
    intake = CandidateIntake.build(registry, [source("alpha", [%{id: "123", identifier: "ALPHA-123"}])], now: @now)
    plan = DispatchPlanning.build(registry, intake, now: @now)

    {ledger, application} = DispatchPlanApplication.apply_plan(registry, plan, RuntimeLedger.new(), now: @now)

    assert application.counts.applied_count == 1
    assert application.counts.pending_start_intent_count == 1
    assert application.reason_counts == %{}

    assert [project] = application.projects
    assert [%{status: "applied", preflight: %{status: "allowed"}}] = project.outcomes

    assert [
             %{runtime_identity: runtime_identity, start_command_summary: start_command_summary} = intent
           ] = application.pending_start_intents

    assert runtime_identity.source_poll.request_id == "provider-request-alpha"
    assert runtime_identity.source_intake.candidate_key == "alpha:github:jhihjian/symphony:123"
    assert runtime_identity.planning.intent_id == intent.intent_id
    assert start_command_summary.starts_agent in [false, "false"]
    assert start_command_summary.creates_workspace in [false, "false"]
    assert start_command_summary.writes_provider in [false, "false"]

    assert [ledger_project] = RuntimeLedger.replay(ledger).projects
    assert [%{status: :pending, run_context: run_context}] = ledger_project.active_attempts
    assert run_context.runtime_identity.source_poll.request_id == "provider-request-alpha"
    assert [%{status: :pending}] = ledger_project.pending_start_intents
    assert [%{lease_id: lease_id}] = ledger_project.workspace_leases
    assert is_binary(lease_id)
  end

  test "repeat application reports already applied without creating another active attempt" do
    registry = registry([project("alpha", max_concurrent_agents: 2)])
    intake = CandidateIntake.build(registry, [source("alpha", [%{id: "123", identifier: "ALPHA-123"}])], now: @now)
    plan = DispatchPlanning.build(registry, intake, now: @now)

    {ledger, first_application} = DispatchPlanApplication.apply_plan(registry, plan, RuntimeLedger.new(), now: @now)
    {_ledger, second_application} = DispatchPlanApplication.apply_plan(registry, plan, ledger, now: DateTime.add(@now, 60, :second))

    assert first_application.counts.applied_count == 1
    assert second_application.counts.already_applied_count == 1
    assert second_application.reason_counts == %{"start_intent_unresolved" => 1}

    assert [project] = RuntimeLedger.replay(ledger).projects
    assert length(project.active_attempts) == 1
    assert length(project.pending_start_intents) == 1
  end

  test "respects runtime ledger capacity and unsafe planning outcomes" do
    registry = registry([project("alpha", max_concurrent_agents: 1)])
    intake = CandidateIntake.build(registry, [source("alpha", [%{id: "123"}, %{id: "124"}])], now: @now)
    plan = DispatchPlanning.build(registry, intake, now: @now)

    {_ledger, application} = DispatchPlanApplication.apply_plan(registry, plan, RuntimeLedger.new(), now: @now)

    assert application.counts.applied_count == 1
    assert application.counts.skipped_count == 1
    assert application.reason_counts == %{"project_capacity_full" => 1}

    statuses =
      application.projects
      |> Enum.flat_map(& &1.outcomes)
      |> Map.new(&{&1.issue_ref.provider_issue_id, &1.status})

    assert statuses["123"] == "applied"
    assert statuses["124"] == "skipped"
  end

  test "sanitizes application summary and pending start intent metadata" do
    registry = registry([project("alpha")])

    intake =
      CandidateIntake.build(
        registry,
        [
          %{
            result: %{
              project_id: "alpha",
              provider_scope_key: "github:jhihjian/symphony",
              request_id: "provider-request-alpha",
              logical_key: "hub-poll:alpha:candidate_scan",
              status: :success,
              result_summary: %{
                authorization: "Bearer supersecret",
                cookie: "session=supersecret",
                token: "ghp_supersecret",
                prompt: "full prompt should not leak",
                transcript: "complete transcript should not leak",
                raw_body: "raw provider body should not leak",
                candidates: [
                  %{id: "123", identifier: "ALPHA-123", comment_body: "complete comment body should not leak"}
                ]
              }
            },
            attempt: %{attempt_id: "poll-attempt-alpha"}
          }
        ],
        now: @now
      )

    plan = DispatchPlanning.build(registry, intake, now: @now)
    {_ledger, application} = DispatchPlanApplication.apply_plan(registry, plan, RuntimeLedger.new(), now: @now)
    safe_text = inspect(application)

    refute safe_text =~ "Bearer"
    refute safe_text =~ "session=supersecret"
    refute safe_text =~ "ghp_supersecret"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "complete transcript"
    refute safe_text =~ "raw provider body"
    refute safe_text =~ "complete comment body"
    refute safe_text =~ "authorization"
    refute safe_text =~ "cookie"
    refute safe_text =~ "comment_body"
  end

  defp registry(projects), do: %{projects: projects, warnings: [], errors: []}

  defp project(project_id, opts \\ []) do
    %{
      project_id: project_id,
      name: String.capitalize(project_id),
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
        provider_scope_key: "github:jhihjian/symphony",
        required_labels: ["symphony"]
      },
      runtime_summary: %{
        workspace_root: "/workspaces/#{project_id}",
        max_concurrent_agents: Keyword.get(opts, :max_concurrent_agents, 10),
        max_concurrent_agents_by_state: %{},
        polling_interval_ms: 30_000,
        server_port: nil
      },
      fingerprint: "#{project_id}-fingerprint",
      loaded_at: @now
    }
  end

  defp source(project_id, candidates, opts \\ []) do
    %{
      result: %{
        project_id: project_id,
        provider_scope_key: "github:jhihjian/symphony",
        request_id: "provider-request-#{project_id}",
        logical_key: "hub-poll:#{project_id}:candidate_scan",
        status: Keyword.get(opts, :status, :success),
        result_summary: %{candidates: candidates}
      },
      attempt: %{attempt_id: "poll-attempt-#{project_id}"}
    }
  end
end
