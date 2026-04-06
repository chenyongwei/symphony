defmodule SymphonyElixir.Codex.WorkflowPhase do
  @moduledoc false

  alias SymphonyElixir.{Config, Linear.Client}

  @issue_phase_context_query """
  query SymphonyIssuePhaseContext($issueId: String!) {
    issue(id: $issueId) {
      id
      state {
        name
      }
      team {
        states(first: 50) {
          nodes {
            name
            type
          }
        }
      }
    }
  }
  """

  @type policy :: %{
          mode: :planning | :unrestricted,
          current_state: String.t() | nil,
          planning_state: String.t() | nil,
          review_gate_state: String.t() | nil
        }

  @spec current(map(), keyword()) :: policy()
  def current(issue, opts \\ []) do
    issue_context =
      Keyword.get_lazy(opts, :issue_context, fn ->
        fetch_issue_context(issue, Keyword.get(opts, :linear_client, &Client.graphql/3))
      end)

    infer(issue_context, issue)
  end

  @spec planning_restricted?(policy()) :: boolean()
  def planning_restricted?(%{mode: :planning}), do: true
  def planning_restricted?(_policy), do: false

  defp infer(%{} = issue_context, issue) do
    states = workflow_states(issue_context)
    current_state = issue_context |> get_in(["state", "name"]) || issue_state(issue)

    with {:ok, planning_index} <- planning_state_index(states),
         {:ok, review_gate_index} <- review_gate_index(states, planning_index),
         true <- state_index_matches?(states, current_state, planning_index) do
      %{
        mode: :planning,
        current_state: current_state,
        planning_state: state_name_at(states, planning_index),
        review_gate_state: state_name_at(states, review_gate_index)
      }
    else
      _ ->
        unrestricted_policy(current_state)
    end
  end

  defp infer(_issue_context, issue), do: unrestricted_policy(issue_state(issue))

  defp unrestricted_policy(current_state) do
    %{
      mode: :unrestricted,
      current_state: current_state,
      planning_state: nil,
      review_gate_state: nil
    }
  end

  defp fetch_issue_context(issue, linear_client) when is_function(linear_client, 3) do
    with issue_id when is_binary(issue_id) and issue_id != "" <- issue_id(issue),
         "linear" <- Config.settings!().tracker.kind,
         {:ok, response} <- linear_client.(@issue_phase_context_query, %{issueId: issue_id}, []),
         %{} = issue_context <- get_in(response, ["data", "issue"]) do
      issue_context
    else
      _ -> nil
    end
  end

  defp planning_state_index(states) do
    with {:ok, todo_index} <- state_index(states, "Todo") do
      if todo_index + 1 >= length(states) do
        :error
      else
        case Enum.find((todo_index + 1)..(length(states) - 1), fn index ->
               active_state_node?(Enum.at(states, index))
             end) do
          planning_index when is_integer(planning_index) -> {:ok, planning_index}
          _ -> :error
        end
      end
    end
  end

  defp review_gate_index(states, planning_index) when is_integer(planning_index) do
    last_active_index = last_active_state_index(states)

    cond do
      is_nil(last_active_index) or planning_index >= last_active_index ->
        :error

      true ->
        case Enum.find((planning_index + 1)..last_active_index, fn index ->
               index < last_active_index and review_gate_state_node?(Enum.at(states, index))
             end) do
          index when is_integer(index) -> {:ok, index}
          _ -> :error
        end
    end
  end

  defp state_index_matches?(states, state_name, expected_index)
       when is_binary(state_name) and is_integer(expected_index) do
    case state_index(states, state_name) do
      {:ok, ^expected_index} -> true
      _ -> false
    end
  end

  defp state_index_matches?(_states, _state_name, _expected_index), do: false

  defp state_index(states, state_name) when is_list(states) and is_binary(state_name) do
    case Enum.find_index(states, fn
           %{"name" => candidate_name} when is_binary(candidate_name) ->
             normalize_state_name(candidate_name) == normalize_state_name(state_name)

           _ ->
             false
         end) do
      nil -> :error
      index -> {:ok, index}
    end
  end

  defp state_index(_states, _state_name), do: :error

  defp last_active_state_index(states) when is_list(states) do
    states
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {%{} = state, index}, acc ->
        if active_state_node?(state), do: index, else: acc

      _, acc ->
        acc
    end)
  end

  defp review_gate_state_node?(%{"type" => type} = state) when is_binary(type) do
    not active_state_node?(state) and type not in ["completed", "canceled"]
  end

  defp review_gate_state_node?(state), do: not active_state_node?(state) and not completed_state_node?(state)

  defp active_state_node?(%{"name" => state_name}) when is_binary(state_name) do
    Config.settings!().tracker.active_states
    |> Enum.any?(fn candidate -> normalize_state_name(candidate) == normalize_state_name(state_name) end)
  end

  defp active_state_node?(_state), do: false

  defp completed_state_node?(%{"type" => type}) when is_binary(type), do: type == "completed"
  defp completed_state_node?(_state), do: false

  defp workflow_states(issue_context) do
    issue_context
    |> get_in(["team", "states", "nodes"])
    |> List.wrap()
  end

  defp state_name_at(states, index) when is_list(states) and is_integer(index) do
    case Enum.at(states, index) do
      %{"name" => state_name} when is_binary(state_name) -> state_name
      _ -> nil
    end
  end

  defp normalize_state_name(state_name) when is_binary(state_name) do
    state_name |> String.trim() |> String.downcase()
  end

  defp issue_id(%{id: issue_id}) when is_binary(issue_id), do: issue_id
  defp issue_id(%{"id" => issue_id}) when is_binary(issue_id), do: issue_id
  defp issue_id(_issue), do: nil

  defp issue_state(%{state: state_name}) when is_binary(state_name), do: state_name
  defp issue_state(%{"state" => state_name}) when is_binary(state_name), do: state_name
  defp issue_state(_issue), do: nil
end
