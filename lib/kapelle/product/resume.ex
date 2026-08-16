defmodule Kapelle.Product.Resume do
  @moduledoc """
  Pure consumer of `loop-resume-decision/v1` (spec/m2-tasks.md TASK-106):
  gives a TASK-105 `needs_human` hold its typed exit by **accepting** an
  existing active decision — this module never creates one, since
  authoring a decision is a producer-side human act.

  `consume/2` takes `decisions` — every document presented for this
  resume attempt, exactly as received (never fetched from the store: how
  decisions arrive is a transport concern out of scope here) — and
  applies the producer's own acceptance rules, verbatim:

    * every presented document validates against the pinned schema;
    * the *active* decision (see below) has `subject` equal to the held
      loop's own wait `(loop_id, iteration)`;
    * its `new_max_iterations` strictly widens the loop's current budget;
    * it is active — not superseded via an admissible `supersedes` edge.
      Admissible means the edge resolves to another *presented* document,
      shares the same `subject`, is not a self-loop, and is not part of a
      cycle; any other edge is a violation, and — fail-closed, as
      always — refuses the whole call rather than silently ignoring the
      bad edge. A decision is active when no presented document names it
      as its own `supersedes` target; more than one surviving active
      decision is ambiguous and refuses rather than guessing.

  Any failure — including the absence of a decision — is a fail-closed
  refusal: `{:error, reason}`, the hold left exactly as it was, nothing
  enqueued.

  The consume transition itself (re-check the wait, widen the budget,
  clear the hold, enqueue the next stage, record the resume under the
  decision's own `loop-resume-decision://LRD-…` ref) is one
  `Ecto.Multi`/`Repo.transaction` — atomic in this codebase's own store,
  the way the producer's file runner is atomic via its single-writer
  lock. `Kapelle.Product.Store.put/2` is deliberately not used for the
  decision artifact itself: `Store.put/2` refuses to run inside an
  ambient transaction outside the test sandbox (its own moduledoc), by
  design, so this composes the equivalent insert directly into the same
  `Ecto.Multi` instead. The `:artifact_stored` event that mirrors
  `Store.put/2`'s own only fires once the transaction has actually
  committed — nothing observable before the artifact that justifies it.

  Re-presenting an already-consumed decision (byte-identical, matched by
  canonical hash) is a no-op: the fresh outcome is recomputed and
  returned, but nothing is re-written, re-enqueued or re-broadcast.
  """

  alias Ecto.Multi

  alias Kapelle.Product.{
    CanonicalHash,
    Event,
    Events,
    Identity,
    Loops,
    NextStage,
    Validator,
    View
  }

  alias Kapelle.Product.Records.ArtifactRow
  alias Kapelle.Product.Workers.StageShell
  alias Kapelle.Repo

  @type stage :: {:research | :concept | :apply, non_neg_integer()}
  @type result :: %{decision_ref: String.t(), stage: stage()}

  @spec consume(String.t(), [map()]) :: {:ok, result()} | {:error, term()}
  def consume(loop_id, decisions) when is_binary(loop_id) and is_list(decisions) do
    with {:ok, valid} <- validate_all(decisions),
         {:ok, active} <- resolve_active(valid) do
      {:ok, decision_id} = Identity.of(:loop_resume_decision, active)
      hash = CanonicalHash.hash(active)

      case already_consumed(loop_id, decision_id, hash) do
        :fresh -> consume_fresh(loop_id, active, decision_id, hash)
        :idempotent -> replay(loop_id, decision_id)
        {:error, _reason} = error -> error
      end
    end
  end

  defp validate_all(decisions) do
    decisions
    |> Enum.reduce_while({:ok, []}, fn decision, {:ok, acc} ->
      case Validator.validate(:loop_resume_decision, decision) do
        :ok -> {:cont, {:ok, [decision | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_decision, reason}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp resolve_active([]), do: {:error, :no_decision}

  defp resolve_active(decisions) do
    by_id = Map.new(decisions, &{&1["decision_id"], &1})

    with :ok <- check_edges_admissible(decisions, by_id),
         :ok <- check_no_cycle(decisions) do
      superseded = superseded_ids(decisions)

      decisions
      |> Enum.reject(&MapSet.member?(superseded, &1["decision_id"]))
      |> case do
        [one] -> {:ok, one}
        [] -> {:error, :no_active_decision}
        many -> {:error, {:multiple_active_decisions, Enum.map(many, & &1["decision_id"])}}
      end
    end
  end

  defp supersedes_id(%{"supersedes" => "loop-resume-decision://" <> id}), do: id
  defp supersedes_id(_decision), do: nil

  defp superseded_ids(decisions) do
    decisions
    |> Enum.map(&supersedes_id/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp check_edges_admissible(decisions, by_id) do
    Enum.reduce_while(decisions, :ok, fn decision, :ok ->
      case supersedes_id(decision) do
        nil -> {:cont, :ok}
        target_id -> check_edge_admissible(decision, target_id, by_id)
      end
    end)
  end

  defp check_edge_admissible(decision, target_id, by_id) do
    decision_id = decision["decision_id"]

    case Map.fetch(by_id, target_id) do
      :error ->
        {:halt, {:error, {:inadmissible_supersedes, :unresolved_target, decision_id}}}

      {:ok, _target} when target_id == decision_id ->
        {:halt, {:error, {:inadmissible_supersedes, :self_loop, decision_id}}}

      {:ok, target} ->
        if target["subject"] == decision["subject"] do
          {:cont, :ok}
        else
          {:halt, {:error, {:inadmissible_supersedes, :subject_mismatch, decision_id}}}
        end
    end
  end

  defp check_no_cycle(decisions) do
    edges =
      decisions
      |> Enum.map(&{&1["decision_id"], supersedes_id(&1)})
      |> Enum.reject(fn {_id, target} -> is_nil(target) end)
      |> Map.new()

    if Enum.any?(Map.keys(edges), &cyclic?(&1, edges, MapSet.new())) do
      {:error, {:inadmissible_supersedes, :cycle}}
    else
      :ok
    end
  end

  defp cyclic?(node, edges, seen) do
    if MapSet.member?(seen, node) do
      true
    else
      case Map.fetch(edges, node) do
        {:ok, next} -> cyclic?(next, edges, MapSet.put(seen, node))
        :error -> false
      end
    end
  end

  defp already_consumed(loop_id, decision_id, hash) do
    case Repo.get_by(ArtifactRow,
           loop_id: loop_id,
           kind: "loop_resume_decision",
           identity: decision_id,
           revision: 0
         ) do
      nil -> :fresh
      %ArtifactRow{canonical_hash: ^hash} -> :idempotent
      %ArtifactRow{} -> {:error, {:decision_conflict, decision_id}}
    end
  end

  defp consume_fresh(loop_id, active, decision_id, hash) do
    loop = Loops.get!(loop_id)

    with :ok <- check_wait(loop, active),
         :ok <- check_budget(loop, active) do
      do_consume(loop_id, active, decision_id, hash)
    end
  end

  defp check_wait(loop, active) do
    %{"loop_id" => subject_loop_id, "iteration" => subject_iteration} = active["subject"]

    cond do
      loop.status != "needs_human" ->
        {:error, {:not_held, loop.status}}

      subject_loop_id != loop.loop_id or subject_iteration != held_iteration(loop) ->
        {:error, {:foreign_subject, active["subject"]}}

      true ->
        :ok
    end
  end

  defp held_iteration(loop), do: get_in(loop.latest_state, ["stop", "iteration"])

  defp check_budget(loop, active) do
    requested = active["new_max_iterations"]

    if requested > loop.max_iterations do
      :ok
    else
      {:error, {:non_widening_budget, %{current: loop.max_iterations, requested: requested}}}
    end
  end

  defp do_consume(loop_id, active, decision_id, hash) do
    new_max = active["new_max_iterations"]

    multi =
      Multi.new()
      |> Multi.run(:resume, fn _repo, _changes -> Loops.resume(loop_id, new_max) end)
      |> Multi.run(:artifact, fn _repo, _changes ->
        insert_decision_artifact(loop_id, decision_id, active, hash)
      end)
      |> Multi.run(:view, fn _repo, _changes -> View.build(loop_id) end)
      |> Multi.run(:outcome, fn _repo, %{resume: loop, view: view} -> next_stage(loop, view) end)
      |> Multi.run(:projection, fn _repo, %{resume: loop, view: view, outcome: outcome} ->
        Loops.put_state_projection(loop_id, StageShell.projection_doc(loop, view, outcome))
      end)
      |> Oban.insert(:job, &stage_job_changeset(loop_id, &1))

    case Repo.transaction(multi) do
      {:ok, %{outcome: {:run, stage}}} ->
        broadcast_stored(loop_id, decision_id, hash)
        {:ok, %{decision_ref: decision_ref(decision_id), stage: stage}}

      {:error, _failed_operation, reason, _changes} ->
        {:error, reason}
    end
  end

  defp stage_job_changeset(loop_id, %{outcome: {:run, {stage, iteration}}, view: view}) do
    worker = StageShell.worker_for(stage)
    input_hash = StageShell.input_hash_for(stage, iteration, view)
    StageShell.stage_job_changeset(worker, loop_id, {stage, iteration}, input_hash)
  end

  defp insert_decision_artifact(loop_id, decision_id, doc, hash) do
    %ArtifactRow{}
    |> ArtifactRow.changeset(%{
      loop_id: loop_id,
      kind: "loop_resume_decision",
      identity: decision_id,
      revision: 0,
      canonical_hash: hash,
      doc: doc
    })
    |> Repo.insert()
  end

  defp next_stage(loop, view) do
    case NextStage.compute(view, loop.max_iterations) do
      {:run, _target} = run -> {:ok, run}
      other -> {:error, {:unexpected_outcome, other}}
    end
  end

  defp replay(loop_id, decision_id) do
    loop = Loops.get!(loop_id)

    case View.build(loop_id) do
      {:ok, view} ->
        case next_stage(loop, view) do
          {:ok, {:run, stage}} -> {:ok, %{decision_ref: decision_ref(decision_id), stage: stage}}
          error -> error
        end

      error ->
        error
    end
  end

  defp decision_ref(decision_id), do: "loop-resume-decision://" <> decision_id

  defp broadcast_stored(loop_id, decision_id, hash) do
    Events.broadcast(%Event{
      loop_id: loop_id,
      kind: :artifact_stored,
      artifact_kind: :loop_resume_decision,
      artifact_ref: decision_ref(decision_id),
      artifact_hash: hash,
      artifact_revision: 0,
      producer: nil
    })
  end
end
