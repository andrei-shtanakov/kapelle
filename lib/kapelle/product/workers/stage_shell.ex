defmodule Kapelle.Product.Workers.StageShell do
  @moduledoc """
  Shared plumbing for `product`-queue stage workers (design doc §5).
  `enqueue_stage/4` is pulled forward to Task 6 so `Kapelle.Product.Loop.start/2`
  can enqueue its first stage job; the full invariant shell around
  `perform/1` (view build, staleness/idempotency checks, agent call,
  projection update, next-stage enqueue) is Task 7's work.
  """

  @doc """
  Builds a stage job's args under the shared idempotency/uniqueness key
  `(loop_id, iteration, stage, input_hash)` and inserts it for
  `worker_module`, deduplicated on `(worker, args)` — a second insert
  with the same worker and args is a no-op rather than a duplicate job.
  """
  @spec enqueue_stage(module(), String.t(), {atom(), non_neg_integer()}, String.t()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def enqueue_stage(worker_module, loop_id, {stage, iteration}, input_hash) do
    args = %{
      "loop_id" => loop_id,
      "iteration" => iteration,
      "stage" => to_string(stage),
      "input_hash" => input_hash
    }

    args
    |> worker_module.new(unique: [fields: [:worker, :args]])
    |> Oban.insert()
  end
end
