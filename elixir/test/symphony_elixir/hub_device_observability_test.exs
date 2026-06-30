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
    assert projection.migration_readiness.status == "blocked"
    assert projection.activation_plan.status == "blocked"
    assert projection.activation_plan.counts.project_count == 4
    assert projection.activation_plan.counts.ack_missing_count == 4
    assert projection.activation_plan.counts.unknown_manual_attention_count >= 1
    assert projection.migration_readiness.hub_runtime.scheduler_enabled == true
    assert projection.migration_readiness.counts.project_count == 4
    assert projection.migration_readiness.counts.migration_states.legacy_only == 1
    assert projection.migration_readiness.counts.decisions.legacy_only == 1
    assert projection.migration_readiness.counts.ready_for_dry_run_count == 0
    assert projection.migration_readiness.counts.unknown_manual_attention_count >= 1
    assert Enum.any?(projection.migration_readiness.global_blocking_risks, &(&1.code == "writeback_unknown"))
    assert Enum.any?(projection.migration_readiness.global_advisory_risks, &(&1.code == "legacy_only_projects_present"))

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
    assert projects["alpha"].migration_readiness.decision == "unknown_manual_attention"
    assert projects["alpha"].activation_plan.status == "unknown_manual_attention"
    assert projects["alpha"].activation_plan.operator_acknowledgement.status == "missing"
    assert "active_attempt_exists" in readiness_reason_codes(projects["alpha"])
    assert "probe_missing" in readiness_reason_codes(projects["alpha"])
    assert "wait_or_reconcile_lifecycle" in readiness_action_codes(projects["alpha"])

    assert projects["beta"].status == "backoff"
    assert projects["beta"].poll.backoff_until == "2026-06-28T09:05:00Z"
    assert projects["beta"].provider_queue.provider_scopes != []
    assert Enum.member?(reason_names(projects["beta"]), "provider_rate_limit")
    assert Enum.member?(reason_names(projects["beta"]), "queue_pressure")
    assert projects["beta"].detail.poll_eligibility.reason == "rate_limited"
    assert projects["beta"].migration_readiness.decision == "unknown_manual_attention"
    assert "provider_rate_limit" in readiness_reason_codes(projects["beta"])
    assert "probe_missing" in readiness_reason_codes(projects["beta"])
    assert "wait_provider_backoff" in readiness_action_codes(projects["beta"])

    assert projects["gamma"].status == "manual_attention"
    assert projects["gamma"].writebacks.counts.unknown == 1
    assert projects["gamma"].writebacks.counts.manual_attention == 1
    assert Enum.member?(reason_names(projects["gamma"]), "writeback_unknown")
    assert Enum.member?(reason_names(projects["gamma"]), "manual_attention")
    assert projects["gamma"].migration_readiness.decision == "unknown_manual_attention"
    assert "writeback_unknown" in readiness_reason_codes(projects["gamma"])
    assert "resolve_writeback_manual_attention" in readiness_action_codes(projects["gamma"])

    assert projects["legacy"].status == "legacy_only"
    assert projects["legacy"].migration_state == "legacy_only"
    assert projects["legacy"].migration_readiness.decision == "legacy_only"
    assert projects["legacy"].activation_plan.proposed_next_state == "keep_legacy_only"
    assert "prepare_hub_yaml" in readiness_action_codes(projects["legacy"])

    aggregate_reasons = Enum.map(projection.backpressure_reasons, & &1.reason)
    assert "provider_rate_limit" in aggregate_reasons
    assert "workspace_occupied" in aggregate_reasons
    assert "writeback_unknown" in aggregate_reasons
    assert "manual_attention" in aggregate_reasons
  end

  test "builds ready dry-run and hub-management decisions from safe summaries" do
    projection =
      DeviceObservability.build(
        %{
          hub_runtime: %{
            read_only: true,
            provider_executor: %{mode: "skeleton", provider_io: false},
            writeback_executor: %{mode: "skeleton", provider_io: false},
            worker_starter: %{mode: "skeleton", worker_start: false},
            activation_probe: %{mode: "host_service", source: "host_service_probe", host_service_probe: true}
          },
          registry: %{
            projects: [
              registry_project("dry", "github:o/r") |> Map.put(:migration_state, "hub_ready"),
              registry_project("managed", "github:o/r") |> Map.put(:migration_state, "hub_managed")
            ],
            warnings: [],
            errors: []
          },
          poll_coordination: %{
            projects: [
              %{project_id: "dry", allow_poll: true, eligibility: %{reason: "ready"}, provider_scope_key: "github:o/r"},
              %{project_id: "managed", allow_poll: true, eligibility: %{reason: "ready"}, provider_scope_key: "github:o/r"}
            ]
          },
          activation_preflight: %{
            projects: [
              %{
                project_id: "dry",
                status: "not_hub_managed",
                safe_to_manage: false,
                reason: "migration_state_not_hub_managed",
                checked_at: "2026-06-28T09:00:00Z",
                probe_source: "host_service_probe",
                blocked_operations: [],
                detected_legacy_ownership: [],
                unknown_probe_results: []
              },
              %{
                project_id: "managed",
                status: "safe_to_manage",
                safe_to_manage: true,
                reason: "hub_managed_no_conflict",
                checked_at: "2026-06-28T09:00:00Z",
                probe_source: "host_service_probe",
                blocked_operations: [],
                detected_legacy_ownership: [],
                unknown_probe_results: []
              }
            ]
          },
          scheduler: %{enabled: false, status: "disabled"},
          runtime_ledger: %{projects: []}
        },
        now: ~U[2026-06-28 09:00:00Z]
      )

    projects = Map.new(projection.projects, &{&1.project_id, &1})

    assert projects["dry"].migration_readiness.decision == "ready_for_hub_management"
    assert projects["dry"].activation_plan.status == "ack_required"
    assert projects["dry"].activation_plan.operator_acknowledgement.status == "missing"
    assert projects["dry"].activation_plan.proposed_next_state == "operator_may_mark_hub_managed_after_checks"
    assert projects["dry"].activation_plan.plan_id == projects["dry"].migration_readiness.activation_plan.plan_id
    assert "mark_hub_managed_after_checks" in activation_ack_codes(projects["dry"])
    assert "hub_management_requires_operator_mark_hub_managed" in advisory_reason_codes(projects["dry"])
    assert "mark_hub_managed_after_checks" in readiness_action_codes(projects["dry"])
    assert projects["managed"].migration_readiness.decision == "already_hub_managed"
    assert projects["managed"].activation_plan.status == "already_managed"
    assert projects["managed"].activation_plan.operator_acknowledgement.status == "missing"
    assert projection.migration_readiness.counts.ready_for_hub_management_count == 1
    assert projection.migration_readiness.counts.decisions.already_hub_managed == 1
    assert projection.activation_plan.counts.plan_statuses.ack_required == 1
    assert projection.activation_plan.counts.plan_statuses.already_managed == 1
    assert projection.activation_plan.counts.acknowledgement_statuses.missing == 2
    assert Enum.any?(projection.migration_readiness.global_blocking_risks, &(&1.code == "scheduler_disabled"))
    assert Enum.any?(projection.migration_readiness.global_advisory_risks, &(&1.code == "provider_executor_skeleton"))

    safe_text = inspect({projection.migration_readiness, projection.activation_plan})
    refute safe_text =~ "/workspaces/dry"
    refute safe_text =~ "GITHUB_TOKEN"
  end

  test "evaluates operator acknowledgement accepted stale conflict malformed unsupported and manual attention statuses" do
    base_sources = ready_ack_sources()
    base = DeviceObservability.build(base_sources, now: ~U[2026-06-28 09:00:00Z])
    plan_id = base.projects |> Enum.find(&(&1.project_id == "dry")) |> get_in([:activation_plan, :plan_id])

    accepted =
      DeviceObservability.build(base_sources,
        now: ~U[2026-06-28 09:00:00Z],
        operator_acknowledgements: [
          %{
            project_id: "dry",
            plan_id: plan_id,
            source: "operator-file",
            created_at: "2026-06-28T09:01:00Z",
            acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"],
            note: "确认已人工检查 legacy service 和 executor mode"
          }
        ]
      )

    dry = accepted.projects |> Enum.find(&(&1.project_id == "dry"))
    assert dry.activation_plan.status == "plan_ready"
    assert dry.activation_plan.operator_acknowledgement.status == "accepted"
    assert dry.activation_plan.operator_acknowledgement.plan_id_matches == true
    refute inspect(dry.activation_plan.operator_acknowledgement) =~ "legacy service"
    assert accepted.activation_plan.counts.acknowledgement_statuses.accepted == 1

    stale =
      DeviceObservability.build(base_sources,
        now: ~U[2026-06-28 09:00:00Z],
        operator_acknowledgements: [
          %{
            project_id: "dry",
            plan_id: "old-plan",
            source: "operator-file",
            created_at: "2026-06-28T09:01:00Z",
            acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
          }
        ]
      )

    dry = stale.projects |> Enum.find(&(&1.project_id == "dry"))
    assert dry.activation_plan.status == "ack_stale"
    assert dry.activation_plan.operator_acknowledgement.status == "stale"
    assert dry.activation_plan.operator_acknowledgement.stale_reasons == ["plan_id_mismatch"]

    conflict =
      DeviceObservability.build(base_sources,
        now: ~U[2026-06-28 09:00:00Z],
        operator_acknowledgements: [
          %{
            project_id: "dry",
            plan_id: plan_id,
            source: "operator-file",
            created_at: "2026-06-28T09:01:00Z",
            provider_scope_key: "github:other/repo",
            acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
          }
        ]
      )

    dry = conflict.projects |> Enum.find(&(&1.project_id == "dry"))
    assert dry.activation_plan.status == "ack_conflict"
    assert dry.activation_plan.operator_acknowledgement.status == "conflict"
    assert dry.activation_plan.operator_acknowledgement.conflict_reasons == ["provider_scope_mismatch"]

    malformed =
      DeviceObservability.build(base_sources,
        now: ~U[2026-06-28 09:00:00Z],
        operator_acknowledgements: [%{project_id: "dry", plan_id: plan_id}]
      )

    dry = malformed.projects |> Enum.find(&(&1.project_id == "dry"))
    assert dry.activation_plan.status in ["ack_conflict", "unknown_manual_attention"]
    assert dry.activation_plan.operator_acknowledgement.status == "malformed"
    assert "source_missing" in dry.activation_plan.operator_acknowledgement.malformed_reasons

    unsupported =
      DeviceObservability.build(base_sources,
        now: ~U[2026-06-28 09:00:00Z],
        operator_acknowledgements: [
          %{
            version: 99,
            project_id: "dry",
            plan_id: plan_id,
            status: "unsupported",
            source: "operator-file",
            created_at: "2026-06-28T09:01:00Z",
            acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
          }
        ]
      )

    dry = unsupported.projects |> Enum.find(&(&1.project_id == "dry"))
    assert dry.activation_plan.status in ["ack_conflict", "unknown_manual_attention"]
    assert dry.activation_plan.operator_acknowledgement.status == "unsupported"

    blocked =
      DeviceObservability.build(
        Map.put(base_sources, :runtime_ledger, %{
          projects: [
            %{
              project_id: "dry",
              counts: %{manual_attention: 1},
              active_attempts: [],
              workspace_leases: [],
              pending_start_intents: [],
              retry_backoff: [],
              writebacks: %{counts: %{manual_attention: 1}},
              lifecycle: %{counts: %{manual_attention: 1}},
              conflicts: [],
              manual_attention: [%{code: "manual_attention_required"}]
            }
          ]
        }),
        now: ~U[2026-06-28 09:00:00Z],
        operator_acknowledgements: [
          %{
            project_id: "dry",
            plan_id: plan_id,
            source: "operator-file",
            created_at: "2026-06-28T09:01:00Z",
            acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
          }
        ]
      )

    dry = blocked.projects |> Enum.find(&(&1.project_id == "dry"))
    assert dry.activation_plan.status == "unknown_manual_attention"
    assert dry.activation_plan.operator_acknowledgement.status in ["manual_attention", "stale"]
    assert "plan_id_mismatch" in dry.activation_plan.operator_acknowledgement.stale_reasons
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
            "activation_plan" => %{
              "project_id" => "alpha",
              "plan_id" => "safe-plan",
              "status" => "ack_required",
              "operator_acknowledgement" => %{
                "status" => "missing",
                "project_id" => "alpha",
                "note" => "Authorization: Bearer supersecret"
              },
              "evidence" => %{"raw_systemd_output" => "raw systemd output should not leak"}
            },
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
    assert project.activation_plan.plan_id == "safe-plan"
    assert project.activation_plan.operator_acknowledgement.status == "missing"
    refute Map.has_key?(project.activation_plan.evidence, "raw_systemd_output")

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
    refute safe_text =~ "raw systemd output"
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
    assert projects["broken"].migration_readiness.decision == "unknown_manual_attention"
    assert "summary_error" in readiness_reason_codes(projects["broken"])
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

  defp readiness_reason_codes(project) do
    project.migration_readiness.blocking_reasons
    |> Enum.map(& &1.code)
    |> Enum.sort()
  end

  defp advisory_reason_codes(project) do
    project.migration_readiness.advisory_reasons
    |> Enum.map(& &1.code)
    |> Enum.sort()
  end

  defp readiness_action_codes(project) do
    project.migration_readiness.required_operator_actions
    |> Enum.map(& &1.code)
    |> Enum.sort()
  end

  defp activation_ack_codes(project) do
    project.activation_plan.required_acknowledgements
    |> Enum.map(& &1.code)
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

  defp ready_ack_sources do
    %{
      hub_runtime: %{
        read_only: false,
        provider_executor: %{mode: "real_writeback", provider_io: true},
        writeback_executor: %{mode: "real_writeback", provider_io: true},
        worker_starter: %{mode: "real_worker_starter", worker_start: true},
        activation_probe: %{mode: "host_service", source: "host_service_probe", host_service_probe: true}
      },
      registry: %{
        projects: [
          registry_project("dry", "github:o/r") |> Map.put(:migration_state, "hub_ready")
        ],
        warnings: [],
        errors: []
      },
      poll_coordination: %{
        projects: [
          %{project_id: "dry", allow_poll: true, eligibility: %{reason: "ready"}, provider_scope_key: "github:o/r"}
        ]
      },
      activation_preflight: %{
        projects: [
          %{
            project_id: "dry",
            status: "not_hub_managed",
            safe_to_manage: false,
            reason: "migration_state_not_hub_managed",
            checked_at: "2026-06-28T09:00:00Z",
            probe_source: "host_service_probe",
            blocked_operations: [],
            detected_legacy_ownership: [],
            unknown_probe_results: []
          }
        ]
      },
      scheduler: %{enabled: true, status: "scheduled"},
      runtime_ledger: %{projects: []}
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
