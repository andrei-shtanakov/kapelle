defmodule KapelleWeb.RunLiveTest do
  use KapelleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Kapelle.Evaluator.Verdict
  alias Kapelle.Executor.Result
  alias Kapelle.Orchestrator.Persistence
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.RunEvents
  alias Kapelle.Repo
  alias Kapelle.Router.Decision

  defp insert_pending_run!(task_id) do
    %{id: task_id}
    |> Persistence.pending_run_changeset()
    |> Repo.insert!()
  end

  defp insert_decision!(run_id, task_id) do
    decision =
      Decision.new!(%{
        decision_id: Ecto.UUID.generate(),
        task_id: task_id,
        target: %{provider: "anthropic", model: "claude-sonnet-5"},
        decided_at: DateTime.utc_now()
      })

    {:ok, decision_record} = Persistence.record_decision(run_id, decision)
    decision_record
  end

  test "shows the task id and status for a run with no decision yet", %{conn: conn} do
    {:ok, run} = Persistence.create_run(%{id: "task-abc-123"})

    {:ok, _live, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ run.task_id
    assert html =~ run.status
  end

  test "shows the decision's routed target once the run has been routed", %{conn: conn} do
    run = insert_pending_run!("task-1")
    insert_decision!(run.id, "task-1")

    {:ok, _live, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "anthropic"
    assert html =~ "claude-sonnet-5"
  end

  test "shows the result status and verdict score once the run has been executed and evaluated",
       %{
         conn: conn
       } do
    run = insert_pending_run!("task-1")
    decision = insert_decision!(run.id, "task-1")

    result = Result.new!(%{task_id: "task-1", status: :pass, duration_ms: 42})
    {:ok, _run_task} = Persistence.record_run_task(run.id, decision.id, result)

    verdict =
      Verdict.new!(%{decision_id: decision.id, task_id: "task-1", total_score: 0.75})

    {:ok, _verdict_record} = Persistence.record_verdict(decision.id, verdict)

    {:ok, _live, html} = live(conn, ~p"/runs/#{run.id}")

    assert html =~ "pass"
    assert html =~ "0.75"
  end

  test "raises Ecto.NoResultsError for a run id that doesn't exist", %{conn: conn} do
    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/runs/#{Ecto.UUID.generate()}")
    end
  end

  test "updates the rendered status when the run's state changes over PubSub, without a reload",
       %{conn: conn} do
    run = insert_pending_run!("task-1")

    {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")
    assert html =~ "pending"

    run
    |> Run.status_changeset("completed")
    |> Repo.update!()

    :ok = RunEvents.broadcast(run.id)

    assert render(view) =~ "completed"
  end

  test "updates to show the decision once one is recorded after the initial mount, without a reload",
       %{conn: conn} do
    run = insert_pending_run!("task-1")

    {:ok, view, html} = live(conn, ~p"/runs/#{run.id}")
    refute html =~ "claude-sonnet-5"

    insert_decision!(run.id, "task-1")
    :ok = RunEvents.broadcast(run.id)

    assert render(view) =~ "claude-sonnet-5"
  end
end
