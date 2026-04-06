defmodule SymphonyElixir.AppServerPhaseGuardTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.WorkflowPhase

  test "app server declines mutating command approvals during the inferred planning phase" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-phase-guard-command-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-PLAN-CMD")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-phase-guard-command.trace")

      File.mkdir_p!(workspace)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-phase-guard-command.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-plan-cmd"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-plan-cmd"}}}'
            printf '%s\\n' '{"id":120,"method":"item/commandExecution/requestApproval","params":{"command":"pnpm test","cwd":"/tmp","reason":"needs approval"}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never",
        tracker_active_states: ["Todo", "Scoping", "Delivery"]
      )

      issue = %Issue{
        id: "issue-plan-cmd",
        identifier: "MT-PLAN-CMD",
        title: "Block implementation commands during planning",
        description: "Planning should stay read-only",
        state: "Scoping",
        url: "https://example.org/issues/MT-PLAN-CMD",
        labels: []
      }

      phase_policy =
        WorkflowPhase.current(issue,
          issue_context: %{
            "state" => %{"name" => "Scoping"},
            "team" => %{
              "states" => %{
                "nodes" => [
                  %{"name" => "Todo", "type" => "unstarted"},
                  %{"name" => "Scoping", "type" => "started"},
                  %{"name" => "Needs Blessing", "type" => "backlog"},
                  %{"name" => "Delivery", "type" => "started"},
                  %{"name" => "Done", "type" => "completed"}
                ]
              }
            }
          }
        )

      assert {:ok, _result} =
               AppServer.run(workspace, "Stay in planning", issue, phase_policy: phase_policy)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 120 and get_in(payload, ["result", "decision"]) == "deny"
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server still auto-approves read-only command approvals during the planning phase" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-phase-guard-readonly-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-PLAN-RO")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-phase-guard-readonly.trace")

      File.mkdir_p!(workspace)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-phase-guard-readonly.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-plan-ro"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-plan-ro"}}}'
            printf '%s\\n' '{"id":121,"method":"item/commandExecution/requestApproval","params":{"command":"rg plan src","cwd":"/tmp","reason":"needs approval"}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never",
        tracker_active_states: ["Todo", "Scoping", "Delivery"]
      )

      issue = %Issue{
        id: "issue-plan-ro",
        identifier: "MT-PLAN-RO",
        title: "Allow read-only commands during planning",
        description: "Planning should keep inspection tools available",
        state: "Scoping",
        url: "https://example.org/issues/MT-PLAN-RO",
        labels: []
      }

      phase_policy =
        WorkflowPhase.current(issue,
          issue_context: %{
            "state" => %{"name" => "Scoping"},
            "team" => %{
              "states" => %{
                "nodes" => [
                  %{"name" => "Todo", "type" => "unstarted"},
                  %{"name" => "Scoping", "type" => "started"},
                  %{"name" => "Needs Blessing", "type" => "backlog"},
                  %{"name" => "Delivery", "type" => "started"},
                  %{"name" => "Done", "type" => "completed"}
                ]
              }
            }
          }
        )

      assert {:ok, _result} =
               AppServer.run(workspace, "Inspect only", issue, phase_policy: phase_policy)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 121 and get_in(payload, ["result", "decision"]) == "acceptForSession"
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end
end
