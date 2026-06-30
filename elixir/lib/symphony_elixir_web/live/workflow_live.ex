defmodule SymphonyElixirWeb.WorkflowLive do
  @moduledoc """
  Read-only workflow-stage configuration visualization for operators.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Orchestrator, TrackerConfig, Workflow}
  alias SymphonyElixir.Workflow.Definition
  alias SymphonyElixir.Workflow.Visualization
  alias SymphonyElixirWeb.Endpoint

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :projection, load_projection())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell workflow-dashboard">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Workflow 配置</p>
            <h1 class="hero-title">阶段流向图</h1>
            <p class="hero-copy">
              只读展示当前 WORKFLOW.md workflow-stage 定义、TRACKER.yaml 映射诊断和运行态 stage 分布。
            </p>
          </div>

          <div class="status-stack">
            <a class="status-badge" href="/">单实例 Dashboard</a>
            <a class="status-badge" href="/admin/instances">多实例管理</a>
          </div>
        </div>
      </header>

      <%= if @projection[:error] do %>
        <section class="error-card">
          <h2 class="error-title">Workflow 配置不可用</h2>
          <p class="error-copy">
            <strong><%= @projection.error.code %>:</strong> <%= @projection.error.message %>
          </p>
        </section>

        <.diagnostics_panel diagnostics={@projection.diagnostics} />
      <% else %>
        <section class="metric-grid workflow-summary-grid">
          <article class="metric-card">
            <p class="metric-label">Start Stage</p>
            <p class="metric-value metric-value-stage mono"><%= @projection.workflow.start_stage %></p>
            <p class="metric-detail">新 issue 从该 workflow stage 开始。</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Stages</p>
            <p class="metric-value numeric"><%= @projection.workflow.stage_count %></p>
            <p class="metric-detail">包含 <%= @projection.workflow.transition_count %> 条普通 transition。</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Terminal</p>
            <p class="metric-value numeric"><%= length(@projection.workflow.terminal_stages) %></p>
            <p class="metric-detail mono"><%= Enum.join(@projection.workflow.terminal_stages, ", ") %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Snapshot</p>
            <p class="metric-value metric-value-stage"><%= if @projection.runtime.available?, do: "可用", else: "不可用" %></p>
            <p class="metric-detail">
              <%= if @projection.runtime.available?, do: "已叠加运行态 stage 分布。", else: @projection.runtime.error.message %>
            </p>
          </article>
        </section>

        <.diagnostics_panel diagnostics={@projection.diagnostics} />

        <section class="workflow-layout">
          <article class="section-card workflow-graph-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Stage Graph</h2>
                <p class="section-copy">节点是 workflow stage，箭头是 outcome -> target stage。</p>
              </div>
            </div>

            <div class="workflow-graph" aria-label="Workflow stage graph">
              <div class="workflow-node-grid">
                <article :for={stage <- @projection.stages} class={stage_node_class(stage)} id={"stage-#{stage.id}"}>
                  <div class="workflow-node-header">
                    <div class="workflow-node-title">
                      <span class="mono"><%= stage.id %></span>
                    </div>
                    <div class="workflow-node-badges">
                      <span :if={stage.start?} class="state-badge state-badge-active">start</span>
                      <span :if={stage.terminal?} class="state-badge state-badge-terminal">terminal</span>
                      <span :if={stage.blocked? and not stage.protocol_blocked?} class="state-badge state-badge-danger">blocked</span>
                      <span :if={stage.protocol_blocked?} class="state-badge state-badge-danger">protocol</span>
                    </div>
                  </div>

                  <p class="workflow-node-prompt"><%= stage.prompt_preview %></p>

                  <div class="runtime-strip">
                    <span>run <strong class="numeric"><%= stage.runtime.running %></strong></span>
                    <span>retry <strong class="numeric"><%= stage.runtime.retrying %></strong></span>
                    <span>blocked <strong class="numeric"><%= stage.runtime.blocked %></strong></span>
                  </div>

                  <div class="workflow-edge-list">
                    <div :for={transition <- stage.transitions} class={transition_class(transition)}>
                      <span class="workflow-edge-outcome mono"><%= transition.outcome %></span>
                      <span class="workflow-edge-arrow">→</span>
                      <a href={"#stage-#{transition.to}"} class="workflow-edge-target mono"><%= transition.to %></a>
                    </div>
                    <p :if={stage.transitions == []} class="muted workflow-empty-edge">无普通 transition</p>
                  </div>
                </article>
              </div>
            </div>
          </article>

          <aside class="workflow-side-stack">
            <section class="section-card">
              <div class="section-header">
                <div>
                  <h2 class="section-title">Missing Outcome</h2>
                  <p class="section-copy">该路径由协议缺失或无效 outcome 触发，不属于普通业务 transition。</p>
                </div>
              </div>
              <div class={missing_outcome_class(@projection.missing_outcome)}>
                <span class="mono">max_retries=<%= @projection.missing_outcome.max_retries %></span>
                <span class="workflow-edge-arrow">→</span>
                <a href={"#stage-#{@projection.missing_outcome.on_exhausted}"} class="mono">
                  <%= @projection.missing_outcome.on_exhausted %>
                </a>
              </div>
            </section>

            <section class="section-card">
              <div class="section-header">
                <div>
                  <h2 class="section-title">Tracker 映射</h2>
                  <p class="section-copy">以 provider-neutral stage 为主，provider state 仅作外部可见状态摘要。</p>
                </div>
              </div>

              <%= if @projection.tracker do %>
                <div class="tracker-summary">
                  <span class="state-badge"><%= @projection.tracker.kind || "unknown" %></span>
                  <span class="state-badge state-badge-muted"><%= @projection.tracker.strategy %></span>
                  <span class={coverage_badge_class(@projection.tracker.coverage)}>
                    <%= @projection.tracker.coverage.mapped %>/<%= @projection.tracker.coverage.total %>
                  </span>
                </div>

                <div class="table-wrap">
                  <table class="data-table workflow-mapping-table">
                    <thead>
                      <tr>
                        <th>Stage</th>
                        <th>Provider State</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={mapping <- @projection.tracker.mappings}>
                        <td class="mono"><%= mapping.stage %></td>
                        <td>
                          <span class={if mapping.mapped?, do: "state-badge", else: "state-badge state-badge-warning"}>
                            <%= mapping.provider_state || "未映射" %>
                          </span>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>

                <pre :if={map_size(@projection.tracker.provider_hint) > 0} class="code-panel tracker-hint"><%= pretty_value(@projection.tracker.provider_hint) %></pre>
              <% else %>
                <p class="empty-state">TRACKER.yaml 不可用，无法展示 stage-state 映射。</p>
              <% end %>
            </section>
          </aside>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Stage 详情</h2>
              <p class="section-copy">每个 stage 的 prompt 预览、outcome 列表、tracker state 和运行态分布。</p>
            </div>
          </div>

          <div class="stage-detail-grid">
            <article :for={stage <- @projection.stages} class="stage-detail-card">
              <div class="stage-detail-header">
                <h3 class="stage-detail-title mono"><%= stage.id %></h3>
                <div class="workflow-node-badges">
                  <span :if={stage.start?} class="state-badge state-badge-active">start</span>
                  <span :if={stage.terminal?} class="state-badge state-badge-terminal">terminal</span>
                  <span :if={!stage.reachable?} class="state-badge state-badge-warning">unreachable</span>
                </div>
              </div>

              <pre class="prompt-preview"><%= stage.prompt %></pre>

              <div class="stage-detail-meta">
                <span>running <strong class="numeric"><%= stage.runtime.running %></strong></span>
                <span>retrying <strong class="numeric"><%= stage.runtime.retrying %></strong></span>
                <span>blocked <strong class="numeric"><%= stage.runtime.blocked %></strong></span>
              </div>

              <p class="section-copy">
                Tracker:
                <%= if stage.tracker_state && stage.tracker_state.provider_state do %>
                  <span class="mono"><%= stage.tracker_state.provider_state %></span>
                <% else %>
                  <span class="muted">未映射</span>
                <% end %>
              </p>

              <div class="transition-detail-list">
                <div :for={transition <- stage.transitions} class="transition-detail-row">
                  <span class="mono"><%= transition.outcome %></span>
                  <span>→</span>
                  <span class="mono"><%= transition.to %></span>
                  <span class={if transition.known_outcome?, do: "state-badge state-badge-muted", else: "state-badge state-badge-warning"}>
                    <%= if transition.known_outcome?, do: "known outcome", else: "unknown outcome" %>
                  </span>
                </div>
                <p :if={stage.transitions == []} class="empty-state">无 outcome transition。</p>
              </div>
            </article>
          </div>
        </section>
      <% end %>
    </section>
    """
  end

  attr(:diagnostics, :list, required: true)

  defp diagnostics_panel(assigns) do
    ~H"""
    <section class="section-card">
      <div class="section-header">
        <div>
          <h2 class="section-title">配置诊断</h2>
          <p class="section-copy">schema、semantic、可达性和 tracker 映射检查结果。</p>
        </div>
      </div>

      <div class="diagnostic-list">
        <article :for={diagnostic <- @diagnostics} class={diagnostic_class(diagnostic)}>
          <span class="state-badge"><%= diagnostic.severity %></span>
          <div>
            <strong class="mono"><%= diagnostic.code %></strong>
            <p><%= diagnostic.message %></p>
          </div>
        </article>
      </div>
    </section>
    """
  end

  defp load_projection do
    case Workflow.load(Workflow.workflow_file_path()) do
      {:ok, %{workflow: %Definition{} = definition}} ->
        Visualization.project(definition,
          tracker_config: load_tracker_config(),
          snapshot: Orchestrator.snapshot(orchestrator(), snapshot_timeout_ms())
        )

      {:ok, %{workflow: nil}} ->
        Visualization.error_projection({:invalid_workflow_definition, "WORKFLOW.md must define provider-neutral workflow stages"})

      {:error, reason} ->
        Visualization.error_projection(reason)
    end
  end

  defp load_tracker_config do
    workflow_path = Workflow.workflow_file_path()

    tracker_path =
      case TrackerConfig.tracker_file_path() do
        path when is_binary(path) -> path
        nil -> TrackerConfig.default_tracker_file_path(workflow_path)
      end

    case TrackerConfig.load(tracker_path) do
      {:ok, tracker_config} -> tracker_config
      {:error, _reason} -> nil
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp stage_node_class(stage) do
    [
      "workflow-node",
      stage.start? && "workflow-node-start",
      stage.terminal? && "workflow-node-terminal",
      stage.blocked? && "workflow-node-blocked",
      stage.protocol_blocked? && "workflow-node-protocol",
      !stage.reachable? && "workflow-node-unreachable"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp transition_class(transition) do
    [
      "workflow-edge",
      transition.terminal_target? && "workflow-edge-terminal",
      transition.blocked_target? && "workflow-edge-blocked",
      transition.protocol_blocked_target? && "workflow-edge-protocol",
      !transition.known_outcome? && "workflow-edge-warning",
      !transition.target_exists? && "workflow-edge-warning"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp missing_outcome_class(missing_outcome) do
    [
      "missing-outcome-edge",
      missing_outcome.terminal_target? && "workflow-edge-terminal",
      missing_outcome.blocked_target? && "workflow-edge-blocked",
      missing_outcome.protocol_blocked_target? && "workflow-edge-protocol"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp coverage_badge_class(%{complete?: true}), do: "state-badge state-badge-active"
  defp coverage_badge_class(_coverage), do: "state-badge state-badge-warning"

  defp diagnostic_class(%{severity: :error}), do: "diagnostic-item diagnostic-error"
  defp diagnostic_class(%{severity: :warning}), do: "diagnostic-item diagnostic-warning"
  defp diagnostic_class(_diagnostic), do: "diagnostic-item"

  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
