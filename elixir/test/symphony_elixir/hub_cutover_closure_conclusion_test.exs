defmodule SymphonyElixir.HubCutoverClosureConclusionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.CutoverClosureConclusion

  @now ~U[2026-07-01 09:00:00Z]
  @now_iso DateTime.to_iso8601(@now)

  test "maps closed succeeded and no-side-effect conclusions separately" do
    summary = %{
      generated_at: @now_iso,
      projects: [
        project_summary("alpha", "closed_succeeded"),
        project_summary("beta", "closed_no_side_effect")
      ]
    }

    conclusion = CutoverClosureConclusion.build(summary, now: @now)
    projects = projects_by_id(conclusion)

    assert conclusion.fully_closed == true
    assert conclusion.operation_success == false
    assert conclusion.closure_chain_status == "closed_no_side_effect"

    assert projects["alpha"].conclusion == "closed_succeeded"
    assert projects["alpha"].operation_success == true
    assert projects["alpha"].required_action_codes == ["review_success_evidence"]

    assert projects["beta"].conclusion == "closed_no_side_effect"
    assert projects["beta"].summary_code == "closure_closed_no_side_effect"
    assert projects["beta"].operation_success == false
    assert projects["beta"].required_action_codes == ["review_no_side_effect_evidence"]
  end

  test "maps open retryable and manual attention without automatic replay semantics" do
    conclusion =
      CutoverClosureConclusion.build(
        %{
          generated_at: @now_iso,
          projects: [
            project_summary("alpha", "open_retryable"),
            project_summary("beta", "open_manual_attention")
          ]
        },
        now: @now
      )

    projects = projects_by_id(conclusion)

    refute conclusion.fully_closed
    refute conclusion.auto_retry_allowed
    refute conclusion.auto_replay_allowed
    refute conclusion.queued_replay
    refute conclusion.pending_execution
    refute conclusion.pending_retry
    refute conclusion.legacy_takeover

    assert projects["alpha"].conclusion == "waiting_explicit_retry_consideration"
    assert projects["alpha"].required_action_codes == ["request_explicit_retry_consideration"]
    refute projects["alpha"].summary_code =~ "automatic"
    refute projects["alpha"].summary_code =~ "queued"

    assert projects["beta"].conclusion == "manual_attention_required"
    assert projects["beta"].required_action_codes == ["resolve_manual_attention"]
    assert projects["beta"].evidence_references |> inspect() =~ "safe-beta"
  end

  test "blocking statuses conservatively prevent fully closed device rollup" do
    conclusion =
      CutoverClosureConclusion.build(
        %{
          generated_at: @now_iso,
          projects: [
            project_summary("closed", "closed_succeeded"),
            project_summary("stale", "stale"),
            project_summary("conflict", "conflict"),
            project_summary("bad", "malformed"),
            project_summary("future", "unsupported")
          ]
        },
        now: @now
      )

    refute conclusion.fully_closed
    assert conclusion.closure_chain_status == "malformed"
    assert conclusion.conclusion == "input_malformed"
    assert "fix_malformed_chain_input" in conclusion.required_action_codes
    assert "resolve_conflict" in conclusion.required_action_codes
    assert "refresh_stale_evidence" in conclusion.required_action_codes
    assert "unsupported_closure_report_slice" in conclusion.required_action_codes
  end

  test "no_chain and no_request do not imply execution, retry, replay, or legacy takeover" do
    conclusion =
      CutoverClosureConclusion.build(
        %{
          generated_at: @now_iso,
          status: "no_request",
          counts: %{no_request_count: 1},
          projects: [project_summary("alpha", "no_request")]
        },
        now: @now
      )

    assert conclusion.conclusion == "no_explicit_cutover_request"
    assert conclusion.required_action_codes == ["none_required"]
    refute conclusion.fully_closed
    refute conclusion.pending_execution
    refute conclusion.pending_retry
    refute conclusion.queued_replay
    refute conclusion.legacy_takeover
  end

  test "reference status conflicts are retained as safe blockers and sensitive material is dropped" do
    project =
      project_summary("alpha", "open_retryable",
        counts:
          count_map("open_retryable")
          |> Map.merge(%{
            replay_decision_reference_status_counts: %{conflict: 1},
            reference_status_counts: %{replay_decision: %{conflict: 1}}
          }),
        recent_reference_reason_codes: [
          "retryable_outcome_waiting_for_explicit_consideration",
          "full prompt with ghp_secret should be dropped"
        ],
        recent_reference_action_codes: ["re_evaluate_explicit_retry_consideration"],
        safe_evidence_fingerprints: %{
          outcome: "safe-alpha-outcome",
          token: "ghp_secret",
          raw_config: "raw config with token",
          local_path: "/home/jhihjian/private/runtime.log"
        }
      )

    conclusion = CutoverClosureConclusion.build(%{generated_at: @now_iso, projects: [project]}, now: @now)
    [project_conclusion] = conclusion.projects

    assert "request_explicit_retry_consideration" in project_conclusion.required_action_codes
    assert "resolve_conflict" in project_conclusion.required_action_codes

    assert Enum.any?(project_conclusion.blocked_by, fn blocker ->
             blocker.code == "reference_status_conflict" and blocker.reference_type == "replay_decision"
           end)

    safe_text = inspect(conclusion, limit: :infinity, printable_limit: :infinity)
    assert safe_text =~ "safe-alpha-outcome"
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "/home/jhihjian/private"
  end

  test "device observability input keeps project evidence scoped to each project" do
    device = %{
      overview: %{
        cutover_closure_chain: %{
          status: "open_manual_attention",
          counts: count_map("open_manual_attention"),
          read_only: true,
          no_side_effects: true,
          auto_replay_allowed: false
        }
      },
      projects: [
        %{
          project_id: "alpha",
          cutover_closure_chain: project_summary("alpha", "closed_succeeded", safe_evidence_fingerprints: %{outcome: "safe-alpha-only"})
        },
        %{
          project_id: "beta",
          detail: %{
            closure_chain: project_summary("beta", "open_manual_attention", safe_evidence_fingerprints: %{outcome: "safe-beta-only"})
          }
        }
      ]
    }

    conclusion = CutoverClosureConclusion.build(device, now: @now)
    projects = projects_by_id(conclusion)

    assert conclusion.project_count == 2
    assert conclusion.closure_chain_status == "open_manual_attention"

    assert projects["alpha"].conclusion == "closed_succeeded"
    assert projects["beta"].conclusion == "manual_attention_required"

    alpha_text = inspect(projects["alpha"], limit: :infinity, printable_limit: :infinity)
    beta_text = inspect(projects["beta"], limit: :infinity, printable_limit: :infinity)

    assert alpha_text =~ "safe-alpha-only"
    refute alpha_text =~ "safe-beta-only"
    assert beta_text =~ "safe-beta-only"
    refute beta_text =~ "safe-alpha-only"
  end

  test "single recent chain fixture can be interpreted as an operator conclusion" do
    conclusion = CutoverClosureConclusion.build(chain_fixture("retryable"), now: @now)

    assert conclusion.conclusion == "waiting_explicit_retry_consideration"
    assert conclusion.closure_chain_status == "open_retryable"
    assert conclusion.required_action_codes == ["request_explicit_retry_consideration"]

    assert [%{closure_chain_status: "open_retryable"}] = conclusion.recent_chains
    assert [%{project_id: "alpha", closure_chain_status: "open_retryable"}] = conclusion.projects
  end

  defp projects_by_id(conclusion), do: Map.new(conclusion.projects, &{&1.project_id, &1})

  defp project_summary(project_id, status, attrs \\ []) do
    attrs = Map.new(attrs)

    Map.merge(
      %{
        version: 1,
        project_id: project_id,
        status: status,
        counts: Map.get(attrs, :counts, count_map(status)),
        recent_reference_reason_codes: ["#{status}_reason"],
        recent_reference_action_codes: ["#{status}_action"],
        safe_evidence_fingerprints: %{outcome: "safe-#{project_id}-outcome"},
        read_only: true,
        no_side_effects: true,
        auto_replay_allowed: false
      },
      Map.delete(attrs, :counts)
    )
  end

  defp count_map(status) do
    %{
      no_chain_count: 0,
      no_request_count: 0,
      closed_succeeded_count: 0,
      closed_no_side_effect_count: 0,
      open_retryable_count: 0,
      open_manual_attention_count: 0,
      conflict_count: 0,
      stale_count: 0,
      malformed_count: 0,
      unsupported_count: 0
    }
    |> Map.put(String.to_atom("#{status}_count"), 1)
  end

  defp chain_fixture(status) do
    %{
      project_id: "alpha",
      provider_scope: provider_scope("alpha"),
      operation: "writeback",
      side_effect_source: "writeback_executor",
      attempt_fingerprint: "attempt-alpha",
      replay_key: "replay-alpha",
      request: %{request_fingerprint: "request-alpha"},
      readiness_permit: %{permit_fingerprint: "permit-alpha", decision: "ready_for_execution_consideration"},
      authorization: %{
        authorization_record_fingerprint: "record-alpha",
        authorization_request_fingerprint: "auth-alpha"
      },
      consumption_guard: %{
        project_id: "alpha",
        provider_scope: provider_scope("alpha"),
        operation: "writeback",
        side_effect_source: "writeback_executor",
        decision: "allowed",
        allowed: true,
        decision_fingerprint: "guard-alpha"
      },
      outcome: %{
        project_id: "alpha",
        provider_scope: provider_scope("alpha"),
        operation: "writeback",
        side_effect_source: "writeback_executor",
        status: status,
        reason_code: "execution_retryable",
        action_code: "re_evaluate_explicit_retry_consideration",
        attempt_fingerprint: "attempt-alpha",
        replay_key: "replay-alpha",
        cutover_operation_request_fingerprint: "request-alpha",
        readiness_permit_fingerprint: "permit-alpha",
        authorization_record_fingerprint: "record-alpha",
        authorization_request_fingerprint: "auth-alpha",
        consumption_guard_fingerprint: "guard-alpha",
        evidence_fingerprint: "outcome-alpha",
        side_effect_entered: false,
        side_effect_may_have_happened: false,
        no_side_effects: status != "retryable",
        generated_at: @now_iso
      }
    }
  end

  defp provider_scope(project_id) do
    %{
      kind: "github",
      key: "github:o/#{project_id}",
      provider_scope_key: "github:o/#{project_id}",
      scope: %{owner: "o", repo: project_id}
    }
  end
end
