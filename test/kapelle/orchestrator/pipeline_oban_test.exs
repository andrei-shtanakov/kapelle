defmodule Kapelle.Orchestrator.PipelineObanTest do
  use Kapelle.DataCase, async: true
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Orchestrator.Pipeline
  alias Kapelle.Orchestrator.Records.Decision, as: DecisionRecord
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.Records.RunTask
  alias Kapelle.Orchestrator.Records.Verdict, as: VerdictRecord
  alias Kapelle.Orchestrator.Workers.EvaluateWorker
  alias Kapelle.Test.FailingJudge
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
    assert job.state in ["retryable", "scheduled"]
    assert job.max_attempts > job.attempt

    refute Repo.get_by(VerdictRecord, decision_id: decision.id)
  end
end
