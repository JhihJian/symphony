defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns = assign(assigns, :csrf_token, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <!DOCTYPE html>
    <html lang="zh-CN">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony 可观测性</title>
        <script defer src="/vendor/mermaid/mermaid.min.js"></script>
        <script defer src="/dashboard.js"></script>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: window.SymphonyDashboardHooks || {}
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href="/dashboard.css" />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    assigns =
      assigns
      |> assign_new(:active_nav, fn -> :dashboard end)
      |> assign_new(:access_role, fn -> nil end)

    ~H"""
    <main class="app-shell">
      <.workspace_nav active_nav={@active_nav} access_role={@access_role} />
      <div class="app-layout">
        <aside class="page-outline" data-page-outline hidden aria-label="页面大纲">
          <div class="page-outline-inner">
            <p class="page-outline-kicker">页面大纲</p>
            <nav class="page-outline-list" data-page-outline-list aria-label="当前页面主要区域"></nav>
          </div>
        </aside>

        <div class="app-content">
          {@inner_content}
        </div>
      </div>
    </main>
    """
  end

  defp workspace_nav(assigns) do
    ~H"""
    <nav class="workspace-nav" aria-label="Symphony 工作台导航">
      <a class="workspace-brand" href="/">
        <span class="workspace-brand-mark" aria-hidden="true">S</span>
        <span>
          <strong>Symphony</strong>
          <small>Agent orchestration</small>
        </span>
      </a>

      <div class="workspace-nav-links">
        <a class={nav_link_class(@active_nav, :dashboard)} href="/" aria-current={current_nav?(@active_nav, :dashboard) && "page"}>
          Hub 运行总览
        </a>
        <a class={nav_link_class(@active_nav, :workflow)} href="/workflow" aria-current={current_nav?(@active_nav, :workflow) && "page"}>
          流程配置
        </a>
        <a class={nav_link_class(@active_nav, :instances)} href="/admin/instances" aria-current={current_nav?(@active_nav, :instances) && "page"}>
          实例管理
        </a>
      </div>

      <span :if={@access_role} class="workspace-role-badge"><%= @access_role %></span>
    </nav>
    """
  end

  defp nav_link_class(active_nav, nav) do
    if current_nav?(active_nav, nav), do: "workspace-nav-link workspace-nav-link-active", else: "workspace-nav-link"
  end

  defp current_nav?(active_nav, nav), do: to_string(active_nav) == to_string(nav)
end
