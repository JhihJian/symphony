defmodule SymphonyElixir.HubDispatchPlanningTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{CandidateIntake, DispatchPlanning, RuntimeLedger}

  @now ~U[2026-06-29 08:00:00Z]

  test "plans eligible candidates into safe pending start intent summaries" do
    registry = registry([project("alpha", max_concurrent_agents: 2)])
    intake = CandidateIntake.build(registry, [source("alpha", [%{id: "123", identifier: "ALPHA-123"}])], now: @now)

    plan = DispatchPlanning.build(registry, intake, now: @now)

    assert plan.counts == %{
             eligible_count: 1,
             outcome_count: 1,
             planned_count: 1,
             skipped_count: 0,
             already_planned_count: 0,
             capacity_unavailable_count: 0,
             invalid_count: 0,
             pending_intent_count: 1,
             project_count: 1
           }

    assert [intent] = plan.pending_intents
    assert intent.project_id == "alpha"
    assert intent.provider_scope_key == "github:jhihjian/symphony"
    assert intent.issue_key == "alpha:github:jhihjian/symphony:123"
    assert intent.source_poll.request_id == "provider-request-alpha"
    assert intent.source_intake.candidate_key == intent.issue_key

    assert intent.start_command_summary == %{
             creates_workspace: false,
             planned: true,
             starts_agent: false,
             writes_provider: false
           }

    assert [project] = plan.projects
    assert [%{status: "planned", intent: ^intent}] = project.outcomes
    assert project.counts.project_count == 0
    assert plan.safety.starts_agent == false
    assert plan.safety.creates_workspace == false
    assert plan.safety.writes_provider == false
  end

  test "does not duplicate unresolved start intents on refresh or replay" do
    registry = registry([project("alpha", max_concurrent_agents: 2)])
    intake = CandidateIntake.build(registry, [source("alpha", [%{id: "123", identifier: "ALPHA-123"}])], now: @now)

    first = DispatchPlanning.build(registry, intake, now: @now)
    second = DispatchPlanning.build(registry, intake, now: DateTime.add(@now, 60, :second), previous_plan: first)

    assert second.counts.planned_count == 0
    assert second.counts.already_planned_count == 1
    assert second.counts.pending_intent_count == 1
    assert [same_intent] = second.pending_intents
    assert same_intent.intent_id == hd(first.pending_intents).intent_id

    ledger = ledger_with_pending_intent()
    intake_from_ledger = CandidateIntake.build(registry, [source("alpha", [%{id: "123", identifier: "ALPHA-123"}])], now: @now, runtime_ledger: ledger)
    replayed = DispatchPlanning.build(registry, intake_from_ledger, now: @now, runtime_ledger: ledger)

    assert replayed.counts.planned_count == 0
    assert replayed.counts.already_planned_count == 1
    assert [intent] = replayed.pending_intents
    assert intent.source_model == "runtime_ledger"
    assert intent.intent_id == "intent-123"
  end

  test "reserves project capacity within the same planning pass" do
    registry = registry([project("alpha", max_concurrent_agents: 1)])

    intake =
      CandidateIntake.build(
        registry,
        [source("alpha", [%{id: "123", identifier: "ALPHA-123"}, %{id: "124", identifier: "ALPHA-124"}])],
        now: @now
      )

    plan = DispatchPlanning.build(registry, intake, now: @now)

    assert plan.counts.planned_count == 1
    assert plan.counts.capacity_unavailable_count == 1
    assert plan.skipped_reasons == %{"project_capacity_full" => 1}

    [project] = plan.projects
    statuses = Map.new(project.outcomes, &{&1.issue_key, &1.status})
    assert statuses["alpha:github:jhihjian/symphony:123"] == "planned"
    assert statuses["alpha:github:jhihjian/symphony:124"] == "capacity_unavailable"
  end

  test "reserves global capacity across projects without blocking unrelated evaluation" do
    registry =
      registry([
        project("alpha", max_concurrent_agents: 10),
        project("beta", max_concurrent_agents: 10, provider_scope_key: "github:jhihjian/beta")
      ])

    intake =
      CandidateIntake.build(
        registry,
        [
          source("alpha", [%{id: "123", identifier: "ALPHA-123"}]),
          source("beta", [%{id: "224", identifier: "BETA-224"}], provider_scope_key: "github:jhihjian/beta")
        ],
        now: @now
      )

    plan = DispatchPlanning.build(registry, intake, now: @now, max_agent_capacity: 1)

    assert plan.counts.planned_count == 1
    assert plan.counts.capacity_unavailable_count == 1
    assert plan.skipped_reasons == %{"global_capacity_full" => 1}

    statuses =
      plan.projects
      |> Enum.flat_map(& &1.outcomes)
      |> Map.new(&{&1.issue_key, &1.status})

    assert statuses["alpha:github:jhihjian/symphony:123"] == "planned"
    assert statuses["beta:github:jhihjian/beta:224"] == "capacity_unavailable"
  end

  test "surfaces intake blockers without planning unsafe candidates" do
    registry =
      registry([
        project("paused", paused: true),
        project("manual"),
        project("limited")
      ])

    intake =
      CandidateIntake.build(
        registry,
        [
          source("paused", [%{id: "1", identifier: "PAUSED-1"}]),
          source("manual", [%{id: "2", identifier: "MANUAL-2"}], manual_attention: true),
          source("limited", [%{id: "3", identifier: "LIMITED-3"}], status: :rate_limited, retry_after_ms: 60_000)
        ],
        now: @now
      )

    plan = DispatchPlanning.build(registry, intake, now: @now)

    assert plan.counts.planned_count == 0

    assert plan.skipped_reasons == %{
             "manual_attention" => 1,
             "project_paused" => 1,
             "provider_rate_limit" => 1
           }

    outcomes =
      plan.projects
      |> Enum.flat_map(& &1.outcomes)
      |> Map.new(&{&1.project_id, &1.status})

    assert outcomes["paused"] == "project_paused"
    assert outcomes["manual"] == "manual_attention"
    assert outcomes["limited"] == "provider_backoff"
  end

  test "redacts unsafe candidate and source fields from planning snapshots" do
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
                token: "ghp_supersecret",
                authorization: "Bearer supersecret",
                prompt: "full prompt should not leak",
                transcript: "complete transcript should not leak",
                raw_body: "raw provider body should not leak",
                candidates: [
                  %{id: "secret", identifier: "ALPHA-SECRET", comment_body: "complete comment body should not leak"}
                ]
              }
            },
            attempt: %{attempt_id: "poll-attempt-alpha"}
          }
        ],
        now: @now
      )

    plan = DispatchPlanning.build(registry, intake, now: @now)
    safe_text = inspect(plan)

    refute safe_text =~ "ghp_supersecret"
    refute safe_text =~ "Bearer"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "complete transcript"
    refute safe_text =~ "raw provider body"
    refute safe_text =~ "complete comment body"
    refute safe_text =~ "authorization"
    refute safe_text =~ "comment_body"
  end

  defp registry(projects), do: %{projects: projects, warnings: [], errors: []}

  defp project(project_id, opts \\ []) do
    paused = Keyword.get(opts, :paused, false)
    status = Keyword.get(opts, :status, if(paused, do: :paused, else: :ready))
    provider_scope_key = Keyword.get(opts, :provider_scope_key, "github:jhihjian/symphony")

    %{
      project_id: project_id,
      name: String.capitalize(project_id),
      dispatch_enabled: not paused,
      paused: paused,
      status: status,
      workflow_summary: %{
        start_stage: "ready",
        terminal_stages: ["done", "blocked"],
        stage_ids: ["ready", "in_progress", "done", "blocked"]
      },
      tracker_summary: %{
        kind: "github",
        provider_scope: github_scope(provider_scope_key),
        provider_scope_key: provider_scope_key,
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
      loaded_at: @now,
      load_error: Keyword.get(opts, :load_error)
    }
  end

  defp source(project_id, candidates, opts \\ []) do
    status = Keyword.get(opts, :status, :success)
    provider_scope_key = Keyword.get(opts, :provider_scope_key, "github:jhihjian/symphony")

    %{
      result: %{
        project_id: project_id,
        provider_scope_key: provider_scope_key,
        request_id: "provider-request-#{project_id}",
        logical_key: "hub-poll:#{project_id}:candidate_scan",
        status: status,
        retry_after_ms: Keyword.get(opts, :retry_after_ms),
        manual_attention: Keyword.get(opts, :manual_attention, false),
        result_summary: %{candidates: candidates}
      },
      attempt: %{attempt_id: "poll-attempt-#{project_id}"}
    }
  end

  defp ledger_with_pending_intent do
    ref = issue_ref("alpha", "123", "ALPHA-123")
    issue_key = RuntimeLedger.issue_key(ref)

    RuntimeLedger.new(
      projects: [
        %{
          project_id: "alpha",
          issues: [
            %{
              issue_ref: ref,
              claim_status: :claimed,
              current_stage: "ready",
              attempts: [
                %{attempt_id: "attempt-123", attempt_number: 1, status: :pending, workspace_path: "/workspaces/alpha/ALPHA-123"}
              ]
            }
          ],
          workspace_leases: [
            %{lease_id: "lease-123", issue_key: issue_key, attempt_id: "attempt-123", workspace_path: "/workspaces/alpha/ALPHA-123", status: :active}
          ],
          start_intents: [
            %{
              intent_id: "intent-123",
              issue_key: issue_key,
              attempt_id: "attempt-123",
              workspace_lease_id: "lease-123",
              workspace_path: "/workspaces/alpha/ALPHA-123",
              status: :pending,
              requested_at: @now
            }
          ]
        }
      ]
    )
  end

  defp issue_ref(project_id, issue_id, identifier) do
    %{
      project_id: project_id,
      tracker_kind: "github",
      provider_scope: github_scope("github:jhihjian/symphony"),
      provider_scope_key: "github:jhihjian/symphony",
      provider_issue_id: issue_id,
      provider_local_id: identifier,
      identifier: identifier,
      url: "https://example.test/#{issue_id}"
    }
  end

  defp github_scope("github:" <> owner_repo) do
    [owner, repo] = String.split(owner_repo, "/", parts: 2)
    %{owner: owner, repo: repo}
  end
end
