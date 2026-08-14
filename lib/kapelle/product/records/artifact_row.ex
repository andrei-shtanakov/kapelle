defmodule Kapelle.Product.Records.ArtifactRow do
  @moduledoc """
  Ecto schema for the `product_artifacts` table.

  One row per stored artifact, keyed by the composite primary key
  `(loop_id, kind, identity)` — that triple IS the immutable identity
  (design doc §5; owner's S2 preamble, item 2). No surrogate UUID.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "product_artifacts" do
    field :loop_id, :string, primary_key: true
    field :kind, :string, primary_key: true
    field :identity, :string, primary_key: true
    field :canonical_hash, :string
    field :doc, :map

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{
          loop_id: String.t() | nil,
          kind: String.t() | nil,
          identity: String.t() | nil,
          canonical_hash: String.t() | nil,
          doc: map() | nil,
          inserted_at: DateTime.t() | nil
        }

  @doc """
  Builds a changeset for inserting an `ArtifactRow`, requiring all
  columns and mapping a composite-PK violation onto `:identity` so the
  race path in `Kapelle.Product.Store.put/2` lands here instead of
  raising (mirrors `EvaluateWorker`'s unique-constraint precedent).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, [:loop_id, :kind, :identity, :canonical_hash, :doc])
    |> validate_required([:loop_id, :kind, :identity, :canonical_hash, :doc])
    |> unique_constraint(:identity, name: :product_artifacts_pkey)
  end
end
