defmodule SymphonyElixir.WorkflowPhaseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.WorkflowPhase

  test "workflow phase infers planning mode from ordered states without relying on workflow names" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "Scoping", "Delivery"]
    )

    issue = %Issue{
      id: "issue-phase-1",
      identifier: "MT-PHASE-1",
      title: "Plan first",
      description: "Infer planning from state order",
      state: "Scoping",
      url: "https://example.org/issues/MT-PHASE-1",
      labels: []
    }

    issue_context = %{
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

    assert %{
             mode: :planning,
             current_state: "Scoping",
             planning_state: "Scoping",
             review_gate_state: "Needs Blessing"
           } = WorkflowPhase.current(issue, issue_context: issue_context)
  end

  test "workflow phase stays unrestricted when there is no human gate between active states" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "Doing"]
    )

    issue = %Issue{
      id: "issue-phase-2",
      identifier: "MT-PHASE-2",
      title: "No plan gate",
      description: "No intermediate human gate",
      state: "Doing",
      url: "https://example.org/issues/MT-PHASE-2",
      labels: []
    }

    issue_context = %{
      "state" => %{"name" => "Doing"},
      "team" => %{
        "states" => %{
          "nodes" => [
            %{"name" => "Todo", "type" => "unstarted"},
            %{"name" => "Doing", "type" => "started"},
            %{"name" => "Done", "type" => "completed"}
          ]
        }
      }
    }

    assert %{mode: :unrestricted, current_state: "Doing"} =
             WorkflowPhase.current(issue, issue_context: issue_context)
  end
end
