defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:put_admin_client_ip)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    live("/admin/instances", AdminInstancesLive, :index)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/admin/instances", AdminInstanceController, :index)
    post("/api/v1/admin/instances", AdminInstanceController, :create)
    match(:*, "/api/v1/admin/instances", AdminInstanceController, :method_not_allowed)
    get("/api/v1/admin/update-timer", AdminInstanceController, :update_timer)
    post("/api/v1/admin/update-timer/enable", AdminInstanceController, :enable_update_timer)
    post("/api/v1/admin/update-timer/disable", AdminInstanceController, :disable_update_timer)
    post("/api/v1/admin/update-timer/trigger", AdminInstanceController, :trigger_update_timer)
    match(:*, "/api/v1/admin/update-timer", AdminInstanceController, :method_not_allowed)
    match(:*, "/api/v1/admin/update-timer/:action", AdminInstanceController, :method_not_allowed)
    get("/api/v1/admin/auto-update", AdminInstanceController, :auto_update)
    post("/api/v1/admin/auto-update/check", AdminInstanceController, :check_update)
    post("/api/v1/admin/auto-update/update", AdminInstanceController, :run_update)
    match(:*, "/api/v1/admin/auto-update", AdminInstanceController, :method_not_allowed)
    match(:*, "/api/v1/admin/auto-update/:action", AdminInstanceController, :method_not_allowed)
    get("/api/v1/admin/instances/:name/logs", AdminInstanceController, :logs)
    post("/api/v1/admin/instances/:name/start", AdminInstanceController, :start)
    post("/api/v1/admin/instances/:name/stop", AdminInstanceController, :stop)
    post("/api/v1/admin/instances/:name/restart", AdminInstanceController, :restart)
    post("/api/v1/admin/instances/:name/enable", AdminInstanceController, :enable)
    post("/api/v1/admin/instances/:name/disable", AdminInstanceController, :disable)
    match(:*, "/api/v1/admin/instances/:name/:action", AdminInstanceController, :method_not_allowed)
    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end

  defp put_admin_client_ip(conn, _opts) do
    Plug.Conn.put_session(conn, :admin_client_ip, conn.remote_ip |> :inet.ntoa() |> to_string())
  end
end
