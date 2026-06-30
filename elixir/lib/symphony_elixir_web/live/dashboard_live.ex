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
                        <span :for={action <- hub_required_actions(project)} class="muted event-meta">
                          action <%= action.code %>
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

  defp hub_readiness_project_status(%{decision: decision}) when is_binary(decision), do: decision
  defp hub_readiness_project_status(_readiness), do: "readiness unknown"

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
    Map.get(counts, key) || Map.get(counts, String.to_atom(key), 0)
  rescue
    ArgumentError -> Map.get(counts, key, 0)
  end

  defp hub_count(_counts, _key), do: 0

  defp hub_attention_text(%{summary_error: %{code: code}}), do: "summary error #{code}"
  defp hub_attention_text(%{status: "manual_attention"}), do: "manual attention"
  defp hub_attention_text(%{status: "blocked"}), do: "blocked"
  defp hub_attention_text(%{status: "backoff"}), do: "backoff"
  defp hub_attention_text(_project), do: "暂无"

  defp hub_required_actions(%{migration_readiness: %{required_operator_actions: actions}}) when is_list(actions) do
    Enum.take(actions, 4)
  end

  defp hub_required_actions(_project), do: []

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
