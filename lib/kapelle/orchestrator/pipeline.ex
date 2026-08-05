defmodule Kapelle.Orchestrator.Pipeline do
  @moduledoc """
  Synchronous submit → route → execute → evaluate pipeline (M1 vertical
  slice). Each step runs inline in the caller's process; Oban-backed async
  execution arrives in TASK-006.
  """

  alias Kapelle.Evaluator.FakeJudge
  alias Kapelle.Evaluator.Verdict
  alias Kapelle.Executor.FakeAdapter
  alias Kapelle.Orchestrator.Persistence
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
           {:ok, _records} <- Persistence.record_run(task, decision, result, verdict) do
        {:ok, verdict}
      end
    end
  end
end
