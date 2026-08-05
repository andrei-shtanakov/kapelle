defmodule Kapelle.Orchestrator.Workers.Terminal do
  @moduledoc """
  Shared failure helper for the orchestrator workers: on a stage's final
  attempt, persists the owning `Run` as `"failed"` and tells Oban to stop
  retrying; on every earlier attempt, leaves the `Run` untouched and
  preserves today's retry behavior.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Repo

  @terminal_statuses ~w(completed failed)

  @doc """
  Adds a conditional terminal-status transition to `multi`: sets the
  `Run` identified by `run_id` to `status`, but only if its current
  status is not already terminal (`"completed"`/`"failed"`).

  Expressed as a single `UPDATE ... WHERE` (via `Ecto.Multi.update_all/4`)
  rather than a read-then-write guard, because a guard built on a
  struct read (`if run.status not in terminal, do: update`) is a
  classic TOCTOU race: the read and the write are two separate
  round-trips, so two concurrent finalizers on the same run can both
  pass the guard before either commits. Folding the condition into the
  `WHERE` clause makes the whole check-and-set one atomic statement, so
  concurrent transitions on the same run race at the database instead
  of in application code — Postgres serializes the two `UPDATE`s and
  at most one of them matches the `WHERE` clause. The `{count, nil}`
  result this produces doubles as the row-count proof of atomicity:
  `1` means this call performed the transition, `0` means no row
  matched — either `run_id` was already terminal or it named no `Run`
  at all — and the call was a no-op either way.
  """
  @spec terminal_transition(Multi.t(), Multi.name(), Ecto.UUID.t(), String.t()) :: Multi.t()
  def terminal_transition(multi, name, run_id, status) when status in @terminal_statuses do
    query = from(r in Run, where: r.id == ^run_id and r.status not in @terminal_statuses)
    Multi.update_all(multi, name, query, set: [status: status, updated_at: DateTime.utc_now()])
  end

  @doc """
  Handles a stage failure for `run`/`job`/`reason`.

  On the final attempt (`attempt >= max_attempts`), updates `run` to
  `"failed"` and returns `{:discard, reason}` so Oban stops retrying the
  job — but only once that write is confirmed; if it fails, `{:error,
  reason}` is returned instead so Oban retries rather than discarding a
  job whose run was never actually marked failed. On any earlier
  attempt, returns `{:error, reason}` unchanged, leaving `run`'s status
  untouched and the job retryable.
  """
  @spec fail(Run.t(), Oban.Job.t(), term()) :: {:error, term()} | {:discard, term()}
  def fail(%Run{} = run, %Oban.Job{attempt: attempt, max_attempts: max_attempts}, reason) do
    if attempt >= max_attempts do
      case run |> Run.status_changeset("failed") |> Repo.update() do
        {:ok, _run} -> {:discard, reason}
        {:error, _changeset} -> {:error, reason}
      end
    else
      {:error, reason}
    end
  end

  @doc """
  True if `changeset` failed on a unique constraint for `field`.

  Lets a worker tell a genuine failure apart from losing a race to a
  concurrent duplicate delivery of the same job: both deliveries can pass
  an idempotency check before either commits, so the loser's insert hits
  the field's unique index rather than a real error. The winner already
  persisted the stage's state and enqueued the successor job, so the
  loser should treat this as success rather than routing through `fail/3`
  and marking `run` `"failed"` despite the pipeline having progressed.
  """
  @spec unique_violation?(Ecto.Changeset.t(), atom()) :: boolean()
  def unique_violation?(%Ecto.Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end
end
