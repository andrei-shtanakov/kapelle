defmodule Kapelle.Orchestrator.Workers.EvaluateWorkerTest do
  use Kapelle.DataCase, async: true
  use Oban.Testing, repo: Kapelle.Repo

  alias Ecto.Adapters.SQL.Sandbox
  alias Kapelle.Evaluator.Verdict
  alias Kapelle.Executor.Result
  alias Kapelle.Orchestrator.Persistence
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.Records.Verdict, as: VerdictRecord
  alias Kapelle.Orchestrator.RunEvents
  alias Kapelle.Orchestrator.Workers.EvaluateWorker
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
    %{"judge" => "fake_judge"}
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
    test "success persists a Verdict linked to the decision, marks the Run completed, and enqueues no further job" do
      run = insert_run!(%{"id" => "task-1"}, default_overrides())
      decision = insert_decision!(run.id, "task-1")
      run_task = insert_run_task!(run.id, decision.id, "task-1")

      args = %{"run_id" => run.id, "run_task_id" => run_task.id, "decision_id" => decision.id}

      assert :ok = perform_job(EvaluateWorker, args)

      verdict = Repo.get_by!(VerdictRecord, decision_id: decision.id)
      assert verdict.task_id == "task-1"
      assert verdict.total_score == 1.0

      assert Repo.get!(Run, run.id).status == "completed"
      assert [] = all_enqueued()
    end

    test "success also persists a typed router Outcome, linked to the decision, atomically with the terminal Verdict" do
      run = insert_run!(%{"id" => "task-1"}, default_overrides())
      decision = insert_decision!(run.id, "task-1")
      run_task = insert_run_task!(run.id, decision.id, "task-1")

      args = %{"run_id" => run.id, "run_task_id" => run_task.id, "decision_id" => decision.id}

      assert :ok = perform_job(EvaluateWorker, args)

      assert %{decision_id: decision_id, type: "success"} =
               Persistence.get_outcome_by_decision(decision.id)

      assert decision_id == decision.id
    end

    test "the task passed to the judge has atom keys, matching Pipeline.run_sync/2's in-memory task shape" do
      run = insert_run!(%{"id" => "task-1", "type" => "code_gen"}, %{"judge" => "echoing_judge"})
      decision = insert_decision!(run.id, "task-1")
      run_task = insert_run_task!(run.id, decision.id, "task-1")

      args = %{"run_id" => run.id, "run_task_id" => run_task.id, "decision_id" => decision.id}

      assert :ok = perform_job(EvaluateWorker, args)

      assert_received {:evaluate_task, task}
      assert task == %{id: "task-1", type: :code_gen, decision_id: decision.id}
    end

    test "an unrecognized run.payload key returns {:error, _} without persisting a Verdict or crashing" do
      run =
        insert_run!(
          %{"id" => "task-1", "not_a_real_atom_anywhere_xyz" => "value"},
          default_overrides()
        )

      decision = insert_decision!(run.id, "task-1")
      run_task = insert_run_task!(run.id, decision.id, "task-1")

      args = %{"run_id" => run.id, "run_task_id" => run_task.id, "decision_id" => decision.id}

      assert {:error, {:unknown_task_key, "not_a_real_atom_anywhere_xyz"}} =
               perform_job(EvaluateWorker, args)

      refute Repo.get_by(VerdictRecord, decision_id: decision.id)
      assert Repo.get!(Run, run.id).status != "completed"
    end

    test "a judge error returns {:error, _} without persisting a Verdict" do
      run = insert_run!(%{"id" => "task-1"}, %{"judge" => "failing_judge"})
      decision = insert_decision!(run.id, "task-1")
      run_task = insert_run_task!(run.id, decision.id, "task-1")

      args = %{"run_id" => run.id, "run_task_id" => run_task.id, "decision_id" => decision.id}

      assert {:error, :judge_failed} = perform_job(EvaluateWorker, args)

      refute Repo.get_by(VerdictRecord, decision_id: decision.id)
    end

    test "a verdict/decision mismatch returns {:error, _} without persisting a Verdict" do
      run = insert_run!(%{"id" => "task-1"}, %{"judge" => "mismatched_judge"})
      decision = insert_decision!(run.id, "task-1")
      run_task = insert_run_task!(run.id, decision.id, "task-1")

      args = %{"run_id" => run.id, "run_task_id" => run_task.id, "decision_id" => decision.id}

      assert {:error, :verdict_decision_mismatch} = perform_job(EvaluateWorker, args)

      refute Repo.get_by(VerdictRecord, decision_id: decision.id)
    end

    test "a judge error on the final attempt goes through Terminal.fail: run is marked failed and the job is discarded" do
      run = insert_run!(%{"id" => "task-1"}, %{"judge" => "failing_judge"})
      decision = insert_decision!(run.id, "task-1")
      run_task = insert_run_task!(run.id, decision.id, "task-1")

      args = %{"run_id" => run.id, "run_task_id" => run_task.id, "decision_id" => decision.id}

      assert {:discard, :judge_failed} =
               perform_job(EvaluateWorker, args, attempt: 1, max_attempts: 1)

      refute Repo.get_by(VerdictRecord, decision_id: decision.id)
      assert Repo.get!(Run, run.id).status == "failed"
    end

    test "a Run whose overrides are missing the judge key fails cleanly through Terminal.fail instead of raising" do
      run = insert_run!(%{"id" => "task-1"}, %{})
      decision = insert_decision!(run.id, "task-1")
      run_task = insert_run_task!(run.id, decision.id, "task-1")

      args = %{"run_id" => run.id, "run_task_id" => run_task.id, "decision_id" => decision.id}

      assert {:discard, {:unknown_judge, nil}} =
               perform_job(EvaluateWorker, args, attempt: 1, max_attempts: 1)

      refute Repo.get_by(VerdictRecord, decision_id: decision.id)
      assert Repo.get!(Run, run.id).status == "failed"
    end

    test "success broadcasts a RunEvents update for the run" do
      run = insert_run!(%{"id" => "task-1"}, default_overrides())
      decision = insert_decision!(run.id, "task-1")
      run_task = insert_run_task!(run.id, decision.id, "task-1")
      :ok = RunEvents.subscribe(run.id)

      args = %{"run_id" => run.id, "run_task_id" => run_task.id, "decision_id" => decision.id}

      assert :ok = perform_job(EvaluateWorker, args)

      assert_receive {:run_updated, run_id}
      assert run_id == run.id
    end

    test "a replayed job is idempotent: no duplicate Verdict, no re-enqueued job, and the Run stays completed" do
      run = insert_run!(%{"id" => "task-1"}, default_overrides())
      decision = insert_decision!(run.id, "task-1")
      run_task = insert_run_task!(run.id, decision.id, "task-1")

      args = %{"run_id" => run.id, "run_task_id" => run_task.id, "decision_id" => decision.id}

      assert :ok = perform_job(EvaluateWorker, args)
      assert :ok = perform_job(EvaluateWorker, args)

      assert Repo.aggregate(VerdictRecord, :count, decision_id: decision.id) == 1
      assert Repo.get!(Run, run.id).status == "completed"
      assert [] = all_enqueued()
    end

    test "a decision_id that matches no persisted Decision fails the Verdict foreign-key constraint and goes through Terminal.fail, not the unique-violation success path" do
      run = insert_run!(%{"id" => "task-1"}, %{"judge" => "echoing_judge"})
      decision = insert_decision!(run.id, "task-1")
      run_task = insert_run_task!(run.id, decision.id, "task-1")
      missing_decision_id = Ecto.UUID.generate()

      args = %{
        "run_id" => run.id,
        "run_task_id" => run_task.id,
        "decision_id" => missing_decision_id
      }

      assert {:discard, %Ecto.Changeset{} = changeset} =
               perform_job(EvaluateWorker, args, attempt: 1, max_attempts: 1)

      assert Enum.any?(changeset.errors, fn
               {:decision_id, {_message, opts}} -> Keyword.get(opts, :constraint) == :foreign
               _ -> false
             end)

      refute Repo.get_by(VerdictRecord, decision_id: missing_decision_id)
      assert Repo.get!(Run, run.id).status == "failed"
    end

    test "two deliveries racing on the same decision_id: the loser treats the unique-constraint collision as success, not a failure" do
      run = insert_run!(%{"id" => "task-1"}, default_overrides())
      decision = insert_decision!(run.id, "task-1")
      run_task = insert_run_task!(run.id, decision.id, "task-1")
      args = %{"run_id" => run.id, "run_task_id" => run_task.id, "decision_id" => decision.id}
      owner = self()

      results =
        1..2
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Sandbox.allow(Repo, owner, self())
            perform_job(EvaluateWorker, args)
          end)
        end)
        |> Task.await_many(5_000)

      assert Enum.all?(results, &(&1 == :ok))
      assert Repo.aggregate(VerdictRecord, :count, decision_id: decision.id) == 1
      assert Repo.get!(Run, run.id).status != "failed"
    end

    test "a late success arriving after a concurrent finalizer already marked the run failed returns :ok and leaves the run failed" do
      run = insert_run!(%{"id" => "task-1"}, default_overrides())
      decision = insert_decision!(run.id, "task-1")
      run_task = insert_run_task!(run.id, decision.id, "task-1")
      Repo.update!(Run.status_changeset(run, "failed"))

      args = %{"run_id" => run.id, "run_task_id" => run_task.id, "decision_id" => decision.id}

      assert :ok = perform_job(EvaluateWorker, args)

      assert Repo.get_by!(VerdictRecord, decision_id: decision.id)
      assert Repo.get!(Run, run.id).status == "failed"
    end
  end

  describe "build_multi/3" do
    test "a verdict write failure rolls back the run status update" do
      run = insert_run!(%{"id" => "task-1"}, default_overrides())
      decision = insert_decision!(run.id, "task-1")
      insert_run_task!(run.id, decision.id, "task-1")

      verdict =
        Verdict.new!(%{
          decision_id: decision.id,
          task_id: "task-1",
          total_score: 1.0,
          score_components: %{status_match: 1.0}
        })

      {:ok, _existing} = Persistence.record_verdict(decision.id, verdict)

      multi = EvaluateWorker.build_multi(run, decision.id, verdict)

      assert {:error, :verdict, _changeset, _changes} = Repo.transaction(multi)
      assert Repo.get!(Run, run.id).status == "pending"
    end

    test "when the run is already terminal, the status transition is a no-op but the verdict still commits" do
      run = insert_run!(%{"id" => "task-1"}, default_overrides())
      decision = insert_decision!(run.id, "task-1")
      insert_run_task!(run.id, decision.id, "task-1")
      run = Repo.update!(Run.status_changeset(run, "failed"))

      verdict =
        Verdict.new!(%{
          decision_id: decision.id,
          task_id: "task-1",
          total_score: 1.0,
          score_components: %{status_match: 1.0}
        })

      multi = EvaluateWorker.build_multi(run, decision.id, verdict)

      assert {:ok, %{run: {0, nil}}} = Repo.transaction(multi)
      assert Repo.get_by!(VerdictRecord, decision_id: decision.id)
      assert Repo.get!(Run, run.id).status == "failed"
    end
  end
end
