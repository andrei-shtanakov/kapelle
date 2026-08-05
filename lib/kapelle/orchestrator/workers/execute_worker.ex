defmodule Kapelle.Orchestrator.Workers.ExecuteWorker do
  @moduledoc """
  Placeholder `executor`-queue worker `RouteWorker` enqueues after routing.

  Full behavior (reload `Run`/`Decision`, execute, persist `RunTask`,
  enqueue `EvaluateWorker`) lands in TASK-006/DESIGN-006.
  """

  use Oban.Worker, queue: :executor

  @impl Oban.Worker
  def perform(_job), do: :ok
end
