defmodule Kapelle.Product.Workers.ResearchWorker do
  @moduledoc """
  Placeholder `product`-queue worker, pulled forward from Task 7 (owner's
  ruling, 2026-08-14) so `Kapelle.Product.Loop.start/2` (Task 6) has a
  real module to enqueue its first stage job against. `perform/1` is
  Task 7's work — this stub exists only so the module compiles and can
  be named as a job's worker.
  """

  use Oban.Worker, queue: :product

  @impl Oban.Worker
  def perform(_job), do: {:error, :not_implemented_until_task_7}
end
