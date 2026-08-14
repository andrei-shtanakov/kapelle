defmodule Kapelle.Orchestrator.Workers.ExecuteWorker do
  @moduledoc """
  `executor`-queue worker: reloads the `Run`/`Decision` for a routed task,
  executes it via the resolved adapter, persists the resulting `RunTask`,
  and enqueues `EvaluateWorker` to carry the pipeline forward.

  Job args carry only `run_id`/`decision_id` — `adapter` is resolved from
  `run.overrides`, set once at `Pipeline.submit/2` time, so every job
  stays plain-JSON-serializable and replayable without embedding transient
  selection state.

  Idempotent under replay: if `decision_id` already has a persisted
  `RunTask` (a prior delivery of this job already executed it), `perform/1`
  returns `:ok` without re-executing or re-enqueueing `EvaluateWorker`. If
  two deliveries race past that check concurrently, the loser's insert
  hits `run_tasks`' unique index on `decision_id` instead — that's treated
  as success too, since the winner already persisted the `RunTask` and
  enqueued `EvaluateWorker`.

  The `RunTask` write and the `EvaluateWorker` enqueue happen inside a
  single `Ecto.Multi` transaction, so a stage's persisted state and its
  successor job either both exist or neither does.
  """

  use Oban.Worker, queue: :executor

  alias Ecto.Multi
  alias Kapelle.Executor.Execution
  alias Kapelle.Executor.Result
  alias Kapelle.Orchestrator.Persistence
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.Records.RunTask
  alias Kapelle.Orchestrator.RunEvents
  alias Kapelle.Orchestrator.Workers.EvaluateWorker
  alias Kapelle.Orchestrator.Workers.OverrideRegistry
  alias Kapelle.Orchestrator.Workers.Terminal
  alias Kapelle.Repo
  alias Kapelle.Router.Decision

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id, "decision_id" => decision_id}} = job) do
    run = Persistence.get_run!(run_id)

    case Persistence.get_run_task_by_decision(decision_id) do
      %RunTask{} -> :ok
      nil -> execute(run, decision_id, job)
    end
  end

  defp execute(run, decision_id, job) do
    decision = Persistence.get_decision!(decision_id)

    with {:ok, adapter} <- resolve_adapter(run),
         {:ok, task} <- Persistence.atomize_task(run.payload),
         {:ok, result} <- Execution.run(task, decision, adapter) do
      run
      |> build_multi(decision, result)
      |> Repo.transaction()
      |> case do
        {:ok, _changes} ->
          RunEvents.broadcast(run.id)
          :ok

        {:error, :run_task, %Ecto.Changeset{} = changeset, _changes_so_far} ->
          handle_run_task_conflict(run, job, changeset)

        {:error, _step, reason, _changes_so_far} ->
          Terminal.fail(run, job, reason)
      end
    else
      {:error, reason} -> Terminal.fail(run, job, reason)
    end
  end

  defp resolve_adapter(run) do
    {:ok, OverrideRegistry.resolve!(:adapter, run.overrides["adapter"])}
  rescue
    ArgumentError -> {:error, {:unknown_adapter, run.overrides["adapter"]}}
  end

  defp handle_run_task_conflict(run, job, changeset) do
    if Terminal.unique_violation?(changeset, :decision_id) do
      :ok
    else
      Terminal.fail(run, job, changeset)
    end
  end

  @doc false
  @spec build_multi(Run.t(), Decision.t(), Result.t(), keyword()) :: Ecto.Multi.t()
  def build_multi(%Run{} = run, %Decision{} = decision, %Result{} = result, opts \\ []) do
    evaluate_opts = Keyword.get(opts, :evaluate_opts, [])

    Multi.new()
    |> Multi.run(:run_task, fn _repo, _changes ->
      Persistence.record_run_task(run.id, decision.decision_id, result)
    end)
    |> Oban.insert(:evaluate_job, fn %{run_task: run_task} ->
      EvaluateWorker.new(
        %{
          run_id: run.id,
          run_task_id: run_task.id,
          decision_id: decision.decision_id
        },
        evaluate_opts
      )
    end)
  end
end
