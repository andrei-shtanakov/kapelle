defmodule Kapelle.Product.View do
  @moduledoc """
  The canonical artifact view over a loop's stored rows (design doc §5;
  owner's revision-snapshot decision, 2026-08-14).

  `Store.all/1` rows are not trusted as-is: every row is re-validated
  against its schema, re-checked for identity agreement, and re-hashed
  before it is allowed into the view — a row that fails any of those
  checks fails the whole build closed (`:artifact_invalid`,
  `:identity_mismatch`, `:hash_mismatch`). Grouping then enforces the
  shape of a loop's artifact set: at most one idea (`:competing_artifacts`),
  research packs and concept drafts keyed by iteration with no duplicate
  per iteration (`:competing_artifacts`), and a causally sane iteration
  sequence (`:impossible_sequence` — a concept draft with no research pack
  of its own iteration, or a hole below the highest iteration reached).

  `product_proposal` and `exchange_log` are evolving, multi-revision
  artifacts (PK `(loop_id, kind, identity, revision)`): the view collects
  every stored revision under the loop's single identity into an ascending
  `proposal_chain`/`exchange_log_chain`, fails closed on more than one
  identity (`:competing_artifacts`) or a hole in the revision sequence
  (`:revision_gap`), and — defense-in-depth over what the composite PK
  already makes structurally impossible — two rows claiming the same
  revision (`:revision_fork`). `proposal`/`exchange_log` expose the
  chain's latest (highest-revision) snapshot, same as before this task
  for any caller that only cares about "now".

  Each chain is then walked for `{:chain_violation, %{kind, rule, detail}}`
  fail-closed rules (design doc §5, owner's decision, 2026-08-14):
  proposal chains for `:initial_version`, `:identity_drift`,
  `:terminal_superseded`, `:fsm_regression`, `:iteration_decrease`;
  exchange-log chains for `:history_rewritten` (byte-canonical prefix
  property), `:entry_order`, and `:missing_researcher_entry` (an
  iteration with a creator/orchestration entry but no researcher entry
  of its own).

  `gate_decision` and `loop_resume_decision` rows are carried as a
  best-effort projection: they are still re-checked, but a row that
  fails the check is dropped from the projection rather than failing
  the whole view — neither participates in the sequence check and
  neither feeds `Kapelle.Product.NextStage`. Both are externally-authored
  documents (a human's gate call, a human's resume authorization) that
  this view only ever reads after they've already done their one-time
  job of driving a transition, so re-validating them forever against a
  schema a later re-vendored contract might tighten would otherwise
  flip an old, already-resumed loop's view closed for no domain reason.
  A drop is never silent: it is logged (`Logger.warning/1`) and
  recorded in the `dropped` field so tampering with a lenient-kind row
  stays visible even though it doesn't fail the build.

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
    proposal_chain: [],
    exchange_log_chain: [],
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
          proposal_chain: [map()],
          exchange_log_chain: [map()],
          research_packs: %{optional(non_neg_integer()) => map()},
          concept_drafts: %{optional(non_neg_integer()) => map()},
          decisions: [map()],
          dropped: [%{kind: atom(), identity: String.t(), reason: term()}]
        }

  @lenient_kinds [:gate_decision, :loop_resume_decision]

  # The reference FSM this checker enforces (design doc §5, owner's
  # decision, 2026-08-14): only the native loop's own transitions. A
  # GateDecision-driven move onto `business_approved`/`approved`/
  # `on_hold`/`killed` is a different part of the system and out of this
  # chain's scope — any such status shows up here as an ordinary
  # `:fsm_regression`, not a dedicated case.
  @terminal_status "ready_for_business"
  @proposal_fsm_edges MapSet.new([
                        {"draft", "in_iteration"},
                        {"in_iteration", "in_iteration"},
                        {"in_iteration", @terminal_status}
                      ])

  @spec build(String.t()) ::
          {:ok, t()}
          | {:error,
             {:artifact_invalid
              | :hash_mismatch
              | :identity_mismatch
              | :competing_artifacts
              | :impossible_sequence
              | :reference_mismatch
              | :revision_gap
              | :revision_fork
              | :chain_violation, term()}}
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

  defp verify(%{kind: kind, id: id, doc: doc, canonical_hash: canonical_hash, revision: revision}) do
    with :ok <- validate_schema(kind, doc),
         :ok <- check_identity(kind, doc, id),
         :ok <- check_hash(doc, canonical_hash, kind, id) do
      {:ok, %{kind: kind, id: id, doc: doc, revision: revision}}
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
         {:ok, {proposal, proposal_chain}} <- build_chain(rows, :product_proposal),
         :ok <- check_proposal_chain(proposal_chain),
         {:ok, {exchange_log, exchange_log_chain}} <- build_chain(rows, :exchange_log),
         :ok <- check_exchange_chain(exchange_log_chain),
         {:ok, research_packs} <- by_iteration(rows, :research_pack),
         {:ok, concept_drafts} <- by_iteration(rows, :concept_draft),
         :ok <- check_sequence(research_packs, concept_drafts),
         :ok <-
           check_references(idea, proposal, research_packs, concept_drafts, exchange_log) do
      {:ok,
       %{
         idea: idea,
         proposal: proposal,
         proposal_chain: proposal_chain,
         exchange_log: exchange_log,
         exchange_log_chain: exchange_log_chain,
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

  # Multi-revision chain assembly for `:product_proposal`/`:exchange_log`
  # (owner's revision-snapshot decision, 2026-08-14): every stored
  # revision under the loop's one identity, sorted ascending. Returns
  # `{latest_doc | nil, ascending_docs}`.
  defp build_chain(rows, kind) do
    case Enum.filter(rows, &(&1.kind == kind)) do
      [] -> {:ok, {nil, []}}
      chain_rows -> build_chain_from_rows(chain_rows, kind)
    end
  end

  defp build_chain_from_rows(chain_rows, kind) do
    sorted = Enum.sort_by(chain_rows, & &1.revision)

    with :ok <- single_identity(chain_rows, kind),
         :ok <- no_revision_fork(chain_rows, kind),
         :ok <- check_no_gap(sorted, kind) do
      docs = Enum.map(sorted, & &1.doc)
      {:ok, {List.last(docs), docs}}
    end
  end

  defp single_identity(rows, kind) do
    rows
    |> Enum.map(& &1.id)
    |> Enum.uniq()
    |> case do
      [_one] -> :ok
      ids -> {:error, {:competing_artifacts, %{kind: kind, ids: ids}}}
    end
  end

  # Two rows sharing a revision is impossible under the composite PK
  # `(loop_id, kind, identity, revision)` — `Store.put/2` can never
  # produce it. Kept anyway as a three-line defense-in-depth check over
  # `Store.all/1`, per the owner's decision.
  defp no_revision_fork(rows, kind) do
    rows
    |> Enum.group_by(& &1.revision)
    |> Enum.find_value(:ok, fn {revision, group} ->
      if length(group) > 1 do
        {:error, {:revision_fork, %{kind: kind, identity: hd(group).id, revision: revision}}}
      end
    end)
  end

  defp check_no_gap(sorted_rows, kind) do
    revisions = Enum.map(sorted_rows, & &1.revision)
    identity = hd(sorted_rows).id
    full_range = Enum.to_list(Enum.min(revisions)..Enum.max(revisions))

    case full_range -- revisions do
      [] -> :ok
      missing -> {:error, {:revision_gap, %{kind: kind, identity: identity, missing: missing}}}
    end
  end

  # --- proposal chain rules (ascending docs) ---

  defp check_proposal_chain([]), do: :ok

  defp check_proposal_chain(chain) do
    with :ok <- check_initial_version(chain),
         :ok <- check_identity_drift(chain),
         :ok <- check_terminal_not_superseded(chain),
         :ok <- check_fsm(chain) do
      check_iteration_monotonic(chain)
    end
  end

  # A single stored snapshot can legitimately start above version 1: a
  # replayed/partial workspace (e.g. the golden happy-path fixture) keeps
  # only its final evolving snapshot on disk, not the full history — that
  # one snapshot already passed schema validation in `verify/1`, which is
  # all "contract-valid initial snapshot" can mean without the earlier
  # revisions to compare against. A chain of two or more, on the other
  # hand, was necessarily built by this codebase's own `Loop.start`
  # (task 6), which always persists version 1 first — so its lowest
  # revision must actually be 1.
  defp check_initial_version([_single]), do: :ok

  defp check_initial_version([first | _]) do
    if first["version"] == 1 do
      :ok
    else
      {:error,
       {:chain_violation,
        %{
          kind: :product_proposal,
          rule: :initial_version,
          detail: %{lowest_version: first["version"]}
        }}}
    end
  end

  defp check_identity_drift([first | rest]) do
    idea_ref = first["idea_ref"]

    Enum.find_value(rest, :ok, fn doc ->
      if doc["idea_ref"] != idea_ref do
        {:error,
         {:chain_violation,
          %{
            kind: :product_proposal,
            rule: :identity_drift,
            detail: %{expected: idea_ref, got: doc["idea_ref"]}
          }}}
      end
    end)
  end

  # Checked before `check_fsm/1` so a snapshot appended after a terminal
  # one is always classified as `:terminal_superseded`, never as an
  # ordinary `:fsm_regression` — the two rules would otherwise overlap on
  # every such pair, since nothing is a valid successor to the terminal
  # status in `@proposal_fsm_edges` either.
  defp check_terminal_not_superseded(chain) do
    chain
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(:ok, fn [a, b] ->
      if a["status"] == @terminal_status do
        {:error,
         {:chain_violation,
          %{
            kind: :product_proposal,
            rule: :terminal_superseded,
            detail: %{terminal_version: a["version"], next_version: b["version"]}
          }}}
      end
    end)
  end

  defp check_fsm(chain) do
    chain
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reject(fn [a, _b] -> a["status"] == @terminal_status end)
    |> Enum.find_value(:ok, fn [a, b] ->
      if MapSet.member?(@proposal_fsm_edges, {a["status"], b["status"]}) do
        nil
      else
        {:error,
         {:chain_violation,
          %{
            kind: :product_proposal,
            rule: :fsm_regression,
            detail: %{from: a["status"], to: b["status"]}
          }}}
      end
    end)
  end

  defp check_iteration_monotonic(chain) do
    chain
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(:ok, fn [a, b] ->
      if b["iteration"] >= a["iteration"] do
        nil
      else
        {:error,
         {:chain_violation,
          %{
            kind: :product_proposal,
            rule: :iteration_decrease,
            detail: %{from_iteration: a["iteration"], to_iteration: b["iteration"]}
          }}}
      end
    end)
  end

  # --- exchange-log chain rules (ascending docs) ---

  defp check_exchange_chain([]), do: :ok

  defp check_exchange_chain(chain) do
    with :ok <- check_exchange_prefix(chain) do
      check_entry_order(chain)
    end
  end

  # The prefix property (design doc §5, owner's decision, 2026-08-14):
  # every earlier snapshot's entries must be a byte-canonical immutable
  # prefix of every later one. Compared via `CanonicalHash.hash/1` over
  # `%{"entries" => ...}` rather than raw `==` so this is the same
  # byte-exact notion of equality the rest of the store already commits
  # to, not Elixir term equality.
  defp check_exchange_prefix(chain) do
    chain
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(:ok, fn [a, b] ->
      a_entries = a["entries"]
      b_prefix = Enum.take(b["entries"], length(a_entries))

      if CanonicalHash.hash(%{"entries" => b_prefix}) ==
           CanonicalHash.hash(%{"entries" => a_entries}) do
        nil
      else
        {:error,
         {:chain_violation,
          %{
            kind: :exchange_log,
            rule: :history_rewritten,
            detail: %{from_revision: length(a_entries), to_revision: length(b["entries"])}
          }}}
      end
    end)
  end

  # Checked once, over the latest snapshot's full entry list: the prefix
  # property already guarantees every earlier snapshot's entries are an
  # exact prefix of the latest's, so a valid order on the latest implies
  # a valid order on every prefix of it too.
  defp check_entry_order(chain) do
    entries = List.last(chain)["entries"]

    with :ok <- check_entries_iteration_order(entries),
         :ok <- check_researcher_present(entries) do
      check_researcher_before_creator(entries)
    end
  end

  # `check_researcher_before_creator/1` only checks *relative* order when
  # BOTH a researcher and a creator entry already exist for an iteration —
  # it says nothing about an iteration that has a creator (or an
  # orchestration) entry but no researcher entry at all, which is exactly
  # as causally impossible (creator's own stage always follows research's
  # for the same iteration) but a different failure shape, so it gets its
  # own rule rather than being folded into `:entry_order`.
  defp check_researcher_present(entries) do
    entries
    |> Enum.group_by(& &1["iteration"])
    |> Enum.find_value(:ok, fn {iteration, group} ->
      if Enum.any?(group, &(&1["actor"] == "researcher")) do
        nil
      else
        {:error,
         {:chain_violation,
          %{
            kind: :exchange_log,
            rule: :missing_researcher_entry,
            detail: %{iteration: iteration}
          }}}
      end
    end)
  end

  defp check_entries_iteration_order(entries) do
    entries
    |> Enum.map(& &1["iteration"])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(:ok, fn [a, b] ->
      if b >= a do
        nil
      else
        {:error,
         {:chain_violation,
          %{
            kind: :exchange_log,
            rule: :entry_order,
            detail: %{reason: :iteration_decrease, from: a, to: b}
          }}}
      end
    end)
  end

  defp check_researcher_before_creator(entries) do
    entries
    |> Enum.with_index()
    |> Enum.group_by(fn {entry, _index} -> entry["iteration"] end)
    |> Enum.find_value(:ok, fn {iteration, indexed} ->
      researcher_index = actor_index(indexed, "researcher")
      creator_index = actor_index(indexed, "creator")

      if researcher_index && creator_index && researcher_index > creator_index do
        {:error,
         {:chain_violation,
          %{
            kind: :exchange_log,
            rule: :entry_order,
            detail: %{reason: :researcher_after_creator, iteration: iteration}
          }}}
      end
    end)
  end

  defp actor_index(indexed, actor) do
    Enum.find_value(indexed, fn {entry, index} -> if entry["actor"] == actor, do: index end)
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

  # Reference validation (design doc §5 step 2, extended by the S2
  # carry-forward N2): grouping/chaining only check that the loop's
  # artifact *shape* is causally sane, not that its documents actually
  # agree with each other about identity. A concept draft naming the
  # wrong research pack, or any document naming the wrong idea/proposal,
  # is a semantic corruption that this alone would let through — so it
  # fails the whole view closed, the same as `:hash_mismatch` does.
  defp check_references(idea, proposal, research_packs, concept_drafts, exchange_log) do
    with :ok <- check_concept_draft_refs(concept_drafts, research_packs),
         :ok <- check_idea_refs(idea, proposal, research_packs, concept_drafts) do
      check_proposal_refs(proposal, research_packs, concept_drafts, exchange_log)
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

  # With no idea in the view there is nothing for a research pack,
  # concept draft, or the proposal to agree with; reference agreement
  # against it is vacuous.
  defp check_idea_refs(nil, _proposal, _research_packs, _concept_drafts), do: :ok

  defp check_idea_refs(idea, proposal, research_packs, concept_drafts) do
    expected = "idea://" <> idea["id"]

    with :ok <- check_single_ref(proposal, "idea_ref", expected, :product_proposal),
         :ok <- check_field_ref(research_packs, "idea_ref", expected, :research_pack) do
      check_field_ref(concept_drafts, "idea_ref", expected, :concept_draft)
    end
  end

  # With no proposal in the view there is nothing for a research pack,
  # concept draft, or the exchange log to agree with either.
  defp check_proposal_refs(nil, _research_packs, _concept_drafts, _exchange_log), do: :ok

  defp check_proposal_refs(proposal, research_packs, concept_drafts, exchange_log) do
    expected = "proposal://" <> proposal["proposal_id"]

    with :ok <- check_field_ref(research_packs, "proposal_ref", expected, :research_pack),
         :ok <- check_field_ref(concept_drafts, "proposal_ref", expected, :concept_draft) do
      check_single_ref(exchange_log, "proposal_ref", expected, :exchange_log)
    end
  end

  defp check_single_ref(nil, _field, _expected, _kind), do: :ok

  defp check_single_ref(doc, field, expected, kind) do
    case doc[field] do
      ^expected -> :ok
      got -> {:error, {:reference_mismatch, %{kind: kind, expected: expected, got: got}}}
    end
  end

  defp check_field_ref(items_by_iteration, field, expected, kind) do
    Enum.find_value(items_by_iteration, :ok, fn {i, doc} ->
      case doc[field] do
        ^expected ->
          nil

        got ->
          {:error,
           {:reference_mismatch, %{kind: kind, iteration: i, expected: expected, got: got}}}
      end
    end)
  end

  defp to_view(loop_id, grouped, dropped) do
    %__MODULE__{
      loop_id: loop_id,
      idea: grouped.idea,
      proposal: grouped.proposal,
      proposal_chain: grouped.proposal_chain,
      exchange_log: grouped.exchange_log,
      exchange_log_chain: grouped.exchange_log_chain,
      research_packs: grouped.research_packs,
      concept_drafts: grouped.concept_drafts,
      decisions: grouped.decisions,
      dropped: dropped
    }
  end
end
