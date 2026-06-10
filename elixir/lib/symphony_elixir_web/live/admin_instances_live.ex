defmodule SymphonyElixirWeb.AdminInstancesLive do
  @moduledoc """
  Operator dashboard for independently deployed Symphony instances.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.Endpoint

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_admin_state(socket, nil)}
  end

  @impl true
  def handle_event("lifecycle", %{"action" => action, "name" => name}, socket) do
    message =
      case run_action(action, name) do
        {:ok, %{service: service}} -> "已请求 #{action} #{service}"
        {:error, %{message: message}} -> message
      end

    {:noreply, assign_admin_state(socket, message)}
  end

  def handle_event("auto_update", %{"action" => action}, socket) do
    {message, auto_update} =
      case run_auto_update_action(action) do
        {:ok, snapshot} -> {"自动更新操作完成：#{auto_update_status(action, snapshot)}", snapshot}
        {:error, snapshot} -> {"自动更新操作失败：#{auto_update_error(snapshot)}", snapshot}
      end

    {:noreply, assign_admin_state(socket, message, auto_update)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony 实例管理</p>
            <h1 class="hero-title">多实例管理 Dashboard</h1>
            <p class="hero-copy">
              集中观察多个独立 Symphony 实例的 systemd 状态、运行压力、健康摘要和运维入口。
            </p>
          </div>
          <div class="status-stack">
            <a class="status-badge" href="/">打开单实例 Dashboard</a>
            <a class="status-badge" href="/api/v1/admin/instances">JSON API</a>
          </div>
        </div>
      </header>

      <%= if @notice do %>
        <section class="section-card">
          <p class="section-copy"><%= @notice %></p>
        </section>
      <% end %>

      <section class="metric-grid fleet-summary">
        <article class="metric-card">
          <p class="metric-label">实例总数</p>
          <p class="metric-value numeric"><%= length(@instances) %></p>
          <p class="metric-detail">已在配置目录登记的 Symphony 实例。</p>
        </article>
        <article class="metric-card">
          <p class="metric-label">运行中 Issue</p>
          <p class="metric-value numeric"><%= total_count(@instances, :running) %></p>
          <p class="metric-detail">来自各实例 `/api/v1/state` 的聚合值。</p>
        </article>
        <article class="metric-card">
          <p class="metric-label">重试中 Issue</p>
          <p class="metric-value numeric"><%= total_count(@instances, :retrying) %></p>
          <p class="metric-detail">不可达实例按 0 计数，不影响其他实例。</p>
        </article>
        <article class="metric-card">
          <p class="metric-label">阻塞 Issue</p>
          <p class="metric-value numeric"><%= total_count(@instances, :blocked) %></p>
          <p class="metric-detail">等待操作员输入或批准的会话数。</p>
        </article>
      </section>

      <section class="section-card auto-update-panel">
        <div class="section-header">
          <div>
            <h2 class="section-title">GitHub main 自动更新</h2>
            <p class="section-copy">
              通过 GitHub API 条件轮询检测 main 最新提交，并按实例策略决定是否重启。
            </p>
          </div>
          <div class="instance-actions">
            <button
              class="lifecycle-button lifecycle-button-neutral"
              phx-click="auto_update"
              phx-value-action="check"
            >立即检查</button>
            <button
              class="lifecycle-button lifecycle-button-primary"
              phx-click="auto_update"
              phx-value-action="update"
            >执行更新</button>
          </div>
        </div>

        <div class="instance-meta-grid">
          <section class="instance-panel">
            <p class="panel-label">当前部署</p>
            <div class="detail-stack mono">
              <span><%= @auto_update.current_sha || "未知" %></span>
              <span class="muted"><%= @auto_update.source_root || "source root 未配置" %></span>
            </div>
          </section>

          <section class="instance-panel">
            <p class="panel-label">远端 main</p>
            <div class="detail-stack mono">
              <span><%= @auto_update.remote_sha || "尚未检查" %></span>
              <span class="muted"><%= @auto_update.repo %>#<%= @auto_update.branch %></span>
            </div>
          </section>

          <section class="instance-panel">
            <p class="panel-label">更新状态</p>
            <div class="detail-stack">
              <span class={update_badge_class(@auto_update.pending_update?)}><%= update_state_text(@auto_update.pending_update?) %></span>
              <span class="muted">最近检查：<%= get_in(@auto_update, [:last_check, :status]) || "never" %></span>
              <span class="muted">检查时间：<%= format_datetime(get_in(@auto_update, [:last_check, :checked_at])) %></span>
            </div>
          </section>

          <section class="instance-panel">
            <p class="panel-label">下次检查</p>
            <div class="detail-stack mono">
              <span><%= format_datetime(@auto_update.next_check_at) %></span>
              <span class="muted">间隔 <%= div(@auto_update.poll_interval_ms || 0, 60_000) %> 分钟</span>
            </div>
          </section>

          <section class="instance-panel">
            <p class="panel-label">GitHub API</p>
            <div class="detail-stack">
              <span>ETag <span class="mono"><%= get_in(@auto_update, [:last_check, :etag]) || "无" %></span></span>
              <span class="muted">剩余额度 <%= get_in(@auto_update, [:last_check, :rate_limit, :remaining]) || "未知" %></span>
              <span :if={get_in(@auto_update, [:last_check, :error])} class="muted"><%= get_in(@auto_update, [:last_check, :error]) %></span>
            </div>
          </section>

          <section class="instance-panel">
            <p class="panel-label">策略</p>
            <div class="detail-stack">
              <span>空闲自动重启</span>
              <span class="muted">运行中延后；失败实例跳过；可配置为只构建、手动确认或强制重启。</span>
            </div>
          </section>
        </div>

        <%= if get_in(@auto_update, [:last_update, :instance_results]) not in [nil, []] do %>
          <div class="table-wrap update-results-table">
            <table class="data-table">
              <thead>
                <tr>
                  <th>实例</th>
                  <th>策略</th>
                  <th>决策</th>
                  <th>原因</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={result <- @auto_update.last_update.instance_results}>
                  <td class="mono"><%= result.name %></td>
                  <td><%= result.strategy %></td>
                  <td><%= result.decision %></td>
                  <td><%= result.reason %></td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">实例总览</h2>
            <p class="section-copy">管理面只展示和触发生命周期操作，不参与 issue 派发或 workspace 隔离。</p>
          </div>
        </div>

        <%= if @instances == [] do %>
          <p class="empty-state">未发现已登记的 Symphony 实例。</p>
        <% else %>
          <div class="instance-card-grid">
            <article :for={instance <- @instances} class="instance-card">
              <header class="instance-card-header">
                <div class="instance-identity">
                  <span class="instance-name"><%= instance.name %></span>
                  <span class="muted mono"><%= instance.service %></span>
                </div>
                <span class={instance_badge_class(instance.status)}><%= instance.status %></span>
              </header>

              <div class="instance-card-body">
                <div class="instance-meta-grid">
                  <section class="instance-panel">
                    <p class="panel-label">Tracker</p>
                    <div class="detail-stack">
                      <span><%= get_in(instance, [:tracker, :kind]) || "unknown" %></span>
                      <span class="muted"><%= get_in(instance, [:tracker, :scope]) || "未配置范围" %></span>
                    </div>
                  </section>

                  <section class="instance-panel pressure-panel">
                    <p class="panel-label">Issue 压力</p>
                    <div class="pressure-grid numeric">
                      <span>运行中 <%= count(instance, :running) %></span>
                      <span>重试中 <%= count(instance, :retrying) %></span>
                      <span>阻塞 <%= count(instance, :blocked) %></span>
                    </div>
                  </section>

                  <section class="instance-panel health-panel">
                    <p class="panel-label">健康摘要</p>
                    <div class="detail-stack">
                      <span><%= get_in(instance, [:health, :summary]) || "暂无健康摘要" %></span>
                      <span class="muted"><%= get_in(instance, [:systemd, :enabled]) || "unknown" %> / <%= get_in(instance, [:systemd, :sub]) || "unknown" %></span>
                      <span :if={get_in(instance, [:health, :error])} class="muted"><%= get_in(instance, [:health, :error]) %></span>
                    </div>
                  </section>

                  <section class="instance-panel">
                    <p class="panel-label">更新策略</p>
                    <div class="detail-stack">
                      <span><%= Map.get(instance, :strategy, "idle_restart") %></span>
                      <span class="muted"><%= strategy_description(Map.get(instance, :strategy, "idle_restart")) %></span>
                    </div>
                  </section>

                  <section class="instance-panel">
                    <p class="panel-label">Dashboard / API</p>
                    <div class="detail-stack">
                      <a :if={instance.dashboard_url} class="issue-link" href={instance.dashboard_url}>Dashboard</a>
                      <a :if={instance.api_url} class="issue-link" href={instance.api_url}>API</a>
                      <span class="muted"><%= instance.dashboard_url || "未配置端口" %></span>
                    </div>
                  </section>

                  <section class="instance-panel path-panel">
                    <p class="panel-label">Workspace / Logs</p>
                    <div class="detail-stack mono">
                      <span><%= instance.workspace_root || "workspace 未知" %></span>
                      <span class="muted"><%= instance.logs_root || "logs 未知" %></span>
                    </div>
                  </section>
                </div>
              </div>

              <footer class="instance-actions">
                <button
                  class="lifecycle-button lifecycle-button-primary"
                  phx-click="lifecycle"
                  phx-value-action="start"
                  phx-value-name={instance.name}
                >启动</button>
                <button
                  class="lifecycle-button lifecycle-button-danger"
                  phx-click="lifecycle"
                  phx-value-action="stop"
                  phx-value-name={instance.name}
                >停止</button>
                <button
                  class="lifecycle-button lifecycle-button-neutral"
                  phx-click="lifecycle"
                  phx-value-action="restart"
                  phx-value-name={instance.name}
                >重启</button>
              </footer>
            </article>
          </div>
        <% end %>
      </section>
    </section>
    """
  end

  defp assign_admin_state(socket, notice, auto_update \\ nil) do
    instances =
      case registry().list_instances(registry_opts()) do
        {:ok, instances} ->
          instances

        {:error, reason} ->
          [
            %{
              name: "registry",
              service: "n/a",
              status: "unknown",
              dashboard_url: nil,
              api_url: nil,
              tracker: %{kind: nil, scope: nil},
              counts: %{running: 0, retrying: 0, blocked: 0},
              health: %{status: "unreachable", summary: "instance registry unavailable", error: inspect(reason)},
              workspace_root: nil,
              logs_root: nil
            }
          ]
      end

    socket
    |> assign(:instances, instances)
    |> assign(:auto_update, auto_update || auto_update_snapshot())
    |> assign(:notice, notice)
  end

  defp run_action("start", name), do: registry().start_instance(name, registry_opts())
  defp run_action("stop", name), do: registry().stop_instance(name, registry_opts())
  defp run_action("restart", name), do: registry().restart_instance(name, registry_opts())
  defp run_action(action, _name), do: {:error, %{message: "Unsupported lifecycle action: #{action}"}}

  defp run_auto_update_action("check"), do: auto_update_module().check_now(auto_update_opts())
  defp run_auto_update_action("update"), do: auto_update_module().update_now(auto_update_opts())
  defp run_auto_update_action(_action), do: {:error, %{last_check: %{error: "Unsupported auto update action"}}}

  defp registry do
    Endpoint.config(:instance_registry) || SymphonyElixir.InstanceRegistry
  end

  defp registry_opts do
    Endpoint.config(:instance_registry_opts) || []
  end

  defp auto_update_snapshot do
    auto_update_module().snapshot(auto_update_opts())
  rescue
    error ->
      %{
        repo: "unknown",
        branch: "main",
        source_root: nil,
        poll_interval_ms: 0,
        current_sha: nil,
        remote_sha: nil,
        pending_update?: false,
        next_check_at: nil,
        last_check: %{status: "unavailable", error: Exception.message(error), rate_limit: %{}, etag: nil},
        last_update: %{status: "idle", instance_results: []}
      }
  end

  defp auto_update_module do
    Endpoint.config(:auto_update) || SymphonyElixir.AutoUpdate
  end

  defp auto_update_opts do
    Endpoint.config(:auto_update_opts) || []
  end

  defp auto_update_status("check", snapshot), do: get_in(snapshot, [:last_check, :status]) || "unknown"
  defp auto_update_status("update", snapshot), do: get_in(snapshot, [:last_update, :status]) || "unknown"
  defp auto_update_status(_action, snapshot), do: get_in(snapshot, [:last_update, :status]) || get_in(snapshot, [:last_check, :status]) || "unknown"

  defp total_count(instances, key) do
    Enum.reduce(instances, 0, fn instance, total -> total + count(instance, key) end)
  end

  defp count(instance, key) do
    counts = Map.get(instance, :counts, %{})
    Map.get(counts, key, Map.get(counts, to_string(key), 0))
  end

  defp instance_badge_class("running"), do: "state-badge state-badge-active"
  defp instance_badge_class("failed"), do: "state-badge state-badge-blocked"
  defp instance_badge_class("stopped"), do: "state-badge state-badge-terminal"
  defp instance_badge_class(_status), do: "state-badge state-badge-muted"

  defp strategy_description("idle_restart"), do: "空闲时自动更新并重启"
  defp strategy_description("defer_until_idle"), do: "运行中延后，空闲后重启"
  defp strategy_description("download_only"), do: "只下载构建，不自动重启"
  defp strategy_description("manual_restart"), do: "手动确认后重启"
  defp strategy_description("force_restart"), do: "强制重启（危险操作）"
  defp strategy_description(_strategy), do: "使用默认空闲重启策略"

  defp update_state_text(true), do: "有可用更新"
  defp update_state_text(false), do: "已是最新"

  defp update_badge_class(true), do: "state-badge state-badge-blocked"
  defp update_badge_class(false), do: "state-badge state-badge-active"

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(nil), do: "未知"
  defp format_datetime(datetime), do: to_string(datetime)

  defp auto_update_error(snapshot) when is_map(snapshot) do
    get_in(snapshot, [:last_update, :error]) || get_in(snapshot, [:last_check, :error]) || "unknown error"
  end
end
