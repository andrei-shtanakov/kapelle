defmodule Kapelle.Product.Identity do
  @moduledoc """
  The per-kind identity table (owner's S2 preamble, item 2). Identity comes
  from the document's own identity field — never from a file path, never a
  generated UUID. Distinct from S3's idempotency key
  `(loop_id, iteration, stage, input_hash)`.
  """

  @fields %{
    idea: "id",
    research_pack: "id",
    concept_draft: "id",
    exchange_log: "id",
    product_proposal: "proposal_id",
    loop_state: "loop_id",
    gate_decision: "decision_id",
    loop_resume_decision: "decision_id"
  }

  @spec field(atom()) :: String.t()
  def field(kind), do: Map.fetch!(@fields, kind)

  @spec of(atom(), map()) ::
          {:ok, String.t()} | {:error, {:missing_identity, atom(), String.t()}}
  def of(kind, doc) when is_map(doc) do
    field = field(kind)

    case doc do
      %{^field => id} when is_binary(id) -> {:ok, id}
      _ -> {:error, {:missing_identity, kind, field}}
    end
  end
end
