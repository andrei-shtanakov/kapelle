defmodule Kapelle.Orchestrator.PipelinePersistenceTest do
  use Kapelle.DataCase, async: true

  alias Kapelle.Evaluator.Verdict
  alias Kapelle.Orchestrator.Pipeline
  alias Kapelle.Orchestrator.Records.Decision, as: DecisionRecord
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.Records.RunTask
  alias Kapelle.Orchestrator.Records.Verdict, as: VerdictRecord
  alias Kapelle.Test.BadDurationAdapter
  alias Kapelle.Test.FailingJudge
  alias Kapelle.Test.MismatchedJudge
  alias Kapelle.Test.StubPolicy

  test "run_sync/2 persists a run/run_task/decision/verdict chain linked by FK" do
    task = %{id: "task-persist-1", type: :code_gen}

    assert {:ok, %Verdict{} = verdict} = Pipeline.run_sync(task, [])

    run = Repo.get_by!(Run, task_id: "task-persist-1")
    decision = Repo.get_by!(DecisionRecord, run_id: run.id)
    run_task = Repo.get_by!(RunTask, decision_id: decision.id)
    verdict_row = Repo.get_by!(VerdictRecord, decision_id: decision.id)

    assert run_task.run_id == run.id
    assert run_task.decision_id == decision.id
    assert verdict_row.decision_id == decision.id
    assert decision.id == verdict.decision_id
    assert verdict_row.total_score == verdict.total_score
  end

  test "run_sync/2 returns {:error, changeset} when persistence fails, without returning a Verdict" do
    task = %{id: "task-persist-2", type: :summarize}

    assert {:ok, %Verdict{}} = Pipeline.run_sync(task, policy: StubPolicy)

    assert {:error, %Ecto.Changeset{valid?: false}} =
             Pipeline.run_sync(task, policy: StubPolicy)

    assert Repo.aggregate(Run, :count, :id) == 1
    assert Repo.aggregate(RunTask, :count, :id) == 1
    assert Repo.aggregate(DecisionRecord, :count, :id) == 1
    assert Repo.aggregate(VerdictRecord, :count, :id) == 1
  end

  test "persistence is not invoked when routing fails, so no rows are written" do
    task = %{id: "task-persist-3", type: :unsupported}

    assert {:error, _reason} = Pipeline.run_sync(task, [])

    assert Repo.aggregate(Run, :count, :id) == 0
  end

  test "run_sync/2 skips persistence when the judge returns an error" do
    task = %{id: "task-persist-4", type: :code_gen}

    assert {:error, :judge_failed} = Pipeline.run_sync(task, judge: FailingJudge)

    assert Repo.aggregate(Run, :count, :id) == 0
    assert Repo.aggregate(RunTask, :count, :id) == 0
    assert Repo.aggregate(DecisionRecord, :count, :id) == 0
    assert Repo.aggregate(VerdictRecord, :count, :id) == 0
  end

  test "run_sync/2 rejects a verdict whose decision_id doesn't match the routed decision, leaving no verdict row" do
    task = %{id: "task-persist-5", type: :code_gen}

    assert {:error, :verdict_decision_mismatch} =
             Pipeline.run_sync(task, judge: MismatchedJudge)

    assert Repo.aggregate(Run, :count, :id) == 0
    assert Repo.aggregate(DecisionRecord, :count, :id) == 0
    assert Repo.aggregate(RunTask, :count, :id) == 0
    assert Repo.aggregate(VerdictRecord, :count, :id) == 0
  end

  test "run_sync/2 rolls back the run and decision when the run_task insert fails" do
    task = %{id: "task-persist-6", type: :code_gen}

    assert {:error, %Ecto.Changeset{valid?: false}} =
             Pipeline.run_sync(task, adapter: BadDurationAdapter)

    assert Repo.aggregate(Run, :count, :id) == 0
    assert Repo.aggregate(DecisionRecord, :count, :id) == 0
    assert Repo.aggregate(RunTask, :count, :id) == 0
    assert Repo.aggregate(VerdictRecord, :count, :id) == 0
  end
end
