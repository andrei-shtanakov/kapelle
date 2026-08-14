defmodule Kapelle.Product.Workers.CreatorWorker do
  @moduledoc """
  The creator stage over `Kapelle.Product.Workers.StageShell` (design doc
  §5, Task 7): produce a concept draft for the loop's own iteration,
  reject a stale research-pack reference *before* persisting anything
  (the producer's own check, loop.py:580 — fail-closed, a domain
  failure, not a schema one: the schema only requires `based_on_research`
  to look like a ref, not that it names this iteration's actual pack),
  then validate, persist, and append the exchange-log entry.
  """

  use Oban.Worker, queue: :product

  alias Kapelle.Product.Agent
  alias Kapelle.Product.Workers.StageShell

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}), do: StageShell.run(args, stage_impl())

  defp stage_impl do
    %{
      stage: :concept,
      output_exists?: &output_exists?/2,
      execute: &execute/3
    }
  end

  defp output_exists?(view, iteration), do: Map.has_key?(view.concept_drafts, iteration)

  defp execute(view, iteration, loop) do
    {agent_mod, key} = Agent.resolve!(loop.agent)
    rp = view.research_packs[iteration]

    with {:ok, doc} <- agent_mod.produce(:creator, iteration, %{key: key, view: view}),
         :ok <- check_research_ref(doc, rp),
         :ok <- StageShell.persist_document(:concept_draft, doc, loop.loop_id) do
      StageShell.append_exchange_entry(loop, view, %{
        "iteration" => iteration,
        "actor" => "creator",
        "artifact_kind" => "concept_draft",
        "artifact_ref" => "concept-draft://" <> doc["id"],
        "at" => StageShell.now_iso()
      })
    end
  end

  defp check_research_ref(doc, rp) do
    expected = "research-pack://" <> rp["id"]

    case get_in(doc, ["based_on_research", "ref"]) do
      ^expected -> :ok
      got -> {:error, {:domain, {:stale_reference, %{expected: expected, got: got}}}}
    end
  end
end
