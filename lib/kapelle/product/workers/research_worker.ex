defmodule Kapelle.Product.Workers.ResearchWorker do
  @moduledoc """
  The researcher stage over `Kapelle.Product.Workers.StageShell` (design
  doc §5, Task 7): produce a research pack for the loop's own iteration,
  validate and persist it, append the exchange-log entry (the log is
  born here on iteration 0 — `StageShell.append_exchange_entry/3`), and
  let the shared shell decide what runs next.
  """

  use Oban.Worker, queue: :product

  alias Kapelle.Product.Agent
  alias Kapelle.Product.Workers.StageShell

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}), do: StageShell.run(args, stage_impl())

  defp stage_impl do
    %{
      stage: :research,
      output_exists?: &output_exists?/2,
      execute: &execute/3
    }
  end

  defp output_exists?(view, iteration), do: Map.has_key?(view.research_packs, iteration)

  defp execute(view, iteration, loop) do
    {agent_mod, key} = Agent.resolve!(loop.agent)

    with {:ok, doc} <- agent_mod.produce(:researcher, iteration, %{key: key, view: view}),
         :ok <- StageShell.persist_document(:research_pack, doc, loop.loop_id) do
      StageShell.append_exchange_entry(loop, view, %{
        "iteration" => iteration,
        "actor" => "researcher",
        "artifact_kind" => "research_pack",
        "artifact_ref" => "research-pack://" <> doc["id"],
        "at" => StageShell.now_iso()
      })
    end
  end
end
