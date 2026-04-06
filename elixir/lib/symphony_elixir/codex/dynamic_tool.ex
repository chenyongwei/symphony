defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Codex.LinearMutationGuard
  alias SymphonyElixir.Linear.Client

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, guard_context} <- LinearMutationGuard.preflight(query, variables, Keyword.put(opts, :linear_client, linear_client)),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response, LinearMutationGuard.postflight(response, guard_context))
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response, control) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response), control)
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload), %{})
  end

  defp dynamic_tool_response(success, output, control)
       when is_boolean(success) and is_binary(output) and is_map(control) do
    base = %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }

    if control == %{} do
      base
    else
      Map.put(base, "control", control)
    end
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:issue_context_unavailable) do
    %{
      "error" => %{
        "message" => "Unable to load the current Linear issue context before applying Symphony policy guards."
      }
    }
  end

  defp tool_error_payload(:target_state_not_found) do
    %{
      "error" => %{
        "message" => "Symphony could not resolve the requested Linear state for this issue."
      }
    }
  end

  defp tool_error_payload(:open_pull_request_required) do
    %{
      "error" => %{
        "message" => "Symphony blocks final review handoff until the current `feature/*` branch has an open pull request."
      }
    }
  end

  defp tool_error_payload(:draft_pull_request_not_reviewable) do
    %{
      "error" => %{
        "message" => "Symphony blocks final review handoff while the pull request is still a draft."
      }
    }
  end

  defp tool_error_payload(:pull_request_template_missing) do
    %{
      "error" => %{
        "message" => "Symphony could not find a PR template in the workspace, so PR body validation could not run."
      }
    }
  end

  defp tool_error_payload(:pull_request_url_missing) do
    %{
      "error" => %{
        "message" => "Symphony could not determine the pull request URL for this branch."
      }
    }
  end

  defp tool_error_payload(:pull_request_context_unavailable) do
    %{
      "error" => %{
        "message" => "Symphony could not load pull request details for the current branch."
      }
    }
  end

  defp tool_error_payload(:pull_request_writeback_failed) do
    %{
      "error" => %{
        "message" => "Symphony could not write the pull request link back to Linear."
      }
    }
  end

  defp tool_error_payload({:pull_request_writeback_failed, reason}) do
    %{
      "error" => %{
        "message" => "Symphony could not write the pull request link back to Linear.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:screenshot_attachments_must_use_comments) do
    %{
      "error" => %{
        "message" => "Symphony blocks screenshot attachments on Linear issues. Post E2E screenshots in Linear comments instead."
      }
    }
  end

  defp tool_error_payload({:screenshot_attachments_disallowed, count}) do
    %{
      "error" => %{
        "message" => "Symphony blocks final review handoff while screenshot evidence is still attached as issue attachments. Move it into Linear comments instead.",
        "attachmentCount" => count
      }
    }
  end

  defp tool_error_payload({:invalid_issue_state_transition, current_state, target_state}) do
    %{
      "error" => %{
        "message" => "Symphony blocks the requested issue state transition.",
        "currentState" => current_state,
        "targetState" => target_state
      }
    }
  end

  defp tool_error_payload({:cross_issue_mutation_blocked, current_issue_id, target_issue_id}) do
    %{
      "error" => %{
        "message" => "Symphony blocks Linear mutations that target a different issue than the active run.",
        "currentIssueId" => current_issue_id,
        "targetIssueId" => target_issue_id
      }
    }
  end

  defp tool_error_payload({:invalid_feature_branch, branch}) do
    %{
      "error" => %{
        "message" => "Symphony requires work to stay on a `feature/*` branch before final review handoff.",
        "branch" => branch
      }
    }
  end

  defp tool_error_payload({:unexpected_issue_branch, branch, expected_branch}) do
    %{
      "error" => %{
        "message" => "Symphony requires each issue to use its dedicated feature branch before final review handoff.",
        "branch" => branch,
        "expectedBranch" => expected_branch
      }
    }
  end

  defp tool_error_payload({:pull_request_not_open, state}) do
    %{
      "error" => %{
        "message" => "Symphony blocks final review handoff unless the pull request is open.",
        "pullRequestState" => state
      }
    }
  end

  defp tool_error_payload({:pull_request_branch_mismatch, pr_branch, current_branch}) do
    %{
      "error" => %{
        "message" => "Symphony blocks final review handoff when the pull request branch does not match the current workspace branch.",
        "pullRequestBranch" => pr_branch,
        "currentBranch" => current_branch
      }
    }
  end

  defp tool_error_payload({:pull_request_title_prefix_missing, identifier, title}) do
    %{
      "error" => %{
        "message" => "Symphony requires PR titles to start with the Linear identifier prefix before final review handoff.",
        "expectedPrefix" => "#{identifier}:",
        "title" => title
      }
    }
  end

  defp tool_error_payload({:pull_request_body_invalid, template_path, errors}) do
    %{
      "error" => %{
        "message" => "Symphony requires the PR body to match the repository template before final review handoff.",
        "templatePath" => template_path,
        "errors" => errors
      }
    }
  end

  defp tool_error_payload(:changes_requested_review_decision) do
    %{
      "error" => %{
        "message" => "Symphony blocks final review handoff while the pull request review decision is still `CHANGES_REQUESTED`."
      }
    }
  end

  defp tool_error_payload({:pending_review_requests, count}) do
    %{
      "error" => %{
        "message" => "Symphony blocks final review handoff while the pull request still has pending review requests.",
        "pendingReviewRequestCount" => count
      }
    }
  end

  defp tool_error_payload(:missing_workspace_context) do
    %{
      "error" => %{
        "message" => "Symphony could not determine the workspace for this run, so final review guards could not execute."
      }
    }
  end

  defp tool_error_payload(:current_branch_unavailable) do
    %{
      "error" => %{
        "message" => "Symphony could not determine the current Git branch for this workspace."
      }
    }
  end

  defp tool_error_payload(:missing_issue_context) do
    %{
      "error" => %{
        "message" => "Symphony could not determine the current Linear issue context for this mutation."
      }
    }
  end

  defp tool_error_payload({:workspace_not_clean, output}) do
    %{
      "error" => %{
        "message" => "Symphony blocks final review handoff while the workspace has tracked local changes.",
        "status" => String.trim(output)
      }
    }
  end

  defp tool_error_payload({:pull_request_branch_not_pushed, branch}) do
    %{
      "error" => %{
        "message" => "Symphony blocks final review handoff until the feature branch exists on `origin`.",
        "branch" => branch
      }
    }
  end

  defp tool_error_payload({:branch_not_pushed, branch, local_head, remote_head}) do
    %{
      "error" => %{
        "message" => "Symphony blocks final review handoff until the current local commit is pushed to `origin`.",
        "branch" => branch,
        "localHead" => local_head,
        "remoteHead" => remote_head
      }
    }
  end

  defp tool_error_payload({:branch_behind_integration, integration_branch}) do
    %{
      "error" => %{
        "message" => "Symphony blocks final review handoff until the branch contains the latest integration branch.",
        "integrationBranch" => integration_branch
      }
    }
  end

  defp tool_error_payload({:workpad_comment_already_exists, comment_id}) do
    %{
      "error" => %{
        "message" => "Symphony allows only one live `## Codex Workpad` comment per issue.",
        "commentId" => comment_id
      }
    }
  end

  defp tool_error_payload({:workpad_comment_missing, comment_id}) do
    %{
      "error" => %{
        "message" => "Symphony could not find the live `## Codex Workpad` comment to update.",
        "commentId" => comment_id
      }
    }
  end

  defp tool_error_payload({:workpad_comment_update_mismatch, existing_comment_id, target_comment_id}) do
    %{
      "error" => %{
        "message" => "Symphony only allows updates to the existing live `## Codex Workpad` comment.",
        "existingCommentId" => existing_comment_id,
        "targetCommentId" => target_comment_id
      }
    }
  end

  defp tool_error_payload({:multiple_workpad_comments, count}) do
    %{
      "error" => %{
        "message" => "Symphony detected multiple live `## Codex Workpad` comments on the issue and refused to continue.",
        "workpadCommentCount" => count
      }
    }
  end

  defp tool_error_payload({:invalid_workpad_structure, errors}) do
    %{
      "error" => %{
        "message" => "Symphony requires the live `## Codex Workpad` comment to match the expected structure.",
        "errors" => errors
      }
    }
  end

  defp tool_error_payload({:git_command_failed, reason}) do
    %{
      "error" => %{
        "message" => "Symphony failed while checking the current Git branch.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:github_command_failed, reason}) do
    %{
      "error" => %{
        "message" => "Symphony failed while checking GitHub pull request state.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:github_json_decode_failed, reason}) do
    %{
      "error" => %{
        "message" => "Symphony received an unexpected GitHub CLI response while enforcing PR guards.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
