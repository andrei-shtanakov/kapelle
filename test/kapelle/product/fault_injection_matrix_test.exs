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
    5. Two sub-cases, both named by the design doc's own "stale OR
       contradicting" wording. STALE — NEW here: the loop's own derived
       projection row (`latest_state`) forced back to a structurally
       valid but out-of-date snapshot (a real earlier projection of this
       same loop) after its artifacts have already moved past it;
       `Reconciler.reconcile/1` must rebuild it byte-identically to what
       the (untouched) artifacts imply, writing zero new artifact
       revisions. CONTRADICTING — not duplicated here, already covered:
       `reconciler_test.exs`'s "d" (`NextStage`'s derived `:ready`
       verdict — computed purely from the research-pack/concept-draft
       artifacts — contradicting the stored proposal chain's own
       `"in_iteration"` status; fails closed as `:projection_drift`,
       zero new artifact revisions written — asserted by "d" itself via
       its own before/after `Store.all/1` comparison) and
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

  A seventh test, outside the six numbered points but required by the
  same checklist item ("the evaluate/apply tear has a decided, tested
  behavior"): "C1" folds a copy of `test/task_107_red_test.exs`'s own
  `simulate_apply_delta_tear!/2` in (that file stays frozen, per its own
  convention — only asserts the healed entry exists) and proves the
  FULL invariant every point above already proves for its own fault:
  converges to the happy golden byte-for-byte, and a second reconcile
  right after the heal writes no duplicate orchestration entry.

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
  import Plug.Conn, only: [put_status: 2]

  alias Kapelle.Product.{
    CanonicalHash,
    Events,
    FixtureAgent,
    Loader,
    Loop,
    Loops,
    NextStage,
    Reconciler,
    RunVerdict,
    Store,
    View
  }

  alias Kapelle.Product.Event
  alias Kapelle.Product.Records.{ArtifactRow, LoopRow}
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

    # (I3) baseline right after injection, before the repair, so the
    # repair's own effect is asserted as an explicit delta rather than
    # implied by the later golden comparison.
    stored_before = Store.all(loop_id)
    jobs_before = length(all_enqueued(queue: :product))
    :ok = Events.subscribe(loop_id)

    expected_input_hash = CanonicalHash.hash(rp_doc)

    assert {:ok, :repaired} = Reconciler.reconcile(loop_id)

    # (I3) the repair is a pure projection rewrite + one enqueue: zero
    # new artifact revisions (`Store.all/1`'s own row count has an
    # explicit delta of zero), exactly one new job, and — since
    # `Kapelle.Product.Events.broadcast/1` only ever fires from
    # `Store.put/2`'s own successful insert — no event at all.
    assert length(Store.all(loop_id)) == length(stored_before)
    assert Store.all(loop_id) == stored_before
    assert length(all_enqueued(queue: :product)) == jobs_before + 1
    refute_receive %Event{}, 200

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

    # (I2) the projection is genuinely repaired, not merely "some map":
    # it must equal exactly what a fresh view of the now-complete
    # artifacts implies (`reconciler_test.exs`'s "a" pattern — the same
    # re-derivation `StageShell.do_repair/1` itself performs), verified
    # by an independent recomputation rather than trusting the write
    # happened at all. `StageShell.projection_doc/3`'s own shape carries
    # no per-stage/per-iteration content (only the loop's static config
    # plus a `"stop"` populated only at a terminal verdict), so — this
    # loop still `"running"`, nowhere near terminal — it is legitimately
    # byte-identical to `original_projection` too; that invariance is
    # the CORRECT behavior here, not evidence the repair was skipped.
    loop = Loops.get!(loop_id)
    {:ok, fresh_view} = View.build(loop_id)
    outcome = NextStage.compute(fresh_view, loop.max_iterations)
    assert loop.latest_state == StageShell.projection_doc(loop, fresh_view, outcome)

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
    # name `EvaluateWorker`/apply/0 never actually persisted. (M3)
    # Scoped to this loop's own `loop_id`: without it, the delete would
    # reach across every loop this async:false file's other tests may
    # have already enqueued an `apply` job for.
    {deleted, _} =
      Repo.delete_all(
        from(j in Oban.Job,
          where:
            j.worker == ^Oban.Worker.to_string(EvaluateWorker) and
              fragment("?->>'stage' = ?", j.args, "apply") and
              fragment("?->>'loop_id' = ?", j.args, ^loop_id)
        )
      )

    assert deleted == 1
    refute_enqueued(worker: EvaluateWorker, queue: :product)

    # (I3) baseline right after injection, before the repair.
    stored_before = Store.all(loop_id)
    :ok = Events.subscribe(loop_id)

    {:ok, cd_doc} = FixtureAgent.produce(:creator, 0, %{key: "golden"})
    expected_input_hash = CanonicalHash.hash(cd_doc)

    assert {:ok, :repaired} = Reconciler.reconcile(loop_id)

    # (I3) re-enqueuing the missing job writes zero new artifact
    # revisions and broadcasts no event (only `Store.put/2`'s own
    # successful insert ever does).
    assert length(Store.all(loop_id)) == length(stored_before)
    assert Store.all(loop_id) == stored_before
    refute_receive %Event{}, 200

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

  # --- the evaluate/apply tear invariant (C1, PR #25 review) ---
  #
  # `test/task_107_red_test.exs` is the frozen RED for TASK-107's own
  # decision (heal the tear, derived from the proposal's own delta_log)
  # and only asserts the healed entry's existence. This folds a copy of
  # that same red test's own `simulate_apply_delta_tear!/2` in here (the
  # red file itself stays untouched, per its frozen convention) and
  # asserts the FULL invariant every other point in this matrix already
  # proves: heal to the same terminal outcome as the uncrashed golden
  # run byte-for-byte, and re-reconciling after the heal never
  # duplicates the healed entry or writes anything new.
  defp simulate_apply_delta_tear!(loop_id, iteration) do
    {:ok, view} = View.build(loop_id)
    rp = view.research_packs[iteration]
    cd = view.concept_drafts[iteration]

    flipped = %{
      view.proposal
      | "status" => "in_iteration",
        "version" => view.proposal["version"] + 1,
        "updated_at" => @now_iso
    }

    assert :ok = StageShell.persist_document(:product_proposal, flipped, loop_id)

    delta_log = get_in(flipped, ["content", "delta_log"]) || []

    entry = %{
      "iteration" => iteration,
      "concept_draft" => cd["id"],
      "delta" => cd["proposal_delta"]
    }

    applied = %{
      flipped
      | "version" => flipped["version"] + 1,
        "iteration" => iteration,
        "content" => Map.put(flipped["content"] || %{}, "delta_log", delta_log ++ [entry]),
        "refs" =>
          Map.merge(flipped["refs"], %{
            "latest_research_pack" => "research-pack://" <> rp["id"],
            "latest_concept_draft" => "concept-draft://" <> cd["id"]
          }),
        "updated_at" => @now_iso
    }

    assert :ok = StageShell.persist_document(:product_proposal, applied, loop_id)
  end

  test "C1) the evaluate/apply tear (task_107_red_test's own scenario) heals to the full invariant: converges to the golden byte-for-byte, and a second reconcile writes no duplicate orchestration entry" do
    loop_id = start_golden_loop!("LOOP-FIM-EVAL-TEAR")

    assert :ok = perform_job(ResearchWorker, job_args(loop_id, "research", 0))
    assert :ok = perform_job(CreatorWorker, job_args(loop_id, "concept", 0))

    simulate_apply_delta_tear!(loop_id, 0)

    assert {:ok, view_before} = View.build(loop_id)

    refute Enum.any?(
             view_before.exchange_log["entries"],
             &(&1["iteration"] == 0 and &1["actor"] == "orchestration")
           ),
           "test setup invariant broken: the orchestration entry must be absent before repair"

    assert {:ok, _} = Reconciler.reconcile(loop_id)

    assert {:ok, view_after} = View.build(loop_id)

    healed_entry =
      Enum.find(
        view_after.exchange_log["entries"],
        &(&1["iteration"] == 0 and &1["actor"] == "orchestration")
      )

    assert healed_entry,
           "expected the evaluate/apply tear to heal the missing orchestration exchange " <>
             "entry (derivable from the proposal's own delta_log), but reconcile left the " <>
             "exchange log silently incomplete"

    assert healed_entry["artifact_kind"] == "product_proposal_patch"
    assert healed_entry["artifact_ref"] == "proposal://PP-001"

    # (C1) the full invariant, not merely entry existence: a second
    # reconcile right after the heal writes no duplicate orchestration
    # entry and nothing else new — `Store.all/1` is byte-identical
    # before and after. The loop is still `"running"` (this iteration's
    # own `EvaluateWorker` job has not drained yet), so this second
    # reconcile is `:in_sync`.
    stored_before_second = Store.all(loop_id)
    assert {:ok, :in_sync} = Reconciler.reconcile(loop_id)
    assert Store.all(loop_id) == stored_before_second

    {:ok, view_after_second} = View.build(loop_id)

    assert Enum.count(
             view_after_second.exchange_log["entries"],
             &(&1["iteration"] == 0 and &1["actor"] == "orchestration")
           ) == 1

    # (C1) the healed loop still converges to the SAME terminal outcome
    # as the uncrashed golden run, byte-for-byte —
    # `assert_converged_to_golden!/1` drains the queue and, inside
    # itself, performs its own repeat-reconcile (now `:terminal`, the
    # loop having reached "ready") with the identical
    # `Store.all/1`-unchanged assertion.
    assert_converged_to_golden!(loop_id)
  end

  # --- point 5: derived row deliberately stale or contradicting the artifacts ---
  #
  # The STALE sub-case: NEW here, below — the loop's own derived
  # projection row (`latest_state`) made deliberately stale relative to
  # its already-correct artifacts. The CONTRADICTING sub-case (a derived
  # verdict actively disagreeing with the stored proposal chain, not
  # merely a stale row behind it) is not duplicated here (moduledoc's
  # coverage map): `reconciler_test.exs`'s "d" and
  # `parity_crash_test.exs`'s LOOP-004/LOOP-007 already inject exactly
  # that shape through the ordinary contour and assert the fail-closed,
  # store-untouched invariant it requires.

  test "5) the loop's own derived projection (latest_state) is made deliberately stale relative to its already-correct artifacts — reconcile rebuilds it byte-identically, writes no new artifact revision, and a repeat reconcile is terminal" do
    loop_id = start_golden_loop!("LOOP-FIM-5")

    assert :ok = perform_job(ResearchWorker, job_args(loop_id, "research", 0))
    assert :ok = perform_job(CreatorWorker, job_args(loop_id, "concept", 0))
    assert :ok = perform_job(EvaluateWorker, job_args(loop_id, "apply", 0))
    assert :ok = perform_job(ResearchWorker, job_args(loop_id, "research", 1))
    assert :ok = perform_job(CreatorWorker, job_args(loop_id, "concept", 1))

    # `StageShell.projection_doc/3`'s own shape carries no per-stage
    # content (only the loop's static config plus a `"stop"` populated
    # ONLY at a terminal verdict), so a stale-but-different-content
    # projection genuinely arises only across a running -> terminal
    # transition — this is the loop's own last real re-derivation
    # (creator/1's own `advance/1`), still `"running"`, no `"stop"` yet.
    # Real, structurally valid, and about to fall behind the moment
    # apply/1's own artifacts land.
    stale_projection = Loops.get!(loop_id).latest_state
    assert is_map(stale_projection)
    assert stale_projection["stop"] == nil

    # Hand-simulates `EvaluateWorker.execute/3`'s own apply/1 persist +
    # orchestration entry + `maybe_finalize_ready/3` byte-for-byte
    # (mirrors `test/task_107_red_test.exs`'s own
    # `simulate_apply_delta_tear!/2`, continued through to the finalize
    # persist this time) WITHOUT ever calling `StageShell.run/2`'s own
    # `advance/1` — the projection/status side of a real apply/1
    # completion never runs, so the loop's own artifacts (already
    # durably committed, real `Store.put/2` writes) now imply `"ready"`
    # while the stored `latest_state`/`status` still say otherwise: a
    # derived row genuinely stale relative to the artifacts.
    {:ok, view1} = View.build(loop_id)
    rp1 = view1.research_packs[1]
    cd1 = view1.concept_drafts[1]
    loop = Loops.get!(loop_id)

    delta_log = get_in(view1.proposal, ["content", "delta_log"]) || []
    entry = %{"iteration" => 1, "concept_draft" => cd1["id"], "delta" => cd1["proposal_delta"]}

    applied = %{
      view1.proposal
      | "version" => view1.proposal["version"] + 1,
        "iteration" => 1,
        "content" => Map.put(view1.proposal["content"] || %{}, "delta_log", delta_log ++ [entry]),
        "refs" =>
          Map.merge(view1.proposal["refs"], %{
            "latest_research_pack" => "research-pack://" <> rp1["id"],
            "latest_concept_draft" => "concept-draft://" <> cd1["id"]
          }),
        "updated_at" => @now_iso
    }

    assert :ok = StageShell.persist_document(:product_proposal, applied, loop_id)

    assert :ok =
             StageShell.append_exchange_entry(loop, view1, %{
               "iteration" => 1,
               "actor" => "orchestration",
               "artifact_kind" => "product_proposal_patch",
               "artifact_ref" => "proposal://" <> loop.proposal_id,
               "at" => @now_iso
             })

    ready = %{
      applied
      | "status" => "ready_for_business",
        "version" => applied["version"] + 1,
        "updated_at" => @now_iso
    }

    assert :ok = StageShell.persist_document(:product_proposal, ready, loop_id)

    # Artifacts alone already imply "ready" — but nothing has told the
    # loop row that yet.
    assert Loops.get!(loop_id).status == "running"
    assert Loops.get!(loop_id).latest_state == stale_projection

    # Explicit fault injection (mirrors `reconciler_test.exs`'s own
    # `corrupt_latest_state!/1`): force the stale snapshot back onto the
    # row via the same raw path — a no-op here (nothing else touched it
    # since it was captured above), but makes the fault an explicit,
    # asserted step rather than an implicit side effect of what this
    # test simply didn't do.
    {1, _} =
      Repo.update_all(
        from(l in LoopRow, where: l.loop_id == ^loop_id),
        set: [latest_state: stale_projection]
      )

    assert Loops.get!(loop_id).latest_state == stale_projection

    stored_before = Store.all(loop_id)
    jobs_before = length(all_enqueued(queue: :product))
    :ok = Events.subscribe(loop_id)

    assert {:ok, :repaired} = Reconciler.reconcile(loop_id)

    assert Loops.get!(loop_id).status == "ready"

    # (I2, pattern: reconciler_test.exs "a") rebuilt to exactly what a
    # fresh view of the (already-durable) artifacts implies — not the
    # stale row, and verified by an independent recomputation rather
    # than trusting the write happened at all.
    refute Loops.get!(loop_id).latest_state == stale_projection

    repaired_loop = Loops.get!(loop_id)
    {:ok, fresh_view} = View.build(loop_id)
    outcome = NextStage.compute(fresh_view, repaired_loop.max_iterations)

    assert repaired_loop.latest_state ==
             StageShell.projection_doc(repaired_loop, fresh_view, outcome)

    assert repaired_loop.latest_state["stop"]["verdict"] == "ready_for_business"

    # The repair itself is a pure projection + status rewrite: zero new
    # artifact revisions (both apply/1 persists above already landed
    # before the repair ran), a terminal verdict enqueues nothing, and
    # no event fires (only `Store.put/2`'s own successful insert ever
    # broadcasts one).
    assert Store.all(loop_id) == stored_before
    assert length(all_enqueued(queue: :product)) == jobs_before
    refute_receive %Event{}, 200

    jobs_before_second = length(all_enqueued(queue: :product))
    assert {:ok, :terminal} = Reconciler.reconcile(loop_id)
    assert length(all_enqueued(queue: :product)) == jobs_before_second
    assert Store.all(loop_id) == stored_before

    assert_converged_to_golden!(loop_id)
  end

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
    :ok = Events.subscribe(loop_id)

    assert {:error, {:hash_mismatch, %{kind: :research_pack}}} = Reconciler.reconcile(loop_id)
    assert Loops.get!(loop_id).status == "failed"

    # Fail-closed means fail-closed: zero new revisions, zero new jobs,
    # and no event (the corruption itself was written via `Repo.update_all/2`,
    # not `Store.put/2`, so it never broadcast one either) — the
    # corrupted row is the only thing that changed, and that change was
    # the fault injection itself, not a repair attempt.
    assert Store.all(loop_id) == stored_before
    assert all_enqueued() |> length() == jobs_before
    refute_receive %Event{}, 200

    assert {:ok, :terminal} = Reconciler.reconcile(loop_id)
    assert Store.all(loop_id) == stored_before
    assert all_enqueued() |> length() == jobs_before
    refute_receive %Event{}, 200
  end

  # --- DT-04: live fault classes route through the ordinary worker contour ---
  #
  # BEH-04 (an address the port cannot resolve is terminal, never
  # retried), BEH-10 (the stop_reason a terminal live failure leaves is
  # readable and secret-free), and BEH-11 (the port-class ->
  # job-outcome/loop-status/retry matrix) all go through a real
  # `ResearchWorker` job on a live `model:` address with only the HTTP
  # transport stubbed (`Req.Test`) — the same double-the-real-SDK
  # technique `live_agent_test.exs` uses at the adapter level (BEH-08),
  # driven one layer up through `Oban.drain_queue/1` so the assertions
  # are about the ordinary worker contour's own routing (`StageShell.run/2`
  # -> `perform_stage/3`), not `LiveAgent.produce/3`'s return value alone.
  #
  # BEH-12 (the adapter-level call timeout) is NOT duplicated here: it is
  # already proven, through this identical ordinary-worker-contour
  # technique, by the frozen
  # `test/task_004_45c64cba9edccc4f_890cd12b_red_test.exs` (referenced,
  # not duplicated — this file's own coverage-map convention, moduledoc
  # above). BEH-29's exhaustive secret-avoidance coverage (a live key
  # value that must never surface, across every result shape) is
  # likewise referenced from `live_agent_test.exs` rather than repeated
  # here; BEH-10's own secret assertion below is the narrower "the
  # persisted `stop_reason` column itself never carries a key-shaped
  # string", not a second full sweep of BEH-29's own cases.

  defp dt04_write_catalog! do
    path =
      Path.join(
        System.tmp_dir!(),
        "fault_injection_matrix_catalog_#{System.unique_integer([:positive])}.toml"
      )

    File.write!(path, """
    [[models]]
    provider = "anthropic"
    model = "test-model"

    [models.params]
    temperature = 0.7
    max_tokens = 1000
    """)

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp dt04_install_catalog! do
    Application.put_env(:kapelle, :product_catalog_path, dt04_write_catalog!())
    on_exit(fn -> Application.delete_env(:kapelle, :product_catalog_path) end)
    "anthropic@test-model"
  end

  defp dt04_stub!(fun) do
    name = {__MODULE__, System.unique_integer([:positive])}
    Req.Test.stub(name, fun)
    Application.put_env(:kapelle, :product_provider_req_opts, plug: {Req.Test, name})
    on_exit(fn -> Application.delete_env(:kapelle, :product_provider_req_opts) end)
  end

  defp dt04_start_loop!(loop_id, agent_address) do
    {:ok, _row} =
      Loop.start(idea_yaml(),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 1,
        agent: agent_address,
        now_iso: @now_iso
      )

    loop_id
  end

  defp dt04_research_job(loop_id) do
    Repo.one!(
      from(j in Oban.Job,
        where:
          j.worker == ^Oban.Worker.to_string(ResearchWorker) and
            fragment("?->>'loop_id' = ?", j.args, ^loop_id)
      )
    )
  end

  test "BEH-04) an address the port cannot resolve is terminal: the loop fails closed, the job is cancelled (not retried), and a redelivery makes no new attempt" do
    loop_id = "LOOP-FIM-BEH-04"

    # No catalog, no stub installed at all — `nope:whatever` fails at
    # `Kapelle.Product.Agent.resolve/1` itself (`{:unknown_scheme, ...}`),
    # before any adapter or provider is ever reached (AC-03/BEH-04's own
    # "и не приводит к ретраю платного вызова" for the address family).
    dt04_start_loop!(loop_id, "nope:whatever")

    assert %{discard: 0, cancelled: 1, failure: 0, success: 0} = drain_product!()

    loop = Loops.get!(loop_id)
    assert loop.status == "failed"
    assert loop.stop_reason =~ "unknown_scheme"

    job = dt04_research_job(loop_id)
    assert job.state == "cancelled"
    attempt_after_first_drain = job.attempt

    # A second drain finds nothing runnable: a `cancelled` job is terminal
    # in Oban's own state model, so real redelivery never reaches
    # `perform/1` again — the attempt count cannot grow because nothing
    # ever re-attempts it.
    assert %{discard: 0, cancelled: 0, failure: 0, success: 0} = drain_product!()
    assert dt04_research_job(loop_id).attempt == attempt_after_first_drain
    assert dt04_research_job(loop_id).state == "cancelled"

    # Simulates the other redelivery shape this suite's own point 3/4
    # already use elsewhere in this file (Oban re-invoking `perform/1` on
    # the very same row out of band): `StageShell.run/2`'s own step 1
    # (`terminal?/1`) discards it as a plain `:ok` without ever calling
    # `Agent.resolve/1` again — no new call attempt, no new failure, the
    # loop's own terminal state is untouched.
    assert :ok = perform_job(ResearchWorker, job_args(loop_id, "research", 0))
    assert Loops.get!(loop_id).status == "failed"
    assert Loops.get!(loop_id).stop_reason == loop.stop_reason
  end

  test "BEH-10) a terminal live failure's stop_reason names the port class and the provider's own distinguishable reason, readably and with no secret in it" do
    loop_id = "LOOP-FIM-BEH-10"
    catalog_id = dt04_install_catalog!()

    # The langchain SDK only threads a wire error's own `message` through
    # to `LangChainError.message` for a body it can parse as a recognized
    # error shape (`error.type` present); an unrecognized shape collapses
    # to its own generic "Unexpected response" instead (proven by BEH-08's
    # own bare `%{"error" => %{"message" => ...}}` case in
    # `live_agent_test.exs`, which only asserts the type/port-class, never
    # the message content). Use the recognized shape (mirrors BEH-08's own
    # "content-based provider refusal (invalid_request_error type...)"
    # case) so the provider's own distinguishable text genuinely survives
    # to `stop_reason`.
    dt04_stub!(fn conn ->
      Req.Test.json(conn, %{
        "type" => "error",
        "error" => %{
          "type" => "invalid_request_error",
          "message" => "distinguishable refusal reason"
        }
      })
    end)

    dt04_start_loop!(loop_id, "model:" <> catalog_id)

    assert %{discard: 0, cancelled: 1, failure: 0, success: 0} = drain_product!()

    loop = Loops.get!(loop_id)
    assert loop.status == "failed"
    assert is_binary(loop.stop_reason)

    # The port class (`:domain`) and the provider's own message both show
    # up verbatim — read straight off the persisted `stop_reason` column,
    # never a process log.
    assert loop.stop_reason =~ "domain"
    assert loop.stop_reason =~ "distinguishable refusal reason"

    refute loop.stop_reason =~ "sk-ant"
    refute loop.stop_reason =~ ~r/api[_-]?key/i
  end

  test "BEH-11) :infrastructure — the job errors (retryable), the loop stays running and unchanged, and a redelivery genuinely re-attempts the call rather than being discarded" do
    loop_id = "LOOP-FIM-BEH-11-INFRA"
    catalog_id = dt04_install_catalog!()
    dt04_stub!(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    dt04_start_loop!(loop_id, "model:" <> catalog_id)

    assert Loops.get!(loop_id).status == "running"

    assert %{discard: 0, cancelled: 0, failure: 1, success: 0} = drain_product!()

    loop = Loops.get!(loop_id)
    assert loop.status == "running"
    assert loop.stop_reason == nil

    job = dt04_research_job(loop_id)
    refute job.state in ["cancelled", "discarded"]

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)
    assert verdict.product == :open

    # Unlike BEH-04's terminal address failure above, the loop is still
    # `"running"` — `StageShell.run/2`'s own terminal-loop short-circuit
    # never fires, so a redelivery genuinely re-invokes `Agent.resolve/1`
    # + `produce/3` rather than being silently discarded. The stub is
    # still broken, so this attempt fails the same way — proving the
    # retry path is structurally live, not merely that the job row exists.
    assert {:error, {:provider_error, _type, _msg}} =
             perform_job(ResearchWorker, job_args(loop_id, "research", 0))
  end

  test "BEH-11) :domain — the job is cancelled, the loop fails closed on the product axis, and retry is forbidden" do
    loop_id = "LOOP-FIM-BEH-11-DOMAIN"
    catalog_id = dt04_install_catalog!()

    dt04_stub!(fn conn ->
      conn
      |> put_status(400)
      |> Req.Test.json(%{"type" => "error", "error" => %{"message" => "bad request"}})
    end)

    dt04_start_loop!(loop_id, "model:" <> catalog_id)

    assert %{discard: 0, cancelled: 1, failure: 0, success: 0} = drain_product!()

    loop = Loops.get!(loop_id)
    assert loop.status == "failed"
    assert dt04_research_job(loop_id).state == "cancelled"

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)
    assert verdict.product == :fail
  end

  test "BEH-11) :invalid_artifact — the job is cancelled, the loop fails closed on the product axis, and retry is forbidden" do
    loop_id = "LOOP-FIM-BEH-11-INVALID-ARTIFACT"
    catalog_id = dt04_install_catalog!()

    dt04_stub!(fn conn ->
      Req.Test.json(conn, %{
        "role" => "assistant",
        "type" => "message",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
        "content" => [%{"type" => "text", "text" => "this is not json or yaml { at all"}]
      })
    end)

    dt04_start_loop!(loop_id, "model:" <> catalog_id)

    assert %{discard: 0, cancelled: 1, failure: 0, success: 0} = drain_product!()

    loop = Loops.get!(loop_id)
    assert loop.status == "failed"
    assert loop.stop_reason =~ "invalid_artifact"
    assert dt04_research_job(loop_id).state == "cancelled"

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)
    assert verdict.product == :fail
  end

  test "BEH-11) configuration failure of the run (auth) — the job is cancelled, the loop fails closed OFF the product axis, and retry is forbidden" do
    loop_id = "LOOP-FIM-BEH-11-CONFIG"
    catalog_id = dt04_install_catalog!()

    dt04_stub!(fn conn ->
      conn
      |> put_status(401)
      |> Req.Test.json(%{
        "type" => "error",
        "error" => %{"type" => "authentication_error", "message" => "missing x-api-key"}
      })
    end)

    dt04_start_loop!(loop_id, "model:" <> catalog_id)

    assert %{discard: 0, cancelled: 1, failure: 0, success: 0} = drain_product!()

    loop = Loops.get!(loop_id)
    assert loop.status == "failed"
    assert dt04_research_job(loop_id).state == "cancelled"

    # BEH-24's own routing: a configuration-of-the-run failure stays off
    # the product axis (not `:fail`) even though the worker's own route is
    # the identical terminal `{:cancel, reason}` every other row above
    # takes.
    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)
    refute verdict.product == :fail
  end
end
