defmodule Kapelle.Test.ExecuteAdapter do
  @moduledoc """
  `Kapelle.Executor.Adapter` test double matching the atom-keyed task shape
  `ExecuteWorker` builds via `Persistence.atomize_task/1` (the same shape
  `Pipeline.run_sync/2` passes directly). Returns `{:error, :unexecutable}`
  for `%{id: "unexecutable"}` so execution-failure paths are reachable too.
  """

  @behaviour Kapelle.Executor.Adapter

  alias Kapelle.Executor.Result

  @impl true
  def execute(%{id: "unexecutable"}, _decision), do: {:error, :unexecutable}

  def execute(%{id: task_id}, _decision) do
    {:ok, Result.new!(%{task_id: task_id, status: :pass})}
  end
end
