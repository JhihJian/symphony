defmodule SymphonyElixir.HubPollCoordinatorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.PollCoordinator
  alias SymphonyElixir.Hub.ProviderGovernance
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

  test "builds provider-neutral poll plan and rotates same-scope project fairness" do
    now = ~U[2026-06-27 10:00:00Z]

    last_alpha_poll =
      PollCoordinator.result_fact(
        %{
          project_id: "alpha",
          provider_kind: "github",
          provider_scope_key: "github:jhihjian/symphony",
          request_id: "alpha-previous-request",
          operation_kind: :candidate_scan
        },
        :success,
        finished_at: ~U[2026-06-27 09:59:00Z],
        poll_interval_ms: 30_000
      )

    plan =
      registry([
        ready_project("alpha", github_scope(), poll_interval_ms: 30_000),
        ready_project("beta", github_scope(), poll_interval_ms: 30_000),
        error_project("broken")
      ])
      |> PollCoordinator.build_plan(now: now, facts: [last_alpha_poll])

    assert plan.poll_order == ["beta"]

    projects = Map.new(plan.projects, &{&1.project_id, &1})

    assert projects["beta"].allow_poll == true
    assert projects["beta"].eligibility == %{eligible?: true, reason: :ready, message: nil}
    assert projects["beta"].tracker_identity.kind == "github"
    assert projects["beta"].provider_scope_key == "github:jhihjian/symphony"
    assert projects["beta"].workflow_identity.start_stage == "ready"
    assert projects["beta"].governance.request.operation_kind == "candidate_scan"
    assert projects["beta"].governance.request.replay_policy == "idempotent"
    assert projects["beta"].governance.request.correlation == %{boundary: "hub_poll_coordination", workflow_start_stage: "ready"}

    assert projects["alpha"].allow_poll == false
    assert projects["alpha"].eligibility.reason == :scope_concurrency
    assert projects["alpha"].governance.backpressure.provider_scope_key == "github:jhihjian/symphony"

    assert projects["broken"].allow_poll == false
    assert projects["broken"].eligibility.reason == :config_error
    assert projects["broken"].eligibility.message =~ "missing tracker.repo"

    assert [%{fact_type: :poll_plan}] = Enum.take(plan.facts, 1)
  end

  test "scope backoff and circuit state block only matching projects" do
    now = ~U[2026-06-27 10:00:00Z]

    queue =
      ProviderGovernance.new_queue()
      |> ProviderGovernance.update_scope_state(github_scope(), %{
        quota: %{remaining: 0, limit: 5_000, reset_at: ~U[2026-06-27 10:05:00Z], authorization: "Bearer secret"},
        backoff_until: ~U[2026-06-27 10:05:00Z],
        circuit_state: :closed,
        last_error_class: :rate_limited
      })
      |> ProviderGovernance.update_scope_state(memory_scope("local"), %{
        circuit_state: :open,
        last_error_class: :auth_config
      })

    plan =
      registry([
        ready_project("alpha", github_scope()),
        ready_project("beta", gitlab_scope()),
        ready_project("local", memory_scope("local"))
      ])
      |> PollCoordinator.build_plan(now: now, queue: queue)

    projects = Map.new(plan.projects, &{&1.project_id, &1})

    assert projects["beta"].allow_poll == true
    assert projects["beta"].eligibility.reason == :ready

    assert projects["alpha"].allow_poll == false
    assert projects["alpha"].eligibility.reason == :rate_limited
    assert projects["alpha"].backoff_until == ~U[2026-06-27 10:05:00Z]

    assert projects["local"].allow_poll == false
    assert projects["local"].eligibility.reason == :circuit_open
    assert projects["local"].governance.backpressure.error_class == :auth_config

    safe_text = inspect(PollCoordinator.to_snapshot(plan))
    refute safe_text =~ "Bearer secret"
    refute safe_text =~ "authorization"
  end

  test "poll attempt and result facts recover next due and backoff after restart" do
    started_at = ~U[2026-06-27 10:00:00Z]
    backoff_until = ~U[2026-06-27 10:02:00Z]

    first_plan =
      registry([ready_project("alpha", github_scope(), poll_interval_ms: 60_000)])
      |> PollCoordinator.build_plan(now: started_at)

    assert [entry] = first_plan.projects
    assert entry.allow_poll == true

    attempt = PollCoordinator.attempt_fact(entry, attempted_at: started_at)

    failure =
      PollCoordinator.result_fact(
        entry,
        :retryable_failure,
        attempt_id: attempt.attempt_id,
        finished_at: ~U[2026-06-27 10:00:10Z],
        backoff_until: backoff_until,
        result_summary: %{message: "provider timeout", token: "github_pat_secret"}
      )

    restarted_plan =
      registry([ready_project("alpha", github_scope(), poll_interval_ms: 60_000)])
      |> PollCoordinator.build_plan(now: ~U[2026-06-27 10:00:30Z], facts: [attempt, failure])

    assert [recovered] = restarted_plan.projects
    assert recovered.allow_poll == false
    assert recovered.eligibility.reason == :backoff
    assert recovered.backoff_until == backoff_until
    assert recovered.next_due_at == backoff_until
    assert recovered.last_poll.status == :retryable_failure

    snapshot = PollCoordinator.to_snapshot(restarted_plan)
    assert {:ok, restored_snapshot} = PollCoordinator.from_snapshot(snapshot)
    assert restored_snapshot["projects"] == nil
    assert restored_snapshot.projects |> List.first() |> Map.fetch!(:backoff_until) == "2026-06-27T10:02:00Z"

    safe_text = inspect(snapshot)
    refute safe_text =~ "github_pat_secret"
    refute safe_text =~ "token"
  end

  test "recovers atom-key plan and JSON string-key snapshots through the snapshot boundary" do
    now = ~U[2026-06-27 10:00:00Z]

    last_poll =
      PollCoordinator.result_fact(
        %{
          project_id: "alpha",
          provider_kind: "github",
          provider_scope_key: "github:jhihjian/symphony",
          request_id: "alpha-request",
          operation_kind: :candidate_scan
        },
        :success,
        finished_at: ~U[2026-06-27 09:59:00Z],
        poll_interval_ms: 30_000,
        result_summary: %{issue_count: 1}
      )

    plan =
      registry([ready_project("alpha", github_scope(), poll_interval_ms: 30_000)])
      |> PollCoordinator.build_plan(now: now, facts: [last_poll])

    assert {:ok, atom_plan_snapshot} = PollCoordinator.from_snapshot(plan)
    assert [atom_plan_project] = atom_plan_snapshot.projects
    assert atom_plan_project.project_id == "alpha"
    assert atom_plan_project.last_poll.status == "success"

    atom_snapshot = PollCoordinator.to_snapshot(plan)
    string_snapshot = atom_snapshot |> Jason.encode!() |> Jason.decode!()

    assert {:ok, restored_snapshot} = PollCoordinator.from_snapshot(string_snapshot)
    assert restored_snapshot == atom_snapshot
    assert [restored_project] = restored_snapshot.projects
    assert restored_project.allow_poll == true
    assert restored_project.eligibility == %{"eligible?" => true, reason: "ready", message: nil}
    assert restored_project.last_poll.status == "success"
    assert Enum.any?(restored_snapshot.facts, &(&1.result_summary == %{issue_count: 1}))
  end

  test "observability snapshot accepts string-key snapshots and keeps visible poll fields" do
    string_snapshot =
      %{
        version: 1,
        generated_at: ~U[2026-06-27 10:00:00Z],
        registry: %{project_count: 1},
        poll_order: ["alpha"],
        projects: [
          %{
            project_id: "alpha",
            name: "Alpha",
            project_status: :ready,
            config_fingerprint: "fp",
            snapshot_version: "sv",
            workflow_identity: %{start_stage: "ready"},
            tracker_identity: %{kind: "github", provider_scope_key: "github:o/r", required_labels: ["symphony"]},
            provider_scope: %{owner: "o", repo: "r"},
            provider_scope_key: "github:o/r",
            poll_interval_ms: 30_000,
            allow_poll: false,
            eligibility: %{eligible?: false, reason: :not_due, message: nil},
            next_due_at: ~U[2026-06-27 10:01:00Z],
            backoff_until: nil,
            last_poll: nil,
            governance: %{decision: :not_selected}
          }
        ],
        provider_queue: %{pending_count: 0},
        facts: [%{fact_type: :poll_plan, recorded_at: ~U[2026-06-27 10:00:00Z]}]
      }
      |> PollCoordinator.to_snapshot()
      |> Jason.encode!()
      |> Jason.decode!()

    assert observability = PollCoordinator.observability_snapshot(string_snapshot)
    assert observability.generated_at == "2026-06-27T10:00:00Z"
    assert observability.provider_queue.pending_count == 0
    refute Map.has_key?(observability, :facts)
    assert [project] = observability.projects
    assert project.project_id == "alpha"
    assert project.allow_poll == false
    assert project.eligibility == %{"eligible?" => false, reason: "not_due", message: nil}
    assert project.governance == %{decision: "not_selected"}
  end

  test "result facts prevent immediate all-project polling when recoverable state is replayed" do
    first_now = ~U[2026-06-27 10:00:00Z]
    restart_now = ~U[2026-06-27 10:00:10Z]

    registry =
      registry([
        ready_project("alpha", github_scope(), poll_interval_ms: 60_000),
        ready_project("beta", gitlab_scope(), poll_interval_ms: 60_000)
      ])

    first_plan = PollCoordinator.build_plan(registry, now: first_now)
    assert Enum.sort(first_plan.poll_order) == ["alpha", "beta"]

    facts =
      first_plan.projects
      |> Enum.filter(& &1.allow_poll)
      |> Enum.map(fn entry ->
        PollCoordinator.result_fact(entry, :success,
          finished_at: first_now,
          poll_interval_ms: entry.poll_interval_ms
        )
      end)

    restarted_plan = PollCoordinator.build_plan(registry, now: restart_now, facts: facts)

    assert restarted_plan.poll_order == []
    assert Enum.all?(restarted_plan.projects, &(&1.allow_poll == false))
    assert Enum.all?(restarted_plan.projects, &(&1.eligibility.reason == :not_due))

    assert Enum.map(restarted_plan.projects, &DateTime.to_iso8601(&1.next_due_at)) == [
             "2026-06-27T10:01:00.000Z",
             "2026-06-27T10:01:00.000Z"
           ]
  end

  test "observability payload exposes safe hub poll coordination status when snapshot includes it" do
    now = ~U[2026-06-27 10:00:00Z]

    plan =
      registry([ready_project("alpha", github_scope())])
      |> PollCoordinator.build_plan(now: now)

    orchestrator_name = Module.concat(__MODULE__, :StaticHubSnapshot)

    start_supervised!(
      {StaticHubOrchestrator,
       name: orchestrator_name,
       snapshot: %{
         running: [],
         retrying: [],
         blocked: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         hub_poll_coordination: plan
       }}
    )

    payload = Presenter.state_payload(orchestrator_name, 50)

    assert payload.hub_poll_coordination.generated_at == "2026-06-27T10:00:00Z"
    assert [alpha_project] = payload.hub_poll_coordination.projects
    assert %{project_id: "alpha", allow_poll: true, eligibility: %{"eligible?" => true, reason: "ready"}} = alpha_project

    safe_text = inspect(payload)
    refute safe_text =~ "TOKEN"
    refute safe_text =~ "api_key"
    refute safe_text =~ "credential"
    refute safe_text =~ "secret"
  end

  test "rejects sensitive poll coordination snapshots" do
    snapshot = %{
      "version" => 1,
      "projects" => [
        %{
          "project_id" => "alpha",
          "raw_config" => %{"tracker" => %{"api_key" => "$GITHUB_TOKEN"}},
          "provider_scope_key" => "github:jhihjian/symphony"
        }
      ]
    }

    assert {:error, diagnostics} = PollCoordinator.from_snapshot(snapshot)
    assert Enum.any?(diagnostics, &(&1.code == :sensitive_poll_coordination_snapshot_field))
  end

  test "rejects sensitive string-key snapshots with diagnostic paths and no secret leakage" do
    snapshot = %{
      "version" => 1,
      "generated_at" => "2026-06-27T10:00:00Z",
      "registry" => %{"project_count" => 1},
      "poll_order" => ["alpha"],
      "projects" => [
        %{
          "project_id" => "alpha",
          "name" => "Alpha",
          "project_status" => "ready",
          "config_fingerprint" => "fp",
          "snapshot_version" => "sv",
          "workflow_identity" => %{"start_stage" => "ready"},
          "tracker_identity" => %{"kind" => "github", "provider_scope_key" => "github:o/r", "required_labels" => ["symphony"]},
          "provider_scope" => %{"owner" => "o", "repo" => "r"},
          "provider_scope_key" => "github:o/r",
          "poll_interval_ms" => 30_000,
          "allow_poll" => true,
          "eligibility" => %{"eligible?" => true, "reason" => "ready"},
          "next_due_at" => "2026-06-27T10:00:00Z",
          "backoff_until" => nil,
          "raw_config" => %{"tracker" => %{"api_key" => "ghp_supersecret"}},
          "governance" => %{
            "request" => %{"request_id" => "r", "operation_kind" => "candidate_scan"},
            "authorization" => "Bearer supersecret",
            "transcript" => "codex transcript secret"
          }
        }
      ],
      "provider_queue" => %{"scope_states" => %{"github:o/r" => %{"cookie" => "session=supersecret"}}},
      "facts" => [
        %{
          "fact_type" => "poll_result",
          "project_id" => "alpha",
          "result_summary" => %{"prompt" => "full prompt secret"}
        }
      ]
    }

    assert {:error, diagnostics} = PollCoordinator.from_snapshot(snapshot)
    messages = Enum.map(diagnostics, & &1.message)

    assert Enum.any?(messages, &String.contains?(&1, "projects.0.raw_config"))
    assert Enum.any?(messages, &String.contains?(&1, "projects.0.raw_config.tracker.api_key"))
    assert Enum.any?(messages, &String.contains?(&1, "projects.0.governance.authorization"))
    assert Enum.any?(messages, &String.contains?(&1, "projects.0.governance.transcript"))
    assert Enum.any?(messages, &String.contains?(&1, "provider_queue.scope_states.github:o/r.cookie"))
    assert Enum.any?(messages, &String.contains?(&1, "facts.0.result_summary.prompt"))

    diagnostic_text = inspect(diagnostics)
    refute diagnostic_text =~ "ghp_supersecret"
    refute diagnostic_text =~ "Bearer supersecret"
    refute diagnostic_text =~ "session=supersecret"
    refute diagnostic_text =~ "full prompt secret"
  end

  defp registry(projects), do: %{projects: projects, warnings: [], errors: []}

  defp ready_project(project_id, provider_scope, opts \\ []) do
    %{
      project_id: project_id,
      name: String.capitalize(project_id),
      dispatch_enabled: true,
      paused: false,
      status: :ready,
      workflow_summary: %{
        start_stage: "ready",
        terminal_stages: ["done", "blocked", "protocol_blocked"],
        stage_ids: ["ready", "in_progress", "human_review", "done", "blocked", "protocol_blocked"]
      },
      tracker_summary: %{
        kind: provider_scope.kind,
        provider_scope: provider_scope.scope,
        provider_scope_key: provider_scope.key,
        required_labels: ["symphony"]
      },
      runtime_summary: %{
        workspace_root: "/workspaces/#{project_id}",
        max_concurrent_agents: 2,
        max_concurrent_agents_by_state: %{},
        polling_interval_ms: Keyword.get(opts, :poll_interval_ms, 30_000),
        server_port: nil
      },
      fingerprint: "#{project_id}-fingerprint",
      loaded_at: ~U[2026-06-27 09:55:00Z],
      load_error: nil
    }
  end

  defp error_project(project_id) do
    %{
      project_id: project_id,
      name: "Broken",
      dispatch_enabled: true,
      paused: true,
      status: :error,
      workflow_summary: nil,
      tracker_summary: nil,
      runtime_summary: nil,
      fingerprint: nil,
      loaded_at: ~U[2026-06-27 09:55:00Z],
      load_error: "Invalid TRACKER.yaml config: missing tracker.repo for GitHub"
    }
  end

  defp github_scope do
    %{kind: "github", key: "github:jhihjian/symphony", scope: %{owner: "JhihJian", repo: "symphony", project_number: 3}}
  end

  defp gitlab_scope do
    %{kind: "gitlab", key: "gitlab:platform/beta", scope: %{project_slug: "platform/beta"}}
  end

  defp memory_scope(namespace) do
    %{kind: "memory", key: "memory:#{namespace}", scope: %{namespace: namespace}}
  end
end
