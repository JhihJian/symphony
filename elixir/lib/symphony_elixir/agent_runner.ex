defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

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

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
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
         issue_state_fetcher,
         turn_number,
         max_turns
       ) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    """
    #{PromptBuilder.build_prompt(issue, opts)}

    #{state_route_prompt(issue)}
    """
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    build_continuation_prompt(turn_number, max_turns)
  end

  defp state_route_prompt(%Issue{state: state_name}) do
    case normalize_issue_state(state_name) do
      "todo" -> todo_route_prompt()
      "in progress" -> in_progress_route_prompt()
      "rework" -> rework_route_prompt()
      "human review" -> human_review_route_prompt()
      "merging" -> merging_route_prompt()
      "done" -> done_route_prompt()
      _ -> generic_active_route_prompt(state_name)
    end
  end

  defp state_route_prompt(_issue), do: generic_active_route_prompt(nil)

  defp todo_route_prompt do
    """
    State route: Todo -> In Progress.

    First move the issue to `In Progress`, then create or refresh the single workpad. Before code changes,
    inspect issue context, fill missing execution context from repository/tracker evidence, mirror acceptance
    and validation requirements into the workpad, and record reproduction evidence.

    Next target state: `Human Review` only after implementation, validation, PR linkage, PR feedback sweep,
    green checks, and all workpad completion criteria are satisfied. If a true external blocker remains,
    record it in the workpad and use the workflow's blocker handoff rules.
    """
  end

  defp in_progress_route_prompt do
    """
    State route: In Progress -> Human Review.

    Continue from the existing workspace and workpad. Reconcile current issue context, complete the planned
    implementation, keep acceptance criteria and validation requirements current, run required checks, create
    or update the PR, resolve actionable PR feedback, and attach/link the PR.

    Next target state: `Human Review` only after validation and PR feedback gates are complete. If validation
    or review feedback fails, keep the issue in `In Progress` and continue fixing.
    """
  end

  defp rework_route_prompt do
    """
    State route: Rework -> Human Review.

    Treat reviewer feedback as the driver for this turn. Re-read issue context and all PR/review comments,
    identify what must change, update the workpad, implement the required changes, rerun validation, push the
    branch, and complete the full PR feedback sweep.

    Next target state: `Human Review` only after every actionable feedback item is resolved or explicitly
    answered, validation is green, and the workpad records the result.
    """
  end

  defp human_review_route_prompt do
    """
    State route: Human Review -> Merging or Rework.

    Do not implement new changes just because this turn started. Poll the PR/review state and issue comments.
    If feedback requires changes, move or leave the issue in `Rework` and record the required changes. If a
    human approval is present, wait for or preserve the `Merging` handoff according to the workflow.

    Next target state: `Merging` when approved by a human, or `Rework` when changes are requested.
    """
  end

  defp merging_route_prompt do
    """
    State route: Merging -> Done.

    Execute the workflow's land/merge path exactly as instructed. Do not bypass the land skill or required
    merge checks. After the PR is merged and the post-merge requirements are satisfied, update the workpad.

    Next target state: `Done` after the merge is complete.
    """
  end

  defp done_route_prompt do
    """
    State route: Done.

    The issue is already terminal. Do not change code, ticket content, or PR state. Summarize that no work is
    required and end the turn.
    """
  end

  defp generic_active_route_prompt(state_name) do
    """
    State route: #{state_name || "unknown"}.

    Re-read the issue state and route using the workflow's status map. If the state is active but not one of
    the named workflow states, avoid code changes until the safe next state is clear from tracker context.

    Next target state: use the closest matching workflow transition, and record the routing decision in the
    workpad before acting.
    """
  end

  defp build_continuation_prompt(turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
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

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
