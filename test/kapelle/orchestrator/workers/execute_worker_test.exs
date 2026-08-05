defmodule Kapelle.Orchestrator.Workers.ExecuteWorkerTest do
  use Kapelle.DataCase, async: true
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Orchestrator.Persistence
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.Records.RunTask
  alias Kapelle.Orchestrator.Workers.{EvaluateWorker, ExecuteWorker}
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

  describe "perform/1" do
    test "success persists a RunTask linked to the run/decision and enqueues EvaluateWorker" do
      run = insert_run!(%{"id" => "task-1"})
      decision = insert_decision!(run.id, "task-1")

      args = %{
        "run_id" => run.id,
        "decision_id" => decision.id,
        "adapter" => "execute_adapter",
        "judge" => "fake_judge"
      }

      assert :ok = perform_job(ExecuteWorker, args)

      run_task = Repo.get_by!(RunTask, decision_id: decision.id)
      assert run_task.run_id == run.id
      assert run_task.status == "pass"

      assert_enqueued(
        worker: EvaluateWorker,
        queue: :evaluator,
        args: %{
          "run_id" => run.id,
          "run_task_id" => run_task.id,
          "decision_id" => decision.id,
          "judge" => "fake_judge"
        }
      )
    end

    test "an adapter error returns {:error, _} without persisting a RunTask or enqueueing EvaluateWorker" do
      run = insert_run!(%{"id" => "unexecutable"})
      decision = insert_decision!(run.id, "unexecutable")

      args = %{
        "run_id" => run.id,
        "decision_id" => decision.id,
        "adapter" => "execute_adapter",
        "judge" => "fake_judge"
      }

      assert {:error, :unexecutable} = perform_job(ExecuteWorker, args)

      refute Repo.get_by(RunTask, decision_id: decision.id)
      refute_enqueued(worker: EvaluateWorker)
    end

    test "executes with the real default FakeAdapter against a jsonb-reloaded, string-keyed payload" do
      run = insert_run!(%{"id" => "task-1", "type" => "code_gen"})
      decision = insert_decision!(run.id, "task-1")

      args = %{
        "run_id" => run.id,
        "decision_id" => decision.id,
        "adapter" => "fake_adapter",
        "judge" => "fake_judge"
      }

      assert :ok = perform_job(ExecuteWorker, args)

      run_task = Repo.get_by!(RunTask, decision_id: decision.id)
      assert run_task.status == "pass"
    end
  end
end
