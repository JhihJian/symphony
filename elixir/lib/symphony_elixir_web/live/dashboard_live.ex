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

  defp stage_conflict_text(%{local_stage: local_stage, provider_stage: provider_stage}) do
    "#{local_stage || "unknown"} -> #{provider_stage || "unknown"}"
  end

  defp stage_conflict_text(%{"local_stage" => local_stage, "provider_stage" => provider_stage}) do
    "#{local_stage || "unknown"} -> #{provider_stage || "unknown"}"
  end

  defp stage_conflict_text(conflict), do: inspect(conflict, pretty: true)

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "暂无"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
