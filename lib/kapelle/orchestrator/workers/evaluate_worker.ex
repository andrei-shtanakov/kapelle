defmodule Kapelle.Orchestrator.Workers.EvaluateWorker do
  @moduledoc """
  Placeholder `evaluator`-queue worker `ExecuteWorker` enqueues after
  execution.

  Full behavior (reload `Run`/`RunTask`, evaluate, persist `Verdict`) lands
  in TASK-007/DESIGN-007.
  """

  use Oban.Worker, queue: :evaluator

  @impl Oban.Worker
  def perform(_job), do: :ok
end
