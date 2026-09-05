defmodule Kapelle.Product.Loops do
  @moduledoc """
  Loop configuration plus a best-effort state-projection surface (design
  doc §5; owner's loop-state-leaves-the-store decision, 2026-08-14).
  `product_loops` is NOT the authoritative artifact store: `latest_state`
  is a pure, deletable/reconstructible projection of the producer-format
  loop-state document, and `status`/`stop_reason` are this codebase's own
  loop lifecycle — not lifted from the producer's `stop.verdict`.
  """

  import Ecto.Query, only: [from: 2]

  alias Kapelle.Product.Records.LoopRow
  alias Kapelle.Repo

  @terminal_statuses ~w(ready needs_human failed)

  @doc """
  Creates a loop's configuration row with default status `"running"`.
  Refuses an already-initialized `loop_id` with a typed error rather than
  a raised constraint violation.
  """
  @spec create(map()) ::
          {:ok, LoopRow.t()} | {:error, :already_initialized | Ecto.Changeset.t()}
  def create(attrs) do
    %LoopRow{}
    |> LoopRow.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, row} -> {:ok, row}
      {:error, changeset} -> classify_insert_error(changeset)
    end
  end

  defp classify_insert_error(changeset) do
    if pk_violation?(changeset) do
      {:error, :already_initialized}
    else
      {:error, changeset}
    end
  end

  defp pk_violation?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_msg, meta}} -> meta[:constraint] == :unique end)
  end

  @doc "Fetches a loop's configuration row, raising if `loop_id` is unknown."
  @spec get!(String.t()) :: LoopRow.t()
  def get!(loop_id), do: Repo.get!(LoopRow, loop_id)

  @doc """
  Fetches a loop's configuration row without raising: `:error` for an
  unknown `loop_id`. For read-only callers that must answer "unknown loop"
  as data rather than as an exception — reporting, in particular.
  """
  @spec fetch(String.t()) :: {:ok, LoopRow.t()} | :error
  def fetch(loop_id) do
    case Repo.get(LoopRow, loop_id) do
      nil -> :error
      row -> {:ok, row}
    end
  end

  @doc """
  Monotonic terminal status transition (the Terminal pattern from
  `Kapelle.Orchestrator.Workers.Terminal`, written locally — read for the
  pattern, never imported): a single conditional `UPDATE ... WHERE status
  = 'running'` folds the check-and-set into one atomic statement, so two
  concurrent finalizers on the same loop race at the database instead of
  in application code. Returns `{:error, :already_terminal}` — without
  touching `stop_reason` — when the loop was already terminal, so a late
  transition can never overwrite an earlier one.
  """
  @spec set_status(String.t(), String.t(), String.t() | nil) ::
          {:ok, :transitioned} | {:error, :already_terminal}
  def set_status(loop_id, status, reason) when status in @terminal_statuses do
    query = from(l in LoopRow, where: l.loop_id == ^loop_id and l.status == "running")

    case Repo.update_all(query,
           set: [status: status, stop_reason: reason, updated_at: DateTime.utc_now()]
         ) do
      {1, _} -> {:ok, :transitioned}
      {0, _} -> {:error, :already_terminal}
    end
  end

  @doc """
  Overwrites the loop's `latest_state` projection. Idempotent (the same
  document written twice leaves the same state) and independent of
  `status` — a projection write never checks or changes the loop's
  lifecycle status.
  """
  @spec put_state_projection(String.t(), map()) :: {:ok, LoopRow.t()}
  def put_state_projection(loop_id, state_doc) when is_map(state_doc) do
    {1, _} =
      Repo.update_all(
        from(l in LoopRow, where: l.loop_id == ^loop_id),
        set: [latest_state: state_doc, updated_at: DateTime.utc_now()]
      )

    {:ok, get!(loop_id)}
  end

  @doc """
  The one non-monotonic transition this module allows: a held
  (`"needs_human"`) loop back to `"running"` with a strictly widened
  budget, clearing `stop_reason` — the DB-transaction-safe half of
  `Kapelle.Product.Resume`'s atomic consume transition (design doc §7).
  Row-locks (`FOR UPDATE`) the loop before re-checking hold and budget,
  so it must run inside the caller's own `Repo.transaction`/`Ecto.Multi`;
  called outside one, the lock is released the instant this query
  returns and buys no protection against a concurrent resume of the same
  loop. Returns typed refusals rather than raising when the row no
  longer agrees with what the caller already checked (a race the
  in-Elixir precheck in `Kapelle.Product.Resume` cannot itself close),
  including for an unknown `loop_id` (`:not_found`) rather than raising
  a `CaseClauseError` on the `nil` `Repo.one/1` returns for it.
  """
  @spec resume(String.t(), pos_integer()) ::
          {:ok, LoopRow.t()}
          | {:error, :not_found | :not_held | :non_widening_budget}
  def resume(loop_id, new_max_iterations) when is_integer(new_max_iterations) do
    query = from(l in LoopRow, where: l.loop_id == ^loop_id, lock: "FOR UPDATE")

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      %LoopRow{status: "needs_human", max_iterations: current}
      when current < new_max_iterations ->
        {1, _} =
          Repo.update_all(
            from(l in LoopRow, where: l.loop_id == ^loop_id),
            set: [
              status: "running",
              max_iterations: new_max_iterations,
              stop_reason: nil,
              updated_at: DateTime.utc_now()
            ]
          )

        {:ok, get!(loop_id)}

      %LoopRow{status: "needs_human"} ->
        {:error, :non_widening_budget}

      %LoopRow{} ->
        {:error, :not_held}
    end
  end
end
