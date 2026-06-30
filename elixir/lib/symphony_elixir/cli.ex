defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.Hub.Runtime, as: HubRuntime
  alias SymphonyElixir.LogFile
  alias SymphonyElixir.TrackerConfig

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [
    {@acknowledgement_switch, :boolean},
    hub_config: :string,
    hub_provider_executor: :string,
    hub_scheduler: :boolean,
    hub_worker_starter: :string,
    logs_root: :string,
    port: :integer,
    tracker_config: :string
  ]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_tracker_config_file_path: (String.t() -> :ok | {:error, term()}),
          set_hub_config_path: (String.t() -> :ok | {:error, term()}),
          set_hub_provider_executor: (module() | nil -> :ok | {:error, term()}),
          set_hub_scheduler_enabled: (boolean() -> :ok | {:error, term()}),
          validate_hub_config: (String.t() -> :ok | {:error, String.t()}),
          set_hub_worker_starter: (module() | nil -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, positional, []} ->
        evaluate_parsed(opts, positional, deps)

      _ ->
        {:error, usage_message()}
    end
  end

  defp evaluate_parsed(opts, [], deps) do
    if Keyword.has_key?(opts, :hub_config) do
      run_hub(opts, deps)
    else
      with :ok <- require_guardrails_acknowledgement(opts),
           :ok <- maybe_set_logs_root(opts, deps),
           :ok <- maybe_set_server_port(opts, deps) do
        run(Path.expand("WORKFLOW.md"), tracker_config_path(opts), deps)
      end
    end
  end

  defp evaluate_parsed(opts, [workflow_path], deps) do
    if Keyword.has_key?(opts, :hub_config) do
      {:error, hub_usage_error("Do not pass a WORKFLOW.md path with --hub-config")}
    else
      with :ok <- require_guardrails_acknowledgement(opts),
           :ok <- maybe_set_logs_root(opts, deps),
           :ok <- maybe_set_server_port(opts, deps) do
        run(workflow_path, tracker_config_path(opts), deps)
      end
    end
  end

  defp evaluate_parsed(_opts, _positional, _deps), do: {:error, usage_message()}

  defp run_hub(opts, deps) do
    with :ok <- require_guardrails_acknowledgement(opts),
         :ok <- maybe_set_logs_root(opts, deps),
         :ok <- maybe_set_server_port(opts, deps),
         :ok <- maybe_set_hub_scheduler(opts, deps),
         :ok <- maybe_set_hub_provider_executor(opts, deps),
         :ok <- maybe_set_hub_worker_starter(opts, deps),
         {:ok, hub_config_path} <- hub_config_path(opts),
         :ok <- require_regular_file(deps, hub_config_path, "Hub config file not found"),
         :ok <- deps.validate_hub_config.(hub_config_path) do
      :ok = deps.set_hub_config_path.(hub_config_path)
      start_hub(hub_config_path, deps)
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps), do: run(workflow_path, nil, deps)

  @spec run(String.t(), String.t() | nil, deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, tracker_config_path, deps) do
    expanded_path = Path.expand(workflow_path)

    with :ok <- require_regular_file(deps, expanded_path, "Workflow file not found"),
         {:ok, expanded_tracker_config_path} <- expand_optional_tracker_config_path(tracker_config_path),
         :ok <- require_optional_tracker_config(deps, expanded_tracker_config_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)
      :ok = maybe_set_tracker_config_file_path(expanded_tracker_config_path, deps)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony [--logs-root <path>] [--port <port>] [--tracker-config <path-to-TRACKER.yaml>] [path-to-WORKFLOW.md]\n       symphony [--logs-root <path>] [--port <port>] [--hub-scheduler] [--hub-provider-executor skeleton|real-candidate-scan] --hub-config <path-to-HUB.yaml>"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_tracker_config_file_path: &TrackerConfig.set_tracker_file_path/1,
      set_hub_config_path: &HubRuntime.set_config_path/1,
      set_hub_provider_executor: &HubRuntime.set_provider_executor/1,
      set_hub_scheduler_enabled: &HubRuntime.set_scheduler_enabled/1,
      validate_hub_config: &HubRuntime.validate_config/1,
      set_hub_worker_starter: &HubRuntime.set_worker_start_starter/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp maybe_set_hub_worker_starter(opts, deps) do
    case Keyword.get_values(opts, :hub_worker_starter) do
      [] ->
        :ok

      values ->
        values
        |> List.last()
        |> hub_worker_starter_module()
        |> case do
          {:ok, module} -> deps.set_hub_worker_starter.(module)
          {:error, message} -> {:error, message}
        end
    end
  end

  defp maybe_set_hub_provider_executor(opts, deps) do
    case Keyword.get_values(opts, :hub_provider_executor) do
      [] ->
        :ok

      values ->
        values
        |> List.last()
        |> hub_provider_executor_module()
        |> case do
          {:ok, module} -> deps.set_hub_provider_executor.(module)
          {:error, message} -> {:error, message}
        end
    end
  end

  defp maybe_set_hub_scheduler(opts, deps) do
    deps.set_hub_scheduler_enabled.(Keyword.get(opts, :hub_scheduler, false) == true)
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  defp hub_worker_starter_module(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:error, usage_message()}

      "real" ->
        {:ok, SymphonyElixir.Hub.RealWorkerStarter}

      "skeleton" ->
        {:ok, nil}

      other ->
        {:error, "Unsupported --hub-worker-starter #{inspect(other)}. Use `real` or omit the option for the default skeleton."}
    end
  end

  defp hub_worker_starter_module(_value), do: {:error, usage_message()}

  defp hub_provider_executor_module(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:error, usage_message()}

      "real-candidate-scan" ->
        {:ok, SymphonyElixir.Hub.RealCandidateScanExecutor}

      "real_candidate_scan" ->
        {:ok, SymphonyElixir.Hub.RealCandidateScanExecutor}

      "skeleton" ->
        {:ok, nil}

      other ->
        {:error, "Unsupported --hub-provider-executor #{inspect(other)}. Use `real-candidate-scan` or omit the option for the default skeleton."}
    end
  end

  defp hub_provider_executor_module(_value), do: {:error, usage_message()}

  defp hub_config_path(opts) do
    case Keyword.get_values(opts, :hub_config) do
      [] -> {:error, usage_message()}
      values -> values |> List.last() |> normalize_cli_path("Hub config path must not be blank")
    end
  end

  defp tracker_config_path(opts) do
    case Keyword.get_values(opts, :tracker_config) do
      [] -> nil
      values -> List.last(values)
    end
  end

  defp expand_optional_tracker_config_path(nil), do: {:ok, nil}

  defp expand_optional_tracker_config_path(path) when is_binary(path) do
    case String.trim(path) do
      "" -> {:error, usage_message()}
      trimmed -> {:ok, Path.expand(trimmed)}
    end
  end

  defp normalize_cli_path(path, blank_message) when is_binary(path) do
    case String.trim(path) do
      "" -> {:error, blank_message}
      trimmed -> {:ok, Path.expand(trimmed)}
    end
  end

  defp normalize_cli_path(_path, blank_message), do: {:error, blank_message}

  defp require_regular_file(deps, path, message_prefix) do
    if deps.file_regular?.(path), do: :ok, else: {:error, "#{message_prefix}: #{path}"}
  end

  defp require_optional_tracker_config(_deps, nil), do: :ok

  defp require_optional_tracker_config(deps, path) do
    require_regular_file(deps, path, "Tracker config file not found")
  end

  defp maybe_set_tracker_config_file_path(nil, _deps), do: :ok

  defp maybe_set_tracker_config_file_path(path, deps) do
    deps.set_tracker_config_file_path.(path)
  end

  defp start_hub(hub_config_path, deps) do
    case deps.ensure_all_started.() do
      {:ok, _started_apps} ->
        :ok

      {:error, reason} ->
        {:error, "Failed to start Symphony Hub with config #{hub_config_path}: #{inspect(reason)}"}
    end
  end

  defp hub_usage_error(message) do
    "#{message}\n\n#{usage_message()}"
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
