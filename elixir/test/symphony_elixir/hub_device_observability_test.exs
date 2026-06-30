defmodule SymphonyElixir.HubDeviceObservabilityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.DeviceObservability
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

  test "builds a safe device projection across running backoff manual attention and legacy projects" do
    projection =
      DeviceObservability.build(
        %{
          registry: registry(),
          poll_coordination: poll_coordination(),
          runtime_ledger: runtime_ledger(),
          scheduler: scheduler(),
          tick: tick(),
          candidate_intake: candidate_intake(),
          dispatch_planning: dispatch_planning(),
          dispatch_plan_application: dispatch_plan_application(),
          worker_start_handoff: worker_start_handoff(),
          worker_lifecycle_reconciliation: worker_lifecycle_reconciliation(),
          legacy_projects: [%{project_id: "legacy", name: "Legacy project", service: "symphony@legacy.service"}],
          migration_boundary: %{
            direct_path_capabilities: ["legacy_poll_loop", "legacy_direct_writeback"],
            opt_in_hub_capabilities: ["provider_tool_routing", "writeback_processor"]
          }
        },
        now: ~U[2026-06-28 09:00:00Z],
        max_agent_capacity: 6
      )

    assert projection.device == %{
             project_count: 4,
             active_agent_count: 1,
             max_agent_capacity: 6,
             provider_scopes_count: 2
           }

    assert projection.overview.scheduler.enabled == true
    assert projection.overview.scheduler.status == "scheduled"
    assert projection.overview.scheduler.next_reason == "runtime_reconciliation"
    assert projection.overview.project_status_counts.running == 1
    assert projection.overview.project_status_counts.backoff == 1
    assert projection.overview.project_status_counts.manual_attention == 1
    assert projection.overview.provider_governance.queue_pressure_count > 0
    assert projection.overview.provider_governance.quota_backoff_count > 0
    assert projection.overview.capacity_workspace.active_attempt_count == 1
    assert projection.overview.capacity_workspace.pending_start_intent_count == 1
    assert projection.overview.writeback.counts.unknown == 1
    assert projection.overview.writeback.manual_attention_count == 1
    assert projection.overview.lifecycle.unresolved_count >= 1
    assert projection.overview.manual_attention.project_count == 1

    assert projection.migration_boundary.legacy_service == "symphony@project.service"
    assert projection.migration_boundary.hub_projection_model_only == true
    assert projection.migration_boundary.hub_takes_over_legacy_poll_loop == false
    assert projection.migration_boundary.hub_routing_requires_opt_in == true

    projects = Map.new(projection.projects, &{&1.project_id, &1})

    assert projects["alpha"].status == "running"
    assert projects["alpha"].runtime.counts.running == 1
    assert [%{"issue_key" => "alpha:github:o/r:1"}] = projects["alpha"].runtime.workspace_leases
    assert "active_attempt_exists" in reason_names(projects["alpha"])
    assert "workspace_occupied" in reason_names(projects["alpha"])
    assert projects["alpha"].detail.identity.provider_scope_key == "github:o/r"
    assert projects["alpha"].detail.config.snapshot_version == "1"
    assert projects["alpha"].detail.candidate_intake.counts["candidate_count"] == 1
    assert projects["alpha"].detail.dispatch_application.counts["applied_count"] == 1
    assert projects["alpha"].detail.worker_start.counts["selected_count"] == 1
    assert projects["alpha"].detail.lifecycle.counts.running == 1

    assert projects["beta"].status == "backoff"
    assert projects["beta"].poll.backoff_until == "2026-06-28T09:05:00Z"
    assert projects["beta"].provider_queue.provider_scopes != []
    assert Enum.member?(reason_names(projects["beta"]), "provider_rate_limit")
    assert Enum.member?(reason_names(projects["beta"]), "queue_pressure")
    assert projects["beta"].detail.poll_eligibility.reason == "rate_limited"

    assert projects["gamma"].status == "manual_attention"
    assert projects["gamma"].writebacks.counts.unknown == 1
    assert projects["gamma"].writebacks.counts.manual_attention == 1
    assert Enum.member?(reason_names(projects["gamma"]), "writeback_unknown")
    assert Enum.member?(reason_names(projects["gamma"]), "manual_attention")

    assert projects["legacy"].status == "legacy_only"
    assert projects["legacy"].migration_state == "legacy_only"

    aggregate_reasons = Enum.map(projection.backpressure_reasons, & &1.reason)
    assert "provider_rate_limit" in aggregate_reasons
    assert "workspace_occupied" in aggregate_reasons
    assert "writeback_unknown" in aggregate_reasons
    assert "manual_attention" in aggregate_reasons
  end

  test "accepts string-key snapshots and redacts sensitive fields without dynamic atom keys" do
    projection =
      %{
        "version" => 1,
        "generated_at" => "2026-06-28T09:00:00Z",
        "device" => %{"project_count" => 1},
        "projects" => [
          %{
            "project_id" => "alpha",
            "name" => "Alpha",
            "status" => "manual_attention",
            "migration_state" => "hub_managed",
            "dispatch_enabled" => true,
            "provider" => %{
              "kind" => "github",
              "provider_scope_key" => "github:o/r",
              "scope" => %{
                "owner" => "o",
                "repo" => "r",
                "token" => "$GITHUB_TOKEN",
                "future_unknown_key_that_must_stay_string" => "visible"
              }
            },
            "poll" => %{
              "allow_poll" => false,
              "eligibility" => %{"reason" => "rate_limited", "authorization" => "Bearer supersecret"},
              "governance" => %{"request" => %{"request_id" => "r1", "prompt" => "full prompt should not leak"}}
            },
            "provider_queue" => %{
              "provider_scopes" => [
                %{"provider_scope_key" => "github:o/r", "state" => %{"quota" => %{"remaining" => 0, "cookie" => "session=secret"}}}
              ]
            },
            "runtime" => %{
              "active_attempts" => [
                %{"attempt_id" => "attempt-1", "run_context" => %{"transcript" => "full Codex transcript", "session_id" => "s1"}}
              ]
            },
            "writebacks" => %{
              "unknown" => [
                %{
                  "intent_key" => "i1",
                  "target" => %{
                    "comment_body" => "comment body should be hashed",
                    "raw_config" => %{"api_key" => "ghp_supersecret"}
                  }
                }
              ],
              "manual_attention" => []
            },
            "backpressure_reasons" => [
              %{"reason" => "writeback_unknown", "source" => "runtime_ledger", "project_id" => "alpha"}
            ],
            "raw_config" => %{"secret_env" => "TOKEN"}
          }
        ],
        "provider_queue" => %{
          "pending" => [%{"project_id" => "alpha", "api_key" => "ghp_supersecret"}]
        }
      }

    assert {:ok, safe_projection} = DeviceObservability.from_snapshot(projection)

    assert [project] = safe_projection.projects
    assert project.provider.scope["future_unknown_key_that_must_stay_string"] == "visible"
    refute Map.has_key?(project.provider.scope, "token")
    assert project.provider.scope |> Map.keys() |> Enum.all?(&is_binary/1)

    [writeback] = project.writebacks.unknown
    assert is_binary(writeback["target"]["comment_body_sha256"])
    assert writeback["target"]["comment_body_bytes"] == 29
    refute Map.has_key?(writeback["target"], "comment_body")

    safe_text = inspect(safe_projection)
    refute safe_text =~ "$GITHUB_TOKEN"
    refute safe_text =~ "Bearer supersecret"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "full Codex transcript"
    refute safe_text =~ "comment body should be hashed"
    refute safe_text =~ "ghp_supersecret"
    refute safe_text =~ "raw_config"
    refute safe_text =~ "api_key"
    refute safe_text =~ "cookie"
  end

  test "isolates a single project summary error and keeps other projects readable" do
    projection =
      DeviceObservability.build(
        %{
          registry: %{
            projects: [
              registry_project("alpha", "github:o/r"),
              registry_project("broken", "github:o/r")
              |> Map.put(:summary_error, %{code: "summary_build_failed", message: "raw stacktrace should not leak"})
            ],
            warnings: [],
            errors: []
          },
          poll_coordination: poll_coordination(),
          runtime_ledger: runtime_ledger()
        },
        now: ~U[2026-06-28 09:00:00Z]
      )

    projects = Map.new(projection.projects, &{&1.project_id, &1})

    assert projects["alpha"].status == "running"
    assert projects["broken"].status == "manual_attention"
    assert projects["broken"].summary_error.code == "summary_build_failed"
    assert "summary_error" in reason_names(projects["broken"])
    assert projection.overview.manual_attention.project_count >= 1
    assert [%{"code" => "summary_build_failed"}] = projection.overview.summary_errors

    safe_text = inspect(projection)
    refute safe_text =~ "raw stacktrace"
    refute safe_text =~ "stacktrace should not leak"
  end

  test "observability presenter exposes hub device projection when present and preserves legacy shape otherwise" do
    projection =
      DeviceObservability.build(
        %{
          registry: registry(),
          poll_coordination: poll_coordination(),
          runtime_ledger: runtime_ledger()
        },
        now: ~U[2026-06-28 09:00:00Z]
      )

    with_hub = Module.concat(__MODULE__, :StaticHubDeviceSnapshot)

    start_supervised!(
      {StaticHubOrchestrator,
       name: with_hub,
       snapshot: %{
         running: [],
         retrying: [],
         blocked: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         hub_device_observability: projection
       }},
      id: :hub_device_observability_snapshot
    )

    payload = Presenter.state_payload(with_hub, 50)
    assert payload.hub_device_observability.device.project_count == 3
    assert payload.hub_device_observability.overview.project_status_counts.running == 1
    assert Enum.any?(payload.hub_device_observability.projects, &(&1.project_id == "alpha"))

    legacy_only = Module.concat(__MODULE__, :StaticLegacySnapshot)

    start_supervised!(
      {StaticHubOrchestrator,
       name: legacy_only,
       snapshot: %{
         running: [],
         retrying: [],
         blocked: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }},
      id: :legacy_without_device_observability_snapshot
    )

    legacy_payload = Presenter.state_payload(legacy_only, 50)
    refute Map.has_key?(legacy_payload, :hub_device_observability)
  end

  defp reason_names(project) do
    project.backpressure_reasons
    |> Enum.map(& &1.reason)
    |> Enum.sort()
  end

  defp registry do
    %{
      projects: [
        registry_project("alpha", "github:o/r"),
        registry_project("beta", "github:o/r"),
        registry_project("gamma", "gitlab:g/p", max_concurrent_agents: 1)
      ],
      warnings: [],
      errors: []
    }
  end

  defp registry_project(project_id, scope_key, opts \\ []) do
    kind = scope_key |> String.split(":", parts: 2) |> List.first()

    %{
      project_id: project_id,
      name: String.capitalize(project_id),
      dispatch_enabled: true,
      paused: false,
      status: :ready,
      tracker_summary: %{
        kind: kind,
        provider_scope_key: scope_key,
        provider_scope: provider_scope(kind, scope_key),
        required_labels: ["symphony"]
      },
      runtime_summary: %{
        workspace_root: "/workspaces/#{project_id}",
        max_concurrent_agents: Keyword.get(opts, :max_concurrent_agents, 2),
        max_concurrent_agents_by_state: %{},
        polling_interval_ms: 30_000,
        server_port: nil
      },
      fingerprint: "#{project_id}-fingerprint",
      loaded_at: ~U[2026-06-28 08:55:00Z],
      load_error: nil
    }
  end

  defp poll_coordination do
    %{
      version: 1,
      generated_at: "2026-06-28T09:00:00Z",
      registry: %{project_count: 3},
      poll_order: ["alpha"],
      projects: [
        %{
          project_id: "alpha",
          allow_poll: true,
          eligibility: %{"eligible?" => true, reason: "ready", message: nil},
          provider_scope_key: "github:o/r",
          tracker_identity: %{kind: "github", provider_scope_key: "github:o/r"},
          next_due_at: "2026-06-28T09:00:00Z"
        },
        %{
          project_id: "beta",
          allow_poll: false,
          eligibility: %{"eligible?" => false, reason: "rate_limited", message: "rate_limited until 2026-06-28T09:05:00Z"},
          provider_scope_key: "github:o/r",
          tracker_identity: %{kind: "github", provider_scope_key: "github:o/r"},
          backoff_until: "2026-06-28T09:05:00Z",
          governance: %{backpressure: %{reason: "rate_limited", provider_scope_key: "github:o/r"}}
        },
        %{
          project_id: "gamma",
          allow_poll: false,
          eligibility: %{"eligible?" => false, reason: "not_due", message: nil},
          provider_scope_key: "gitlab:g/p",
          tracker_identity: %{kind: "gitlab", provider_scope_key: "gitlab:g/p"}
        }
      ],
      provider_queue: provider_queue()
    }
  end

  defp provider_queue do
    %{
      pending_count: 1,
      running_count: 1,
      provider_scopes: [
        %{
          provider_scope_key: "github:o/r",
          running_count: 1,
          pending_count: 1,
          state: %{
            provider_kind: "github",
            provider_scope_key: "github:o/r",
            quota: %{remaining: 0, limit: 5_000, reset_at: "2026-06-28T10:00:00Z"},
            backoff_until: "2026-06-28T09:05:00Z",
            circuit_state: "closed",
            last_error_class: "rate_limited"
          }
        }
      ],
      pending: [
        %{
          request_id: "beta-request",
          project_id: "beta",
          provider_scope_key: "github:o/r",
          operation_kind: "candidate_scan",
          backpressure: %{reason: "rate_limited"}
        }
      ],
      running: [
        %{request_id: "alpha-request", project_id: "alpha", provider_scope_key: "github:o/r", operation_kind: "candidate_scan"}
      ],
      recent_results: [
        %{request_id: "beta-previous-request", project_id: "beta", provider_scope_key: "github:o/r", status: "rate_limited"}
      ],
      backpressure: [
        %{request_id: "beta-request", project_id: "beta", provider_scope_key: "github:o/r", reason: "rate_limited"}
      ]
    }
  end

  defp runtime_ledger do
    %{
      version: 1,
      generated_at: "2026-06-28T09:00:00Z",
      projects: [
        %{
          project_id: "alpha",
          counts: %{running: 1},
          active_attempts: [
            %{
              issue_key: "alpha:github:o/r:1",
              attempt_id: "alpha-attempt-1",
              status: :running,
              workspace_path: "/workspaces/alpha/1"
            }
          ],
          workspace_leases: [
            %{issue_key: "alpha:github:o/r:1", attempt_id: "alpha-attempt-1", workspace_path: "/workspaces/alpha/1", status: :active}
          ],
          pending_start_intents: [],
          retry_backoff: [],
          blocked_candidates: [],
          writebacks: %{counts: %{pending: 0, succeeded: 0, failed: 0, unknown: 0, manual_attention: 0}},
          lifecycle: %{
            counts: %{running: 1}
          },
          conflicts: [],
          manual_attention: []
        },
        %{
          project_id: "beta",
          counts: %{retry: 1},
          active_attempts: [],
          workspace_leases: [],
          pending_start_intents: [],
          retry_backoff: [
            %{issue_key: "beta:github:o/r:2", attempt_id: "beta-attempt-1", due_at: "2026-06-28T09:05:00Z", error_summary: "provider rate limit"}
          ],
          blocked_candidates: [],
          writebacks: %{counts: %{pending: 0, succeeded: 0, failed: 0, unknown: 0, manual_attention: 0}},
          conflicts: [],
          manual_attention: []
        },
        %{
          project_id: "gamma",
          counts: %{manual_attention: 1},
          active_attempts: [],
          workspace_leases: [],
          pending_start_intents: [
            %{issue_key: "gamma:gitlab:g/p:3", attempt_id: "gamma-attempt-1", intent_id: "start-1", status: :unknown, manual_attention: true}
          ],
          retry_backoff: [],
          blocked_candidates: [],
          writebacks: %{
            counts: %{pending: 0, succeeded: 0, failed: 0, unknown: 1, manual_attention: 1},
            unknown: [
              %{
                issue_key: "gamma:gitlab:g/p:3",
                intent_key: "gamma-writeback-1",
                logical_action: "comment_append",
                result_status: "unknown",
                target: %{issue_id: "3"}
              }
            ],
            manual_attention: [
              %{
                issue_key: "gamma:gitlab:g/p:3",
                intent_key: "gamma-writeback-1",
                manual_attention_reason: "unknown_append_comment_requires_manual_attention",
                target: %{issue_id: "3"}
              }
            ]
          },
          lifecycle: %{
            counts: %{unknown: 1, manual_attention: 1},
            unresolved: [%{issue_key: "gamma:gitlab:g/p:3", status: "unknown"}],
            manual_attention: [%{issue_key: "gamma:gitlab:g/p:3", status: "manual_attention"}]
          },
          conflicts: [],
          manual_attention: [
            %{level: :warning, code: :writeback_unknown_manual_attention, project_id: "gamma", issue_key: "gamma:gitlab:g/p:3"}
          ]
        }
      ]
    }
  end

  defp scheduler do
    %{
      enabled: true,
      status: "scheduled",
      queued: true,
      coalesced: false,
      next_tick_at: "2026-06-28T09:00:01Z",
      next_reason: "runtime_reconciliation",
      counts: %{run_count: 1, coalesced_count: 0, skipped_count: 0, error_count: 0},
      unresolved_runtime: %{active_attempt_count: 1, pending_start_intent_count: 1, manual_attention_count: 1}
    }
  end

  defp tick do
    %{
      status: "completed",
      reason: "manual_refresh",
      selected_count: 1,
      operations: ["hub_poll_plan", "hub_candidate_intake", "hub_device_observability"]
    }
  end

  defp candidate_intake do
    %{
      version: 1,
      generated_at: "2026-06-28T09:00:00Z",
      status: "completed",
      counts: %{candidate_count: 1, eligible_count: 1, skipped_count: 0, invalid_count: 0},
      skipped_reasons: %{},
      projects: [
        %{
          project_id: "alpha",
          provider_kind: "github",
          provider_scope_key: "github:o/r",
          counts: %{candidate_count: 1, eligible_count: 1, skipped_count: 0, invalid_count: 0},
          skipped_reasons: %{},
          candidates: [%{issue_key: "alpha:github:o/r:1", status: "ready_for_dispatch_evaluation"}],
          invalid_candidates: []
        }
      ]
    }
  end

  defp dispatch_planning do
    %{
      version: 1,
      generated_at: "2026-06-28T09:00:00Z",
      status: "completed",
      counts: %{planned_count: 1, pending_intent_count: 1},
      skipped_reasons: %{},
      projects: [
        %{
          project_id: "alpha",
          provider_kind: "github",
          provider_scope_key: "github:o/r",
          counts: %{planned_count: 1, pending_intent_count: 1},
          skipped_reasons: %{},
          outcomes: [%{status: "planned", issue_key: "alpha:github:o/r:1"}],
          pending_intents: [%{intent_id: "intent-1", project_id: "alpha", issue_key: "alpha:github:o/r:1", status: "pending"}]
        }
      ],
      pending_intents: [%{intent_id: "intent-1", project_id: "alpha", issue_key: "alpha:github:o/r:1", status: "pending"}]
    }
  end

  defp dispatch_plan_application do
    %{
      version: 1,
      generated_at: "2026-06-28T09:00:00Z",
      status: "completed",
      counts: %{selected_count: 1, applied_count: 1, pending_start_intent_count: 1},
      reason_counts: %{},
      projects: [
        %{
          project_id: "alpha",
          provider_kind: "github",
          provider_scope_key: "github:o/r",
          counts: %{selected_count: 1, applied_count: 1, pending_start_intent_count: 1},
          reason_counts: %{},
          outcomes: [%{status: "applied", issue_key: "alpha:github:o/r:1", intent_id: "intent-1"}],
          pending_start_intents: [%{intent_id: "intent-1", project_id: "alpha", issue_key: "alpha:github:o/r:1", status: "pending"}]
        }
      ],
      pending_start_intents: [%{intent_id: "intent-1", project_id: "alpha", issue_key: "alpha:github:o/r:1", status: "pending"}]
    }
  end

  defp worker_start_handoff do
    %{
      version: 1,
      generated_at: "2026-06-28T09:00:00Z",
      status: "completed",
      counts: %{selected_count: 1, acked_count: 1, unresolved_start_intent_count: 0},
      reason_counts: %{},
      results: [%{project_id: "alpha", issue_key: "alpha:github:o/r:1", start_intent_id: "intent-1", status: "ack"}],
      pending_start_intents: []
    }
  end

  defp worker_lifecycle_reconciliation do
    %{
      version: 1,
      generated_at: "2026-06-28T09:00:00Z",
      status: "completed",
      counts: %{selected_count: 1, running_count: 1, unresolved_count: 0},
      reason_counts: %{},
      workspace_action_counts: %{},
      results: [%{project_id: "alpha", issue_key: "alpha:github:o/r:1", attempt_id: "alpha-attempt-1", status: "running"}]
    }
  end

  defp provider_scope("github", "github:" <> owner_repo) do
    [owner, repo] = String.split(owner_repo, "/", parts: 2)
    %{owner: owner, repo: repo}
  end

  defp provider_scope("gitlab", "gitlab:" <> project_slug), do: %{project_slug: project_slug}
end
