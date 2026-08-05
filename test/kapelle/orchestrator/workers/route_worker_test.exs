defmodule Kapelle.Orchestrator.Workers.RouteWorkerTest do
  use Kapelle.DataCase, async: true
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Orchestrator.Records.Decision, as: DecisionRecord
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.Workers.{ExecuteWorker, RouteWorker}
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
    %{"policy" => "route_policy", "adapter" => "fake_adapter", "judge" => "fake_judge"}
  end

  describe "perform/1" do
    test "success persists a Decision linked to the run and enqueues ExecuteWorker" do
      run = insert_run!(%{"id" => "task-1"}, default_overrides())

      args = %{"run_id" => run.id}

      assert :ok = perform_job(RouteWorker, args)

      decision = Repo.get_by!(DecisionRecord, run_id: run.id)
      assert decision.task_id == "task-1"

      assert_enqueued(
        worker: ExecuteWorker,
        queue: :executor,
        args: %{
          "run_id" => run.id,
          "decision_id" => decision.id,
          "adapter" => "fake_adapter",
          "judge" => "fake_judge"
        }
      )
    end

    test "a routing error returns {:error, _} without persisting a Decision or enqueueing ExecuteWorker" do
      run = insert_run!(%{"id" => "unroutable"}, default_overrides())

      args = %{"run_id" => run.id}

      assert {:error, :unroutable} = perform_job(RouteWorker, args)

      refute Repo.get_by(DecisionRecord, run_id: run.id)
      refute_enqueued(worker: ExecuteWorker)
    end

    test "a routing error on the final attempt goes through Terminal.fail: run is marked failed and the job is discarded" do
      run = insert_run!(%{"id" => "unroutable"}, default_overrides())

      args = %{"run_id" => run.id}

      assert {:discard, :unroutable} = perform_job(RouteWorker, args, attempt: 1, max_attempts: 1)

      refute Repo.get_by(DecisionRecord, run_id: run.id)
      refute_enqueued(worker: ExecuteWorker)
      assert Repo.get!(Run, run.id).status == "failed"
    end

    test "routes with the real default RulesPolicy against a jsonb-reloaded, string-keyed payload" do
      run =
        insert_run!(%{"id" => "task-1", "type" => "code_gen"}, %{
          "policy" => "rules_policy",
          "adapter" => "fake_adapter",
          "judge" => "fake_judge"
        })

      args = %{"run_id" => run.id}

      assert :ok = perform_job(RouteWorker, args)

      decision = Repo.get_by!(DecisionRecord, run_id: run.id)
      assert decision.task_id == "task-1"

      assert_enqueued(worker: ExecuteWorker, queue: :executor, args: %{"run_id" => run.id})
    end

    test "a replayed job is idempotent: no duplicate Decision and no re-enqueued ExecuteWorker" do
      run = insert_run!(%{"id" => "task-1"}, default_overrides())

      args = %{"run_id" => run.id}

      assert :ok = perform_job(RouteWorker, args)
      assert :ok = perform_job(RouteWorker, args)

      assert Repo.aggregate(DecisionRecord, :count, run_id: run.id) == 1

      assert [_single_job] = all_enqueued(worker: ExecuteWorker)
    end
  end

  describe "build_multi/3" do
    test "an Oban.insert failure rolls back the Decision write" do
      run = insert_run!(%{"id" => "task-1"}, default_overrides())

      decision =
        Decision.new!(%{
          decision_id: Ecto.UUID.generate(),
          task_id: "task-1",
          target: %{provider: "anthropic", model: "claude-sonnet-5"},
          decided_at: DateTime.utc_now()
        })

      multi = RouteWorker.build_multi(run, decision, execute_opts: [max_attempts: 0])

      assert {:error, :execute_job, _changeset, _changes} = Repo.transaction(multi)
      assert Repo.aggregate(DecisionRecord, :count) == 0
    end
  end
end
