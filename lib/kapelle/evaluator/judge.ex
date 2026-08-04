defmodule Kapelle.Evaluator.Judge do
  @moduledoc """
  Behaviour for scoring an executed task's `Result` into a `Verdict`.
  """

  alias Kapelle.Evaluator.Verdict
  alias Kapelle.Executor.Result

  @callback evaluate(task :: map(), result :: Result.t()) ::
              {:ok, Verdict.t()} | {:error, term()}
end
