defmodule SymphonyElixirWeb.AdminInstancesLive do
  @moduledoc """
  Operator dashboard for independently deployed Symphony instances.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.Endpoint

  @admin_instances_timeout_ms 10_000
  @create_safe_name_pattern ~r/\A[A-Za-z0-9_.-]+\z/
  @create_env_var_pattern ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @max_port 65_535
  @update_strategies ["idle_restart", "defer_until_idle", "download_only", "manual_restart", "force_restart"]
  @create_field_labels %{
    "project" => "Project",
    "owner" => "Owner",
    "repo" => "Repo",
    "project_number" => "Project Number",
    "port" => "Port",
    "update_strategy" => "更新策略",
    "max_agents" => "Max Agents",
    "token_env" => "Token Env"
  }

  @impl true
  def mount(_params, session, socket) do
    local_admin? = local_admin_session?(Map.get(session, "admin_client_ip") || Map.get(session, :admin_client_ip))

    socket =
      socket
      |> assign(:active_nav, :instances)
      |> assign(:access_role, if(local_admin?, do: "本机管理员", else: "远程只读"))
      |> assign(:local_admin?, local_admin?)
      |> assign(:create_form, default_create_form())
      |> assign(:create_errors, %{})
      |> assign(:create_form_open?, false)
      |> assign(:logs, nil)
      |> assign(:instances, [])
      |> assign(:instances_loading?, true)
      |> assign(:instances_loaded?, false)
      |> assign(:instances_error, nil)
      |> assign(:auto_update, auto_update_loading_snapshot())
      |> assign(:update_timer, update_timer_loading_snapshot())
      |> assign(:notice, nil)

    {:ok, refresh_admin_state(socket, nil)}
  end

  @impl true
  def handle_async(:admin_state, {:ok, admin_state}, socket) do
    {:noreply, apply_admin_state(socket, admin_state)}
  end

  def handle_async(:admin_state, {:exit, reason}, socket) do
    {:noreply, assign_instances_error(socket, "实例总览加载失败：#{inspect(reason)}")}
  end

  @impl true
  def handle_event("lifecycle", %{"action" => action, "name" => name}, socket) do
    message = guarded(socket, fn -> action_message(run_action(action, name), action) end)

    {:noreply, refresh_admin_state(socket, message)}
  end

  def handle_event("toggle_create_form", _params, socket) do
    {:noreply, assign(socket, :create_form_open?, !socket.assigns.create_form_open?)}
  end

  def handle_event("create_instance", %{"instance" => params}, socket) do
    form = normalize_form(params)

    {message, form, create_form_open?, create_errors, refresh?} =
      cond do
        !socket.assigns.local_admin? ->
          {"管理操作只允许本机客户端访问", form, true, %{}, true}

        map_size(create_form_errors(form)) > 0 ->
          {"请先修正新建实例表单中标记的字段。", form, true, create_form_errors(form), false}

        true ->
          guarded_create(socket, params, fn ->
            case registry().create_instance(params, registry_opts()) do
              {:ok, %{instance: instance}} ->
                {"已创建实例 #{instance.name}", default_create_form(), false, %{}, true}

              {:error, %{message: message} = error} ->
                {message, form, true, create_errors_from_registry_error(error), true}
            end
          end)
      end

    socket =
      socket
      |> assign(:create_form, form)
      |> assign(:create_form_open?, create_form_open?)
      |> assign(:create_errors, create_errors)

    socket =
      if refresh? do
        refresh_admin_state(socket, message)
      else
        assign(socket, :notice, message)
      end

    {:noreply, socket}
  end

  def handle_event("logs", %{"name" => name}, socket) do
    {message, logs} =
      guarded_logs(socket, fn ->
        case registry().latest_logs(name, registry_opts()) do
          {:ok, payload} -> {"已读取 #{payload.service} 最近日志", payload}
          {:error, %{message: message}} -> {message, nil}
        end
      end)

    socket =
      socket
      |> assign(:logs, logs)
      |> refresh_admin_state(message)

    {:noreply, socket}
  end

  def handle_event("auto_update", %{"action" => action}, socket) do
    {message, auto_update} =
      guarded_auto_update(socket, fn ->
        case safe_auto_update_action(action) do
          {:ok, snapshot} ->
            {"自动更新操作完成：#{auto_update_status(action, snapshot)}", snapshot}

          {:error, snapshot} ->
            {"自动更新操作失败：#{auto_update_error(snapshot)}", snapshot}
        end
      end)

    {:noreply, refresh_admin_state(socket, message, auto_update)}
  end

  def handle_event("update_timer", %{"action" => action}, socket) do
    message = guarded(socket, fn -> action_message(run_update_timer_action(action), action) end)

    {:noreply, refresh_admin_state(socket, message)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony 实例管理</p>
            <h1 class="hero-title">实例管理工作台</h1>
            <p class="hero-copy">
              集中观察多个独立 Symphony 实例的 systemd 状态、运行压力、健康摘要和运维入口。
            </p>
          </div>
          <div class="status-stack">
            <span class={if @local_admin?, do: "state-badge state-badge-active", else: "state-badge state-badge-warning"}>
              <%= if @local_admin?, do: "可执行管理操作", else: "只读预览" %>
            </span>
            <a :if={@local_admin?} class="status-badge" href="/api/v1/admin/instances">JSON API</a>
            <span :if={!@local_admin?} class="status-badge status-badge-disabled">JSON API 仅本机</span>
          </div>
        </div>
      </header>

      <%= if @notice do %>
        <section class={notice_class(@notice)} role={notice_role(@notice)} aria-live="polite">
          <strong><%= notice_title(@notice) %></strong>
          <p><%= @notice %></p>
        </section>
      <% end %>

      <%= unless @local_admin? do %>
        <section class="error-card" id="admin-readonly-reason">
          <h2 class="error-title">管理操作已限制</h2>
          <p class="error-copy">实例创建、systemd 操作和日志读取只允许本机客户端访问。</p>
        </section>
      <% end %>

      <section :if={@instances_loading? && !@instances_loaded?} class="notice-banner notice-banner-warning" role="status" aria-live="polite" aria-busy="true">
        <strong>正在加载实例总览</strong>
        <p>页面已可操作；实例 systemd 状态和 `/api/v1/state` 快照会在后台加载，慢实例不会阻塞首屏。</p>
      </section>

      <section :if={@instances_error} class="notice-banner notice-banner-error" role="alert" aria-live="polite">
        <strong>实例总览暂不可用</strong>
        <p><%= @instances_error %></p>
      </section>

      <section :if={@instances_loaded?} class="metric-grid fleet-summary">
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
          <p class="metric-detail">仅统计可返回状态快照的实例。</p>
        </article>
        <article class="metric-card">
          <p class="metric-label">阻塞 Issue</p>
          <p class="metric-value numeric"><%= total_count(@instances, :blocked) %></p>
          <p class="metric-detail">等待操作员输入或批准的会话数。</p>
        </article>
        <article class="metric-card">
          <p class="metric-label">不可达/未知实例</p>
          <p class="metric-value numeric"><%= unavailable_instance_count(@instances) %></p>
          <p class="metric-detail">这些实例的 Issue 数可能未知，不应被解读为 0 风险。</p>
        </article>
      </section>

      <%= instance_overview(assigns) %>

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
              type="button"
              class="lifecycle-button lifecycle-button-neutral"
              phx-click="auto_update"
              phx-value-action="check"
              disabled={!auto_update_action_enabled?(@local_admin?, @auto_update, "check")}
              aria-disabled={aria_disabled(auto_update_action_enabled?(@local_admin?, @auto_update, "check"))}
              aria-describedby={auto_update_action_describedby(@local_admin?, @auto_update, "check")}
              aria-label="立即检查 GitHub main 自动更新"
              title={auto_update_action_title(@local_admin?, @auto_update, "check")}
              phx-disable-with="检查中..."
            >立即检查</button>
            <button
              type="button"
              class="lifecycle-button lifecycle-button-primary"
              phx-click="auto_update"
              phx-value-action="update"
              disabled={!auto_update_action_enabled?(@local_admin?, @auto_update, "update")}
              aria-disabled={aria_disabled(auto_update_action_enabled?(@local_admin?, @auto_update, "update"))}
              aria-describedby={auto_update_action_describedby(@local_admin?, @auto_update, "update")}
              aria-label="执行 GitHub main 自动更新"
              title={auto_update_action_title(@local_admin?, @auto_update, "update")}
              phx-confirm="确认执行 GitHub main 更新？此操作会按各实例更新策略执行，部分实例可能被重启。"
              phx-disable-with="更新中..."
            >执行更新</button>
          </div>
        </div>

        <p :if={auto_update_action_notice(@local_admin?, @auto_update)} id="auto-update-action-note" class="lifecycle-action-note">
          <%= auto_update_action_notice(@local_admin?, @auto_update) %>
        </p>

        <%= if auto_update_state(@auto_update) == :unavailable do %>
          <section class="instance-panel" id="auto-update-unavailable-reason">
            <p class="panel-label">自动更新状态不可用</p>
            <div class="detail-stack">
              <span>无法判断 GitHub main 是否已有新版本。</span>
              <span class="muted">页面和实例管理仍可用；请检查自动更新进程或最近错误后再执行更新相关操作。</span>
            </div>
          </section>
        <% end %>

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
              <span class={update_badge_class(@auto_update)}><%= update_state_text(@auto_update) %></span>
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

      <%= create_instance_panel(assigns) %>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">systemd 自动更新 timer</h2>
            <p class="section-copy">查看和管理 `symphony-update.timer` 与 `symphony-update.service`。</p>
          </div>
          <div class="instance-actions">
            <button type="button" class="lifecycle-button lifecycle-button-primary" phx-click="update_timer" phx-value-action="enable" disabled={!@local_admin?} aria-disabled={aria_disabled(@local_admin?)} aria-describedby={admin_disabled_reason_id(@local_admin?)} aria-label="启用 symphony-update.timer 自动更新定时器" title={admin_disabled_title(@local_admin?)} phx-confirm="确认启用并立即启动 symphony-update.timer？此操作会改变用户 systemd 自动更新定时器状态，之后会按计划检查 GitHub main 更新。" phx-disable-with="启用中...">启用</button>
            <button type="button" class="lifecycle-button lifecycle-button-danger" phx-click="update_timer" phx-value-action="disable" disabled={!@local_admin?} aria-disabled={aria_disabled(@local_admin?)} aria-describedby={admin_disabled_reason_id(@local_admin?)} aria-label="禁用 symphony-update.timer 自动更新定时器" title={admin_disabled_title(@local_admin?)} phx-confirm="确认禁用 symphony-update.timer？禁用后不会自动检查 GitHub main 更新。" phx-disable-with="禁用中...">禁用</button>
            <button type="button" class="lifecycle-button lifecycle-button-neutral" phx-click="update_timer" phx-value-action="trigger" disabled={!@local_admin?} aria-disabled={aria_disabled(@local_admin?)} aria-describedby={admin_disabled_reason_id(@local_admin?)} aria-label="手动触发 symphony-update.service" title={admin_disabled_title(@local_admin?)} phx-confirm="确认手动触发 symphony-update.service？" phx-disable-with="触发中...">手动触发</button>
          </div>
        </div>

        <div class="instance-meta-grid timer-grid">
          <section class="instance-panel">
            <p class="panel-label">Timer</p>
            <div class="detail-stack">
              <span><%= @update_timer.timer %></span>
              <span class="muted"><%= @update_timer.enabled %> / <%= @update_timer.active %> / <%= @update_timer.sub || "unknown" %></span>
            </div>
          </section>

          <section class="instance-panel">
            <p class="panel-label">Service</p>
            <div class="detail-stack">
              <span><%= @update_timer.service %></span>
              <span class="muted"><%= @update_timer.service_active %> / <%= @update_timer.service_sub || "unknown" %></span>
            </div>
          </section>

          <section class="instance-panel">
            <p class="panel-label">Next Run</p>
            <div class="detail-stack mono">
              <span><%= @update_timer.next_run || "未知" %></span>
              <span class="muted">Last Trigger <%= @update_timer.last_trigger || "未知" %></span>
            </div>
          </section>
        </div>
      </section>

      <%= if @logs do %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">最近日志</h2>
              <p class="section-copy"><%= @logs.service %></p>
            </div>
          </div>
          <pre class="code-panel log-panel"><%= @logs.logs %></pre>
        </section>
      <% end %>
    </section>
    """
  end

  defp instance_overview(assigns) do
    ~H"""
    <section class="section-card">
      <div class="section-header">
        <div>
          <h2 class="section-title">实例总览</h2>
          <p class="section-copy">先确认每个实例是否可达、是否有运行压力，再执行创建、更新或 systemd 操作。</p>
        </div>
        <span :if={@instances_loading? && @instances_loaded?} class="state-badge state-badge-warning">刷新中</span>
      </div>

      <section :if={@instances_loading? && !@instances_loaded?} class="instance-panel instance-loading-panel" aria-busy="true">
        <p class="panel-label">正在加载</p>
        <div class="detail-stack">
          <span>正在读取已登记实例、systemd 状态和各实例状态快照。</span>
          <span class="muted">如果某个实例响应慢，只会标记该实例不可达，不会阻塞整个管理页。</span>
        </div>
      </section>

      <p :if={@instances_error && !@instances_loaded?} class="empty-state">
        实例总览加载失败；自动更新和创建实例入口仍可查看，建议先检查本机 systemd 或实例配置目录。
      </p>

      <p :if={@instances_loaded? && @instances == []} class="empty-state">未发现已登记的 Symphony 实例。</p>

      <div :if={@instances_loaded? && @instances != []} class="instance-card-grid">
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
                  <span class="muted">端口 <%= Map.get(instance, :port) || "未知" %></span>
                  <span class="muted"><%= instance.dashboard_url || "未配置端口" %></span>
                </div>
              </section>

              <section class="instance-panel path-panel">
                <p class="panel-label">Config / Runtime</p>
                <div class="detail-stack mono">
                  <span><%= instance.config_path || "workflow 未知" %></span>
                  <span class="muted"><%= Map.get(instance, :tracker_config_path) || "tracker config 未知" %></span>
                  <span class="muted"><%= instance.env_path || "env 未知" %></span>
                  <span><%= instance.workspace_root || "workspace 未知" %></span>
                  <span class="muted"><%= instance.logs_root || "logs 未知" %></span>
                </div>
              </section>
            </div>
          </div>

          <footer class="instance-actions">
            <p :if={instance_lifecycle_notice(instance)} id={instance_action_note_id(instance)} class="lifecycle-action-note">
              <%= instance_lifecycle_notice(instance) %>
            </p>
            <button
              type="button"
              class="lifecycle-button lifecycle-button-primary"
              phx-click="lifecycle"
              phx-value-action="start"
              phx-value-name={instance.name}
              disabled={!instance_action_enabled?(@local_admin?, instance, "start")}
              aria-disabled={aria_disabled(instance_action_enabled?(@local_admin?, instance, "start"))}
              aria-describedby={instance_action_describedby(@local_admin?, instance, "start")}
              aria-label={instance_action_label("启动", instance)}
              title={instance_action_title(@local_admin?, instance, "start")}
              phx-confirm={"确认启动 #{instance.service}？此操作会改变用户 systemd 服务状态，并可能开始处理 Issue。"}
              phx-disable-with="启动中..."
            >启动</button>
            <button
              type="button"
              class="lifecycle-button lifecycle-button-danger"
              phx-click="lifecycle"
              phx-value-action="stop"
              phx-value-name={instance.name}
              disabled={!instance_action_enabled?(@local_admin?, instance, "stop")}
              aria-disabled={aria_disabled(instance_action_enabled?(@local_admin?, instance, "stop"))}
              aria-describedby={instance_action_describedby(@local_admin?, instance, "stop")}
              aria-label={instance_action_label("停止", instance)}
              title={instance_action_title(@local_admin?, instance, "stop")}
              phx-confirm={"确认停止 #{instance.service}？停止后该实例不会继续派发或处理 Issue。"}
              phx-disable-with="停止中..."
            >停止</button>
            <button
              type="button"
              class="lifecycle-button lifecycle-button-neutral"
              phx-click="lifecycle"
              phx-value-action="restart"
              phx-value-name={instance.name}
              disabled={!instance_action_enabled?(@local_admin?, instance, "restart")}
              aria-disabled={aria_disabled(instance_action_enabled?(@local_admin?, instance, "restart"))}
              aria-describedby={instance_action_describedby(@local_admin?, instance, "restart")}
              aria-label={instance_action_label("重启", instance)}
              title={instance_action_title(@local_admin?, instance, "restart")}
              phx-confirm={"确认重启 #{instance.service}？重启期间当前实例会短暂不可用。"}
              phx-disable-with="重启中..."
            >重启</button>
            <button
              type="button"
              class="lifecycle-button lifecycle-button-neutral"
              phx-click="lifecycle"
              phx-value-action="enable"
              phx-value-name={instance.name}
              disabled={!instance_action_enabled?(@local_admin?, instance, "enable")}
              aria-disabled={aria_disabled(instance_action_enabled?(@local_admin?, instance, "enable"))}
              aria-describedby={instance_action_describedby(@local_admin?, instance, "enable")}
              aria-label={instance_action_label("启用", instance)}
              title={instance_action_title(@local_admin?, instance, "enable")}
              phx-confirm={"确认启用 #{instance.service}？此操作会改变用户 systemd 开机/登录自启动状态。"}
              phx-disable-with="启用中..."
            >启用</button>
            <button
              type="button"
              class="lifecycle-button lifecycle-button-neutral"
              phx-click="lifecycle"
              phx-value-action="disable"
              phx-value-name={instance.name}
              disabled={!instance_action_enabled?(@local_admin?, instance, "disable")}
              aria-disabled={aria_disabled(instance_action_enabled?(@local_admin?, instance, "disable"))}
              aria-describedby={instance_action_describedby(@local_admin?, instance, "disable")}
              aria-label={instance_action_label("禁用", instance)}
              title={instance_action_title(@local_admin?, instance, "disable")}
              phx-confirm={"确认禁用 #{instance.service}？禁用后该实例不会随用户 systemd 自动启动。"}
              phx-disable-with="禁用中..."
            >禁用</button>
            <button
              type="button"
              class="lifecycle-button lifecycle-button-neutral"
              phx-click="logs"
              phx-value-name={instance.name}
              disabled={!instance_action_enabled?(@local_admin?, instance, "logs")}
              aria-disabled={aria_disabled(instance_action_enabled?(@local_admin?, instance, "logs"))}
              aria-describedby={instance_action_describedby(@local_admin?, instance, "logs")}
              aria-label={instance_action_label("读取最近日志", instance)}
              title={instance_action_title(@local_admin?, instance, "logs")}
              phx-disable-with="读取中..."
            >最近日志</button>
          </footer>
        </article>
      </div>
    </section>
    """
  end

  defp create_instance_panel(assigns) do
    ~H"""
    <section class="section-card">
      <div class="section-header">
        <div>
          <h2 class="section-title">新增实例</h2>
          <p class="section-copy">通过现有 systemd template 安装脚本生成配置、env、logs 和 workspaces。</p>
        </div>
        <div class="instance-actions form-actions">
          <button
            class="lifecycle-button lifecycle-button-primary"
            type="button"
            phx-click="toggle_create_form"
            phx-disable-with="切换中..."
            aria-expanded={if(@create_form_open?, do: "true", else: "false")}
            aria-controls="create-instance-form"
          ><%= if @create_form_open?, do: "收起表单", else: "新建实例" %></button>
          </div>
        </div>

      <form id="create-instance-form" phx-submit="create_instance" class="instance-form" hidden={!@create_form_open?} novalidate>
        <section :if={map_size(@create_errors) > 0} id="create-form-errors" class="notice-banner notice-banner-error form-error-summary" role="alert" aria-live="polite">
          <strong>新建实例表单需要修正</strong>
          <ul>
            <li :for={{field, label, message} <- create_error_items(@create_errors)}>
              <a href={"#create-field-#{field}"}><%= label %>：<%= message %></a>
            </li>
          </ul>
        </section>

        <div class="create-form-layout">
          <section class="form-section form-section-main">
            <div class="form-section-header">
              <div>
                <p class="form-section-kicker">Identity</p>
                <h3 class="form-section-title">项目与仓库</h3>
              </div>
              <span class="form-section-step">1</span>
            </div>

            <div class="form-grid">
              <label class="field field-prominent">
                <span>Project</span>
                <input id="create-field-project" name="instance[project]" value={@create_form["project"]} placeholder="project-a" required aria-invalid={field_invalid(@create_errors, "project")} aria-describedby={field_describedby(@create_errors, "project", ["create-field-project-hint"])} />
                <small id="create-field-project-hint" class="field-hint">生成实例名、配置目录和 systemd unit 后缀。</small>
                <span :if={field_error(@create_errors, "project")} id="create-field-project-error" class="field-error"><%= field_error(@create_errors, "project") %></span>
              </label>

              <label class="field">
                <span>Tracker</span>
                <select id="create-field-tracker_kind" name="instance[tracker_kind]">
                  <option value="github" selected={@create_form["tracker_kind"] == "github"}>GitHub</option>
                </select>
                <small class="field-hint">当前新增实例流程使用 GitHub Project。</small>
              </label>

              <label class="field">
                <span>Owner</span>
                <input id="create-field-owner" name="instance[owner]" value={@create_form["owner"]} placeholder="owner" required aria-invalid={field_invalid(@create_errors, "owner")} aria-describedby={field_describedby(@create_errors, "owner")} />
                <span :if={field_error(@create_errors, "owner")} id="create-field-owner-error" class="field-error"><%= field_error(@create_errors, "owner") %></span>
              </label>

              <label class="field">
                <span>Repo</span>
                <input id="create-field-repo" name="instance[repo]" value={@create_form["repo"]} placeholder="repo" required aria-invalid={field_invalid(@create_errors, "repo")} aria-describedby={field_describedby(@create_errors, "repo")} />
                <span :if={field_error(@create_errors, "repo")} id="create-field-repo-error" class="field-error"><%= field_error(@create_errors, "repo") %></span>
              </label>

              <label class="field">
                <span>Project Number</span>
                <input id="create-field-project_number" name="instance[project_number]" value={@create_form["project_number"]} inputmode="numeric" placeholder="14" required aria-invalid={field_invalid(@create_errors, "project_number")} aria-describedby={field_describedby(@create_errors, "project_number")} />
                <span :if={field_error(@create_errors, "project_number")} id="create-field-project_number-error" class="field-error"><%= field_error(@create_errors, "project_number") %></span>
              </label>

              <label class="field">
                <span>Port</span>
                <input id="create-field-port" name="instance[port]" value={@create_form["port"]} inputmode="numeric" placeholder="自动分配" aria-invalid={field_invalid(@create_errors, "port")} aria-describedby={field_describedby(@create_errors, "port", ["create-field-port-hint"])} />
                <small id="create-field-port-hint" class="field-hint">留空时由安装脚本分配可用端口。</small>
                <span :if={field_error(@create_errors, "port")} id="create-field-port-error" class="field-error"><%= field_error(@create_errors, "port") %></span>
              </label>
            </div>
          </section>

          <div class="form-side-stack">
            <section class="form-section">
              <div class="form-section-header">
                <div>
                  <p class="form-section-kicker">Runtime</p>
                  <h3 class="form-section-title">运行策略</h3>
                </div>
                <span class="form-section-step">2</span>
              </div>

              <div class="form-grid form-grid-single">
                <label class="field">
                  <span>更新策略</span>
                  <select id="create-field-update_strategy" name="instance[update_strategy]" aria-invalid={field_invalid(@create_errors, "update_strategy")} aria-describedby={field_describedby(@create_errors, "update_strategy", ["create-field-update_strategy-hint"])}>
                    <option :for={strategy <- update_strategies()} value={strategy} selected={@create_form["update_strategy"] == strategy}><%= strategy_label(strategy) %></option>
                  </select>
                  <small id="create-field-update_strategy-hint" class="field-hint field-warning">选择 force_restart 时会强制重启实例，仅适合明确需要抢修的场景。</small>
                  <span :if={field_error(@create_errors, "update_strategy")} id="create-field-update_strategy-error" class="field-error"><%= field_error(@create_errors, "update_strategy") %></span>
                </label>

                <label class="field">
                  <span>Max Agents</span>
                  <input id="create-field-max_agents" name="instance[max_agents]" value={@create_form["max_agents"]} inputmode="numeric" aria-invalid={field_invalid(@create_errors, "max_agents")} aria-describedby={field_describedby(@create_errors, "max_agents")} />
                  <span :if={field_error(@create_errors, "max_agents")} id="create-field-max_agents-error" class="field-error"><%= field_error(@create_errors, "max_agents") %></span>
                </label>
              </div>

              <div class="form-option-grid">
                <label class="form-option">
                  <input type="hidden" name="instance[start]" value="false" />
                  <input type="checkbox" name="instance[start]" value="true" checked={@create_form["start"] == "true"} />
                  <span>
                    <strong>立即启动</strong>
                    <small>创建完成后直接启动服务。</small>
                  </span>
                </label>
                <label class="form-option">
                  <input type="hidden" name="instance[auto_update]" value="false" />
                  <input type="checkbox" name="instance[auto_update]" value="true" checked={@create_form["auto_update"] == "true"} />
                  <span>
                    <strong>自动更新 timer</strong>
                    <small>启用 systemd 自动更新定时器。</small>
                  </span>
                </label>
              </div>
            </section>

            <section class="form-section">
              <div class="form-section-header">
                <div>
                  <p class="form-section-kicker">Auth</p>
                  <h3 class="form-section-title">访问令牌</h3>
                </div>
                <span class="form-section-step">3</span>
              </div>

              <div class="form-grid form-grid-single">
                <label class="field">
                  <span>Token</span>
                  <input id="create-field-token" name="instance[token]" type="password" value="" autocomplete="off" placeholder="留空则复用环境或已有 env" />
                  <small class="field-hint">提交后不会回显 token。</small>
                </label>

                <label class="field">
                  <span>Token Env</span>
                  <input id="create-field-token_env" name="instance[token_env]" value={@create_form["token_env"]} placeholder="GITHUB_TOKEN" aria-invalid={field_invalid(@create_errors, "token_env")} aria-describedby={field_describedby(@create_errors, "token_env", ["create-field-token_env-hint"])} />
                  <small id="create-field-token_env-hint" class="field-hint">可指定服务环境变量名。</small>
                  <span :if={field_error(@create_errors, "token_env")} id="create-field-token_env-error" class="field-error"><%= field_error(@create_errors, "token_env") %></span>
                </label>
              </div>
            </section>
          </div>
        </div>

        <div class="form-submit-strip">
          <div>
            <strong>创建后将写入实例配置并刷新总览</strong>
            <span>本机管理员可提交；远端访问仅能预览当前表单。</span>
          </div>
          <button
            class="lifecycle-button lifecycle-button-primary"
            type="submit"
            disabled={!@local_admin?}
            aria-disabled={aria_disabled(@local_admin?)}
            aria-describedby={admin_disabled_reason_id(@local_admin?)}
            aria-label="创建新的 Symphony 实例"
            title={admin_disabled_title(@local_admin?)}
            phx-confirm={create_instance_confirm(@create_form)}
            phx-disable-with="创建中..."
          >创建实例</button>
        </div>
      </form>
    </section>
    """
  end

  defp refresh_admin_state(socket, notice, auto_update \\ nil) do
    socket =
      socket
      |> assign(:notice, notice)
      |> assign(:instances_loading?, true)
      |> assign(:instances_error, nil)
      |> maybe_assign_auto_update(auto_update)

    if connected?(socket) do
      start_async(socket, :admin_state, fn -> admin_state_snapshot(auto_update) end)
    else
      socket
    end
  end

  defp admin_state_snapshot(auto_update) do
    %{
      instances: list_instances_with_timeout(),
      auto_update: auto_update || auto_update_snapshot(),
      update_timer: update_timer_snapshot()
    }
  end

  defp apply_admin_state(socket, %{instances: {:ok, instances}, auto_update: auto_update, update_timer: update_timer}) do
    socket
    |> assign(:instances, instances)
    |> assign(:instances_loading?, false)
    |> assign(:instances_loaded?, true)
    |> assign(:instances_error, nil)
    |> assign(:auto_update, auto_update)
    |> assign(:update_timer, update_timer)
  end

  defp apply_admin_state(socket, %{instances: {:error, reason}, auto_update: auto_update, update_timer: update_timer}) do
    socket
    |> assign(:auto_update, auto_update)
    |> assign(:update_timer, update_timer)
    |> assign_instances_error("实例总览加载失败：#{format_registry_error(reason)}")
  end

  defp assign_instances_error(socket, message) do
    socket
    |> assign(:instances_loading?, false)
    |> assign(:instances_error, message)
  end

  defp maybe_assign_auto_update(socket, nil), do: socket
  defp maybe_assign_auto_update(socket, auto_update), do: assign(socket, :auto_update, auto_update)

  defp list_instances_with_timeout do
    timeout_ms = admin_instances_timeout_ms()
    task = Task.async(fn -> registry().list_instances(registry_opts()) end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:instance_registry_exit, reason}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:instance_registry_timeout, timeout_ms}}
    end
  end

  defp admin_instances_timeout_ms do
    case Endpoint.config(:admin_instances_timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> timeout_ms
      _timeout_ms -> @admin_instances_timeout_ms
    end
  end

  defp format_registry_error({:instance_registry_timeout, timeout_ms}), do: "超过 #{timeout_ms}ms 未返回"
  defp format_registry_error({:instance_registry_exit, reason}), do: inspect(reason)
  defp format_registry_error(reason), do: inspect(reason)

  defp auto_update_loading_snapshot do
    %{
      repo: "unknown",
      branch: "main",
      source_root: nil,
      poll_interval_ms: 0,
      current_sha: nil,
      remote_sha: nil,
      pending_update?: false,
      next_check_at: nil,
      last_check: %{status: "loading", checked_at: nil, etag: nil, error: nil, rate_limit: %{}},
      last_update: %{
        status: "idle",
        started_at: nil,
        finished_at: nil,
        from_sha: nil,
        to_sha: nil,
        error: nil,
        instance_results: []
      }
    }
  end

  defp update_timer_loading_snapshot do
    %{
      timer: "symphony-update.timer",
      service: "symphony-update.service",
      active: "loading",
      sub: "loading",
      enabled: "loading",
      next_run: nil,
      last_trigger: nil,
      service_active: "loading",
      service_sub: "loading"
    }
  end

  defp run_action("start", name), do: registry().start_instance(name, registry_opts())
  defp run_action("stop", name), do: registry().stop_instance(name, registry_opts())
  defp run_action("restart", name), do: registry().restart_instance(name, registry_opts())
  defp run_action("enable", name), do: registry().enable_instance(name, registry_opts())
  defp run_action("disable", name), do: registry().disable_instance(name, registry_opts())
  defp run_action(action, _name), do: {:error, %{message: "Unsupported lifecycle action: #{action}"}}

  defp run_auto_update_action("check"), do: auto_update_module().check_now(auto_update_opts())
  defp run_auto_update_action("update"), do: auto_update_module().update_now(auto_update_opts())
  defp run_auto_update_action(_action), do: {:error, %{last_check: %{error: "Unsupported auto update action"}}}

  defp safe_auto_update_action(action) do
    run_auto_update_action(action)
  rescue
    error ->
      {:error, auto_update_unavailable_snapshot(error)}
  catch
    :exit, reason ->
      {:error, auto_update_unavailable_snapshot(reason)}
  end

  defp run_update_timer_action("enable"), do: registry().enable_update_timer(registry_opts())
  defp run_update_timer_action("disable"), do: registry().disable_update_timer(registry_opts())
  defp run_update_timer_action("trigger"), do: registry().trigger_update_service(registry_opts())
  defp run_update_timer_action(action), do: {:error, %{message: "Unsupported update timer action: #{action}"}}

  defp action_message({:ok, %{service: service}}, action), do: "已请求 #{action} #{service}"
  defp action_message({:error, %{message: message}}, _action), do: message

  defp guarded(%{assigns: %{local_admin?: true}}, fun), do: fun.()
  defp guarded(_socket, _fun), do: "管理操作只允许本机客户端访问"

  defp guarded_create(%{assigns: %{local_admin?: true}}, _params, fun), do: fun.()
  defp guarded_create(_socket, params, _fun), do: {"管理操作只允许本机客户端访问", normalize_form(params), true, %{}, true}

  defp guarded_logs(%{assigns: %{local_admin?: true}}, fun), do: fun.()
  defp guarded_logs(_socket, _fun), do: {"管理操作只允许本机客户端访问", nil}

  defp guarded_auto_update(%{assigns: %{local_admin?: true}}, fun), do: fun.()
  defp guarded_auto_update(_socket, _fun), do: {"管理操作只允许本机客户端访问", auto_update_snapshot()}

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
      auto_update_unavailable_snapshot(error)
  catch
    :exit, reason ->
      auto_update_unavailable_snapshot(reason)
  end

  defp auto_update_unavailable_snapshot(reason) do
    %{
      repo: "unknown",
      branch: "main",
      source_root: nil,
      poll_interval_ms: 0,
      current_sha: nil,
      remote_sha: nil,
      pending_update?: false,
      next_check_at: nil,
      last_check: %{status: "unavailable", error: auto_update_unavailable_error(reason), rate_limit: %{}, etag: nil},
      last_update: %{status: "idle", instance_results: []}
    }
  end

  defp auto_update_unavailable_error(_reason), do: "当前 Hub 模式未启用自动更新进程，更新检查不可用。"

  defp auto_update_module do
    Endpoint.config(:auto_update) || SymphonyElixir.AutoUpdate
  end

  defp auto_update_opts do
    Endpoint.config(:auto_update_opts) || []
  end

  defp update_timer_snapshot do
    registry().update_timer_status(registry_opts())
  rescue
    error ->
      %{
        timer: "symphony-update.timer",
        service: "symphony-update.service",
        active: "unknown",
        sub: nil,
        enabled: "unknown",
        next_run: nil,
        last_trigger: nil,
        service_active: "unknown",
        service_sub: Exception.message(error)
      }
  end

  defp default_create_form do
    %{
      "project" => "",
      "tracker_kind" => "github",
      "owner" => "",
      "repo" => "",
      "project_number" => "",
      "port" => "",
      "token_env" => "",
      "update_strategy" => "idle_restart",
      "max_agents" => "2",
      "start" => "true",
      "auto_update" => "false"
    }
  end

  defp normalize_form(params) do
    Map.merge(default_create_form(), Map.new(params, fn {key, value} -> {to_string(key), to_string(value)} end))
  end

  defp create_form_errors(form) do
    %{}
    |> validate_safe_text_field(form, "project", "Project 必填，只能包含字母、数字、点、下划线和连字符。")
    |> validate_safe_text_field(form, "owner", "Owner 必填，只能包含字母、数字、点、下划线和连字符。")
    |> validate_safe_text_field(form, "repo", "Repo 必填，只能包含字母、数字、点、下划线和连字符。")
    |> validate_positive_integer_field(form, "project_number", "Project Number 必须是正整数。")
    |> validate_optional_port_field(form)
    |> validate_update_strategy_field(form)
    |> validate_positive_integer_field(form, "max_agents", "Max Agents 必须是正整数。")
    |> validate_optional_env_field(form)
  end

  defp validate_safe_text_field(errors, form, field, message) do
    value = Map.get(form, field, "")

    if Regex.match?(@create_safe_name_pattern, value) do
      errors
    else
      Map.put(errors, field, message)
    end
  end

  defp validate_positive_integer_field(errors, form, field, message) do
    case Integer.parse(Map.get(form, field, "")) do
      {integer, ""} when integer > 0 -> errors
      _invalid -> Map.put(errors, field, message)
    end
  end

  defp validate_optional_port_field(errors, form) do
    case Map.get(form, "port", "") do
      "" ->
        errors

      value ->
        case Integer.parse(value) do
          {port, ""} when port in 1..@max_port -> errors
          _invalid -> Map.put(errors, "port", "Port 必须留空或填写 1 到 #{@max_port} 之间的整数。")
        end
    end
  end

  defp validate_update_strategy_field(errors, form) do
    if Map.get(form, "update_strategy") in @update_strategies do
      errors
    else
      Map.put(errors, "update_strategy", "更新策略必须来自页面提供的选项。")
    end
  end

  defp validate_optional_env_field(errors, form) do
    case Map.get(form, "token_env", "") do
      "" ->
        errors

      value ->
        if Regex.match?(@create_env_var_pattern, value) do
          errors
        else
          Map.put(errors, "token_env", "Token Env 必须是合法环境变量名，例如 GITHUB_TOKEN。")
        end
    end
  end

  defp create_errors_from_registry_error(%{code: code, message: message}) do
    case code do
      "invalid_instance_name" -> %{"project" => message}
      "instance_exists" -> %{"project" => message}
      "invalid_owner" -> %{"owner" => message}
      "invalid_repo" -> %{"repo" => message}
      "invalid_project_number" -> %{"project_number" => message}
      "invalid_port" -> %{"port" => message}
      "port_in_use" -> %{"port" => message}
      "port_unavailable" -> %{"port" => message}
      "invalid_update_strategy" -> %{"update_strategy" => message}
      "invalid_max_agents" -> %{"max_agents" => message}
      "invalid_token_env" -> %{"token_env" => message}
      "missing_token_env" -> %{"token_env" => message}
      _other -> %{}
    end
  end

  defp create_errors_from_registry_error(_error), do: %{}

  defp create_error_items(errors) do
    errors
    |> Enum.map(fn {field, message} -> {field, Map.get(@create_field_labels, field, field), message} end)
    |> Enum.sort_by(fn {field, _label, _message} -> field_order(field) end)
  end

  defp field_order("project"), do: 0
  defp field_order("owner"), do: 1
  defp field_order("repo"), do: 2
  defp field_order("project_number"), do: 3
  defp field_order("port"), do: 4
  defp field_order("update_strategy"), do: 5
  defp field_order("max_agents"), do: 6
  defp field_order("token_env"), do: 7
  defp field_order(_field), do: 99

  defp field_error(errors, field), do: Map.get(errors, field)

  defp field_invalid(errors, field) do
    if field_error(errors, field), do: "true", else: "false"
  end

  defp field_describedby(errors, field, base_ids \\ []) do
    ids =
      if field_error(errors, field) do
        base_ids ++ ["create-field-#{field}-error"]
      else
        base_ids
      end

    case Enum.reject(ids, &(&1 in [nil, ""])) do
      [] -> nil
      describedby -> Enum.join(describedby, " ")
    end
  end

  defp update_strategies, do: @update_strategies

  defp strategy_label("force_restart"), do: "force_restart - 强制重启（危险）"
  defp strategy_label(strategy), do: strategy

  defp notice_class(notice), do: "notice-banner notice-banner-#{notice_kind(notice)}"

  defp notice_role(notice) do
    case notice_kind(notice) do
      :error -> "alert"
      _kind -> "status"
    end
  end

  defp notice_title(notice) do
    case notice_kind(notice) do
      :success -> "操作已受理"
      :error -> "操作未完成"
      :warning -> "需要注意"
    end
  end

  defp notice_kind(notice) when is_binary(notice) do
    cond do
      String.contains?(notice, ["失败", "只允许", "Unsupported", "unavailable", "Failed"]) -> :error
      String.contains?(notice, ["已", "完成", "created", "updated"]) -> :success
      true -> :warning
    end
  end

  defp notice_kind(_notice), do: :warning

  defp local_admin_session?(ip) when ip in ["127.0.0.1", "::1", "::ffff:127.0.0.1"], do: true
  defp local_admin_session?(_ip), do: false

  defp auto_update_status("check", snapshot), do: get_in(snapshot, [:last_check, :status]) || "unknown"
  defp auto_update_status("update", snapshot), do: get_in(snapshot, [:last_update, :status]) || "unknown"
  defp auto_update_status(_action, snapshot), do: get_in(snapshot, [:last_update, :status]) || get_in(snapshot, [:last_check, :status]) || "unknown"

  defp total_count(instances, key) do
    Enum.reduce(instances, 0, fn instance, total -> total + count(instance, key) end)
  end

  defp unavailable_instance_count(instances) do
    Enum.count(instances, fn instance ->
      health_status = get_in(instance, [:health, :status])
      instance_status = Map.get(instance, :status) || Map.get(instance, "status")

      health_status != "reachable" or instance_status in [nil, "unknown"]
    end)
  end

  defp count(instance, key) do
    counts = Map.get(instance, :counts, %{})
    Map.get(counts, key, Map.get(counts, to_string(key), 0))
  end

  defp instance_badge_class("running"), do: "state-badge state-badge-active"
  defp instance_badge_class("failed"), do: "state-badge state-badge-blocked"
  defp instance_badge_class("stopped"), do: "state-badge state-badge-terminal"
  defp instance_badge_class(_status), do: "state-badge state-badge-muted"

  defp instance_action_label(action, instance) do
    service = Map.get(instance, :service) || Map.get(instance, "service") || Map.get(instance, :name) || Map.get(instance, "name")
    "#{action} #{service}"
  end

  defp instance_action_enabled?(false, _instance, _action), do: false

  defp instance_action_enabled?(true, instance, action) do
    is_nil(instance_action_disabled_reason(instance, action))
  end

  defp instance_action_describedby(false, _instance, _action), do: "admin-readonly-reason"

  defp instance_action_describedby(true, instance, action) do
    if instance_action_disabled_reason(instance, action), do: instance_action_note_id(instance), else: nil
  end

  defp instance_action_title(false, _instance, _action), do: "管理操作只允许本机客户端访问"
  defp instance_action_title(true, instance, action), do: instance_action_disabled_reason(instance, action)

  defp instance_action_disabled_reason(instance, action) do
    cond do
      systemd_not_found?(instance) ->
        "systemd unit 未安装或 template 已归档，需先恢复服务单元后再执行实例操作。"

      action == "start" and instance_running?(instance) ->
        "实例已在运行，无需再次启动。"

      action == "stop" and not instance_running?(instance) ->
        "实例当前未运行，无需停止。"

      action == "enable" and systemd_enabled?(instance) ->
        "systemd unit 已启用。"

      action == "disable" and systemd_disabled?(instance) ->
        "systemd unit 已禁用。"

      true ->
        nil
    end
  end

  defp instance_lifecycle_notice(instance) do
    if systemd_not_found?(instance), do: instance_action_disabled_reason(instance, "start"), else: nil
  end

  defp instance_action_note_id(instance) do
    "instance-actions-note-#{Map.get(instance, :name) || Map.get(instance, "name") || "unknown"}"
  end

  defp instance_running?(instance) do
    status = Map.get(instance, :status) || Map.get(instance, "status")
    active = get_in(instance, [:systemd, :active]) || get_in(instance, ["systemd", "active"])
    sub = get_in(instance, [:systemd, :sub]) || get_in(instance, ["systemd", "sub"])

    status == "running" or active == "active" or sub == "running"
  end

  defp systemd_not_found?(instance) do
    enabled = get_in(instance, [:systemd, :enabled]) || get_in(instance, ["systemd", "enabled"])
    active = get_in(instance, [:systemd, :active]) || get_in(instance, ["systemd", "active"])

    enabled == "not-found" or active == "not-found"
  end

  defp systemd_enabled?(instance) do
    enabled = get_in(instance, [:systemd, :enabled]) || get_in(instance, ["systemd", "enabled"])
    enabled == "enabled"
  end

  defp systemd_disabled?(instance) do
    enabled = get_in(instance, [:systemd, :enabled]) || get_in(instance, ["systemd", "enabled"])
    enabled in ["disabled", "masked"]
  end

  defp auto_update_action_enabled?(false, _snapshot, _action), do: false

  defp auto_update_action_enabled?(true, snapshot, action) do
    is_nil(auto_update_action_disabled_reason(snapshot, action))
  end

  defp auto_update_action_describedby(false, _snapshot, _action), do: "admin-readonly-reason"

  defp auto_update_action_describedby(true, snapshot, action) do
    if auto_update_action_disabled_reason(snapshot, action), do: "auto-update-action-note", else: nil
  end

  defp auto_update_action_title(false, _snapshot, _action), do: "管理操作只允许本机客户端访问"
  defp auto_update_action_title(true, snapshot, action), do: auto_update_action_disabled_reason(snapshot, action)

  defp auto_update_action_notice(false, _snapshot), do: "管理操作只允许本机客户端访问。"

  defp auto_update_action_notice(true, snapshot) do
    auto_update_action_disabled_reason(snapshot, "update")
  end

  defp auto_update_action_disabled_reason(snapshot, action) do
    case {auto_update_state(snapshot), action} do
      {:loading, _action} -> "自动更新状态仍在加载。"
      {:unavailable, _action} -> "自动更新进程不可用，需先恢复自动更新服务。"
      {:up_to_date, "update"} -> "GitHub main 当前没有可执行更新。"
      {_state, _action} -> nil
    end
  end

  defp aria_disabled(true), do: "false"
  defp aria_disabled(false), do: "true"

  defp admin_disabled_reason_id(true), do: nil
  defp admin_disabled_reason_id(false), do: "admin-readonly-reason"

  defp admin_disabled_title(true), do: nil
  defp admin_disabled_title(false), do: "管理操作只允许本机客户端访问"

  defp strategy_description("idle_restart"), do: "空闲时自动更新并重启"
  defp strategy_description("defer_until_idle"), do: "运行中延后，空闲后重启"
  defp strategy_description("download_only"), do: "只下载构建，不自动重启"
  defp strategy_description("manual_restart"), do: "手动确认后重启"
  defp strategy_description("force_restart"), do: "强制重启（危险操作）"
  defp strategy_description(_strategy), do: "使用默认空闲重启策略"

  defp create_instance_confirm(_form) do
    "确认创建实例？此操作会写入实例配置；如果勾选了立即启动或自动更新 timer，还会改变用户 systemd 服务或自动化定时器状态。"
  end

  defp auto_update_state(snapshot) do
    last_check = Map.get(snapshot, :last_check, %{})
    status = Map.get(last_check, :status) || Map.get(last_check, "status")
    error = Map.get(last_check, :error) || Map.get(last_check, "error")

    cond do
      status == "loading" ->
        :loading

      status in ["unavailable", "unknown"] or error not in [nil, ""] ->
        :unavailable

      Map.get(snapshot, :pending_update?, false) ->
        :pending

      status in ["ok", "not_modified", "up_to_date"] ->
        :up_to_date

      true ->
        :unavailable
    end
  end

  defp update_state_text(snapshot) do
    case auto_update_state(snapshot) do
      :loading -> "正在加载"
      :pending -> "有可用更新"
      :up_to_date -> "已是最新"
      :unavailable -> "无法判断/不可用"
    end
  end

  defp update_badge_class(snapshot) do
    case auto_update_state(snapshot) do
      :loading -> "state-badge state-badge-muted"
      :pending -> "state-badge state-badge-blocked"
      :up_to_date -> "state-badge state-badge-active"
      :unavailable -> "state-badge state-badge-warning"
    end
  end

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(nil), do: "未知"
  defp format_datetime(datetime), do: to_string(datetime)

  defp auto_update_error(snapshot) when is_map(snapshot) do
    get_in(snapshot, [:last_update, :error]) || get_in(snapshot, [:last_check, :error]) || "unknown error"
  end
end
