defmodule Kapelle.Orchestrator.Workers.RouteWorker do
  @moduledoc """
  `orchestrator`-queue worker: reloads the `Run` for a submitted task,
  routes it via the resolved policy, persists the resulting `Decision`,
  and enqueues `ExecuteWorker` to carry the pipeline forward.

  Job args carry only `run_id` plus the `OverrideRegistry` string keys for
  `policy`/`adapter`/`judge` — never structs or business-data maps, so
  every job stays plain-JSON-serializable.
  """

  use Oban.Worker, queue: :orchestrator

  alias Ecto.Multi
  alias Kapelle.Orchestrator.Persistence
  alias Kapelle.Orchestrator.Workers.ExecuteWorker
  alias Kapelle.Orchestrator.Workers.OverrideRegistry
  alias Kapelle.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id} = args}) do
    run = Persistence.get_run!(run_id)
    policy = OverrideRegistry.resolve!(:policy, args["policy"])

    with {:ok, task} <- Persistence.atomize_task(run.payload),
         {:ok, decision} <- policy.route(task, []) do
      execute_job =
        ExecuteWorker.new(%{
          run_id: run.id,
          decision_id: decision.decision_id,
          adapter: args["adapter"],
          judge: args["judge"]
        })

      Multi.new()
      |> Multi.insert(:decision, Persistence.decision_changeset(run.id, decision))
      |> Oban.insert(:execute_job, execute_job)
      |> Repo.transaction()
      |> case do
        {:ok, _changes} -> :ok
        {:error, _step, changeset, _changes_so_far} -> {:error, changeset}
      end
    end
  end
end
