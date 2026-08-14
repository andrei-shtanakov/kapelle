defmodule Kapelle.Orchestrator.PipelineObanTest do
  use Kapelle.DataCase, async: true
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Orchestrator.Persistence
  alias Kapelle.Orchestrator.Pipeline
  alias Kapelle.Orchestrator.Records.Decision, as: DecisionRecord
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.Records.RunTask
  alias Kapelle.Orchestrator.Records.Verdict, as: VerdictRecord
  alias Kapelle.Orchestrator.Workers.EvaluateWorker
  alias Kapelle.Test.FailingJudge
  alias Kapelle.Test.FallbackAdapter
  alias Kapelle.Test.RoutePolicy

  test "draining :orchestrator for an unroutable task fails the job without enqueueing ExecuteWorker" do
    assert {:ok, run_id} =
             Pipeline.submit(%{id: "unroutable", type: :code_gen}, policy: RoutePolicy)

    assert %{success: 0, failure: 1} = Oban.drain_queue(queue: :orchestrator)

    refute Repo.get_by(DecisionRecord, run_id: run_id)
    assert %{success: 0, failure: 0} = Oban.drain_queue(queue: :executor)
  end

  test "submit/2 drains orchestrator -> executor -> evaluator and persists a Verdict" do
    assert {:ok, run_id} = Pipeline.submit(%{id: "task-oban-1", type: :code_gen}, [])

    run = Repo.get!(Run, run_id)
    assert run.status == "pending"

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :orchestrator)
    decision = Repo.get_by!(DecisionRecord, run_id: run_id)

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :executor)
    run_task = Repo.get_by!(RunTask, decision_id: decision.id)
    assert run_task.run_id == run_id

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :evaluator)
    verdict = Repo.get_by!(VerdictRecord, decision_id: decision.id)

    assert verdict.decision_id == decision.id
    assert verdict.task_id == "task-oban-1"

    assert Repo.get!(Run, run_id).status == "completed"

    # Duplicate delivery of the already-processed evaluate job: perform/1's
    # existing-Verdict check short-circuits before re-evaluating, so no
    # second Verdict is recorded and the run stays completed. (The
    # DB-level unique-constraint race between two concurrent first
    # deliveries is covered separately in evaluate_worker_test.exs.)
    assert :ok =
             perform_job(EvaluateWorker, %{
               "run_id" => run_id,
               "run_task_id" => run_task.id,
               "decision_id" => decision.id
             })

    assert Repo.aggregate(VerdictRecord, :count, decision_id: decision.id) == 1
    assert Repo.get!(Run, run_id).status == "completed"
  end

  # REQ-104/TASK-104: drives the fallback chain through the real runtime
  # entrypoint (submit -> RouteWorker -> ExecuteWorker), not a direct
  # FallbackResolver call, proving the wiring holds on the async path too.
  test "submit/2 walks the fallback chain through the real orchestrator/executor workers and persists the walk" do
    assert {:ok, run_id} =
             Pipeline.submit(%{id: "task-oban-fallback-1", type: :code_gen},
               adapter: FallbackAdapter
             )

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :orchestrator)
    decision = Repo.get_by!(DecisionRecord, run_id: run_id)

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :executor)
    run_task = Repo.get_by!(RunTask, decision_id: decision.id)
    result = Persistence.to_contract(run_task)

    assert result.status == :pass
    assert result.target == "anthropic@claude-opus-5"
    assert result.rejected == [{"anthropic@claude-sonnet-5", :provider_down}]

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :evaluator)
    assert Repo.get_by!(VerdictRecord, decision_id: decision.id)
    assert Repo.get!(Run, run_id).status == "completed"
  end

  # REQ-104: every target in the chain erroring ends the run "failed" with
  # the typed exhaustion reason, driven through the real ExecuteWorker
  # rather than a direct resolver call — no crash, no retry storm (the job
  # is discarded on its final attempt, not endlessly retried).
  test "submit/2 exhausting every target in the fallback chain fails the run without persisting a RunTask" do
    assert {:ok, run_id} =
             Pipeline.submit(%{id: "unexecutable", type: :code_gen},
               adapter: Kapelle.Test.ExecuteAdapter
             )

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :orchestrator)
    decision = Repo.get_by!(DecisionRecord, run_id: run_id)

    execute_job =
      Repo.one!(
        from j in Oban.Job,
          where:
            j.worker == ^Oban.Worker.to_string(Kapelle.Orchestrator.Workers.ExecuteWorker) and
              fragment("?->>'decision_id' = ?", j.args, ^decision.id)
      )

    execute_job
    |> Ecto.Changeset.change(max_attempts: 1)
    |> Repo.update!()

    assert %{discard: 1, failure: 0} = Oban.drain_queue(queue: :executor)

    refute Repo.get_by(RunTask, decision_id: decision.id)
    assert %{success: 0, failure: 0} = Oban.drain_queue(queue: :evaluator)
    assert Repo.get!(Run, run_id).status == "failed"
  end

  test "a judge failure in :evaluator leaves the job retryable and persists no Verdict" do
    assert {:ok, run_id} =
             Pipeline.submit(%{id: "task-oban-retry-1", type: :code_gen}, judge: FailingJudge)

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :orchestrator)
    decision = Repo.get_by!(DecisionRecord, run_id: run_id)

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :executor)
    assert Repo.get_by!(RunTask, decision_id: decision.id)

    assert %{success: 0, failure: 1} = Oban.drain_queue(queue: :evaluator)

    job =
      Repo.one!(
        from j in Oban.Job,
          where:
            j.worker == ^Oban.Worker.to_string(EvaluateWorker) and
              fragment("?->>'decision_id' = ?", j.args, ^decision.id)
      )

    assert job.attempt == 1
    assert job.state == "retryable"
    assert job.max_attempts > job.attempt

    refute Repo.get_by(VerdictRecord, decision_id: decision.id)
  end

  test "a judge failure on :evaluator's final attempt fails the Run and persists no Verdict" do
    assert {:ok, run_id} =
             Pipeline.submit(%{id: "task-oban-final-fail", type: :code_gen}, judge: FailingJudge)

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :orchestrator)
    decision = Repo.get_by!(DecisionRecord, run_id: run_id)

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :executor)
    run_task = Repo.get_by!(RunTask, decision_id: decision.id)

    evaluate_job =
      Repo.one!(
        from j in Oban.Job,
          where:
            j.worker == ^Oban.Worker.to_string(EvaluateWorker) and
              fragment("?->>'decision_id' = ?", j.args, ^decision.id)
      )

    evaluate_job
    |> Ecto.Changeset.change(max_attempts: 1)
    |> Repo.update!()

    assert %{discard: 1, failure: 0} = Oban.drain_queue(queue: :evaluator)

    refute Repo.get_by(VerdictRecord, decision_id: decision.id)
    assert Repo.get!(Run, run_id).status == "failed"

    # A second manual drain finds no jobs left to run...
    assert %{success: 0, failure: 0} = Oban.drain_queue(queue: :evaluator)

    # ...and a duplicate delivery of the same discarded job is a no-op:
    # the run was already terminal, so it's discarded again rather than
    # overwriting the failed status.
    assert {:discard, :already_terminal} =
             perform_job(
               EvaluateWorker,
               %{
                 "run_id" => run_id,
                 "run_task_id" => run_task.id,
                 "decision_id" => decision.id
               },
               attempt: 1,
               max_attempts: 1
             )

    refute Repo.get_by(VerdictRecord, decision_id: decision.id)
    assert Repo.get!(Run, run_id).status == "failed"
  end
end
