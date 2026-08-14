defmodule Kapelle.Product.Store do
  @moduledoc """
  The immutable artifact store (design doc §5; owner's S2 preamble item 4).
  put/2 is idempotent by canonical hash: identical bytes are a no-op,
  divergent bytes under the same identity are a typed conflict. The write
  IS the authoritative commit; the Event goes out only after it succeeds.
  """

  alias Kapelle.Product.{CanonicalHash, Event, Events, Record}
  alias Kapelle.Product.Records.ArtifactRow
  alias Kapelle.Repo

  @kind_refs %{
    idea: "idea",
    research_pack: "research-pack",
    concept_draft: "concept-draft",
    product_proposal: "proposal",
    exchange_log: "exchange-log",
    loop_state: "loop-state",
    gate_decision: "gate-decision"
  }

  @spec put(Record.t(), String.t()) ::
          {:ok, :inserted | :noop}
          | {:error, {:artifact_conflict, atom(), String.t(), String.t(), String.t()}}
          | {:error, Ecto.Changeset.t()}
  def put(%Record{kind: kind, id: id, doc: doc}, loop_id) when is_binary(loop_id) do
    hash = CanonicalHash.hash(doc)

    case Repo.get_by(ArtifactRow, loop_id: loop_id, kind: to_string(kind), identity: id) do
      %ArtifactRow{canonical_hash: ^hash} ->
        {:ok, :noop}

      %ArtifactRow{canonical_hash: existing} ->
        {:error, {:artifact_conflict, kind, id, existing, hash}}

      nil ->
        insert_new(kind, id, doc, hash, loop_id)
    end
  end

  defp insert_new(kind, id, doc, hash, loop_id) do
    %ArtifactRow{}
    |> ArtifactRow.changeset(%{
      loop_id: loop_id,
      kind: to_string(kind),
      identity: id,
      canonical_hash: hash,
      doc: doc
    })
    |> Repo.insert()
    |> case do
      {:ok, _row} ->
        Events.broadcast(%Event{
          loop_id: loop_id,
          kind: :artifact_stored,
          artifact_kind: kind,
          artifact_ref: "#{@kind_refs[kind]}://#{id}",
          artifact_hash: hash,
          producer: nil
        })

        {:ok, :inserted}

      {:error, %Ecto.Changeset{} = changeset} ->
        retry_or_fail(changeset, kind, id, doc, loop_id)
    end
  end

  # Insert race on the composite PK: re-read and reclassify — the
  # winner's bytes decide noop vs conflict.
  defp retry_or_fail(changeset, kind, id, doc, loop_id) do
    if pk_violation?(changeset) do
      put(%Record{kind: kind, id: id, doc: doc}, loop_id)
    else
      {:error, changeset}
    end
  end

  @spec all(String.t()) :: [
          %{kind: atom(), id: String.t(), doc: map(), canonical_hash: String.t()}
        ]
  def all(loop_id) do
    import Ecto.Query, only: [from: 2]

    Repo.all(from(a in ArtifactRow, where: a.loop_id == ^loop_id, order_by: a.inserted_at))
    |> Enum.map(fn row ->
      %{
        kind: String.to_existing_atom(row.kind),
        id: row.identity,
        doc: row.doc,
        canonical_hash: row.canonical_hash
      }
    end)
  end

  defp pk_violation?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_msg, meta}} ->
      meta[:constraint] == :unique
    end)
  end
end
