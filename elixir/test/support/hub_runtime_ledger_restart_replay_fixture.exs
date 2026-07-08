defmodule SymphonyElixir.HubRuntimeLedgerRestartReplayFixture do
  @moduledoc false

  alias SymphonyElixir.Hub.{IssueRef, Runtime, RuntimeLedger}

  @fixture_version 1
  @now ~U[2026-07-02 09:30:00Z]
  @now_iso DateTime.to_iso8601(@now)

  @project_specs [
    %{
      project_id: "alpha-live",
      provider_kind: "github",
      provider_scope_key: "github:org/alpha-live",
      provider_issue_id: "20301",
      provider_local_id: "501",
      identifier: "org/alpha-live#501"
    },
    %{
      project_id: "beta-complete",
      provider_kind: "github",
      provider_scope_key: "github:org/beta-complete",
      provider_issue_id: "20302",
      provider_local_id: "502",
      identifier: "org/beta-complete#502"
    },
    %{
      project_id: "gamma-retry",
      provider_kind: "gitlab",
      provider_scope_key: "gitlab:ops/gamma-retry",
      provider_issue_id: "20303",
      provider_local_id: "503",
      identifier: "ops/gamma-retry#503"
    },
    %{
      project_id: "delta-manual",
      provider_kind: "github",
      provider_scope_key: "github:org/delta-manual",
      provider_issue_id: "20304",
      provider_local_id: "504",
      identifier: "org/delta-manual#504"
    }
  ]

  @forbidden_output_markers [
    "unsafe-restart-replay-marker-01",
    "unsafe-restart-replay-marker-02",
    "unsafe-restart-replay-marker-03",
    "unsafe-restart-replay-marker-04",
    "unsafe-restart-replay-marker-05",
    "unsafe-restart-replay-marker-06",
    "unsafe-restart-replay-marker-07",
    "unsafe-restart-replay-marker-08",
    "unsafe-restart-replay-marker-09",
    "unsafe-restart-replay-marker-10",
    "unsafe-restart-replay-marker-11",
    "unsafe-restart-replay-marker-12",
    "unsafe-restart-replay-marker-13",
    "unsafe-restart-replay-marker-14",
    "unsafe-restart-replay-marker-15"
  ]

  @spec fixture_version() :: pos_integer()
  def fixture_version, do: @fixture_version

  @spec generated_at() :: String.t()
  def generated_at, do: @now_iso

  @spec forbidden_output_markers() :: [String.t()]
  def forbidden_output_markers, do: @forbidden_output_markers

  @spec project_specs() :: [map()]
  def project_specs, do: @project_specs

  @spec safe_ledger() :: RuntimeLedger.ledger()
  def safe_ledger do
    RuntimeLedger.new(
      generated_at: @now,
      updated_at: @now,
      projects: [
        alpha_live_project(),
        beta_complete_project(),
        gamma_retry_project(),
        delta_manual_project()
      ]
    )
  end

  @spec safe_snapshot() :: RuntimeLedger.ledger()
  def safe_snapshot, do: RuntimeLedger.to_snapshot(safe_ledger())

  @spec restored_ledger() :: RuntimeLedger.ledger()
  def restored_ledger do
    safe_snapshot()
    |> Jason.encode!()
    |> Jason.decode!()
    |> RuntimeLedger.from_snapshot()
    |> case do
      {:ok, restored} -> restored
      {:error, diagnostics} -> raise "restart/replay fixture must stay valid: #{inspect(diagnostics)}"
    end
  end

  @spec replay_summary() :: RuntimeLedger.replay_summary()
  def replay_summary, do: RuntimeLedger.replay(restored_ledger())

  @spec active_attempt_conflict_snapshot() :: RuntimeLedger.ledger()
  def active_attempt_conflict_snapshot do
    safe_snapshot()
    |> Map.update!(:projects, fn projects ->
      Enum.map(projects, fn
        %{project_id: "alpha-live"} = project ->
          Map.update!(project, :issues, fn issues ->
            Enum.map(issues, fn issue ->
              Map.update!(issue, :attempts, fn attempts ->
                attempts ++
                  [
                    %{
                      attempt_id: "alpha-live-attempt-duplicate",
                      attempt_number: 2,
                      status: :running,
                      started_at: "2026-07-02T09:31:00Z",
                      current_stage: "in_progress",
                      worker_host: "fixture-worker-a",
                      workspace_path: "safe-workspace/alpha-live/duplicate"
                    }
                  ]
              end)
            end)
          end)
          |> Map.update!(:workspace_leases, fn leases ->
            leases ++
              [
                %{
                  lease_id: "lease-alpha-live-duplicate",
                  issue_key: issue_key("alpha-live"),
                  attempt_id: "alpha-live-attempt-duplicate",
                  workspace_path: "safe-workspace/alpha-live/duplicate",
                  status: :active,
                  acquired_at: "2026-07-02T09:31:00Z",
                  worker_host: "fixture-worker-a"
                }
              ]
          end)

        project ->
          project
      end)
    end)
    |> RuntimeLedger.to_snapshot()
  end

  @spec registry() :: map()
  def registry do
    %{
      projects: Enum.map(@project_specs, &registry_project/1),
      warnings: [],
      errors: []
    }
  end

  @spec runtime_snapshot() :: map()
  def runtime_snapshot do
    Runtime.build_snapshot(support_source_path(), @now, registry(),
      now: @now,
      read_only: true,
      runtime_ledger: restored_ledger(),
      scheduler: %{enabled: false, status: "disabled", queued: false, coalesced: false}
    )
  end

  @spec device_observability() :: map()
  def device_observability, do: runtime_snapshot().hub_device_observability

  @spec support_source_path() :: Path.t()
  def support_source_path do
    Path.expand("hub_runtime_ledger_restart_replay_fixture.exs", __DIR__)
  end

  @spec issue_key(String.t()) :: String.t()
  def issue_key(project_id), do: RuntimeLedger.issue_key(issue_ref(project_id))

  defp alpha_live_project do
    project_id = "alpha-live"
    key = issue_key(project_id)

    %{
      project_id: project_id,
      config_fingerprint: "#{project_id}-fixture-fp",
      snapshot_version: "restart-replay-fixture:v#{@fixture_version}",
      issues: [
        %{
          issue_ref: issue_ref(project_id),
          claim_status: :running,
          current_stage: "in_progress",
          claimed_at: "2026-07-02T09:20:00Z",
          attempts: [
            %{
              attempt_id: "alpha-live-attempt-1",
              attempt_number: 1,
              status: :running,
              started_at: "2026-07-02T09:21:00Z",
              current_stage: "in_progress",
              worker_host: "fixture-worker-a",
              workspace_path: "safe-workspace/alpha-live/501",
              agent_session: %{
                session_id: "session-alpha-live",
                last_activity_at: "2026-07-02T09:29:00Z",
                usage: %{input_tokens: 1200, output_tokens: 350, turns: 4}
              },
              run_context: run_context(project_id, key, "alpha-live-attempt-1", "lease-alpha-live-1")
            }
          ]
        }
      ],
      workspace_leases: [
        %{
          lease_id: "lease-alpha-live-1",
          issue_key: key,
          attempt_id: "alpha-live-attempt-1",
          workspace_path: "safe-workspace/alpha-live/501",
          status: :active,
          acquired_at: "2026-07-02T09:21:00Z",
          worker_host: "fixture-worker-a"
        }
      ],
      start_intents: [
        %{
          intent_id: "start-alpha-live-1",
          issue_key: key,
          attempt_id: "alpha-live-attempt-1",
          workspace_lease_id: "lease-alpha-live-1",
          workspace_path: "safe-workspace/alpha-live/501",
          status: :acknowledged,
          requested_at: "2026-07-02T09:20:30Z",
          acked_at: "2026-07-02T09:21:00Z",
          worker_host: "fixture-worker-a",
          runtime_identity: %{runtime: "hub", fixture: "restart-replay"},
          worker_identity: %{host: "fixture-worker-a", starter: "safe-fixture"},
          runner: "codex",
          start_command_summary: %{creates_workspace: false, worker_start: false},
          correlation_id: "corr-alpha-live-1"
        }
      ]
    }
  end

  defp beta_complete_project do
    project_id = "beta-complete"
    key = issue_key(project_id)

    %{
      project_id: project_id,
      config_fingerprint: "#{project_id}-fixture-fp",
      snapshot_version: "restart-replay-fixture:v#{@fixture_version}",
      issues: [
        %{
          issue_ref: issue_ref(project_id),
          claim_status: :released,
          current_stage: "done",
          claimed_at: "2026-07-02T09:00:00Z",
          released_at: "2026-07-02T09:18:00Z",
          terminal_reason: "stage outcome accepted",
          attempts: [
            %{
              attempt_id: "beta-complete-attempt-1",
              attempt_number: 1,
              status: :succeeded,
              started_at: "2026-07-02T09:02:00Z",
              ended_at: "2026-07-02T09:18:00Z",
              terminal_reason: "stage outcome accepted",
              current_stage: "done",
              worker_host: "fixture-worker-b",
              workspace_path: "safe-workspace/beta-complete/502"
            }
          ],
          lifecycle_results: [
            %{
              result_id: "lifecycle-beta-complete-1",
              attempt_id: "beta-complete-attempt-1",
              start_intent_id: "start-beta-complete-1",
              workspace_lease_id: "lease-beta-complete-1",
              workspace_path: "safe-workspace/beta-complete/502",
              session_id: "session-beta-complete",
              worker_host: "fixture-worker-b",
              worker_identity: %{host: "fixture-worker-b", source: "safe-fixture"},
              status: :succeeded,
              recovery_status: :released,
              reason: "stage_outcome_accepted",
              source: "fixture_lifecycle_reconciliation",
              finished_at: "2026-07-02T09:18:00Z",
              terminal: true,
              workspace_action: "released",
              recorded_at: "2026-07-02T09:18:10Z"
            }
          ],
          writebacks: [
            %{
              intent_key: RuntimeLedger.writeback_intent_key(issue_ref(project_id), "workpad-upsert"),
              logical_action: "workpad_upsert",
              operation_type: "comment_upsert",
              target: %{provider: "github", issue_id: "20302", marker: "codex-workpad"},
              replay_policy: :idempotent,
              result_status: :succeeded,
              attempt_id: "beta-complete-attempt-1",
              provider_marker: "<!-- symphony:workpad-upsert -->",
              external_ref: "safe-provider-comment-20302"
            }
          ]
        }
      ],
      workspace_leases: [
        %{
          lease_id: "lease-beta-complete-1",
          issue_key: key,
          attempt_id: "beta-complete-attempt-1",
          workspace_path: "safe-workspace/beta-complete/502",
          status: :released,
          acquired_at: "2026-07-02T09:02:00Z",
          released_at: "2026-07-02T09:18:00Z",
          worker_host: "fixture-worker-b"
        }
      ],
      start_intents: [
        %{
          intent_id: "start-beta-complete-1",
          issue_key: key,
          attempt_id: "beta-complete-attempt-1",
          workspace_lease_id: "lease-beta-complete-1",
          workspace_path: "safe-workspace/beta-complete/502",
          status: :acknowledged,
          requested_at: "2026-07-02T09:01:30Z",
          acked_at: "2026-07-02T09:02:00Z",
          finished_at: "2026-07-02T09:18:00Z",
          worker_host: "fixture-worker-b",
          runtime_identity: %{runtime: "hub", fixture: "restart-replay"},
          worker_identity: %{host: "fixture-worker-b", starter: "safe-fixture"},
          runner: "codex",
          start_command_summary: %{creates_workspace: false, worker_start: false},
          correlation_id: "corr-beta-complete-1"
        }
      ]
    }
  end

  defp gamma_retry_project do
    project_id = "gamma-retry"
    key = issue_key(project_id)

    %{
      project_id: project_id,
      config_fingerprint: "#{project_id}-fixture-fp",
      snapshot_version: "restart-replay-fixture:v#{@fixture_version}",
      issues: [
        %{
          issue_ref: issue_ref(project_id),
          claim_status: :retry_queued,
          current_stage: "in_progress",
          claimed_at: "2026-07-02T09:05:00Z",
          attempts: [
            %{
              attempt_id: "gamma-retry-attempt-1",
              attempt_number: 1,
              status: :failed,
              started_at: "2026-07-02T09:06:00Z",
              ended_at: "2026-07-02T09:12:00Z",
              terminal_reason: "provider rate limit",
              worker_host: "fixture-worker-c",
              workspace_path: "safe-workspace/gamma-retry/503"
            }
          ],
          retry_backoff: %{
            attempt_id: "gamma-retry-attempt-1",
            due_at: "2026-07-02T09:45:00Z",
            error_summary: "provider rate limit",
            preferred_worker_host: "fixture-worker-c",
            preferred_workspace_path: "safe-workspace/gamma-retry/503"
          },
          lifecycle_results: [
            %{
              result_id: "lifecycle-gamma-retry-1",
              attempt_id: "gamma-retry-attempt-1",
              start_intent_id: "start-gamma-retry-1",
              workspace_lease_id: "lease-gamma-retry-1",
              workspace_path: "safe-workspace/gamma-retry/503",
              session_id: "session-gamma-retry",
              worker_host: "fixture-worker-c",
              worker_identity: %{host: "fixture-worker-c", source: "safe-fixture"},
              status: :failed,
              recovery_status: :retry_queued,
              reason: "provider_rate_limit",
              source: "fixture_lifecycle_reconciliation",
              finished_at: "2026-07-02T09:12:00Z",
              terminal: true,
              workspace_action: "retained",
              workspace_retained_reason: "retry_backoff_pending",
              recorded_at: "2026-07-02T09:12:10Z"
            }
          ]
        }
      ],
      workspace_leases: [
        %{
          lease_id: "lease-gamma-retry-1",
          issue_key: key,
          attempt_id: "gamma-retry-attempt-1",
          workspace_path: "safe-workspace/gamma-retry/503",
          status: :active,
          acquired_at: "2026-07-02T09:06:00Z",
          worker_host: "fixture-worker-c"
        }
      ],
      start_intents: [
        %{
          intent_id: "start-gamma-retry-1",
          issue_key: key,
          attempt_id: "gamma-retry-attempt-1",
          workspace_lease_id: "lease-gamma-retry-1",
          workspace_path: "safe-workspace/gamma-retry/503",
          status: :acknowledged,
          requested_at: "2026-07-02T09:05:30Z",
          acked_at: "2026-07-02T09:06:00Z",
          finished_at: "2026-07-02T09:12:00Z",
          worker_host: "fixture-worker-c",
          runtime_identity: %{runtime: "hub", fixture: "restart-replay"},
          worker_identity: %{host: "fixture-worker-c", starter: "safe-fixture"},
          runner: "codex",
          start_command_summary: %{creates_workspace: false, worker_start: false},
          correlation_id: "corr-gamma-retry-1"
        }
      ]
    }
  end

  defp delta_manual_project do
    project_id = "delta-manual"
    key = issue_key(project_id)
    ref = issue_ref(project_id)

    %{
      project_id: project_id,
      config_fingerprint: "#{project_id}-fixture-fp",
      snapshot_version: "restart-replay-fixture:v#{@fixture_version}",
      issues: [
        %{
          issue_ref: ref,
          claim_status: :manual_attention,
          current_stage: "in_progress",
          claimed_at: "2026-07-02T09:10:00Z",
          attempts: [
            %{
              attempt_id: "delta-manual-attempt-1",
              attempt_number: 1,
              status: :pending,
              started_at: "2026-07-02T09:11:00Z",
              current_stage: "in_progress",
              worker_host: "fixture-worker-d",
              workspace_path: "safe-workspace/delta-manual/504"
            }
          ],
          lifecycle_results: [
            %{
              result_id: "lifecycle-delta-manual-1",
              attempt_id: "delta-manual-attempt-1",
              start_intent_id: "start-delta-manual-1",
              workspace_lease_id: "lease-delta-manual-1",
              workspace_path: "safe-workspace/delta-manual/504",
              session_id: "session-delta-manual",
              worker_host: "fixture-worker-d",
              worker_identity: %{host: "fixture-worker-d", source: "safe-fixture"},
              status: :manual_attention,
              recovery_status: :manual_attention,
              reason: "start_ack_unknown_after_restart",
              source: "fixture_lifecycle_reconciliation",
              manual_attention: true,
              workspace_action: "retained",
              workspace_retained_reason: "unknown_start_ack",
              recorded_at: "2026-07-02T09:30:00Z"
            }
          ],
          writebacks: [
            %{
              intent_key: RuntimeLedger.writeback_intent_key(ref, "stage-writeback-retryable"),
              logical_action: "stage_writeback",
              operation_type: "set_status",
              target: %{provider: "github", issue_id: "20304", state: "Human Review"},
              replay_policy: :idempotent,
              result_status: :failed,
              attempt_id: "delta-manual-attempt-1",
              error_summary: "rate limited",
              provider_result_status: "retryable_failure",
              provider_replayable: true,
              correlation: %{safe_request_id: "delta-stage-request-1"}
            },
            %{
              intent_key: RuntimeLedger.writeback_intent_key(ref, "pr-create-lookup"),
              logical_action: "pr_create",
              operation_type: "create_pr",
              target: %{provider: "github", head_ref_name: "issue-203-restart-replay", base_ref_name: "main"},
              replay_policy: :non_idempotent,
              result_status: :unknown,
              attempt_id: "delta-manual-attempt-1",
              error_summary: "provider acknowledgement unknown",
              provider_result_status: "unknown_result",
              provider_replayable: false,
              manual_attention: true,
              manual_attention_reason: "unknown_pr_create_requires_provider_lookup",
              correlation: %{safe_request_id: "delta-pr-request-1"}
            },
            %{
              intent_key: RuntimeLedger.writeback_intent_key(ref, "append-comment-manual"),
              logical_action: "comment_append",
              operation_type: "create_comment",
              target: %{provider: "github", issue_id: "20304", body_sha256: "fixture-comment-body-sha256", body_bytes: 128},
              replay_policy: :non_idempotent,
              result_status: :unknown,
              attempt_id: "delta-manual-attempt-1",
              error_summary: "append comment acknowledgement unknown",
              provider_result_status: "unknown_result",
              provider_replayable: false,
              manual_attention: true,
              manual_attention_reason: "unknown_append_comment_requires_manual_attention",
              correlation: %{safe_request_id: "delta-comment-request-1"}
            }
          ]
        }
      ],
      workspace_leases: [
        %{
          lease_id: "lease-delta-manual-1",
          issue_key: key,
          attempt_id: "delta-manual-attempt-1",
          workspace_path: "safe-workspace/delta-manual/504",
          status: :active,
          acquired_at: "2026-07-02T09:11:00Z",
          worker_host: "fixture-worker-d"
        }
      ],
      start_intents: [
        %{
          intent_id: "start-delta-manual-1",
          issue_key: key,
          attempt_id: "delta-manual-attempt-1",
          workspace_lease_id: "lease-delta-manual-1",
          workspace_path: "safe-workspace/delta-manual/504",
          status: :unknown,
          requested_at: "2026-07-02T09:10:30Z",
          worker_host: "fixture-worker-d",
          runtime_identity: %{runtime: "hub", fixture: "restart-replay"},
          worker_identity: %{host: "fixture-worker-d", starter: "safe-fixture"},
          runner: "codex",
          start_command_summary: %{creates_workspace: false, worker_start: false},
          correlation_id: "corr-delta-manual-1",
          error_summary: "start acknowledgement unknown after restart",
          manual_attention: true
        }
      ]
    }
  end

  defp run_context(project_id, issue_key, attempt_id, lease_id) do
    %{
      project_id: project_id,
      project: %{project_id: project_id, config_fingerprint: "#{project_id}-fixture-fp"},
      workflow: %{start_stage: "ready", terminal_stages: ["done", "blocked"]},
      tracker: %{kind: tracker_kind(project_id), provider_scope_key: provider_scope_key(project_id)},
      issue_key: issue_key,
      issue_ref: issue_ref(project_id),
      current_stage: "in_progress",
      attempt_id: attempt_id,
      attempt_number: 1,
      correlation_id: "corr-#{project_id}-1",
      workspace_path: "safe-workspace/#{project_id}/#{provider_local_id(project_id)}",
      workspace_lease_id: lease_id,
      worker_host: "fixture-worker-a",
      runtime_identity: %{runtime: "hub", fixture: "restart-replay"},
      worker_identity: %{host: "fixture-worker-a", starter: "safe-fixture"},
      runner: "codex",
      start_command_summary: %{creates_workspace: false, worker_start: false},
      session_id: "session-alpha-live",
      started_at: "2026-07-02T09:21:00Z",
      last_activity_at: "2026-07-02T09:29:00Z",
      exit_summary: %{status: "running"},
      status: "running"
    }
  end

  defp registry_project(spec) do
    %{
      project_id: spec.project_id,
      name: String.capitalize(String.replace(spec.project_id, "-", " ")),
      dispatch_enabled: true,
      paused: false,
      migration_state: "hub_managed",
      status: :ready,
      workflow_path: "safe-config/#{spec.project_id}/WORKFLOW.md",
      tracker_config_path: "safe-config/#{spec.project_id}/TRACKER.yaml",
      workflow_summary: %{start_stage: "ready", terminal_stages: ["done", "blocked"], stage_ids: ["ready", "in_progress", "done", "blocked"]},
      tracker_summary: %{
        kind: spec.provider_kind,
        provider_scope_key: spec.provider_scope_key,
        provider_scope: provider_scope(spec.provider_kind, spec.provider_scope_key),
        required_labels: ["symphony"]
      },
      runtime_summary: %{
        workspace_root: "safe-workspace-root/#{spec.project_id}",
        max_concurrent_agents: 2,
        max_concurrent_agents_by_state: %{},
        polling_interval_ms: 30_000,
        server_port: nil
      },
      fingerprint: "#{spec.project_id}-fixture-fp",
      loaded_at: @now,
      load_error: nil
    }
  end

  defp issue_ref(project_id) do
    %IssueRef{
      project_id: project_id,
      tracker_kind: tracker_kind(project_id),
      provider_scope: provider_scope(tracker_kind(project_id), provider_scope_key(project_id)),
      provider_scope_key: provider_scope_key(project_id),
      provider_issue_id: provider_issue_id(project_id),
      provider_local_id: provider_local_id(project_id),
      identifier: identifier(project_id),
      url: "https://example.invalid/#{project_id}/#{provider_local_id(project_id)}"
    }
  end

  defp project_spec(project_id), do: Enum.find(@project_specs, &(&1.project_id == project_id))
  defp tracker_kind(project_id), do: project_spec(project_id).provider_kind
  defp provider_scope_key(project_id), do: project_spec(project_id).provider_scope_key
  defp provider_issue_id(project_id), do: project_spec(project_id).provider_issue_id
  defp provider_local_id(project_id), do: project_spec(project_id).provider_local_id
  defp identifier(project_id), do: project_spec(project_id).identifier

  defp provider_scope("github", "github:" <> owner_repo) do
    [owner, repo] = String.split(owner_repo, "/", parts: 2)
    %{owner: owner, repo: repo}
  end

  defp provider_scope("gitlab", "gitlab:" <> project_slug), do: %{project_slug: project_slug}
end
