defmodule Kapelle.Orchestrator.Workers.Terminal do
  @moduledoc """
  Shared failure helper for the orchestrator workers: on a stage's final
  attempt, persists the owning `Run` as `"failed"` and tells Oban to stop
  retrying; on every earlier attempt, leaves the `Run` untouched and
  preserves today's retry behavior.
  """

  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Repo

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
