defmodule Kapelle.Test.MismatchedJudge do
  @moduledoc """
  `Kapelle.Evaluator.Judge` test double that always emits a `Verdict`
  linked to a random `decision_id` instead of `task[:decision_id]`, so
  tests can prove `Persistence.record_verdict/2`'s mismatch guard is
  reachable through `Pipeline.run_sync/2`, not just unit-tested in
  isolation.
  """

  @behaviour Kapelle.Evaluator.Judge

  alias Kapelle.Evaluator.Verdict

  @impl true
  def evaluate(_task, result) do
    {:ok,
     Verdict.new!(%{
       decision_id: Ecto.UUID.generate(),
       task_id: result.task_id,
       total_score: 1.0,
       score_components: %{status_match: 1.0}
     })}
  end
end
