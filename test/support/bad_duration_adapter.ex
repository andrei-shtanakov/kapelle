defmodule Kapelle.Test.BadDurationAdapter do
  @moduledoc """
  `Kapelle.Executor.Adapter` test double returning a `Result` whose
  `duration_ms` isn't castable to the `run_tasks.duration_ms` `:integer`
  column, so tests can force `Persistence.record_run_task/3`'s insert to
  fail with an `Ecto.Changeset` error — exercising the `Multi.run(:run_task,
  ...)` step's failure/rollback path specifically.
  """

  @behaviour Kapelle.Executor.Adapter

  alias Kapelle.Executor.Result

  @impl true
  def execute(%{id: task_id}, _decision) do
    {:ok, Result.new!(%{task_id: task_id, status: :pass, duration_ms: "not-a-number"})}
  end
end
