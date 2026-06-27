defmodule SymphonyElixir.HubDispatchBoundaryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.DispatchBoundary
  alias SymphonyElixir.Hub.IssueRef
  alias SymphonyElixir.Hub.RuntimeLedger
  alias SymphonyElixirWeb.Presenter

  defmodule StaticHubOrchestrator do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      snapshot = Keyword.fetch!(opts, :snapshot)
      GenServer.start_link(__MODULE__, snapshot, name: name)
    end

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  test "dispatch context captures candidate identity and preflight inputs" do
    ledger = RuntimeLedger.new()
    candidate = candidate()

    assert {:ok, context} = DispatchBoundary.build_context(candidate, ledger)

    assert context.project_id == "alpha"
    assert context.issue_key == "alpha:github:jhihjian/symphony:123"
    assert context.workflow.start_stage == "ready"
    assert context.tracker.kind == "github"
    assert context.trigger_source == :poll_plan
    assert context.attempt_number == 1
    assert context.attempt_id =~ "hub-attempt:"
    assert context.workspace_lease_id =~ "hub-workspace-lease:"
    assert context.start_intent_id =~ "hub-start-intent:"

    assert context.preflight == %{
             status: :allowed,
             can_start?: true,
             reason: nil,
             message: nil,
             existing_attempt_id: nil,
             existing_workspace_path: nil,
             retry_due_at: nil,
             blocked_by: []
           }
  end

  test "duplicate candidate for same project IssueRef does not create a second active attempt" do
    assert {:ok, ledger, first_context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate())

    assert {:ignored, preflight, second_context} =
             DispatchBoundary.dispatch(
               ledger,
               candidate(correlation_id: "repeat-webhook", trigger_source: :webhook)
             )

    assert first_context.issue_key == second_context.issue_key
    assert preflight.status == :already_active
    assert preflight.existing_attempt_id == first_context.attempt_id

    summary = RuntimeLedger.replay(ledger)
    [project] = summary.projects
    assert length(project.active_attempts) == 1
    assert hd(project.active_attempts).attempt_id == first_context.attempt_id
    assert length(project.pending_start_intents) == 1
  end

  test "same workspace cannot be leased by two active attempts" do
    assert {:ok, ledger, _context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate())

    second =
      candidate(
        issue_ref: issue_ref("alpha", "github", "github:jhihjian/symphony", "124", "jhihjian/symphony#124"),
        workspace_path: "/workspaces/alpha/shared",
        correlation_id: "second"
      )

    assert {:error, preflight, _context} = DispatchBoundary.dispatch(ledger, second)
    assert preflight.status == :workspace_conflict
    assert preflight.existing_workspace_path == "/workspaces/alpha/shared"

    summary = RuntimeLedger.replay(ledger)
    [project] = summary.projects
    assert length(project.active_attempts) == 1
    assert length(project.workspace_leases) == 1
  end

  test "workspace lease conflicts are global across projects" do
    assert {:ok, ledger, _context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate())

    second =
      candidate(
        project_id: "beta",
        config_fingerprint: "beta-fingerprint",
        snapshot_version: "hub-project:beta:1",
        issue_ref: issue_ref("beta", "github", "github:jhihjian/symphony", "223", "jhihjian/symphony#223"),
        workspace_path: "/workspaces/alpha/shared",
        correlation_id: "beta-shared"
      )

    assert {:error, preflight, _context} = DispatchBoundary.dispatch(ledger, second)
    assert preflight.status == :workspace_conflict
    assert preflight.reason == :workspace_already_leased

    conflicting =
      RuntimeLedger.new(
        projects: [
          project_with_active_lease("alpha", "123", "/workspaces/shared"),
          project_with_active_lease("beta", "223", "/workspaces/shared")
        ]
      )

    assert {:error, diagnostics} = RuntimeLedger.validate(conflicting)
    assert Enum.any?(diagnostics, &(&1.code == :workspace_cross_project_active_lease_conflict))
  end

  test "pending start intent after lost ack is replayed and prevents blind double start" do
    assert {:ok, ledger, context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate())

    summary = RuntimeLedger.replay(ledger)
    [project] = summary.projects
    assert [%{intent_id: intent_id, status: :pending}] = project.pending_start_intents
    assert intent_id == context.start_intent_id
    assert project.conflicts == []

    assert {:ignored, preflight, _context} =
             DispatchBoundary.dispatch(
               ledger,
               candidate(correlation_id: "restart-recovery", trigger_source: :recovery)
             )

    assert preflight.status == :already_active
    assert preflight.existing_attempt_id == context.attempt_id
  end

  test "unknown worker start result enters manual attention instead of safe auto replay" do
    assert {:ok, ledger, context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate())

    assert {:ok, failed_ledger} =
             DispatchBoundary.record_start_failure(
               ledger,
               %{
                 project_id: context.project_id,
                 issue_key: context.issue_key,
                 attempt_id: context.attempt_id,
                 start_intent_id: context.start_intent_id,
                 error_summary: "start ack lost"
               },
               :manual_attention,
               now: ~U[2026-06-27 11:01:00Z]
             )

    summary = RuntimeLedger.replay(failed_ledger)
    [project] = summary.projects
    assert project.counts.manual_attention == 1
    assert [%{status: :manual_attention}] = project.active_issues
    assert [%{status: :unknown, manual_attention: true}] = project.pending_start_intents
    assert [%{code: :start_intent_unknown_manual_attention}] = project.manual_attention

    assert {:ignored, preflight, _context} = DispatchBoundary.dispatch(failed_ledger, candidate(correlation_id: "after-unknown"))
    assert preflight.status == :already_active
    assert preflight.reason == :start_intent_unresolved
  end

  test "ack failure and release reject unknown dispatch targets" do
    assert {:ok, ledger, context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate())

    bad_ack = %{
      project_id: context.project_id,
      issue_key: context.issue_key,
      attempt_id: context.attempt_id,
      start_intent_id: "missing-intent"
    }

    assert {:error, {:unknown_start_intent, "missing-intent"}} = DispatchBoundary.acknowledge_start(ledger, bad_ack)

    bad_failure =
      Map.merge(bad_ack, %{
        start_intent_id: context.start_intent_id,
        attempt_id: "missing-attempt"
      })

    assert {:error, {:unknown_attempt, "missing-attempt"}} =
             DispatchBoundary.record_start_failure(ledger, bad_failure, :blocked)

    assert {:error, {:unknown_issue, "missing-issue"}} =
             DispatchBoundary.release_attempt(ledger, %{
               project_id: context.project_id,
               issue_key: "missing-issue",
               attempt_id: context.attempt_id
             })
  end

  test "dispatch failure can enter retry blocked and released states" do
    assert {:ok, retry_ledger, retry_context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate())

    assert {:ok, retry_ledger} =
             DispatchBoundary.record_start_failure(
               retry_ledger,
               %{
                 project_id: retry_context.project_id,
                 issue_key: retry_context.issue_key,
                 attempt_id: retry_context.attempt_id,
                 start_intent_id: retry_context.start_intent_id,
                 due_at: "2026-06-27T11:05:00Z",
                 error_summary: "worker unavailable"
               },
               :retry_queued
             )

    [retry_project] = RuntimeLedger.replay(retry_ledger).projects
    assert [%{due_at: "2026-06-27T11:05:00Z"}] = retry_project.retry_backoff
    assert retry_project.workspace_leases == []

    assert {:ok, blocked_ledger, blocked_context} =
             RuntimeLedger.new()
             |> DispatchBoundary.dispatch(candidate(issue_ref: issue_ref("alpha", "github", "github:jhihjian/symphony", "125", "jhihjian/symphony#125"), workspace_path: "/workspaces/alpha/125"))

    assert {:ok, blocked_ledger} =
             DispatchBoundary.record_start_failure(
               blocked_ledger,
               %{
                 project_id: blocked_context.project_id,
                 issue_key: blocked_context.issue_key,
                 attempt_id: blocked_context.attempt_id,
                 start_intent_id: blocked_context.start_intent_id,
                 error_summary: "config invalid"
               },
               :blocked
             )

    [blocked_project] = RuntimeLedger.replay(blocked_ledger).projects
    assert [%{issue_key: "alpha:github:jhihjian/symphony:125"}] = blocked_project.blocked_candidates
    assert blocked_project.workspace_leases == []

    assert {:ok, released_ledger, released_context} =
             RuntimeLedger.new()
             |> DispatchBoundary.dispatch(candidate(issue_ref: issue_ref("alpha", "github", "github:jhihjian/symphony", "126", "jhihjian/symphony#126"), workspace_path: "/workspaces/alpha/126"))

    assert {:ok, released_ledger} =
             DispatchBoundary.release_attempt(
               released_ledger,
               %{
                 project_id: released_context.project_id,
                 issue_key: released_context.issue_key,
                 attempt_id: released_context.attempt_id,
                 reason: "stage outcome accepted"
               }
             )

    [released_project] = RuntimeLedger.replay(released_ledger).projects
    assert released_project.counts.released == 1
    assert released_project.workspace_leases == []
  end

  test "expired retry backoff allows a later dispatch attempt" do
    assert {:ok, ledger, context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate())

    assert {:ok, retry_ledger} =
             DispatchBoundary.record_start_failure(
               ledger,
               %{
                 project_id: context.project_id,
                 issue_key: context.issue_key,
                 attempt_id: context.attempt_id,
                 start_intent_id: context.start_intent_id,
                 due_at: "2026-06-27T11:05:00Z",
                 error_summary: "worker unavailable"
               },
               :retry_queued
             )

    assert {:ok, retry_context} =
             DispatchBoundary.build_context(
               candidate(correlation_id: "retry-after-backoff"),
               retry_ledger,
               now: "2026-06-27T11:06:00Z"
             )

    assert retry_context.preflight.status == :allowed

    assert {:ok, dispatched_ledger, retry_context} =
             DispatchBoundary.dispatch(
               retry_ledger,
               candidate(correlation_id: "retry-after-backoff"),
               now: "2026-06-27T11:06:00Z"
             )

    [project] = RuntimeLedger.replay(dispatched_ledger).projects
    assert project.counts.claimed == 1
    assert [%{attempt_id: attempt_id}] = project.active_attempts
    assert attempt_id == retry_context.attempt_id
  end

  test "acknowledged start updates run context without leaking secrets" do
    assert {:ok, ledger, context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate())

    assert {:ok, ledger} =
             DispatchBoundary.acknowledge_start(ledger, %{
               project_id: context.project_id,
               issue_key: context.issue_key,
               attempt_id: context.attempt_id,
               start_intent_id: context.start_intent_id,
               session_id: "session-alpha",
               worker_host: "worker-1",
               usage: %{input_tokens: 10, token: "github_pat_secret"}
             })

    snapshot = RuntimeLedger.to_snapshot(ledger)
    [project] = snapshot.projects
    [issue] = project.issues
    [attempt] = issue.attempts

    assert attempt.status == :running
    assert issue.claim_status == :running
    assert attempt.agent_session.session_id == "session-alpha"
    assert attempt.agent_session.usage == %{"input_tokens" => 10}
    assert attempt.run_context.session_id == "session-alpha"
    assert attempt.run_context.status == "running"

    assert [alpha_project] = RuntimeLedger.replay(ledger, project_id: "alpha").projects
    assert alpha_project.project_id == "alpha"
    assert alpha_project.counts.running == 1
    assert [%{status: :running, attempt_id: attempt_id}] = alpha_project.active_issues
    assert attempt_id == context.attempt_id
    assert RuntimeLedger.replay(ledger, project_id: "missing").projects == []

    safe_text = inspect(snapshot)
    refute safe_text =~ "github_pat_secret"
    refute safe_text =~ "api_key"
    refute safe_text =~ ":token"
    refute safe_text =~ "\"token\""
    refute safe_text =~ "credential"
    refute safe_text =~ "cookie"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "transcript"
    refute safe_text =~ "raw_config"
  end

  test "run context and snapshot reject raw secret-bearing config or prompt data" do
    unsafe =
      candidate(
        tracker: %{kind: "github", api_key: "$GITHUB_TOKEN"},
        runtime_identity: %{host: "worker-1", credential: "secret"},
        start_command_summary: %{runner: "codex", prompt: "full prompt should not be here"}
      )

    assert {:ok, ledger, _context} = DispatchBoundary.dispatch(RuntimeLedger.new(), unsafe)
    snapshot = RuntimeLedger.to_snapshot(ledger)

    safe_text = inspect(snapshot)
    refute safe_text =~ "$GITHUB_TOKEN"
    refute safe_text =~ "credential"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "api_key"

    assert {:error, diagnostics} =
             RuntimeLedger.from_snapshot(%{
               "version" => 1,
               "projects" => [
                 %{
                   "project_id" => "alpha",
                   "start_intents" => [%{"intent_id" => "i", "token" => "ghp_supersecret"}]
                 }
               ]
             })

    assert Enum.any?(diagnostics, &(&1.code == :sensitive_ledger_snapshot_field))
  end

  test "map issue refs must include provider scope and issue identity" do
    assert {:error, :issue_ref_missing_provider_scope} =
             DispatchBoundary.build_context(
               candidate(issue_ref: %{project_id: "alpha", provider_issue_id: "123"}),
               RuntimeLedger.new()
             )

    assert {:error, :issue_ref_missing_provider_issue_identity} =
             DispatchBoundary.build_context(
               candidate(issue_ref: %{project_id: "alpha", provider_scope_key: "github:jhihjian/symphony"}),
               RuntimeLedger.new()
             )
  end

  test "legacy single project snapshot shape remains compatible when Hub boundary is unused" do
    ledger =
      RuntimeLedger.new(
        projects: [
          %{
            project_id: "alpha",
            issues: [
              %{
                issue_ref: issue_ref("alpha", "github", "github:jhihjian/symphony", "123", "jhihjian/symphony#123"),
                claim_status: :running,
                attempts: [%{attempt_id: "legacy-attempt", status: :running}]
              }
            ],
            workspace_leases: [
              %{
                issue_key: "alpha:github:jhihjian/symphony:123",
                attempt_id: "legacy-attempt",
                workspace_path: "/workspaces/alpha/legacy",
                status: :active
              }
            ]
          }
        ]
      )

    snapshot = RuntimeLedger.to_snapshot(ledger)
    assert [project] = snapshot.projects
    assert project.start_intents == []
    assert [issue] = project.issues
    assert [attempt] = issue.attempts
    assert attempt.run_context == nil
  end

  test "observability payload exposes safe Hub dispatch boundary snapshot when present" do
    assert {:ok, ledger, _context} = DispatchBoundary.dispatch(RuntimeLedger.new(), candidate())
    orchestrator_name = Module.concat(__MODULE__, :StaticHubDispatchSnapshot)

    start_supervised!(
      {StaticHubOrchestrator,
       name: orchestrator_name,
       snapshot: %{
         running: [],
         retrying: [],
         blocked: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         hub_dispatch_boundary: ledger
       }}
    )

    payload = Presenter.state_payload(orchestrator_name, 50)
    assert [project] = payload.hub_dispatch_boundary.projects
    assert project.project_id == "alpha"
    assert [%{status: :pending}] = project.pending_start_intents

    safe_text = inspect(payload)
    refute safe_text =~ "TOKEN"
    refute safe_text =~ "api_key"
    refute safe_text =~ "credential"
    refute safe_text =~ "secret"
    refute safe_text =~ "prompt"
    refute safe_text =~ "transcript"
  end

  defp candidate(overrides \\ []) do
    ref =
      Keyword.get(
        overrides,
        :issue_ref,
        issue_ref("alpha", "github", "github:jhihjian/symphony", "123", "jhihjian/symphony#123")
      )

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
      correlation_id: "correlation-1",
      workspace_path: "/workspaces/alpha/shared",
      worker_host: "worker-1",
      runtime_identity: %{host: "worker-1", os: "linux"},
      runner: "codex",
      start_command_summary: %{runner: "codex", argv: ["codex", "exec"], env: ["CODEX_HOME"]}
    }
    |> Map.merge(Map.new(overrides))
  end

  defp issue_ref(project_id, tracker_kind, provider_scope_key, provider_issue_id, identifier) do
    %IssueRef{
      project_id: project_id,
      tracker_kind: tracker_kind,
      provider_scope: provider_scope(tracker_kind, provider_scope_key),
      provider_scope_key: provider_scope_key,
      provider_issue_id: provider_issue_id,
      provider_local_id: identifier,
      identifier: identifier,
      url: "https://example.test/#{provider_issue_id}"
    }
  end

  defp provider_scope("github", "github:" <> owner_repo) do
    [owner, repo] = String.split(owner_repo, "/", parts: 2)
    %{owner: owner, repo: repo}
  end

  defp project_with_active_lease(project_id, issue_id, workspace_path) do
    attempt_id = "attempt-#{project_id}-#{issue_id}"
    issue_ref = issue_ref(project_id, "github", "github:jhihjian/symphony", issue_id, "jhihjian/symphony##{issue_id}")
    issue_key = RuntimeLedger.issue_key(issue_ref)

    %{
      project_id: project_id,
      issues: [
        %{
          issue_ref: issue_ref,
          claim_status: :claimed,
          attempts: [
            %{
              attempt_id: attempt_id,
              attempt_number: 1,
              status: :pending,
              workspace_path: workspace_path
            }
          ]
        }
      ],
      workspace_leases: [
        %{
          issue_key: issue_key,
          attempt_id: attempt_id,
          workspace_path: workspace_path,
          status: :active
        }
      ]
    }
  end
end
