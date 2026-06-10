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
           systemd: %{active: "active", enabled: "enabled", sub: "running", failed: false},
           dashboard_url: "http://127.0.0.1:20001/",
           api_url: "http://127.0.0.1:20001/api/v1/state",
           tracker: %{kind: "github", scope: "acme/project-a", required_labels: ["symphony"]},
           counts: %{running: 2, retrying: 1, blocked: 0},
           health: %{status: "reachable", summary: "state API reachable; service running", error: nil},
           workspace_root: "/runtime/project-a/workspaces",
           logs_root: "/runtime/project-a/logs",
           config_path: "/config/project-a/WORKFLOW.md",
           env_path: "/config/project-a/env",
           runtime: %{codex_total_tokens: 1234, primary_rate_limit_remaining: 42},
           strategy: "idle_restart"
         },
         %{
           name: "project-b",
           service: "symphony@project-b.service",
           status: "failed",
           systemd: %{active: "failed", enabled: "disabled", sub: "failed", failed: true},
           dashboard_url: "http://127.0.0.1:20002/",
           api_url: "http://127.0.0.1:20002/api/v1/state",
           tracker: %{kind: "gitlab", scope: "platform/group/repo", required_labels: ["symphony"]},
           counts: %{running: 0, retrying: 0, blocked: 1},
           health: %{status: "unreachable", summary: "state API unreachable; service failed", error: ":econnrefused"},
           workspace_root: "/runtime/project-b/workspaces",
           logs_root: "/runtime/project-b/logs",
           config_path: "/config/project-b/WORKFLOW.md",
           env_path: "/config/project-b/env",
           runtime: %{codex_total_tokens: 0, primary_rate_limit_remaining: 0},
           strategy: "manual_restart"
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

  defmodule FakeAutoUpdate do
    @moduledoc false

    def snapshot(opts) do
      send(owner(opts), {:auto_update_snapshot, opts})
      snapshot_payload()
    end

    def check_now(opts) do
      send(owner(opts), {:auto_update_check_now, opts})

      {:ok,
       %{
         snapshot_payload()
         | pending_update?: false,
           next_check_at: ~U[2026-06-10 02:20:00Z],
           last_check: %{
             snapshot_payload().last_check
             | status: "not_modified",
               checked_at: ~U[2026-06-10 02:10:00Z],
               rate_limit: %{remaining: 57, reset_at: "2026-06-10T03:00:00Z"}
           }
       }}
    end

    def update_now(opts) do
      send(owner(opts), {:auto_update_update_now, opts})

      {:ok,
       %{
         snapshot_payload()
         | current_sha: "remote-sha",
           pending_update?: false,
           last_update: %{
             status: "updated",
             started_at: ~U[2026-06-10 02:00:00Z],
             finished_at: ~U[2026-06-10 02:01:00Z],
             from_sha: "local-sha",
             to_sha: "remote-sha",
             error: nil,
             instance_results: [
               %{
                 name: "project-a",
                 service: "symphony@project-a.service",
                 status: "running",
                 running: 0,
                 strategy: "idle_restart",
                 decision: "restarted",
                 reason: "active instance is idle"
               },
               %{
                 name: "project-b",
                 service: "symphony@project-b.service",
                 status: "failed",
                 running: 0,
                 strategy: "idle_restart",
                 decision: "skipped_failed",
                 reason: "service is failed; manual intervention required"
               }
             ]
           }
       }}
    end

    defp snapshot_payload do
      %{
        repo: "jhihjian/symphony",
        branch: "main",
        source_root: "/source",
        poll_interval_ms: 600_000,
        current_sha: "local-sha",
        remote_sha: "remote-sha",
        pending_update?: true,
        next_check_at: ~U[2026-06-10 02:10:00Z],
        last_check: %{
          status: "ok",
          checked_at: ~U[2026-06-10 02:00:00Z],
          etag: ~s(W/"etag-1"),
          error: nil,
          rate_limit: %{remaining: 58, reset_at: "2026-06-10T03:00:00Z"}
        },
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

    defp owner(opts), do: Keyword.fetch!(opts, :owner)
  end

  setup do
    original_endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    endpoint_config =
      original_endpoint_config
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.put(:instance_registry, FakeInstanceRegistry)
      |> Keyword.put(:instance_registry_opts, owner: self())
      |> Keyword.put(:auto_update, FakeAutoUpdate)
      |> Keyword.put(:auto_update_opts, owner: self())

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

  test "admin auto update API exposes status and manual triggers" do
    status_payload = json_response(get(build_conn(), "/api/v1/admin/auto-update"), 200)
    assert_receive {:auto_update_snapshot, opts}
    assert Keyword.fetch!(opts, :owner) == self()

    assert status_payload["repo"] == "jhihjian/symphony"
    assert status_payload["branch"] == "main"
    assert status_payload["current_sha"] == "local-sha"
    assert status_payload["remote_sha"] == "remote-sha"
    assert status_payload["pending_update?"] == true
    assert status_payload["last_check"]["etag"] == ~s(W/"etag-1")
    assert status_payload["last_check"]["rate_limit"]["remaining"] == 58
    assert status_payload["next_check_at"] == "2026-06-10T02:10:00Z"

    check_payload = json_response(post(build_conn(), "/api/v1/admin/auto-update/check", %{}), 202)
    assert_receive {:auto_update_check_now, _opts}
    assert check_payload["last_check"]["status"] == "not_modified"

    update_payload = json_response(post(build_conn(), "/api/v1/admin/auto-update/update", %{}), 202)
    assert_receive {:auto_update_update_now, _opts}
    assert update_payload["last_update"]["status"] == "updated"
    assert [project_a, project_b] = update_payload["last_update"]["instance_results"]
    assert project_a["decision"] == "restarted"
    assert project_b["decision"] == "skipped_failed"
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
    assert html =~ "enabled / running"
    assert html =~ "idle_restart"
    assert html =~ "manual_restart"
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

    assert html =~ "GitHub main 自动更新"
    assert html =~ "当前部署"
    assert html =~ "local-sha"
    assert html =~ "remote-sha"
    assert html =~ "有可用更新"
    assert html =~ "下次检查"
    assert html =~ "2026-06-10T02:10:00Z"
    assert html =~ "立即检查"
    assert html =~ "执行更新"
    assert html =~ "空闲自动重启"
  end

  test "admin dashboard check now button refreshes visible check details" do
    {:ok, view, html} = live(build_conn(), "/admin/instances")

    assert html =~ "最近检查：ok"
    refute html =~ "检查时间：2026-06-10T02:10:00Z"
    refute html =~ "自动更新操作完成：not_modified"

    html =
      view
      |> element("button", "立即检查")
      |> render_click()

    assert_receive {:auto_update_check_now, _opts}
    assert html =~ "自动更新操作完成：not_modified"
    assert html =~ "最近检查：not_modified"
    assert html =~ "检查时间"
    assert html =~ "2026-06-10T02:10:00Z"
    assert html =~ "剩余额度 57"
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
