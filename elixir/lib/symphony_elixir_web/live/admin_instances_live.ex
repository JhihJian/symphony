defmodule SymphonyElixirWeb.AdminInstancesLive do
  @moduledoc """
  Operator dashboard for independently deployed Symphony instances.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.Endpoint

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_instances(socket, nil)}
  end

  @impl true
  def handle_event("lifecycle", %{"action" => action, "name" => name}, socket) do
    message =
      case run_action(action, name) do
        {:ok, %{service: service}} -> "已请求 #{action} #{service}"
        {:error, %{message: message}} -> message
      end

    {:noreply, assign_instances(socket, message)}
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

      <section class="metric-grid">
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
          <div class="table-wrap">
            <table class="data-table" style="min-width: 1120px;">
              <thead>
                <tr>
                  <th>实例</th>
                  <th>状态</th>
                  <th>Tracker</th>
                  <th>Issue 压力</th>
                  <th>健康摘要</th>
                  <th>Dashboard / API</th>
                  <th>Workspace / Logs</th>
                  <th>操作</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={instance <- @instances}>
                  <td>
                    <div class="issue-stack">
                      <span class="issue-id"><%= instance.name %></span>
                      <span class="muted mono"><%= instance.service %></span>
                    </div>
                  </td>
                  <td><span class={instance_badge_class(instance.status)}><%= instance.status %></span></td>
                  <td>
                    <div class="detail-stack">
                      <span><%= get_in(instance, [:tracker, :kind]) || "unknown" %></span>
                      <span class="muted"><%= get_in(instance, [:tracker, :scope]) || "未配置范围" %></span>
                    </div>
                  </td>
                  <td>
                    <div class="detail-stack numeric">
                      <span>运行中 <%= count(instance, :running) %></span>
                      <span>重试中 <%= count(instance, :retrying) %></span>
                      <span>阻塞 <%= count(instance, :blocked) %></span>
                    </div>
                  </td>
                  <td>
                    <div class="detail-stack">
                      <span><%= get_in(instance, [:health, :summary]) || "暂无健康摘要" %></span>
                      <span :if={get_in(instance, [:health, :error])} class="muted"><%= get_in(instance, [:health, :error]) %></span>
                    </div>
                  </td>
                  <td>
                    <div class="detail-stack">
                      <a :if={instance.dashboard_url} class="issue-link" href={instance.dashboard_url}>Dashboard</a>
                      <a :if={instance.api_url} class="issue-link" href={instance.api_url}>API</a>
                      <span class="muted"><%= instance.dashboard_url || "未配置端口" %></span>
                    </div>
                  </td>
                  <td>
                    <div class="detail-stack mono">
                      <span><%= instance.workspace_root || "workspace 未知" %></span>
                      <span class="muted"><%= instance.logs_root || "logs 未知" %></span>
                    </div>
                  </td>
                  <td>
                    <div class="action-row">
                      <button phx-click="lifecycle" phx-value-action="start" phx-value-name={instance.name}>启动</button>
                      <button phx-click="lifecycle" phx-value-action="stop" phx-value-name={instance.name}>停止</button>
                      <button phx-click="lifecycle" phx-value-action="restart" phx-value-name={instance.name}>重启</button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>
    </section>
    """
  end

  defp assign_instances(socket, notice) do
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
    |> assign(:notice, notice)
  end

  defp run_action("start", name), do: registry().start_instance(name, registry_opts())
  defp run_action("stop", name), do: registry().stop_instance(name, registry_opts())
  defp run_action("restart", name), do: registry().restart_instance(name, registry_opts())
  defp run_action(action, _name), do: {:error, %{message: "Unsupported lifecycle action: #{action}"}}

  defp registry do
    Endpoint.config(:instance_registry) || SymphonyElixir.InstanceRegistry
  end

  defp registry_opts do
    Endpoint.config(:instance_registry_opts) || []
  end

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
end
