defmodule Kapelle.Orchestrator.Workers.ExecuteWorkerTest do
  use Kapelle.DataCase, async: true
  use Oban.Testing, repo: Kapelle.Repo

  alias Ecto.Adapters.SQL.Sandbox
  alias Kapelle.Executor.Result
  alias Kapelle.Orchestrator.Persistence
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.Records.RunTask
  alias Kapelle.Orchestrator.Workers.{EvaluateWorker, ExecuteWorker}
  alias Kapelle.Router.Decision

  defp insert_run!(payload, overrides) do
    %Run{}
    |> Run.changeset(%{
      task_id: "task-1",
      status: "pending",
      payload: payload,
      overrides: overrides
    })
    |> Repo.insert!()
  end

  defp default_overrides do
    %{"adapter" => "fake_adapter", "judge" => "fake_judge"}
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
      run = insert_run!(%{"id" => "task-1"}, default_overrides())
      decision = insert_decision!(run.id, "task-1")

      args = %{"run_id" => run.id, "decision_id" => decision.id}

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
          "decision_id" => decision.id
        }
      )

      assert [%{args: enqueued_args}] = all_enqueued(worker: EvaluateWorker)

      assert Map.keys(enqueued_args) |> Enum.sort() == [
               "decision_id",
               "run_id",
               "run_task_id"
             ]
    end

    test "an adapter error returns {:error, _} without persisting a RunTask or enqueueing EvaluateWorker" do
      run = insert_run!(%{"id" => "unexecutable"}, %{"adapter" => "execute_adapter"})
      decision = insert_decision!(run.id, "unexecutable")

      args = %{"run_id" => run.id, "decision_id" => decision.id}

      assert {:error, :unexecutable} = perform_job(ExecuteWorker, args)

      refute Repo.get_by(RunTask, decision_id: decision.id)
      refute_enqueued(worker: EvaluateWorker)
    end

    test "an adapter error on the final attempt goes through Terminal.fail: run is marked failed and the job is discarded" do
      run = insert_run!(%{"id" => "unexecutable"}, %{"adapter" => "execute_adapter"})
      decision = insert_decision!(run.id, "unexecutable")

      args = %{"run_id" => run.id, "decision_id" => decision.id}

      assert {:discard, :unexecutable} =
               perform_job(ExecuteWorker, args, attempt: 1, max_attempts: 1)

      refute Repo.get_by(RunTask, decision_id: decision.id)
      refute_enqueued(worker: EvaluateWorker)
      assert Repo.get!(Run, run.id).status == "failed"
    end

    test "a Run whose overrides are missing the adapter key fails cleanly through Terminal.fail instead of raising" do
      run = insert_run!(%{"id" => "task-1"}, %{"judge" => "fake_judge"})
      decision = insert_decision!(run.id, "task-1")

      args = %{"run_id" => run.id, "decision_id" => decision.id}

      assert {:discard, {:unknown_adapter, nil}} =
               perform_job(ExecuteWorker, args, attempt: 1, max_attempts: 1)

      refute Repo.get_by(RunTask, decision_id: decision.id)
      refute_enqueued(worker: EvaluateWorker)
      assert Repo.get!(Run, run.id).status == "failed"
    end

    test "executes with the real default FakeAdapter against a jsonb-reloaded, string-keyed payload" do
      run = insert_run!(%{"id" => "task-1", "type" => "code_gen"}, default_overrides())
      decision = insert_decision!(run.id, "task-1")

      args = %{"run_id" => run.id, "decision_id" => decision.id}

      assert :ok = perform_job(ExecuteWorker, args)

      run_task = Repo.get_by!(RunTask, decision_id: decision.id)
      assert run_task.status == "pass"
    end

    test "a replayed job is idempotent: no duplicate RunTask and no re-enqueued EvaluateWorker" do
      run = insert_run!(%{"id" => "task-1"}, default_overrides())
      decision = insert_decision!(run.id, "task-1")

      args = %{"run_id" => run.id, "decision_id" => decision.id}

      assert :ok = perform_job(ExecuteWorker, args)
      assert :ok = perform_job(ExecuteWorker, args)

      assert Repo.aggregate(RunTask, :count, decision_id: decision.id) == 1

      assert [_single_job] = all_enqueued(worker: EvaluateWorker)
    end

    test "two deliveries racing on the same decision_id: the loser treats the unique-constraint collision as success, not a failure" do
      run = insert_run!(%{"id" => "task-1"}, default_overrides())
      decision = insert_decision!(run.id, "task-1")
      args = %{"run_id" => run.id, "decision_id" => decision.id}
      owner = self()

      results =
        1..2
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Sandbox.allow(Repo, owner, self())
            perform_job(ExecuteWorker, args)
          end)
        end)
        |> Task.await_many(5_000)

      assert Enum.all?(results, &(&1 == :ok))
      assert Repo.aggregate(RunTask, :count, decision_id: decision.id) == 1
      assert Repo.get!(Run, run.id).status != "failed"
      assert [_single_job] = all_enqueued(worker: EvaluateWorker)
    end
  end

  describe "build_multi/4" do
    test "an Oban.insert failure rolls back the RunTask write" do
      run = insert_run!(%{"id" => "task-1"}, default_overrides())
      decision_record = insert_decision!(run.id, "task-1")
      decision = Persistence.get_decision!(decision_record.id)
      result = Result.new!(%{task_id: "task-1", status: :pass})

      multi =
        ExecuteWorker.build_multi(run, decision, result, evaluate_opts: [max_attempts: 0])

      assert {:error, :evaluate_job, _changeset, _changes} = Repo.transaction(multi)
      assert Repo.aggregate(RunTask, :count) == 0
    end
  end
end
