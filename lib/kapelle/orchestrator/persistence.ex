defmodule Kapelle.Orchestrator.Persistence do
  @moduledoc """
  Pure mapping functions from the pipeline's contract structs
  (`Kapelle.Router.Decision`, `Kapelle.Executor.Result`,
  `Kapelle.Evaluator.Verdict`) and the submitted task map to
  `Kapelle.Orchestrator.Records` schema-insert attrs.

  No DB access here — plain maps in, plain maps out.
  """

  alias Kapelle.Evaluator.Verdict
  alias Kapelle.Executor.Result
  alias Kapelle.Router.Decision

  @doc """
  Builds insert attrs for `Records.Run` from the submitted `task` map.
  """
  @spec run_attrs(map()) :: map()
  def run_attrs(task) when is_map(task) do
    %{task_id: Map.fetch!(task, :id), status: "completed"}
  end

  @doc """
  Builds insert attrs for `Records.RunTask` from an `Executor.Result`,
  linked to `run_id`. `output`, `duration_ms`, and `artifacts` are
  carried over verbatim.
  """
  @spec run_task_attrs(Ecto.UUID.t(), Result.t()) :: map()
  def run_task_attrs(run_id, %Result{} = result) do
    %{
      run_id: run_id,
      task_id: result.task_id,
      status: to_string(result.status),
      output: result.output,
      duration_ms: result.duration_ms,
      artifacts: result.artifacts
    }
  end

  @doc """
  Builds insert attrs for `Records.Decision` from a `Router.Decision`,
  linked to `run_task_id`. `id` is set to `decision.decision_id` so the
  row's primary key matches the contract struct verbatim.
  """
  @spec decision_attrs(Ecto.UUID.t(), Decision.t()) :: map()
  def decision_attrs(run_task_id, %Decision{} = decision) do
    %{
      id: decision.decision_id,
      run_task_id: run_task_id,
      task_id: decision.task_id,
      target: decision.target,
      features: decision.features,
      decided_at: decision.decided_at
    }
  end

  @doc """
  Builds insert attrs for `Records.Verdict` from an `Evaluator.Verdict`,
  linked to `decision_id`. `score_components` is never dropped, matching
  the invariant `Evaluator.Verdict` itself enforces.
  """
  @spec verdict_attrs(Ecto.UUID.t(), Verdict.t()) :: map()
  def verdict_attrs(decision_id, %Verdict{} = verdict) do
    %{
      decision_id: decision_id,
      task_id: verdict.task_id,
      total_score: verdict.total_score,
      score_components: verdict.score_components
    }
  end
end
