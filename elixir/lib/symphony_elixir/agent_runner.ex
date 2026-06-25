defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.{AppServer, DynamicTool}
  alias SymphonyElixir.Linear.Issue

  alias SymphonyElixir.{
    Config,
    StageOutcomeChannel,
    StagePromptRenderer,
    Tracker,
    Workflow,
    Workspace
  }

  alias SymphonyElixir.Workflow.Definition

  @type worker_host :: String.t() | nil
  @type stage_loop :: %{
          required(:workflow) => Definition.t(),
          required(:tracker_config) => map(),
          required(:current_stage) => String.t(),
          required(:missing_outcome_retries) => %{String.t() => non_neg_integer()}
        }

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp send_worker_stage_update(recipient, %Issue{id: issue_id}, stage_id)
       when is_pid(recipient) and is_binary(issue_id) and is_binary(stage_id) do
    send(recipient, {:worker_stage_update, issue_id, stage_id})
    :ok
  end

  defp send_worker_stage_update(_recipient, _issue, _stage_id), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    stage_loop = stage_loop_for_issue(issue, opts)

    app_server_opts = app_server_opts_for_issue(issue, opts, worker_host)

    with {:ok, session} <- AppServer.start_session(workspace, app_server_opts) do
      try do
        do_run_codex_turns(
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          stage_loop,
          1,
          max_turns
        )
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         stage_loop,
         turn_number,
         max_turns
       ) do
    {prompt, run_turn_opts} = build_turn_prompt(issue, opts, stage_loop, turn_number, max_turns)
    outcome_capture = Keyword.get(run_turn_opts, :stage_outcome_capture)

    try do
      with {:ok, turn_session} <-
             AppServer.run_turn(
               app_session,
               prompt,
               issue,
               Keyword.merge(
                 run_turn_opts,
                 on_message: codex_message_handler(codex_update_recipient, issue)
               )
             ) do
        Logger.info(
          "Completed agent run for #{issue_context(issue)} " <>
            "session_id=#{turn_session[:session_id]} workspace=#{workspace} " <>
            "turn=#{turn_number}/#{max_turns}"
        )

        with {:ok, stage_result} <- validate_stage_outcome(outcome_capture),
             :ok <-
               continue_after_turn(
                 issue,
                 stage_loop,
                 stage_result,
                 turn_number,
                 max_turns,
                 app_session,
                 workspace,
                 codex_update_recipient,
                 opts
               ) do
          :ok
        end
      end
    after
      StageOutcomeChannel.stop(outcome_capture)
    end
  end

  defp continue_after_turn(
         issue,
         %{} = stage_loop,
         stage_result,
         turn_number,
         max_turns,
         app_session,
         workspace,
         codex_update_recipient,
         opts
       ) do
    continue_after_stage_turn(
      issue,
      stage_loop,
      stage_result,
      turn_number,
      max_turns,
      app_session,
      workspace,
      codex_update_recipient,
      opts
    )
  end

  defp continue_after_stage_turn(
         issue,
         stage_loop,
         %{target_stage: nil},
         _turn_number,
         _max_turns,
         _app_session,
         _workspace,
         _codex_update_recipient,
         _opts
       ) do
    Logger.info("Reached terminal workflow stage #{stage_loop.current_stage} for #{issue_context(issue)}")
    :ok
  end

  defp continue_after_stage_turn(
         issue,
         stage_loop,
         %{target_stage: next_stage},
         turn_number,
         max_turns,
         app_session,
         workspace,
         codex_update_recipient,
         opts
       )
       when is_binary(next_stage) do
    with :ok <- write_issue_stage(issue, next_stage) do
      send_worker_stage_update(codex_update_recipient, issue, next_stage)

      if terminal_stage?(stage_loop.workflow, next_stage) do
        Logger.info("Workflow stage loop reached terminal stage #{next_stage} for #{issue_context(issue)}")
        :ok
      else
        continue_stage_loop(
          issue,
          %{stage_loop | current_stage: next_stage, missing_outcome_retries: %{}},
          turn_number,
          max_turns,
          app_session,
          workspace,
          codex_update_recipient,
          opts
        )
      end
    end
  end

  defp continue_after_stage_turn(
         issue,
         stage_loop,
         {:error, {:stage_outcome_protocol_error, _reason, _details} = protocol_error},
         turn_number,
         max_turns,
         app_session,
         workspace,
         codex_update_recipient,
         opts
       ) do
    current_stage = stage_loop.current_stage
    retry_count = Map.get(stage_loop.missing_outcome_retries, current_stage, 0)
    max_retries = missing_outcome_max_retries(stage_loop.workflow)

    if retry_count < max_retries do
      Logger.warning(
        "Retrying workflow stage #{current_stage} for #{issue_context(issue)} after missing or invalid stage outcome " <>
          "retry=#{retry_count + 1}/#{max_retries} reason=#{inspect(protocol_error)}"
      )

      retry_loop = %{
        stage_loop
        | missing_outcome_retries: Map.put(stage_loop.missing_outcome_retries, current_stage, retry_count + 1)
      }

      continue_stage_loop(
        issue,
        retry_loop,
        turn_number,
        max_turns,
        app_session,
        workspace,
        codex_update_recipient,
        opts
      )
    else
      exhausted_stage = missing_outcome_on_exhausted(stage_loop.workflow)

      Logger.warning(
        "Workflow stage #{current_stage} exhausted missing outcome retries for #{issue_context(issue)}; " <>
          "writing fallback stage #{exhausted_stage}"
      )

      with :ok <- write_issue_stage(issue, exhausted_stage) do
        send_worker_stage_update(codex_update_recipient, issue, exhausted_stage)

        if terminal_stage?(stage_loop.workflow, exhausted_stage) do
          :ok
        else
          continue_stage_loop(
            issue,
            %{stage_loop | current_stage: exhausted_stage, missing_outcome_retries: %{}},
            turn_number,
            max_turns,
            app_session,
            workspace,
            codex_update_recipient,
            opts
          )
        end
      end
    end
  end

  defp continue_stage_loop(
         issue,
         stage_loop,
         turn_number,
         max_turns,
         app_session,
         workspace,
         codex_update_recipient,
         opts
       ) do
    if turn_number < max_turns do
      Logger.info(
        "Continuing workflow stage loop for #{issue_context(issue)} " <>
          "next_stage=#{stage_loop.current_stage} turn=#{turn_number + 1}/#{max_turns}"
      )

      do_run_codex_turns(
        app_session,
        workspace,
        issue_for_stage(issue, stage_loop.current_stage, stage_loop.tracker_config),
        codex_update_recipient,
        opts,
        stage_loop,
        turn_number + 1,
        max_turns
      )
    else
      Logger.info(
        "Reached agent.max_turns for #{issue_context(issue)} during workflow stage loop " <>
          "stage=#{stage_loop.current_stage}; returning control to orchestrator"
      )

      :ok
    end
  end

  defp build_turn_prompt(issue, opts, %{} = stage_loop, _turn_number, _max_turns) do
    {:ok, %{prompt: prompt, outcome_capture: outcome_capture}} = stage_turn_context(issue, opts, stage_loop)

    {prompt,
     [
       tool_executor: stage_outcome_tool_executor(outcome_capture, opts),
       stage_outcome_capture: outcome_capture
     ]}
  end

  defp app_server_opts_for_issue(_issue, _opts, worker_host) do
    base_opts = [worker_host: worker_host]

    case Workflow.current() do
      {:ok, %{workflow: %Definition{} = workflow}} ->
        dynamic_tools = [StageOutcomeChannel.tool_spec(workflow.outcomes)]
        Keyword.merge(base_opts, dynamic_tools: dynamic_tools)

      _other ->
        base_opts
    end
  end

  defp stage_loop_for_issue(issue, _opts) do
    case Workflow.current() do
      {:ok, %{workflow: %Definition{} = workflow}} ->
        tracker_config = Config.settings!().tracker_config

        case StagePromptRenderer.stage_for_issue(workflow, issue, tracker_config) do
          {:ok, stage_id} ->
            %{
              workflow: workflow,
              tracker_config: tracker_config,
              current_stage: stage_id,
              missing_outcome_retries: %{}
            }

          {:error, reason} ->
            raise RuntimeError, "stage_turn_prompt_unavailable: #{inspect(reason)}"
        end

      {:ok, _workflow} ->
        raise RuntimeError, "stage_turn_prompt_unavailable: workflow stage schema is required"

      {:error, reason} ->
        raise RuntimeError, "stage_turn_prompt_unavailable: #{inspect(reason)}"
    end
  end

  defp stage_turn_context(issue, opts, %{workflow: workflow, tracker_config: tracker_config, current_stage: stage_id}) do
    stage_issue = issue_for_stage(issue, stage_id, tracker_config)
    prompt = StagePromptRenderer.render(workflow, stage_id, stage_issue, opts)
    stage = Map.fetch!(workflow.stages, stage_id)
    outcome_capture = StageOutcomeChannel.new(stage_id, workflow.outcomes, Map.get(stage, "transitions", %{}))

    {:ok, %{workflow: workflow, stage_id: stage_id, prompt: prompt, outcome_capture: outcome_capture}}
  end

  defp stage_outcome_tool_executor(outcome_capture, opts) do
    fallback_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments)
      end)

    fn tool, arguments ->
      if tool == StageOutcomeChannel.tool_name() do
        outcome_capture
        |> StageOutcomeChannel.execute(arguments)
        |> elem(1)
      else
        fallback_executor.(tool, arguments)
      end
    end
  end

  defp validate_stage_outcome(outcome_capture) do
    case outcome_capture do
      nil ->
        {:ok, %{outcome: nil, target_stage: nil, submissions: []}}

      outcome_capture ->
        case StageOutcomeChannel.validate(outcome_capture) do
          {:ok, outcome} -> {:ok, outcome}
          {:error, reason} -> {:ok, {:error, reason}}
        end
    end
  end

  defp write_issue_stage(%Issue{id: issue_id}, next_stage) when is_binary(issue_id) and is_binary(next_stage) do
    case Tracker.write_issue_stage(issue_id, next_stage) do
      :ok -> :ok
      {:error, reason} -> {:error, {:stage_write_failed, issue_id, next_stage, reason}}
    end
  end

  defp write_issue_stage(issue, next_stage), do: {:error, {:stage_write_failed, issue, next_stage, :missing_issue_id}}

  defp issue_for_stage(%Issue{} = issue, stage_id, tracker_config) do
    %Issue{issue | state: provider_state_for_stage(stage_id, tracker_config) || stage_id}
  end

  defp provider_state_for_stage(stage_id, tracker_config) when is_binary(stage_id) and is_map(tracker_config) do
    tracker_config
    |> normalize_keys()
    |> then(&Map.get(&1, "tracker", &1))
    |> Map.get("stage_states", %{})
    |> Map.get(stage_id)
    |> case do
      %{"state" => provider_state} when is_binary(provider_state) -> provider_state
      _ -> nil
    end
  end

  defp provider_state_for_stage(_stage_id, _tracker_config), do: nil

  defp terminal_stage?(%Definition{terminal_stages: terminal_stages}, stage_id) when is_binary(stage_id) do
    stage_id in terminal_stages
  end

  defp missing_outcome_max_retries(%Definition{missing_outcome: missing_outcome}) do
    case Map.get(missing_outcome, "max_retries") do
      retries when is_integer(retries) and retries >= 0 -> retries
      _ -> 0
    end
  end

  defp missing_outcome_on_exhausted(%Definition{missing_outcome: missing_outcome}) do
    Map.fetch!(missing_outcome, "on_exhausted")
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
