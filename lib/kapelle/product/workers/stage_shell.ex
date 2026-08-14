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
       Oban's `unique` dedup only covers scheduled/available/executing,
       not `completed`, so this genuinely happens, see spec §8's
       crash/retry exit gate), the job is idempotent: skip straight to
       re-deriving the projection and the next enqueue. Otherwise the
       job is truly stale (superseded by other progress) and is a no-op.
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
  # trust whatever the caller already had in hand.
  defp advance(loop) do
    case View.build(loop.loop_id) do
      {:ok, view} ->
        outcome = NextStage.compute(view, loop.max_iterations)

        {:ok, _row} =
          Loops.put_state_projection(loop.loop_id, projection_doc(loop, view, outcome))

        apply_outcome(loop, view, outcome)

      {:error, reason} ->
        Loops.set_status(loop.loop_id, "failed", inspect(reason))
        {:cancel, reason}
    end
  end

  defp apply_outcome(loop, _view, {:terminal, verdict, reason}) do
    Loops.set_status(loop.loop_id, verdict_status(verdict), reason)
    :ok
  end

  defp apply_outcome(loop, view, {:run, {stage, iteration}}) do
    input_hash = input_hash_for(stage, iteration, view)
    {:ok, _job} = enqueue_stage(worker_for(stage), loop.loop_id, {stage, iteration}, input_hash)
    :ok
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
  own output goes through the identical fail-closed gate. Any failure
  (schema, identity, or an unexpected store error) is reported as
  `{:invalid_artifact, reason}` — a stage's own output failing this
  check is this worker's fault, not the agent's, and fails closed the
  same way.
  """
  @spec persist_document(atom(), map(), String.t()) :: :ok | {:error, {:invalid_artifact, term()}}
  def persist_document(kind, doc, loop_id) do
    with :ok <- Validator.validate(kind, doc),
         {:ok, id} <- Identity.of(kind, doc),
         {:ok, _} <- Store.put(%Record{kind: kind, id: id, doc: doc}, loop_id) do
      :ok
    else
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
          :ok | {:error, {:invalid_artifact, term()}}
  def append_exchange_entry(loop, view, entry) do
    existing_entries = if view.exchange_log, do: view.exchange_log["entries"], else: []

    doc = %{
      "id" => loop.exchange_log_id,
      "proposal_ref" => "proposal://" <> loop.proposal_id,
      "entries" => existing_entries ++ [entry]
    }

    persist_document(:exchange_log, doc, loop.loop_id)
  end

  @doc "Current time as the ISO-8601 string the vendored timestamp schemas require."
  @spec now_iso() :: String.t()
  def now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
