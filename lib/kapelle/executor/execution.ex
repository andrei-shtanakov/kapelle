defmodule Kapelle.Executor.Execution do
  @moduledoc """
  Shared execution seam: resolves the catalog entry for a `Decision`'s
  routed target and walks `[target | fallback]` via
  `Kapelle.Executor.FallbackResolver.resolve/2` against `adapter`.

  `Kapelle.Orchestrator.Pipeline.run_sync/2` and
  `Kapelle.Orchestrator.Workers.ExecuteWorker` both call `run/3` instead of
  `adapter.execute/2` directly, so REQ-104's runtime guarantee — a
  provider `:error` moves execution to the next declared target — holds
  identically on both the sync and async paths.
  """

  alias Kapelle.Executor.FallbackResolver
  alias Kapelle.Executor.Result
  alias Kapelle.Providers.Catalog
  alias Kapelle.Providers.Catalog.Entry
  alias Kapelle.Router.Decision

  @doc """
  Executes `task` against `decision`'s routed target via `adapter`,
  falling back along the target's catalog-declared chain on a provider
  `:error`.

  Returns `{:ok, Result.t()}` from whichever target served (`:pass` or
  `:fail`, never triggering a fallback), or `{:error, reason}` — either
  `{:all_targets_errored, rejections}` if every target in the chain
  errored, or a catalog lookup failure if the routed target isn't a known
  catalog id.
  """
  @spec run(map(), Decision.t(), module()) ::
          {:ok, Result.t()} | {:error, term()}
  def run(task, %Decision{target: %{provider: provider, model: model}} = decision, adapter)
      when is_map(task) and is_atom(adapter) do
    id = "#{provider}@#{model}"

    with {:ok, entries} <- Catalog.list(),
         {:ok, entry} <- fetch_entry(entries, id) do
      entries_by_id = Map.new(entries, &{&1.id, &1})

      FallbackResolver.resolve(entry, fn target_id ->
        attempt(task, decision, adapter, entries_by_id, target_id)
      end)
    end
  end

  defp attempt(task, %Decision{} = decision, adapter, entries_by_id, target_id) do
    %Entry{provider: provider, model: model} = Map.fetch!(entries_by_id, target_id)
    adapter.execute(task, %Decision{decision | target: %{provider: provider, model: model}})
  end

  defp fetch_entry(entries, id) do
    case Enum.find(entries, &(&1.id == id)) do
      nil -> {:error, {:unknown_model_id, id}}
      entry -> {:ok, entry}
    end
  end
end
