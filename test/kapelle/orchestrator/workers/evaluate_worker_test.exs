defmodule Kapelle.Orchestrator.Workers.EvaluateWorkerTest do
  use Kapelle.DataCase, async: true
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Executor.Result
  alias Kapelle.Orchestrator.Persistence
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.Records.Verdict, as: VerdictRecord
  alias Kapelle.Orchestrator.Workers.EvaluateWorker
  alias Kapelle.Router.Decision

  defp insert_run!(payload) do
    %Run{}
    |> Run.changeset(%{task_id: "task-1", status: "pending", payload: payload})
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

  defp insert_run_task!(run_id, decision_id, task_id) do
    result = Result.new!(%{task_id: task_id, status: :pass})
    {:ok, run_task} = Persistence.record_run_task(run_id, decision_id, result)
    run_task
  end

  describe "perform/1" do
    test "success persists a Verdict linked to the decision and enqueues no further job" do
      run = insert_run!(%{"id" => "task-1"})
      decision = insert_decision!(run.id, "task-1")
      run_task = insert_run_task!(run.id, decision.id, "task-1")

      args = %{
        "run_id" => run.id,
        "run_task_id" => run_task.id,
        "decision_id" => decision.id,
        "judge" => "fake_judge"
      }

      assert :ok = perform_job(EvaluateWorker, args)

      verdict = Repo.get_by!(VerdictRecord, decision_id: decision.id)
      assert verdict.task_id == "task-1"
      assert verdict.total_score == 1.0

      assert [] = all_enqueued()
    end

    test "a judge error returns {:error, _} without persisting a Verdict" do
      run = insert_run!(%{"id" => "task-1"})
      decision = insert_decision!(run.id, "task-1")
      run_task = insert_run_task!(run.id, decision.id, "task-1")

      args = %{
        "run_id" => run.id,
        "run_task_id" => run_task.id,
        "decision_id" => decision.id,
        "judge" => "failing_judge"
      }

      assert {:error, :judge_failed} = perform_job(EvaluateWorker, args)

      refute Repo.get_by(VerdictRecord, decision_id: decision.id)
    end

    test "a verdict/decision mismatch returns {:error, _} without persisting a Verdict" do
      run = insert_run!(%{"id" => "task-1"})
      decision = insert_decision!(run.id, "task-1")
      run_task = insert_run_task!(run.id, decision.id, "task-1")

      args = %{
        "run_id" => run.id,
        "run_task_id" => run_task.id,
        "decision_id" => decision.id,
        "judge" => "mismatched_judge"
      }

      assert {:error, :verdict_decision_mismatch} = perform_job(EvaluateWorker, args)

      refute Repo.get_by(VerdictRecord, decision_id: decision.id)
    end
  end
end
