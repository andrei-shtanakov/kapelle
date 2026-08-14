defmodule Kapelle.Product.View do
  @moduledoc """
  The canonical artifact view over a loop's stored rows (design doc §5).

  `Store.all/1` rows are not trusted as-is: every row is re-validated
  against its schema, re-checked for identity agreement, and re-hashed
  before it is allowed into the view — a row that fails any of those
  checks fails the whole build closed (`:artifact_invalid`,
  `:identity_mismatch`, `:hash_mismatch`). Grouping then enforces the
  shape of a loop's artifact set: at most one idea / product_proposal /
  exchange_log (`:competing_artifacts`), research packs and concept
  drafts keyed by iteration with no duplicate per iteration
  (`:competing_artifacts`), and a causally sane iteration sequence
  (`:impossible_sequence` — a concept draft with no research pack of its
  own iteration, or a hole below the highest iteration reached).

  `gate_decision` rows are carried as a best-effort projection: they are
  still re-checked, but a row that fails the check is dropped from the
  projection rather than failing the whole view — it never participates
  in the sequence check and never feeds `Kapelle.Product.NextStage`. A
  drop is never silent: it is logged (`Logger.warning/1`) and recorded
  in the `dropped` field so tampering with a lenient-kind row stays
  visible even though it doesn't fail the build.

  `loop_state` has no place in this view at all (owner's
  loop-state-leaves-the-store decision, 2026-08-14): it is not stored in
  `product_artifacts`, so `Store.all/1` never yields a `:loop_state` row
  for this module to carry, drop, or fail on. Its projection lives in
  `Kapelle.Product.Loops`'s `latest_state` column instead.
  """

  require Logger

  alias Kapelle.Product.{CanonicalHash, Identity, Store, Validator}

  @enforce_keys [:loop_id]
  defstruct [
    :loop_id,
    :idea,
    :proposal,
    :exchange_log,
    research_packs: %{},
    concept_drafts: %{},
    decisions: [],
    dropped: []
  ]

  @type t :: %__MODULE__{
          loop_id: String.t(),
          idea: map() | nil,
          proposal: map() | nil,
          exchange_log: map() | nil,
          research_packs: %{optional(non_neg_integer()) => map()},
          concept_drafts: %{optional(non_neg_integer()) => map()},
          decisions: [map()],
          dropped: [%{kind: atom(), identity: String.t(), reason: term()}]
        }

  @lenient_kinds [:gate_decision]

  @spec build(String.t()) ::
          {:ok, t()}
          | {:error,
             {:artifact_invalid
              | :hash_mismatch
              | :identity_mismatch
              | :competing_artifacts
              | :impossible_sequence
              | :reference_mismatch, term()}}
  def build(loop_id) when is_binary(loop_id) do
    with {:ok, checked, dropped} <- check_rows(Store.all(loop_id)),
         {:ok, grouped} <- group(checked) do
      {:ok, to_view(loop_id, grouped, dropped)}
    end
  end

  defp check_rows(rows) do
    Enum.reduce_while(rows, {:ok, [], []}, fn row, {:ok, acc, dropped} ->
      case check_row(row) do
        {:ok, checked} -> {:cont, {:ok, [checked | acc], dropped}}
        {:dropped, drop} -> {:cont, {:ok, acc, [drop | dropped]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc, dropped} -> {:ok, Enum.reverse(acc), Enum.reverse(dropped)}
      error -> error
    end
  end

  defp check_row(%{kind: kind, id: id} = row) when kind in @lenient_kinds do
    case verify(row) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.warning(
          "Kapelle.Product.View dropping corrupted #{kind} artifact " <>
            "identity=#{id} reason=#{inspect(reason)}"
        )

        {:dropped, %{kind: kind, identity: id, reason: reason}}
    end
  end

  defp check_row(row), do: verify(row)

  defp verify(%{kind: kind, id: id, doc: doc, canonical_hash: canonical_hash}) do
    with :ok <- validate_schema(kind, doc),
         :ok <- check_identity(kind, doc, id),
         :ok <- check_hash(doc, canonical_hash, kind, id) do
      {:ok, %{kind: kind, id: id, doc: doc}}
    end
  end

  defp validate_schema(kind, doc) do
    case Validator.validate(kind, doc) do
      :ok -> :ok
      {:error, reason} -> {:error, {:artifact_invalid, %{kind: kind, reason: reason}}}
    end
  end

  defp check_identity(kind, doc, id) do
    case Identity.of(kind, doc) do
      {:ok, ^id} ->
        :ok

      {:ok, other} ->
        {:error, {:identity_mismatch, %{kind: kind, id: id, doc_id: other}}}

      {:error, reason} ->
        {:error, {:identity_mismatch, %{kind: kind, id: id, reason: reason}}}
    end
  end

  defp check_hash(doc, canonical_hash, kind, id) do
    case CanonicalHash.hash(doc) do
      ^canonical_hash -> :ok
      _other -> {:error, {:hash_mismatch, %{kind: kind, id: id}}}
    end
  end

  defp group(rows) do
    with {:ok, idea} <- singleton(rows, :idea),
         {:ok, proposal} <- singleton(rows, :product_proposal),
         {:ok, exchange_log} <- singleton(rows, :exchange_log),
         {:ok, research_packs} <- by_iteration(rows, :research_pack),
         {:ok, concept_drafts} <- by_iteration(rows, :concept_draft),
         :ok <- check_sequence(research_packs, concept_drafts),
         :ok <- check_references(idea, proposal, research_packs, concept_drafts) do
      {:ok,
       %{
         idea: idea,
         proposal: proposal,
         exchange_log: exchange_log,
         research_packs: research_packs,
         concept_drafts: concept_drafts,
         decisions: decisions(rows)
       }}
    end
  end

  defp singleton(rows, kind) do
    case Enum.filter(rows, &(&1.kind == kind)) do
      [] -> {:ok, nil}
      [row] -> {:ok, row.doc}
      many -> {:error, {:competing_artifacts, %{kind: kind, ids: Enum.map(many, & &1.id)}}}
    end
  end

  defp decisions(rows) do
    rows
    |> Enum.filter(&(&1.kind == :gate_decision))
    |> Enum.map(& &1.doc)
  end

  defp by_iteration(rows, kind) do
    rows
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.reduce_while({:ok, %{}}, fn row, {:ok, acc} ->
      iteration = row.doc["iteration"]

      if Map.has_key?(acc, iteration) do
        {:halt, {:error, {:competing_artifacts, %{kind: kind, iteration: iteration}}}}
      else
        {:cont, {:ok, Map.put(acc, iteration, row.doc)}}
      end
    end)
  end

  defp check_sequence(research_packs, concept_drafts) do
    with :ok <- check_cd_needs_rp(concept_drafts, research_packs) do
      check_contiguous(research_packs, concept_drafts)
    end
  end

  defp check_cd_needs_rp(concept_drafts, research_packs) do
    concept_drafts
    |> Map.keys()
    |> Enum.find(fn i -> not Map.has_key?(research_packs, i) end)
    |> case do
      nil -> :ok
      i -> {:error, {:impossible_sequence, %{iteration: i, missing: :research_pack}}}
    end
  end

  defp check_contiguous(research_packs, concept_drafts) do
    case max_iteration(research_packs, concept_drafts) do
      nil ->
        :ok

      max ->
        0..max
        |> Enum.find(fn i -> not Map.has_key?(research_packs, i) end)
        |> case do
          nil -> :ok
          i -> {:error, {:impossible_sequence, %{iteration: i, missing: :hole}}}
        end
    end
  end

  defp max_iteration(research_packs, concept_drafts) do
    case Map.keys(research_packs) ++ Map.keys(concept_drafts) do
      [] -> nil
      keys -> Enum.max(keys)
    end
  end

  # Reference validation (design doc §5 step 2): grouping only checks that
  # the loop's artifact *shape* is causally sane, not that its documents
  # actually agree with each other about identity. A concept draft naming
  # the wrong research pack, or a research pack/proposal naming the wrong
  # idea, is a semantic corruption that grouping alone would let through —
  # so it fails the whole view closed, the same as :hash_mismatch does.
  defp check_references(idea, proposal, research_packs, concept_drafts) do
    with :ok <- check_concept_draft_refs(concept_drafts, research_packs) do
      check_idea_refs(idea, proposal, research_packs)
    end
  end

  defp check_concept_draft_refs(concept_drafts, research_packs) do
    Enum.find_value(concept_drafts, :ok, fn {i, cd} ->
      concept_draft_ref_error(i, cd, research_packs)
    end)
  end

  defp concept_draft_ref_error(i, cd, research_packs) do
    expected = "research-pack://" <> research_packs[i]["id"]
    got = get_in(cd, ["based_on_research", "ref"])

    if got == expected do
      nil
    else
      {:error,
       {:reference_mismatch, %{kind: :concept_draft, iteration: i, expected: expected, got: got}}}
    end
  end

  # With no idea in the view there is nothing for a research pack or the
  # proposal to agree with; reference agreement against it is vacuous.
  defp check_idea_refs(nil, _proposal, _research_packs), do: :ok

  defp check_idea_refs(idea, proposal, research_packs) do
    expected = "idea://" <> idea["id"]

    with :ok <- check_proposal_idea_ref(proposal, expected) do
      Enum.find_value(research_packs, :ok, fn {i, rp} ->
        research_pack_idea_ref_error(i, rp, expected)
      end)
    end
  end

  defp check_proposal_idea_ref(nil, _expected), do: :ok

  defp check_proposal_idea_ref(proposal, expected) do
    case proposal["idea_ref"] do
      ^expected ->
        :ok

      got ->
        {:error, {:reference_mismatch, %{kind: :product_proposal, expected: expected, got: got}}}
    end
  end

  defp research_pack_idea_ref_error(i, rp, expected) do
    case rp["idea_ref"] do
      ^expected ->
        nil

      got ->
        {:error,
         {:reference_mismatch,
          %{kind: :research_pack, iteration: i, expected: expected, got: got}}}
    end
  end

  defp to_view(loop_id, grouped, dropped) do
    %__MODULE__{
      loop_id: loop_id,
      idea: grouped.idea,
      proposal: grouped.proposal,
      exchange_log: grouped.exchange_log,
      research_packs: grouped.research_packs,
      concept_drafts: grouped.concept_drafts,
      decisions: grouped.decisions,
      dropped: dropped
    }
  end
end
