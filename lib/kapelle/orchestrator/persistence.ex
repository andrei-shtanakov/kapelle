defmodule Kapelle.Orchestrator.Persistence do
  @moduledoc """
  Pure mapping functions from the pipeline's contract structs
  (`Kapelle.Router.Decision`, `Kapelle.Executor.Result`,
  `Kapelle.Evaluator.Verdict`) and the submitted task map to
  `Kapelle.Orchestrator.Records` schema-insert attrs.

  No DB access here — plain maps in, plain maps out.
  """

  alias Ecto.Multi
  alias Kapelle.Evaluator.Verdict
  alias Kapelle.Executor.Result
  alias Kapelle.Orchestrator.Records.Decision, as: DecisionRecord
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.Records.RunTask
  alias Kapelle.Orchestrator.Records.Verdict, as: VerdictRecord
  alias Kapelle.Repo
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
  linked to `run_id` and `decision_id`. `output`, `duration_ms`, and
  `artifacts` are carried over verbatim.
  """
  @spec run_task_attrs(Ecto.UUID.t(), Ecto.UUID.t(), Result.t()) :: map()
  def run_task_attrs(run_id, decision_id, %Result{} = result) do
    %{
      run_id: run_id,
      decision_id: decision_id,
      task_id: result.task_id,
      status: to_string(result.status),
      output: result.output,
      duration_ms: result.duration_ms,
      artifacts: result.artifacts
    }
  end

  @doc """
  Builds insert attrs for `Records.Decision` from a `Router.Decision`,
  linked to `run_id`. `id` is set to `decision.decision_id` so the row's
  primary key matches the contract struct verbatim.
  """
  @spec decision_attrs(Ecto.UUID.t(), Decision.t()) :: map()
  def decision_attrs(run_id, %Decision{} = decision) do
    %{
      id: decision.decision_id,
      run_id: run_id,
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

  @doc """
  Persists a full pipeline run (`run`, `run_task`, `decision`, `verdict`) in
  a single `Ecto.Multi` transaction, each step reading the prior step's id
  off the `Multi` changes map. Either all four rows are inserted or none
  are.

  Returns `{:error, :verdict_decision_mismatch}` without touching the DB if
  `verdict.decision_id` doesn't match `decision.decision_id` — `verdict_attrs/2`
  always links the verdict row to `decision.decision_id`, so a mismatched
  `verdict` would otherwise be silently persisted against the wrong decision.
  """
  @spec record_run(map(), Decision.t(), Result.t(), Verdict.t()) ::
          {:ok,
           %{
             run: Run.t(),
             run_task: RunTask.t(),
             decision: DecisionRecord.t(),
             verdict: VerdictRecord.t()
           }}
          | {:error, {atom(), Ecto.Changeset.t()}}
          | {:error, :verdict_decision_mismatch}
  def record_run(task, %Decision{} = decision, %Result{} = result, %Verdict{} = verdict) do
    if verdict.decision_id == decision.decision_id do
      Multi.new()
      |> Multi.insert(:run, Run.changeset(%Run{}, run_attrs(task)))
      |> Multi.insert(:decision, fn %{run: run} ->
        DecisionRecord.changeset(%DecisionRecord{}, decision_attrs(run.id, decision))
      end)
      |> Multi.insert(:run_task, fn %{run: run, decision: decision_record} ->
        RunTask.changeset(%RunTask{}, run_task_attrs(run.id, decision_record.id, result))
      end)
      |> Multi.insert(:verdict, fn %{decision: decision_record} ->
        VerdictRecord.changeset(%VerdictRecord{}, verdict_attrs(decision_record.id, verdict))
      end)
      |> Repo.transaction()
      |> case do
        {:ok, records} -> {:ok, records}
        {:error, failed_step, changeset, _changes_so_far} -> {:error, {failed_step, changeset}}
      end
    else
      {:error, :verdict_decision_mismatch}
    end
  end
end
