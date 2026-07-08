defmodule SymphonyElixirWeb.AdminInstancesLive do
  @moduledoc """
  Operator dashboard for independently deployed Symphony instances.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.Endpoint

  @impl true
  def mount(_params, session, socket) do
    local_admin? = local_admin_session?(Map.get(session, "admin_client_ip") || Map.get(session, :admin_client_ip))

    socket =
      socket
      |> assign(:active_nav, :instances)
      |> assign(:access_role, if(local_admin?, do: "本机管理员", else: "远程只读"))
      |> assign(:local_admin?, local_admin?)
      |> assign(:create_form, default_create_form())
      |> assign(:create_form_open?, false)
      |> assign(:logs, nil)

    {:ok, assign_admin_state(socket, nil)}
  end

  @impl true
  def handle_event("lifecycle", %{"action" => action, "name" => name}, socket) do
    message = guarded(socket, fn -> action_message(run_action(action, name), action) end)

    {:noreply, assign_admin_state(socket, message)}
  end

  def handle_event("toggle_create_form", _params, socket) do
    {:noreply, assign(socket, :create_form_open?, !socket.assigns.create_form_open?)}
  end

  def handle_event("create_instance", %{"instance" => params}, socket) do
    {message, form, create_form_open?} =
      guarded_create(socket, params, fn ->
        case registry().create_instance(params, registry_opts()) do
          {:ok, %{instance: instance}} -> {"已创建实例 #{instance.name}", default_create_form(), false}
          {:error, %{message: message}} -> {message, normalize_form(params), true}
        end
      end)

    socket =
      socket
      |> assign(:create_form, form)
      |> assign(:create_form_open?, create_form_open?)
      |> assign_admin_state(message)

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
      |> assign_admin_state(message)

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

    {:noreply, assign_admin_state(socket, message, auto_update)}
  end

  def handle_event("update_timer", %{"action" => action}, socket) do
    message = guarded(socket, fn -> action_message(run_update_timer_action(action), action) end)

    {:noreply, assign_admin_state(socket, message)}
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
        <section class="error-card">
          <h2 class="error-title">管理操作已限制</h2>
          <p class="error-copy">实例创建、systemd 操作和日志读取只允许本机客户端访问。</p>
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

        <form id="create-instance-form" phx-submit="create_instance" class="instance-form" hidden={!@create_form_open?}>
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
                  <input name="instance[project]" value={@create_form["project"]} placeholder="project-a" required />
                  <small class="field-hint">生成实例名、配置目录和 systemd unit 后缀。</small>
                </label>

                <label class="field">
                  <span>Tracker</span>
                  <select name="instance[tracker_kind]">
                    <option value="github" selected={@create_form["tracker_kind"] == "github"}>GitHub</option>
                  </select>
                  <small class="field-hint">当前新增实例流程使用 GitHub Project。</small>
                </label>

                <label class="field">
                  <span>Owner</span>
                  <input name="instance[owner]" value={@create_form["owner"]} placeholder="owner" required />
                </label>

                <label class="field">
                  <span>Repo</span>
                  <input name="instance[repo]" value={@create_form["repo"]} placeholder="repo" required />
                </label>

                <label class="field">
                  <span>Project Number</span>
                  <input name="instance[project_number]" value={@create_form["project_number"]} inputmode="numeric" placeholder="14" required />
                </label>

                <label class="field">
                  <span>Port</span>
                  <input name="instance[port]" value={@create_form["port"]} inputmode="numeric" placeholder="自动分配" />
                  <small class="field-hint">留空时由安装脚本分配可用端口。</small>
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
                    <select name="instance[update_strategy]">
                      <option :for={strategy <- update_strategies()} value={strategy} selected={@create_form["update_strategy"] == strategy}><%= strategy_label(strategy) %></option>
                    </select>
                    <small class="field-hint field-warning">选择 force_restart 时会强制重启实例，仅适合明确需要抢修的场景。</small>
                  </label>

                  <label class="field">
                    <span>Max Agents</span>
                    <input name="instance[max_agents]" value={@create_form["max_agents"]} inputmode="numeric" />
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
                    <input name="instance[token]" type="password" value="" autocomplete="off" placeholder="留空则复用环境或已有 env" />
                    <small class="field-hint">提交后不会回显 token。</small>
                  </label>

                  <label class="field">
                    <span>Token Env</span>
                    <input name="instance[token_env]" value={@create_form["token_env"]} placeholder="GITHUB_TOKEN" />
                    <small class="field-hint">可指定服务环境变量名。</small>
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
              phx-confirm={create_instance_confirm(@create_form)}
              phx-disable-with="创建中..."
            >创建实例</button>
          </div>
        </form>
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
              type="button"
              class="lifecycle-button lifecycle-button-neutral"
              phx-click="auto_update"
              phx-value-action="check"
              disabled={!@local_admin?}
              phx-disable-with="检查中..."
            >立即检查</button>
            <button
              type="button"
              class="lifecycle-button lifecycle-button-primary"
              phx-click="auto_update"
              phx-value-action="update"
              disabled={!@local_admin?}
              phx-confirm="确认执行 GitHub main 更新？此操作会按各实例更新策略执行，部分实例可能被重启。"
              phx-disable-with="更新中..."
            >执行更新</button>
          </div>
        </div>

        <%= if auto_update_state(@auto_update) == :unavailable do %>
          <section class="instance-panel">
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

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">systemd 自动更新 timer</h2>
            <p class="section-copy">查看和管理 `symphony-update.timer` 与 `symphony-update.service`。</p>
          </div>
          <div class="instance-actions">
            <button type="button" class="lifecycle-button lifecycle-button-primary" phx-click="update_timer" phx-value-action="enable" disabled={!@local_admin?} phx-confirm="确认启用并立即启动 symphony-update.timer？此操作会改变用户 systemd 自动更新定时器状态，之后会按计划检查 GitHub main 更新。" phx-disable-with="启用中...">启用</button>
            <button type="button" class="lifecycle-button lifecycle-button-danger" phx-click="update_timer" phx-value-action="disable" disabled={!@local_admin?} phx-confirm="确认禁用 symphony-update.timer？禁用后不会自动检查 GitHub main 更新。" phx-disable-with="禁用中...">禁用</button>
            <button type="button" class="lifecycle-button lifecycle-button-neutral" phx-click="update_timer" phx-value-action="trigger" disabled={!@local_admin?} phx-confirm="确认手动触发 symphony-update.service？" phx-disable-with="触发中...">手动触发</button>
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
                <button
                  type="button"
                  class="lifecycle-button lifecycle-button-primary"
                  phx-click="lifecycle"
                  phx-value-action="start"
                  phx-value-name={instance.name}
                  disabled={!@local_admin?}
                  phx-confirm={"确认启动 #{instance.service}？此操作会改变用户 systemd 服务状态，并可能开始处理 Issue。"}
                  phx-disable-with="启动中..."
                >启动</button>
                <button
                  type="button"
                  class="lifecycle-button lifecycle-button-danger"
                  phx-click="lifecycle"
                  phx-value-action="stop"
                  phx-value-name={instance.name}
                  disabled={!@local_admin?}
                  phx-confirm={"确认停止 #{instance.service}？停止后该实例不会继续派发或处理 Issue。"}
                  phx-disable-with="停止中..."
                >停止</button>
                <button
                  type="button"
                  class="lifecycle-button lifecycle-button-neutral"
                  phx-click="lifecycle"
                  phx-value-action="restart"
                  phx-value-name={instance.name}
                  disabled={!@local_admin?}
                  phx-confirm={"确认重启 #{instance.service}？重启期间当前实例会短暂不可用。"}
                  phx-disable-with="重启中..."
                >重启</button>
                <button
                  type="button"
                  class="lifecycle-button lifecycle-button-neutral"
                  phx-click="lifecycle"
                  phx-value-action="enable"
                  phx-value-name={instance.name}
                  disabled={!@local_admin?}
                  phx-confirm={"确认启用 #{instance.service}？此操作会改变用户 systemd 开机/登录自启动状态。"}
                  phx-disable-with="启用中..."
                >启用</button>
                <button
                  type="button"
                  class="lifecycle-button lifecycle-button-neutral"
                  phx-click="lifecycle"
                  phx-value-action="disable"
                  phx-value-name={instance.name}
                  disabled={!@local_admin?}
                  phx-confirm={"确认禁用 #{instance.service}？禁用后该实例不会随用户 systemd 自动启动。"}
                  phx-disable-with="禁用中..."
                >禁用</button>
                <button
                  type="button"
                  class="lifecycle-button lifecycle-button-neutral"
                  phx-click="logs"
                  phx-value-name={instance.name}
                  disabled={!@local_admin?}
                  phx-disable-with="读取中..."
                >最近日志</button>
              </footer>
            </article>
          </div>
        <% end %>
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
    |> assign(:update_timer, update_timer_snapshot())
    |> assign(:notice, notice)
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
  defp guarded_create(_socket, params, _fun), do: {"管理操作只允许本机客户端访问", normalize_form(params), true}

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

  defp auto_update_unavailable_error(%{__exception__: true} = error), do: Exception.message(error)
  defp auto_update_unavailable_error(reason), do: "auto_update_unavailable: #{inspect(reason)}"

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

  defp update_strategies do
    ["idle_restart", "defer_until_idle", "download_only", "manual_restart", "force_restart"]
  end

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
      :pending -> "有可用更新"
      :up_to_date -> "已是最新"
      :unavailable -> "无法判断/不可用"
    end
  end

  defp update_badge_class(snapshot) do
    case auto_update_state(snapshot) do
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
