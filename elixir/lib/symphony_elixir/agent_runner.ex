defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

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
          with :ok <- Workspace.sync_integration_branch(workspace, worker_host),
               :ok <- Workspace.ensure_issue_feature_branch(workspace, issue, worker_host),
               {:ok, issue} <- maybe_promote_todo_issue(issue),
               :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
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
    with {:ok, session} <- AppServer.start_session(workspace, issue: issue, worker_host: worker_host) do
      try do
        do_run_codex_turn(session, workspace, issue, codex_update_recipient, opts)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turn(app_session, workspace, issue, codex_update_recipient, opts) do
    prompt = PromptBuilder.build_prompt(issue, opts)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace}")
      :ok
    end
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

  defp maybe_promote_todo_issue(%Issue{} = issue) do
    case next_state_after_todo(issue) do
      {:ok, next_state} ->
        Logger.info("Promoting issue to #{next_state} before run #{issue_context(issue)}")

        case Tracker.update_issue_state(issue.id, next_state) do
          :ok ->
            {:ok, %{issue | state: next_state}}

          {:error, reason} ->
            {:error, {:issue_state_transition_failed, next_state, reason}}
        end

      :noop ->
        {:ok, issue}
    end
  end

  defp maybe_promote_todo_issue(issue), do: {:ok, issue}

  defp next_state_after_todo(%Issue{id: issue_id, state: "Todo"}) when is_binary(issue_id) do
    Config.settings!().tracker.active_states
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> find_next_state_after_todo()
  end

  defp next_state_after_todo(_issue), do: :noop

  defp find_next_state_after_todo(["Todo", next_state | _rest]), do: {:ok, next_state}
  defp find_next_state_after_todo([_state | rest]), do: find_next_state_after_todo(rest)
  defp find_next_state_after_todo([]), do: :noop

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
