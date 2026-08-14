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
    args = %{
      "loop_id" => loop_id,
      "iteration" => iteration,
      "stage" => to_string(stage),
      "input_hash" => input_hash
    }

    args
    |> worker_module.new(unique: [fields: [:worker, :args]])
    |> Oban.insert()
  end

  @doc "The invariant stage-worker shell (moduledoc) — see there for the step-by-step contract."
  @spec run(map(), stage_impl()) :: :ok | {:error, term()} | {:cancel, term()}
  def run(%{"loop_id" => loop_id, "iteration" => iteration}, %{stage: stage} = stage_impl)
      when is_binary(loop_id) and is_integer(iteration) do
    loop = Loops.get!(loop_id)

    if terminal?(loop) do
      :ok
    else
      case View.build(loop_id) do
        {:ok, view} ->
          handle_stage(loop, view, stage, iteration, stage_impl)

        {:error, reason} ->
          Loops.set_status(loop_id, "failed", inspect(reason))
          {:cancel, reason}
      end
    end
  end

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

  A terminal loop is `:terminal` and touches nothing. Otherwise the
  projection is rebuilt unconditionally (idempotent: writing the same
  bytes twice is a no-op change in effect) and the fresh outcome is
  applied; the result is `:repaired` when the projection actually
  changed or the outcome's job needed a real insert (`Oban.Job.conflict?
  == false`), and `:in_sync` when neither did — calling `repair/1` twice
  in a row on an already-healthy loop is `:in_sync` the second time.
  """
  @spec repair(String.t()) :: {:ok, :terminal | :repaired | :in_sync} | {:error, term()}
  def repair(loop_id) when is_binary(loop_id) do
    loop_id |> Loops.get!() |> repair_loop()
  end

  defp repair_loop(loop) do
    if terminal?(loop) do
      {:ok, :terminal}
    else
      do_repair(loop)
    end
  end

  defp do_repair(loop) do
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

  defp classify_and_apply(loop, _view, {:terminal, verdict, reason}, _projection_stale?) do
    Loops.set_status(loop.loop_id, verdict_status(verdict), reason)
    {:ok, :repaired}
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

  defp worker_for(:research), do: ResearchWorker
  defp worker_for(:concept), do: CreatorWorker
  defp worker_for(:apply), do: EvaluateWorker

  # input_hash for the stage about to be enqueued (owner's decision,
  # 2026-08-14): the primary input document that stage will consume —
  # research always re-reads the (unchanging) idea, concept reads its
  # own iteration's research pack, apply reads its own iteration's
  # concept draft.
  defp input_hash_for(:research, _iteration, view), do: CanonicalHash.hash(view.idea)

  defp input_hash_for(:concept, iteration, view),
    do: CanonicalHash.hash(view.research_packs[iteration])

  defp input_hash_for(:apply, iteration, view),
    do: CanonicalHash.hash(view.concept_drafts[iteration])

  defp projection_doc(loop, view, outcome) do
    %{
      "loop_id" => loop.loop_id,
      "idea_ref" => "idea://" <> loop.idea_identity,
      "idea_input_hash" => CanonicalHash.hash(view.idea),
      "proposal_id" => loop.proposal_id,
      "exchange_log_id" => loop.exchange_log_id,
      "max_iterations" => loop.max_iterations,
      "stop" => stop_field(outcome, view)
    }
  end

  defp stop_field({:run, _target}, _view), do: nil

  defp stop_field({:terminal, verdict, reason}, view) do
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
