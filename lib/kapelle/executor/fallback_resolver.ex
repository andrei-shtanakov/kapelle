defmodule Kapelle.Executor.FallbackResolver do
  @moduledoc """
  Walks a catalog entry's declared `fallback` chain, stopping at the first
  target whose attempt does not error.

  A provider `:error` (the provider itself failed, either as a bare
  `{:error, reason}` from the attempt or as a `Result` with
  `status: :error`) moves resolution on to the next target. A `:fail`
  result (the provider answered, and the answer was a failure) is a valid
  outcome and is returned as-is — it never triggers a fallback.

  Chain validation (unknown targets, cycles) happens once, at catalog load
  time (`Kapelle.Providers.Catalog.load/1`); by the time a chain reaches
  this module every id in it is known to exist.
  """

  alias Kapelle.Executor.Result
  alias Kapelle.Providers.Catalog.Entry

  @typedoc "a target id paired with the reason its attempt was rejected"
  @type rejection :: {String.t(), term()}

  @doc """
  Attempts `entry.id`, then each id in `entry.fallback` in order, calling
  `attempt.(id)` for each, and stops at the first attempt that is not a
  provider error.

  Returns `{:ok, result}` with `result.target` set to whichever id served
  and `result.rejected` set to the ordered rejections of every earlier
  target, or `{:error, {:all_targets_errored, rejections}}` if every
  target in the chain errored.
  """
  @spec resolve(Entry.t(), (String.t() -> {:ok, Result.t()} | {:error, term()})) ::
          {:ok, Result.t()} | {:error, {:all_targets_errored, [rejection()]}}
  def resolve(%Entry{id: id, fallback: fallback}, attempt) when is_function(attempt, 1) do
    walk([id | fallback], attempt, [])
  end

  defp walk([id | rest], attempt, rejected) do
    case classify(attempt.(id)) do
      {:final, result} ->
        {:ok, %Result{result | target: id, rejected: Enum.reverse(rejected)}}

      {:reject, reason} ->
        reject_or_halt(rest, attempt, [{id, reason} | rejected])
    end
  end

  defp reject_or_halt([], _attempt, rejected) do
    {:error, {:all_targets_errored, Enum.reverse(rejected)}}
  end

  defp reject_or_halt(rest, attempt, rejected) do
    walk(rest, attempt, rejected)
  end

  defp classify({:ok, %Result{status: status} = result}) when status in [:pass, :fail] do
    {:final, result}
  end

  defp classify({:ok, %Result{} = result}), do: {:reject, result}
  defp classify({:error, reason}), do: {:reject, reason}
end
