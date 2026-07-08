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
  def mount(_params, session, socket) do
    projection = load_projection()

    {:ok,
     socket
     |> assign(:active_nav, :workflow)
     |> assign(:access_role, access_role(session))
     |> assign(:projection, projection)
     |> assign(:selected_stage_id, default_selected_stage_id(projection))}
  end

  @impl true
  def handle_event("select_stage", %{"stage" => stage_id}, socket) do
    selected_stage_id =
      if stage_exists?(socket.assigns.projection, stage_id) do
        stage_id
      else
        socket.assigns.selected_stage_id
      end

    {:noreply, assign(socket, :selected_stage_id, selected_stage_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell workflow-dashboard">
      <header class="hero-card workflow-command-hero">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Workflow 配置</p>
            <h1 class="hero-title">流程配置检查</h1>
            <p class="hero-copy">
              先确认入口阶段、运行快照和配置提醒，再查看阶段流向图与当前阶段详情。
            </p>
          </div>

          <div class="status-stack" role="status" aria-live="polite">
            <span class="status-badge">页面连接</span>
            <span class="status-badge status-badge-connecting">
              <span class="status-badge-dot"></span>
              连接中
            </span>
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              实时连接
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              连接断开
            </span>
            <span class="status-badge">
              当前访问：<%= @access_role %>
            </span>
            <span class="status-badge">只读</span>
            <span class={workflow_config_badge_class(@projection)}>
              <%= workflow_config_state_text(@projection) %>
            </span>
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
        <section class="workflow-status-strip" aria-label="Workflow 配置摘要">
          <article class="workflow-status-chip">
            <p class="metric-label">入口阶段</p>
            <p class="workflow-chip-value mono"><%= @projection.workflow.start_stage %></p>
            <p class="metric-detail">新 issue 从这里开始。</p>
          </article>

          <article class="workflow-status-chip">
            <p class="metric-label">阶段数量</p>
            <p class="workflow-chip-value numeric"><%= @projection.workflow.stage_count %></p>
            <p class="metric-detail">包含 <%= @projection.workflow.transition_count %> 条普通流转。</p>
          </article>

          <article class="workflow-status-chip">
            <p class="metric-label">结束阶段</p>
            <p class="workflow-chip-value numeric"><%= length(@projection.workflow.terminal_stages) %></p>
            <p class="metric-detail mono"><%= Enum.join(@projection.workflow.terminal_stages, ", ") %></p>
          </article>

          <article class="workflow-status-chip">
            <p class="metric-label">运行快照</p>
            <p class="workflow-chip-value"><%= if @projection.runtime.available?, do: "可用", else: "不可用" %></p>
            <p class="metric-detail">
              <%= if @projection.runtime.available?, do: "已叠加运行态阶段分布。", else: @projection.runtime.error.message %>
            </p>
          </article>

          <article class={workflow_diagnostic_chip_class(@projection.diagnostics)}>
            <p class="metric-label">诊断提醒</p>
            <p class="workflow-chip-value numeric"><%= workflow_problem_diagnostic_count(@projection.diagnostics) %></p>
            <p class="metric-detail">
              <a class="issue-link" href="#workflow-diagnostics"><%= workflow_diagnostic_summary_text(@projection.diagnostics) %></a>
            </p>
          </article>
        </section>

        <section class="workflow-layout">
          <article class="section-card workflow-graph-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">阶段流向图</h2>
                <p class="section-copy">节点是阶段，箭头是结果到目标阶段；选中节点会在右侧展示当前阶段详情。</p>
              </div>
            </div>

            <% graph = workflow_mermaid(@projection, @selected_stage_id) %>

            <div class="workflow-graph-inspector">
              <div class="workflow-graph-stack">
                <div
                  id="workflow-mermaid-graph"
                  class="workflow-graph workflow-mermaid"
                  phx-hook="WorkflowMermaid"
                  data-mermaid-signature={graph.signature}
                  data-stage-map={graph.stage_map_json}
                  aria-label="Workflow stage graph"
                >
                  <pre class="workflow-mermaid-source" data-mermaid-source><%= graph.definition %></pre>
                  <div class="workflow-mermaid-output" data-mermaid-output>
                    <p class="empty-state">正在渲染 Workflow 图...</p>
                  </div>
                </div>

                <.workflow_mobile_flow_list stages={mobile_flow_stages(@projection)} />
              </div>

              <.selected_stage_panel stage={selected_stage(@projection, @selected_stage_id)} />
            </div>
          </article>

          <div class="workflow-detail-strip">
            <section class="section-card">
              <div class="section-header">
                <div>
                  <h2 class="section-title">缺失结果处理</h2>
                  <p class="section-copy">该路径由协议缺失或无效结果触发，不属于普通业务流转。</p>
                </div>
              </div>
              <div class={missing_outcome_class(@projection.missing_outcome)}>
                <div class="workflow-route-token">
                  <span class="workflow-route-label">max retries</span>
                  <span class="mono"><%= @projection.missing_outcome.max_retries %></span>
                </div>
                <span class="workflow-edge-arrow" aria-hidden="true">→</span>
                <a href={"#stage-#{@projection.missing_outcome.on_exhausted}"} class="workflow-route-token">
                  <span class="workflow-route-label">on exhausted</span>
                  <span class="mono"><%= @projection.missing_outcome.on_exhausted %></span>
                </a>
              </div>
            </section>

            <section class="section-card">
              <div class="section-header">
                <div>
                  <h2 class="section-title">Tracker 映射</h2>
                  <p class="section-copy">以内部阶段为主，外部 provider state 只作为可见状态摘要。</p>
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

                <div class="workflow-mapping-list" aria-label="Tracker stage-state mapping">
                  <article :for={mapping <- @projection.tracker.mappings} class="workflow-mapping-row">
                    <div class="workflow-mapping-stage">
                      <span class="mapping-label">Stage</span>
                      <strong class="mono"><%= mapping.stage %></strong>
                    </div>
                    <div class="workflow-mapping-state">
                      <span class="mapping-label">Provider State</span>
                      <span class={if mapping.mapped?, do: "state-badge", else: "state-badge state-badge-warning"}>
                        <%= mapping.provider_state || "未映射" %>
                      </span>
                    </div>
                  </article>
                </div>

                <pre :if={map_size(@projection.tracker.provider_hint) > 0} class="code-panel tracker-hint"><%= pretty_value(@projection.tracker.provider_hint) %></pre>
              <% else %>
                <p class="empty-state">TRACKER.yaml 不可用，无法展示 stage-state 映射。</p>
              <% end %>
            </section>
          </div>
        </section>

        <.diagnostics_panel diagnostics={@projection.diagnostics} />

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Stage 详情</h2>
              <p class="section-copy">每个 stage 的 prompt 预览、outcome 列表、tracker state 和运行态分布。</p>
            </div>
          </div>

          <div class="stage-detail-grid">
            <article :for={stage <- @projection.stages} id={"stage-#{stage.id}"} class="stage-detail-card">
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
                  <div class="workflow-route-token">
                    <span class="workflow-route-label">outcome</span>
                    <span class="mono"><%= transition.outcome %></span>
                  </div>
                  <span class="workflow-edge-arrow" aria-hidden="true">→</span>
                  <div class="workflow-route-token">
                    <span class="workflow-route-label">target</span>
                    <span class="mono"><%= transition.to %></span>
                  </div>
                  <span class={if transition.known_outcome?, do: "state-badge state-badge-muted", else: "state-badge state-badge-warning"}>
                    <%= if transition.known_outcome?, do: "known outcome", else: "unknown outcome" %>
                  </span>
                  <span :if={!transition.target_exists?} class="state-badge state-badge-warning">
                    unknown target
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
    <section class="section-card" id="workflow-diagnostics">
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
            <p :if={diagnostic_operator_guidance(diagnostic)} class="diagnostic-guidance">
              <%= diagnostic_operator_guidance(diagnostic) %>
            </p>
          </div>
        </article>
      </div>
    </section>
    """
  end

  attr(:stages, :list, required: true)

  defp workflow_mobile_flow_list(assigns) do
    ~H"""
    <div class="workflow-mobile-flow-list" aria-label="手机端 workflow stage 流向概览">
      <article :for={stage <- @stages} class="workflow-mobile-stage-card">
        <div class="workflow-mobile-stage-header">
          <div class="workflow-mobile-stage-title">
            <span class="mapping-label">Stage</span>
            <strong class="mono"><%= stage.id %></strong>
          </div>
          <div class="workflow-node-badges">
            <span :if={stage.start?} class="state-badge state-badge-active">start</span>
            <span :if={stage.terminal?} class="state-badge state-badge-terminal">terminal</span>
            <span :if={!stage.reachable?} class="state-badge state-badge-warning">unreachable</span>
          </div>
        </div>

        <div class="stage-detail-meta workflow-mobile-runtime">
          <span>running <strong class="numeric"><%= stage.runtime.running %></strong></span>
          <span>retrying <strong class="numeric"><%= stage.runtime.retrying %></strong></span>
          <span>blocked <strong class="numeric"><%= stage.runtime.blocked %></strong></span>
        </div>

        <div class="transition-detail-list workflow-mobile-transitions">
          <div :for={transition <- stage.transitions} class="workflow-edge workflow-mobile-transition">
            <div class="workflow-route-token">
              <span class="workflow-route-label">outcome</span>
              <span class="mono"><%= transition.outcome %></span>
            </div>
            <span class="workflow-edge-arrow" aria-hidden="true">→</span>
            <div class="workflow-route-token">
              <span class="workflow-route-label">target</span>
              <span class="mono"><%= transition.to %></span>
            </div>
          </div>
          <p :if={stage.transitions == []} class="empty-state workflow-empty-edge">无 outcome transition。</p>
        </div>
      </article>
    </div>
    """
  end

  attr(:stage, :map, required: true)

  defp selected_stage_panel(assigns) do
    ~H"""
    <section class="section-card selected-stage-panel" id="selected-stage-panel">
      <div class="section-header">
        <div>
          <h2 class="section-title">当前阶段</h2>
          <p class="section-copy mono"><%= @stage.id %></p>
        </div>
        <div class="workflow-node-badges">
          <span :if={@stage.start?} class="state-badge state-badge-active">start</span>
          <span :if={@stage.terminal?} class="state-badge state-badge-terminal">terminal</span>
          <span :if={!@stage.reachable?} class="state-badge state-badge-warning">unreachable</span>
          <span :if={@stage.blocked? and not @stage.protocol_blocked?} class="state-badge state-badge-danger">blocked</span>
          <span :if={@stage.protocol_blocked?} class="state-badge state-badge-danger">protocol</span>
        </div>
      </div>

      <div class="stage-detail-meta selected-stage-runtime">
        <span>running <strong class="numeric"><%= @stage.runtime.running %></strong></span>
        <span>retrying <strong class="numeric"><%= @stage.runtime.retrying %></strong></span>
        <span>blocked <strong class="numeric"><%= @stage.runtime.blocked %></strong></span>
      </div>

      <p class="section-copy">
        Tracker:
        <%= if @stage.tracker_state && @stage.tracker_state.provider_state do %>
          <span class="mono"><%= @stage.tracker_state.provider_state %></span>
        <% else %>
          <span class="muted">未映射</span>
        <% end %>
      </p>

      <pre class="prompt-preview selected-stage-prompt"><%= @stage.prompt %></pre>

      <div class="transition-detail-list selected-stage-transitions">
        <%= for transition <- @stage.transitions do %>
          <button
            :if={transition.target_exists?}
            type="button"
            class={transition_select_class(transition)}
            data-stage-target={transition.to}
            phx-click="select_stage"
            phx-value-stage={transition.to}
          >
            <.transition_content transition={transition} />
          </button>
          <div
            :if={!transition.target_exists?}
            class={transition_select_class(transition)}
            data-stage-target={transition.to}
            aria-disabled="true"
          >
            <.transition_content transition={transition} />
          </div>
        <% end %>
        <p :if={@stage.transitions == []} class="empty-state">无 outcome transition。</p>
      </div>
    </section>
    """
  end

  attr(:transition, :map, required: true)

  defp transition_content(assigns) do
    ~H"""
    <div class="workflow-route-token">
      <span class="workflow-route-label">outcome</span>
      <span class="mono"><%= @transition.outcome %></span>
    </div>
    <span class="workflow-edge-arrow" aria-hidden="true">→</span>
    <div class="workflow-route-token">
      <span class="workflow-route-label">target</span>
      <span class="mono"><%= @transition.to %></span>
    </div>
    <div class="workflow-node-badges transition-warning-badges">
      <span :if={!@transition.known_outcome?} class="state-badge state-badge-warning">unknown outcome</span>
      <span :if={!@transition.target_exists?} class="state-badge state-badge-warning">unknown target</span>
    </div>
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

  defp access_role(session) do
    if local_admin_session?(Map.get(session, "admin_client_ip") || Map.get(session, :admin_client_ip)) do
      "本机管理员"
    else
      "远程只读"
    end
  end

  defp local_admin_session?(ip) when ip in ["127.0.0.1", "::1", "::ffff:127.0.0.1"], do: true
  defp local_admin_session?(_ip), do: false

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

  defp workflow_config_badge_class(%{error: _error}), do: "state-badge state-badge-danger"

  defp workflow_config_badge_class(%{diagnostics: diagnostics}) do
    if workflow_problem_diagnostic_count(diagnostics) > 0 do
      "state-badge state-badge-warning"
    else
      "state-badge state-badge-active"
    end
  end

  defp workflow_config_state_text(%{error: _error}), do: "配置不可用"

  defp workflow_config_state_text(%{diagnostics: diagnostics}) do
    if workflow_problem_diagnostic_count(diagnostics) > 0 do
      "配置有提醒"
    else
      "配置可读"
    end
  end

  defp workflow_diagnostic_chip_class(diagnostics) do
    if workflow_problem_diagnostic_count(diagnostics) > 0 do
      "workflow-status-chip workflow-status-chip-warning"
    else
      "workflow-status-chip"
    end
  end

  defp workflow_diagnostic_summary_text(diagnostics) do
    count = workflow_problem_diagnostic_count(diagnostics)

    case workflow_primary_problem_diagnostic(diagnostics) do
      nil -> "没有阻断项或 warning"
      diagnostic -> "查看 #{count} 条配置提醒：#{diagnostic_brief(diagnostic)}"
    end
  end

  defp workflow_problem_diagnostic_count(diagnostics) when is_list(diagnostics) do
    Enum.count(diagnostics, fn diagnostic -> diagnostic.severity in [:error, :warning] end)
  end

  defp workflow_primary_problem_diagnostic(diagnostics) when is_list(diagnostics) do
    Enum.find(diagnostics, fn diagnostic -> diagnostic.severity in [:error, :warning] end)
  end

  defp diagnostic_brief(%{code: code, message: message}) do
    "#{code} - #{message}"
  end

  defp diagnostic_operator_guidance(%{code: :unreachable_stage}) do
    "这类 stage 不会从 start stage 自动抵达；确认它是不是废弃阶段，或缺少一条 transition。"
  end

  defp diagnostic_operator_guidance(%{code: :terminal_stage_unreached}) do
    "如果这是正常终点，应检查是否有 transition 或 missing-outcome fallback 能够抵达它。"
  end

  defp diagnostic_operator_guidance(%{code: :tracker_config_unavailable}) do
    "运行态仍可展示静态流程图，但无法确认 provider-visible state 映射是否完整。"
  end

  defp diagnostic_operator_guidance(_diagnostic), do: nil

  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp transition_select_class(transition) do
    [
      "transition-select-button",
      !transition.known_outcome? && "workflow-edge-warning",
      !transition.target_exists? && "transition-select-disabled"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp default_selected_stage_id(%{workflow: %{start_stage: start_stage}}) when is_binary(start_stage), do: start_stage
  defp default_selected_stage_id(_projection), do: nil

  defp stage_exists?(%{stages: stages}, stage_id) when is_binary(stage_id) do
    Enum.any?(stages, &(&1.id == stage_id))
  end

  defp stage_exists?(_projection, _stage_id), do: false

  defp selected_stage(%{stages: stages} = projection, selected_stage_id) do
    Enum.find(stages, &(&1.id == selected_stage_id || &1.id == default_selected_stage_id(projection)))
  end

  defp mobile_flow_stages(%{stages: stages, workflow: %{start_stage: start_stage}}) do
    Enum.sort_by(stages, &{if(&1.id == start_stage, do: 0, else: 1), &1.id})
  end

  defp workflow_mermaid(projection, selected_stage_id) do
    stages = Map.get(projection, :stages, [])

    node_ids =
      stages
      |> Enum.with_index()
      |> Map.new(fn {stage, index} -> {stage.id, mermaid_node_id(stage.id, index)} end)

    definition =
      ([
         "flowchart LR",
         "  classDef stage fill:#ffffff,stroke:#d9d9e3,stroke-width:1.5px,color:#202123;",
         "  classDef selected fill:#e8faf4,stroke:#10a37f,stroke-width:3px,color:#202123;",
         "  classDef start fill:#f0fbf7,stroke:#10a37f,stroke-width:2px,color:#202123;",
         "  classDef terminal fill:#ffffff,stroke:#7c8597,stroke-width:2px,color:#202123;",
         "  classDef blocked fill:#fef3f2,stroke:#f0aaa3,stroke-width:2px,color:#202123;",
         "  classDef unreachable fill:#f5f5f7,stroke:#d9d9e3,stroke-width:1.5px,color:#6e6e80;"
       ] ++
         Enum.flat_map(stages, &mermaid_node_lines(&1, node_ids, selected_stage_id)) ++
         mermaid_edge_lines(Map.get(projection, :transitions, []), node_ids))
      |> Enum.join("\n")

    %{
      definition: definition,
      signature: mermaid_signature(definition),
      stage_map_json: mermaid_stage_map_json(node_ids)
    }
  end

  defp collapse_blocked_edges(transitions) do
    {blocked_edges, normal_edges} = Enum.split_with(transitions, & &1.blocked_target?)

    case blocked_edges do
      [] ->
        normal_edges

      edges ->
        [representative_blocked_edge(edges) | normal_edges]
    end
  end

  defp representative_blocked_edge(edges) do
    edges
    |> Enum.sort_by(fn edge -> {edge.from == "ready", edge.from, edge.to} end, :desc)
    |> List.first()
    |> Map.put(:outcome, "blocked")
    |> Map.put(:graph_summary?, true)
  end

  defp mermaid_node_lines(stage, node_ids, selected_stage_id) do
    node_id = Map.fetch!(node_ids, stage.id)

    [
      ~s(  #{node_id}["#{mermaid_node_label(stage.id)}"]),
      "  class #{node_id} #{Enum.join(mermaid_node_classes(stage, selected_stage_id), ",")};"
    ]
  end

  defp mermaid_edge_lines(transitions, node_ids) do
    transitions
    |> Enum.filter(fn transition -> Map.has_key?(node_ids, transition.from) and Map.has_key?(node_ids, transition.to) end)
    |> collapse_blocked_edges()
    |> Enum.map(fn transition ->
      from_node_id = Map.fetch!(node_ids, transition.from)
      to_node_id = Map.fetch!(node_ids, transition.to)

      "  #{from_node_id} -->|#{mermaid_text(transition.outcome)}| #{to_node_id}"
    end)
  end

  defp mermaid_node_classes(stage, selected_stage_id) do
    [
      "stage",
      stage.start? && "start",
      stage.terminal? && "terminal",
      (stage.blocked? or stage.protocol_blocked?) && "blocked",
      !stage.reachable? && "unreachable",
      stage.id == selected_stage_id && "selected"
    ]
    |> Enum.filter(& &1)
  end

  defp mermaid_node_id(stage_id, index) do
    normalized =
      stage_id
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_]/, "_")
      |> String.trim("_")

    suffix =
      case normalized do
        "" -> "stage"
        value -> value
      end

    "stage_#{index}_#{suffix}"
  end

  defp mermaid_text(value) do
    value
    |> to_string()
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> String.replace(~r/[|"<>]/, " ")
    |> String.trim()
  end

  defp mermaid_node_label(value) do
    value
    |> mermaid_text()
    |> String.replace("_", "\\n")
  end

  defp mermaid_signature(definition) do
    :sha256
    |> :crypto.hash(definition)
    |> Base.encode16(case: :lower)
  end

  defp mermaid_stage_map_json(node_ids) do
    node_ids
    |> Map.new(fn {stage_id, node_id} -> {node_id, stage_id} end)
    |> Jason.encode!()
  end
end
