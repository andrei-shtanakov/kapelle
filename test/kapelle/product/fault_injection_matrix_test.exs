defmodule Kapelle.Product.FaultInjectionMatrixTest do
  @moduledoc """
  TASK-107: the systematic fault-injection matrix over the six points the
  design doc names (§5) — every one of them injected through the ordinary
  worker contour (`Kapelle.Product.Workers.*`/`Kapelle.Product.Reconciler`,
  never a direct `Kapelle.Product.NextStage` call), asserting the
  invariant the design promises: the loop either heals to the same
  outcome as the uncrashed run (the happy golden, byte-for-byte) or fails
  closed with a typed reason, and re-delivery/re-execution never
  duplicates an artifact, an event, or a job. A repeat `Reconciler.reconcile/1`
  after convergence reports `:terminal`; after a fail-closed stop it also
  reports `:terminal` (a "failed" loop is as final as a "ready" one).

  The six points, verbatim from the task:

    1. after artifact persistence, before projection;
    2. after projection, before enqueue;
    3. after enqueue, before ack;
    4. worker re-run after its artifact is already written;
    5. derived row deliberately stale or contradicting the artifacts;
    6. artifact present but hash/schema/identity corrupted.

  Coverage map (checklist: "existing fault-adjacent tests ... are
  referenced or extended, not duplicated"):

    1. NEW here: a hand-simulated research/0 crash one step later than
       `reconciler_test.exs`'s own "b" (which stops mid-`execute/3`,
       before the exchange entry) — both the artifact AND its exchange
       entry land (the whole stage durably committed), but the loop's
       projection is never rewritten and no creator job is enqueued.
       `Reconciler.reconcile/1` must notice the stale projection and the
       missing enqueue and repair both.
    2. NEW here: a real `CreatorWorker` run (projection correctly
       rewritten, `EvaluateWorker` enqueued) with the resulting job row
       deleted afterward — reconstructing the exact DB state a crash
       between the projection write and the enqueue's own commit would
       leave. `Reconciler.reconcile/1` must re-enqueue exactly the
       missing job without touching the (already-correct) projection.
    3. NEW here: `CreatorWorker` completes normally (including its own
       enqueue of `EvaluateWorker`) and is then replayed — modeling
       Oban redelivering the job because ITS OWN completion was never
       acknowledged, even though everything the job itself durably
       produced (including the next stage's enqueue) already landed.
       Asserts no second `EvaluateWorker` job is ever created.
    4. NEW here: `EvaluateWorker` (the evaluate/apply stage this task's
       own TASK-107 decision covers — `test/task_107_red_test.exs`, the
       frozen red for the tear itself) completes normally and is then
       replayed. The general form of this same idempotency invariant is
       already covered for the researcher stage by
       `test/kapelle/product/workers/research_worker_test.exs` ("a stale
       replay after the loop already advanced is a no-op") — referenced,
       not duplicated, here.
    5. Not duplicated here — already covered: `reconciler_test.exs`'s "d"
       (`NextStage`'s derived `:ready` verdict — computed purely from the
       research-pack/concept-draft artifacts — contradicting the stored
       proposal chain's own `"in_iteration"` status; fails closed as
       `:projection_drift`, zero new artifact revisions written) and
       `parity_crash_test.exs`'s LOOP-004/LOOP-007 (an exchange log that
       is present but corrupted, not merely torn, relative to the
       artifacts it derives from — `:entry_order` / `:missing_researcher_entry`,
       both fail closed with the heal writing nothing).
    6. NEW here: a stored research-pack row corrupted post-hoc (same
       technique as `view_test.exs`'s "a stored row whose doc was
       corrupted post-hoc fails closed on hash mismatch"), but driven
       through `Reconciler.reconcile/1` — the ordinary contour — rather
       than a direct `View.build/1` call, with the additional
       store-untouched and repeat-reconcile assertions the unit-level
       test doesn't make. Schema/identity corruption fail closed through
       the identical `View.build/1` gate (`view_test.exs`'s sibling
       reference-mismatch/competing-artifact tests); hash mismatch is
       this family's representative instance for the ordinary-contour
       level this task adds.

  Out of scope, each for a reason already settled at RED time:
  chaos tooling/random injection (the six points are named and
  deterministic — randomness would blur which invariant failed),
  LiveView surfacing of failed/healed states (separate slice), and a
  real LLM anywhere in the path. No test here performs network I/O or
  invokes a live producer — every stage's output comes from
  `Kapelle.Product.FixtureAgent`'s scripted replay of the golden
  workspace's own `rp-*.yaml`/`cd-*.yaml` documents.
  """

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

  import Ecto.Query, only: [from: 2]

  alias Kapelle.Product.{
    CanonicalHash,
    Events,
    FixtureAgent,
    Loader,
    Loop,
    Loops,
    Reconciler,
    Store,
    View
  }

  alias Kapelle.Product.Event
  alias Kapelle.Product.Records.ArtifactRow
  alias Kapelle.Product.Workers.{CreatorWorker, EvaluateWorker, ResearchWorker, StageShell}

  @golden "test/support/fixtures/golden/happy"
  @now_iso "2026-08-12T18:00:00Z"

  setup do
    Application.put_env(:kapelle, :product_clock, fn -> @now_iso end)
    on_exit(fn -> Application.delete_env(:kapelle, :product_clock) end)
    :ok
  end

  defp idea_yaml, do: File.read!(Path.join(@golden, "workspace/idea.yaml"))

  defp start_golden_loop!(loop_id) do
    script = FixtureAgent.script_from_golden!()

    {:ok, _loop_row} =
      Loop.start(idea_yaml(),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: script,
        now_iso: @now_iso
      )

    loop_id
  end

  defp job_args(loop_id, stage, iteration) do
    %{"loop_id" => loop_id, "iteration" => iteration, "stage" => stage, "input_hash" => "x"}
  end

  defp drain_product!, do: Oban.drain_queue(queue: :product, with_recursion: true)

  defp normalized_artifact_observations do
    @golden
    |> Path.join("normalized.json")
    |> File.read!()
    |> Jason.decode!()
    |> Enum.filter(&Map.has_key?(&1, "artifact_hash"))
  end

  defp assert_observation_stored(observation, stored) do
    kind = String.to_existing_atom(observation["artifact_kind"])
    identity = observation["artifact_ref"] |> String.split("://") |> List.last()

    row = Enum.find(stored, &(&1.kind == kind and &1.id == identity))

    assert row, "no artifact stored in Store.all/1 for #{observation["artifact_ref"]}"
    assert row.canonical_hash == observation["artifact_hash"]
  end

  # Shared oracle check for the happy-path fault points (1-4): after a
  # fault is injected and healed and the queue is fully drained, the loop
  # must land byte-for-byte where the uncrashed golden run lands — same
  # artifact hashes, same final proposal, same exchange log (mirrors
  # `parity_crash_test.exs`'s own convergence assertions).
  defp assert_converged_to_golden!(loop_id) do
    assert %{discard: 0, failure: 0} = drain_product!()
    assert Loops.get!(loop_id).status == "ready"

    assert {:ok, view} = View.build(loop_id)
    stored = Store.all(loop_id)

    observations = normalized_artifact_observations()
    assert length(observations) == 4
    Enum.each(observations, &assert_observation_stored(&1, stored))

    {:ok, golden_proposal} =
      Loader.load(:product_proposal, File.read!(Path.join(@golden, "workspace/proposal.yaml")))

    assert CanonicalHash.hash(view.proposal) == CanonicalHash.hash(golden_proposal.doc)

    {:ok, golden_xlog} =
      Loader.load(:exchange_log, File.read!(Path.join(@golden, "workspace/exchange-log.yaml")))

    assert CanonicalHash.hash(view.exchange_log) == CanonicalHash.hash(golden_xlog.doc)

    # A repeat reconcile of the now-terminal loop touches nothing new.
    jobs_before = length(all_enqueued(queue: :product))
    assert {:ok, :terminal} = Reconciler.reconcile(loop_id)
    assert length(all_enqueued(queue: :product)) == jobs_before
    assert Store.all(loop_id) == stored
  end

  # --- point 1: after artifact persistence, before projection ---

  test "1) research/0's artifact and its own exchange entry both land, but the projection is never rewritten and no creator job is enqueued — reconcile repairs both and the drained loop converges to the golden" do
    loop_id = start_golden_loop!("LOOP-FIM-1")

    original_projection = Loops.get!(loop_id).latest_state
    assert is_map(original_projection)

    # Mirrors `ResearchWorker.execute/3` byte-for-byte through its own
    # last persist (the exchange entry) — one boundary further than
    # `reconciler_test.exs`'s own "b" case, which stops before the entry
    # — then simply never calls `StageShell.run/2`'s own `advance/1`
    # (the projection rewrite + creator enqueue).
    {:ok, rp_doc} = FixtureAgent.produce(:researcher, 0, %{key: "golden"})
    assert :ok = StageShell.persist_document(:research_pack, rp_doc, loop_id)

    {:ok, view_after_artifact} = View.build(loop_id)

    assert :ok =
             StageShell.append_exchange_entry(Loops.get!(loop_id), view_after_artifact, %{
               "iteration" => 0,
               "actor" => "researcher",
               "artifact_kind" => "research_pack",
               "artifact_ref" => "research-pack://" <> rp_doc["id"],
               "at" => StageShell.now_iso()
             })

    refute_enqueued(worker: CreatorWorker, queue: :product)
    assert Loops.get!(loop_id).latest_state == original_projection

    expected_input_hash = CanonicalHash.hash(rp_doc)

    assert {:ok, :repaired} = Reconciler.reconcile(loop_id)

    assert_enqueued(
      worker: CreatorWorker,
      queue: :product,
      args: %{
        "loop_id" => loop_id,
        "iteration" => 0,
        "stage" => "concept",
        "input_hash" => expected_input_hash
      }
    )

    assert_converged_to_golden!(loop_id)
  end

  # --- point 2: after projection, before enqueue ---

  test "2) creator/0 completes normally (correct projection, EvaluateWorker enqueued), then the enqueued job's own row is lost — reconcile re-enqueues exactly the missing job without touching the already-correct projection" do
    loop_id = start_golden_loop!("LOOP-FIM-2")

    assert :ok = perform_job(ResearchWorker, job_args(loop_id, "research", 0))
    assert :ok = perform_job(CreatorWorker, job_args(loop_id, "concept", 0))

    projection_before = Loops.get!(loop_id).latest_state
    assert is_map(projection_before)

    # Reconstructs the exact DB state a crash between the projection
    # write and the enqueue's own commit would leave: the projection is
    # already the correct post-creator one, but the job row that would
    # name `EvaluateWorker`/apply/0 never actually persisted.
    {deleted, _} =
      Repo.delete_all(
        from(j in Oban.Job,
          where:
            j.worker == ^Oban.Worker.to_string(EvaluateWorker) and
              fragment("?->>'stage' = ?", j.args, "apply")
        )
      )

    assert deleted == 1
    refute_enqueued(worker: EvaluateWorker, queue: :product)

    {:ok, cd_doc} = FixtureAgent.produce(:creator, 0, %{key: "golden"})
    expected_input_hash = CanonicalHash.hash(cd_doc)

    assert {:ok, :repaired} = Reconciler.reconcile(loop_id)

    assert_enqueued(
      worker: EvaluateWorker,
      queue: :product,
      args: %{
        "loop_id" => loop_id,
        "iteration" => 0,
        "stage" => "apply",
        "input_hash" => expected_input_hash
      }
    )

    # The projection needed no repair — only the missing enqueue did.
    assert Loops.get!(loop_id).latest_state == projection_before

    assert_converged_to_golden!(loop_id)
  end

  # --- point 3: after enqueue, before ack ---

  test "3) creator/0 completes normally, including its own EvaluateWorker enqueue, and is then replayed (redelivery after a lost ack) — no second EvaluateWorker job, no duplicate artifact or event" do
    loop_id = start_golden_loop!("LOOP-FIM-3")

    assert :ok = perform_job(ResearchWorker, job_args(loop_id, "research", 0))
    assert :ok = perform_job(CreatorWorker, job_args(loop_id, "concept", 0))

    stored_before = Store.all(loop_id)
    jobs_before = all_enqueued() |> length()
    :ok = Events.subscribe(loop_id)

    # Models Oban's ordinary retry re-invoking `perform/1` on the very
    # same row after its own completion was never durably acknowledged —
    # everything this job itself produced (its artifact, its exchange
    # entry, AND its own downstream enqueue) already landed.
    assert :ok = perform_job(CreatorWorker, job_args(loop_id, "concept", 0))

    assert Store.all(loop_id) == stored_before
    assert all_enqueued() |> length() == jobs_before
    refute_receive %Event{}, 200

    assert_converged_to_golden!(loop_id)
  end

  # --- point 4: worker re-run after its artifact is already written ---

  test "4) apply/0 completes normally (the evaluate/apply tear's own stage — TASK-107) and is then re-run — no duplicate proposal revision, no duplicate orchestration entry, no duplicate research/1 job" do
    loop_id = start_golden_loop!("LOOP-FIM-4")

    assert :ok = perform_job(ResearchWorker, job_args(loop_id, "research", 0))
    assert :ok = perform_job(CreatorWorker, job_args(loop_id, "concept", 0))
    assert :ok = perform_job(EvaluateWorker, job_args(loop_id, "apply", 0))

    stored_before = Store.all(loop_id)
    jobs_before = all_enqueued() |> length()
    :ok = Events.subscribe(loop_id)

    # The general form of this invariant is already proven for the
    # researcher stage (`research_worker_test.exs`, "a stale replay after
    # the loop already advanced is a no-op") — this instance exercises it
    # for the apply stage specifically, the one this task's own decision
    # (heal the evaluate/apply tear, `test/task_107_red_test.exs`) adds a
    # new derived-entry path to: a replay must stay a no-op even now that
    # `heal_missing_exchange_entries/1` also derives orchestration
    # entries.
    assert :ok = perform_job(EvaluateWorker, job_args(loop_id, "apply", 0))

    assert Store.all(loop_id) == stored_before
    assert all_enqueued() |> length() == jobs_before
    refute_receive %Event{}, 200

    assert_converged_to_golden!(loop_id)
  end

  # --- point 5: derived row deliberately stale or contradicting the artifacts ---
  #
  # Not duplicated here (moduledoc's coverage map): `reconciler_test.exs`
  # "d" and `parity_crash_test.exs`'s LOOP-004/LOOP-007 already inject
  # exactly this fault through the ordinary contour and assert the
  # fail-closed, store-untouched invariant this point requires.

  # --- point 6: artifact present but hash/schema/identity corrupted ---

  test "6) a research-pack row corrupted post-hoc (hash mismatch) fails the loop closed through Reconciler.reconcile/1 — no repair attempt, no new artifact revision, a repeat reconcile is terminal" do
    loop_id = start_golden_loop!("LOOP-FIM-6")

    assert :ok = perform_job(ResearchWorker, job_args(loop_id, "research", 0))

    row = Repo.get_by!(ArtifactRow, loop_id: loop_id, kind: "research_pack")
    corrupted = Map.put(row.doc, "gaps", [%{"what" => "tampered", "blocks_approval" => true}])

    Repo.update_all(
      from(a in ArtifactRow, where: a.loop_id == ^loop_id and a.kind == "research_pack"),
      set: [doc: corrupted]
    )

    stored_before = Store.all(loop_id)
    jobs_before = all_enqueued() |> length()

    assert {:error, {:hash_mismatch, %{kind: :research_pack}}} = Reconciler.reconcile(loop_id)
    assert Loops.get!(loop_id).status == "failed"

    # Fail-closed means fail-closed: zero new revisions, zero new jobs —
    # the corrupted row is the only thing that changed, and that change
    # was the fault injection itself, not a repair attempt.
    assert Store.all(loop_id) == stored_before
    assert all_enqueued() |> length() == jobs_before

    assert {:ok, :terminal} = Reconciler.reconcile(loop_id)
    assert Store.all(loop_id) == stored_before
    assert all_enqueued() |> length() == jobs_before
  end
end
