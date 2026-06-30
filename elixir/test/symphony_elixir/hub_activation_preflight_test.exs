defmodule SymphonyElixir.HubActivationPreflightTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.ActivationPreflight

  test "allows explicit hub managed project when injected probe has no legacy ownership" do
    summary =
      ActivationPreflight.build(
        registry([project("alpha", migration_state: "hub_managed")]),
        now: ~U[2026-06-30 02:00:00Z],
        probe: %{
          source: "unit-test",
          projects: %{
            "alpha" => %{
              legacy_service: %{service: "symphony@alpha.service", active: false, enabled: false},
              provider_scope_owners: [],
              workspace_owners: [],
              port_owners: []
            }
          }
        }
      )

    assert summary.status == "safe_to_manage"
    assert summary.counts.safe_count == 1
    assert [alpha] = summary.projects
    assert alpha.project_id == "alpha"
    assert alpha.migration_state == "hub_managed"
    assert alpha.status == "safe_to_manage"
    assert alpha.safe_to_manage == true
    assert alpha.blocked_operations == []
    assert ActivationPreflight.safe_to_manage?(summary, "alpha", :poll)
    assert ActivationPreflight.safe_to_manage?(summary, "alpha", "worker-start")
  end

  test "blocks legacy service provider workspace runtime and port ownership conflicts" do
    summary =
      ActivationPreflight.build(
        registry([project("alpha", migration_state: "hub_managed")]),
        now: ~U[2026-06-30 02:00:00Z],
        probe: %{
          source: "systemd-test",
          projects: %{
            "alpha" => %{
              legacy_service: %{service: "symphony@alpha.service", active: true},
              provider_scope_owners: [%{provider_scope_key: "github:o/r", owner: "legacy-poll", token: "ghp_secret"}],
              workspace_owners: [%{workspace_root: "/private/workspaces/alpha", owner: "legacy-worker"}],
              runtime_path_owners: [%{project_id: "alpha", runtime_path: "/private/state/alpha.json"}],
              log_path_owners: [%{project_id: "alpha", log_path: "/private/logs/alpha.log"}],
              state_path_owners: [%{project_id: "alpha", state_path: "/private/state/alpha.state"}],
              port_owners: [%{port: 20_001, service: "symphony@alpha.service"}]
            }
          }
        }
      )

    assert summary.status == "blocked_conflict"
    assert [alpha] = summary.projects
    assert alpha.status == "blocked_conflict"
    assert alpha.safe_to_manage == false
    assert alpha.blocked_operations == ["poll", "dispatch", "worker_start", "writeback"]
    assert alpha.conflict_count >= 7

    sources = Enum.map(alpha.detected_legacy_ownership, & &1.source)
    assert "legacy_service" in sources
    assert "provider_scope_owner" in sources
    assert "workspace_owner" in sources
    assert "runtime_path_owner" in sources
    assert "log_path_owner" in sources
    assert "state_path_owner" in sources
    assert "dashboard_port_owner" in sources

    refute ActivationPreflight.safe_to_manage?(summary, "alpha", :poll)

    assert %{reason: "legacy_ownership_conflict", blocked_operations: ["poll", "dispatch", "worker_start", "writeback"]} =
             ActivationPreflight.block_reason(summary, "alpha", :writeback)

    safe_text = inspect(summary)
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "/private/workspaces/alpha"
    refute safe_text =~ "/private/state/alpha.json"
    refute safe_text =~ "/private/logs/alpha.log"
  end

  test "unknown probe result requires manual attention without dynamic atom creation" do
    unknown_keys =
      Enum.map(1..150, fn index ->
        "future_probe_key_#{System.unique_integer([:positive])}_#{index}"
      end)

    project =
      project("alpha", migration_state: "hub_managed")
      |> Jason.encode!()
      |> Jason.decode!()
      |> Map.merge(Map.new(unknown_keys, &{&1, "visible"}))

    probe =
      %{
        "source" => "json-test",
        "projects" => %{
          "alpha" => %{
            "status" => "unknown",
            "legacy_service" => %{"active" => "unknown", "authorization" => "Bearer secret"}
          }
        }
      }
      |> Jason.encode!()
      |> Jason.decode!()

    atom_count_before = :erlang.system_info(:atom_count)
    assert {:ok, summary} = ActivationPreflight.from_snapshot(ActivationPreflight.build(%{"projects" => [project]}, probe: probe))
    assert :erlang.system_info(:atom_count) - atom_count_before < 50

    assert [alpha] = summary.projects
    assert alpha.status == "unknown_manual_attention"
    assert alpha.unknown_probe_results != []
    assert alpha.blocked_operations == ["poll", "dispatch", "worker_start", "writeback"]

    safe_text = inspect(summary)
    refute safe_text =~ "Bearer secret"
    refute safe_text =~ "authorization"
  end

  test "conflicts are isolated per project" do
    summary =
      ActivationPreflight.build(
        registry([
          project("alpha", migration_state: "hub_managed"),
          project("beta", migration_state: "hub_managed", scope_key: "github:o/beta", workspace_root: "/workspaces/beta", port: 20_002)
        ]),
        probe: %{
          projects: %{
            "alpha" => %{legacy_service: %{service: "symphony@alpha.service", active: true}},
            "beta" => %{legacy_service: %{service: "symphony@beta.service", active: false, enabled: false}}
          }
        }
      )

    projects = Map.new(summary.projects, &{&1.project_id, &1})
    assert projects["alpha"].status == "blocked_conflict"
    assert projects["beta"].status == "safe_to_manage"
    refute ActivationPreflight.safe_to_manage?(summary, "alpha", :dispatch)
    assert ActivationPreflight.safe_to_manage?(summary, "beta", :dispatch)
  end

  defp registry(projects), do: %{projects: projects, warnings: [], errors: []}

  defp project(project_id, opts) do
    scope_key = Keyword.get(opts, :scope_key, "github:o/r")
    migration_state = Keyword.get(opts, :migration_state, "hub_ready")
    workspace_root = Keyword.get(opts, :workspace_root, "/private/workspaces/#{project_id}")
    port = Keyword.get(opts, :port, 20_001)

    %{
      project_id: project_id,
      name: String.capitalize(project_id),
      migration_state: migration_state,
      dispatch_enabled: true,
      paused: false,
      status: :ready,
      workflow_path: "/private/#{project_id}/WORKFLOW.md",
      tracker_config_path: "/private/#{project_id}/TRACKER.yaml",
      tracker_summary: %{
        kind: "github",
        provider_scope_key: scope_key,
        provider_scope: %{owner: "o", repo: "r"},
        required_labels: ["symphony"]
      },
      runtime_summary: %{
        workspace_root: workspace_root,
        runtime_state_path: "/private/state/#{project_id}.json",
        log_path: "/private/logs/#{project_id}.log",
        max_concurrent_agents: 2,
        max_concurrent_agents_by_state: %{},
        polling_interval_ms: 30_000,
        server_port: port
      },
      fingerprint: "#{project_id}-fp",
      loaded_at: ~U[2026-06-30 01:59:00Z],
      load_error: nil
    }
  end
end
