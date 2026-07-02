defmodule SymphonyElixir.HubDashboardDetailTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Hub.{CutoverClosureChain, DeviceObservability}

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule StaticOrchestrator do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    original_endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, original_endpoint_config)
    end)

    :ok
  end

  test "dashboard renders Hub device overview and project detail when Hub summary exists" do
    hub_name = Module.concat(__MODULE__, :HubDashboardRuntime)

    start_supervised!(
      {StaticOrchestrator, name: hub_name, snapshot: hub_snapshot()},
      id: :hub_dashboard_runtime
    )

    start_endpoint(orchestrator: hub_name)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Hub 设备总览"
    assert html =~ "Hub 项目明细"
    assert html =~ "Migration Readiness"
    assert html =~ "Activation Plan / Ack"
    assert html =~ "Cutover Audit"
    assert html =~ "Execution Permit"
    assert html =~ "Execution Authorization"
    assert html =~ "Replay Decision"
    assert html =~ "Replay Request"
    assert html =~ "Closure Chain"
    assert html =~ "Closure Conclusion"
    assert html =~ "scheduler scheduled"
    assert html =~ "runtime_reconciliation"
    assert html =~ "provider_failure"
    assert html =~ "alpha"
    assert html =~ "ready"
    assert html =~ "closure closed_succeeded"
    assert html =~ "conclusion closed_succeeded"
    assert html =~ "gamma"
    assert html =~ "manual attention"
    assert html =~ "unknown_manual_attention"
    assert html =~ "plan unknown_manual_attention"
    assert html =~ "ack missing"
    assert html =~ "audit no_request"
    assert html =~ "permit no_request"
    assert html =~ "auth no_ready_permit"
    assert html =~ "replay blocked_unresolved_outcome"
    assert html =~ "replay request no_request"
    assert html =~ "closure open_manual_attention"
    assert html =~ "manual_attention_required"
    assert html =~ "summary closure_open_manual_attention_required"
    assert html =~ "actions resolve_manual_attention"
    assert html =~ "blocked manual_attention_required/open_manual_attention"
    assert html =~ "closeout refs current"
    assert html =~ "replay decision refs current"
    assert html =~ "request audit refs current"
    assert html =~ "replay reason matching_closeout_missing"
    assert html =~ "closure reason closeout_reference_current"
    assert html =~ "closure action record_cutover_replay_request_audit"
    assert html =~ "closure fp outcome=gamma-outcome-fp"
    assert html =~ "conclusion fp outcome=gamma-outcome-fp"
    assert html =~ "auto replay allowed false"
    assert html =~ "auto retry allowed false"
    assert html =~ "pending execution false"
    assert html =~ "pending retry false"
    assert html =~ "queued replay false"
    assert html =~ "legacy takeover false"
    assert html =~ "ack resolve_writeback_manual_attention"
    assert html =~ "action resolve_writeback_manual_attention"
    assert html =~ "writeback pending"
    refute html =~ "ghp_secret"
    refute html =~ "Bearer"
    refute html =~ "raw systemd output"
    refute html =~ "queued replay true"
    refute html =~ "automatic retry"
  end

  test "dashboard omits Hub detail for legacy snapshots" do
    legacy_name = Module.concat(__MODULE__, :LegacyDashboardRuntime)

    start_supervised!(
      {StaticOrchestrator, name: legacy_name, snapshot: legacy_snapshot()},
      id: :legacy_dashboard_runtime
    )

    start_endpoint(orchestrator: legacy_name)

    {:ok, _view, legacy_html} = live(build_conn(), "/")
    refute legacy_html =~ "Hub 设备总览"
    refute legacy_html =~ "Hub 项目明细"
    refute legacy_html =~ "Hub-managed"
  end

  test "state API returns Hub overview and detail without raw sensitive material" do
    hub_name = Module.concat(__MODULE__, :HubApiRuntime)

    start_supervised!(
      {StaticOrchestrator, name: hub_name, snapshot: hub_snapshot()},
      id: :hub_api_runtime
    )

    start_endpoint(orchestrator: hub_name)

    payload = json_response(get(build_conn(), "/api/v1/state"), 200)
    hub = payload["hub_device_observability"]

    assert hub["overview"]["scheduler"]["status"] == "scheduled"
    assert hub["overview"]["provider_governance"]["recent_failure_count"] == 1
    assert hub["overview"]["writeback"]["manual_attention_count"] == 1
    assert hub["migration_readiness"]["status"] == "blocked"
    assert hub["migration_readiness"]["counts"]["decisions"]["unknown_manual_attention"] == 2
    assert hub["activation_plan"]["status"] == "blocked"
    assert hub["activation_plan"]["counts"]["acknowledgement_statuses"]["missing"] == 2
    assert hub["cutover_operation_audit"]["status"] == "no_request"
    assert hub["cutover_operation_audit"]["counts"]["request_count"] == 0
    assert hub["cutover_operation_audit"]["counts"]["no_request_count"] == 2
    assert hub["cutover_readiness_permit"]["status"] == "no_request"
    assert hub["cutover_readiness_permit"]["counts"]["permit_count"] == 0
    assert hub["cutover_readiness_permit"]["counts"]["no_request_count"] == 2
    assert hub["cutover_execution_authorization_ledger"]["status"] == "no_ready_permit"
    assert hub["cutover_execution_authorization_ledger"]["counts"]["authorization_request_count"] == 0
    assert hub["cutover_execution_authorization_ledger"]["counts"]["record_count"] == 0
    assert hub["cutover_authorization_consumption_guard"]["status"] == "no_consumption"
    assert hub["cutover_authorization_consumption_guard"]["counts"]["consumption_count"] == 0
    assert hub["cutover_replay_decision"]["status"] == "blocked_unresolved_outcome"
    assert hub["cutover_replay_decision"]["counts"]["unresolved_outcome_blocked_count"] == 1
    assert hub["overview"]["cutover_replay_decision"]["status"] == "blocked_unresolved_outcome"
    assert hub["overview"]["cutover_replay_decision"]["unresolved_outcome_blocked_count"] == 1
    assert hub["overview"]["cutover_replay_decision"]["no_unresolved_outcome_count"] == 1
    assert hub["cutover_replay_request_audit"]["status"] == "no_request"
    assert hub["cutover_replay_request_audit"]["counts"]["request_count"] == 0
    assert hub["overview"]["cutover_replay_request_audit"]["status"] == "no_request"
    assert hub["overview"]["cutover_replay_request_audit"]["request_count"] == 0
    assert hub["overview"]["cutover_replay_request_audit"]["no_request_count"] == 2
    assert hub["cutover_closure_chain"]["status"] == "open_manual_attention"
    assert hub["cutover_closure_chain"]["counts"]["closed_succeeded_count"] == 1
    assert hub["cutover_closure_chain"]["counts"]["open_manual_attention_count"] == 1
    assert hub["overview"]["cutover_closure_chain"]["status"] == "open_manual_attention"
    assert hub["overview"]["cutover_closure_chain"]["closure_status_counts"]["closed_succeeded"] == 1
    assert hub["overview"]["cutover_closure_chain"]["closure_status_counts"]["open_manual_attention"] == 1
    assert hub["overview"]["cutover_closure_chain"]["closeout_reference_status_counts"]["current"] == 1
    assert hub["overview"]["cutover_closure_chain"]["replay_decision_reference_status_counts"]["current"] == 1
    assert hub["overview"]["cutover_closure_chain"]["replay_request_audit_reference_status_counts"]["current"] == 1
    assert hub["overview"]["cutover_closure_chain"]["read_only"] == true
    assert hub["overview"]["cutover_closure_chain"]["no_side_effects"] == true
    assert hub["overview"]["cutover_closure_chain"]["auto_replay_allowed"] == false
    assert hub["cutover_closure_conclusion"]["conclusion"] == "manual_attention_required"
    assert hub["cutover_closure_conclusion"]["summary_code"] == "closure_open_manual_attention_required"
    assert hub["cutover_closure_conclusion"]["fully_closed"] == false
    assert hub["cutover_closure_conclusion"]["operation_success"] == false
    assert hub["cutover_closure_conclusion"]["auto_retry_allowed"] == false
    assert hub["cutover_closure_conclusion"]["auto_replay_allowed"] == false
    assert hub["overview"]["cutover_closure_conclusion"]["conclusion"] == "manual_attention_required"
    assert hub["overview"]["cutover_closure_conclusion"]["severity"] == "warning"
    assert hub["overview"]["cutover_closure_conclusion"]["attention_level"] == "manual_attention"
    assert hub["overview"]["cutover_closure_conclusion"]["summary_code"] == "closure_open_manual_attention_required"
    assert "resolve_manual_attention" in hub["overview"]["cutover_closure_conclusion"]["required_action_codes"]
    assert hub["overview"]["cutover_closure_conclusion"]["blocked_by"] != []
    assert hub["overview"]["cutover_closure_conclusion"]["evidence_references"] != []
    assert hub["overview"]["cutover_closure_conclusion"]["read_only"] == true
    assert hub["overview"]["cutover_closure_conclusion"]["no_side_effects"] == true
    assert hub["overview"]["cutover_closure_conclusion"]["auto_retry_allowed"] == false
    assert hub["overview"]["cutover_closure_conclusion"]["auto_replay_allowed"] == false
    assert hub["overview"]["cutover_closure_conclusion"]["pending_execution"] == false
    assert hub["overview"]["cutover_closure_conclusion"]["pending_retry"] == false
    assert hub["overview"]["cutover_closure_conclusion"]["queued_replay"] == false
    assert hub["overview"]["cutover_closure_conclusion"]["legacy_takeover"] == false

    projects = Map.new(hub["projects"], &{&1["project_id"], &1})
    assert projects["alpha"]["detail"]["candidate_intake"]["counts"]["candidate_count"] == 1
    assert projects["alpha"]["cutover_operation_audit"]["status"] == "no_request"
    assert projects["alpha"]["cutover_operation_audit"]["request"] == nil
    assert projects["alpha"]["cutover_readiness_permit"]["status"] == "no_request"
    assert projects["alpha"]["cutover_readiness_permit"]["permits"] == []
    assert projects["alpha"]["cutover_execution_authorization_ledger"]["status"] == "no_ready_permit"
    assert projects["alpha"]["cutover_execution_authorization_ledger"]["records"] == []
    assert projects["alpha"]["cutover_authorization_consumption_guard"] == nil
    assert projects["alpha"]["cutover_replay_decision"]["status"] == "no_unresolved_outcome"
    assert projects["alpha"]["cutover_replay_request_audit"]["status"] == "no_request"
    assert projects["alpha"]["cutover_closure_chain"]["status"] == "closed_succeeded"
    assert projects["alpha"]["detail"]["closure_chain"]["safe_evidence_fingerprints"]["outcome"] == "alpha-outcome-fp"
    assert projects["alpha"]["cutover_closure_conclusion"]["conclusion"] == "closed_succeeded"
    assert projects["alpha"]["cutover_closure_conclusion"]["operation_success"] == true
    assert projects["alpha"]["detail"]["closure_conclusion"]["summary_code"] == "closure_closed_succeeded"
    assert projects["alpha"]["detail"]["closure_conclusion"]["safe_evidence_fingerprints"]["outcome"] == "alpha-outcome-fp"
    assert projects["alpha"]["detail"]["replay_request_audit"]["counts"]["request_count"] == 0
    assert projects["gamma"]["detail"]["writeback"]["counts"]["manual_attention"] == 1
    assert projects["gamma"]["cutover_replay_decision"]["status"] == "blocked_unresolved_outcome"
    assert projects["gamma"]["detail"]["replay_decision"]["blocked_replay"] != []
    assert projects["gamma"]["cutover_replay_request_audit"]["status"] == "no_request"
    assert projects["gamma"]["detail"]["replay_request_audit"]["auto_replay_allowed"] == false
    assert projects["gamma"]["cutover_closure_chain"]["status"] == "open_manual_attention"
    assert projects["gamma"]["detail"]["closure_chain"]["safe_evidence_fingerprints"]["outcome"] == "gamma-outcome-fp"
    assert projects["gamma"]["cutover_closure_conclusion"]["conclusion"] == "manual_attention_required"
    assert projects["gamma"]["cutover_closure_conclusion"]["operation_success"] == false
    assert projects["gamma"]["cutover_closure_conclusion"]["auto_retry_allowed"] == false
    assert projects["gamma"]["cutover_closure_conclusion"]["auto_replay_allowed"] == false
    assert projects["gamma"]["detail"]["closure_conclusion"]["summary_code"] == "closure_open_manual_attention_required"
    assert projects["gamma"]["detail"]["closure_conclusion"]["safe_evidence_fingerprints"]["outcome"] == "gamma-outcome-fp"
    assert projects["gamma"]["detail"]["closure_conclusion"]["queued_replay"] == false
    assert projects["gamma"]["detail"]["closure_conclusion"]["pending_execution"] == false
    assert projects["gamma"]["detail"]["closure_conclusion"]["pending_retry"] == false
    assert projects["gamma"]["detail"]["closure_conclusion"]["legacy_takeover"] == false
    assert projects["gamma"]["detail"]["closure_chain"]["closeout_reference_status_counts"]["current"] == 1
    assert projects["gamma"]["detail"]["closure_chain"]["replay_decision_reference_status_counts"]["current"] == 1
    assert projects["gamma"]["detail"]["closure_chain"]["replay_request_audit_reference_status_counts"]["current"] == 1
    assert projects["gamma"]["detail"]["closure_chain"]["auto_replay_allowed"] == false
    assert projects["gamma"]["migration_readiness"]["decision"] == "unknown_manual_attention"
    assert projects["gamma"]["activation_plan"]["status"] == "unknown_manual_attention"
    assert projects["gamma"]["activation_plan"]["operator_acknowledgement"]["status"] == "missing"
    assert projects["gamma"]["migration_readiness"]["activation_plan"]["plan_id"] == projects["gamma"]["activation_plan"]["plan_id"]
    assert Enum.any?(projects["gamma"]["migration_readiness"]["blocking_reasons"], &(&1["code"] == "writeback_unknown"))
    assert Enum.any?(projects["gamma"]["migration_readiness"]["required_operator_actions"], &(&1["code"] == "resolve_writeback_manual_attention"))
    assert Enum.any?(projects["gamma"]["activation_plan"]["required_acknowledgements"], &(&1["code"] == "resolve_writeback_manual_attention"))
    refute projects["alpha"]["detail"]["closure_chain"]["safe_evidence_fingerprints"]["outcome"] == "gamma-outcome-fp"
    refute projects["alpha"]["detail"]["closure_conclusion"]["safe_evidence_fingerprints"]["outcome"] == "gamma-outcome-fp"

    safe_text = inspect(payload)
    refute safe_text =~ "ghp_secret"
    refute safe_text =~ "Authorization"
    refute safe_text =~ "raw systemd output"
    refute safe_text =~ "full prompt"
    refute safe_text =~ "raw provider response"
    refute safe_text =~ "queued replay"
    refute safe_text =~ "automatic retry"
  end

  defp start_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp hub_snapshot do
    %{
      running: [],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil,
      hub_device_observability:
        DeviceObservability.build(
          %{
            registry: registry(),
            poll_coordination: poll_coordination(),
            runtime_ledger: runtime_ledger(),
            scheduler: %{
              enabled: true,
              status: "scheduled",
              queued: true,
              next_tick_at: "2026-06-28T09:00:01Z",
              next_reason: "runtime_reconciliation"
            },
            candidate_intake: candidate_intake(),
            provider_queue: provider_queue(),
            cutover_replay_decision: replay_decision_summary(),
            cutover_closure_chain: closure_chain_summary()
          },
          now: ~U[2026-06-28 09:00:00Z]
        )
    }
  end

  defp legacy_snapshot do
    %{
      running: [],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }
  end

  defp registry do
    %{
      projects: [
        %{
          project_id: "alpha",
          name: "Alpha",
          dispatch_enabled: true,
          paused: false,
          status: :ready,
          tracker_summary: %{
            kind: "github",
            provider_scope_key: "github:o/r",
            provider_scope: %{owner: "o", repo: "r", token: "ghp_secret"},
            required_labels: ["symphony"]
          },
          runtime_summary: %{
            workspace_root: "/workspaces/alpha",
            max_concurrent_agents: 2,
            max_concurrent_agents_by_state: %{},
            polling_interval_ms: 30_000,
            server_port: nil
          },
          fingerprint: "alpha-fingerprint",
          loaded_at: ~U[2026-06-28 08:55:00Z],
          load_error: nil
        },
        %{
          project_id: "gamma",
          name: "Gamma",
          dispatch_enabled: true,
          paused: false,
          status: :ready,
          tracker_summary: %{
            kind: "github",
            provider_scope_key: "github:o/r",
            provider_scope: %{owner: "o", repo: "r"},
            required_labels: ["symphony"]
          },
          runtime_summary: %{
            workspace_root: "/workspaces/gamma",
            max_concurrent_agents: 1,
            max_concurrent_agents_by_state: %{},
            polling_interval_ms: 30_000,
            server_port: nil
          },
          fingerprint: "gamma-fingerprint",
          loaded_at: ~U[2026-06-28 08:55:00Z],
          load_error: nil
        }
      ],
      warnings: [],
      errors: []
    }
  end

  defp poll_coordination do
    %{
      projects: [
        %{
          project_id: "alpha",
          allow_poll: true,
          eligibility: %{reason: "ready", message: nil},
          provider_scope_key: "github:o/r",
          tracker_identity: %{kind: "github", provider_scope_key: "github:o/r"}
        },
        %{
          project_id: "gamma",
          allow_poll: false,
          eligibility: %{reason: "manual_attention", message: "writeback requires manual attention"},
          provider_scope_key: "github:o/r",
          tracker_identity: %{kind: "github", provider_scope_key: "github:o/r"}
        }
      ],
      provider_queue: provider_queue()
    }
  end

  defp provider_queue do
    %{
      pending_count: 1,
      running_count: 0,
      provider_scopes: [
        %{
          provider_scope_key: "github:o/r",
          pending_count: 1,
          running_count: 0,
          state: %{quota: %{remaining: 0}, backoff_until: "2026-06-28T09:05:00Z", circuit_state: "closed"}
        }
      ],
      pending: [%{project_id: "gamma", provider_scope_key: "github:o/r", operation_kind: "candidate_scan"}],
      running: [],
      recent_results: [
        %{
          project_id: "gamma",
          provider_scope_key: "github:o/r",
          operation_kind: "candidate_scan",
          status: "retryable_failure",
          error_class: "provider_failure",
          raw_provider_response: "raw provider response"
        }
      ],
      backpressure: [%{project_id: "gamma", provider_scope_key: "github:o/r", reason: "rate_limited"}]
    }
  end

  defp candidate_intake do
    %{
      status: "completed",
      projects: [
        %{
          project_id: "alpha",
          provider_kind: "github",
          provider_scope_key: "github:o/r",
          counts: %{candidate_count: 1, eligible_count: 1},
          candidates: [%{issue_key: "alpha:github:o/r:1", prompt: "full prompt"}],
          invalid_candidates: []
        }
      ]
    }
  end

  defp runtime_ledger do
    %{
      projects: [
        %{
          project_id: "alpha",
          counts: %{running: 1},
          active_attempts: [%{issue_key: "alpha:github:o/r:1", attempt_id: "attempt-1", status: :running}],
          pending_start_intents: [],
          workspace_leases: [%{issue_key: "alpha:github:o/r:1", attempt_id: "attempt-1", status: :active, systemd_output: "raw systemd output"}],
          retry_backoff: [],
          blocked_candidates: [],
          writebacks: %{counts: %{pending: 0, succeeded: 0, failed: 0, unknown: 0, manual_attention: 0}},
          lifecycle: %{counts: %{running: 1}},
          conflicts: [],
          manual_attention: []
        },
        %{
          project_id: "gamma",
          counts: %{manual_attention: 1},
          active_attempts: [],
          pending_start_intents: [],
          workspace_leases: [],
          retry_backoff: [],
          blocked_candidates: [],
          writebacks: %{
            counts: %{pending: 0, succeeded: 0, failed: 0, unknown: 1, manual_attention: 1},
            unknown: [%{intent_key: "gamma-writeback", result_status: "unknown", replay_policy: "non_idempotent", target: %{body: "Authorization: Bearer ghp_secret"}}],
            manual_attention: [%{intent_key: "gamma-writeback", manual_attention_reason: "unknown_non_idempotent_writeback"}]
          },
          lifecycle: %{counts: %{unknown: 1, manual_attention: 1}},
          conflicts: [],
          manual_attention: [%{code: "writeback_unknown_manual_attention"}]
        }
      ]
    }
  end

  defp replay_decision_summary do
    %{
      version: 1,
      generated_at: "2026-06-28T09:00:00Z",
      recent_decisions: [
        %{
          project_id: "alpha",
          provider_scope: %{kind: "github", key: "github:o/r", provider_scope_key: "github:o/r", scope: %{owner: "o", repo: "r"}},
          operation: "poll",
          side_effect_source: "candidate_scan",
          replay_key: "alpha-poll-replay",
          decision: "no_unresolved_outcome",
          allowed: true,
          reason_code: "no_matching_unresolved_outcome",
          evaluated_at: "2026-06-28T09:00:00Z",
          no_side_effects: true,
          auto_replay_allowed: false
        },
        %{
          project_id: "gamma",
          provider_scope: %{kind: "github", key: "github:o/r", provider_scope_key: "github:o/r", scope: %{owner: "o", repo: "r"}},
          operation: "writeback",
          side_effect_source: "writeback_executor",
          replay_key: "gamma-writeback-replay",
          outcome_replay_key: "gamma-writeback-replay",
          outcome_fingerprint: "gamma-outcome-fp",
          outcome_status: "unknown",
          decision: "blocked_unresolved_outcome",
          allowed: false,
          reason_code: "matching_closeout_missing",
          action_code: "record_execution_outcome_closeout",
          authorization_record_fingerprint: "gamma-auth-record-fp",
          readiness_permit_fingerprint: "gamma-permit-fp",
          consumption_guard_fingerprint: "gamma-consumption-fp",
          safe_evidence_fingerprints: %{
            authorization_record: "gamma-auth-record-fp",
            readiness_permit: "gamma-permit-fp",
            consumption_guard: "gamma-consumption-fp"
          },
          evaluated_at: "2026-06-28T09:00:00Z",
          no_side_effects: true,
          auto_replay_allowed: false
        }
      ],
      no_side_effects: true,
      auto_replay_allowed: false
    }
  end

  defp closure_chain_summary do
    CutoverClosureChain.build(
      %{
        closure_chains: [
          closure_chain("alpha", "succeeded"),
          closure_chain("gamma", "unknown", retained_references?: true)
        ]
      },
      now: ~U[2026-06-28 09:00:00Z]
    )
  end

  defp closure_chain(project_id, status, opts \\ []) do
    provider_scope = closure_provider_scope()

    base = %{
      project_id: project_id,
      provider_scope: provider_scope,
      operation: "writeback",
      side_effect_source: "writeback_executor",
      attempt_fingerprint: "#{project_id}-attempt-fp",
      replay_key: "#{project_id}-replay-key",
      request: %{request_fingerprint: "#{project_id}-request-fp"},
      readiness_permit: %{
        permit_fingerprint: "#{project_id}-permit-fp",
        decision: "ready_for_execution_consideration"
      },
      authorization: %{
        status: "authorized_for_explicit_execution",
        authorization_record_fingerprint: "#{project_id}-record-fp",
        authorization_request_fingerprint: "#{project_id}-auth-request-fp"
      },
      consumption_guard: %{
        project_id: project_id,
        provider_scope: provider_scope,
        operation: "writeback",
        side_effect_source: "writeback_executor",
        decision: "allowed",
        allowed: true,
        decision_fingerprint: "#{project_id}-guard-fp"
      },
      outcome: closure_outcome(project_id, provider_scope, status)
    }

    if Keyword.get(opts, :retained_references?, false) do
      Map.merge(base, retained_closure_references(project_id, provider_scope))
    else
      base
    end
  end

  defp closure_outcome(project_id, provider_scope, status) do
    %{
      project_id: project_id,
      provider_scope: provider_scope,
      operation: "writeback",
      side_effect_source: "writeback_executor",
      status: status,
      attempt_fingerprint: "#{project_id}-attempt-fp",
      replay_key: "#{project_id}-replay-key",
      cutover_operation_request_fingerprint: "#{project_id}-request-fp",
      readiness_permit_fingerprint: "#{project_id}-permit-fp",
      readiness_permit_decision: "ready_for_execution_consideration",
      authorization_record_fingerprint: "#{project_id}-record-fp",
      authorization_request_fingerprint: "#{project_id}-auth-request-fp",
      evidence_fingerprint: "#{project_id}-outcome-fp",
      safe_evidence_fingerprints: %{
        outcome: "#{project_id}-outcome-fp",
        cutover_operation_request: "#{project_id}-request-fp",
        readiness_permit: "#{project_id}-permit-fp",
        readiness_permit_decision: "ready_for_execution_consideration",
        authorization_record: "#{project_id}-record-fp",
        authorization_request: "#{project_id}-auth-request-fp",
        consumption_guard: "#{project_id}-guard-fp"
      },
      side_effect_entered: status in ["succeeded", "unknown"],
      side_effect_may_have_happened: status in ["succeeded", "unknown"],
      generated_at: "2026-06-28T09:00:00Z"
    }
  end

  defp retained_closure_references(project_id, provider_scope) do
    evidence = closure_outcome(project_id, provider_scope, "unknown").safe_evidence_fingerprints

    %{
      closeout: %{
        project_id: project_id,
        provider_scope: provider_scope,
        operation: "writeback",
        side_effect_source: "writeback_executor",
        replay_key: "#{project_id}-replay-key",
        status: "resolved",
        resolution_code: "allow_explicit_retry_consideration",
        closeout_record_fingerprint: "#{project_id}-closeout-fp",
        outcome_fingerprint: "#{project_id}-outcome-fp",
        outcome_status: "unknown",
        side_effect_entered: true,
        side_effect_may_have_happened: true,
        safe_evidence_fingerprints: evidence,
        reason_code: "closeout_reference_current",
        action_code: "evaluate_cutover_replay_decision",
        operator_request_fingerprint: "#{project_id}-operator-request-fp"
      },
      replay_decision: %{
        project_id: project_id,
        provider_scope: provider_scope,
        operation: "writeback",
        side_effect_source: "writeback_executor",
        replay_key: "#{project_id}-replay-key",
        decision: "retry_consideration_allowed",
        allowed: true,
        replay_decision_fingerprint: "#{project_id}-replay-decision-fp",
        outcome_fingerprint: "#{project_id}-outcome-fp",
        outcome_status: "unknown",
        closeout_record_fingerprint: "#{project_id}-closeout-fp",
        closeout_resolution_code: "allow_explicit_retry_consideration",
        side_effect_entered: true,
        side_effect_may_have_happened: true,
        safe_evidence_fingerprints: evidence,
        reason_code: "replay_decision_reference_current",
        action_code: "record_cutover_replay_request_audit",
        no_side_effects: true,
        auto_replay_allowed: false
      },
      replay_request_audit: %{
        project_id: project_id,
        provider_scope: provider_scope,
        operation: "writeback",
        side_effect_source: "writeback_executor",
        replay_key: "#{project_id}-replay-key",
        status: "would_allow_retry_consideration",
        outcome_link_status: "outcome_still_pending",
        request_fingerprint: "#{project_id}-replay-request-fp",
        audit_record_fingerprint: "#{project_id}-replay-audit-fp",
        outcome_fingerprint: "#{project_id}-outcome-fp",
        outcome_status: "unknown",
        closeout_record_fingerprint: "#{project_id}-closeout-fp",
        closeout_resolution_code: "allow_explicit_retry_consideration",
        replay_decision_fingerprint: "#{project_id}-replay-decision-fp",
        replay_decision_status: "retry_consideration_allowed",
        side_effect_entered: true,
        side_effect_may_have_happened: true,
        safe_evidence_fingerprints: evidence,
        reason_code: "replay_request_audit_reference_current",
        action_code: "wait_for_explicit_retry_operator_decision",
        no_side_effects: true,
        auto_replay_allowed: false
      }
    }
  end

  defp closure_provider_scope do
    %{
      kind: "github",
      key: "github:o/r",
      provider_scope_key: "github:o/r",
      scope: %{owner: "o", repo: "r"}
    }
  end
end
