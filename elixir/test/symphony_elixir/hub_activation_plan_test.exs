defmodule SymphonyElixir.HubActivationPlanTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Hub.ActivationPlan

  test "builds serializable activation plan from safe readiness summaries" do
    summary =
      ActivationPlan.build(
        readiness(%{
          projects: [
            readiness_project("ready", "ready_for_hub_management"),
            readiness_project("managed", "already_hub_managed", migration_state: "hub_managed"),
            readiness_project("blocked", "blocked",
              blocking_reasons: [%{reason: "legacy_service_running", source: "activation_preflight", level: "unexpected"}],
              required_operator_actions: ["inspect_legacy_service"]
            )
          ],
          hub_runtime: runtime(enabled: true, scheduler_enabled: true, activation_probe: %{source: "host_service_probe"})
        }),
        [
          project("ready", "github:owner/repo"),
          project("managed", "github:owner/repo"),
          project("blocked", "gitlab:group/project")
        ],
        %{scheduler: %{enabled: true, status: "scheduled"}},
        now: ~U[2026-06-28 09:00:00Z]
      )

    projects = Map.new(summary.projects, &{&1.project_id, &1})

    assert summary.generated_at == "2026-06-28T09:00:00Z"
    assert summary.status == "blocked"
    assert summary.counts.project_count == 3
    assert summary.counts.plan_statuses.ack_required == 1
    assert summary.counts.plan_statuses.already_managed == 1
    assert summary.counts.plan_statuses.blocked == 1
    assert summary.counts.acknowledgement_statuses.missing == 3
    assert summary.global_blocking_risks == []

    assert projects["ready"].status == "ack_required"
    assert projects["ready"].acknowledgement_required == true
    assert projects["ready"].proposed_next_state == "operator_may_mark_hub_managed_after_checks"

    assert projects["ready"].operator_acknowledgement.missing_acknowledgements == [
             "confirm_hub_executor_modes",
             "mark_hub_managed_after_checks"
           ]

    assert projects["managed"].status == "already_managed"
    assert projects["managed"].proposed_next_state == "already_managed"
    assert projects["blocked"].status == "blocked"
    assert [%{level: "blocking"}] = projects["blocked"].blocking_reasons
  end

  test "accepts acknowledgement maps lists and keyed project maps without reusing stale evidence" do
    base = ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(), now: ~U[2026-06-28 09:00:00Z])
    plan = hd(base.projects)

    accepted =
      ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(),
        now: ~U[2026-06-28 09:00:00Z],
        acknowledgements: %{
          "ready" => %{
            "plan_id" => plan.plan_id,
            "source" => "operator-file",
            "acknowledged_at" => "2026-06-28T09:01:00Z",
            "confirmed_action_codes" => ["confirm_hub_executor_modes"],
            "action_codes" => ["mark_hub_managed_after_checks"],
            "risk_codes" => ["legacy_ownership_guardrail"],
            "note" => %{note_sha256: "abc123", note_bytes: "12"}
          },
          "ignored" => "not-a-map"
        }
      )

    assert [accepted_project] = accepted.projects
    assert accepted_project.status == "plan_ready"
    assert accepted_project.operator_acknowledgement.status == "accepted"
    assert accepted_project.operator_acknowledgement.plan_id_matches == true
    assert accepted_project.operator_acknowledgement.note_summary == %{note_sha256: "abc123", note_bytes: 12}
    assert "legacy_ownership_guardrail" in accepted_project.operator_acknowledgement.acknowledged_risk_codes
    assert accepted_project.hub_owned_actions_allowed == false
    assert "activation_preflight" in accepted_project.hub_owned_actions_remain_guarded_by

    stale =
      ActivationPlan.build(
        readiness(%{
          projects: [
            readiness_project("ready", "ready_for_hub_management",
              evidence: %{
                activation_preflight: %{
                  status: "blocked_conflict",
                  safe_to_manage: false,
                  reason: "legacy_service_active"
                }
              }
            )
          ]
        }),
        [project("ready", "github:owner/repo")],
        overview(),
        now: ~U[2026-06-28 09:00:00Z],
        operator_acknowledgements: [
          %{
            project_id: "ready",
            readiness_fingerprint: plan.plan_id,
            source: "operator-file",
            created_at: "2026-06-28T09:02:00Z",
            acknowledged_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
          }
        ]
      )

    assert [stale_project] = stale.projects
    assert stale_project.status == "ack_stale"
    assert stale_project.operator_acknowledgement.status == "stale"
    assert stale_project.operator_acknowledgement.stale_reasons == ["plan_id_mismatch"]
  end

  test "ignores malformed readiness evidence when building stable plan fingerprint" do
    summary =
      ActivationPlan.build(
        readiness(%{projects: [readiness_project("ready", "ready_for_hub_management", evidence: "not-a-map")]}),
        [project("ready", "github:owner/repo")],
        overview(),
        now: ~U[2026-06-28 09:00:00Z]
      )

    assert [%{plan_id: plan_id, evidence: "not-a-map"}] = summary.projects
    assert is_binary(plan_id)
  end

  test "detects acknowledgement conflicts malformed unsupported and manual attention statuses" do
    base = ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(), now: ~U[2026-06-28 09:00:00Z])
    plan_id = hd(base.projects).plan_id

    assert ack_status([%{project_id: "other", plan_id: plan_id, source: "operator", created_at: "2026-06-28T09:00:00Z"}]) ==
             {"missing", []}

    provider_conflict =
      project_ack(%{
        provider_scope_key: "github:other/repo",
        acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
      })
      |> Map.put(:plan_id, plan_id)

    assert ack_status([provider_conflict]) == {"conflict", ["provider_scope_mismatch"]}

    migration_conflict =
      project_ack(%{
        migration_state: "legacy_only",
        acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
      })
      |> Map.put(:plan_id, plan_id)

    assert ack_status([migration_conflict]) == {"conflict", ["migration_state_mismatch"]}

    decision_conflict =
      project_ack(%{
        readiness_decision: "ready_for_dry_run",
        acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
      })
      |> Map.put(:plan_id, plan_id)

    assert ack_status([decision_conflict]) == {"conflict", ["readiness_decision_mismatch"]}

    incomplete =
      project_ack(%{acknowledged_action_codes: ["confirm_hub_executor_modes"]})
      |> Map.put(:plan_id, plan_id)

    assert ack_status([incomplete]) == {"conflict", ["acknowledged_codes_incomplete"]}

    malformed = ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(), operator_acknowledgements: 42)
    assert [%{operator_acknowledgement: %{status: "missing"}}] = malformed.projects
    assert [%{code: "operator_acknowledgement_unscoped"}] = malformed.global_advisory_risks

    unsupported =
      ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(), operator_acknowledgements: [project_ack(%{version: "not-an-integer", plan_id: plan_id})])

    assert [%{operator_acknowledgement: %{status: "unsupported", unsupported_reasons: ["acknowledgement_version_unsupported"]}}] =
             unsupported.projects

    manual_attention =
      ActivationPlan.build(
        readiness(%{projects: [readiness_project("ready", "blocked")]}),
        [project("ready", "github:owner/repo")],
        overview(),
        operator_acknowledgements: [
          project_ack(%{
            plan_id:
              ActivationPlan.build(readiness(%{projects: [readiness_project("ready", "blocked")]}), [project("ready", "github:owner/repo")], overview()).projects |> hd() |> Map.fetch!(:plan_id),
            acknowledged_action_codes: ["inspect_blocking_reasons"]
          })
        ]
      )

    assert [%{operator_acknowledgement: %{status: "manual_attention", manual_attention_reasons: ["plan_not_ready_for_ack_acceptance"]}}] =
             manual_attention.projects
  end

  test "normalizes snapshot boundaries and strips acknowledgement for plan-only output" do
    plan = %{
      "version" => "2",
      "project_id" => 123,
      "provider" => %{
        "provider_kind" => :github,
        "provider_scope_key" => "github:owner/repo",
        "provider_scope" => %{"owner" => "owner", "token" => "$GITHUB_TOKEN", "visibility" => :private}
      },
      "migration_state" => nil,
      "decision" => "manual attention",
      "status" => "not-known",
      "proposed_next_state" => "",
      "required_acknowledgements" => ["Confirm Hub Executor Modes", %{code: :release_workspace}],
      "blocking_reasons" => ["Probe Missing", %{reason: "manual_attention", blocks_hub_management: false}],
      "advisory_reasons" => [%{code: "executor mode changed", level: "other"}],
      "evidence" => %{
        "checked_at" => "2026-06-28T09:00:00Z",
        "loaded_at" => "2026-06-28T09:00:00Z",
        "visible" => %DateTime{} = ~U[2026-06-28 09:00:00Z],
        "raw_config" => "secret",
        "details" => [%{status: :ok}, "Authorization: Bearer secret"]
      },
      "operator_acknowledgement" => %{
        "status" => "mystery",
        "note_summary" => %{"note_sha256" => "hash", "note_bytes" => "7"}
      }
    }

    snapshot = ActivationPlan.project_plan_snapshot(plan)

    same_snapshot =
      ActivationPlan.project_plan_snapshot(
        Map.delete(plan, "evidence")
        |> Map.put("evidence", %{"checked_at" => "later", "loaded_at" => "later", "visible" => ~U[2026-06-28 09:00:00Z], "details" => [%{status: :ok}]})
      )

    plan_only = ActivationPlan.activation_plan_only(plan)

    assert snapshot.project_id == "123"
    assert snapshot.version == 2
    assert snapshot.status == "unknown_manual_attention"
    assert snapshot.readiness_decision == "unknown_manual_attention"
    assert snapshot.migration_state == "hub_ready"
    assert snapshot.provider.kind == "github"
    assert snapshot.provider.scope["visibility"] == "private"
    refute Map.has_key?(snapshot.provider.scope, "token")
    refute Map.has_key?(snapshot.evidence, "raw_config")
    assert snapshot.evidence["visible"] == "2026-06-28T09:00:00Z"
    assert snapshot.evidence["details"] == [%{"status" => "ok"}]
    assert snapshot.operator_acknowledgement.status == "missing"
    assert snapshot.operator_acknowledgement.note_summary == %{note_sha256: "hash", note_bytes: 7}
    assert snapshot.plan_id == same_snapshot.plan_id
    refute Map.has_key?(plan_only, :operator_acknowledgement)

    fallback = ActivationPlan.project_plan_snapshot("bad-plan")
    assert fallback.project_id == ""
    assert fallback.operator_acknowledgement.status == "missing"
  end

  test "snapshot summary handles non-map inputs unknown statuses and global runtime blockers" do
    assert %{projects: [], status: "unknown_manual_attention"} = ActivationPlan.to_snapshot(nil)
    assert %{status: "unknown_manual_attention"} = ActivationPlan.to_snapshot(%{status: "bad", projects: []})

    snapshot =
      ActivationPlan.to_snapshot(%{
        version: "3",
        generated_at: "not-a-time",
        status: "bad status",
        counts: "bad-counts",
        safety_gates: ["activation_preflight", nil, "  "],
        hub_runtime: %{
          enabled: false,
          mode: :legacy,
          read_only: "1",
          provider_executor: %{mode: :skeleton},
          writeback_executor: %{mode: "skeleton"},
          worker_starter: %{mode: "skeleton"},
          activation_probe: "not-a-map"
        },
        global_blocking_risks: [%{code: "readiness summary unavailable", level: "other"}],
        projects: [
          %{
            project_id: "stale",
            readiness_decision: "legacy_only",
            status: "not-known",
            operator_acknowledgement: %{status: "stale"}
          },
          %{
            project_id: "conflict",
            readiness_decision: "ready_for_dry_run",
            status: "not-known",
            operator_acknowledgement: %{status: "conflict"}
          }
        ]
      })

    assert snapshot.version == 3
    assert snapshot.generated_at == "not-a-time"
    assert snapshot.status == "blocked"
    assert snapshot.hub_runtime.enabled == false
    assert snapshot.hub_runtime.mode == "legacy"
    assert snapshot.hub_runtime.read_only == true
    assert snapshot.hub_runtime.activation_probe == "not-a-map"
    assert snapshot.safety_gates == ["activation_preflight"]
    assert snapshot.counts.project_count == 2
    assert Enum.map(snapshot.projects, & &1.status) == ["ack_conflict", "ack_stale"]
    assert [%{code: "readiness_summary_unavailable", level: "blocking"}] = snapshot.global_blocking_risks
  end

  test "build isolates unsafe project and input shape errors without leaking sensitive evidence" do
    summary =
      ActivationPlan.build(
        readiness(%{
          projects: [
            readiness_project("bad-project", "ready_for_hub_management"),
            readiness_project("ok-project", "ready_for_dry_run", evidence: %{secret_env: "$API_KEY", visible: "safe"})
          ],
          hub_runtime: runtime(enabled: false, scheduler_enabled: false, activation_probe: %{})
        }),
        [
          %{
            project_id: "bad-project",
            provider: %{kind: "github", provider_scope_key: "github:bad/project", scope: %{{:bad, :key} => "value"}}
          },
          project("ok-project", "github:owner/repo")
        ],
        :not_a_map,
        now: ~U[2026-06-28 09:00:00Z],
        operator_acknowledgements: %{
          acknowledgements: [
            project_ack(%{
              project_id: "ok-project",
              plan_id: "old",
              source: "Authorization: Bearer secret",
              created_at: "bad-time",
              version: 2
            })
          ]
        }
      )

    projects = Map.new(summary.projects, &{&1.project_id, &1})

    assert projects["bad-project"].status == "unknown_manual_attention"
    assert projects["bad-project"].operator_acknowledgement.status == "manual_attention"
    assert [%{code: "activation_plan_summary_error"}] = projects["bad-project"].blocking_reasons

    assert projects["ok-project"].operator_acknowledgement.status == "unsupported"
    assert projects["ok-project"].evidence == %{"visible" => "safe"}
    assert Enum.any?(summary.global_blocking_risks, &(&1.code == "hub_runtime_not_enabled"))
    assert Enum.any?(summary.global_blocking_risks, &(&1.code == "scheduler_disabled"))
    assert Enum.any?(summary.global_blocking_risks, &(&1.code == "activation_probe_not_host_service"))

    safe_text = inspect(summary)
    refute safe_text =~ "$API_KEY"
    refute safe_text =~ "Authorization"
    refute safe_text =~ "secret_env"
  end

  test "acknowledgement snapshot normalizes public fields and safe note summaries" do
    assert ActivationPlan.acknowledgement_snapshot("bad").status == "missing"

    snapshot =
      ActivationPlan.acknowledgement_snapshot(%{
        status: "manual-attention",
        required: true,
        project_id: :ready,
        plan_id: 123,
        plan_id_matches: true,
        source: "$GITHUB_TOKEN",
        created_at: ~U[2026-06-28 09:00:00Z],
        acknowledged_codes: "single code",
        acknowledged_action_codes: [:stop_legacy_service, ""],
        acknowledged_risk_codes: ["provider ownership", "provider ownership"],
        missing_acknowledgements: "release workspace",
        stale_reasons: "plan_id_mismatch",
        conflict_reasons: "provider_scope_mismatch",
        malformed_reasons: "source_missing",
        unsupported_reasons: "ack_version",
        manual_attention_reasons: "manual review",
        note: :not_a_note
      })

    assert snapshot.status == "manual_attention"
    assert snapshot.required == true
    assert snapshot.project_id == "ready"
    assert snapshot.plan_id == "123"
    assert snapshot.source == nil
    assert snapshot.created_at == "2026-06-28T09:00:00Z"
    assert snapshot.acknowledged_codes == ["single_code"]
    assert snapshot.acknowledged_action_codes == ["stop_legacy_service"]
    assert snapshot.acknowledged_risk_codes == ["provider_ownership"]
    assert snapshot.missing_acknowledgements == ["release_workspace"]
    assert snapshot.stale_reasons == ["plan_id_mismatch"]
    assert snapshot.conflict_reasons == ["provider_scope_mismatch"]
    assert snapshot.malformed_reasons == ["source_missing"]
    assert snapshot.unsupported_reasons == ["ack_version"]
    assert snapshot.manual_attention_reasons == ["manual_review"]
    assert snapshot.note_summary == nil
  end

  test "acknowledgement input supports projects list and picks newest scoped acknowledgement" do
    base = ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(), now: ~U[2026-06-28 09:00:00Z])
    plan_id = hd(base.projects).plan_id

    from_projects_key =
      ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(),
        now: ~U[2026-06-28 09:00:00Z],
        operator_acknowledgements: %{
          projects: [
            project_ack(%{
              plan_id: plan_id,
              created_at: "2026-06-28T09:01:00Z",
              acknowledged_action_codes: ["confirm_hub_executor_modes"]
            }),
            project_ack(%{
              plan_id: plan_id,
              created_at: "2026-06-28T09:02:00Z",
              acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
            })
          ]
        }
      )

    assert [%{operator_acknowledgement: %{status: "accepted", created_at: "2026-06-28T09:02:00Z"}}] =
             from_projects_key.projects

    newer_without_current_time =
      ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(),
        now: ~U[2026-06-28 09:00:00Z],
        operator_acknowledgements: [
          project_ack(%{
            plan_id: plan_id,
            created_at: "bad-time",
            acknowledged_action_codes: ["confirm_hub_executor_modes"]
          }),
          project_ack(%{
            plan_id: plan_id,
            created_at: "2026-06-28T09:03:00Z",
            acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
          })
        ]
      )

    assert [%{operator_acknowledgement: %{status: "accepted", created_at: "2026-06-28T09:03:00Z"}}] =
             newer_without_current_time.projects

    keeps_current_when_candidate_is_not_newer =
      ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(),
        now: ~U[2026-06-28 09:00:00Z],
        operator_acknowledgements: [
          project_ack(%{
            plan_id: plan_id,
            created_at: "2026-06-28T09:04:00Z",
            acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
          }),
          project_ack(%{
            plan_id: plan_id,
            created_at: "2026-06-28T09:03:00Z",
            acknowledged_action_codes: ["confirm_hub_executor_modes"]
          })
        ]
      )

    assert [%{operator_acknowledgement: %{status: "accepted", created_at: "2026-06-28T09:04:00Z"}}] =
             keeps_current_when_candidate_is_not_newer.projects
  end

  test "malformed and explicit manual-attention acknowledgements stay isolated to their project" do
    base = ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(), now: ~U[2026-06-28 09:00:00Z])
    plan_id = hd(base.projects).plan_id

    malformed =
      ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(),
        now: ~U[2026-06-28 09:00:00Z],
        operator_acknowledgements: %{
          "ready" => "not-a-map",
          "other" =>
            project_ack(%{
              project_id: "ready",
              plan_id: plan_id,
              acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
            })
        }
      )

    assert [%{operator_acknowledgement: %{status: "accepted"}}] = malformed.projects

    malformed_for_project =
      ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(),
        now: ~U[2026-06-28 09:00:00Z],
        operator_acknowledgements: [project_ack(%{plan_id: plan_id, status: "malformed", malformed_reasons: ["acknowledgement_not_map"]})]
      )

    assert [%{status: "unknown_manual_attention", operator_acknowledgement: %{status: "malformed", malformed_reasons: ["acknowledgement_not_map"]}}] =
             malformed_for_project.projects

    explicit_manual_attention =
      ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(),
        now: ~U[2026-06-28 09:00:00Z],
        operator_acknowledgements: [
          project_ack(%{
            plan_id: plan_id,
            status: "manual_attention",
            manual_attention_reasons: ["operator_requested_review"]
          })
        ]
      )

    assert [
             %{
               status: "unknown_manual_attention",
               operator_acknowledgement: %{status: "manual_attention", manual_attention_reasons: ["operator_requested_review"]}
             }
           ] = explicit_manual_attention.projects
  end

  test "fallback input shapes remain safe and non misleading" do
    empty = ActivationPlan.build(:not_a_readiness, :not_projects, :not_overview, now: 123)
    assert empty.generated_at != nil
    assert empty.projects == []
    assert empty.status == "blocked"
    assert Enum.any?(empty.global_blocking_risks, &(&1.code == "activation_probe_not_host_service"))

    details_project =
      ActivationPlan.build(
        readiness(%{
          projects: [readiness_project("detail", "ready_for_dry_run", evidence: %{struct: URI.parse("https://example.com/path")})],
          hub_runtime: runtime(enabled: true, scheduler_enabled: true, activation_probe: "probe-unavailable")
        }),
        [
          %{
            project_id: "detail",
            detail: %{
              identity: %{
                provider_kind: "github",
                provider_scope_key: "github:owner/repo",
                provider_scope: %{repo: "repo"}
              }
            }
          }
        ],
        overview(),
        now: ~U[2026-06-28 09:00:00Z]
      )

    assert [%{provider: %{kind: "github", provider_scope_key: "github:owner/repo"}, proposed_next_state: "continue_dry_run"}] =
             details_project.projects

    assert details_project.status == "blocked"
  end

  test "remaining snapshot edge cases preserve safe defaults" do
    plan_ready =
      ActivationPlan.project_plan_snapshot(%{
        project_id: "accepted-legacy",
        readiness_decision: "legacy_only",
        operator_acknowledgement: %{status: "accepted"},
        evidence: %{uri: URI.parse("https://example.com/path")}
      })

    assert plan_ready.status == "plan_ready"
    assert plan_ready.evidence["uri"]["host"] == "example.com"

    assert %{note_summary: %{note_sha256: "hash", note_bytes: 4}} =
             ActivationPlan.acknowledgement_snapshot(%{status: "accepted", note: %{note_sha256: "hash", note_bytes: 4}})

    assert %{note_summary: %{note_sha256: "hash", note_bytes: 5}} =
             ActivationPlan.acknowledgement_snapshot(%{status: "accepted", note: %{"note_sha256" => "hash", "note_bytes" => "5"}})

    assert %{note_summary: %{note_sha256: _hash, note_bytes: 13}} =
             ActivationPlan.acknowledgement_snapshot(%{status: "accepted", note_summary: %{bad: "shape"}, note: "operator note"})

    assert %{status: "unsupported", unsupported_reasons: ["acknowledgement_version_unsupported"]} =
             ack_for(%{version: 2})

    assert %{status: "unsupported", unsupported_reasons: ["acknowledgement_version_unsupported"]} =
             ack_for(%{version: "2"})

    assert %{status: "unsupported", unsupported_reasons: ["acknowledgement_version_unsupported"]} =
             ack_for(%{version: %{unsupported: true}})

    malformed_unscoped =
      ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(),
        operator_acknowledgements: ["not-a-map"],
        now: ~U[2026-06-28 09:00:00Z]
      )

    assert [%{operator_acknowledgement: %{status: "missing"}}] = malformed_unscoped.projects
    assert [%{code: "operator_acknowledgement_unscoped"}] = malformed_unscoped.global_advisory_risks
  end

  test "final normalization boundaries keep stable safe output" do
    base = ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(), now: ~U[2026-06-28 09:00:00Z])
    plan_id = hd(base.projects).plan_id

    accepted_integer_version = ack_for(%{version: 1, acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]})
    accepted_string_version = ack_for(%{version: "1", acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]})

    assert accepted_integer_version.status == "accepted"
    assert accepted_string_version.status == "accepted"

    accepted_datetime =
      ack_for(%{
        created_at: ~U[2026-06-28 09:05:00Z],
        note: %{"note_sha256" => "raw-hash", "note_bytes" => "8"},
        acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
      })

    assert accepted_datetime.status == "accepted"
    assert accepted_datetime.created_at == "2026-06-28T09:05:00Z"
    assert accepted_datetime.note_summary == %{note_sha256: "raw-hash", note_bytes: 8}

    same_time =
      ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(),
        now: ~U[2026-06-28 09:00:00Z],
        operator_acknowledgements: [
          project_ack(%{
            plan_id: plan_id,
            created_at: "2026-06-28T09:04:00Z",
            acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
          }),
          project_ack(%{
            plan_id: plan_id,
            created_at: "2026-06-28T09:04:00Z",
            acknowledged_action_codes: ["confirm_hub_executor_modes"]
          })
        ]
      )

    assert [%{operator_acknowledgement: %{status: "accepted", created_at: "2026-06-28T09:04:00Z"}}] = same_time.projects

    no_candidate_time =
      ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(),
        now: ~U[2026-06-28 09:00:00Z],
        operator_acknowledgements: [
          project_ack(%{
            plan_id: plan_id,
            created_at: "bad-time",
            acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]
          }),
          project_ack(%{
            plan_id: plan_id,
            created_at: "also-bad",
            acknowledged_action_codes: ["confirm_hub_executor_modes"]
          })
        ]
      )

    assert [%{operator_acknowledgement: %{status: "malformed", acknowledged_action_codes: ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]}}] =
             no_candidate_time.projects

    assert %{created_at: "2026-06-28T09:00:00Z"} =
             ActivationPlan.acknowledgement_snapshot(%{status: "accepted", created_at: ~U[2026-06-28 09:00:00Z]})

    assert %{note_summary: %{note_sha256: "hash", note_bytes: 6}} =
             ActivationPlan.acknowledgement_snapshot(%{status: "accepted", note_summary: %{"note_sha256" => "hash", "note_bytes" => "6"}})

    assert %{note_summary: %{note_sha256: "hash", note_bytes: nil}} =
             ActivationPlan.acknowledgement_snapshot(%{status: "accepted", note_summary: %{"note_sha256" => "hash", "note_bytes" => "bad"}})

    missing_detail =
      ActivationPlan.build(
        readiness(%{projects: [readiness_project("missing-detail", "ready_for_dry_run")]}),
        [%{project_id: "missing-detail", detail: %{identity: nil}}],
        overview(),
        now: ~U[2026-06-28 09:00:00Z]
      )

    assert [%{provider: %{kind: nil, provider_scope_key: nil}}] = missing_detail.projects

    non_string_project_id =
      ActivationPlan.project_plan_snapshot(%{
        version: "bad-version",
        project_id: %{bad: "id"},
        readiness_decision: "legacy_only",
        operator_acknowledgement: %{status: "missing"}
      })

    assert non_string_project_id.version == 1
    assert non_string_project_id.project_id == ""
  end

  defp ack_status(acks) do
    summary =
      ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(),
        operator_acknowledgements: acks,
        now: ~U[2026-06-28 09:00:00Z]
      )

    ack = summary.projects |> hd() |> Map.fetch!(:operator_acknowledgement)
    {ack.status, ack.conflict_reasons}
  end

  defp ack_for(raw_ack) do
    base = ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(), now: ~U[2026-06-28 09:00:00Z])
    plan_id = hd(base.projects).plan_id

    raw_ack =
      if is_map(raw_ack) do
        Map.merge(project_ack(%{plan_id: plan_id}), raw_ack)
      else
        raw_ack
      end

    summary =
      ActivationPlan.build(readiness(), [project("ready", "github:owner/repo")], overview(),
        operator_acknowledgements: [raw_ack],
        now: ~U[2026-06-28 09:00:00Z]
      )

    summary.projects |> hd() |> Map.fetch!(:operator_acknowledgement)
  end

  defp readiness(overrides \\ %{}) do
    overrides = Map.new(overrides)

    Map.merge(
      %{
        version: 1,
        generated_at: "2026-06-28T09:00:00Z",
        status: "ready_for_hub_management",
        hub_runtime: runtime(enabled: true, scheduler_enabled: true, activation_probe: %{mode: "host_service"}),
        global_blocking_risks: [],
        global_advisory_risks: [],
        projects: [readiness_project("ready", "ready_for_hub_management")]
      },
      overrides
    )
  end

  defp readiness_project(project_id, decision, opts \\ []) do
    %{
      project_id: project_id,
      migration_state: Keyword.get(opts, :migration_state, "hub_ready"),
      decision: decision,
      blocking_reasons: Keyword.get(opts, :blocking_reasons, []),
      advisory_reasons: Keyword.get(opts, :advisory_reasons, [%{code: "hub_management_requires_operator_mark_hub_managed"}]),
      required_operator_actions: Keyword.get(opts, :required_operator_actions, ["confirm_hub_executor_modes", "mark_hub_managed_after_checks"]),
      evidence:
        Keyword.get(opts, :evidence, %{
          stable_fact: "same",
          checked_at: "2026-06-28T09:00:00Z",
          nested: %{loaded_at: "2026-06-28T08:00:00Z", state: "ready"}
        })
    }
  end

  defp project(project_id, scope_key) do
    %{
      project_id: project_id,
      provider: %{
        kind: scope_key |> String.split(":", parts: 2) |> List.first(),
        provider_scope_key: scope_key,
        scope: %{owner: "owner", repo: "repo"}
      }
    }
  end

  defp runtime(overrides) when is_list(overrides), do: runtime(Map.new(overrides))

  defp runtime(overrides) do
    Map.merge(
      %{
        enabled: true,
        mode: "hub",
        read_only: false,
        scheduler_enabled: true,
        scheduler_status: "scheduled",
        provider_executor: %{mode: "real"},
        writeback_executor: %{mode: "real"},
        worker_starter: %{mode: "real"},
        activation_probe: %{mode: "host_service", host_service_probe: true}
      },
      overrides
    )
  end

  defp overview, do: %{scheduler: %{enabled: true, status: "scheduled"}}

  defp project_ack(overrides) do
    Map.merge(
      %{
        project_id: "ready",
        plan_id: "plan",
        source: "operator-file",
        created_at: "2026-06-28T09:01:00Z"
      },
      overrides
    )
  end
end
