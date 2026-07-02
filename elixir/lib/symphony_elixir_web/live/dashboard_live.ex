defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony 可观测性
            </p>
            <h1 class="hero-title">
              运维仪表盘
            </h1>
            <p class="hero-copy">
              展示当前状态、重试压力、Token 用量，以及活跃 Symphony 运行时的编排健康状况。
            </p>
          </div>

          <div class="status-stack">
            <a class="status-badge" href="/workflow">Workflow 图</a>
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              实时
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              离线
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            快照不可用
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">运行中</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">当前运行时中的活跃 Issue 会话。</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">重试中</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">等待下一个重试窗口的 Issue。</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">已阻塞</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail">因等待操作员输入或批准而暂停的 Issue。</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Token 总数</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              输入 <%= format_int(@payload.codex_totals.input_tokens) %> / 输出 <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">运行时长</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">已完成和活跃会话累计的 Codex 运行时长。</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">速率限制</h2>
              <p class="section-copy">可用时展示最新的上游速率限制快照。</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <%= if hub_device?(@payload) do %>
          <section class="section-card hub-device-overview">
            <div class="section-header">
              <div>
                <h2 class="section-title">Hub 设备总览</h2>
                <p class="section-copy">显式 Hub mode 的设备级运行、安全阻断和下一轮 tick 状态。</p>
              </div>
              <span class={hub_scheduler_badge_class(@payload.hub_device_observability.overview.scheduler.status)}>
                <%= hub_scheduler_status(@payload.hub_device_observability.overview.scheduler) %>
              </span>
            </div>

            <div class="hub-overview-grid">
              <article class="hub-summary-panel">
                <p class="metric-label">Scheduler / Tick</p>
                <p class="metric-value"><%= hub_scheduler_status(@payload.hub_device_observability.overview.scheduler) %></p>
                <p class="metric-detail">
                  下一轮 <span class="mono"><%= @payload.hub_device_observability.overview.scheduler.next_reason || "暂无" %></span>
                  · <span class="mono"><%= @payload.hub_device_observability.overview.scheduler.next_tick_at || "暂无" %></span>
                </p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">项目状态</p>
                <p class="metric-value numeric"><%= @payload.hub_device_observability.device.project_count %></p>
                <p class="metric-detail">
                  ready <%= hub_status_count(@payload, :ready_to_poll) %> · managed <%= hub_migration_count(@payload, "hub_managed") %> · blocked <%= hub_status_count(@payload, :blocked) %> · manual <%= hub_status_count(@payload, :manual_attention) %>
                </p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">Migration Readiness</p>
                <p class="metric-value"><%= hub_readiness_status(@payload) %></p>
                <p class="metric-detail">
                  dry-run <%= hub_readiness_count(@payload, :ready_for_dry_run) %> · hub-ready <%= hub_readiness_count(@payload, :ready_for_hub_management) %> · blocked <%= hub_readiness_count(@payload, :blocked) %> · unknown <%= hub_readiness_count(@payload, :unknown_manual_attention) %>
                </p>
                <p class="metric-detail event-meta">
                  blocking risks <%= hub_global_risk_count(@payload, :global_blocking_risks) %> · advisory <%= hub_global_risk_count(@payload, :global_advisory_risks) %>
                </p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">Provider 压力</p>
                <p class="metric-value numeric"><%= @payload.hub_device_observability.overview.provider_governance.queue_pressure_count %></p>
                <p class="metric-detail">
                  backoff <%= @payload.hub_device_observability.overview.provider_governance.quota_backoff_count %> · circuit <%= @payload.hub_device_observability.overview.provider_governance.circuit_open_count %> · failure <%= @payload.hub_device_observability.overview.provider_governance.recent_failure_count %>
                </p>
                <p class="metric-detail event-meta"><%= hub_recent_provider_failures(@payload.hub_device_observability.overview.provider_governance) %></p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">Capacity / Workspace</p>
                <p class="metric-value numeric"><%= @payload.hub_device_observability.overview.capacity_workspace.active_attempt_count %></p>
                <p class="metric-detail">
                  start intents <%= @payload.hub_device_observability.overview.capacity_workspace.pending_start_intent_count %> · leases <%= @payload.hub_device_observability.overview.capacity_workspace.workspace_lease_count %> · waiting capacity <%= @payload.hub_device_observability.overview.capacity_workspace.waiting_capacity_count %>
                </p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">Writeback / Manual</p>
                <p class="metric-value numeric"><%= @payload.hub_device_observability.overview.writeback.manual_attention_count %></p>
                <p class="metric-detail">
                  unknown <%= @payload.hub_device_observability.overview.writeback.counts.unknown %> · conflict <%= @payload.hub_device_observability.overview.writeback.intent_conflict_count %> · lookup <%= @payload.hub_device_observability.overview.writeback.provider_lookup_required_count %>
                </p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">Activation / Lifecycle</p>
                <p class="metric-value numeric"><%= @payload.hub_device_observability.overview.activation_preflight.blocked_project_count %></p>
                <p class="metric-detail">
                  unknown preflight <%= @payload.hub_device_observability.overview.activation_preflight.unknown_project_count %> · lifecycle unknown <%= @payload.hub_device_observability.overview.lifecycle.unresolved_count %>
                </p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">Activation Plan / Ack</p>
                <p class="metric-value"><%= hub_activation_plan_status(@payload) %></p>
                <p class="metric-detail">
                  plan-ready <%= hub_activation_plan_count(@payload, :plan_ready) %> · ack-required <%= hub_activation_plan_count(@payload, :ack_required) %> · stale <%= hub_activation_plan_count(@payload, :ack_stale) %> · conflict <%= hub_activation_plan_count(@payload, :ack_conflict) %>
                </p>
                <p class="metric-detail event-meta">
                  accepted <%= hub_activation_ack_count(@payload, :accepted) %> · missing <%= hub_activation_ack_count(@payload, :missing) %> · malformed <%= hub_activation_ack_count(@payload, :malformed) %>
                </p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">Cutover Gate</p>
                <p class="metric-value"><%= hub_cutover_status(@payload) %></p>
                <p class="metric-detail">
                  allowed <%= hub_cutover_count(@payload, :allowed_count) %> · staged <%= hub_cutover_count(@payload, :staged_ready_count) %> · blocked <%= hub_cutover_count(@payload, :blocked_count) %> · manual <%= hub_cutover_count(@payload, :manual_attention_count) %>
                </p>
                <p class="metric-detail event-meta">
                  records <%= hub_cutover_count(@payload, :staged_ownership_record_count) %> · ops <%= hub_cutover_allowed_ops(@payload) %>
                </p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">Cutover Audit</p>
                <p class="metric-value"><%= hub_cutover_audit_status(@payload) %></p>
                <p class="metric-detail">
                  requests <%= hub_cutover_audit_count(@payload, :request_count) %> · ready <%= hub_cutover_audit_count(@payload, :dry_run_ready_count) %> · blocked <%= hub_cutover_audit_count(@payload, :blocked_count) %> · manual <%= hub_cutover_audit_count(@payload, :manual_attention_count) %>
                </p>
                <p class="metric-detail event-meta">
                  none <%= hub_cutover_audit_count(@payload, :no_request_count) %> · unsupported <%= hub_cutover_audit_count(@payload, :unsupported_count) %> · dry-run only
                </p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">Audit History / Closeout</p>
                <p class="metric-value"><%= hub_cutover_history_status(@payload) %></p>
                <p class="metric-detail">
                  history <%= hub_cutover_history_count(@payload, :history_entry_count) %> · unresolved <%= hub_cutover_history_count(@payload, :unresolved_manual_attention_count) %> · closed <%= hub_cutover_history_count(@payload, :closed_count) %> · stale <%= hub_cutover_history_count(@payload, :stale_count) %>
                </p>
                <p class="metric-detail event-meta">
                  conflict <%= hub_cutover_history_count(@payload, :conflict_count) %> · malformed <%= hub_cutover_history_count(@payload, :malformed_count) %> · unsupported <%= hub_cutover_history_count(@payload, :unsupported_count) %>
                </p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">Execution Permit</p>
                <p class="metric-value"><%= hub_cutover_permit_status(@payload) %></p>
                <p class="metric-detail">
                  permits <%= hub_cutover_permit_count(@payload, :permit_count) %> · ready <%= hub_cutover_permit_count(@payload, :ready_count) %> · blocked <%= hub_cutover_permit_count(@payload, :blocked_count) %> · stale <%= hub_cutover_permit_count(@payload, :stale_count) %>
                </p>
                <p class="metric-detail event-meta">
                  manual <%= hub_cutover_permit_count(@payload, :manual_attention_count) %> · malformed <%= hub_cutover_permit_count(@payload, :malformed_count) %> · unsupported <%= hub_cutover_permit_count(@payload, :unsupported_count) %>
                </p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">Execution Authorization</p>
                <p class="metric-value"><%= hub_cutover_authorization_status(@payload) %></p>
                <p class="metric-detail">
                  requests <%= hub_cutover_authorization_count(@payload, :authorization_request_count) %> · records <%= hub_cutover_authorization_count(@payload, :record_count) %> · authorized <%= hub_cutover_authorization_count(@payload, :authorized_count) %> · blocked <%= hub_cutover_authorization_count(@payload, :blocked_count) %>
                </p>
                <p class="metric-detail event-meta">
                  stale <%= hub_cutover_authorization_count(@payload, :stale_count) %> · manual <%= hub_cutover_authorization_count(@payload, :manual_attention_count) %> · no ready permit <%= hub_cutover_authorization_count(@payload, :no_ready_permit_count) %>
                </p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">Authorization Consumption</p>
                <p class="metric-value"><%= hub_cutover_consumption_status(@payload) %></p>
                <p class="metric-detail">
                  allowed <%= hub_cutover_consumption_count(@payload, :allowed_count) %> · blocked <%= hub_cutover_consumption_count(@payload, :blocked_count) %> · no auth <%= hub_cutover_consumption_count(@payload, :no_authorization_count) %> · stale <%= hub_cutover_consumption_count(@payload, :stale_count) %>
                </p>
                <p class="metric-detail event-meta">
                  manual <%= hub_cutover_consumption_count(@payload, :manual_attention_count) %> · unsupported <%= hub_cutover_consumption_count(@payload, :unsupported_count) %> · malformed <%= hub_cutover_consumption_count(@payload, :malformed_count) %>
                </p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">Execution Outcome</p>
                <p class="metric-value"><%= hub_cutover_outcome_status(@payload) %></p>
                <p class="metric-detail">
                  succeeded <%= hub_cutover_outcome_count(@payload, :succeeded_count) %> · unknown <%= hub_cutover_outcome_count(@payload, :unknown_count) %> · manual <%= hub_cutover_outcome_count(@payload, :manual_attention_count) %> · failed <%= hub_cutover_outcome_count(@payload, :failed_count) %>
                </p>
                <p class="metric-detail event-meta">
                  entered <%= hub_cutover_outcome_count(@payload, :side_effect_entered_count) %> · not entered <%= hub_cutover_outcome_count(@payload, :side_effect_not_entered_count) %> · unresolved <%= hub_cutover_outcome_count(@payload, :unresolved_count) %>
                </p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">Outcome Closeout</p>
                <p class="metric-value"><%= hub_cutover_outcome_closeout_status(@payload) %></p>
                <p class="metric-detail">
                  unresolved <%= hub_cutover_outcome_closeout_count(@payload, :unresolved_outcome_count) %> · resolved <%= hub_cutover_outcome_closeout_count(@payload, :resolved_count) %> · stale <%= hub_cutover_outcome_closeout_count(@payload, :stale_count) %> · conflict <%= hub_cutover_outcome_closeout_count(@payload, :conflict_count) %>
                </p>
                <p class="metric-detail event-meta">
                  retry consideration <%= hub_cutover_outcome_closeout_count(@payload, :allow_explicit_retry_consideration_count) %> · manual <%= hub_cutover_outcome_closeout_count(@payload, :manual_attention_count) %> · malformed <%= hub_cutover_outcome_closeout_count(@payload, :malformed_count) %>
                </p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">Replay Decision</p>
                <p class="metric-value"><%= hub_cutover_replay_decision_status(@payload) %></p>
                <p class="metric-detail">
                  blocked <%= hub_cutover_replay_decision_count(@payload, :unresolved_outcome_blocked_count) %> · retry allowed <%= hub_cutover_replay_decision_count(@payload, :retry_consideration_allowed_count) %> · denied <%= hub_cutover_replay_decision_count(@payload, :retry_consideration_denied_count) %> · no unresolved <%= hub_cutover_replay_decision_count(@payload, :no_unresolved_outcome_count) %>
                </p>
                <p class="metric-detail event-meta">
                  stale <%= hub_cutover_replay_decision_count(@payload, :stale_closeout_count) %> · conflict <%= hub_cutover_replay_decision_count(@payload, :conflict_count) %> · manual <%= hub_cutover_replay_decision_count(@payload, :manual_attention_count) %> · malformed <%= hub_cutover_replay_decision_count(@payload, :malformed_count) %>
                </p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">Replay Request</p>
                <p class="metric-value"><%= hub_cutover_replay_request_audit_status(@payload) %></p>
                <p class="metric-detail">
                  requests <%= hub_cutover_replay_request_audit_count(@payload, :request_count) %> · allow <%= hub_cutover_replay_request_audit_count(@payload, :allow_count) %> · block <%= hub_cutover_replay_request_audit_count(@payload, :block_count) %> · no request <%= hub_cutover_replay_request_audit_count(@payload, :no_request_count) %>
                </p>
                <p class="metric-detail event-meta">
                  stale <%= hub_cutover_replay_request_audit_count(@payload, :stale_count) %> · conflict <%= hub_cutover_replay_request_audit_count(@payload, :conflict_count) %> · manual <%= hub_cutover_replay_request_audit_count(@payload, :manual_attention_count) %> · outcome recorded <%= hub_cutover_replay_request_audit_count(@payload, :linked_outcome_recorded_count) %>
                </p>
              </article>

              <article class="hub-summary-panel">
                <p class="metric-label">Closure Chain</p>
                <p class="metric-value"><%= hub_cutover_closure_chain_status(@payload) %></p>
                <p class="metric-detail">
                  closed <%= hub_cutover_closure_chain_count(@payload, :closed_succeeded) %> · no-side <%= hub_cutover_closure_chain_count(@payload, :closed_no_side_effect) %> · retryable <%= hub_cutover_closure_chain_count(@payload, :open_retryable) %> · manual <%= hub_cutover_closure_chain_count(@payload, :open_manual_attention) %>
                </p>
                <p class="metric-detail event-meta">
                  stale <%= hub_cutover_closure_chain_count(@payload, :stale) %> · conflict <%= hub_cutover_closure_chain_count(@payload, :conflict) %> · malformed <%= hub_cutover_closure_chain_count(@payload, :malformed) %> · unsupported <%= hub_cutover_closure_chain_count(@payload, :unsupported) %> · no chain <%= hub_cutover_closure_chain_count(@payload, :no_chain) %> · no request <%= hub_cutover_closure_chain_count(@payload, :no_request) %>
                </p>
                <p class="metric-detail event-meta">
                  closeout refs current <%= hub_cutover_closure_chain_ref_count(@payload, :closeout, :current) %> / missing <%= hub_cutover_closure_chain_ref_count(@payload, :closeout, :missing) %> · replay decision refs current <%= hub_cutover_closure_chain_ref_count(@payload, :replay_decision, :current) %> / missing <%= hub_cutover_closure_chain_ref_count(@payload, :replay_decision, :missing) %> · request audit refs current <%= hub_cutover_closure_chain_ref_count(@payload, :replay_request_audit, :current) %> / missing <%= hub_cutover_closure_chain_ref_count(@payload, :replay_request_audit, :missing) %>
                </p>
                <p class="metric-detail event-meta">
                  reason <%= hub_cutover_closure_chain_recent_codes(@payload, :reason) %> · action <%= hub_cutover_closure_chain_recent_codes(@payload, :action) %> · fp <%= hub_cutover_closure_chain_recent_fingerprints(@payload) %>
                </p>
                <p class="metric-detail event-meta">
                  read-only <%= hub_cutover_closure_chain_flag(@payload, :read_only) %> · no side effects <%= hub_cutover_closure_chain_flag(@payload, :no_side_effects) %> · auto replay allowed <%= hub_cutover_closure_chain_flag(@payload, :auto_replay_allowed) %>
                </p>
              </article>
            </div>
          </section>

          <section class="section-card hub-project-details">
            <div class="section-header">
              <div>
                <h2 class="section-title">Hub 项目明细</h2>
                <p class="section-copy">每个 Hub project 的 ownership、preflight、poll、dispatch、start、lifecycle 和 writeback 当前状态。</p>
              </div>
            </div>

            <div class="table-wrap">
              <table class="data-table hub-project-table">
                <thead>
                  <tr>
                    <th>Project</th>
                    <th>状态</th>
                    <th>Poll / Preflight</th>
                    <th>Dispatch / Start</th>
                    <th>Lifecycle / Writeback</th>
                    <th>需要处理</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={project <- @payload.hub_device_observability.projects}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= project.project_id %></span>
                        <span class="muted event-meta"><%= project.name || project.detail.identity.provider_scope_key || "unknown scope" %></span>
                        <span class="muted event-meta mono"><%= project.detail.config.config_fingerprint || "no fingerprint" %></span>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class={hub_project_badge_class(project.status)}><%= hub_project_status(project.status) %></span>
                        <span class={hub_readiness_badge_class(project.migration_readiness && project.migration_readiness.decision)}>
                          <%= hub_readiness_project_status(project.migration_readiness) %>
                        </span>
                        <span class={hub_activation_plan_badge_class(project.activation_plan && project.activation_plan.status)}>
                          plan <%= hub_activation_project_status(project.activation_plan) %>
                        </span>
                        <span class={hub_activation_ack_badge_class(project.activation_plan && project.activation_plan.operator_acknowledgement && project.activation_plan.operator_acknowledgement.status)}>
                          ack <%= hub_activation_ack_status(project.activation_plan) %>
                        </span>
                        <span class={hub_cutover_badge_class(project.cutover_gate && project.cutover_gate.decision)}>
                          gate <%= hub_cutover_project_status(project.cutover_gate) %>
                        </span>
                        <span class={hub_cutover_audit_badge_class(project.cutover_operation_audit && project.cutover_operation_audit.status)}>
                          audit <%= hub_cutover_audit_project_status(project.cutover_operation_audit) %>
                        </span>
                        <span class={hub_cutover_history_badge_class(project.cutover_audit_history && project.cutover_audit_history.status)}>
                          history <%= hub_cutover_history_project_status(project.cutover_audit_history) %>
                        </span>
                        <span class={hub_cutover_permit_badge_class(project.cutover_readiness_permit && project.cutover_readiness_permit.status)}>
                          permit <%= hub_cutover_permit_project_status(project.cutover_readiness_permit) %>
                        </span>
                        <span class={hub_cutover_authorization_badge_class(project.cutover_execution_authorization_ledger && project.cutover_execution_authorization_ledger.status)}>
                          auth <%= hub_cutover_authorization_project_status(project.cutover_execution_authorization_ledger) %>
                        </span>
                        <span class={hub_cutover_consumption_badge_class(project.cutover_authorization_consumption_guard && project.cutover_authorization_consumption_guard.status)}>
                          consume <%= hub_cutover_consumption_project_status(project.cutover_authorization_consumption_guard) %>
                        </span>
                        <span class={hub_cutover_outcome_badge_class(project.cutover_execution_outcome_ledger && project.cutover_execution_outcome_ledger.status)}>
                          outcome <%= hub_cutover_outcome_project_status(project.cutover_execution_outcome_ledger) %>
                        </span>
                        <span class={hub_cutover_outcome_closeout_badge_class(project.cutover_execution_outcome_closeout && project.cutover_execution_outcome_closeout.status)}>
                          closeout <%= hub_cutover_outcome_closeout_project_status(project.cutover_execution_outcome_closeout) %>
                        </span>
                        <span class={hub_cutover_replay_decision_badge_class(project.cutover_replay_decision && project.cutover_replay_decision.status)}>
                          replay <%= hub_cutover_replay_decision_project_status(project.cutover_replay_decision) %>
                        </span>
                        <span class={hub_cutover_replay_request_audit_badge_class(project.cutover_replay_request_audit && project.cutover_replay_request_audit.status)}>
                          replay request <%= hub_cutover_replay_request_audit_project_status(project.cutover_replay_request_audit) %>
                        </span>
                        <span class={hub_cutover_closure_chain_badge_class(project.cutover_closure_chain && project.cutover_closure_chain.status)}>
                          closure <%= hub_cutover_closure_chain_project_status(project.cutover_closure_chain) %>
                        </span>
                        <span class="muted event-meta"><%= project.migration_state %></span>
                        <span :if={project.summary_error} class="muted event-meta">summary error <%= project.summary_error.code %></span>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span><%= hub_poll_text(project.detail.poll_eligibility) %></span>
                        <span class="muted event-meta">
                          preflight <%= hub_preflight_text(project.activation_preflight) %>
                        </span>
                        <span class="muted event-meta mono"><%= project.detail.poll_eligibility.next_due_at || project.detail.poll_eligibility.backoff_until || "暂无" %></span>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span>intake <%= hub_count(project.detail.candidate_intake.counts, "candidate_count") %> / planned <%= hub_count(project.detail.dispatch_planning.counts, "planned_count") %></span>
                        <span class="muted event-meta">applied <%= hub_count(project.detail.dispatch_application.counts, "applied_count") %> · start unknown <%= hub_count(project.detail.worker_start.counts, "unknown_count") %></span>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span>running <%= project.detail.lifecycle.counts.running %> · unknown <%= project.detail.lifecycle.counts.unknown %></span>
                        <span class="muted event-meta">writeback pending <%= project.detail.writeback.counts.pending %> · unknown <%= project.detail.writeback.counts.unknown %> · manual <%= project.detail.writeback.counts.manual_attention %></span>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span><%= hub_attention_text(project) %></span>
                        <span :if={project.activation_plan} class="muted event-meta mono">
                          plan <%= hub_short_plan_id(project.activation_plan) %>
                        </span>
                        <span :for={action <- hub_required_acknowledgements(project)} class="muted event-meta">
                          ack <%= action.code %>
                        </span>
                        <span :for={action <- hub_required_actions(project)} class="muted event-meta">
                          action <%= action.code %>
                        </span>
                        <span :if={project.cutover_operation_audit && project.cutover_operation_audit.request} class="muted event-meta mono">
                          request <%= hub_short_request_id(project.cutover_operation_audit.request) %>
                        </span>
                        <span :for={reason <- hub_cutover_audit_reasons(project)} class="muted event-meta">
                          audit <%= reason %>
                        </span>
                        <span :if={project.cutover_audit_history} class="muted event-meta">
                          unresolved <%= hub_cutover_history_project_count(project, :unresolved_manual_attention_count) %> · closed <%= hub_cutover_history_project_count(project, :closed_count) %> · stale <%= hub_cutover_history_project_count(project, :stale_count) %>
                        </span>
                        <span :for={item <- hub_unresolved_cutover_items(project)} class="muted event-meta">
                          cutover <%= item.operation %> <%= item.reason_code %> / <%= item.required_operator_action_code %>
                        </span>
                        <span :if={project.cutover_readiness_permit} class="muted event-meta">
                          permit ready <%= hub_cutover_permit_project_count(project, :ready_count) %> · blocked <%= hub_cutover_permit_project_count(project, :blocked_count) %> · stale <%= hub_cutover_permit_project_count(project, :stale_count) %>
                        </span>
                        <span :for={permit <- hub_cutover_project_permits(project)} class="muted event-meta">
                          permit <%= permit.operation %> <%= permit.decision %>
                        </span>
                        <span :if={project.cutover_execution_authorization_ledger} class="muted event-meta">
                          auth authorized <%= hub_cutover_authorization_project_count(project, :authorized_count) %> · blocked <%= hub_cutover_authorization_project_count(project, :blocked_count) %> · stale <%= hub_cutover_authorization_project_count(project, :stale_count) %>
                        </span>
                        <span :for={record <- hub_cutover_project_authorizations(project)} class="muted event-meta">
                          auth <%= record.operation %> <%= record.status %>
                        </span>
                        <span :if={project.cutover_authorization_consumption_guard} class="muted event-meta">
                          consume allowed <%= hub_cutover_consumption_project_count(project, :allowed_count) %> · blocked <%= hub_cutover_consumption_project_count(project, :blocked_count) %> · no auth <%= hub_cutover_consumption_project_count(project, :no_authorization_count) %>
                        </span>
                        <span :for={blocked <- hub_cutover_project_consumption_blocks(project)} class="muted event-meta">
                          consume <%= blocked.side_effect_source %> <%= blocked.decision %> / <%= blocked.reason_code %>
                        </span>
                        <span :if={project.cutover_execution_outcome_ledger} class="muted event-meta">
                          outcome ok <%= hub_cutover_outcome_project_count(project, :succeeded_count) %> · unknown <%= hub_cutover_outcome_project_count(project, :unknown_count) %> · manual <%= hub_cutover_outcome_project_count(project, :manual_attention_count) %> · no side effects <%= hub_cutover_outcome_project_count(project, :side_effect_not_entered_count) %>
                        </span>
                        <span :for={outcome <- hub_cutover_project_unresolved_outcomes(project)} class="muted event-meta">
                          outcome <%= outcome.side_effect_source %> <%= outcome.status %> / <%= outcome.reason_code %>
                        </span>
                        <span :if={project.cutover_execution_outcome_closeout} class="muted event-meta">
                          closeout resolved <%= hub_cutover_outcome_closeout_project_count(project, :resolved_count) %> · stale <%= hub_cutover_outcome_closeout_project_count(project, :stale_count) %> · conflict <%= hub_cutover_outcome_closeout_project_count(project, :conflict_count) %>
                        </span>
                        <span :for={closeout <- hub_cutover_project_outcome_closeouts(project)} class="muted event-meta">
                          closeout <%= closeout.side_effect_source %> <%= closeout.status %> / <%= closeout.resolution_code %>
                        </span>
                        <span :if={project.cutover_replay_decision} class="muted event-meta">
                          replay blocked <%= hub_cutover_replay_decision_project_count(project, :unresolved_outcome_blocked_count) %> · retry allowed <%= hub_cutover_replay_decision_project_count(project, :retry_consideration_allowed_count) %> · stale <%= hub_cutover_replay_decision_project_count(project, :stale_closeout_count) %>
                        </span>
                        <span :for={blocked <- hub_cutover_project_blocked_replay(project)} class="muted event-meta">
                          replay <%= blocked.side_effect_source %> <%= blocked.decision %> / <%= blocked.reason_code %>
                        </span>
                        <span :for={reason <- hub_cutover_project_replay_reason_codes(project)} class="muted event-meta">
                          replay reason <%= reason %>
                        </span>
                        <span :if={project.cutover_replay_request_audit} class="muted event-meta">
                          replay request allow <%= hub_cutover_replay_request_audit_project_count(project, :allow_count) %> · block <%= hub_cutover_replay_request_audit_project_count(project, :block_count) %> · linked <%= hub_cutover_replay_request_audit_project_count(project, :linked_outcome_recorded_count) %>
                        </span>
                        <span :for={request <- hub_cutover_project_replay_requests(project)} class="muted event-meta">
                          replay request <%= request.side_effect_source %> <%= request.status %> / <%= request.outcome_link_status %>
                        </span>
                        <span :if={project.cutover_closure_chain} class="muted event-meta">
                          closure closed <%= hub_cutover_closure_chain_project_count(project, :closed_succeeded) %> · retryable <%= hub_cutover_closure_chain_project_count(project, :open_retryable) %> · manual <%= hub_cutover_closure_chain_project_count(project, :open_manual_attention) %> · no request <%= hub_cutover_closure_chain_project_count(project, :no_request) %>
                        </span>
                        <span :if={project.cutover_closure_chain} class="muted event-meta">
                          closure refs closeout current <%= hub_cutover_closure_chain_project_ref_count(project, :closeout, :current) %> · replay decision current <%= hub_cutover_closure_chain_project_ref_count(project, :replay_decision, :current) %> · request audit current <%= hub_cutover_closure_chain_project_ref_count(project, :replay_request_audit, :current) %>
                        </span>
                        <span :for={reason <- hub_cutover_project_closure_reason_codes(project)} class="muted event-meta">
                          closure reason <%= reason %>
                        </span>
                        <span :for={action <- hub_cutover_project_closure_action_codes(project)} class="muted event-meta">
                          closure action <%= action %>
                        </span>
                        <span :for={fingerprint <- hub_cutover_project_closure_fingerprints(project)} class="muted event-meta mono">
                          closure fp <%= fingerprint %>
                        </span>
                        <span :for={reason <- Enum.take(project.backpressure_reasons, 3)} class="muted event-meta">
                          <%= reason.reason %><%= if reason.detail, do: " · #{reason.detail}", else: "" %>
                        </span>
                        <span :for={reason <- hub_readiness_reasons(project)} class="muted event-meta">
                          readiness <%= reason.code %>
                        </span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        <% end %>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">运行中会话</h2>
              <p class="section-copy">活跃 Issue、最近一次已知 Agent 活动和 Token 用量。</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">暂无活跃会话。</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>状态</th>
                    <th>会话</th>
                    <th>运行时长 / 轮次</th>
                    <th>Codex 更新</th>
                    <th>Token</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON 详情</a>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class={state_badge_class(entry.state)}>
                          <%= display_state(entry.state) %>
                        </span>
                        <span :if={entry.current_stage} class="muted event-meta">
                          stage <span class="mono"><%= entry.current_stage %></span>
                        </span>
                        <span :if={entry.stage_conflict} class="muted event-meta">
                          冲突 <span class="mono"><%= stage_conflict_text(entry.stage_conflict) %></span>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="复制 ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = '已复制'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            复制 ID
                          </button>
                        <% else %>
                          <span class="muted">暂无</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "暂无")}
                        ><%= entry.last_message || to_string(entry.last_event || "暂无") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "暂无" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>总计：<%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">输入 <%= format_int(entry.tokens.input_tokens) %> / 输出 <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">阻塞会话</h2>
              <p class="section-copy">因 Codex 请求操作员输入或批准而暂停的 Issue。</p>
            </div>
          </div>

          <%= if @payload.blocked == [] do %>
            <p class="empty-state">暂无阻塞会话。</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>状态</th>
                    <th>会话</th>
                    <th>恢复证据</th>
                    <th>阻塞时间</th>
                    <th>最近更新</th>
                    <th>错误</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON 详情</a>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class={state_badge_class(entry.state || "Blocked")}>
                          <%= display_state(entry.state || "Blocked") %>
                        </span>
                        <span :if={entry.current_stage} class="muted event-meta">
                          stage <span class="mono"><%= entry.current_stage %></span>
                        </span>
                        <span :if={entry.stage_conflict} class="muted event-meta">
                          冲突 <span class="mono"><%= stage_conflict_text(entry.stage_conflict) %></span>
                        </span>
                      </div>
                    </td>
                    <td>
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="复制 ID"
                          data-copy={entry.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = '已复制'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          复制 ID
                        </button>
                      <% else %>
                        <span class="muted">暂无</span>
                      <% end %>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class="mono event-text" title={recovery_artifact_path(entry.recovery_artifact)}>
                          <%= recovery_artifact_path(entry.recovery_artifact) || entry.workspace_path || "暂无" %>
                        </span>
                        <span :if={entry.recovery_artifact && entry.recovery_artifact.available? == false} class="muted event-meta">
                          <%= entry.recovery_artifact.error || "workspace retained" %>
                        </span>
                      </div>
                    </td>
                    <td class="mono"><%= entry.blocked_at || "暂无" %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "暂无")}
                        ><%= entry.last_message || to_string(entry.last_event || "暂无") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "暂无" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td><%= entry.error || "暂无" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">重试队列</h2>
              <p class="section-copy">等待下一个重试窗口的 Issue。</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">当前没有处于退避等待的 Issue。</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>尝试次数</th>
                    <th>到期时间</th>
                    <th>错误</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON 详情</a>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span><%= entry.attempt %></span>
                        <span :if={entry.current_stage} class="muted event-meta">
                          stage <span class="mono"><%= entry.current_stage %></span>
                        </span>
                      </div>
                    </td>
                    <td class="mono"><%= entry.due_at || "暂无" %></td>
                    <td><%= entry.error || "暂无" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "暂无"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp display_state(state) do
    case state |> to_string() |> String.trim() |> String.downcase() do
      "" -> "暂无"
      "active" -> "活跃"
      "blocked" -> "已阻塞"
      "completed" -> "已完成"
      "done" -> "已完成"
      "error" -> "错误"
      "failed" -> "失败"
      "in progress" -> "进行中"
      "pending" -> "等待中"
      "queued" -> "排队中"
      "ready" -> "就绪"
      "retry" -> "重试"
      "retrying" -> "重试中"
      "running" -> "运行中"
      "to do" -> "待办"
      "todo" -> "待办"
      _ -> state
    end
  end

  defp hub_device?(payload) do
    is_map(payload) and is_map(Map.get(payload, :hub_device_observability))
  end

  defp hub_scheduler_badge_class("scheduled"), do: "state-badge state-badge-warning"
  defp hub_scheduler_badge_class("running"), do: "state-badge state-badge-active"
  defp hub_scheduler_badge_class("coalesced"), do: "state-badge state-badge-warning"
  defp hub_scheduler_badge_class("failed"), do: "state-badge state-badge-danger"
  defp hub_scheduler_badge_class(_status), do: "state-badge state-badge-muted"

  defp hub_scheduler_status(%{enabled: false}), do: "scheduler disabled"
  defp hub_scheduler_status(%{status: status}) when is_binary(status), do: "scheduler #{status}"
  defp hub_scheduler_status(_scheduler), do: "scheduler unknown"

  defp hub_status_count(payload, status) do
    payload
    |> get_in([:hub_device_observability, :overview, :project_status_counts, status])
    |> case do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp hub_migration_count(payload, migration_state) do
    payload
    |> get_in([:hub_device_observability, :projects])
    |> List.wrap()
    |> Enum.count(&(Map.get(&1, :migration_state) == migration_state))
  end

  defp hub_readiness_status(payload) do
    payload
    |> get_in([:hub_device_observability, :migration_readiness, :status])
    |> case do
      status when is_binary(status) -> status
      _status -> "unknown"
    end
  end

  defp hub_readiness_count(payload, decision) do
    payload
    |> get_in([:hub_device_observability, :migration_readiness, :counts, :decisions, decision])
    |> case do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp hub_activation_plan_status(payload) do
    payload
    |> get_in([:hub_device_observability, :activation_plan, :status])
    |> case do
      status when is_binary(status) -> status
      _status -> "unknown_manual_attention"
    end
  end

  defp hub_activation_plan_count(payload, status) do
    payload
    |> get_in([:hub_device_observability, :activation_plan, :counts, :plan_statuses, status])
    |> case do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp hub_activation_ack_count(payload, status) do
    payload
    |> get_in([:hub_device_observability, :activation_plan, :counts, :acknowledgement_statuses, status])
    |> case do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp hub_cutover_status(payload) do
    payload
    |> get_in([:hub_device_observability, :cutover_gate, :status])
    |> case do
      status when is_binary(status) -> status
      _status -> "not_applicable"
    end
  end

  defp hub_cutover_count(payload, key) do
    payload
    |> get_in([:hub_device_observability, :cutover_gate, :counts, key])
    |> case do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp hub_cutover_allowed_ops(payload) do
    payload
    |> get_in([:hub_device_observability, :cutover_gate, :projects])
    |> case do
      projects when is_list(projects) ->
        projects
        |> Enum.flat_map(&(Map.get(&1, :allowed_operations) || []))
        |> Enum.uniq()
        |> Enum.sort()
        |> case do
          [] -> "none"
          ops -> Enum.join(ops, ", ")
        end

      _projects ->
        "none"
    end
  end

  defp hub_cutover_audit_status(payload) do
    payload
    |> get_in([:hub_device_observability, :cutover_operation_audit, :status])
    |> case do
      status when is_binary(status) -> status
      _status -> "no_request"
    end
  end

  defp hub_cutover_audit_count(payload, key) do
    payload
    |> get_in([:hub_device_observability, :cutover_operation_audit, :counts, key])
    |> case do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp hub_cutover_history_status(payload) do
    payload
    |> get_in([:hub_device_observability, :cutover_audit_history, :status])
    |> case do
      status when is_binary(status) -> status
      _status -> "no_history"
    end
  end

  defp hub_cutover_history_count(payload, key) do
    payload
    |> get_in([:hub_device_observability, :cutover_audit_history, :counts, key])
    |> case do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp hub_cutover_permit_status(payload) do
    payload
    |> get_in([:hub_device_observability, :cutover_readiness_permit, :status])
    |> case do
      status when is_binary(status) -> status
      _status -> "no_request"
    end
  end

  defp hub_cutover_permit_count(payload, key) do
    payload
    |> get_in([:hub_device_observability, :cutover_readiness_permit, :counts, key])
    |> case do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp hub_cutover_authorization_status(payload) do
    payload
    |> get_in([:hub_device_observability, :cutover_execution_authorization_ledger, :status])
    |> case do
      status when is_binary(status) -> status
      _status -> "no_ready_permit"
    end
  end

  defp hub_cutover_authorization_count(payload, key) do
    payload
    |> get_in([:hub_device_observability, :cutover_execution_authorization_ledger, :counts, key])
    |> case do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp hub_cutover_consumption_status(payload) do
    payload
    |> get_in([:hub_device_observability, :cutover_authorization_consumption_guard, :status])
    |> case do
      status when is_binary(status) -> status
      _status -> "no_consumption"
    end
  end

  defp hub_cutover_consumption_count(payload, key) do
    payload
    |> get_in([:hub_device_observability, :cutover_authorization_consumption_guard, :counts, key])
    |> case do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp hub_cutover_outcome_status(payload) do
    payload
    |> get_in([:hub_device_observability, :cutover_execution_outcome_ledger, :status])
    |> case do
      status when is_binary(status) -> status
      _status -> "no_outcome"
    end
  end

  defp hub_cutover_outcome_count(payload, key) do
    payload
    |> get_in([:hub_device_observability, :cutover_execution_outcome_ledger, :counts, key])
    |> case do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp hub_cutover_outcome_closeout_status(payload) do
    payload
    |> get_in([:hub_device_observability, :cutover_execution_outcome_closeout, :status])
    |> case do
      status when is_binary(status) -> status
      _status -> "no_outcome"
    end
  end

  defp hub_cutover_outcome_closeout_count(payload, key) do
    payload
    |> get_in([:hub_device_observability, :cutover_execution_outcome_closeout, :counts, key])
    |> case do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp hub_cutover_replay_decision_status(payload) do
    payload
    |> get_in([:hub_device_observability, :cutover_replay_decision, :status])
    |> case do
      status when is_binary(status) -> status
      _status -> "no_replay_decision"
    end
  end

  defp hub_cutover_replay_decision_count(payload, key) do
    payload
    |> get_in([:hub_device_observability, :cutover_replay_decision, :counts, key])
    |> case do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp hub_cutover_replay_request_audit_status(payload) do
    payload
    |> get_in([:hub_device_observability, :cutover_replay_request_audit, :status])
    |> case do
      status when is_binary(status) -> status
      _status -> "no_request"
    end
  end

  defp hub_cutover_replay_request_audit_count(payload, key) do
    payload
    |> get_in([:hub_device_observability, :cutover_replay_request_audit, :counts, key])
    |> case do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp hub_cutover_closure_chain_status(payload) do
    payload
    |> get_in([:hub_device_observability, :overview, :cutover_closure_chain, :status])
    |> case do
      status when is_binary(status) -> status
      _status -> "no_chain"
    end
  end

  defp hub_cutover_closure_chain_count(payload, key) do
    payload
    |> get_in([:hub_device_observability, :overview, :cutover_closure_chain, :closure_status_counts])
    |> hub_count(Atom.to_string(key))
  end

  defp hub_cutover_closure_chain_ref_count(payload, reference_type, status) do
    payload
    |> get_in([
      :hub_device_observability,
      :overview,
      :cutover_closure_chain,
      closure_chain_reference_count_key(reference_type)
    ])
    |> hub_count(Atom.to_string(status))
  end

  defp hub_cutover_closure_chain_recent_codes(payload, :reason) do
    payload
    |> get_in([:hub_device_observability, :overview, :cutover_closure_chain, :recent_reason_codes])
    |> format_short_list()
  end

  defp hub_cutover_closure_chain_recent_codes(payload, :action) do
    payload
    |> get_in([:hub_device_observability, :overview, :cutover_closure_chain, :recent_action_codes])
    |> format_short_list()
  end

  defp hub_cutover_closure_chain_recent_fingerprints(payload) do
    payload
    |> get_in([:hub_device_observability, :overview, :cutover_closure_chain, :recent_evidence_fingerprints])
    |> format_short_list()
  end

  defp hub_cutover_closure_chain_flag(payload, key) do
    payload
    |> get_in([:hub_device_observability, :overview, :cutover_closure_chain, key])
    |> case do
      true -> "true"
      false -> "false"
      _value -> "false"
    end
  end

  defp hub_global_risk_count(payload, key) do
    payload
    |> get_in([:hub_device_observability, :migration_readiness, key])
    |> List.wrap()
    |> length()
  end

  defp hub_project_badge_class(status) do
    case status do
      "running" -> "state-badge state-badge-active"
      "ready_to_poll" -> "state-badge state-badge-active"
      "backoff" -> "state-badge state-badge-warning"
      "blocked" -> "state-badge state-badge-danger"
      "manual_attention" -> "state-badge state-badge-danger"
      "config_invalid" -> "state-badge state-badge-danger"
      "legacy_only" -> "state-badge state-badge-muted"
      _status -> "state-badge state-badge-muted"
    end
  end

  defp hub_readiness_badge_class("ready_for_dry_run"), do: "state-badge state-badge-active"
  defp hub_readiness_badge_class("ready_for_hub_management"), do: "state-badge state-badge-active"
  defp hub_readiness_badge_class("already_hub_managed"), do: "state-badge state-badge-active"
  defp hub_readiness_badge_class("legacy_only"), do: "state-badge state-badge-muted"
  defp hub_readiness_badge_class("blocked"), do: "state-badge state-badge-danger"
  defp hub_readiness_badge_class("unknown_manual_attention"), do: "state-badge state-badge-danger"
  defp hub_readiness_badge_class(_status), do: "state-badge state-badge-muted"

  defp hub_activation_plan_badge_class("plan_ready"), do: "state-badge state-badge-active"
  defp hub_activation_plan_badge_class("already_managed"), do: "state-badge state-badge-active"
  defp hub_activation_plan_badge_class("ack_required"), do: "state-badge state-badge-warning"
  defp hub_activation_plan_badge_class("ack_stale"), do: "state-badge state-badge-warning"
  defp hub_activation_plan_badge_class("ack_conflict"), do: "state-badge state-badge-danger"
  defp hub_activation_plan_badge_class("blocked"), do: "state-badge state-badge-danger"
  defp hub_activation_plan_badge_class("unknown_manual_attention"), do: "state-badge state-badge-danger"
  defp hub_activation_plan_badge_class(_status), do: "state-badge state-badge-muted"

  defp hub_activation_ack_badge_class("accepted"), do: "state-badge state-badge-active"
  defp hub_activation_ack_badge_class("missing"), do: "state-badge state-badge-warning"
  defp hub_activation_ack_badge_class("stale"), do: "state-badge state-badge-warning"
  defp hub_activation_ack_badge_class("conflict"), do: "state-badge state-badge-danger"
  defp hub_activation_ack_badge_class("malformed"), do: "state-badge state-badge-danger"
  defp hub_activation_ack_badge_class("unsupported"), do: "state-badge state-badge-danger"
  defp hub_activation_ack_badge_class("manual_attention"), do: "state-badge state-badge-danger"
  defp hub_activation_ack_badge_class(_status), do: "state-badge state-badge-muted"

  defp hub_cutover_badge_class("allowed"), do: "state-badge state-badge-active"
  defp hub_cutover_badge_class("staged_ready"), do: "state-badge state-badge-active"
  defp hub_cutover_badge_class("not_applicable"), do: "state-badge state-badge-muted"
  defp hub_cutover_badge_class("blocked"), do: "state-badge state-badge-danger"
  defp hub_cutover_badge_class("manual_attention"), do: "state-badge state-badge-danger"
  defp hub_cutover_badge_class(_status), do: "state-badge state-badge-muted"

  defp hub_cutover_audit_badge_class("dry_run_ready"), do: "state-badge state-badge-active"
  defp hub_cutover_audit_badge_class("no_request"), do: "state-badge state-badge-muted"
  defp hub_cutover_audit_badge_class("blocked"), do: "state-badge state-badge-danger"
  defp hub_cutover_audit_badge_class("manual_attention"), do: "state-badge state-badge-danger"
  defp hub_cutover_audit_badge_class("unsupported"), do: "state-badge state-badge-danger"
  defp hub_cutover_audit_badge_class("summary_error"), do: "state-badge state-badge-danger"
  defp hub_cutover_audit_badge_class(_status), do: "state-badge state-badge-muted"

  defp hub_cutover_history_badge_class("history_ready"), do: "state-badge state-badge-active"
  defp hub_cutover_history_badge_class("closed"), do: "state-badge state-badge-active"
  defp hub_cutover_history_badge_class("no_history"), do: "state-badge state-badge-muted"
  defp hub_cutover_history_badge_class("deferred"), do: "state-badge state-badge-warning"
  defp hub_cutover_history_badge_class("stale"), do: "state-badge state-badge-warning"
  defp hub_cutover_history_badge_class("unresolved_manual_attention"), do: "state-badge state-badge-danger"
  defp hub_cutover_history_badge_class("conflict"), do: "state-badge state-badge-danger"
  defp hub_cutover_history_badge_class("malformed"), do: "state-badge state-badge-danger"
  defp hub_cutover_history_badge_class("unsupported"), do: "state-badge state-badge-danger"
  defp hub_cutover_history_badge_class("summary_error"), do: "state-badge state-badge-danger"
  defp hub_cutover_history_badge_class(_status), do: "state-badge state-badge-muted"

  defp hub_cutover_permit_badge_class("ready_for_execution_consideration"), do: "state-badge state-badge-active"
  defp hub_cutover_permit_badge_class("no_request"), do: "state-badge state-badge-muted"
  defp hub_cutover_permit_badge_class("stale"), do: "state-badge state-badge-warning"
  defp hub_cutover_permit_badge_class("blocked"), do: "state-badge state-badge-danger"
  defp hub_cutover_permit_badge_class("manual_attention"), do: "state-badge state-badge-danger"
  defp hub_cutover_permit_badge_class("malformed"), do: "state-badge state-badge-danger"
  defp hub_cutover_permit_badge_class("unsupported"), do: "state-badge state-badge-danger"
  defp hub_cutover_permit_badge_class("summary_error"), do: "state-badge state-badge-danger"
  defp hub_cutover_permit_badge_class(_status), do: "state-badge state-badge-muted"

  defp hub_cutover_authorization_badge_class("authorized_for_explicit_execution"), do: "state-badge state-badge-active"
  defp hub_cutover_authorization_badge_class("stale"), do: "state-badge state-badge-warning"
  defp hub_cutover_authorization_badge_class("no_ready_permit"), do: "state-badge state-badge-muted"
  defp hub_cutover_authorization_badge_class("blocked"), do: "state-badge state-badge-danger"
  defp hub_cutover_authorization_badge_class("manual_attention"), do: "state-badge state-badge-danger"
  defp hub_cutover_authorization_badge_class("malformed"), do: "state-badge state-badge-danger"
  defp hub_cutover_authorization_badge_class("unsupported"), do: "state-badge state-badge-danger"
  defp hub_cutover_authorization_badge_class("summary_error"), do: "state-badge state-badge-danger"
  defp hub_cutover_authorization_badge_class(_status), do: "state-badge state-badge-muted"

  defp hub_cutover_consumption_badge_class("allowed"), do: "state-badge state-badge-active"
  defp hub_cutover_consumption_badge_class("no_consumption"), do: "state-badge state-badge-muted"
  defp hub_cutover_consumption_badge_class("stale"), do: "state-badge state-badge-warning"
  defp hub_cutover_consumption_badge_class("blocked"), do: "state-badge state-badge-danger"
  defp hub_cutover_consumption_badge_class("no_authorization"), do: "state-badge state-badge-danger"
  defp hub_cutover_consumption_badge_class("manual_attention"), do: "state-badge state-badge-danger"
  defp hub_cutover_consumption_badge_class("malformed"), do: "state-badge state-badge-danger"
  defp hub_cutover_consumption_badge_class("unsupported"), do: "state-badge state-badge-danger"
  defp hub_cutover_consumption_badge_class(_status), do: "state-badge state-badge-muted"

  defp hub_cutover_outcome_badge_class("succeeded"), do: "state-badge state-badge-active"
  defp hub_cutover_outcome_badge_class("not_executed"), do: "state-badge state-badge-muted"
  defp hub_cutover_outcome_badge_class("no_outcome"), do: "state-badge state-badge-muted"
  defp hub_cutover_outcome_badge_class("retryable"), do: "state-badge state-badge-warning"
  defp hub_cutover_outcome_badge_class("unknown"), do: "state-badge state-badge-danger"
  defp hub_cutover_outcome_badge_class("blocked"), do: "state-badge state-badge-danger"
  defp hub_cutover_outcome_badge_class("failed"), do: "state-badge state-badge-danger"
  defp hub_cutover_outcome_badge_class("manual_attention"), do: "state-badge state-badge-danger"
  defp hub_cutover_outcome_badge_class("malformed"), do: "state-badge state-badge-danger"
  defp hub_cutover_outcome_badge_class("unsupported"), do: "state-badge state-badge-danger"
  defp hub_cutover_outcome_badge_class(_status), do: "state-badge state-badge-muted"

  defp hub_cutover_outcome_closeout_badge_class("resolved"), do: "state-badge state-badge-active"
  defp hub_cutover_outcome_closeout_badge_class("no_outcome"), do: "state-badge state-badge-muted"
  defp hub_cutover_outcome_closeout_badge_class("no_closeout"), do: "state-badge state-badge-warning"
  defp hub_cutover_outcome_closeout_badge_class("stale"), do: "state-badge state-badge-warning"
  defp hub_cutover_outcome_closeout_badge_class("manual_attention"), do: "state-badge state-badge-danger"
  defp hub_cutover_outcome_closeout_badge_class("conflict"), do: "state-badge state-badge-danger"
  defp hub_cutover_outcome_closeout_badge_class("malformed"), do: "state-badge state-badge-danger"
  defp hub_cutover_outcome_closeout_badge_class("unsupported"), do: "state-badge state-badge-danger"
  defp hub_cutover_outcome_closeout_badge_class(_status), do: "state-badge state-badge-muted"

  defp hub_cutover_replay_decision_badge_class("no_replay_decision"), do: "state-badge state-badge-muted"
  defp hub_cutover_replay_decision_badge_class("no_unresolved_outcome"), do: "state-badge state-badge-muted"
  defp hub_cutover_replay_decision_badge_class("retry_consideration_allowed"), do: "state-badge state-badge-active"
  defp hub_cutover_replay_decision_badge_class("retry_consideration_denied"), do: "state-badge state-badge-warning"
  defp hub_cutover_replay_decision_badge_class("stale_closeout"), do: "state-badge state-badge-warning"
  defp hub_cutover_replay_decision_badge_class("blocked_unresolved_outcome"), do: "state-badge state-badge-danger"
  defp hub_cutover_replay_decision_badge_class("manual_attention"), do: "state-badge state-badge-danger"
  defp hub_cutover_replay_decision_badge_class("conflict"), do: "state-badge state-badge-danger"
  defp hub_cutover_replay_decision_badge_class("malformed"), do: "state-badge state-badge-danger"
  defp hub_cutover_replay_decision_badge_class("unsupported"), do: "state-badge state-badge-danger"
  defp hub_cutover_replay_decision_badge_class(_status), do: "state-badge state-badge-muted"

  defp hub_cutover_replay_request_audit_badge_class("no_request"), do: "state-badge state-badge-muted"
  defp hub_cutover_replay_request_audit_badge_class("would_allow_retry_consideration"), do: "state-badge state-badge-active"
  defp hub_cutover_replay_request_audit_badge_class("would_block"), do: "state-badge state-badge-warning"
  defp hub_cutover_replay_request_audit_badge_class("stale"), do: "state-badge state-badge-warning"
  defp hub_cutover_replay_request_audit_badge_class("manual_attention"), do: "state-badge state-badge-danger"
  defp hub_cutover_replay_request_audit_badge_class("conflict"), do: "state-badge state-badge-danger"
  defp hub_cutover_replay_request_audit_badge_class("malformed"), do: "state-badge state-badge-danger"
  defp hub_cutover_replay_request_audit_badge_class("unsupported"), do: "state-badge state-badge-danger"
  defp hub_cutover_replay_request_audit_badge_class(_status), do: "state-badge state-badge-muted"

  defp hub_cutover_closure_chain_badge_class("closed_succeeded"), do: "state-badge state-badge-active"
  defp hub_cutover_closure_chain_badge_class("closed_no_side_effect"), do: "state-badge state-badge-active"
  defp hub_cutover_closure_chain_badge_class("no_chain"), do: "state-badge state-badge-muted"
  defp hub_cutover_closure_chain_badge_class("no_request"), do: "state-badge state-badge-muted"
  defp hub_cutover_closure_chain_badge_class("open_retryable"), do: "state-badge state-badge-warning"
  defp hub_cutover_closure_chain_badge_class("stale"), do: "state-badge state-badge-warning"
  defp hub_cutover_closure_chain_badge_class("open_manual_attention"), do: "state-badge state-badge-danger"
  defp hub_cutover_closure_chain_badge_class("conflict"), do: "state-badge state-badge-danger"
  defp hub_cutover_closure_chain_badge_class("malformed"), do: "state-badge state-badge-danger"
  defp hub_cutover_closure_chain_badge_class("unsupported"), do: "state-badge state-badge-danger"
  defp hub_cutover_closure_chain_badge_class(_status), do: "state-badge state-badge-muted"

  defp hub_readiness_project_status(%{decision: decision}) when is_binary(decision), do: decision
  defp hub_readiness_project_status(_readiness), do: "readiness unknown"

  defp hub_activation_project_status(%{status: status}) when is_binary(status), do: status
  defp hub_activation_project_status(_plan), do: "unknown"

  defp hub_activation_ack_status(%{operator_acknowledgement: %{status: status}}) when is_binary(status), do: status
  defp hub_activation_ack_status(_plan), do: "missing"

  defp hub_cutover_project_status(%{decision: decision}) when is_binary(decision), do: decision
  defp hub_cutover_project_status(_gate), do: "unknown"

  defp hub_cutover_audit_project_status(%{status: status}) when is_binary(status), do: status
  defp hub_cutover_audit_project_status(_audit), do: "no_request"

  defp hub_cutover_history_project_status(%{status: status}) when is_binary(status), do: status
  defp hub_cutover_history_project_status(_history), do: "no_history"

  defp hub_cutover_permit_project_status(%{status: status}) when is_binary(status), do: status
  defp hub_cutover_permit_project_status(_permit), do: "no_request"

  defp hub_cutover_authorization_project_status(%{status: status}) when is_binary(status), do: status
  defp hub_cutover_authorization_project_status(_ledger), do: "no_ready_permit"

  defp hub_cutover_consumption_project_status(%{status: status}) when is_binary(status), do: status
  defp hub_cutover_consumption_project_status(_guard), do: "no_consumption"

  defp hub_cutover_outcome_project_status(%{status: status}) when is_binary(status), do: status
  defp hub_cutover_outcome_project_status(_ledger), do: "no_outcome"

  defp hub_cutover_outcome_closeout_project_status(%{status: status}) when is_binary(status), do: status
  defp hub_cutover_outcome_closeout_project_status(_closeout), do: "no_outcome"

  defp hub_cutover_replay_decision_project_status(%{status: status}) when is_binary(status), do: status
  defp hub_cutover_replay_decision_project_status(_decision), do: "no_replay_decision"

  defp hub_cutover_replay_request_audit_project_status(%{status: status}) when is_binary(status), do: status
  defp hub_cutover_replay_request_audit_project_status(_audit), do: "no_request"

  defp hub_cutover_closure_chain_project_status(%{status: status}) when is_binary(status), do: status
  defp hub_cutover_closure_chain_project_status(_closure_chain), do: "no_chain"

  defp hub_project_status("ready_to_poll"), do: "ready"
  defp hub_project_status("manual_attention"), do: "manual attention"
  defp hub_project_status("config_invalid"), do: "config error"
  defp hub_project_status("legacy_only"), do: "legacy-only"
  defp hub_project_status(status) when is_binary(status), do: status
  defp hub_project_status(_status), do: "unknown"

  defp hub_recent_provider_failures(%{recent_failure_classes: failures}) when is_list(failures) and failures != [] do
    failures
    |> Enum.take(3)
    |> Enum.join(", ")
  end

  defp hub_recent_provider_failures(_governance), do: "暂无 recent provider failure"

  defp hub_poll_text(%{allow_poll: true}), do: "poll ready"

  defp hub_poll_text(%{reason: reason}) when is_binary(reason) and reason != "" do
    "poll #{reason}"
  end

  defp hub_poll_text(_poll), do: "poll unknown"

  defp hub_preflight_text(nil), do: "not checked"
  defp hub_preflight_text(%{status: status}) when is_binary(status), do: status
  defp hub_preflight_text(_preflight), do: "unknown"

  defp hub_count(counts, key) when is_map(counts) do
    Map.get(counts, key) || hub_count_atom_key(counts, key) || 0
  end

  defp hub_count(_counts, _key), do: 0

  defp hub_count_atom_key(counts, key) do
    Map.get(counts, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp hub_short_request_id(%{request_id: request_id}) when is_binary(request_id) and request_id != "" do
    String.slice(request_id, 0, 12)
  end

  defp hub_short_request_id(%{request_fingerprint: fingerprint}) when is_binary(fingerprint) and fingerprint != "" do
    String.slice(fingerprint, 0, 12)
  end

  defp hub_short_request_id(_request), do: "unknown"

  defp hub_cutover_audit_reasons(%{cutover_operation_audit: %{reason_codes: reasons}}) when is_list(reasons) do
    Enum.take(reasons, 3)
  end

  defp hub_cutover_audit_reasons(_project), do: []

  defp hub_cutover_history_project_count(%{cutover_audit_history: %{counts: counts}}, key), do: hub_count(counts, Atom.to_string(key))
  defp hub_cutover_history_project_count(_project, _key), do: 0

  defp hub_unresolved_cutover_items(%{cutover_audit_history: %{unresolved_manual_attention: items}}) when is_list(items) do
    Enum.take(items, 3)
  end

  defp hub_unresolved_cutover_items(_project), do: []

  defp hub_cutover_permit_project_count(%{cutover_readiness_permit: %{permits: permits}}, key) when is_list(permits) do
    decisions = %{
      ready_count: "ready_for_execution_consideration",
      blocked_count: "blocked",
      stale_count: "stale",
      manual_attention_count: "manual_attention",
      unsupported_count: "unsupported",
      malformed_count: "malformed"
    }

    case Map.fetch(decisions, key) do
      {:ok, decision} -> Enum.count(permits, &(&1.decision == decision))
      :error -> 0
    end
  end

  defp hub_cutover_permit_project_count(_project, _key), do: 0

  defp hub_cutover_project_permits(%{cutover_readiness_permit: %{permits: permits}}) when is_list(permits) do
    Enum.take(permits, 3)
  end

  defp hub_cutover_project_permits(_project), do: []

  defp hub_cutover_authorization_project_count(%{cutover_execution_authorization_ledger: %{records: records}}, key) when is_list(records) do
    statuses = %{
      authorized_count: "authorized_for_explicit_execution",
      blocked_count: "blocked",
      stale_count: "stale",
      manual_attention_count: "manual_attention",
      unsupported_count: "unsupported",
      malformed_count: "malformed",
      no_ready_permit_count: "no_ready_permit"
    }

    case Map.fetch(statuses, key) do
      {:ok, status} -> Enum.count(records, &(&1.status == status))
      :error -> 0
    end
  end

  defp hub_cutover_authorization_project_count(_project, _key), do: 0

  defp hub_cutover_project_authorizations(%{cutover_execution_authorization_ledger: %{records: records}}) when is_list(records) do
    Enum.take(records, 3)
  end

  defp hub_cutover_project_authorizations(_project), do: []

  defp hub_cutover_consumption_project_count(%{cutover_authorization_consumption_guard: %{counts: counts}}, key), do: hub_count(counts, Atom.to_string(key))
  defp hub_cutover_consumption_project_count(_project, _key), do: 0

  defp hub_cutover_project_consumption_blocks(%{cutover_authorization_consumption_guard: %{blocked_sources: blocked_sources}})
       when is_list(blocked_sources) do
    Enum.take(blocked_sources, 3)
  end

  defp hub_cutover_project_consumption_blocks(_project), do: []

  defp hub_cutover_outcome_project_count(%{cutover_execution_outcome_ledger: %{counts: counts}}, key), do: hub_count(counts, Atom.to_string(key))
  defp hub_cutover_outcome_project_count(_project, _key), do: 0

  defp hub_cutover_project_unresolved_outcomes(%{cutover_execution_outcome_ledger: %{unresolved_outcomes: outcomes}})
       when is_list(outcomes) do
    Enum.take(outcomes, 3)
  end

  defp hub_cutover_project_unresolved_outcomes(_project), do: []

  defp hub_cutover_outcome_closeout_project_count(%{cutover_execution_outcome_closeout: %{counts: counts}}, key) do
    hub_count(counts, Atom.to_string(key))
  end

  defp hub_cutover_outcome_closeout_project_count(_project, _key), do: 0

  defp hub_cutover_project_outcome_closeouts(%{cutover_execution_outcome_closeout: %{closeouts: closeouts}})
       when is_list(closeouts) do
    Enum.take(closeouts, 3)
  end

  defp hub_cutover_project_outcome_closeouts(_project), do: []

  defp hub_cutover_replay_decision_project_count(%{cutover_replay_decision: %{counts: counts}}, key) do
    hub_count(counts, Atom.to_string(key))
  end

  defp hub_cutover_replay_decision_project_count(_project, _key), do: 0

  defp hub_cutover_replay_request_audit_project_count(%{cutover_replay_request_audit: %{counts: counts}}, key) do
    hub_count(counts, Atom.to_string(key))
  end

  defp hub_cutover_replay_request_audit_project_count(_project, _key), do: 0

  defp hub_cutover_project_replay_requests(%{cutover_replay_request_audit: %{requests: requests}})
       when is_list(requests) do
    Enum.take(requests, 3)
  end

  defp hub_cutover_project_replay_requests(_project), do: []

  defp hub_cutover_project_blocked_replay(%{cutover_replay_decision: %{blocked_replay: blocked_replay}})
       when is_list(blocked_replay) do
    Enum.take(blocked_replay, 3)
  end

  defp hub_cutover_project_blocked_replay(_project), do: []

  defp hub_cutover_project_replay_reason_codes(%{cutover_replay_decision: %{recent_reason_codes: reason_codes}})
       when is_list(reason_codes) do
    Enum.take(reason_codes, 3)
  end

  defp hub_cutover_project_replay_reason_codes(_project), do: []

  defp hub_cutover_closure_chain_project_count(%{detail: %{closure_chain: %{closure_status_counts: counts}}}, key) do
    hub_count(counts, Atom.to_string(key))
  end

  defp hub_cutover_closure_chain_project_count(_project, _key), do: 0

  defp hub_cutover_closure_chain_project_ref_count(%{detail: %{closure_chain: closure_chain}}, reference_type, status)
       when is_map(closure_chain) do
    closure_chain
    |> Map.get(closure_chain_reference_count_key(reference_type), %{})
    |> hub_count(Atom.to_string(status))
  end

  defp hub_cutover_closure_chain_project_ref_count(_project, _reference_type, _status), do: 0

  defp hub_cutover_project_closure_reason_codes(%{detail: %{closure_chain: %{recent_reason_codes: reason_codes}}})
       when is_list(reason_codes) do
    Enum.take(reason_codes, 3)
  end

  defp hub_cutover_project_closure_reason_codes(_project), do: []

  defp hub_cutover_project_closure_action_codes(%{detail: %{closure_chain: %{recent_action_codes: action_codes}}})
       when is_list(action_codes) do
    Enum.take(action_codes, 3)
  end

  defp hub_cutover_project_closure_action_codes(_project), do: []

  defp hub_cutover_project_closure_fingerprints(%{detail: %{closure_chain: %{safe_evidence_fingerprints: fingerprints}}})
       when is_map(fingerprints) do
    fingerprints
    |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
    |> Enum.reject(&String.ends_with?(&1, "="))
    |> Enum.sort()
    |> Enum.take(3)
  end

  defp hub_cutover_project_closure_fingerprints(_project), do: []

  defp closure_chain_reference_count_key(:closeout), do: :closeout_reference_status_counts
  defp closure_chain_reference_count_key(:replay_decision), do: :replay_decision_reference_status_counts
  defp closure_chain_reference_count_key(:replay_request_audit), do: :replay_request_audit_reference_status_counts

  defp format_short_list(values) when is_list(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(3)
    |> case do
      [] -> "none"
      items -> Enum.join(items, ", ")
    end
  end

  defp format_short_list(_values), do: "none"

  defp hub_attention_text(%{summary_error: %{code: code}}), do: "summary error #{code}"
  defp hub_attention_text(%{status: "manual_attention"}), do: "manual attention"
  defp hub_attention_text(%{status: "blocked"}), do: "blocked"
  defp hub_attention_text(%{status: "backoff"}), do: "backoff"
  defp hub_attention_text(_project), do: "暂无"

  defp hub_required_actions(%{migration_readiness: %{required_operator_actions: actions}}) when is_list(actions) do
    Enum.take(actions, 4)
  end

  defp hub_required_actions(_project), do: []

  defp hub_required_acknowledgements(%{activation_plan: %{required_acknowledgements: actions}}) when is_list(actions) do
    Enum.take(actions, 4)
  end

  defp hub_required_acknowledgements(_project), do: []

  defp hub_short_plan_id(%{plan_id: plan_id}) when is_binary(plan_id), do: String.slice(plan_id, 0, 12)
  defp hub_short_plan_id(_plan), do: "unknown"

  defp hub_readiness_reasons(%{migration_readiness: %{blocking_reasons: blocking, advisory_reasons: advisory}})
       when is_list(blocking) and is_list(advisory) do
    Enum.take(blocking ++ advisory, 3)
  end

  defp hub_readiness_reasons(_project), do: []

  defp stage_conflict_text(%{local_stage: local_stage, provider_stage: provider_stage}) do
    "#{local_stage || "unknown"} -> #{provider_stage || "unknown"}"
  end

  defp stage_conflict_text(%{"local_stage" => local_stage, "provider_stage" => provider_stage}) do
    "#{local_stage || "unknown"} -> #{provider_stage || "unknown"}"
  end

  defp stage_conflict_text(conflict), do: inspect(conflict, pretty: true)

  defp recovery_artifact_path(%{artifact_dir: artifact_dir}) when is_binary(artifact_dir), do: artifact_dir
  defp recovery_artifact_path(%{"artifact_dir" => artifact_dir}) when is_binary(artifact_dir), do: artifact_dir
  defp recovery_artifact_path(_artifact), do: nil

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "暂无"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
