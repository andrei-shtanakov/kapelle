defmodule Kapelle.Product.NextStage do
  @moduledoc """
  The pure next-stage function over the canonical artifact view (design doc
  §5): a native port of the reference loop's stage progression and its
  deterministic evaluator. No IO, no clocks, no randomness — verified
  against the golden oracle (parity), not against the producer's code.
  """

  alias Kapelle.Product.View

  @type stage :: {:run, {:research | :concept | :apply, non_neg_integer()}}
  @type verdict :: {:terminal, :ready | :needs_human, String.t()}

  @spec compute(View.t(), pos_integer()) :: stage() | verdict()
  def compute(%View{} = view, max_iterations) when max_iterations > 0 do
    walk(view, 0, max_iterations)
  end

  defp walk(_view, i, max) when i >= max do
    {:terminal, :needs_human, "max_iterations reached with open critical items"}
  end

  defp walk(view, i, max) do
    rp = view.research_packs[i]
    cd = view.concept_drafts[i]

    cond do
      rp == nil -> {:run, {:research, i}}
      cd == nil -> {:run, {:concept, i}}
      not delta_applied?(view.proposal, i) -> {:run, {:apply, i}}
      true -> evaluate(rp, cd, i, max)
    end
  end

  defp delta_applied?(nil, _i), do: false
  defp delta_applied?(proposal, i), do: (proposal["iteration"] || -1) >= i

  defp evaluate(rp, cd, i, max) do
    issues = open_criticals(rp, cd)
    requests = Map.get(cd, "requests_to_researcher", [])

    cond do
      issues == [] and requests == [] ->
        {:terminal, :ready, "no open critical assumptions/gaps and no open requests"}

      i + 1 < max ->
        {:run, {:research, i + 1}}

      true ->
        {:terminal, :needs_human,
         "max_iterations reached with open critical items: " <>
           if(issues != [],
             do: Enum.join(issues, "; "),
             else: "#{length(requests)} open request(s)"
           )}
    end
  end

  # Port of the producer's open_criticals/2 (impresario loop.py:419-433).
  # The field shapes below are verified against the vendored schemas
  # (priv/contracts/impresario/{research-pack,concept-draft}/v1/schema.json),
  # NOT the brief's guessed "criticality"/"addresses" shape:
  #
  #   - research-pack `gaps` items are `{what, needed?, blocks_approval,
  #     closed?}` — there is no `criticality` enum, and there is no
  #     `assumptions` field on research-pack at all. An open gap is one
  #     with `blocks_approval: true` that has not been marked `closed`.
  #   - concept-draft `assumptions` items are `{text, blocks_approval,
  #     answered_by?, human_waiver?}` — again no `criticality` enum. An
  #     open assumption is one with `blocks_approval: true` that carries
  #     neither `answered_by` (a later research pack that resolved it)
  #     nor `human_waiver` (a human's explicit waiver).
  #   - concept-draft has no `addresses` list; there is no concept of the
  #     concept draft naming research-pack gaps as addressed. Each item
  #     records its own closure instead.
  defp open_criticals(rp, cd) do
    open_gaps =
      rp
      |> Map.get("gaps", [])
      |> Enum.filter(&open_gap?/1)
      |> Enum.map(& &1["what"])

    open_assumptions =
      cd
      |> Map.get("assumptions", [])
      |> Enum.filter(&open_assumption?/1)
      |> Enum.map(& &1["text"])

    open_gaps ++ open_assumptions
  end

  defp open_gap?(%{"blocks_approval" => true} = gap), do: gap["closed"] != true
  defp open_gap?(_gap), do: false

  defp open_assumption?(%{"blocks_approval" => true} = assumption) do
    is_nil(assumption["answered_by"]) and is_nil(assumption["human_waiver"])
  end

  defp open_assumption?(_assumption), do: false
end
