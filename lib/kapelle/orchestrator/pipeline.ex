defmodule Kapelle.Orchestrator.Pipeline do
  @moduledoc """
  Synchronous submit → route → execute → evaluate pipeline (M1 vertical
  slice). Each step runs inline in the caller's process; Oban-backed async
  execution arrives in TASK-006.
  """

  alias Ecto.Multi
  alias Kapelle.Evaluator.FakeJudge
  alias Kapelle.Evaluator.Verdict
  alias Kapelle.Executor.FakeAdapter
  alias Kapelle.Orchestrator.Persistence
  alias Kapelle.Orchestrator.Workers.OverrideRegistry
  alias Kapelle.Orchestrator.Workers.RouteWorker
  alias Kapelle.Repo
  alias Kapelle.Router.RulesPolicy

  @default_policy RulesPolicy
  @default_adapter FakeAdapter
  @default_judge FakeJudge

  @doc """
  Runs `task` through routing, execution, and evaluation, returning
  `{:ok, Verdict.t()}` with a `decision_id` referencing the `Decision` this
  run was routed to.

  `opts` is forwarded to `policy.route/2` and may include `:policy`,
  `:adapter`, `:judge` module overrides (defaulting to `RulesPolicy`,
  `FakeAdapter`, `FakeJudge`).
  """
  @spec run_sync(map(), keyword()) :: {:ok, Verdict.t()} | {:error, term()}
  def run_sync(task, opts \\ []) when is_map(task) do
    policy = Keyword.get(opts, :policy, @default_policy)
    adapter = Keyword.get(opts, :adapter, @default_adapter)
    judge = Keyword.get(opts, :judge, @default_judge)

    with {:ok, decision} <- policy.route(task, opts),
         {:ok, result} <- adapter.execute(task, decision) do
      task_with_decision = Map.put(task, :decision_id, decision.decision_id)

      with {:ok, verdict} <- judge.evaluate(task_with_decision, result),
           {:ok, run} <- Persistence.create_run(task),
           {:ok, _decision_record} <- Persistence.record_decision(run.id, decision),
           {:ok, _run_task_record} <-
             Persistence.record_run_task(run.id, decision.decision_id, result),
           {:ok, _verdict_record} <- Persistence.record_verdict(decision.decision_id, verdict) do
        {:ok, verdict}
      end
    end
  end

  @doc """
  Persists `task` as a pending `Run` and enqueues `RouteWorker` to carry it
  through routing, execution, and evaluation asynchronously via Oban.

  Returns `{:ok, run_id}` as soon as the `Run` row and the `RouteWorker` job
  are durably inserted, without waiting on any worker to run.

  `opts` mirrors `run_sync/2`'s `:policy`/`:adapter`/`:judge` overrides; each
  is translated to its `OverrideRegistry` string key before being placed in
  the job args, since Oban job args must be plain JSON.
  """
  @spec submit(map(), keyword()) :: {:ok, Ecto.UUID.t()} | {:error, term()}
  def submit(task, opts \\ []) when is_map(task) do
    policy = Keyword.get(opts, :policy, @default_policy)
    adapter = Keyword.get(opts, :adapter, @default_adapter)
    judge = Keyword.get(opts, :judge, @default_judge)

    route_job_attrs = fn run_id ->
      %{
        run_id: run_id,
        policy: OverrideRegistry.key_for(:policy, policy),
        adapter: OverrideRegistry.key_for(:adapter, adapter),
        judge: OverrideRegistry.key_for(:judge, judge)
      }
    end

    Multi.new()
    |> Multi.insert(:run, Persistence.pending_run_changeset(task))
    |> Oban.insert(:route_job, fn %{run: run} -> RouteWorker.new(route_job_attrs.(run.id)) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{run: run}} -> {:ok, run.id}
      {:error, _step, changeset, _changes_so_far} -> {:error, changeset}
    end
  end
end
