defmodule SymphonyElixir.HubRuntimeLedgerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.IssueRef
  alias SymphonyElixir.Hub.RuntimeLedger

  test "serializes and replays recoverable ledger facts for multiple projects" do
    alpha_ref = issue_ref("alpha", "github", "github:jhihjian/symphony", "123", "jhihjian/symphony#77")
    beta_ref = issue_ref("beta", "gitlab", "gitlab:platform/beta", "456", "platform/beta#8")
    alpha_key = RuntimeLedger.issue_key(alpha_ref)
    beta_key = RuntimeLedger.issue_key(beta_ref)
    alpha_intent_key = RuntimeLedger.writeback_intent_key(alpha_ref, "needs-review-comment")

    ledger =
      RuntimeLedger.new(
        generated_at: ~U[2026-06-27 08:00:00Z],
        updated_at: ~U[2026-06-27 08:10:00Z],
        projects: [
          %{
            project_id: "alpha",
            config_fingerprint: "alpha-fingerprint",
            snapshot_version: "hub-registry:alpha:1",
            issues: [
              %{
                issue_ref: alpha_ref,
                claim_status: :running,
                current_stage: "in_progress",
                claimed_at: "2026-06-27T08:01:00Z",
                attempts: [
                  %{
                    attempt_id: "alpha-attempt-1",
                    attempt_number: 1,
                    status: :running,
                    started_at: "2026-06-27T08:02:00Z",
                    current_stage: "in_progress",
                    worker_host: "worker-a",
                    workspace_path: "/workspaces/alpha/77",
                    agent_session: %{
                      session_id: "session-alpha",
                      last_activity_at: "2026-06-27T08:09:00Z",
                      usage: %{input_tokens: 1200, output_tokens: 340, turns: 5}
                    }
                  }
                ],
                writebacks: [
                  %{
                    intent_key: alpha_intent_key,
                    logical_action: "needs-review-comment",
                    operation_type: "create_comment",
                    target: %{provider: "github", issue: "77"},
                    replay_policy: :idempotent,
                    result_status: :succeeded,
                    attempt_id: "alpha-attempt-1",
                    provider_marker: "<!-- symphony:needs-review-comment -->",
                    external_ref: "github-comment-1"
                  }
                ]
              },
              %{
                issue_ref: issue_ref("alpha", "github", "github:jhihjian/symphony", "124", "jhihjian/symphony#78"),
                claim_status: :retry_queued,
                current_stage: "in_progress",
                attempts: [
                  %{
                    attempt_id: "alpha-attempt-2",
                    attempt_number: 1,
                    status: :failed,
                    started_at: "2026-06-27T08:00:00Z",
                    ended_at: "2026-06-27T08:03:00Z",
                    terminal_reason: "worker lost"
                  }
                ],
                retry_backoff: %{
                  attempt_id: "alpha-attempt-2",
                  due_at: "2026-06-27T08:15:00Z",
                  error_summary: "worker lost",
                  preferred_worker_host: "worker-a",
                  preferred_workspace_path: "/workspaces/alpha/78"
                }
              },
              %{
                issue_ref: issue_ref("alpha", "github", "github:jhihjian/symphony", "125", "jhihjian/symphony#79"),
                claim_status: :blocked,
                current_stage: "blocked",
                attempts: [],
                writebacks: [
                  %{
                    intent_key: "alpha:blocking-side-effect",
                    logical_action: "close-pr",
                    operation_type: "merge_pr",
                    target: %{provider: "github", pr: "12"},
                    replay_policy: :non_idempotent,
                    result_status: :unknown,
                    attempt_id: "alpha-attempt-3"
                  }
                ]
              },
              %{
                issue_ref: issue_ref("alpha", "github", "github:jhihjian/symphony", "126", "jhihjian/symphony#80"),
                claim_status: :released,
                released_at: "2026-06-27T08:07:00Z",
                attempts: [
                  %{
                    attempt_id: "alpha-attempt-4",
                    attempt_number: 1,
                    status: :succeeded,
                    started_at: "2026-06-27T08:04:00Z",
                    ended_at: "2026-06-27T08:07:00Z",
                    terminal_reason: "stage outcome accepted"
                  }
                ]
              }
            ],
            workspace_leases: [
              %{
                lease_id: "lease-alpha-1",
                issue_key: alpha_key,
                attempt_id: "alpha-attempt-1",
                workspace_path: "/workspaces/alpha/77",
                status: :active,
                acquired_at: "2026-06-27T08:02:00Z",
                worker_host: "worker-a"
              }
            ]
          },
          %{
            project_id: "beta",
            config_fingerprint: "beta-fingerprint",
            issues: [
              %{
                issue_ref: beta_ref,
                claim_status: :claimed,
                current_stage: "ready",
                claimed_at: "2026-06-27T08:05:00Z",
                attempts: [
                  %{
                    attempt_id: "beta-attempt-1",
                    attempt_number: 1,
                    status: :pending,
                    current_stage: "ready",
                    worker_host: "worker-b",
                    workspace_path: "/workspaces/beta/8"
                  }
                ]
              }
            ],
            workspace_leases: [
              %{
                lease_id: "lease-beta-1",
                issue_key: beta_key,
                attempt_id: "beta-attempt-1",
                workspace_path: "/workspaces/beta/8",
                status: :active,
                acquired_at: "2026-06-27T08:05:00Z",
                worker_host: "worker-b"
              }
            ]
          }
        ]
      )

    assert :ok = RuntimeLedger.validate(ledger)
    snapshot = RuntimeLedger.to_snapshot(ledger)
    encoded = Jason.encode!(snapshot)
    decoded = Jason.decode!(encoded)

    assert {:ok, restored} = RuntimeLedger.from_snapshot(decoded)
    assert restored == snapshot
    assert get_in(restored, [:projects, Access.at(0), :issues, Access.at(0), :issue_key]) == alpha_key
    assert get_in(restored, [:projects, Access.at(1), :issues, Access.at(0), :issue_key]) == beta_key

    summary = RuntimeLedger.replay(restored)
    projects = Map.new(summary.projects, &{&1.project_id, &1})

    assert projects["alpha"].counts == %{
             claimed: 0,
             running: 1,
             retry: 1,
             blocked: 1,
             manual_attention: 0,
             released: 1,
             terminal: 0
           }

    assert projects["beta"].counts == %{
             claimed: 1,
             running: 0,
             retry: 0,
             blocked: 0,
             manual_attention: 0,
             released: 0,
             terminal: 0
           }

    alpha_running = Enum.find(projects["alpha"].active_issues, &(&1.issue_key == alpha_key))
    assert alpha_running.stage == "in_progress"
    assert alpha_running.attempt_id == "alpha-attempt-1"
    assert alpha_running.workspace_path == "/workspaces/alpha/77"
    assert alpha_running.worker_host == "worker-a"

    alpha_retry = Enum.find(projects["alpha"].active_issues, &(&1.backoff_due_at == "2026-06-27T08:15:00Z"))
    assert alpha_retry.last_error == "worker lost"

    assert [%{code: :writeback_unknown_manual_attention, intent_key: "alpha:blocking-side-effect"}] =
             summary.manual_attention

    refute inspect(snapshot) =~ "GITHUB_TOKEN"
    refute inspect(snapshot) =~ "api_key"
    refute inspect(snapshot) =~ "credential"
    refute inspect(snapshot) =~ "transcript"
  end

  test "detects active attempt conflicts for a single project issue" do
    ref = issue_ref("alpha", "github", "github:jhihjian/symphony", "123", "jhihjian/symphony#77")

    ledger =
      ledger_with_issue(%{
        issue_ref: ref,
        claim_status: :running,
        attempts: [
          %{attempt_id: "attempt-1", attempt_number: 1, status: :running},
          %{attempt_id: "attempt-2", attempt_number: 2, status: :pending}
        ]
      })

    assert {:error, diagnostics} = RuntimeLedger.validate(ledger)
    assert Enum.any?(diagnostics, &(&1.code == :active_attempt_conflict))
  end

  test "detects active attempt conflicts across duplicate issue facts with the same IssueRef" do
    ref = issue_ref("alpha", "github", "github:jhihjian/symphony", "123", "jhihjian/symphony#77")

    ledger =
      RuntimeLedger.new(
        projects: [
          %{
            project_id: "alpha",
            issues: [
              %{issue_ref: ref, claim_status: :running, attempts: [%{attempt_id: "attempt-1", status: :running}]},
              %{issue_ref: ref, claim_status: :running, attempts: [%{attempt_id: "attempt-2", status: :running}]}
            ]
          }
        ]
      )

    assert {:error, diagnostics} = RuntimeLedger.validate(ledger)

    assert [%{code: :active_attempt_conflict, issue_key: "alpha:github:jhihjian/symphony:123"}] =
             Enum.filter(diagnostics, &(&1.code == :active_attempt_conflict))
  end

  test "detects workspace active lease conflicts and orphan leases" do
    first_ref = issue_ref("alpha", "github", "github:jhihjian/symphony", "123", "jhihjian/symphony#77")
    second_ref = issue_ref("alpha", "github", "github:jhihjian/symphony", "124", "jhihjian/symphony#78")
    first_key = RuntimeLedger.issue_key(first_ref)
    second_key = RuntimeLedger.issue_key(second_ref)

    ledger =
      RuntimeLedger.new(
        projects: [
          %{
            project_id: "alpha",
            issues: [
              %{issue_ref: first_ref, claim_status: :running, attempts: [%{attempt_id: "attempt-1", status: :running}]},
              %{issue_ref: second_ref, claim_status: :running, attempts: [%{attempt_id: "attempt-2", status: :running}]}
            ],
            workspace_leases: [
              %{issue_key: first_key, attempt_id: "attempt-1", workspace_path: "/workspaces/shared", status: :active},
              %{issue_key: second_key, attempt_id: "attempt-2", workspace_path: "/workspaces/shared", status: :active},
              %{issue_key: second_key, attempt_id: "missing-attempt", workspace_path: "/workspaces/orphan", status: :active}
            ]
          }
        ]
      )

    assert {:error, diagnostics} = RuntimeLedger.validate(ledger)
    assert Enum.any?(diagnostics, &(&1.code == :workspace_active_lease_conflict))
    assert Enum.any?(diagnostics, &(&1.code == :workspace_lease_orphan))
  end

  test "detects released or terminal records that still hold active workspace leases" do
    ref = issue_ref("alpha", "github", "github:jhihjian/symphony", "123", "jhihjian/symphony#77")
    issue_key = RuntimeLedger.issue_key(ref)

    ledger =
      RuntimeLedger.new(
        projects: [
          %{
            project_id: "alpha",
            issues: [
              %{issue_ref: ref, claim_status: :terminal, attempts: [%{attempt_id: "attempt-1", status: :succeeded}]}
            ],
            workspace_leases: [
              %{issue_key: issue_key, attempt_id: "attempt-1", workspace_path: "/workspaces/alpha/77", status: :active}
            ]
          }
        ]
      )

    assert {:error, diagnostics} = RuntimeLedger.validate(ledger)
    assert Enum.any?(diagnostics, &(&1.code == :terminal_issue_has_active_workspace_lease))
  end

  test "detects retry backoff references to unknown attempts" do
    ledger =
      ledger_with_issue(%{
        issue_ref: issue_ref("alpha", "github", "github:jhihjian/symphony", "123", "jhihjian/symphony#77"),
        claim_status: :retry_queued,
        attempts: [%{attempt_id: "attempt-1", status: :failed}],
        retry_backoff: %{attempt_id: "attempt-2", due_at: "2026-06-27T09:00:00Z", error_summary: "lost ack"}
      })

    assert {:error, diagnostics} = RuntimeLedger.validate(ledger)
    assert Enum.any?(diagnostics, &(&1.code == :retry_backoff_unknown_attempt))
  end

  test "rejects issue facts that are not keyed by project_id and IssueRef provider scope" do
    ledger =
      RuntimeLedger.new(
        projects: [
          %{
            project_id: "alpha",
            issues: [
              %{
                issue_key: "123",
                issue_ref: %{
                  project_id: "alpha",
                  tracker_kind: "github",
                  provider_issue_id: "123",
                  provider_local_id: "77",
                  identifier: "jhihjian/symphony#77"
                },
                claim_status: :claimed
              }
            ]
          }
        ]
      )

    assert {:error, diagnostics} = RuntimeLedger.validate(ledger)
    assert Enum.any?(diagnostics, &(&1.code == :issue_ref_missing_provider_scope))
    assert Enum.any?(diagnostics, &(&1.code == :issue_key_mismatch))
  end

  test "keeps writeback intent keys stable across retry attempts" do
    ref = issue_ref("alpha", "github", "github:jhihjian/symphony", "123", "jhihjian/symphony#77")
    stable_key = RuntimeLedger.writeback_intent_key(ref, "needs-review-comment")

    stable_ledger =
      ledger_with_issue(%{
        issue_ref: ref,
        claim_status: :retry_queued,
        attempts: [%{attempt_id: "attempt-1", status: :failed}, %{attempt_id: "attempt-2", status: :pending}],
        writebacks: [
          %{
            intent_key: stable_key,
            logical_action: "needs-review-comment",
            operation_type: "create_comment",
            target: %{provider: "github", issue: "77"},
            replay_policy: :idempotent,
            result_status: :failed,
            attempt_id: "attempt-1"
          },
          %{
            intent_key: stable_key,
            logical_action: "needs-review-comment",
            operation_type: "create_comment",
            target: %{provider: "github", issue: "77"},
            replay_policy: :idempotent,
            result_status: :pending,
            attempt_id: "attempt-2"
          }
        ]
      })

    assert :ok = RuntimeLedger.validate(stable_ledger)

    unstable_ledger =
      ledger_with_issue(%{
        issue_ref: ref,
        claim_status: :retry_queued,
        attempts: [%{attempt_id: "attempt-1", status: :failed}, %{attempt_id: "attempt-2", status: :pending}],
        writebacks: [
          %{
            intent_key: stable_key <> ":attempt-1",
            logical_action: "needs-review-comment",
            operation_type: "create_comment",
            target: %{provider: "github", issue: "77"},
            replay_policy: :idempotent,
            result_status: :failed,
            attempt_id: "attempt-1"
          },
          %{
            intent_key: stable_key <> ":attempt-2",
            logical_action: "needs-review-comment",
            operation_type: "create_comment",
            target: %{provider: "github", issue: "77"},
            replay_policy: :idempotent,
            result_status: :pending,
            attempt_id: "attempt-2"
          }
        ]
      })

    assert {:error, diagnostics} = RuntimeLedger.validate(unstable_ledger)
    assert Enum.any?(diagnostics, &(&1.code == :writeback_intent_key_unstable))
  end

  test "rejects sensitive fields and values in snapshots" do
    snapshot = %{
      "version" => 1,
      "projects" => [
        %{
          "project_id" => "alpha",
          "raw_config" => %{"tracker" => %{"api_key" => "$GITHUB_TOKEN"}},
          "issues" => [
            %{
              "issue_ref" => %{
                "project_id" => "alpha",
                "tracker_kind" => "github",
                "provider_scope_key" => "github:jhihjian/symphony",
                "provider_issue_id" => "123"
              },
              "claim_status" => "running",
              "attempts" => [
                %{
                  "attempt_id" => "attempt-1",
                  "status" => "running",
                  "agent_session" => %{"session_id" => "s1", "transcript" => "full Codex transcript"}
                }
              ]
            }
          ]
        }
      ]
    }

    assert {:error, diagnostics} = RuntimeLedger.from_snapshot(snapshot)
    assert Enum.any?(diagnostics, &(&1.code == :sensitive_ledger_snapshot_field))

    assert {:error, validate_diagnostics} = RuntimeLedger.validate(snapshot)
    assert Enum.any?(validate_diagnostics, &(&1.code == :sensitive_ledger_snapshot_field))
  end

  defp ledger_with_issue(issue) do
    RuntimeLedger.new(projects: [%{project_id: "alpha", issues: [issue]}])
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

  defp provider_scope("gitlab", "gitlab:" <> project_slug), do: %{project_slug: project_slug}
end
