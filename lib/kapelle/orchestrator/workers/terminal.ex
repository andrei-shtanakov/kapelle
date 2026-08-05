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
end
