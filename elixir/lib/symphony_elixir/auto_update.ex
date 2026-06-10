defmodule SymphonyElixir.AutoUpdate do
  @moduledoc """
  Coordinates Dashboard-controlled updates of the deployed Symphony checkout.

  The process owns polling state and serializes update execution so only one
  git/build/restart flow can run at a time. Expensive and host-specific work is
  delegated through injectable dependencies to keep policy decisions testable.
  """

  use GenServer

  alias SymphonyElixir.InstanceRegistry

  @default_repo "jhihjian/symphony"
  @default_branch "main"
  @default_poll_interval_ms 10 * 60 * 1_000
  @github_api_version "2022-11-28"
  @state_timeout_ms 30_000

  @type snapshot :: map()
  @type deps :: map()

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    if Keyword.get(opts, :enabled?, true) do
      start_opts = start_opts(opts)

      GenServer.start_link(__MODULE__, opts, start_opts)
    else
      :ignore
    end
  end

  defp start_opts(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> []
      {:ok, name} -> [name: name]
      :error -> [name: __MODULE__]
    end
  end

  @spec snapshot(GenServer.server() | keyword()) :: snapshot()
  def snapshot(server_or_opts \\ __MODULE__) do
    GenServer.call(server_from(server_or_opts), :snapshot, @state_timeout_ms)
  end

  @spec check_now(GenServer.server() | keyword()) :: {:ok, snapshot()} | {:error, snapshot()}
  def check_now(server_or_opts \\ __MODULE__) do
    GenServer.call(server_from(server_or_opts), :check_now, @state_timeout_ms)
  end

  @spec update_now(GenServer.server() | keyword()) :: {:ok, snapshot()} | {:error, snapshot()}
  def update_now(server_or_opts \\ __MODULE__) do
    GenServer.call(server_from(server_or_opts), :update_now, :infinity)
  end

  @doc false
  @spec replace_deps(GenServer.server(), deps()) :: :ok
  def replace_deps(server, deps) when is_map(deps) do
    GenServer.call(server, {:replace_deps, deps}, @state_timeout_ms)
  end

  defp server_from(opts) when is_list(opts), do: Keyword.get(opts, :server, __MODULE__)
  defp server_from(server), do: server

  @impl true
  def init(opts) do
    state = initial_state(opts)

    if state.schedule_poll? do
      schedule_poll(state.poll_interval_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, public_snapshot(state), state}
  end

  def handle_call(:check_now, _from, state) do
    {result, state} = run_check(state)
    {:reply, {result, public_snapshot(state)}, state}
  end

  def handle_call(:update_now, _from, state) do
    {result, state} = run_update(state)
    {:reply, {result, public_snapshot(state)}, state}
  end

  def handle_call({:replace_deps, deps}, _from, state) do
    {:reply, :ok, %{state | deps: deps}}
  end

  @impl true
  def handle_info(:poll, state) do
    {_result, state} = run_check(state)

    if state.schedule_poll? do
      schedule_poll(state.poll_interval_ms)
    end

    {:noreply, state}
  end

  defp initial_state(opts) do
    source_root = Keyword.get(opts, :source_root, default_source_root())
    branch = Keyword.get(opts, :branch, @default_branch)
    repo = Keyword.get(opts, :repo, @default_repo)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    deps = Keyword.get_lazy(opts, :deps, fn -> default_deps(source_root, branch, repo) end)
    now = now(deps)

    %{
      repo: repo,
      branch: branch,
      source_root: source_root,
      poll_interval_ms: poll_interval_ms,
      lock_path: Keyword.get(opts, :lock_path, Path.join(System.tmp_dir!(), "symphony-auto-update.lock")),
      schedule_poll?: Keyword.get(opts, :schedule_poll?, true),
      current_sha: nil,
      remote_sha: nil,
      pending_update?: false,
      next_check_at: add_milliseconds(now, poll_interval_ms),
      last_check: %{
        status: "never",
        checked_at: nil,
        etag: nil,
        error: nil,
        rate_limit: %{}
      },
      last_update: %{
        status: "idle",
        started_at: nil,
        finished_at: nil,
        from_sha: nil,
        to_sha: nil,
        error: nil,
        instance_results: []
      },
      deps: deps
    }
  end

  defp public_snapshot(state) do
    state
    |> Map.drop([:deps, :schedule_poll?])
  end

  defp run_check(state) do
    checked_at = now(state.deps)
    {current_sha, current_error} = current_revision(state.deps, state.current_sha)
    headers = conditional_headers(state.last_check.etag)

    case state.deps.github_head.(headers) do
      {:ok, response} ->
        checked_at = Map.get(response, :checked_at, checked_at)
        remote_sha = Map.fetch!(response, :sha)
        etag = Map.get(response, :etag, state.last_check.etag)
        rate_limit = Map.get(response, :rate_limit, %{})

        state = %{
          state
          | current_sha: current_sha,
            remote_sha: remote_sha,
            pending_update?: pending_update?(current_sha, remote_sha),
            next_check_at: add_milliseconds(checked_at, state.poll_interval_ms),
            last_check: %{
              status: "ok",
              checked_at: checked_at,
              etag: etag,
              error: current_error,
              rate_limit: rate_limit
            }
        }

        {:ok, state}

      {:not_modified, response} ->
        checked_at = Map.get(response, :checked_at, checked_at)
        rate_limit = Map.get(response, :rate_limit, %{})

        state = %{
          state
          | current_sha: current_sha,
            pending_update?: pending_update?(current_sha, state.remote_sha),
            next_check_at: add_milliseconds(checked_at, state.poll_interval_ms),
            last_check: %{
              status: "not_modified",
              checked_at: checked_at,
              etag: state.last_check.etag,
              error: current_error,
              rate_limit: rate_limit
            }
        }

        {:ok, state}

      {:error, reason} ->
        state = %{
          state
          | current_sha: current_sha,
            pending_update?: pending_update?(current_sha, state.remote_sha),
            next_check_at: add_milliseconds(checked_at, state.poll_interval_ms),
            last_check: %{
              status: "error",
              checked_at: checked_at,
              etag: state.last_check.etag,
              error: format_error(reason),
              rate_limit: rate_limit(reason)
            }
        }

        {:error, state}
    end
  end

  defp run_update(state) do
    started_at = now(state.deps)

    case acquire_lock(state.lock_path) do
      {:ok, lock_path} ->
        try do
          run_update_locked(state, started_at)
        after
          release_lock(lock_path)
        end

      {:error, :busy} ->
        {:error, fail_update(state, "busy", started_at, nil, "Another Symphony update is already running.", [])}

      {:error, reason} ->
        {:error, fail_update(state, "failed", started_at, nil, format_error(reason), [])}
    end
  end

  defp run_update_locked(state, started_at) do
    with {:dirty, {:ok, false, _status}} <- {:dirty, state.deps.dirty?.()},
         {:fetch, {:ok, revision}} <- {:fetch, state.deps.fetch.()} do
      execute_revision_update(state, started_at, revision)
    else
      {:dirty, {:ok, true, status}} ->
        {:error, fail_update(state, "blocked", started_at, nil, local_changes_error(status), [])}

      {:dirty, {:error, reason}} ->
        {:error, fail_update(state, "failed", started_at, nil, format_error(reason), [])}

      {:fetch, {:error, reason}} ->
        {:error, fail_update(state, "failed", started_at, nil, format_error(reason), [])}
    end
  end

  defp acquire_lock(lock_path) do
    case File.mkdir(lock_path) do
      :ok -> {:ok, lock_path}
      {:error, :eexist} -> {:error, :busy}
      {:error, reason} -> {:error, reason}
    end
  end

  defp release_lock(lock_path), do: File.rm_rf(lock_path)

  defp execute_revision_update(state, started_at, revision) do
    if Map.get(revision, :changed?, false) do
      with {:build, :ok} <- {:build, state.deps.build.()},
           {:instances, {:ok, instances}} <- {:instances, state.deps.list_instances.()} do
        {instance_results, _state} = restart_instances(instances, state)
        finished_at = now(state.deps)
        to_sha = Map.get(revision, :after_sha)

        state = %{
          state
          | current_sha: to_sha,
            pending_update?: pending_update?(to_sha, state.remote_sha),
            last_update: %{
              status: "updated",
              started_at: started_at,
              finished_at: finished_at,
              from_sha: Map.get(revision, :before_sha),
              to_sha: to_sha,
              error: nil,
              instance_results: instance_results
            }
        }

        {:ok, state}
      else
        {:build, {:error, reason}} ->
          {:error, fail_update(state, "failed", started_at, revision, format_error(reason), [])}

        {:instances, {:error, reason}} ->
          {:error, fail_update(state, "failed", started_at, revision, format_error(reason), [])}
      end
    else
      state = up_to_date_update(state, started_at, revision)
      {:ok, state}
    end
  end

  defp up_to_date_update(state, started_at, revision) do
    finished_at = now(state.deps)
    to_sha = Map.get(revision, :after_sha, state.current_sha)

    %{
      state
      | current_sha: to_sha,
        pending_update?: pending_update?(to_sha, state.remote_sha),
        last_update: %{
          status: "up_to_date",
          started_at: started_at,
          finished_at: finished_at,
          from_sha: Map.get(revision, :before_sha, to_sha),
          to_sha: to_sha,
          error: nil,
          instance_results: []
        }
    }
  end

  defp fail_update(state, status, started_at, revision, error, instance_results) do
    finished_at = now(state.deps)

    %{
      state
      | last_update: %{
          status: status,
          started_at: started_at,
          finished_at: finished_at,
          from_sha: revision && Map.get(revision, :before_sha),
          to_sha: revision && Map.get(revision, :after_sha),
          error: error,
          instance_results: instance_results
        }
    }
  end

  defp restart_instances(instances, state) do
    results = Enum.map(instances, &instance_decision(&1, state))
    {results, state}
  end

  defp instance_decision(instance, state) do
    case decision(instance) do
      {:restart, decision_name, reason} ->
        case state.deps.restart_instance.(instance.name) do
          :ok -> result(instance, "restarted", reason)
          {:ok, _payload} -> result(instance, "restarted", reason)
          {:error, error} -> result(instance, "restart_failed", format_error(error))
          error -> result(instance, decision_name, format_error(error))
        end

      {:skip, decision_name, reason} ->
        result(instance, decision_name, reason)
    end
  end

  defp decision(instance) do
    strategy = Map.get(instance, :strategy, Map.get(instance, "strategy", "idle_restart"))
    status = instance_status(instance)
    running = running_count(instance)

    cond do
      strategy == "download_only" ->
        {:skip, "build_only", "strategy downloads and builds without restart"}

      strategy == "manual_restart" ->
        {:skip, "manual_confirmation_required", "strategy requires manual restart confirmation"}

      strategy == "force_restart" ->
        {:restart, "force_restarted", "force restart requested"}

      status == "failed" ->
        {:skip, "skipped_failed", "service is failed; manual intervention required"}

      running > 0 ->
        {:skip, "pending_idle", "#{running} active Symphony session(s)"}

      status in ["running", "active"] ->
        {:restart, "restarted", "active instance is idle"}

      status in ["stopped", "inactive"] ->
        {:skip, "updated_not_started", "inactive instance was updated but not started"}

      true ->
        {:skip, "skipped_unknown", "service status is #{status}"}
    end
  end

  defp result(instance, decision, reason) do
    %{
      name: instance.name,
      service: Map.get(instance, :service, "symphony@#{instance.name}.service"),
      status: instance_status(instance),
      running: running_count(instance),
      strategy: Map.get(instance, :strategy, "idle_restart"),
      decision: decision,
      reason: reason
    }
  end

  defp instance_status(instance), do: Map.get(instance, :status, Map.get(instance, "status", "unknown"))

  defp running_count(instance) do
    counts = Map.get(instance, :counts, Map.get(instance, "counts", %{}))
    value = Map.get(counts, :running, Map.get(counts, "running", 0))
    if is_integer(value), do: value, else: 0
  end

  defp conditional_headers(nil), do: %{}
  defp conditional_headers(""), do: %{}
  defp conditional_headers(etag), do: %{if_none_match: etag}

  defp current_revision(deps, fallback) do
    case deps.current_revision.() do
      {:ok, sha} -> {sha, nil}
      {:error, reason} -> {fallback, format_error(reason)}
    end
  end

  defp pending_update?(current_sha, remote_sha) when is_binary(current_sha) and is_binary(remote_sha) do
    current_sha != remote_sha
  end

  defp pending_update?(_current_sha, _remote_sha), do: false

  defp local_changes_error(status) do
    status = String.trim(to_string(status))
    "Refusing to update because the Symphony repository has local changes" <> local_changes_suffix(status)
  end

  defp local_changes_suffix(""), do: "."
  defp local_changes_suffix(status), do: ":\n" <> status

  defp default_deps(source_root, branch, repo) do
    %{
      current_revision: fn -> git_current_revision(source_root) end,
      github_head: fn headers -> github_head(repo, branch, headers) end,
      dirty?: fn -> git_dirty?(source_root) end,
      fetch: fn -> git_fetch_and_fast_forward(source_root, branch) end,
      build: fn -> build(source_root) end,
      list_instances: fn -> InstanceRegistry.list_instances() end,
      restart_instance: fn name -> restart_instance(name) end,
      now: fn -> DateTime.utc_now() |> DateTime.truncate(:second) end
    }
  end

  defp default_source_root do
    __DIR__
    |> Path.expand("../../..")
    |> Path.expand()
  end

  defp git_current_revision(source_root) do
    case cmd("git", ["-C", source_root, "rev-parse", "HEAD"]) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_dirty?(source_root) do
    ensure_projects_excluded(source_root)

    case cmd("git", ["-C", source_root, "status", "--porcelain", "--", ".", ":(exclude)projects"]) do
      {:ok, output} -> {:ok, String.trim(output) != "", String.trim(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_fetch_and_fast_forward(source_root, branch) do
    with {:ok, before_sha} <- git_current_revision(source_root),
         {:ok, _fetch_output} <- cmd("git", ["-C", source_root, "fetch", "origin", branch]),
         {:ok, _checkout_output} <- cmd("git", ["-C", source_root, "checkout", branch]),
         {:ok, _pull_output} <- cmd("git", ["-C", source_root, "pull", "--ff-only", "origin", branch]),
         {:ok, after_sha} <- git_current_revision(source_root) do
      {:ok, %{before_sha: before_sha, after_sha: after_sha, changed?: before_sha != after_sha}}
    end
  end

  defp build(source_root) do
    app_dir = Path.join(source_root, "elixir")

    with {:ok, _trust_output} <- cmd("mise", ["trust"], cd: app_dir),
         {:ok, _setup_output} <- cmd("mise", ["exec", "--", "mix", "setup"], cd: app_dir),
         {:ok, _build_output} <- cmd("mise", ["exec", "--", "mix", "build"], cd: app_dir) do
      :ok
    end
  end

  defp restart_instance(name) do
    service = "symphony@#{name}.service"

    case cmd("systemctl", ["--user", "restart", service]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_projects_excluded(source_root) do
    with {:ok, git_dir} <- git_dir(source_root) do
      exclude_file = Path.join([git_dir, "info", "exclude"])
      File.mkdir_p!(Path.dirname(exclude_file))

      if !File.exists?(exclude_file) or !String.contains?(File.read!(exclude_file), "/projects/") do
        File.write!(exclude_file, "\n# Symphony runtime directories\n/projects/\n", [:append])
      end
    end
  end

  defp git_dir(source_root) do
    case cmd("git", ["-C", source_root, "rev-parse", "--git-dir"]) do
      {:ok, output} ->
        dir = String.trim(output)
        {:ok, if(Path.type(dir) == :absolute, do: dir, else: Path.join(source_root, dir))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp github_head(repo, branch, headers) do
    url = "https://api.github.com/repos/#{repo}/branches/#{branch}"

    request_headers =
      [
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", @github_api_version},
        {"user-agent", "symphony-auto-update"}
      ]
      |> maybe_add_token_header()
      |> maybe_add_if_none_match(headers)

    case Req.get(url: url, headers: request_headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body} = response} ->
        response_headers = Req.get_headers_list(response)

        {:ok,
         %{
           sha: get_in(body, ["commit", "sha"]),
           etag: header_value(response_headers, "etag"),
           checked_at: DateTime.utc_now() |> DateTime.truncate(:second),
           rate_limit: rate_limit(response_headers)
         }}

      {:ok, %{status: 304} = response} ->
        response_headers = Req.get_headers_list(response)

        {:not_modified,
         %{
           checked_at: DateTime.utc_now() |> DateTime.truncate(:second),
           rate_limit: rate_limit(response_headers)
         }}

      {:ok, %{status: status, body: body} = response} ->
        response_headers = Req.get_headers_list(response)

        {:error,
         %{
           message: "GitHub API returned HTTP #{status}: #{github_error_message(body)}",
           rate_limit: rate_limit(response_headers)
         }}

      {:error, reason} ->
        {:error, %{message: "GitHub API request failed: #{format_error(reason)}"}}
    end
  end

  defp maybe_add_token_header(headers) do
    case System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN") do
      token when is_binary(token) and token != "" -> [{"authorization", "Bearer " <> token} | headers]
      _token -> headers
    end
  end

  defp maybe_add_if_none_match(headers, %{if_none_match: etag}) when is_binary(etag) and etag != "" do
    [{"if-none-match", etag} | headers]
  end

  defp maybe_add_if_none_match(headers, _conditional_headers), do: headers

  defp github_error_message(%{"message" => message}) when is_binary(message), do: message
  defp github_error_message(body), do: inspect(body)

  defp cmd(command, args, opts \\ []) do
    case System.cmd(command, args, Keyword.merge([stderr_to_stdout: true], opts)) do
      {output, 0} -> {:ok, output}
      {output, exit_status} -> {:error, %{exit_status: exit_status, output: String.trim(output)}}
    end
  rescue
    error -> {:error, error}
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, max(interval_ms, 1_000))
  end

  defp now(deps) do
    deps
    |> Map.get(:now, fn -> DateTime.utc_now() |> DateTime.truncate(:second) end)
    |> then(& &1.())
  end

  defp add_milliseconds(%DateTime{} = datetime, milliseconds) when is_integer(milliseconds) do
    datetime
    |> DateTime.add(milliseconds, :millisecond)
    |> DateTime.truncate(:second)
  end

  defp rate_limit(headers) when is_list(headers) do
    %{
      limit: parse_integer(header_value(headers, "x-ratelimit-limit")),
      remaining: parse_integer(header_value(headers, "x-ratelimit-remaining")),
      reset_at: reset_at(header_value(headers, "x-ratelimit-reset")),
      resource: header_value(headers, "x-ratelimit-resource")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp rate_limit(%{rate_limit: rate_limit}) when is_map(rate_limit), do: rate_limit
  defp rate_limit(_reason), do: %{}

  defp header_value(headers, name) when is_list(headers) do
    normalized_name = String.downcase(name)

    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == normalized_name, do: value

      _header ->
        nil
    end)
  end

  defp parse_integer(nil), do: nil

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> nil
    end
  end

  defp reset_at(nil), do: nil

  defp reset_at(value) do
    case parse_integer(value) do
      nil -> nil
      seconds -> DateTime.from_unix!(seconds) |> DateTime.to_iso8601()
    end
  end

  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(%{output: output}) when is_binary(output) and output != "", do: output
  defp format_error(%{exit_status: exit_status}), do: "exit status #{exit_status}"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
