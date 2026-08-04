defmodule Kapelle.Executor.Adapter do
  @moduledoc """
  Behaviour for executing a routed task against its `Decision` target.

  Implementations perform the task (fake, or a real provider call) and
  return a `Kapelle.Executor.Result` recording the outcome.
  """

  alias Kapelle.Executor.Result
  alias Kapelle.Router.Decision

  @callback execute(task :: map(), decision :: Decision.t()) ::
              {:ok, Result.t()} | {:error, term()}
end
