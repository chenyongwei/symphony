defmodule SymphonyElixir.Codex.LinearMutationGuard do
  @moduledoc false

  alias SymphonyElixir.{Config, PullRequestBody, SSH, Workpad}

  @issue_context_query """
  query SymphonyIssueGuardContext($issueId: String!) {
    issue(id: $issueId) {
      id
      identifier
      description
      state {
        name
      }
      team {
        states(first: 50) {
          nodes {
            id
            name
            position
            type
          }
        }
      }
      attachments {
        nodes {
          title
          url
          sourceType
        }
      }
      comments(last: 100) {
        nodes {
          id
          body
        }
      }
    }
  }
  """

  @attach_github_pr_mutation """
  mutation SymphonyAttachGitHubPR($issueId: String!, $url: String!, $title: String!) {
    attachmentLinkGitHubPR(issueId: $issueId, url: $url, title: $title, linkKind: links) {
      success
      attachment {
        id
        title
        url
      }
    }
  }
  """

  @attach_url_mutation """
  mutation SymphonyAttachURL($issueId: String!, $url: String!, $title: String!) {
    attachmentLinkURL(issueId: $issueId, url: $url, title: $title) {
      success
      attachment {
        id
        title
        url
      }
    }
  }
  """

  @pull_request_guard_query """
  query SymphonyPullRequestGuard($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        title
        body
        url
        state
        isDraft
        baseRefName
        headRefName
        reviewDecision
        reviewRequests(first: 100) {
          nodes {
            requestedReviewer {
              __typename
            }
          }
        }
      }
    }
  }
  """

  @type linear_client :: (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()})
  @type command_runner ::
          (Path.t(), String.t() | nil, String.t(), [String.t()] -> {:ok, String.t()} | {:error, term()})

  @spec preflight(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def preflight(query, variables, opts) when is_binary(query) and is_map(variables) do
    if screenshot_attachment_mutation?(query, variables) do
      {:error, :screenshot_attachments_must_use_comments}
    else
      with {:ok, workpad_context} <- maybe_guard_comment_mutation(query, variables, opts),
           {:ok, issue_update_context} <- maybe_guard_issue_update(query, variables, opts) do
        {:ok, Map.merge(workpad_context, issue_update_context)}
      end
    end
  end

  @spec postflight(map(), map()) :: map()
  def postflight(%{"data" => %{"issueUpdate" => %{"success" => true}}}, %{
        halt_after_successful_state_transition: state_name
      })
      when is_binary(state_name) do
    %{
      "haltAfterTool" => true,
      "haltReason" => %{
        "type" => "pause_state_entered",
        "state" => state_name
      }
    }
  end

  def postflight(_response, _guard_context), do: %{}

  defp maybe_guard_issue_update(query, variables, opts) do
    case parse_issue_update(query, variables) do
      {:ok, mutation} ->
        guard_issue_update(mutation, opts)

      :nomatch ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_guard_comment_mutation(query, variables, opts) do
    case parse_comment_mutation(query, variables) do
      {:ok, mutation} ->
        guard_comment_mutation(mutation, opts)

      :nomatch ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp guard_issue_update(%{issue_id: issue_id, state_id: state_id}, opts) do
    current_issue = Keyword.get(opts, :issue)
    linear_client = Keyword.fetch!(opts, :linear_client)

    with :ok <- ensure_mutation_targets_current_issue(issue_id, current_issue),
         {:ok, issue_context} <- fetch_issue_context(linear_client, issue_id),
         {:ok, target_state_name} <- resolve_target_state_name(issue_context, state_id),
         :ok <- ensure_allowed_transition(issue_context, target_state_name),
         :ok <- maybe_guard_planning_review_handoff(target_state_name, issue_context),
         :ok <- maybe_guard_review_handoff(target_state_name, issue_context, opts) do
      {:ok, maybe_halt_after_transition(target_state_name, issue_context)}
    end
  end

  defp guard_comment_mutation(%{issue_id: issue_id, body: body} = mutation, opts)
       when is_binary(issue_id) and is_binary(body) do
    current_issue = Keyword.get(opts, :issue)
    linear_client = Keyword.fetch!(opts, :linear_client)

    if Workpad.workpad_comment?(body) do
      with :ok <- ensure_mutation_targets_current_issue(issue_id, current_issue),
           {:ok, issue_context} <- fetch_issue_context(linear_client, issue_id),
           :ok <- ensure_workpad_comment_allowed(issue_context, mutation) do
        {:ok, %{}}
      end
    else
      {:ok, %{}}
    end
  end

  defp guard_comment_mutation(%{type: :update, body: body} = mutation, opts) when is_binary(body) do
    current_issue = Keyword.get(opts, :issue)
    linear_client = Keyword.fetch!(opts, :linear_client)

    if Workpad.workpad_comment?(body) do
      with {:ok, issue_id} <- current_issue_id(current_issue),
           {:ok, issue_context} <- fetch_issue_context(linear_client, issue_id),
           :ok <- ensure_workpad_comment_allowed(issue_context, Map.put(mutation, :issue_id, issue_id)) do
        {:ok, %{}}
      end
    else
      {:ok, %{}}
    end
  end

  defp fetch_issue_context(linear_client, issue_id) do
    with {:ok, response} <- linear_client.(@issue_context_query, %{issueId: issue_id}, []),
         %{} = issue_context <- get_in(response, ["data", "issue"]) do
      {:ok, issue_context}
    else
      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :issue_context_unavailable}
    end
  end

  defp ensure_mutation_targets_current_issue(_issue_id, nil), do: :ok

  defp ensure_mutation_targets_current_issue(issue_id, %{id: current_issue_id})
       when is_binary(issue_id) and is_binary(current_issue_id) do
    if issue_id == current_issue_id do
      :ok
    else
      {:error, {:cross_issue_mutation_blocked, current_issue_id, issue_id}}
    end
  end

  defp ensure_mutation_targets_current_issue(_issue_id, _issue), do: :ok

  defp current_issue_id(%{id: issue_id}) when is_binary(issue_id) and issue_id != "", do: {:ok, issue_id}
  defp current_issue_id(_issue), do: {:error, :missing_issue_context}

  defp resolve_target_state_name(issue_context, state_id) do
    case issue_context
         |> get_in(["team", "states", "nodes"])
         |> List.wrap()
         |> Enum.find(&(Map.get(&1, "id") == state_id)) do
      %{"name" => state_name} when is_binary(state_name) and state_name != "" ->
        {:ok, state_name}

      _ ->
        {:error, :target_state_not_found}
    end
  end

  defp ensure_allowed_transition(issue_context, target_state_name) when is_binary(target_state_name) do
    current_state_name = get_in(issue_context, ["state", "name"])

    cond do
      not is_binary(current_state_name) ->
        :ok

      normalize_state_name(current_state_name) == normalize_state_name(target_state_name) ->
        :ok

      true ->
        case transition_distance(issue_context, current_state_name, target_state_name) do
          {:ok, distance} when abs(distance) == 1 ->
            ensure_not_reverting_to_planning_review(issue_context, current_state_name, target_state_name, distance)

          {:ok, _distance} ->
            {:error, {:invalid_issue_state_transition, current_state_name, target_state_name}}

          :error ->
            :ok
        end
    end
  end

  defp ensure_not_reverting_to_planning_review(
         issue_context,
         current_state_name,
         target_state_name,
         distance
       )
       when is_binary(current_state_name) and is_binary(target_state_name) and is_integer(distance) do
    planning_review_state = planning_review_state_name(issue_context)

    cond do
      distance >= 0 ->
        :ok

      not is_binary(planning_review_state) ->
        :ok

      normalize_state_name(target_state_name) != normalize_state_name(planning_review_state) ->
        :ok

      true ->
        {:error, {:planning_review_reentry_blocked, current_state_name, target_state_name}}
    end
  end

  defp maybe_halt_after_transition(target_state_name, issue_context) do
    if should_halt_after_transition?(issue_context, target_state_name) do
      %{halt_after_successful_state_transition: target_state_name}
    else
      %{}
    end
  end

  defp maybe_guard_planning_review_handoff(target_state_name, issue_context) do
    if planning_review_transition?(issue_context, target_state_name) do
      ensure_plan_review_workpad_ready(issue_context)
    else
      :ok
    end
  end

  defp maybe_guard_review_handoff(target_state_name, issue_context, opts) do
    if review_handoff_transition?(issue_context, target_state_name) do
      guard_code_review(issue_context, opts)
    else
      :ok
    end
  end

  defp guard_code_review(issue_context, opts) do
    workspace = Keyword.get(opts, :workspace)
    worker_host = Keyword.get(opts, :worker_host)
    command_runner = Keyword.get(opts, :command_runner, &default_command_runner/4)
    linear_client = Keyword.fetch!(opts, :linear_client)

    with {:ok, workspace_path} <- normalize_workspace(workspace),
         {:ok, current_branch} <- current_branch(workspace_path, worker_host, command_runner),
         :ok <- refresh_branch_tracking(workspace_path, worker_host, current_branch, command_runner),
         :ok <- ensure_clean_worktree(workspace_path, worker_host, command_runner),
         :ok <- ensure_feature_branch(current_branch, issue_context),
         :ok <- ensure_branch_pushed(workspace_path, worker_host, current_branch, command_runner),
         :ok <- ensure_branch_includes_origin_dev(workspace_path, worker_host, command_runner),
         {:ok, pr_number} <- open_pull_request_number(workspace_path, worker_host, current_branch, command_runner),
         {:ok, pr_details} <- pull_request_details(workspace_path, worker_host, pr_number, command_runner),
         :ok <- ensure_pull_request_ready(pr_details, current_branch, issue_context, workspace_path),
         :ok <- ensure_review_decision_clear(pr_details),
         :ok <- ensure_no_pending_review_requests(pr_details),
         :ok <- ensure_comment_based_screenshot_evidence(issue_context) do
      ensure_pr_written_back(issue_context, pr_details, linear_client)
    end
  end

  defp normalize_workspace(workspace) when is_binary(workspace) and workspace != "", do: {:ok, workspace}
  defp normalize_workspace(_workspace), do: {:error, :missing_workspace_context}

  defp current_branch(workspace, worker_host, command_runner) do
    with {:ok, output} <- run_command(command_runner, workspace, worker_host, "git", ["branch", "--show-current"]),
         branch when is_binary(branch) <- String.trim(output),
         true <- branch != "" do
      {:ok, branch}
    else
      false -> {:error, :current_branch_unavailable}
      {:error, reason} -> {:error, {:git_command_failed, reason}}
    end
  end

  defp refresh_branch_tracking(workspace, worker_host, _current_branch, command_runner) do
    case run_command(command_runner, workspace, worker_host, "git", ["fetch", "origin", "dev"]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:git_command_failed, reason}}
    end
  end

  defp ensure_clean_worktree(workspace, worker_host, command_runner) do
    case run_command(command_runner, workspace, worker_host, "git", [
           "status",
           "--porcelain",
           "--untracked-files=no"
         ]) do
      {:ok, output} ->
        if String.trim(output) == "" do
          :ok
        else
          {:error, {:workspace_not_clean, output}}
        end

      {:error, reason} ->
        {:error, {:git_command_failed, reason}}
    end
  end

  defp ensure_branch_pushed(workspace, worker_host, current_branch, command_runner) do
    with {:ok, remote_head} <- origin_branch_head(workspace, worker_host, current_branch, command_runner),
         {:ok, local_head} <- git_rev_parse(workspace, worker_host, command_runner, "HEAD") do
      if local_head == remote_head do
        :ok
      else
        {:error, {:branch_not_pushed, current_branch, local_head, remote_head}}
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_branch_includes_origin_dev(workspace, worker_host, command_runner) do
    case run_command(command_runner, workspace, worker_host, "git", [
           "merge-base",
           "--is-ancestor",
           "refs/remotes/origin/dev",
           "HEAD"
         ]) do
      {:ok, _output} ->
        :ok

      {:error, {:command_failed, "git", 1, _output}} ->
        {:error, {:branch_behind_integration, "origin/dev"}}

      {:error, reason} ->
        {:error, {:git_command_failed, reason}}
    end
  end

  defp git_rev_parse(workspace, worker_host, command_runner, rev) do
    case run_command(command_runner, workspace, worker_host, "git", ["rev-parse", rev]) do
      {:ok, output} ->
        {:ok, String.trim(output)}

      {:error, {:command_failed, "git", _status, _output}} ->
        {:error, {:git_ref_missing, rev}}

      {:error, reason} ->
        {:error, {:git_command_failed, reason}}
    end
  end

  defp origin_branch_head(workspace, worker_host, current_branch, command_runner) do
    case run_command(command_runner, workspace, worker_host, "git", [
           "ls-remote",
           "--heads",
           "origin",
           current_branch
         ]) do
      {:ok, output} ->
        parse_origin_branch_head(output, current_branch)

      {:error, reason} ->
        {:error, {:git_command_failed, reason}}
    end
  end

  defp ensure_feature_branch(current_branch, issue_context) do
    expected_branch =
      issue_context
      |> Map.get("identifier")
      |> expected_feature_branch()

    cond do
      not String.starts_with?(current_branch, "feature/") ->
        {:error, {:invalid_feature_branch, current_branch}}

      is_binary(expected_branch) and current_branch != expected_branch ->
        {:error, {:unexpected_issue_branch, current_branch, expected_branch}}

      true ->
        :ok
    end
  end

  defp expected_feature_branch(identifier) when is_binary(identifier) and identifier != "" do
    "feature/" <> String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp expected_feature_branch(_identifier), do: nil

  defp open_pull_request_number(workspace, worker_host, branch, command_runner) do
    with {:ok, output} <-
           run_command(command_runner, workspace, worker_host, "gh", [
             "pr",
             "list",
             "--head",
             branch,
             "--state",
             "open",
             "--limit",
             "10",
             "--json",
             "number"
           ]),
         {:ok, payload} <- Jason.decode(output),
         pr_number when is_integer(pr_number) <-
           payload
           |> List.wrap()
           |> Enum.find_value(fn
             %{"number" => number} when is_integer(number) -> number
             _ -> nil
           end) do
      {:ok, pr_number}
    else
      {:error, %Jason.DecodeError{} = reason} ->
        {:error, {:github_json_decode_failed, reason}}

      {:error, reason} ->
        {:error, {:github_command_failed, reason}}

      nil ->
        {:error, :open_pull_request_required}
    end
  end

  defp pull_request_details(workspace, worker_host, pr_number, command_runner) when is_integer(pr_number) do
    args = [
      "api",
      "graphql",
      "-F",
      "owner={owner}",
      "-F",
      "name={repo}",
      "-F",
      "number=#{pr_number}",
      "-f",
      "query=#{@pull_request_guard_query}"
    ]

    with {:ok, output} <- run_command(command_runner, workspace, worker_host, "gh", args),
         {:ok, payload} <- Jason.decode(output),
         %{} = pr_details <- get_in(payload, ["data", "repository", "pullRequest"]) do
      {:ok, pr_details}
    else
      {:error, %Jason.DecodeError{} = reason} ->
        {:error, {:github_json_decode_failed, reason}}

      {:error, reason} ->
        {:error, {:github_command_failed, reason}}

      _ ->
        {:error, :pull_request_context_unavailable}
    end
  end

  defp ensure_pull_request_ready(pr_details, current_branch, issue_context, workspace) do
    with :ok <- ensure_pull_request_open(pr_details),
         :ok <- ensure_pull_request_not_draft(pr_details),
         :ok <- ensure_pull_request_base_branch(pr_details),
         :ok <- ensure_pull_request_branch_matches(pr_details, current_branch),
         :ok <- ensure_pull_request_title_prefix(pr_details, issue_context) do
      ensure_pull_request_body_valid(pr_details, workspace)
    end
  end

  defp ensure_pull_request_open(pr_details) do
    pr_state = Map.get(pr_details, "state")

    if pr_state == "OPEN" do
      :ok
    else
      {:error, {:pull_request_not_open, pr_state}}
    end
  end

  defp ensure_pull_request_not_draft(pr_details) do
    if Map.get(pr_details, "isDraft") == true do
      {:error, :draft_pull_request_not_reviewable}
    else
      :ok
    end
  end

  defp ensure_pull_request_base_branch(pr_details) do
    pr_base_branch = Map.get(pr_details, "baseRefName")
    required_base_branch = "dev"

    if pr_base_branch == required_base_branch do
      :ok
    else
      {:error, {:pull_request_base_branch_mismatch, pr_base_branch, required_base_branch}}
    end
  end

  defp ensure_pull_request_branch_matches(pr_details, current_branch) do
    pr_branch = Map.get(pr_details, "headRefName")

    if pr_branch == current_branch do
      :ok
    else
      {:error, {:pull_request_branch_mismatch, pr_branch, current_branch}}
    end
  end

  defp ensure_pull_request_title_prefix(pr_details, issue_context) do
    identifier = Map.get(issue_context, "identifier")
    title = Map.get(pr_details, "title") || ""

    if pull_request_title_has_issue_prefix?(title, identifier) do
      :ok
    else
      {:error, {:pull_request_title_prefix_missing, identifier, title}}
    end
  end

  defp pull_request_title_has_issue_prefix?(title, identifier)
       when is_binary(title) and is_binary(identifier) do
    pattern = ~r/^#{Regex.escape(identifier)}(?:$|:|：|\s|-|\[)/
    Regex.match?(pattern, title)
  end

  defp pull_request_title_has_issue_prefix?(_title, _identifier), do: false

  defp ensure_pull_request_body_valid(pr_details, workspace) do
    body = Map.get(pr_details, "body") || ""

    case PullRequestBody.validate_body(body, workspace) do
      :ok ->
        :ok

      {:error, {:template_not_found, _paths}} ->
        {:error, :pull_request_template_missing}

      {:error, {:invalid, template_path, errors}} ->
        {:error, {:pull_request_body_invalid, template_path, errors}}
    end
  end

  defp ensure_review_decision_clear(pr_details) do
    if Map.get(pr_details, "reviewDecision") == "CHANGES_REQUESTED" do
      {:error, :changes_requested_review_decision}
    else
      :ok
    end
  end

  defp ensure_no_pending_review_requests(pr_details) do
    request_count =
      pr_details
      |> get_in(["reviewRequests", "nodes"])
      |> List.wrap()
      |> length()

    if request_count == 0 do
      :ok
    else
      {:error, {:pending_review_requests, request_count}}
    end
  end

  defp ensure_pr_written_back(issue_context, pr_details, linear_client) do
    pr_url = Map.get(pr_details, "url")
    issue_id = Map.fetch!(issue_context, "id")
    pr_title = pr_link_title(pr_details)

    cond do
      not is_binary(pr_url) or pr_url == "" ->
        {:error, :pull_request_url_missing}

      issue_references_url?(issue_context, pr_url) ->
        :ok

      true ->
        case attach_pull_request_link(linear_client, issue_id, pr_url, pr_title) do
          :ok -> :ok
          {:error, reason} -> {:error, {:pull_request_writeback_failed, reason}}
        end
    end
  end

  defp attach_pull_request_link(linear_client, issue_id, pr_url, pr_title) do
    variables = %{issueId: issue_id, url: pr_url, title: pr_title}

    case run_attachment_mutation(linear_client, @attach_github_pr_mutation, "attachmentLinkGitHubPR", variables) do
      :ok ->
        :ok

      {:error, github_reason} ->
        case run_attachment_mutation(linear_client, @attach_url_mutation, "attachmentLinkURL", variables) do
          :ok -> :ok
          {:error, url_reason} -> {:error, %{github_pr: github_reason, url_attachment: url_reason}}
        end
    end
  end

  defp run_attachment_mutation(linear_client, mutation, response_key, variables) do
    with {:ok, response} <- linear_client.(mutation, variables, []),
         true <- get_in(response, ["data", response_key, "success"]) == true do
      :ok
    else
      false ->
        {:error, :unsuccessful_response}

      {:ok, response} ->
        {:error, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_references_url?(issue_context, url) do
    attachment_urls =
      issue_context
      |> get_in(["attachments", "nodes"])
      |> List.wrap()
      |> Enum.map(&Map.get(&1, "url"))

    comment_bodies =
      issue_context
      |> get_in(["comments", "nodes"])
      |> List.wrap()
      |> Enum.map(&Map.get(&1, "body"))

    texts =
      attachment_urls ++ comment_bodies ++ [Map.get(issue_context, "description")]

    Enum.any?(texts, fn
      text when is_binary(text) -> String.contains?(text, url)
      _ -> false
    end)
  end

  defp ensure_comment_based_screenshot_evidence(issue_context) do
    screenshot_attachments =
      issue_context
      |> get_in(["attachments", "nodes"])
      |> List.wrap()
      |> Enum.filter(&image_attachment?/1)

    if screenshot_attachments == [] do
      :ok
    else
      {:error, {:screenshot_attachments_disallowed, length(screenshot_attachments)}}
    end
  end

  defp image_attachment?(attachment) when is_map(attachment) do
    haystack =
      [Map.get(attachment, "title"), Map.get(attachment, "url"), Map.get(attachment, "sourceType")]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")

    Regex.match?(~r/(screenshot|screen[-_ ]?shot|e2e|\.png\b|\.jpe?g\b|\.gif\b|\.webp\b|image)/i, haystack)
  end

  defp image_attachment?(_attachment), do: false

  defp ensure_workpad_comment_allowed(issue_context, mutation) do
    workpad_comments = existing_workpad_comments(issue_context)

    if length(workpad_comments) > 1 do
      {:error, {:multiple_workpad_comments, length(workpad_comments)}}
    else
      with :ok <- ensure_workpad_mutation_targets_single_live_comment(workpad_comments, mutation) do
        ensure_workpad_structure(issue_context, mutation.body)
      end
    end
  end

  defp ensure_plan_review_workpad_ready(issue_context) do
    workpad_comments = existing_workpad_comments(issue_context)

    cond do
      length(workpad_comments) > 1 ->
        {:error, {:multiple_workpad_comments, length(workpad_comments)}}

      workpad_comments == [] ->
        {:error, :planning_review_requires_workpad}

      true ->
        [%{"body" => body}] = workpad_comments

        with :ok <- ensure_workpad_structure(issue_context, body) do
          ensure_plan_review_gate_pending(body)
        end
    end
  end

  defp existing_workpad_comments(issue_context) do
    issue_context
    |> get_in(["comments", "nodes"])
    |> List.wrap()
    |> Enum.filter(fn
      %{"body" => body} -> Workpad.workpad_comment?(body)
      _ -> false
    end)
  end

  defp ensure_workpad_mutation_targets_single_live_comment([], %{type: :create}), do: :ok

  defp ensure_workpad_mutation_targets_single_live_comment([], %{type: :update, comment_id: comment_id}) do
    {:error, {:workpad_comment_missing, comment_id}}
  end

  defp ensure_workpad_mutation_targets_single_live_comment([%{"id" => existing_id}], %{
         type: :create
       }) do
    {:error, {:workpad_comment_already_exists, existing_id}}
  end

  defp ensure_workpad_mutation_targets_single_live_comment([%{"id" => existing_id}], %{
         type: :update,
         comment_id: comment_id
       }) do
    if existing_id == comment_id do
      :ok
    else
      {:error, {:workpad_comment_update_mismatch, existing_id, comment_id}}
    end
  end

  defp ensure_workpad_structure(issue_context, body) do
    case Workpad.validate(body,
           plan_gate_required: plan_gate_required?(issue_context)
         ) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_workpad_structure, errors}}
    end
  end

  defp ensure_plan_review_gate_pending(body) when is_binary(body) do
    case Regex.named_captures(
           ~r/###\s+Plan Review Gate[\s\S]*?-\s+Gate status:\s+`(?<status>[^`]+)`/m,
           body
         ) do
      %{"status" => "pending-human-review"} ->
        :ok

      %{"status" => gate_status} ->
        {:error, {:plan_review_gate_not_pending, gate_status}}

      _ ->
        {:error, {:plan_review_gate_not_pending, nil}}
    end
  end

  defp pr_link_title(pr_details) do
    case Map.get(pr_details, "title") do
      title when is_binary(title) and title != "" -> title
      _ -> "Symphony PR link"
    end
  end

  defp parse_issue_update(query, variables) do
    case Regex.named_captures(~r/issueUpdate\s*\((?<args>.*?)\)\s*\{/s, query) do
      %{"args" => args_block} ->
        with {:ok, issue_id} <- extract_argument_value(args_block, "id", variables),
             {:ok, input_value} <- extract_issue_update_input(args_block, variables),
             {:ok, state_id} <- extract_input_field_value(input_value, "stateId", variables) do
          {:ok, %{issue_id: issue_id, state_id: state_id}}
        end

      _ ->
        :nomatch
    end
  end

  defp parse_comment_mutation(query, variables) do
    cond do
      match = Regex.named_captures(~r/commentCreate\s*\(\s*input\s*:\s*\{(?<input>.*?)\}\s*\)\s*\{/s, query) ->
        input_block = Map.fetch!(match, "input")

        with {:ok, issue_id} <- extract_argument_value(input_block, "issueId", variables),
             {:ok, body} <- extract_argument_value(input_block, "body", variables) do
          {:ok, %{type: :create, issue_id: issue_id, body: body}}
        end

      match = Regex.named_captures(~r/commentUpdate\s*\((?<args>.*?)\)\s*\{/s, query) ->
        args_block = Map.fetch!(match, "args")

        with {:ok, comment_id} <- extract_argument_value(args_block, "id", variables),
             {:ok, input_block} <- extract_inline_input(args_block),
             {:ok, body} <- extract_argument_value(input_block, "body", variables) do
          {:ok, %{type: :update, comment_id: comment_id, body: body}}
        end

      true ->
        :nomatch
    end
  end

  defp extract_inline_input(args_block) when is_binary(args_block) do
    case Regex.named_captures(~r/input\s*:\s*\{(?<input>.*)\}\s*$/s, String.trim(args_block)) do
      %{"input" => input_block} -> {:ok, input_block}
      _ -> {:error, :invalid_issue_update_mutation}
    end
  end

  defp extract_issue_update_input(args_block, variables) when is_binary(args_block) and is_map(variables) do
    case Regex.named_captures(~r/input\s*:\s*(?<value>\$[A-Za-z0-9_]+|\{.*\})\s*$/s, String.trim(args_block)) do
      %{"value" => "$" <> variable_name} ->
        case lookup_map_value(variables, variable_name) do
          value when is_map(value) -> {:ok, value}
          _ -> {:error, :invalid_issue_update_mutation}
        end

      %{"value" => value} ->
        {:ok, value |> String.trim() |> String.trim_leading("{") |> String.trim_trailing("}")}

      _ ->
        {:error, :invalid_issue_update_mutation}
    end
  end

  defp extract_input_field_value(input, argument_name, variables)
       when is_binary(input) and is_binary(argument_name) and is_map(variables) do
    extract_argument_value(input, argument_name, variables)
  end

  defp extract_input_field_value(input, argument_name, _variables)
       when is_map(input) and is_binary(argument_name) do
    case lookup_map_value(input, argument_name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_mutation_argument, argument_name}}
    end
  end

  defp extract_argument_value(block, argument_name, variables) do
    case Regex.named_captures(~r/#{Regex.escape(argument_name)}\s*:\s*(?<value>\$[A-Za-z0-9_]+|"(?:[^"\\]|\\.)*")/, block) do
      %{"value" => "$" <> variable_name} ->
        case lookup_map_value(variables, variable_name) do
          value when is_binary(value) and value != "" -> {:ok, value}
          _ -> {:error, {:missing_mutation_variable, variable_name}}
        end

      %{"value" => quoted} ->
        {:ok, quoted |> String.trim_leading("\"") |> String.trim_trailing("\"")}

      _ ->
        {:error, {:missing_mutation_argument, argument_name}}
    end
  end

  defp lookup_map_value(map, key) when is_map(map) and is_binary(key) do
    Enum.find_value(map, fn
      {^key, value} ->
        value

      {map_key, value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: value, else: nil

      _ ->
        nil
    end)
  end

  defp screenshot_attachment_mutation?(query, variables) do
    mutation?(query) and
      Regex.match?(~r/\battachment[a-zA-Z]*\b/i, query) and
      screenshot_like_payload?(query, variables)
  end

  defp mutation?(query), do: String.contains?(String.downcase(query), "mutation")

  defp screenshot_like_payload?(query, variables) do
    haystack =
      [query, inspect(variables, printable_limit: 1_000)]
      |> Enum.join(" ")

    Regex.match?(~r/(screenshot|screen[-_ ]?shot|e2e|\.png\b|\.jpe?g\b|\.gif\b|\.webp\b|image\/(png|jpeg|gif|webp))/i, haystack)
  end

  defp run_command(command_runner, workspace, worker_host, command, args)
       when is_binary(workspace) and is_list(args) do
    case command_runner.(workspace, worker_host, command, args) do
      {:ok, output} when is_binary(output) -> {:ok, output}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_command_runner_response, other}}
    end
  end

  defp default_command_runner(workspace, nil, command, args)
       when is_binary(workspace) and is_binary(command) and is_list(args) do
    case System.find_executable(command) do
      nil ->
        {:error, {:command_not_found, command}}

      executable ->
        case System.cmd(executable, args, cd: workspace, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {:command_failed, command, status, output}}
        end
    end
  end

  defp default_command_runner(workspace, worker_host, command, args)
       when is_binary(workspace) and is_binary(worker_host) and is_binary(command) and is_list(args) do
    remote_command =
      [
        "cd #{shell_escape(workspace)}",
        "exec #{shell_join([command | args])}"
      ]
      |> Enum.join(" && ")

    case SSH.run(worker_host, remote_command, stderr_to_stdout: true) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {:command_failed, command, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp shell_join(parts) when is_list(parts) do
    Enum.map_join(parts, " ", &shell_escape/1)
  end

  defp parse_origin_branch_head(output, current_branch) do
    case output |> String.trim() |> String.split("\n", trim: true) do
      [line | _rest] ->
        parse_origin_branch_head_line(line, output)

      [] ->
        {:error, {:pull_request_branch_not_pushed, current_branch}}
    end
  end

  defp parse_origin_branch_head_line(line, output) do
    case String.split(line, "\t", parts: 2) do
      [sha, _ref] when sha != "" -> {:ok, sha}
      _ -> {:error, {:git_command_failed, {:invalid_ls_remote_output, output}}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp transition_distance(issue_context, current_state_name, target_state_name) do
    with {:ok, current_index} <- state_index(issue_context, current_state_name),
         {:ok, target_index} <- state_index(issue_context, target_state_name) do
      {:ok, target_index - current_index}
    end
  end

  defp should_halt_after_transition?(issue_context, target_state_name) do
    not active_state_name?(target_state_name) and not terminal_state?(issue_context, target_state_name)
  end

  defp review_handoff_transition?(issue_context, target_state_name) do
    current_state_name = get_in(issue_context, ["state", "name"])

    with true <- is_binary(current_state_name),
         {:ok, 1} <- transition_distance(issue_context, current_state_name, target_state_name),
         review_state when is_binary(review_state) <- final_review_state_name(issue_context),
         true <- normalize_state_name(review_state) == normalize_state_name(target_state_name),
         true <- active_state_name?(current_state_name),
         false <- active_state_name?(target_state_name),
         false <- terminal_state?(issue_context, target_state_name),
         true <- review_handoff_source_state?(issue_context, current_state_name, review_state) do
      true
    else
      _ -> false
    end
  end

  defp planning_review_transition?(issue_context, target_state_name) do
    current_state_name = get_in(issue_context, ["state", "name"])

    with true <- is_binary(current_state_name),
         {:ok, 1} <- transition_distance(issue_context, current_state_name, target_state_name),
         planning_review_state when is_binary(planning_review_state) <- planning_review_state_name(issue_context),
         true <- normalize_state_name(planning_review_state) == normalize_state_name(target_state_name),
         true <- active_state_name?(current_state_name),
         false <- active_state_name?(target_state_name),
         false <- terminal_state?(issue_context, target_state_name),
         true <- review_handoff_source_state?(issue_context, current_state_name, planning_review_state) do
      true
    else
      _ -> false
    end
  end

  defp plan_gate_required?(issue_context) do
    planning_review_state_name(issue_context) != nil
  end

  defp state_index(issue_context, state_name) when is_binary(state_name) do
    case Enum.find_index(business_state_sequence(issue_context), fn candidate_name ->
           normalize_state_name(candidate_name) == normalize_state_name(state_name)
         end) do
      nil -> :error
      index -> {:ok, index}
    end
  end

  defp state_index(_issue_context, _state_name), do: :error

  defp business_state_sequence(issue_context) do
    active_states = Config.settings!().tracker.active_states
    planning_review_state = planning_review_state_name(issue_context)
    final_review_state = final_review_state_name(issue_context)

    {states, _final_review_inserted?} =
      Enum.reduce(Enum.with_index(active_states), {[], false}, fn {state_name, index}, {acc, inserted?} ->
        next_acc = acc ++ [state_name]

        next_acc =
          if index == 1 and is_binary(planning_review_state) do
            next_acc ++ [planning_review_state]
          else
            next_acc
          end

        cond do
          inserted? or not is_binary(final_review_state) ->
            {next_acc, inserted?}

          final_review_anchor_index(active_states, planning_review_state, final_review_state) == index ->
            {next_acc ++ [final_review_state], true}

          true ->
            {next_acc, false}
        end
      end)

    states
  end

  defp final_review_anchor_index(active_states, planning_review_state, final_review_state)
       when is_list(active_states) do
    cond do
      not is_binary(final_review_state) or active_states == [] ->
        nil

      is_binary(planning_review_state) and length(active_states) >= 3 ->
        2

      true ->
        length(active_states) - 1
    end
  end

  defp planning_review_state_name(issue_context) do
    preferred_available_state_name(issue_context, ["Plan Review"])
  end

  defp final_review_state_name(issue_context) do
    preferred_available_state_name(issue_context, ["Code Review", "Review"])
  end

  defp review_handoff_source_state?(issue_context, current_state_name, review_state) do
    case state_index(issue_context, review_state) do
      {:ok, review_index} when review_index > 0 ->
        case Enum.at(business_state_sequence(issue_context), review_index - 1) do
          predecessor when is_binary(predecessor) ->
            normalize_state_name(predecessor) == normalize_state_name(current_state_name)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp preferred_available_state_name(issue_context, preferred_names) when is_list(preferred_names) do
    available_names =
      issue_context
      |> get_in(["team", "states", "nodes"])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"name" => state_name} when is_binary(state_name) -> [state_name]
        _ -> []
      end)

    Enum.find_value(preferred_names, fn preferred_name ->
      Enum.find(available_names, fn available_name ->
        normalize_state_name(available_name) == normalize_state_name(preferred_name)
      end)
    end)
  end

  defp workflow_states(issue_context) do
    issue_context
    |> get_in(["team", "states", "nodes"])
    |> List.wrap()
    |> Enum.sort_by(&workflow_state_position/1)
  end

  defp workflow_state_position(%{"position" => position}) when is_number(position), do: position
  defp workflow_state_position(%{position: position}) when is_number(position), do: position
  defp workflow_state_position(_state), do: :infinity

  defp active_state_name?(state_name) when is_binary(state_name) do
    Config.settings!().tracker.active_states
    |> Enum.any?(fn candidate -> normalize_state_name(candidate) == normalize_state_name(state_name) end)
  end

  defp active_state_name?(_state_name), do: false

  defp terminal_state_name?(state_name) when is_binary(state_name) do
    Config.settings!().tracker.terminal_states
    |> Enum.any?(fn candidate -> normalize_state_name(candidate) == normalize_state_name(state_name) end)
  end

  defp terminal_state_name?(_state_name), do: false

  defp terminal_state?(issue_context, state_name) do
    terminal_state_name?(state_name) or completed_state?(issue_context, state_name)
  end

  defp completed_state?(issue_context, state_name) when is_binary(state_name) do
    Enum.any?(workflow_states(issue_context), fn
      %{"name" => candidate_name, "type" => "completed"} when is_binary(candidate_name) ->
        normalize_state_name(candidate_name) == normalize_state_name(state_name)

      _ ->
        false
    end)
  end

  defp completed_state?(_issue_context, _state_name), do: false

  defp normalize_state_name(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end
end
