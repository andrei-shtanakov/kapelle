defmodule Kapelle.Test.ExplodingJudge do
  @moduledoc """
  `Kapelle.Evaluator.Judge` test double that raises if reached — used to prove
  the pipeline short-circuits before evaluation on upstream errors.
  """

  @behaviour Kapelle.Evaluator.Judge

  @impl true
  def evaluate(_task, _result), do: raise("evaluate/2 must not be called")
end
