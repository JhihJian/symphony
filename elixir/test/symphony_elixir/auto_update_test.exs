defmodule SymphonyElixir.AutoUpdateTest do
  use ExUnit.Case

  alias SymphonyElixir.AutoUpdate

  describe "GitHub polling" do
    test "starts with a registered default name" do
      pid = Process.whereis(AutoUpdate)

      assert is_pid(pid)
      assert AutoUpdate.snapshot().repo == "jhihjian/symphony"
    end

    test "uses the repository root as the default source root" do
      source_root = AutoUpdate.default_source_root()

      assert source_root == Path.expand("../../..", __DIR__)
      assert File.dir?(Path.join(source_root, "elixir"))
      assert File.dir?(Path.join(source_root, "scripts"))
      refute source_root =~ "elixir/lib/symphony_elixir"
    end

    test "resolves mise from the user-local fallback when PATH is minimal" do
      original_path = System.get_env("PATH")
      System.put_env("PATH", "/usr/bin:/bin")

      try do
        assert {:ok, mise} = AutoUpdate.resolve_mise_executable()
        assert String.ends_with?(mise, "/.local/bin/mise") or Path.basename(mise) == "mise"
        assert File.exists?(mise)
      after
        if original_path, do: System.put_env("PATH", original_path), else: System.delete_env("PATH")
      end
    end

    test "checks main with etag and marks update availability" do
      owner = self()

      deps =
        deps(owner,
          current_revision: fn -> {:ok, "local-sha"} end,
          github_head: fn headers ->
            send(owner, {:github_headers, headers})

            {:ok,
             %{
               sha: "remote-sha",
               etag: ~s(W/"etag-1"),
               checked_at: ~U[2026-06-10 02:00:00Z],
               rate_limit: %{remaining: 59, reset_at: "2026-06-10T03:00:00Z"}
             }}
          end
        )

      {:ok, pid} = start_supervised({AutoUpdate, auto_update_opts(deps, poll_interval_ms: 600_000)})

      assert {:ok, snapshot} = AutoUpdate.check_now(pid)
      assert_receive {:github_headers, %{}}

      assert snapshot.current_sha == "local-sha"
      assert snapshot.remote_sha == "remote-sha"
      assert snapshot.pending_update? == true
      assert snapshot.last_check.status == "ok"
      assert snapshot.last_check.etag == ~s(W/"etag-1")
      assert snapshot.last_check.rate_limit.remaining == 59
      assert snapshot.next_check_at == ~U[2026-06-10 02:10:00Z]

      deps =
        deps(owner,
          current_revision: fn -> {:ok, "local-sha"} end,
          github_head: fn headers ->
            send(owner, {:github_headers, headers})
            {:not_modified, %{checked_at: ~U[2026-06-10 02:10:00Z], rate_limit: %{remaining: 58}}}
          end
        )

      AutoUpdate.replace_deps(pid, deps)
      assert {:ok, snapshot} = AutoUpdate.check_now(pid)
      assert_receive {:github_headers, %{if_none_match: ~s(W/"etag-1")}}
      assert snapshot.remote_sha == "remote-sha"
      assert snapshot.last_check.status == "not_modified"
      assert snapshot.last_check.rate_limit.remaining == 58
    end

    test "keeps instances running when GitHub API fails" do
      owner = self()

      deps =
        deps(owner,
          current_revision: fn -> {:ok, "local-sha"} end,
          github_head: fn _headers -> {:error, %{message: "rate limit exceeded", rate_limit: %{remaining: 0}}} end,
          restart_instance: fn _name ->
            send(owner, :unexpected_restart)
            :ok
          end
        )

      {:ok, pid} = start_supervised({AutoUpdate, auto_update_opts(deps)})

      assert {:error, snapshot} = AutoUpdate.check_now(pid)
      assert snapshot.current_sha == "local-sha"
      assert snapshot.remote_sha == nil
      assert snapshot.pending_update? == false
      assert snapshot.last_check.status == "error"
      assert snapshot.last_check.error =~ "rate limit exceeded"
      assert snapshot.last_check.rate_limit.remaining == 0
      refute_received :unexpected_restart
    end
  end

  describe "update execution" do
    test "serializes updates with a host lock" do
      owner = self()
      lock_path = Path.join(System.tmp_dir!(), "symphony-auto-update-lock-#{System.unique_integer([:positive])}.lock")
      File.mkdir_p!(lock_path)

      deps =
        deps(owner,
          build: fn ->
            send(owner, :unexpected_build)
            :ok
          end,
          lock_path: lock_path
        )

      {:ok, pid} = start_supervised({AutoUpdate, auto_update_opts(deps, lock_path: lock_path)})

      assert {:error, snapshot} = AutoUpdate.update_now(pid)
      assert snapshot.last_update.status == "busy"
      assert snapshot.last_update.error =~ "already running"
      refute_received :unexpected_build

      File.rm_rf!(lock_path)
    end

    test "blocks update when source tree has local changes" do
      owner = self()

      deps =
        deps(owner,
          dirty?: fn -> {:ok, true, " M elixir/lib/file.ex"} end,
          build: fn ->
            send(owner, :unexpected_build)
            :ok
          end,
          restart_instance: fn _name ->
            send(owner, :unexpected_restart)
            :ok
          end
        )

      {:ok, pid} = start_supervised({AutoUpdate, auto_update_opts(deps)})

      assert {:error, snapshot} = AutoUpdate.update_now(pid)
      assert snapshot.last_update.status == "blocked"
      assert snapshot.last_update.error =~ "local changes"
      assert snapshot.last_update.error =~ "elixir/lib/file.ex"
      refute_received :unexpected_build
      refute_received :unexpected_restart
    end

    test "build failure does not restart any instance" do
      owner = self()

      deps =
        deps(owner,
          dirty?: fn -> {:ok, false, ""} end,
          fetch: fn -> {:ok, %{before_sha: "old", after_sha: "new", changed?: true}} end,
          build: fn -> {:error, %{exit_status: 2, output: "mix build failed"}} end,
          restart_instance: fn _name ->
            send(owner, :unexpected_restart)
            :ok
          end
        )

      {:ok, pid} = start_supervised({AutoUpdate, auto_update_opts(deps)})

      assert {:error, snapshot} = AutoUpdate.update_now(pid)
      assert snapshot.last_update.status == "failed"
      assert snapshot.last_update.error =~ "mix build failed"
      assert snapshot.last_update.from_sha == "old"
      assert snapshot.last_update.to_sha == "new"
      refute_received :unexpected_restart
    end

    test "rebuilds and restarts when git is current but the built revision marker is stale" do
      owner = self()

      deps =
        deps(owner,
          dirty?: fn -> {:ok, false, ""} end,
          fetch: fn -> {:ok, %{before_sha: "new", after_sha: "new", changed?: false}} end,
          build_current?: fn "new" -> false end,
          build: fn ->
            send(owner, :build)
            :ok
          end,
          mark_built: fn "new" ->
            send(owner, {:mark_built, "new"})
            :ok
          end,
          restart_instance: fn name ->
            send(owner, {:restart, name})
            :ok
          end
        )

      {:ok, pid} = start_supervised({AutoUpdate, auto_update_opts(deps)})

      assert {:ok, snapshot} = AutoUpdate.update_now(pid)
      assert_receive :build
      assert_receive {:mark_built, "new"}
      assert_receive {:restart, "default"}
      assert snapshot.last_update.status == "rebuilt"
      assert snapshot.last_update.from_sha == "new"
      assert snapshot.last_update.to_sha == "new"
    end

    test "does not rebuild when git and built revision are both current" do
      owner = self()

      deps =
        deps(owner,
          dirty?: fn -> {:ok, false, ""} end,
          fetch: fn -> {:ok, %{before_sha: "new", after_sha: "new", changed?: false}} end,
          build_current?: fn "new" -> true end,
          build: fn ->
            send(owner, :unexpected_build)
            :ok
          end,
          restart_instance: fn _name ->
            send(owner, :unexpected_restart)
            :ok
          end
        )

      {:ok, pid} = start_supervised({AutoUpdate, auto_update_opts(deps)})

      assert {:ok, snapshot} = AutoUpdate.update_now(pid)
      assert snapshot.last_update.status == "up_to_date"
      refute_received :unexpected_build
      refute_received :unexpected_restart
    end

    test "records the built revision before restarting instances" do
      owner = self()

      deps =
        deps(owner,
          dirty?: fn -> {:ok, false, ""} end,
          fetch: fn -> {:ok, %{before_sha: "old", after_sha: "new", changed?: true}} end,
          build: fn ->
            send(owner, {:step, :build})
            :ok
          end,
          mark_built: fn "new" ->
            send(owner, {:step, :mark_built})
            :ok
          end,
          restart_instance: fn name ->
            send(owner, {:step, {:restart, name}})
            :ok
          end
        )

      {:ok, pid} = start_supervised({AutoUpdate, auto_update_opts(deps)})

      assert {:ok, snapshot} = AutoUpdate.update_now(pid)
      assert_receive {:step, :build}
      assert_receive {:step, :mark_built}
      assert_receive {:step, {:restart, "default"}}
      assert snapshot.last_update.status == "updated"
    end

    test "does not restart instances when recording the built revision fails" do
      owner = self()

      deps =
        deps(owner,
          dirty?: fn -> {:ok, false, ""} end,
          fetch: fn -> {:ok, %{before_sha: "old", after_sha: "new", changed?: true}} end,
          build: fn -> :ok end,
          mark_built: fn "new" -> {:error, %{message: "marker write failed"}} end,
          restart_instance: fn name ->
            send(owner, {:restart, name})
            :ok
          end
        )

      {:ok, pid} = start_supervised({AutoUpdate, auto_update_opts(deps)})

      assert {:error, snapshot} = AutoUpdate.update_now(pid)
      assert snapshot.last_update.status == "failed"
      assert snapshot.last_update.error =~ "marker write failed"
      assert snapshot.last_update.instance_results == []
      refute_received {:restart, "default"}
    end

    test "restarts idle active instances and defers busy or unsafe instances" do
      owner = self()

      instances = [
        instance("idle", status: "running", running: 0),
        instance("busy", status: "running", running: 2),
        instance("stopped", status: "stopped", running: 0),
        instance("broken", status: "failed", running: 0)
      ]

      deps =
        deps(owner,
          dirty?: fn -> {:ok, false, ""} end,
          fetch: fn -> {:ok, %{before_sha: "old", after_sha: "new", changed?: true}} end,
          build: fn -> :ok end,
          list_instances: fn -> {:ok, instances} end,
          restart_instance: fn name ->
            send(owner, {:restart, name})
            :ok
          end
        )

      {:ok, pid} = start_supervised({AutoUpdate, auto_update_opts(deps)})

      assert {:ok, snapshot} = AutoUpdate.update_now(pid)
      assert_receive {:restart, "idle"}
      refute_received {:restart, "busy"}
      refute_received {:restart, "stopped"}
      refute_received {:restart, "broken"}

      assert snapshot.last_update.status == "updated"
      assert snapshot.current_sha == "new"

      decisions = Map.new(snapshot.last_update.instance_results, &{&1.name, &1})
      assert decisions["idle"].decision == "restarted"
      assert decisions["busy"].decision == "pending_idle"
      assert decisions["stopped"].decision == "updated_not_started"
      assert decisions["broken"].decision == "skipped_failed"
    end
  end

  defp auto_update_opts(deps, opts \\ []) do
    Keyword.merge(
      [
        deps: deps,
        poll_interval_ms: 300_000,
        schedule_poll?: false,
        repo: "jhihjian/symphony",
        branch: "main",
        source_root: "/source",
        name: nil
      ],
      opts
    )
  end

  defp deps(owner, overrides) do
    defaults = %{
      current_revision: fn -> {:ok, "local-sha"} end,
      github_head: fn _headers -> {:ok, %{sha: "local-sha", checked_at: DateTime.utc_now()}} end,
      dirty?: fn -> {:ok, false, ""} end,
      fetch: fn -> {:ok, %{before_sha: "local-sha", after_sha: "remote-sha", changed?: true}} end,
      build: fn -> :ok end,
      build_current?: fn _revision -> true end,
      mark_built: fn _revision -> :ok end,
      list_instances: fn -> {:ok, [instance("default", status: "running", running: 0)]} end,
      restart_instance: fn name ->
        send(owner, {:restart, name})
        :ok
      end,
      now: fn -> ~U[2026-06-10 02:00:00Z] end
    }

    Map.merge(defaults, Map.new(overrides))
  end

  defp instance(name, opts) do
    %{
      name: name,
      service: "symphony@#{name}.service",
      status: Keyword.fetch!(opts, :status),
      counts: %{running: Keyword.fetch!(opts, :running), retrying: 0, blocked: 0},
      strategy: Keyword.get(opts, :strategy, "idle_restart")
    }
  end
end
