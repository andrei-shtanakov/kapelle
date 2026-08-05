defmodule Kapelle.Orchestrator.Workers.RouteWorker do
  @moduledoc """
  `orchestrator`-queue worker: reloads the `Run` for a submitted task,
  routes it via the resolved policy, persists the resulting `Decision`,
  and enqueues `ExecuteWorker` to carry the pipeline forward.

  Job args carry only `run_id` — `policy`/`adapter`/`judge` are resolved
  from `run.overrides`, set once at `Pipeline.submit/2` time, so every job
  stays plain-JSON-serializable and replayable without embedding transient
  selection state.

  Idempotent under replay: if `run_id` already has a persisted `Decision`
  (a prior delivery of this job already routed it), `perform/1` returns
  `:ok` without re-routing or re-enqueueing `ExecuteWorker`.
  """

  use Oban.Worker, queue: :orchestrator

  alias Ecto.Multi
  alias Kapelle.Orchestrator.Persistence
  alias Kapelle.Orchestrator.Records.Decision, as: DecisionRecord
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.Workers.ExecuteWorker
  alias Kapelle.Orchestrator.Workers.OverrideRegistry
  alias Kapelle.Orchestrator.Workers.Terminal
  alias Kapelle.Repo
  alias Kapelle.Router.Decision

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}} = job) do
    run = Persistence.get_run!(run_id)

    case Persistence.get_decision_by_run(run_id) do
      %DecisionRecord{} -> :ok
      nil -> route(run, job)
    end
  end

  defp route(run, job) do
    policy = OverrideRegistry.resolve!(:policy, run.overrides["policy"])

    with {:ok, task} <- Persistence.atomize_task(run.payload),
         {:ok, decision} <- policy.route(task, []) do
      run
      |> build_multi(decision)
      |> Repo.transaction()
      |> case do
        {:ok, _changes} -> :ok
        {:error, _step, reason, _changes_so_far} -> Terminal.fail(run, job, reason)
      end
    else
      {:error, reason} -> Terminal.fail(run, job, reason)
    end
  end

  @doc false
  @spec build_multi(Run.t(), Decision.t(), keyword()) :: Ecto.Multi.t()
  def build_multi(%Run{} = run, %Decision{} = decision, opts \\ []) do
    execute_opts = Keyword.get(opts, :execute_opts, [])

    execute_job =
      ExecuteWorker.new(
        %{
          run_id: run.id,
          decision_id: decision.decision_id,
          adapter: run.overrides["adapter"],
          judge: run.overrides["judge"]
        },
        execute_opts
      )

    Multi.new()
    |> Multi.insert(:decision, Persistence.decision_changeset(run.id, decision))
    |> Oban.insert(:execute_job, execute_job)
  end
end
