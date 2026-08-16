defmodule Kapelle.Product.Workers.StageShell do
  @moduledoc """
  Shared plumbing for `product`-queue stage workers (design doc §5, Task
  7). Each worker supplies a `stage_impl` map — `%{stage: atom(),
  output_exists?: (View.t(), iteration -> boolean()), execute: (View.t(),
  iteration, LoopRow.t() -> :ok | {:error, Agent.failure()})}` — and calls
  `run/2` from its own `perform/1`; everything else (view build,
  staleness/idempotency, projection rebuild, next-stage enqueue) lives
  here so the three workers stay thin wrappers around their own
  produce/validate/persist logic.

  Fail-closed stays the rule for every torn or corrupted state a view
  build can detect — with exactly one narrow exception. Each stage
  worker's `execute/3` persists its own artifact and appends the
  matching exchange-log entry as two separate authoritative writes
  (design doc §5's durable-boundary order); a crash between them leaves
  the artifact stored with its own entry missing. That missing entry is
  not lost information — it is mechanically re-derivable from the
  artifact row itself (the producer's own model: artifacts are the
  durable truth, the exchange log is derived evidence of them), so
  `heal_missing_exchange_entries/1` reconstructs it byte-for-byte
  instead of the loop failing terminally over what is really a
  recoverable infrastructure gap. This mirrors the producer's own
  resume-from-artifacts semantics, and is exactly what the oracle's
  crash-parity guarantee requires: a crash at any boundary must converge
  byte-identically to the uncrashed run. Anything else a view build
  rejects (a rewritten history, a reference mismatch, a genuinely absent
  artifact, an out-of-order entry not explained by a missing append) is
  not derivable from an artifact alone and stays fail-closed exactly as
  before.

  The invariant shell, in order:

    1. A terminal loop discards the job (`:ok`, nothing else runs).
    2. `View.build/1` fails closed — the loop is marked `"failed"` and the
       job is cancelled (not retried: a broken chain does not get better
       on retry).
    3. A fresh `NextStage.compute/2` decides what actually happens next:
       if it names *this* job's own `(stage, iteration)`, the stage's
       `execute` callback runs. Otherwise, if this job's own output is
       already in the view (a same-args replay after a completed run —
       `enqueue_stage/4`'s `unique` uses the default `states:
       :successful` [the default since Oban v2.23.1], which does cover
       `completed`, but only dedupes a second *insert* within the
       default `period: 60` window; past that, an identical-args insert
       lands as a genuine new row instead. The replay this branch
       actually exists for has no insert involved at all: Oban's
       ordinary retry re-invokes `perform/1` on the very same row after
       step 4's `{:infrastructure, reason}` route returns an error — a
       stage that already persisted its own artifact before that later
       failure lands right back here on retry. A raw BEAM crash
       mid-`perform/1`, by contrast, leaves the row stuck in `executing`
       forever unless `Oban.Plugins.Lifeline` is configured, which this
       app does not do — see spec §8's crash/retry exit gate), the job
       is idempotent: skip straight to re-deriving the projection and
       the next enqueue. Otherwise the job is truly stale (superseded by
       other progress) and is a no-op.
    4. `execute`'s `{:infrastructure, reason}` becomes `{:error, reason}`
       (Oban retries); `{:domain, reason}`/`{:invalid_artifact, reason}`
       marks the loop `"failed"` and cancels the job (fail-closed, no
       retry — the input or the agent's output is bad, not transient).
    5. On success (real work done, or the idempotent-skip path), the
       projection is rebuilt from a fresh view and the next stage is
       either enqueued (`{:run, {stage, iteration}}`) or the loop's
       terminal status is set (`{:terminal, verdict, reason}`).

  `Store.put/2` already emitted this step's event (if any); nothing here
  duplicates it.
  """

  alias Kapelle.Product.{
    CanonicalHash,
    Identity,
    Loops,
    NextStage,
    Record,
    Store,
    Validator,
    View
  }

  alias Kapelle.Product.Records.LoopRow
  alias Kapelle.Product.Workers.{CreatorWorker, EvaluateWorker, ResearchWorker}

  @type stage_impl :: %{
          stage: :research | :concept | :apply,
          output_exists?: (View.t(), non_neg_integer() -> boolean()),
          execute: (View.t(), non_neg_integer(), LoopRow.t() ->
                      :ok | {:error, Kapelle.Product.Agent.failure()})
        }

  @doc """
  Builds a stage job's args under the shared idempotency/uniqueness key
  `(loop_id, iteration, stage, input_hash)` and inserts it for
  `worker_module`, deduplicated on `(worker, args)` — a second insert
  with the same worker and args is a no-op rather than a duplicate job.
  """
  @spec enqueue_stage(module(), String.t(), {atom(), non_neg_integer()}, String.t()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def enqueue_stage(worker_module, loop_id, {stage, iteration}, input_hash) do
    worker_module
    |> stage_job_changeset(loop_id, {stage, iteration}, input_hash)
    |> Oban.insert()
  end

  @doc """
  Builds (without inserting) a stage job's changeset under the shared
  idempotency/uniqueness key `enqueue_stage/4` inserts — exposed for a
  caller that composes its own `Ecto.Multi`/`Oban.insert/3` transaction
  (`Kapelle.Product.Resume`'s atomic consume transition), so the job it
  enqueues is byte-identical to one the ordinary worker contour would
  have produced.
  """
  @spec stage_job_changeset(module(), String.t(), {atom(), non_neg_integer()}, String.t()) ::
          Ecto.Changeset.t()
  def stage_job_changeset(worker_module, loop_id, {stage, iteration}, input_hash) do
    args = %{
      "loop_id" => loop_id,
      "iteration" => iteration,
      "stage" => to_string(stage),
      "input_hash" => input_hash
    }

    worker_module.new(args, unique: [fields: [:worker, :args]])
  end

  @doc "The invariant stage-worker shell (moduledoc) — see there for the step-by-step contract."
  @spec run(map(), stage_impl()) :: :ok | {:error, term()} | {:cancel, term()}
  def run(%{"loop_id" => loop_id, "iteration" => iteration}, %{stage: stage} = stage_impl)
      when is_binary(loop_id) and is_integer(iteration) do
    loop = Loops.get!(loop_id)

    if terminal?(loop) do
      :ok
    else
      case build_view_with_heal(loop) do
        {:ok, view} ->
          handle_stage(loop, view, stage, iteration, stage_impl)

        {:error, reason} ->
          Loops.set_status(loop_id, "failed", inspect(reason))
          {:cancel, reason}
      end
    end
  end

  # The one narrow exception to fail-closed (moduledoc): a view build
  # that fails on exactly a missing-exchange-entry chain violation is a
  # crash tear whose missing piece is derivable from the loop's own
  # stored artifacts, not a genuine corruption. Heal and rebuild once;
  # any other error (including the rebuilt view still failing, or there
  # being nothing to heal) falls straight back to fail-closed. This is
  # `run/2`'s own defensive backstop, reactive rather than unconditional
  # (unlike `do_repair/1`'s own pre-pass, see there for why the two
  # callers need different strategies even though both end up calling
  # `heal_missing_exchange_entries/1`).
  defp build_view_with_heal(loop) do
    case View.build(loop.loop_id) do
      {:ok, view} -> {:ok, view}
      {:error, reason} -> heal_and_rebuild_or_fail(loop, reason)
    end
  end

  defp heal_and_rebuild_or_fail(loop, reason) do
    if missing_entry_violation?(reason) do
      case heal_missing_exchange_entries(loop) do
        {:ok, :healed} -> View.build(loop.loop_id)
        _not_healed -> {:error, reason}
      end
    else
      {:error, reason}
    end
  end

  @missing_entry_rule ~r/^missing_.*_entry$/

  defp missing_entry_violation?({:chain_violation, %{kind: :exchange_log, rule: rule}}) do
    rule |> Atom.to_string() |> then(&Regex.match?(@missing_entry_rule, &1))
  end

  defp missing_entry_violation?(_reason), do: false

  defp terminal?(%LoopRow{status: status}), do: status != "running"

  defp handle_stage(loop, view, stage, iteration, stage_impl) do
    case NextStage.compute(view, loop.max_iterations) do
      {:run, {^stage, ^iteration}} ->
        perform_stage(loop, view, iteration, stage_impl)

      _fresh ->
        if stage_impl.output_exists?.(view, iteration) do
          advance(loop)
        else
          :ok
        end
    end
  end

  defp perform_stage(loop, view, iteration, stage_impl) do
    case stage_impl.execute.(view, iteration, loop) do
      :ok ->
        advance(loop)

      {:error, {:infrastructure, reason}} ->
        {:error, reason}

      {:error, {kind, reason}} when kind in [:domain, :invalid_artifact] ->
        Loops.set_status(loop.loop_id, "failed", inspect({kind, reason}))
        {:cancel, reason}

      {:error, reason} ->
        # Any other shape (e.g. EvaluateWorker's own internal View.build
        # re-check failing) fails exactly like step 2's build failure:
        # closed, not retried.
        Loops.set_status(loop.loop_id, "failed", inspect(reason))
        {:cancel, reason}
    end
  end

  # Steps 5-8 (moduledoc), reused for both a just-completed stage and an
  # idempotent replay: always re-derive from a fresh view rather than
  # trust whatever the caller already had in hand. Delegates to
  # `repair/1` — the worker shell and `Kapelle.Product.Reconciler` share
  # the identical repair computation; this just narrows `repair/1`'s
  # richer `{:ok, classification}` result back down to `run/2`'s own
  # `:ok | {:cancel, reason}` contract.
  defp advance(loop) do
    case repair_loop(loop) do
      {:ok, _classification} -> :ok
      {:error, reason} -> {:cancel, reason}
    end
  end

  @doc """
  Re-derives a loop's stage from a fresh view and repairs whatever has
  drifted: a stale or missing state projection, and/or a next-stage job
  that was never actually enqueued — the same computation `run/2`'s own
  `advance/1` step performs right after a stage completes, exposed here
  so `Kapelle.Product.Reconciler` (an out-of-band caller, e.g. a periodic
  sweep or a manual repair after a suspected crash) reconciles exactly
  the same way: same projection shape, same `input_hash` chain, same
  `(loop_id, iteration, stage, input_hash)` uniqueness key.

  A loop already at a final status (`"ready"`/`"failed"`) is `:terminal`
  and touches nothing — there is nothing left to ever re-derive.
  `"needs_human"` is a hold, not a final status (design doc §5, Task 8):
  a person may still be looking at it, so a held loop is repaired like
  any running one — re-deriving from a fresh view, which reaches the
  identical `{:terminal, :needs_human, reason}` verdict deterministically
  as long as its artifacts are untouched, so the hold itself never
  advances or duplicates anything. Otherwise the projection is rebuilt
  unconditionally (idempotent: writing the same bytes twice is a no-op
  change in effect) and the fresh outcome is applied; the result is
  `:repaired` when the projection actually changed, the outcome's job
  needed a real insert (`Oban.Job.conflict? == false`), or a running loop
  just reached a terminal status for the first time, and `:in_sync` when
  none of that did — calling `repair/1` twice in a row on an
  already-healthy or already-held loop is `:in_sync` the second time.
  """
  @spec repair(String.t()) :: {:ok, :terminal | :repaired | :in_sync} | {:error, term()}
  def repair(loop_id) when is_binary(loop_id) do
    loop_id |> Loops.get!() |> repair_loop()
  end

  @final_statuses ~w(ready failed)

  defp repair_loop(loop) do
    if loop.status in @final_statuses do
      {:ok, :terminal}
    else
      do_repair(loop)
    end
  end

  # `do_repair/1` heals unconditionally, *before* ever building a view —
  # unlike `run/2`'s own initial build, which only reacts to an actual
  # `View.build/1` failure (moduledoc's `build_view_with_heal/1`).
  # `do_repair/1` is what decides and enqueues a loop's *next* stage
  # (`classify_and_apply/4` below), so it runs strictly before the
  # window this heal needs to close: an exchange log that does not exist
  # yet at all is an EMPTY chain, and `View.build/1` raises no violation
  # over an empty chain — the log is simply absent, not malformed. A
  # reactive-only heal would therefore let a crash-tear survive
  # unnoticed straight through `do_repair/1`'s own `View.build/1` call,
  # all the way to the next stage's worker actually running: that
  # worker's own `append_exchange_entry/3` would then found the log with
  # ITS entry alone (e.g. a lone "creator" entry with no "researcher"
  # entry for the same iteration) — which IS a violation, but by then
  # it is durably committed as revision 1, and the exchange-log chain's
  # own immutable-prefix rule (`View`'s `check_exchange_prefix/1`) makes
  # that revision un-fixable after the fact: no later revision can ever
  # re-order what an earlier, already-stored revision fixed. Healing
  # unconditionally here — before `Reconciler.reconcile/1` (an
  # out-of-band caller that may be the very first thing to touch a loop
  # after a crash) ever decides what runs next — closes that window
  # instead of reacting to its aftermath. The heal itself is a cheap
  # no-op (`{:ok, :nothing_to_heal}`, no write) whenever nothing is
  # actually missing, which is every ordinary (non-crash) repair, so
  # this costs nothing on the hot path.
  defp do_repair(loop) do
    case heal_missing_exchange_entries(loop) do
      {:error, reason} ->
        Loops.set_status(loop.loop_id, "failed", inspect(reason))
        {:error, reason}

      {:ok, _healed_or_not} ->
        build_and_process(loop)
    end
  end

  defp build_and_process(loop) do
    case View.build(loop.loop_id) do
      # `view.idea == nil` means literally nothing has been persisted for
      # this loop yet (`Loop.start/2` always writes the idea before
      # anything else, and `View.build/1` itself tolerates a nil idea —
      # its own `check_idea_refs/4` is vacuous with nothing to check
      # against). A stranded config row with no idea can genuinely reach
      # here via `Kapelle.Product.Reconciler` (e.g. a periodic sweep
      # visiting a loop whose `Loop.start/2` crashed right after
      # `Loops.create/1` but before its own `Store.put(idea, ...)`) — the
      # ordinary worker path can't hit this, since the first job is only
      # ever enqueued after the idea is already persisted. Both
      # `projection_doc/3` and the research stage's own `input_hash_for/3`
      # hash `view.idea` unconditionally, which would otherwise raise
      # (`CanonicalHash.hash/1`'s `is_map` guard has no clause for `nil`)
      # instead of failing closed like every other incomplete-view case.
      {:ok, %{idea: nil}} ->
        reason = {:view_incomplete, :idea_missing}
        Loops.set_status(loop.loop_id, "failed", inspect(reason))
        {:error, reason}

      {:ok, view} ->
        outcome = NextStage.compute(view, loop.max_iterations)
        new_projection = projection_doc(loop, view, outcome)
        projection_stale? = new_projection != loop.latest_state

        {:ok, _row} = Loops.put_state_projection(loop.loop_id, new_projection)

        classify_and_apply(loop, view, outcome, projection_stale?)

      {:error, reason} ->
        Loops.set_status(loop.loop_id, "failed", inspect(reason))
        {:error, reason}
    end
  end

  # `NextStage.compute/2`'s `:ready` verdict is derived purely from the
  # research-pack/concept-draft artifacts' own open items (design doc §5;
  # `NextStage.evaluate/5`) — it never reads the proposal doc back. That
  # makes it possible, after a crash between two of `EvaluateWorker`'s own
  # separate persists (durable boundary order: `apply_delta` lands before
  # `maybe_finalize_ready`'s own "ready_for_business" snapshot), for a
  # fresh view to compute `:ready` while the *stored* proposal chain's
  # latest snapshot still says `"in_iteration"` — the loop would then
  # falsely claim `"ready"` with no `"ready_for_business"` proposal to back
  # it up. Refuse that: only trust `:ready` when the view's own proposal
  # already agrees; otherwise this is a typed `:projection_drift`, fails
  # the loop closed exactly like any other repair failure, and is
  # reported to the caller instead of silently claiming success.
  defp classify_and_apply(loop, view, {:terminal, :ready, reason}, _projection_stale?) do
    case view.proposal["status"] do
      "ready_for_business" ->
        Loops.set_status(loop.loop_id, verdict_status(:ready), reason)
        {:ok, :repaired}

      actual ->
        detail = %{expected: "ready_for_business", actual: actual}
        Loops.set_status(loop.loop_id, "failed", inspect({:projection_drift, detail}))
        {:error, {:projection_drift, detail}}
    end
  end

  # A held (`needs_human`) loop reaches here again on every later
  # reconcile: `Loops.set_status/3`'s own `WHERE status = 'running'` guard
  # makes the second-and-later call a no-op (`{:error, :already_terminal}`)
  # rather than re-writing `stop_reason` — this is that no-op reported
  # back as `:in_sync` unless the projection itself still needed a
  # rewrite.
  defp classify_and_apply(loop, _view, {:terminal, verdict, reason}, projection_stale?) do
    case Loops.set_status(loop.loop_id, verdict_status(verdict), reason) do
      {:ok, :transitioned} -> {:ok, :repaired}
      {:error, :already_terminal} -> {:ok, if(projection_stale?, do: :repaired, else: :in_sync)}
    end
  end

  defp classify_and_apply(loop, view, {:run, {stage, iteration}}, projection_stale?) do
    input_hash = input_hash_for(stage, iteration, view)

    {:ok, job} = enqueue_stage(worker_for(stage), loop.loop_id, {stage, iteration}, input_hash)

    if projection_stale? or not job.conflict? do
      {:ok, :repaired}
    else
      {:ok, :in_sync}
    end
  end

  defp verdict_status(:ready), do: "ready"
  defp verdict_status(:needs_human), do: "needs_human"

  @doc "The worker module that runs `stage` — shared with `Kapelle.Product.Resume`."
  @spec worker_for(atom()) :: module()
  def worker_for(:research), do: ResearchWorker
  def worker_for(:concept), do: CreatorWorker
  def worker_for(:apply), do: EvaluateWorker

  # input_hash for the stage about to be enqueued (owner's decision,
  # 2026-08-14): the primary input document that stage will consume —
  # research always re-reads the (unchanging) idea, concept reads its
  # own iteration's research pack, apply reads its own iteration's
  # concept draft.
  @doc "The `input_hash` a fresh enqueue of `stage`/`iteration` carries — shared with `Kapelle.Product.Resume`."
  @spec input_hash_for(atom(), non_neg_integer(), View.t()) :: String.t()
  def input_hash_for(:research, _iteration, view), do: CanonicalHash.hash(view.idea)

  def input_hash_for(:concept, iteration, view),
    do: CanonicalHash.hash(view.research_packs[iteration])

  def input_hash_for(:apply, iteration, view),
    do: CanonicalHash.hash(view.concept_drafts[iteration])

  @doc "The loop's `latest_state` projection document for `outcome` — shared with `Kapelle.Product.Resume`."
  @spec projection_doc(LoopRow.t(), View.t(), NextStage.stage() | NextStage.verdict()) :: map()
  def projection_doc(loop, view, outcome) do
    %{
      "loop_id" => loop.loop_id,
      "idea_ref" => "idea://" <> loop.idea_identity,
      "idea_input_hash" => CanonicalHash.hash(view.idea),
      "proposal_id" => loop.proposal_id,
      "exchange_log_id" => loop.exchange_log_id,
      "max_iterations" => loop.max_iterations,
      "stop" => stop_field(outcome, view, loop.latest_state)
    }
  end

  defp stop_field({:run, _target}, _view, _existing_projection), do: nil

  # A hold's `stop` is written once, at hold time — the producer never
  # restamps it (design doc §5), and neither does this. Every later
  # reconcile of a held (or otherwise still-terminal) loop re-derives the
  # SAME `outcome` from its own untouched artifacts (nothing enqueues a
  # new stage while a loop is held or final), so recomputing `"at"` via
  # `now_iso/0` here would rewrite the recorded moment to "now" on every
  # single reconcile — in production, with the real wall clock, that
  # makes `projection_stale?` true forever (a fresh timestamp each call),
  # so `repair/1` would report `:repaired` on every reconcile of an
  # already-held loop instead of ever reaching `:in_sync`, and the
  # audited hold-start time would drift indefinitely. When the stored
  # projection already has a `"stop"` for this SAME verdict, reuse it
  # verbatim; only a genuinely new/changed verdict computes a fresh one.
  defp stop_field({:terminal, verdict, reason}, view, existing_projection) do
    case existing_projection do
      %{"stop" => %{"verdict" => existing_verdict} = existing_stop} ->
        if existing_verdict == stop_verdict(verdict) do
          existing_stop
        else
          fresh_stop(verdict, reason, view)
        end

      _no_existing_stop ->
        fresh_stop(verdict, reason, view)
    end
  end

  defp fresh_stop(verdict, reason, view) do
    %{
      "verdict" => stop_verdict(verdict),
      "reason" => reason,
      "iteration" => view.proposal["iteration"],
      "at" => now_iso()
    }
  end

  defp stop_verdict(:ready), do: "ready_for_business"
  defp stop_verdict(:needs_human), do: "needs_human"

  @doc """
  Validates `doc` against `kind`'s vendored schema, derives its identity,
  and persists it via `Store.put/2` — the same validate-then-persist
  path `Kapelle.Product.Loop.start/2` uses, shared here so every stage's
  own output goes through the identical fail-closed gate.

  A schema or identity failure is genuinely this stage's own output
  being invalid, reported as `{:invalid_artifact, reason}`. `Store.put/2`'s
  own typed errors are *not* relabeled into that same bucket — an
  `:ambient_transaction` guard trip is an environment/programming
  invariant violation, and an `:artifact_conflict` is honest disagreement
  between two documents that both claim the same identity+revision;
  neither is "this document failed schema validation". Both are passed
  through in their own shape, still fail-closed the same way as any
  other `perform_stage` error (design doc §5 step 4's final catch-all),
  but with a `stop_reason` that names the real class instead of
  misreporting every store failure as a schema problem.
  """
  @spec persist_document(atom(), map(), String.t()) ::
          :ok
          | {:error, {:invalid_artifact, term()}}
          | {:error, :ambient_transaction}
          | {:error, {:artifact_conflict, atom(), String.t(), String.t(), String.t()}}
  def persist_document(kind, doc, loop_id) do
    with :ok <- Validator.validate(kind, doc),
         {:ok, id} <- Identity.of(kind, doc),
         {:ok, _} <- Store.put(%Record{kind: kind, id: id, doc: doc}, loop_id) do
      :ok
    else
      {:error, :ambient_transaction} = error -> error
      {:error, {:artifact_conflict, _kind, _id, _existing, _new}} = error -> error
      {:error, reason} -> {:error, {:invalid_artifact, reason}}
    end
  end

  @doc """
  Appends one entry to the loop's exchange log and persists the new
  snapshot — the log is born at the first append (revision 1; no
  revision-0 snapshot exists, controller's ruling 2026-08-14, `Loop.ex`
  moduledoc). `loop.exchange_log_id`/`loop.proposal_id` are the loop
  config's own fields, not derived from any stored document, so this
  works identically whether the log already exists in `view` or not.
  """
  @spec append_exchange_entry(LoopRow.t(), View.t(), map()) ::
          :ok
          | {:error, {:invalid_artifact, term()}}
          | {:error, :ambient_transaction}
          | {:error, {:artifact_conflict, atom(), String.t(), String.t(), String.t()}}
  def append_exchange_entry(loop, view, entry) do
    existing_entries = if view.exchange_log, do: view.exchange_log["entries"], else: []

    doc = %{
      "id" => loop.exchange_log_id,
      "proposal_ref" => "proposal://" <> loop.proposal_id,
      "entries" => existing_entries ++ [entry]
    }

    persist_document(:exchange_log, doc, loop.loop_id)
  end

  @doc """
  Heals a crash tear between a stage's own artifact persist and its
  exchange-log append (moduledoc): derives whichever entries are
  missing directly from the loop's stored `:research_pack`/
  `:concept_draft` rows and appends them, mirroring
  `append_exchange_entry/3`'s own persistence path — the only
  difference is where the "current" log doc comes from. `View.build/1`
  is deliberately NOT used here: it is exactly what fails closed on the
  state this function exists to heal. The current log is instead read
  straight off `Store.all/1`, same as every other row this function
  looks at.

  Missing entries are appended in deterministic order — iteration
  ascending, researcher before creator within an iteration — regardless
  of how many are missing or what order `Store.all/1` happens to return
  its rows in, though in practice at most one trailing entry can ever
  be missing (only one worker runs a given stage at a time). Already-
  present entries (same `iteration` + `actor`) are never re-appended,
  so calling this on an already-healthy log is `{:ok, :nothing_to_heal}`.
  When the log does not exist yet at all (an iteration-0 researcher
  tear), it is born here the same way `append_exchange_entry/3` would
  have born it: `entries` starts from `[]`.
  """
  @spec heal_missing_exchange_entries(LoopRow.t()) ::
          {:ok, :healed | :nothing_to_heal} | {:error, term()}
  def heal_missing_exchange_entries(%LoopRow{} = loop) do
    rows = Store.all(loop.loop_id)
    existing_entries = latest_exchange_log_entries(rows)

    case derive_missing_entries(rows, existing_entries) do
      [] ->
        {:ok, :nothing_to_heal}

      missing ->
        doc = %{
          "id" => loop.exchange_log_id,
          "proposal_ref" => "proposal://" <> loop.proposal_id,
          "entries" => existing_entries ++ missing
        }

        case persist_document(:exchange_log, doc, loop.loop_id) do
          :ok -> {:ok, :healed}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp latest_exchange_log_entries(rows) do
    rows
    |> Enum.filter(&(&1.kind == :exchange_log))
    |> Enum.max_by(& &1.revision, fn -> nil end)
    |> case do
      nil -> []
      row -> row.doc["entries"]
    end
  end

  # Candidate entries for every stored artifact that has no matching
  # exchange-log entry yet, sorted `{iteration, actor_rank}` ascending so
  # a researcher entry always lands before its own iteration's creator
  # entry no matter what order the artifacts themselves are found in.
  defp derive_missing_entries(rows, existing_entries) do
    candidates =
      missing_derived_entries(rows, existing_entries, :research_pack, "researcher") ++
        missing_derived_entries(rows, existing_entries, :concept_draft, "creator")

    Enum.sort_by(candidates, &{&1["iteration"], actor_rank(&1["actor"])})
  end

  defp missing_derived_entries(rows, existing_entries, kind, actor) do
    rows
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.reject(&entry_present?(existing_entries, &1.doc["iteration"], actor))
    |> Enum.map(&derived_entry(&1.doc, actor))
  end

  defp entry_present?(existing_entries, iteration, actor) do
    Enum.any?(existing_entries, &(&1["iteration"] == iteration and &1["actor"] == actor))
  end

  @derived_entry_shape %{
    "researcher" => {"research_pack", "research-pack"},
    "creator" => {"concept_draft", "concept-draft"}
  }

  defp derived_entry(doc, actor) do
    {artifact_kind, ref_scheme} = Map.fetch!(@derived_entry_shape, actor)

    %{
      "iteration" => doc["iteration"],
      "actor" => actor,
      "artifact_kind" => artifact_kind,
      "artifact_ref" => ref_scheme <> "://" <> doc["id"],
      "at" => now_iso()
    }
  end

  defp actor_rank("researcher"), do: 0
  defp actor_rank("creator"), do: 1

  @doc """
  Current time as the ISO-8601 string the vendored timestamp schemas
  require. Resolved through an overridable clock (owner's decision,
  2026-08-14, resolving Task 8's sanctioned-divergence STOP over
  `Loop.start/2`'s own `now_iso` opt): defaults to `DateTime.utc_now/0`,
  but `Application.put_env(:kapelle, :product_clock, fn -> "..." end)`
  pins it — the e2e happy-path test does this to match the golden
  oracle's own baked-in timestamps, since full canonical-hash equality
  against a golden fixture is otherwise unreachable (every stamped field
  would differ by construction).
  """
  @spec now_iso() :: String.t()
  def now_iso, do: Application.get_env(:kapelle, :product_clock, &default_clock/0).()

  defp default_clock, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
