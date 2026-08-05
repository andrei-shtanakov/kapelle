defmodule Kapelle.Orchestrator.Workers.ExecuteWorker do
  @moduledoc """
  `executor`-queue worker: reloads the `Run`/`Decision` for a routed task,
  executes it via the resolved adapter, persists the resulting `RunTask`,
  and enqueues `EvaluateWorker` to carry the pipeline forward.

  Job args carry only `run_id`/`decision_id` plus the `OverrideRegistry`
  string keys for `adapter`/`judge` — never structs or business-data maps,
  so every job stays plain-JSON-serializable.
  """

  use Oban.Worker, queue: :executor

  alias Kapelle.Orchestrator.Persistence
  alias Kapelle.Orchestrator.Workers.EvaluateWorker
  alias Kapelle.Orchestrator.Workers.OverrideRegistry

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id, "decision_id" => decision_id} = args}) do
    run = Persistence.get_run!(run_id)
    decision = Persistence.get_decision!(decision_id)
    adapter = OverrideRegistry.resolve!(:adapter, args["adapter"])

    with {:ok, task} <- Persistence.atomize_task(run.payload),
         {:ok, result} <- adapter.execute(task, decision),
         {:ok, run_task} <- Persistence.record_run_task(run.id, decision.decision_id, result) do
      %{
        run_id: run.id,
        run_task_id: run_task.id,
        decision_id: decision.decision_id,
        judge: args["judge"]
      }
      |> EvaluateWorker.new()
      |> Oban.insert()
      |> case do
        {:ok, _job} -> :ok
        {:error, changeset} -> {:error, changeset}
      end
    end
  end
end
