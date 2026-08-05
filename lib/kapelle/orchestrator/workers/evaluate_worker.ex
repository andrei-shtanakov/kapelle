defmodule Kapelle.Orchestrator.Workers.EvaluateWorker do
  @moduledoc """
  `evaluator`-queue worker: reloads the `Run`/`RunTask` for an executed
  task, evaluates it via the resolved judge, and persists the resulting
  `Verdict`. Terminal stage — no further job is enqueued on success.
  """

  use Oban.Worker, queue: :evaluator

  alias Kapelle.Orchestrator.Persistence
  alias Kapelle.Orchestrator.Workers.OverrideRegistry

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{"run_id" => run_id, "run_task_id" => run_task_id, "decision_id" => decision_id} =
            args
      }) do
    run = Persistence.get_run!(run_id)
    run_task = Persistence.get_run_task!(run_task_id)
    judge = OverrideRegistry.resolve!(:judge, args["judge"])

    task_with_decision =
      run.payload
      |> atomize_keys()
      |> Map.put(:decision_id, decision_id)

    with {:ok, verdict} <- judge.evaluate(task_with_decision, run_task),
         {:ok, _verdict_record} <- Persistence.record_verdict(decision_id, verdict) do
      :ok
    end
  end

  # `run.payload` reloads from a jsonb column as a string-keyed map, unlike
  # `Pipeline.run_sync/2`'s in-memory atom-keyed task. Restores the atom
  # keys judges expect (mirrors `Persistence.atomize_target/1`).
  defp atomize_keys(map) do
    Map.new(map, fn {key, value} -> {String.to_existing_atom(key), value} end)
  end
end
