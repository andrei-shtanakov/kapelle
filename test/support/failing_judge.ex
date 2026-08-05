defmodule Kapelle.Test.FailingJudge do
  @moduledoc """
  `Kapelle.Evaluator.Judge` test double that always returns an error, so
  tests can assert the pipeline skips persistence when evaluation fails.
  """

  @behaviour Kapelle.Evaluator.Judge

  @impl true
  def evaluate(_task, _result), do: {:error, :judge_failed}
end
