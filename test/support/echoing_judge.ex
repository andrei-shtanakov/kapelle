defmodule Kapelle.Test.EchoingJudge do
  @moduledoc """
  `Kapelle.Evaluator.Judge` test double that sends the received `task` map
  to the calling process, so tests can assert on exactly what a caller
  builds and passes to `evaluate/2`.
  """

  @behaviour Kapelle.Evaluator.Judge

  alias Kapelle.Evaluator.Verdict

  @impl true
  def evaluate(task, result) do
    send(self(), {:evaluate_task, task})

    {:ok,
     Verdict.new!(%{
       decision_id: task.decision_id,
       task_id: result.task_id,
       total_score: 1.0,
       score_components: %{}
     })}
  end
end
