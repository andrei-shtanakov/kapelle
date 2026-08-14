defmodule Kapelle.Orchestrator.Pipeline do
  @moduledoc """
  Synchronous submit → route → execute → evaluate pipeline (M1 vertical
  slice). Each step runs inline in the caller's process; Oban-backed async
  execution arrives in TASK-006.
  """

  alias Ecto.Multi
  alias Kapelle.Evaluator.FakeJudge
  alias Kapelle.Evaluator.Verdict
  alias Kapelle.Executor.Execution
  alias Kapelle.Executor.FakeAdapter
  alias Kapelle.Orchestrator.Persistence
  alias Kapelle.Orchestrator.Records.Run
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
         {:ok, result} <- Execution.run(task, decision, adapter),
         task_with_decision = Map.put(task, :decision_id, decision.decision_id),
         {:ok, verdict} <- judge.evaluate(task_with_decision, result) do
      Multi.new()
      |> Multi.insert(:run, Run.changeset(%Run{}, Persistence.run_attrs(task)))
      |> Multi.run(:decision, fn _repo, %{run: run} ->
        Persistence.record_decision(run.id, decision)
      end)
      |> Multi.run(:run_task, fn _repo, %{run: run, decision: decision_record} ->
        Persistence.record_run_task(run.id, decision_record.id, result)
      end)
      |> Multi.run(:verdict, fn _repo, %{decision: decision_record} ->
        Persistence.record_verdict(decision_record.id, verdict)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{}} -> {:ok, verdict}
        {:error, _step, reason, _changes_so_far} -> {:error, reason}
      end
    end
  end

  @doc """
  Persists `task` as a pending `Run` and enqueues `RouteWorker` to carry it
  through routing, execution, and evaluation asynchronously via Oban.

  Returns `{:ok, run_id}` as soon as the `Run` row and the `RouteWorker` job
  are durably inserted, without waiting on any worker to run.

  `opts` mirrors `run_sync/2`'s `:policy`/`:adapter`/`:judge` overrides; each
  is translated to its `OverrideRegistry` string key and persisted on the
  `Run` row's `overrides` field, not the job args — `RouteWorker` and the
  workers downstream of it resolve their policy/adapter/judge from
  `run.overrides`, keeping job args down to ids only.
  """
  @spec submit(map(), keyword()) :: {:ok, Ecto.UUID.t()} | {:error, term()}
  def submit(task, opts \\ []) when is_map(task) do
    policy = Keyword.get(opts, :policy, @default_policy)
    adapter = Keyword.get(opts, :adapter, @default_adapter)
    judge = Keyword.get(opts, :judge, @default_judge)

    overrides = %{
      "policy" => OverrideRegistry.key_for(:policy, policy),
      "adapter" => OverrideRegistry.key_for(:adapter, adapter),
      "judge" => OverrideRegistry.key_for(:judge, judge)
    }

    Multi.new()
    |> Multi.insert(:run, Persistence.pending_run_changeset(task, overrides))
    |> Oban.insert(:route_job, fn %{run: run} -> RouteWorker.new(%{run_id: run.id}) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{run: run}} -> {:ok, run.id}
      {:error, _step, changeset, _changes_so_far} -> {:error, changeset}
    end
  end
end
