defmodule Kapelle.Product.Reconciler do
  @moduledoc """
  Idempotent repair over a loop's own artifacts (design doc §5, Task 8).
  `reconcile/1` is an out-of-band caller's entry point (a periodic sweep,
  or an operator running it by hand after a suspected crash) into
  `Kapelle.Product.Workers.StageShell.repair/1` — the identical
  computation the worker shell already performs after every stage
  completes, shared rather than duplicated so the projection shape and
  the `input_hash` chain a repair enqueues can never drift from what a
  normal stage worker would have produced.

  A terminal loop reconciles to `:terminal` untouched. A running loop
  whose projection or job queue has drifted from what its own stored
  artifacts imply is repaired and reconciles to `:repaired`. A running
  loop that already agrees with its own artifacts — same projection,
  same job already enqueued (Oban's own uniqueness dedup proves it) — is
  `:in_sync`: calling `reconcile/1` twice in a row on a healthy loop
  always lands here the second time.
  """

  alias Kapelle.Product.Workers.StageShell

  @spec reconcile(String.t()) ::
          {:ok, :terminal | :repaired | :in_sync} | {:error, term()}
  def reconcile(loop_id) when is_binary(loop_id), do: StageShell.repair(loop_id)
end
