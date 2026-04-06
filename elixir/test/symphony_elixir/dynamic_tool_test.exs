defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "Plan Progress", "Code Progress"]
    )

    :ok
  end

  test "tool_specs advertises the linear_graphql input contract" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "Linear"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end

  test "linear_graphql blocks invalid workflow state transitions before calling Linear mutations" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Todo"}

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => issue_update_mutation(), "variables" => %{"issueId" => "issue-1", "stateId" => workflow_state_id("Code Review")}},
        issue: issue,
        linear_client: fn query, _variables, _opts ->
          if String.contains?(query, "SymphonyIssueGuardContext") do
            {:ok, %{"data" => %{"issue" => workflow_issue_context("Todo")}}}
          else
            flunk("mutation should be blocked before the original Linear mutation is executed")
          end
        end,
        command_runner: fn _workspace, _worker_host, _command, _args ->
          flunk("git/github checks should not run when the workflow transition is already invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Symphony blocks the requested issue state transition.",
               "currentState" => "Todo",
               "targetState" => "Code Review"
             }
           }
  end

  test "linear_graphql accepts issueUpdate mutations that pass input via a variable object" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Todo"}
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => issue_update_with_input_variable_mutation(),
          "variables" => %{
            "issueId" => "issue-1",
            "input" => %{"stateId" => workflow_state_id("Plan Progress")}
          }
        },
        issue: issue,
        linear_client: fn query, variables, _opts ->
          cond do
            String.contains?(query, "SymphonyIssueGuardContext") ->
              {:ok, %{"data" => %{"issue" => workflow_issue_context("Todo")}}}

            String.contains?(query, "issueUpdate") ->
              send(test_pid, {:issue_update_called, variables})
              {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}

            true ->
              flunk("unexpected Linear query #{query}")
          end
        end
      )

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"issueUpdate" => %{"success" => true}}}

    assert_received {:issue_update_called, %{"issueId" => "issue-1", "input" => %{"stateId" => state_id}}}

    assert state_id == workflow_state_id("Plan Progress")
  end

  test "linear_graphql blocks non-adjacent transitions using the workflow state order" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ["Todo", "Doing"])

    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Todo"}

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => issue_update_mutation(), "variables" => %{"issueId" => "issue-1", "stateId" => workflow_state_id("Review")}},
        issue: issue,
        linear_client: fn query, _variables, _opts ->
          if String.contains?(query, "SymphonyIssueGuardContext") do
            {:ok,
             %{
               "data" => %{
                 "issue" =>
                   workflow_issue_context("Todo",
                     states:
                       workflow_states([
                         {"Todo", "unstarted"},
                         {"Doing", "started"},
                         {"Review", "unstarted"},
                         {"Done", "completed"}
                       ])
                   )
               }
             }}
          else
            flunk("mutation should be blocked before the original Linear mutation is executed")
          end
        end,
        command_runner: fn _workspace, _worker_host, _command, _args ->
          flunk("git/github checks should not run when the workflow transition is already invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Symphony blocks the requested issue state transition.",
               "currentState" => "Todo",
               "targetState" => "Review"
             }
           }
  end

  test "linear_graphql applies review handoff guards using ordered active states instead of fixed review names" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ["Todo", "Doing"])

    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Doing"}
    workspace = workspace_with_pr_template!()

    on_exit(fn -> File.rm_rf!(workspace) end)

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => issue_update_mutation(), "variables" => %{"issueId" => "issue-1", "stateId" => workflow_state_id("Review")}},
        issue: issue,
        workspace: workspace,
        linear_client: fn query, _variables, _opts ->
          if String.contains?(query, "SymphonyIssueGuardContext") do
            {:ok,
             %{
               "data" => %{
                 "issue" =>
                   workflow_issue_context("Doing",
                     states:
                       workflow_states([
                         {"Todo", "unstarted"},
                         {"Doing", "started"},
                         {"Review", "unstarted"},
                         {"Done", "completed"}
                       ])
                   )
               }
             }}
          else
            flunk("original mutation should not run when no PR is open")
          end
        end,
        command_runner: fn _workspace, _worker_host, command, args ->
          case {command, args} do
            {"git", ["branch", "--show-current"]} -> {:ok, "feature/MT-1\n"}
            {"git", ["fetch", "origin", "dev"]} -> {:ok, ""}
            {"git", ["status", "--porcelain", "--untracked-files=no"]} -> {:ok, ""}
            {"git", ["ls-remote", "--heads", "origin", "feature/MT-1"]} -> {:ok, "abc123\trefs/heads/feature/MT-1\n"}
            {"git", ["rev-parse", "HEAD"]} -> {:ok, "abc123\n"}
            {"git", ["merge-base", "--is-ancestor", "refs/remotes/origin/dev", "HEAD"]} -> {:ok, ""}
            {"gh", ["pr", "list", "--head", "feature/MT-1", "--state", "open", "--limit", "10", "--json", "number"]} -> {:ok, "[]"}
            other -> flunk("unexpected command #{inspect(other)}")
          end
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Symphony blocks final review handoff until the current `feature/*` branch has an open pull request."
             }
           }
  end

  test "linear_graphql blocks Code Review without an open pull request" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Code Progress"}
    workspace = workspace_with_pr_template!()

    on_exit(fn -> File.rm_rf!(workspace) end)

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => issue_update_mutation(), "variables" => %{"issueId" => "issue-1", "stateId" => workflow_state_id("Code Review")}},
        issue: issue,
        workspace: workspace,
        linear_client: fn query, _variables, _opts ->
          if String.contains?(query, "SymphonyIssueGuardContext") do
            {:ok, %{"data" => %{"issue" => workflow_issue_context("Code Progress")}}}
          else
            flunk("original mutation should not run when no PR is open")
          end
        end,
        command_runner: fn _workspace, _worker_host, command, args ->
          case {command, args} do
            {"git", ["branch", "--show-current"]} -> {:ok, "feature/MT-1\n"}
            {"git", ["fetch", "origin", "dev"]} -> {:ok, ""}
            {"git", ["status", "--porcelain", "--untracked-files=no"]} -> {:ok, ""}
            {"git", ["ls-remote", "--heads", "origin", "feature/MT-1"]} -> {:ok, "abc123\trefs/heads/feature/MT-1\n"}
            {"git", ["rev-parse", "HEAD"]} -> {:ok, "abc123\n"}
            {"git", ["merge-base", "--is-ancestor", "refs/remotes/origin/dev", "HEAD"]} -> {:ok, ""}
            {"gh", ["pr", "list", "--head", "feature/MT-1", "--state", "open", "--limit", "10", "--json", "number"]} -> {:ok, "[]"}
            other -> flunk("unexpected command #{inspect(other)}")
          end
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Symphony blocks final review handoff until the current `feature/*` branch has an open pull request."
             }
           }
  end

  test "linear_graphql blocks Code Review when the PR title prefix is missing" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Code Progress"}
    workspace = workspace_with_pr_template!()

    on_exit(fn -> File.rm_rf!(workspace) end)

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => issue_update_mutation(), "variables" => %{"issueId" => "issue-1", "stateId" => workflow_state_id("Code Review")}},
        issue: issue,
        workspace: workspace,
        linear_client: fn query, _variables, _opts ->
          if String.contains?(query, "SymphonyIssueGuardContext") do
            {:ok, %{"data" => %{"issue" => workflow_issue_context("Code Progress")}}}
          else
            flunk("original mutation should not run when the PR title prefix is invalid")
          end
        end,
        command_runner:
          successful_review_command_runner(%{
            "title" => "Fix bug",
            "body" => valid_pr_body(),
            "url" => "https://github.com/openai/symphony/pull/42",
            "state" => "OPEN",
            "isDraft" => false,
            "headRefName" => "feature/MT-1",
            "reviewThreads" => %{"nodes" => []},
            "commits" => %{"nodes" => [%{"commit" => %{"statusCheckRollup" => %{"state" => "SUCCESS"}}}]}
          })
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Symphony requires PR titles to start with the Linear identifier prefix before final review handoff.",
               "expectedPrefix" => "MT-1:",
               "title" => "Fix bug"
             }
           }
  end

  test "linear_graphql allows Code Review when PR checks are not green" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Code Progress"}
    workspace = workspace_with_pr_template!()

    on_exit(fn -> File.rm_rf!(workspace) end)

    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => issue_update_mutation(), "variables" => %{"issueId" => "issue-1", "stateId" => workflow_state_id("Code Review")}},
        issue: issue,
        workspace: workspace,
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})

          cond do
            String.contains?(query, "SymphonyIssueGuardContext") ->
              {:ok, %{"data" => %{"issue" => workflow_issue_context("Code Progress")}}}

            String.contains?(query, "commentCreate") ->
              {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}

            String.contains?(query, "issueUpdate") ->
              {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}

            true ->
              flunk("unexpected Linear query #{query}")
          end
        end,
        command_runner:
          successful_review_command_runner(%{
            "title" => "MT-1: Fix bug",
            "body" => valid_pr_body(),
            "url" => "https://github.com/openai/symphony/pull/42",
            "state" => "OPEN",
            "isDraft" => false,
            "headRefName" => "feature/MT-1",
            "reviewThreads" => %{"nodes" => []},
            "commits" => %{"nodes" => [%{"commit" => %{"statusCheckRollup" => %{"state" => "PENDING"}}}]}
          })
      )

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"issueUpdate" => %{"success" => true}}}

    linear_calls = Enum.map(1..3, fn _index -> receive_linear_client_call!() end)

    assert Enum.any?(linear_calls, fn {query, _variables, _opts} ->
             String.contains?(query, "issueUpdate")
           end)
  end

  test "linear_graphql allows Code Review when review threads are unresolved" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Code Progress"}
    workspace = workspace_with_pr_template!()

    on_exit(fn -> File.rm_rf!(workspace) end)

    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => issue_update_mutation(), "variables" => %{"issueId" => "issue-1", "stateId" => workflow_state_id("Code Review")}},
        issue: issue,
        workspace: workspace,
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})

          cond do
            String.contains?(query, "SymphonyIssueGuardContext") ->
              {:ok, %{"data" => %{"issue" => workflow_issue_context("Code Progress")}}}

            String.contains?(query, "commentCreate") ->
              {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}

            String.contains?(query, "issueUpdate") ->
              {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}

            true ->
              flunk("unexpected Linear query #{query}")
          end
        end,
        command_runner:
          successful_review_command_runner(%{
            "title" => "MT-1: Fix bug",
            "body" => valid_pr_body(),
            "url" => "https://github.com/openai/symphony/pull/42",
            "state" => "OPEN",
            "isDraft" => false,
            "headRefName" => "feature/MT-1",
            "reviewThreads" => %{"nodes" => [%{"isResolved" => false}, %{"isResolved" => true}]},
            "commits" => %{"nodes" => [%{"commit" => %{"statusCheckRollup" => %{"state" => "SUCCESS"}}}]}
          })
      )

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"issueUpdate" => %{"success" => true}}}

    linear_calls = Enum.map(1..3, fn _index -> receive_linear_client_call!() end)

    assert Enum.any?(linear_calls, fn {query, _variables, _opts} ->
             String.contains?(query, "issueUpdate")
           end)
  end

  test "linear_graphql blocks Code Review when screenshot evidence is still attached to the issue" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Code Progress"}
    workspace = workspace_with_pr_template!()

    on_exit(fn -> File.rm_rf!(workspace) end)

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => issue_update_mutation(), "variables" => %{"issueId" => "issue-1", "stateId" => workflow_state_id("Code Review")}},
        issue: issue,
        workspace: workspace,
        linear_client: fn query, _variables, _opts ->
          if String.contains?(query, "SymphonyIssueGuardContext") do
            {:ok,
             %{
               "data" => %{
                 "issue" =>
                   workflow_issue_context("Code Progress",
                     attachments: [%{"title" => "e2e-screenshot.png", "url" => "https://linear.app/assets/e2e-screenshot.png", "sourceType" => "upload"}]
                   )
               }
             }}
          else
            flunk("original mutation should not run when screenshot evidence is attached")
          end
        end,
        command_runner:
          successful_review_command_runner(%{
            "title" => "MT-1: Fix bug",
            "body" => valid_pr_body(),
            "url" => "https://github.com/openai/symphony/pull/42",
            "state" => "OPEN",
            "isDraft" => false,
            "headRefName" => "feature/MT-1",
            "reviewThreads" => %{"nodes" => []},
            "commits" => %{"nodes" => [%{"commit" => %{"statusCheckRollup" => %{"state" => "SUCCESS"}}}]}
          })
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Symphony blocks final review handoff while screenshot evidence is still attached as issue attachments. Move it into Linear comments instead.",
               "attachmentCount" => 1
             }
           }
  end

  test "linear_graphql writes back the PR link to Linear before allowing Code Review" do
    test_pid = self()
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Code Progress"}
    workspace = workspace_with_pr_template!()

    on_exit(fn -> File.rm_rf!(workspace) end)

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => issue_update_mutation(), "variables" => %{"issueId" => "issue-1", "stateId" => workflow_state_id("Code Review")}},
        issue: issue,
        workspace: workspace,
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})

          cond do
            String.contains?(query, "SymphonyIssueGuardContext") ->
              {:ok, %{"data" => %{"issue" => workflow_issue_context("Code Progress")}}}

            String.contains?(query, "commentCreate") ->
              {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}

            String.contains?(query, "issueUpdate") ->
              {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}

            true ->
              flunk("unexpected Linear query #{query}")
          end
        end,
        command_runner:
          successful_review_command_runner(%{
            "title" => "MT-1: Fix bug",
            "body" => valid_pr_body(),
            "url" => "https://github.com/openai/symphony/pull/42",
            "state" => "OPEN",
            "isDraft" => false,
            "headRefName" => "feature/MT-1",
            "reviewThreads" => %{"nodes" => []},
            "commits" => %{"nodes" => [%{"commit" => %{"statusCheckRollup" => %{"state" => "SUCCESS"}}}]}
          })
      )

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"issueUpdate" => %{"success" => true}}}

    linear_calls = Enum.map(1..3, fn _index -> receive_linear_client_call!() end)

    assert Enum.any?(linear_calls, fn {query, variables, opts} ->
             opts == [] and issue_id_variable(variables) == "issue-1" and
               String.contains?(query, "SymphonyIssueGuardContext")
           end)

    assert Enum.any?(linear_calls, fn {query, variables, opts} ->
             opts == [] and issue_id_variable(variables) == "issue-1" and
               body_variable(variables) == "Symphony PR link\nhttps://github.com/openai/symphony/pull/42" and
               String.contains?(query, "commentCreate")
           end)

    expected_state_id = workflow_state_id("Code Review")

    assert Enum.any?(linear_calls, fn {query, variables, opts} ->
             opts == [] and issue_id_variable(variables) == "issue-1" and
               state_id_variable(variables) == expected_state_id and
               String.contains?(query, "issueUpdate")
           end)
  end

  test "linear_graphql blocks screenshot attachment mutations for e2e evidence" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => """
          mutation AddAttachment($issueId: String!, $url: String!) {
            attachmentLinkURL(input: {issueId: $issueId, title: "E2E screenshot", url: $url}) {
              success
            }
          }
          """,
          "variables" => %{"issueId" => "issue-1", "url" => "https://example.com/e2e-step.png"}
        },
        linear_client: fn _query, _variables, _opts ->
          flunk("attachment mutation should be blocked before hitting Linear")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Symphony blocks screenshot attachments on Linear issues. Post E2E screenshots in Linear comments instead."
             }
           }
  end

  test "linear_graphql blocks Code Review while the workspace has tracked local changes" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Code Progress"}
    workspace = workspace_with_pr_template!()

    on_exit(fn -> File.rm_rf!(workspace) end)

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => issue_update_mutation(), "variables" => %{"issueId" => "issue-1", "stateId" => workflow_state_id("Code Review")}},
        issue: issue,
        workspace: workspace,
        linear_client: fn query, _variables, _opts ->
          if String.contains?(query, "SymphonyIssueGuardContext") do
            {:ok, %{"data" => %{"issue" => workflow_issue_context("Code Progress")}}}
          else
            flunk("original mutation should not run when the worktree is dirty")
          end
        end,
        command_runner:
          successful_review_command_runner(
            %{
              "title" => "MT-1: Fix bug",
              "body" => valid_pr_body(),
              "url" => "https://github.com/openai/symphony/pull/42",
              "state" => "OPEN",
              "isDraft" => false,
              "headRefName" => "feature/MT-1",
              "reviewDecision" => nil,
              "reviewRequests" => %{"nodes" => []},
              "reviewThreads" => %{"nodes" => []},
              "commits" => %{"nodes" => [%{"commit" => %{"statusCheckRollup" => %{"state" => "SUCCESS"}}}]}
            },
            %{worktree_status: " M README.md\n"}
          )
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "workspace has tracked local changes"
  end

  test "linear_graphql blocks Code Review until the current commit is pushed to origin" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Code Progress"}
    workspace = workspace_with_pr_template!()

    on_exit(fn -> File.rm_rf!(workspace) end)

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => issue_update_mutation(), "variables" => %{"issueId" => "issue-1", "stateId" => workflow_state_id("Code Review")}},
        issue: issue,
        workspace: workspace,
        linear_client: fn query, _variables, _opts ->
          if String.contains?(query, "SymphonyIssueGuardContext") do
            {:ok, %{"data" => %{"issue" => workflow_issue_context("Code Progress")}}}
          else
            flunk("original mutation should not run when the branch head is not pushed")
          end
        end,
        command_runner:
          successful_review_command_runner(
            %{
              "title" => "MT-1: Fix bug",
              "body" => valid_pr_body(),
              "url" => "https://github.com/openai/symphony/pull/42",
              "state" => "OPEN",
              "isDraft" => false,
              "headRefName" => "feature/MT-1",
              "reviewDecision" => nil,
              "reviewRequests" => %{"nodes" => []},
              "reviewThreads" => %{"nodes" => []},
              "commits" => %{"nodes" => [%{"commit" => %{"statusCheckRollup" => %{"state" => "SUCCESS"}}}]}
            },
            %{local_head: "local123", remote_head: "remote456"}
          )
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "current local commit is pushed"
  end

  test "linear_graphql blocks Code Review until the branch contains origin/dev" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Code Progress"}
    workspace = workspace_with_pr_template!()

    on_exit(fn -> File.rm_rf!(workspace) end)

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => issue_update_mutation(), "variables" => %{"issueId" => "issue-1", "stateId" => workflow_state_id("Code Review")}},
        issue: issue,
        workspace: workspace,
        linear_client: fn query, _variables, _opts ->
          if String.contains?(query, "SymphonyIssueGuardContext") do
            {:ok, %{"data" => %{"issue" => workflow_issue_context("Code Progress")}}}
          else
            flunk("original mutation should not run when the branch is behind origin/dev")
          end
        end,
        command_runner:
          successful_review_command_runner(
            %{
              "title" => "MT-1: Fix bug",
              "body" => valid_pr_body(),
              "url" => "https://github.com/openai/symphony/pull/42",
              "state" => "OPEN",
              "isDraft" => false,
              "headRefName" => "feature/MT-1",
              "reviewDecision" => nil,
              "reviewRequests" => %{"nodes" => []},
              "reviewThreads" => %{"nodes" => []},
              "commits" => %{"nodes" => [%{"commit" => %{"statusCheckRollup" => %{"state" => "SUCCESS"}}}]}
            },
            %{merge_base_status: 1}
          )
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["integrationBranch"] == "origin/dev"
  end

  test "linear_graphql blocks Code Review when review decision is changes requested" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Code Progress"}
    workspace = workspace_with_pr_template!()

    on_exit(fn -> File.rm_rf!(workspace) end)

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => issue_update_mutation(), "variables" => %{"issueId" => "issue-1", "stateId" => workflow_state_id("Code Review")}},
        issue: issue,
        workspace: workspace,
        linear_client: fn query, _variables, _opts ->
          if String.contains?(query, "SymphonyIssueGuardContext") do
            {:ok, %{"data" => %{"issue" => workflow_issue_context("Code Progress")}}}
          else
            flunk("original mutation should not run when review decision is changes requested")
          end
        end,
        command_runner:
          successful_review_command_runner(%{
            "title" => "MT-1: Fix bug",
            "body" => valid_pr_body(),
            "url" => "https://github.com/openai/symphony/pull/42",
            "state" => "OPEN",
            "isDraft" => false,
            "headRefName" => "feature/MT-1",
            "reviewDecision" => "CHANGES_REQUESTED",
            "reviewRequests" => %{"nodes" => []},
            "reviewThreads" => %{"nodes" => []},
            "commits" => %{"nodes" => [%{"commit" => %{"statusCheckRollup" => %{"state" => "SUCCESS"}}}]}
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "CHANGES_REQUESTED"
  end

  test "linear_graphql blocks Code Review when pending review requests remain" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Code Progress"}
    workspace = workspace_with_pr_template!()

    on_exit(fn -> File.rm_rf!(workspace) end)

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => issue_update_mutation(), "variables" => %{"issueId" => "issue-1", "stateId" => workflow_state_id("Code Review")}},
        issue: issue,
        workspace: workspace,
        linear_client: fn query, _variables, _opts ->
          if String.contains?(query, "SymphonyIssueGuardContext") do
            {:ok, %{"data" => %{"issue" => workflow_issue_context("Code Progress")}}}
          else
            flunk("original mutation should not run when pending review requests remain")
          end
        end,
        command_runner:
          successful_review_command_runner(%{
            "title" => "MT-1: Fix bug",
            "body" => valid_pr_body(),
            "url" => "https://github.com/openai/symphony/pull/42",
            "state" => "OPEN",
            "isDraft" => false,
            "headRefName" => "feature/MT-1",
            "reviewDecision" => nil,
            "reviewRequests" => %{"nodes" => [%{"requestedReviewer" => %{"__typename" => "User"}}]},
            "reviewThreads" => %{"nodes" => []},
            "commits" => %{"nodes" => [%{"commit" => %{"statusCheckRollup" => %{"state" => "SUCCESS"}}}]}
          })
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["pendingReviewRequestCount"] == 1
  end

  test "linear_graphql blocks duplicate workpad comment creation" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => """
          mutation AddWorkpad($issueId: String!, $body: String!) {
            commentCreate(input: {issueId: $issueId, body: $body}) {
              success
            }
          }
          """,
          "variables" => %{"issueId" => "issue-1", "body" => valid_workpad_body(plan_gate?: true)}
        },
        issue: %Issue{id: "issue-1", identifier: "MT-1", state: "Plan Progress"},
        linear_client: fn query, _variables, _opts ->
          if String.contains?(query, "SymphonyIssueGuardContext") do
            {:ok,
             %{
               "data" => %{
                 "issue" =>
                   workflow_issue_context("Plan Progress",
                     comments: [%{"id" => "comment-9", "body" => valid_workpad_body(plan_gate?: true)}]
                   )
               }
             }}
          else
            flunk("duplicate workpad creation should be blocked before hitting Linear")
          end
        end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["commentId"] == "comment-9"
  end

  test "linear_graphql blocks invalid workpad structure on create" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => """
          mutation AddWorkpad($issueId: String!, $body: String!) {
            commentCreate(input: {issueId: $issueId, body: $body}) {
              success
            }
          }
          """,
          "variables" => %{"issueId" => "issue-1", "body" => "## Codex Workpad\n\n### Plan\n"}
        },
        issue: %Issue{id: "issue-1", identifier: "MT-1", state: "Plan Progress"},
        linear_client: fn query, _variables, _opts ->
          if String.contains?(query, "SymphonyIssueGuardContext") do
            {:ok, %{"data" => %{"issue" => workflow_issue_context("Plan Progress")}}}
          else
            flunk("invalid workpad should be blocked before hitting Linear")
          end
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"])["error"]["message"] =~
             "live `## Codex Workpad` comment to match the expected structure"
  end

  defp issue_update_mutation do
    """
    mutation UpdateIssueState($issueId: String!, $stateId: String!) {
      issueUpdate(id: $issueId, input: {stateId: $stateId}) {
        success
      }
    }
    """
  end

  defp issue_update_with_input_variable_mutation do
    """
    mutation UpdateIssueState($issueId: String!, $input: IssueUpdateInput!) {
      issueUpdate(id: $issueId, input: $input) {
        success
      }
    }
    """
  end

  defp workflow_issue_context(current_state, overrides \\ []) do
    attachments = Keyword.get(overrides, :attachments, [])
    comments = Keyword.get(overrides, :comments, [])
    description = Keyword.get(overrides, :description, "")
    states = Keyword.get(overrides, :states, workflow_states())

    %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "description" => description,
      "state" => %{"name" => current_state},
      "team" => %{"states" => %{"nodes" => states}},
      "attachments" => %{"nodes" => attachments},
      "comments" => %{"nodes" => Enum.map(Enum.with_index(comments, 1), &comment_node/1)}
    }
  end

  defp workflow_states do
    workflow_states([
      {"Todo", "unstarted"},
      {"Plan Progress", "started"},
      {"Plan Review", "unstarted"},
      {"Code Progress", "started"},
      {"Code Review", "started"},
      {"Rework", "started"},
      {"Done", "completed"}
    ])
  end

  defp workflow_states(definitions) when is_list(definitions) do
    Enum.map(definitions, fn {name, type} ->
      %{"id" => workflow_state_id(name), "name" => name, "type" => type}
    end)
  end

  defp workflow_state_id(name) do
    "state-" <> (name |> String.downcase() |> String.replace(" ", "-"))
  end

  defp workspace_with_pr_template! do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dynamic-tool-pr-template-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, ".github"))
    File.write!(Path.join([workspace, ".github", "pull_request_template.md"]), pr_template())
    workspace
  end

  defp pr_template do
    """
    #### Summary

    - Describe the change.

    #### Testing

    - [ ] Ran targeted checks.
    """
  end

  defp valid_pr_body do
    """
    #### Summary

    - Fixed the regression in the issue workflow guard.

    #### Testing

    - [x] Ran targeted checks.
    """
  end

  defp valid_workpad_body(opts) do
    plan_gate? = Keyword.get(opts, :plan_gate?, false)

    """
    ## Codex Workpad

    ```text
    host:/tmp/workspace@abc123
    ```

    ### Plan

    - [ ] 1. Reconcile state

    #{if plan_gate?, do: "### Plan Review Gate\n\n- Gate status: `pending-human-review`\n\n", else: ""}
    ### Acceptance Criteria

    - [ ] Criterion 1

    ### Validation

    - [ ] targeted tests: `mix test`

    #{if plan_gate?, do: "### Evidence\n\n- [ ] PR linked on issue\n\n", else: ""}
    ### Notes

    - 2026-04-06 12:00 SGT: drafted workpad
    """
  end

  defp successful_review_command_runner(pr_details, overrides \\ %{}) do
    branch = Map.get(overrides, :branch, "feature/MT-1")
    local_head = Map.get(overrides, :local_head, "abc123")
    remote_head = Map.get(overrides, :remote_head, local_head)
    worktree_status = Map.get(overrides, :worktree_status, "")
    merge_base_status = Map.get(overrides, :merge_base_status, 0)

    fn _workspace, _worker_host, command, args ->
      successful_review_command_response(
        {command, args},
        branch,
        local_head,
        remote_head,
        worktree_status,
        merge_base_status,
        pr_details
      )
    end
  end

  defp successful_review_command_response(
         {"git", ["branch", "--show-current"]},
         branch,
         _local_head,
         _remote_head,
         _worktree_status,
         _merge_base_status,
         _pr_details
       ),
       do: {:ok, branch <> "\n"}

  defp successful_review_command_response(
         {"git", ["fetch", "origin", "dev"]},
         _branch,
         _local_head,
         _remote_head,
         _worktree_status,
         _merge_base_status,
         _pr_details
       ),
       do: {:ok, ""}

  defp successful_review_command_response(
         {"git", ["status", "--porcelain", "--untracked-files=no"]},
         _branch,
         _local_head,
         _remote_head,
         worktree_status,
         _merge_base_status,
         _pr_details
       ),
       do: {:ok, worktree_status}

  defp successful_review_command_response(
         {"git", ["ls-remote", "--heads", "origin", branch]},
         branch,
         _local_head,
         remote_head,
         _worktree_status,
         _merge_base_status,
         _pr_details
       ),
       do: remote_branch_response(remote_head, branch)

  defp successful_review_command_response(
         {"git", ["rev-parse", "HEAD"]},
         _branch,
         local_head,
         _remote_head,
         _worktree_status,
         _merge_base_status,
         _pr_details
       ),
       do: {:ok, local_head <> "\n"}

  defp successful_review_command_response(
         {"git", ["merge-base", "--is-ancestor", "refs/remotes/origin/dev", "HEAD"]},
         _branch,
         _local_head,
         _remote_head,
         _worktree_status,
         merge_base_status,
         _pr_details
       ),
       do: merge_base_response(merge_base_status)

  defp successful_review_command_response(
         {"gh", ["pr", "list", "--head", branch, "--state", "open", "--limit", "10", "--json", "number"]},
         branch,
         _local_head,
         _remote_head,
         _worktree_status,
         _merge_base_status,
         _pr_details
       ),
       do: {:ok, Jason.encode!([%{"number" => 42}])}

  defp successful_review_command_response(
         {"gh", ["api", "graphql", "-F", "owner={owner}", "-F", "name={repo}", "-F", "number=42", "-f", query]},
         _branch,
         _local_head,
         _remote_head,
         _worktree_status,
         _merge_base_status,
         pr_details
       ) do
    assert String.starts_with?(query, "query=")
    {:ok, Jason.encode!(%{"data" => %{"repository" => %{"pullRequest" => pr_details}}})}
  end

  defp successful_review_command_response(other, _branch, _local_head, _remote_head, _worktree_status, _merge_base_status, _pr_details) do
    flunk("unexpected command #{inspect(other)}")
  end

  defp remote_branch_response(nil, _branch), do: {:ok, ""}
  defp remote_branch_response(remote_head, branch), do: {:ok, "#{remote_head}\trefs/heads/#{branch}\n"}

  defp merge_base_response(0), do: {:ok, ""}
  defp merge_base_response(status), do: {:error, {:command_failed, "git", status, ""}}

  defp receive_linear_client_call! do
    receive do
      {:linear_client_called, query, variables, opts} -> {query, variables, opts}
    after
      1_000 -> flunk("timed out waiting for a Linear client call")
    end
  end

  defp issue_id_variable(variables) when is_map(variables) do
    Map.get(variables, "issueId") || Map.get(variables, :issueId)
  end

  defp state_id_variable(variables) when is_map(variables) do
    Map.get(variables, "stateId") || Map.get(variables, :stateId)
  end

  defp body_variable(variables) when is_map(variables) do
    Map.get(variables, "body") || Map.get(variables, :body)
  end

  defp comment_node({comment, index}) when is_binary(comment) do
    %{"id" => "comment-#{index}", "body" => comment}
  end

  defp comment_node({%{} = comment, _index}) do
    comment
  end
end
