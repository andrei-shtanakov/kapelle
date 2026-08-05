defmodule Kapelle.Orchestrator.Workers.RouteWorkerTest do
  use Kapelle.DataCase, async: true
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Orchestrator.Records.Decision, as: DecisionRecord
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.Workers.{ExecuteWorker, RouteWorker}

  defp insert_run!(payload) do
    %Run{}
    |> Run.changeset(%{task_id: "task-1", status: "pending", payload: payload})
    |> Repo.insert!()
  end

  describe "perform/1" do
    test "success persists a Decision linked to the run and enqueues ExecuteWorker" do
      run = insert_run!(%{"id" => "task-1"})

      args = %{
        "run_id" => run.id,
        "policy" => "route_policy",
        "adapter" => "fake_adapter",
        "judge" => "fake_judge"
      }

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
      run = insert_run!(%{"id" => "unroutable"})

      args = %{
        "run_id" => run.id,
        "policy" => "route_policy",
        "adapter" => "fake_adapter",
        "judge" => "fake_judge"
      }

      assert {:error, :unroutable} = perform_job(RouteWorker, args)

      refute Repo.get_by(DecisionRecord, run_id: run.id)
      refute_enqueued(worker: ExecuteWorker)
    end
  end
end
