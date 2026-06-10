defmodule SymphonyElixir.AdminInstanceDashboardTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeInstanceRegistry do
    def list_instances(opts) do
      send(owner(opts), {:list_instances, opts})

      {:ok,
       [
         %{
           name: "project-a",
           service: "symphony@project-a.service",
           status: "running",
           dashboard_url: "http://127.0.0.1:20001/",
           api_url: "http://127.0.0.1:20001/api/v1/state",
           tracker: %{kind: "github", scope: "acme/project-a", required_labels: ["symphony"]},
           counts: %{running: 2, retrying: 1, blocked: 0},
           health: %{status: "reachable", summary: "state API reachable; service running", error: nil},
           workspace_root: "/runtime/project-a/workspaces",
           logs_root: "/runtime/project-a/logs",
           config_path: "/config/project-a/WORKFLOW.md",
           env_path: "/config/project-a/env",
           runtime: %{codex_total_tokens: 1234, primary_rate_limit_remaining: 42}
         },
         %{
           name: "project-b",
           service: "symphony@project-b.service",
           status: "failed",
           dashboard_url: "http://127.0.0.1:20002/",
           api_url: "http://127.0.0.1:20002/api/v1/state",
           tracker: %{kind: "gitlab", scope: "platform/group/repo", required_labels: ["symphony"]},
           counts: %{running: 0, retrying: 0, blocked: 1},
           health: %{status: "unreachable", summary: "state API unreachable; service failed", error: ":econnrefused"},
           workspace_root: "/runtime/project-b/workspaces",
           logs_root: "/runtime/project-b/logs",
           config_path: "/config/project-b/WORKFLOW.md",
           env_path: "/config/project-b/env",
           runtime: %{codex_total_tokens: 0, primary_rate_limit_remaining: 0}
         }
       ]}
    end

    def start_instance(name, opts), do: action("start", name, opts)
    def stop_instance(name, opts), do: action("stop", name, opts)
    def restart_instance(name, opts), do: action("restart", name, opts)

    defp action(action, name, opts) do
      send(owner(opts), {:instance_action, action, name, opts})

      case {action, name} do
        {"start", "project-b"} ->
          {:error, %{code: "systemctl_failed", message: "Failed to start"}}

        _other ->
          {:ok, %{action: action, service: "symphony@#{name}.service"}}
      end
    end

    defp owner(opts), do: Keyword.fetch!(opts, :owner)
  end

  setup do
    original_endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    endpoint_config =
      original_endpoint_config
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.put(:instance_registry, FakeInstanceRegistry)
      |> Keyword.put(:instance_registry_opts, owner: self())

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, original_endpoint_config)
    end)

    :ok
  end

  test "admin instances API lists isolated instance summaries" do
    payload = json_response(get(build_conn(), "/api/v1/admin/instances"), 200)

    assert_receive {:list_instances, opts}
    assert Keyword.fetch!(opts, :owner) == self()

    assert %{"instances" => [project_a, project_b]} = payload
    assert project_a["name"] == "project-a"
    assert project_a["status"] == "running"
    assert project_a["counts"] == %{"running" => 2, "retrying" => 1, "blocked" => 0}
    assert project_a["dashboard_url"] == "http://127.0.0.1:20001/"

    assert project_b["name"] == "project-b"
    assert project_b["status"] == "failed"

    assert project_b["health"] == %{
             "status" => "unreachable",
             "summary" => "state API unreachable; service failed",
             "error" => ":econnrefused"
           }
  end

  test "admin instances API runs lifecycle actions and returns readable errors" do
    response = post(build_conn(), "/api/v1/admin/instances/project-a/restart", %{})
    assert json_response(response, 202) == %{"action" => "restart", "service" => "symphony@project-a.service"}
    assert_receive {:instance_action, "restart", "project-a", _opts}

    error_response = post(build_conn(), "/api/v1/admin/instances/project-b/start", %{})

    assert json_response(error_response, 500) == %{
             "error" => %{"code" => "systemctl_failed", "message" => "Failed to start"}
           }

    assert_receive {:instance_action, "start", "project-b", _opts}
  end

  test "admin dashboard renders multi-instance overview and links" do
    {:ok, _view, html} = live(build_conn(), "/admin/instances")

    assert html =~ "Symphony 实例管理"
    assert html =~ "集中观察"
    assert html =~ "fleet-summary"
    assert html =~ "instance-card-grid"
    assert html =~ "instance-identity"
    assert html =~ "health-panel"
    assert html =~ "lifecycle-button lifecycle-button-primary"
    assert html =~ "lifecycle-button lifecycle-button-danger"
    assert html =~ "lifecycle-button lifecycle-button-neutral"
    assert html =~ "project-a"
    assert html =~ "project-b"
    assert html =~ "running"
    assert html =~ "failed"
    assert html =~ "acme/project-a"
    assert html =~ "platform/group/repo"
    assert html =~ "运行中 2"
    assert html =~ "重试中 1"
    assert html =~ "阻塞 1"
    assert html =~ "http://127.0.0.1:20001/"
    assert html =~ "/runtime/project-a/workspaces"
    assert html =~ "/runtime/project-b/logs"
    assert html =~ "启动"
    assert html =~ "停止"
    assert html =~ "重启"
  end

  test "admin dashboard stylesheet includes responsive card styling" do
    css = response(get(build_conn(), "/dashboard.css"), 200)

    assert css =~ ".fleet-summary"
    assert css =~ ".instance-card-grid"
    assert css =~ ".instance-card"
    assert css =~ ".health-panel"
    assert css =~ ".lifecycle-button-danger"
    assert css =~ "@media (prefers-reduced-motion: reduce)"
    assert css =~ "@media (max-width: 720px)"
  end
end
