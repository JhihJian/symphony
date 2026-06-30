defmodule SymphonyElixir.HubCandidateIntakeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.{CandidateIntake, RuntimeLedger}

  @now ~U[2026-06-29 08:00:00Z]

  test "normalizes string-key provider candidates into provider-neutral ready records" do
    summary =
      CandidateIntake.build(
        registry([project("alpha", max_concurrent_agents: 2)]),
        [
          %{
            "result" => %{
              "project_id" => "alpha",
              "provider_scope_key" => "github:jhihjian/symphony",
              "request_id" => "provider-request-1",
              "logical_key" => "hub-poll:alpha:candidate_scan",
              "status" => "success",
              "result_summary" => %{
                "candidates" => [
                  %{
                    "id" => "gid://github/issue/123",
                    "number" => 123,
                    "identifier" => "jhihjian/symphony#123",
                    "current_stage" => "ready"
                  }
                ]
              }
            },
            "attempt" => %{"attempt_id" => "poll-attempt-1"}
          }
        ],
        now: @now
      )

    assert summary.counts == %{
             candidate_count: 1,
             valid_candidate_count: 1,
             eligible_count: 1,
             skipped_count: 0,
             invalid_count: 0,
             project_count: 1
           }

    assert [project] = summary.projects
    assert project.project_id == "alpha"
    assert project.provider_scope_key == "github:jhihjian/symphony"

    assert [candidate] = project.candidates
    assert candidate.issue_key == "alpha:github:jhihjian/symphony:gid://github/issue/123"
    assert candidate.issue_ref.provider_local_id == "123"
    assert candidate.issue_ref.identifier == "jhihjian/symphony#123"
    assert candidate.workspace_path == "/workspaces/alpha/123"
    assert candidate.source_poll.request_id == "provider-request-1"
    assert candidate.source_poll.poll_attempt_id == "poll-attempt-1"
    assert candidate.dispatch_evaluation.status == "ready_for_dispatch_evaluation"
    assert candidate.dispatch_evaluation.eligible == true
    assert candidate.dispatch_evaluation.preflight.status == "allowed"
  end

  test "invalid candidates are isolated and unsafe provider fields are not exposed" do
    summary =
      CandidateIntake.build(
        registry([project("alpha")]),
        [
          %{
            result: %{
              project_id: "alpha",
              provider_scope_key: "github:jhihjian/symphony",
              request_id: "provider-request-2",
              status: :success,
              result_summary: %{
                token: "ghp_supersecret",
                authorization: "Bearer supersecret",
                prompt: "full prompt should not leak",
                transcript: "complete transcript should not leak",
                raw_body: "raw provider body should not leak",
                candidates: [
                  %{
                    id: "124",
                    identifier: "jhihjian/symphony#124",
                    authorization: "Bearer nested",
                    raw_body: "nested raw body"
                  },
                  %{identifier: "missing stable id"},
                  "bad candidate"
                ]
              }
            }
          }
        ],
        now: @now
      )

    assert summary.counts.candidate_count == 3
    assert summary.counts.eligible_count == 2
    assert summary.counts.invalid_count == 1
    assert summary.skipped_reasons == %{"invalid_candidate" => 1}

    assert [project] = summary.projects
    candidate = Enum.find(project.candidates, &(&1.issue_ref.provider_issue_id == "124"))
    assert candidate.issue_key == "alpha:github:jhihjian/symphony:124"
    assert Enum.any?(project.candidates, &(&1.issue_key == "alpha:github:jhihjian/symphony:missing stable id"))
    assert length(project.invalid_candidates) == 1

    safe_text = inspect(summary)
    refute safe_text =~ "ghp_supersecret"
    refute safe_text =~ "Bearer"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "transcript"
    refute safe_text =~ "raw provider body"
    refute safe_text =~ "nested raw body"
    refute safe_text =~ "authorization"
    refute safe_text =~ "raw_body"
  end

  test "candidate identity is bound to poll source project" do
    summary =
      CandidateIntake.build(
        registry([project("alpha"), project("beta", provider_scope_key: "github:other/repo")]),
        [
          %{
            entry: %{
              project_id: "alpha",
              provider_kind: "github",
              provider_scope: github_scope("github:jhihjian/symphony"),
              provider_scope_key: "github:jhihjian/symphony"
            },
            request: %{
              project_id: "alpha",
              provider_kind: "github",
              provider_scope: github_scope("github:jhihjian/symphony"),
              provider_scope_key: "github:jhihjian/symphony",
              request_id: "provider-request-alpha",
              logical_key: "hub-poll:alpha:candidate_scan"
            },
            result: %{
              project_id: "beta",
              provider_scope_key: "github:other/repo",
              status: :success,
              result_summary: %{
                candidates: [
                  %{
                    id: "beta-1",
                    identifier: "other/repo#1",
                    project_id: "beta",
                    issue_ref: %{project_id: "beta", provider_scope_key: "github:other/repo"}
                  }
                ]
              }
            },
            attempt: %{attempt_id: "poll-attempt-alpha"}
          }
        ],
        now: @now
      )

    assert summary.counts == %{
             candidate_count: 1,
             valid_candidate_count: 0,
             eligible_count: 0,
             skipped_count: 1,
             invalid_count: 1,
             project_count: 1
           }

    assert [project] = summary.projects
    assert project.project_id == "alpha"
    assert project.provider_scope_key == "github:jhihjian/symphony"
    assert project.candidates == []
    assert [%{invalid_reason: "source_project_mismatch"}] = project.invalid_candidates

    safe_text = inspect(summary)
    refute safe_text =~ "ready_for_dispatch_evaluation"
  end

  test "candidate identity rejects provider scope kind and repo mismatches" do
    summary =
      CandidateIntake.build(
        registry([project("alpha")]),
        [
          source("alpha", [
            %{id: "scope-key", identifier: "scope-key", provider_scope_key: "github:other/repo"},
            %{id: "kind", identifier: "kind", issue_ref: %{tracker_kind: "gitlab"}},
            %{id: "repo", identifier: "repo", provider_scope: %{owner: "JhihJian", repo: "other"}}
          ])
        ],
        now: @now
      )

    assert summary.counts.candidate_count == 3
    assert summary.counts.valid_candidate_count == 0
    assert summary.counts.eligible_count == 0
    assert summary.counts.invalid_count == 3

    assert [project] = summary.projects
    assert project.candidates == []

    invalid_reasons = Enum.map(project.invalid_candidates, & &1.invalid_reason)
    assert "source_provider_scope_mismatch" in invalid_reasons
    assert "source_provider_kind_mismatch" in invalid_reasons
    refute inspect(summary) =~ "ready_for_dispatch_evaluation"
  end

  test "precheck explains duplicate active attempts workspace leases and project capacity" do
    ledger = active_ledger()

    summary =
      CandidateIntake.build(
        registry([project("alpha", max_concurrent_agents: 1)]),
        [
          source(
            "alpha",
            [
              %{id: "123", identifier: "jhihjian/symphony#123", workspace_path: "/workspaces/alpha/123"},
              %{id: "124", identifier: "jhihjian/symphony#124", workspace_path: "/workspaces/alpha/shared"},
              %{id: "125", identifier: "jhihjian/symphony#125", workspace_path: "/workspaces/alpha/125"}
            ]
          )
        ],
        now: @now,
        runtime_ledger: ledger
      )

    assert summary.counts.candidate_count == 3
    assert summary.counts.eligible_count == 0

    assert summary.skipped_reasons == %{
             "duplicate_active_attempt" => 1,
             "project_capacity_full" => 1,
             "workspace_busy" => 1
           }

    reasons_by_issue =
      summary.projects
      |> List.first()
      |> Map.fetch!(:candidates)
      |> Map.new(&{&1.issue_ref.provider_issue_id, &1.dispatch_evaluation.skipped_reason})

    assert reasons_by_issue["123"] == "duplicate_active_attempt"
    assert reasons_by_issue["124"] == "workspace_busy"
    assert reasons_by_issue["125"] == "project_capacity_full"
  end

  test "precheck explains project state provider backoff and manual attention blockers" do
    summary =
      CandidateIntake.build(
        registry([
          project("paused", paused: true),
          project("bad", status: :error, paused: true, load_error: "missing tracker.repo"),
          project("limited"),
          project("manual")
        ]),
        [
          source("paused", [%{id: "1", identifier: "paused#1"}]),
          source("bad", [%{id: "2", identifier: "bad#2"}]),
          source("limited", [%{id: "3", identifier: "limited#3"}], status: :rate_limited, retry_after_ms: 60_000),
          source("manual", [%{id: "4", identifier: "manual#4"}], status: :unknown_result, manual_attention: true)
        ],
        now: @now
      )

    assert summary.counts.candidate_count == 4
    assert summary.counts.eligible_count == 0

    assert summary.skipped_reasons == %{
             "config_error" => 1,
             "manual_attention" => 1,
             "project_paused" => 1,
             "provider_rate_limit" => 1
           }
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

  defp active_ledger do
    active_ref = issue_ref("alpha", "123", "jhihjian/symphony#123")
    shared_ref = issue_ref("alpha", "999", "jhihjian/symphony#999")
    active_key = RuntimeLedger.issue_key(active_ref)
    shared_key = RuntimeLedger.issue_key(shared_ref)

    RuntimeLedger.new(
      projects: [
        %{
          project_id: "alpha",
          issues: [
            %{
              issue_ref: active_ref,
              claim_status: :running,
              attempts: [%{attempt_id: "attempt-123", attempt_number: 1, status: :running, workspace_path: "/workspaces/alpha/123"}]
            },
            %{
              issue_ref: shared_ref,
              claim_status: :running,
              attempts: [%{attempt_id: "attempt-999", attempt_number: 1, status: :running, workspace_path: "/workspaces/alpha/shared"}]
            }
          ],
          workspace_leases: [
            %{lease_id: "lease-123", issue_key: active_key, attempt_id: "attempt-123", workspace_path: "/workspaces/alpha/123", status: :active},
            %{lease_id: "lease-999", issue_key: shared_key, attempt_id: "attempt-999", workspace_path: "/workspaces/alpha/shared", status: :active}
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
