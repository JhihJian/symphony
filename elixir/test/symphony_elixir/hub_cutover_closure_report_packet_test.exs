defmodule SymphonyElixir.HubCutoverClosureReportPacketTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hub.CutoverClosureReportPacket

  @now ~U[2026-07-01 09:00:00Z]
  @now_iso DateTime.to_iso8601(@now)

  test "builds a device and project report packet without cross-project leakage" do
    chain = %{
      generated_at: @now_iso,
      status: "open_manual_attention",
      counts: count_map("open_manual_attention"),
      recent_reference_reason_codes: ["device_manual_reason"],
      recent_reference_action_codes: ["device_manual_action"],
      projects: [
        project_summary("alpha", "closed_succeeded",
          provider_scope: provider_scope("alpha"),
          safe_evidence_fingerprints: %{outcome: "safe-alpha-only"}
        ),
        project_summary("beta", "open_manual_attention",
          provider_scope: provider_scope("beta"),
          safe_evidence_fingerprints: %{outcome: "safe-beta-only"}
        )
      ]
    }

    packet =
      CutoverClosureReportPacket.build(
        %{
          hub_cutover_closure_chain: chain,
          hub_cutover_closure_conclusion: %{generated_at: @now_iso}
        },
        now: @now
      )

    projects = projects_by_id(packet)

    assert packet.report_version == 1
    assert packet.generated_at == @now_iso
    assert packet.read_only_boundary.read_only == true
    assert packet.read_only_boundary.provider_calls == false
    assert packet.device.report_status == "manual_attention_required"
    assert packet.device.operator_conclusion == "manual_attention_required"
    assert packet.device.closure_chain.retained_reference_status_counts.closeout.current == 0
    assert "device_manual_action" in packet.device.closure_chain.recent_action_codes
    assert is_binary(packet.device.closure_chain.safe_evidence_fingerprint)

    assert projects["alpha"].provider_scope.provider_scope_key == "github:o/alpha"
    assert projects["alpha"].operator_conclusion == "closed_succeeded"
    assert projects["alpha"].safe_evidence_fingerprints.outcome == "safe-alpha-only"
    assert projects["alpha"].required_action_codes == ["review_success_evidence"]

    assert projects["beta"].provider_scope.provider_scope_key == "github:o/beta"
    assert projects["beta"].operator_conclusion == "manual_attention_required"
    assert projects["beta"].safe_evidence_fingerprints.outcome == "safe-beta-only"
    assert projects["beta"].required_action_codes == ["resolve_manual_attention"]

    alpha_text = inspect(projects["alpha"], limit: :infinity, printable_limit: :infinity)
    beta_text = inspect(projects["beta"], limit: :infinity, printable_limit: :infinity)

    assert alpha_text =~ "safe-alpha-only"
    refute alpha_text =~ "safe-beta-only"
    assert beta_text =~ "safe-beta-only"
    refute beta_text =~ "safe-alpha-only"
  end

  test "preserves supplied conclusion snapshot when chain snapshot is also present" do
    chain = %{
      generated_at: @now_iso,
      status: "open_retryable",
      counts: count_map("open_retryable"),
      projects: [
        project_summary("alpha", "open_retryable",
          provider_scope: provider_scope("alpha"),
          safe_evidence_fingerprints: %{outcome: "safe-alpha-chain"}
        )
      ]
    }

    conclusion = %{
      generated_at: @now_iso,
      closure_chain_status: "open_retryable",
      conclusion: "manual_attention_required",
      severity: "warning",
      attention_level: "manual_attention",
      summary_code: "custom_manual_attention_summary",
      required_action_codes: ["custom_action"],
      blocked_by: [%{code: "custom_blocker"}],
      projects: [
        %{
          project_id: "alpha",
          closure_chain_status: "open_retryable",
          conclusion: "custom_project_conclusion",
          required_action_codes: ["custom_project_action"],
          blocked_by: [%{code: "custom_project_blocker"}]
        }
      ]
    }

    packet =
      CutoverClosureReportPacket.build(
        %{
          hub_cutover_closure_chain: chain,
          hub_cutover_closure_conclusion: conclusion
        },
        now: @now
      )

    [project] = packet.projects

    assert packet.report_status == "retry_consideration_required"
    assert packet.operator_conclusion == "manual_attention_required"
    assert packet.required_action_codes == ["custom_action"]
    assert packet.blocked_by == [%{code: "custom_blocker"}]
    assert packet.summary_code == "custom_manual_attention_summary"

    assert project.project_id == "alpha"
    assert project.provider_scope.provider_scope_key == "github:o/alpha"
    assert project.safe_evidence_fingerprints.outcome == "safe-alpha-chain"
    assert project.operator_conclusion == "custom_project_conclusion"
    assert project.required_action_codes == ["custom_project_action"]
    assert project.blocked_by == [%{code: "custom_project_blocker"}]
  end

  test "conservatively rolls up open retryable and no-side-effect statuses" do
    retryable =
      CutoverClosureReportPacket.build(
        %{
          generated_at: @now_iso,
          projects: [
            project_summary("alpha", "closed_succeeded"),
            project_summary("beta", "open_retryable")
          ]
        },
        now: @now
      )

    refute retryable.fully_closed
    refute retryable.operation_success
    assert retryable.report_status == "retry_consideration_required"
    assert retryable.operator_conclusion == "waiting_explicit_retry_consideration"
    assert retryable.device.boundary_flags.auto_retry_allowed == false
    assert retryable.device.boundary_flags.auto_replay_allowed == false
    assert retryable.device.boundary_flags.queued_replay == false
    assert retryable.device.boundary_flags.pending_execution == false
    assert retryable.device.boundary_flags.pending_retry == false
    assert retryable.device.boundary_flags.legacy_takeover == false
    assert "request_explicit_retry_consideration" in retryable.required_action_codes

    no_side_effect =
      CutoverClosureReportPacket.build(
        %{
          generated_at: @now_iso,
          projects: [project_summary("alpha", "closed_no_side_effect")]
        },
        now: @now
      )

    assert no_side_effect.fully_closed
    refute no_side_effect.operation_success
    assert no_side_effect.report_status == "closed_no_side_effect"
    assert no_side_effect.operator_conclusion == "closed_no_side_effect"
    refute no_side_effect.report_status == "fully_closed"
  end

  test "no_chain and no_request packets do not imply execution, retry, replay, or takeover" do
    no_chain = CutoverClosureReportPacket.build(%{generated_at: @now_iso}, now: @now)

    assert no_chain.report_status == "no_chain"
    assert no_chain.operator_conclusion == "no_explicit_closure_chain"
    assert no_chain.required_action_codes == ["none_required"]
    assert no_chain.projects == []
    refute no_chain.fully_closed
    assert no_chain.boundary_flags.pending_execution == false
    assert no_chain.boundary_flags.pending_retry == false
    assert no_chain.boundary_flags.queued_replay == false
    assert no_chain.boundary_flags.legacy_takeover == false

    no_request =
      CutoverClosureReportPacket.build(
        %{
          generated_at: @now_iso,
          projects: [project_summary("alpha", "no_request")]
        },
        now: @now
      )

    assert no_request.report_status == "no_request"
    assert no_request.operator_conclusion == "no_explicit_cutover_request"
    assert no_request.required_action_codes == ["none_required"]
    refute no_request.fully_closed
    assert no_request.boundary_flags.pending_execution == false
    assert no_request.boundary_flags.pending_retry == false
    assert no_request.boundary_flags.queued_replay == false
    assert no_request.boundary_flags.legacy_takeover == false
  end

  test "drops sensitive and raw fields from report packet output" do
    packet =
      CutoverClosureReportPacket.build(
        %{
          hub_cutover_closure_chain: %{
            generated_at: @now_iso,
            status: "open_retryable",
            counts: count_map("open_retryable"),
            projects: [
              project_summary("alpha", "open_retryable",
                provider_scope:
                  Map.merge(provider_scope("alpha"), %{
                    token: "ghp_secret_provider_token",
                    raw_config: "raw config with token",
                    local_path: "/home/jhihjian/private/provider.yaml"
                  }),
                evidence_references: [
                  %{
                    type: "raw",
                    raw_provider_payload: "raw provider payload should not survive",
                    authorization: "Bearer ghp_secret",
                    cookie: "session=secret",
                    transcript: "complete transcript should not survive",
                    comment_body: "complete comment body should be hashed",
                    pull_request_body: "complete PR body should be hashed",
                    raw_systemd_output: "raw systemd output should not survive",
                    stack_trace: "stack trace should not survive",
                    local_path: "/home/jhihjian/private/runtime.log",
                    safe_evidence_fingerprints: %{
                      outcome: "safe-alpha-outcome",
                      token: "ghp_secret",
                      raw_provider_payload: "raw provider payload should not survive",
                      local_path: "/home/jhihjian/private/evidence.json"
                    }
                  }
                ],
                safe_evidence_fingerprints: %{
                  outcome: "safe-alpha-outcome",
                  token: "ghp_secret",
                  raw_provider_payload: "raw provider payload should not survive",
                  raw_config: "raw config should not survive",
                  local_path: "/home/jhihjian/private/evidence.json"
                }
              )
            ]
          }
        },
        now: @now
      )

    safe_text = inspect(packet, limit: :infinity, printable_limit: :infinity)

    assert safe_text =~ "safe-alpha-outcome"
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "raw provider payload"
    refute safe_text =~ "complete transcript"
    refute safe_text =~ "complete comment body"
    refute safe_text =~ "complete PR body"
    refute safe_text =~ "/home/jhihjian/private"
    refute safe_text =~ "raw config"
    refute safe_text =~ "raw systemd output"
    refute safe_text =~ "stack trace"
  end

  test "read model boundary is structural and does not reference execution modules" do
    packet =
      CutoverClosureReportPacket.build(
        %{generated_at: @now_iso, projects: [project_summary("alpha", "closed_succeeded")]},
        now: @now
      )

    assert packet.read_only_boundary == packet.boundary_flags
    assert packet.read_only_boundary.consumes_safe_snapshots_only == true
    assert packet.read_only_boundary.provider_calls == false
    assert packet.read_only_boundary.authorization_consumption == false
    assert packet.read_only_boundary.dispatch_calls == false
    assert packet.read_only_boundary.worker_start_calls == false
    assert packet.read_only_boundary.writeback_calls == false
    assert packet.read_only_boundary.systemd_calls == false
    assert packet.read_only_boundary.config_mutation == false

    source = File.read!("lib/symphony_elixir/hub/cutover_closure_report_packet.ex")

    refute source =~ "ProviderExecutor"
    refute source =~ "RealWorkerStarter"
    refute source =~ "RealWritebackExecutor"
    refute source =~ "DispatchPlanApplication"
    refute source =~ "System.cmd"
    refute source =~ "Systemd"
  end

  defp projects_by_id(packet), do: Map.new(packet.projects, &{&1.project_id, &1})

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
        provider_scope: provider_scope(project_id),
        read_only: true,
        no_side_effects: true,
        auto_replay_allowed: false
      },
      Map.drop(attrs, [:counts])
    )
  end

  defp count_map(status) do
    %{
      chain_count: 1,
      no_chain_count: 0,
      no_request_count: 0,
      closed_succeeded_count: 0,
      closed_no_side_effect_count: 0,
      open_retryable_count: 0,
      open_manual_attention_count: 0,
      conflict_count: 0,
      stale_count: 0,
      malformed_count: 0,
      unsupported_count: 0,
      closeout_reference_status_counts: zero_reference_counts(),
      replay_decision_reference_status_counts: zero_reference_counts(),
      replay_request_audit_reference_status_counts: zero_reference_counts(),
      reference_status_counts: %{
        closeout: zero_reference_counts(),
        replay_decision: zero_reference_counts(),
        replay_request_audit: zero_reference_counts()
      }
    }
    |> Map.put(String.to_atom("#{status}_count"), 1)
  end

  defp zero_reference_counts do
    %{missing: 0, current: 0, stale: 0, conflict: 0, malformed: 0, unsupported: 0}
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
