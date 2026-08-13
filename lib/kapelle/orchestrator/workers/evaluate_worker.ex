defmodule Kapelle.Orchestrator.Workers.EvaluateWorker do
  @moduledoc """
  `evaluator`-queue worker: reloads the `Run`/`RunTask` for an executed
  task, evaluates it via the resolved judge, and persists the resulting
  `Verdict`, a typed `Router.Outcome` derived from it, and the owning
  `Run`'s terminal `"completed"` status. Terminal stage — no further job
  is enqueued on success. Closes REQ-102's `decision_id → verdict →
  router outcome` loop exactly once.

  Job args carry only `run_id`/`run_task_id`/`decision_id` — `judge` is
  resolved from `run.overrides`, set once at `Pipeline.submit/2` time, so
  every job stays plain-JSON-serializable and replayable without
  embedding transient selection state.

  Idempotent under replay: if `decision_id` already has a persisted
  `Verdict` (a prior delivery of this job already evaluated it),
  `perform/1` returns `:ok` without re-evaluating or re-writing `Run`'s
  status or `Outcome`. If two deliveries race past that check
  concurrently, the loser's insert hits `verdicts`' unique index on
  `decision_id` instead — that's treated as success too, since the
  winner already persisted the `Verdict`, the `Outcome`, and the `Run`'s
  `"completed"` status.

  The `Verdict` write, the `Outcome` write, and the `Run`'s `"completed"`
  status write happen inside a single `Ecto.Multi` transaction, so a
  run's terminal state, its verdict, and its outcome either all exist or
  none does — a crash between steps can't leave one written without the
  others. The status write goes through `Terminal.terminal_transition/4`,
  so it's a no-op (rather than an overwrite) if `run` is already terminal
  — e.g. a concurrent failure finalized it first, so a late success can
  never overwrite that terminal result. Either way `perform/1` still
  returns `:ok`, since the verdict and outcome themselves committed and
  there's no successor job to withhold.
  """

  use Oban.Worker, queue: :evaluator

  alias Ecto.Multi
  alias Kapelle.Evaluator.Verdict
  alias Kapelle.Orchestrator.Persistence
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.Records.Verdict, as: VerdictRecord
  alias Kapelle.Orchestrator.RunEvents
  alias Kapelle.Orchestrator.Workers.OverrideRegistry
  alias Kapelle.Orchestrator.Workers.Terminal
  alias Kapelle.Repo
  alias Kapelle.Router.Outcome

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args: %{
            "run_id" => run_id,
            "run_task_id" => run_task_id,
            "decision_id" => decision_id
          }
        } = job
      ) do
    run = Persistence.get_run!(run_id)

    case Persistence.get_verdict_by_decision(decision_id) do
      %VerdictRecord{} -> :ok
      nil -> evaluate(run, run_task_id, decision_id, job)
    end
  end

  defp evaluate(run, run_task_id, decision_id, job) do
    run_task = Persistence.get_run_task!(run_task_id)

    with {:ok, judge} <- resolve_judge(run),
         {:ok, task} <- Persistence.atomize_task(run.payload),
         task_with_decision = Map.put(task, :decision_id, decision_id),
         {:ok, verdict} <- judge.evaluate(task_with_decision, run_task) do
      run
      |> build_multi(decision_id, verdict)
      |> Repo.transaction()
      |> case do
        {:ok, _changes} ->
          RunEvents.broadcast(run.id)
          :ok

        {:error, :verdict, %Ecto.Changeset{} = changeset, _changes_so_far} ->
          handle_verdict_conflict(run, job, changeset)

        {:error, _step, reason, _changes_so_far} ->
          Terminal.fail(run, job, reason)
      end
    else
      {:error, reason} -> Terminal.fail(run, job, reason)
    end
  end

  defp resolve_judge(run) do
    {:ok, OverrideRegistry.resolve!(:judge, run.overrides["judge"])}
  rescue
    ArgumentError -> {:error, {:unknown_judge, run.overrides["judge"]}}
  end

  defp handle_verdict_conflict(run, job, changeset) do
    if Terminal.unique_violation?(changeset, :decision_id) do
      :ok
    else
      Terminal.fail(run, job, changeset)
    end
  end

  @doc false
  @spec build_multi(Run.t(), Ecto.UUID.t(), Verdict.t()) :: Ecto.Multi.t()
  def build_multi(%Run{} = run, decision_id, %Verdict{} = verdict) do
    Multi.new()
    |> Multi.run(:verdict, fn _repo, _changes ->
      Persistence.record_verdict(decision_id, verdict)
    end)
    |> Multi.run(:outcome, fn _repo, _changes ->
      Persistence.record_outcome(decision_id, Outcome.from_verdict(verdict))
    end)
    |> Terminal.terminal_transition(:run, run.id, "completed")
  end
end
