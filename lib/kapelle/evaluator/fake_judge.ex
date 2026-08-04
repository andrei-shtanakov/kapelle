defmodule Kapelle.Evaluator.FakeJudge do
  @moduledoc """
  `Kapelle.Evaluator.Judge` test double deriving a deterministic score from
  `Result.status` — makes no network calls. Used to prove the M1 pipeline
  and by dev seeds.

  Requires `task[:decision_id]` (the pipeline injects this before calling
  `evaluate/2`) so the emitted `Verdict` references its originating
  `Decision`.
  """

  @behaviour Kapelle.Evaluator.Judge

  alias Kapelle.Evaluator.Verdict
  alias Kapelle.Executor.Result

  @score_by_status %{pass: 1.0, fail: 0.0, error: 0.0}

  @impl true
  def evaluate(%{decision_id: decision_id}, %Result{} = result) do
    score = Map.fetch!(@score_by_status, result.status)

    {:ok,
     Verdict.new!(%{
       decision_id: decision_id,
       task_id: result.task_id,
       total_score: score,
       score_components: %{status_match: score}
     })}
  end
end
