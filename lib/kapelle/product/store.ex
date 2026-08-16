defmodule Kapelle.Product.Store do
  @moduledoc """
  The immutable artifact store (design doc §5; owner's revision-snapshot
  decision, 2026-08-14). put/2 is idempotent by canonical hash under the
  four-part key `(loop_id, kind, identity, revision)`: identical bytes at
  the same revision are a no-op, divergent bytes at the same revision are
  a typed conflict, a new admissible revision is a new immutable row.

  The authoritative write IS the commit: `put/2` refuses to run inside a
  caller-held ambient transaction (`Repo.in_transaction?/0`), because a
  nested "commit" there is not actually a commit, and the post-insert
  Event must never be observed before the real one lands. Oban's Basic
  engine executes `perform/1` outside any transaction, so this makes that
  assumption enforced rather than trusted. The Ecto SQL sandbox wraps
  every test in a transaction, so tests get an explicit, documented
  carve-out via `Application.get_env(:kapelle, :sandbox?, false)` (set in
  `config/test.exs`) — this is not a general bypass. If a future slice
  needs cross-write composition, the path is an outbox, not lifting this
  guard.

  `loop_state` is NOT stored here (owner's loop-state-leaves-the-store
  decision, 2026-08-14): it is a derived projection with no monotonic
  revision of its own, and lives in `Kapelle.Product.Loops`'s
  `latest_state` column instead. `put/2` refuses a `:loop_state` record
  with a typed `{:projection_kind, :loop_state}` error rather than
  silently accepting it into the authoritative store.
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
    gate_decision: "gate-decision",
    loop_resume_decision: "loop-resume-decision"
  }

  @doc """
  The revision component of a kind's storage key (owner's decision,
  2026-08-14): `product_proposal` revisions by its own `version`,
  `exchange_log` by its entry count, every other stored kind is `0`.
  """
  @spec revision_of(atom(), map()) :: integer()
  def revision_of(:product_proposal, doc), do: doc["version"]
  def revision_of(:exchange_log, doc), do: length(doc["entries"])
  def revision_of(_kind, _doc), do: 0

  @spec put(Record.t(), String.t()) ::
          {:ok, :inserted | :noop}
          | {:error, :ambient_transaction}
          | {:error, {:projection_kind, :loop_state}}
          | {:error, {:artifact_conflict, atom(), String.t(), String.t(), String.t()}}
          | {:error, Ecto.Changeset.t()}
  def put(%Record{kind: :loop_state}, loop_id) when is_binary(loop_id) do
    {:error, {:projection_kind, :loop_state}}
  end

  def put(%Record{kind: kind, id: id, doc: doc}, loop_id) when is_binary(loop_id) do
    if Repo.in_transaction?() and not sandbox?() do
      {:error, :ambient_transaction}
    else
      hash = CanonicalHash.hash(doc)
      revision = revision_of(kind, doc)

      case Repo.get_by(ArtifactRow,
             loop_id: loop_id,
             kind: to_string(kind),
             identity: id,
             revision: revision
           ) do
        %ArtifactRow{canonical_hash: ^hash} ->
          {:ok, :noop}

        %ArtifactRow{canonical_hash: existing} ->
          {:error, {:artifact_conflict, kind, id, existing, hash}}

        nil ->
          insert_new(kind, id, doc, hash, revision, loop_id)
      end
    end
  end

  defp sandbox?, do: Application.get_env(:kapelle, :sandbox?, false)

  defp insert_new(kind, id, doc, hash, revision, loop_id) do
    %ArtifactRow{}
    |> ArtifactRow.changeset(%{
      loop_id: loop_id,
      kind: to_string(kind),
      identity: id,
      revision: revision,
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
          artifact_revision: revision,
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
          %{
            kind: atom(),
            id: String.t(),
            doc: map(),
            canonical_hash: String.t(),
            revision: integer()
          }
        ]
  def all(loop_id) do
    import Ecto.Query, only: [from: 2]

    Repo.all(from(a in ArtifactRow, where: a.loop_id == ^loop_id, order_by: a.inserted_at))
    |> Enum.map(fn row ->
      %{
        kind: String.to_existing_atom(row.kind),
        id: row.identity,
        doc: row.doc,
        canonical_hash: row.canonical_hash,
        revision: row.revision
      }
    end)
  end

  defp pk_violation?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_msg, meta}} ->
      meta[:constraint] == :unique
    end)
  end
end
