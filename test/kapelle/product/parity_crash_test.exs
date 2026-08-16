defmodule Kapelle.Product.ParityCrashTest do
  @moduledoc """
  The crash case of the parity matrix (design doc §8, S4). Unlike the
  other cases it needs no golden set of its own: the producer proved a
  crashed-and-resumed run is byte-identical to the uncrashed one at every
  boundary, so the crash oracle IS the happy golden — the assertion is
  convergence, not a new trace.

  The simulated crash is the canonical crash-after-authoritative-commit
  gap the reconciler exists for (its own moduledoc; reconciler_test "b"):
  the iteration-0 research pack lands via the worker's own store path,
  but the exchange-log append and the creator enqueue that would normally
  follow never happen. `Reconciler.reconcile/1` repairs, the queue drains,
  and the final state must be hash-equal to the happy golden — same
  artifact hashes, same final proposal, same exchange log.
  """

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Product.{
    CanonicalHash,
    FixtureAgent,
    Loader,
    Loop,
    Loops,
    Reconciler,
    Store,
    View
  }

  alias Kapelle.Product.Workers.StageShell

  @golden "test/support/fixtures/golden/happy"
  @now_iso "2026-08-12T18:00:00Z"

  setup do
    Application.put_env(:kapelle, :product_clock, fn -> @now_iso end)
    on_exit(fn -> Application.delete_env(:kapelle, :product_clock) end)
    :ok
  end

  test "crash at the first boundary + reconcile + drain converges to the happy golden byte-for-byte" do
    loop_id = "LOOP-001"
    script = FixtureAgent.script_from_golden!()

    {:ok, _} =
      Loop.start(File.read!(Path.join(@golden, "workspace/idea.yaml")),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: script,
        now_iso: @now_iso
      )

    # Crash-after-authoritative-commit: RP-001 lands through the worker's
    # own store path, but the worker itself "never ran to completion" —
    # no exchange-log append, no creator enqueue.
    {:ok, rp_doc} = FixtureAgent.produce(:researcher, 0, %{key: "golden"})
    assert :ok = StageShell.persist_document(:research_pack, rp_doc, loop_id)

    assert {:ok, _} = Reconciler.reconcile(loop_id)

    assert %{discard: 0, failure: 0} =
             Oban.drain_queue(queue: :product, with_recursion: true)

    loop = Loops.get!(loop_id)
    assert loop.status == "ready"

    assert {:ok, view} = View.build(loop_id)
    stored = Store.all(loop_id)

    # (1) every golden artifact observation hash-matches a stored row.
    observations =
      @golden
      |> Path.join("normalized.json")
      |> File.read!()
      |> Jason.decode!()
      |> Enum.filter(&Map.has_key?(&1, "artifact_hash"))

    assert length(observations) == 4

    Enum.each(observations, fn observation ->
      kind = String.to_existing_atom(observation["artifact_kind"])
      identity = observation["artifact_ref"] |> String.split("://") |> List.last()
      row = Enum.find(stored, &(&1.kind == kind and &1.id == identity))
      assert row, "no artifact stored in Store.all/1 for #{observation["artifact_ref"]}"
      assert row.canonical_hash == observation["artifact_hash"]
    end)

    # (2) final proposal and exchange log equal the golden workspace's by
    # canonical hash — the crash left no seam anywhere in the evidence.
    {:ok, golden_proposal} =
      Loader.load(:product_proposal, File.read!(Path.join(@golden, "workspace/proposal.yaml")))

    assert CanonicalHash.hash(view.proposal) == CanonicalHash.hash(golden_proposal.doc)

    {:ok, golden_xlog} =
      Loader.load(:exchange_log, File.read!(Path.join(@golden, "workspace/exchange-log.yaml")))

    assert CanonicalHash.hash(view.exchange_log) == CanonicalHash.hash(golden_xlog.doc)

    # (3) healed means healed: a second reconcile touches nothing new.
    # The loop is already "ready" (a final status) by this point, so
    # `Reconciler.reconcile/1`'s own contract (its moduledoc; same as
    # reconciler_test "c") is `:terminal`, not `:in_sync` — `:in_sync` is
    # reserved for a *running* loop that already agrees with its own
    # artifacts. Either way nothing new happens: same job count, same
    # stored rows.
    jobs_before = length(all_enqueued(queue: :product))
    assert {:ok, :terminal} = Reconciler.reconcile(loop_id)
    assert length(all_enqueued(queue: :product)) == jobs_before
    assert Store.all(loop_id) == stored
  end

  test "the same crash, healed with no explicit reconcile — the replayed research job's own run/2 heals it via drain alone" do
    loop_id = "LOOP-002"
    script = FixtureAgent.script_from_golden!()

    {:ok, _} =
      Loop.start(File.read!(Path.join(@golden, "workspace/idea.yaml")),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: script,
        now_iso: @now_iso
      )

    # Same torn state as the crash test above (RP-001 lands, no
    # exchange-log append, no creator enqueue) — but this time nothing
    # calls `Reconciler.reconcile/1` at all. `Loop.start/2` already
    # enqueued the loop's very first `ResearchWorker` job; draining the
    # queue alone replays it. That job's own `output_exists?/2` already
    # sees RP-001 (idempotent-skip, `StageShell.handle_stage/5`), so it
    # never re-executes the researcher — it just re-derives via
    # `advance/1`'s `do_repair/1`, which is where the heal actually
    # fires (unconditional pre-pass, `do_repair/1`'s own moduledoc).
    {:ok, rp_doc} = FixtureAgent.produce(:researcher, 0, %{key: "golden"})
    assert :ok = StageShell.persist_document(:research_pack, rp_doc, loop_id)

    assert %{discard: 0, failure: 0} =
             Oban.drain_queue(queue: :product, with_recursion: true)

    loop = Loops.get!(loop_id)
    assert loop.status == "ready"

    assert {:ok, view} = View.build(loop_id)
    stored = Store.all(loop_id)

    {:ok, golden_proposal} =
      Loader.load(:product_proposal, File.read!(Path.join(@golden, "workspace/proposal.yaml")))

    assert CanonicalHash.hash(view.proposal) == CanonicalHash.hash(golden_proposal.doc)

    {:ok, golden_xlog} =
      Loader.load(:exchange_log, File.read!(Path.join(@golden, "workspace/exchange-log.yaml")))

    assert CanonicalHash.hash(view.exchange_log) == CanonicalHash.hash(golden_xlog.doc)

    observations =
      @golden
      |> Path.join("normalized.json")
      |> File.read!()
      |> Jason.decode!()
      |> Enum.filter(&Map.has_key?(&1, "artifact_hash"))

    Enum.each(observations, fn observation ->
      kind = String.to_existing_atom(observation["artifact_kind"])
      identity = observation["artifact_ref"] |> String.split("://") |> List.last()
      row = Enum.find(stored, &(&1.kind == kind and &1.id == identity))
      assert row, "no artifact stored in Store.all/1 for #{observation["artifact_ref"]}"
      assert row.canonical_hash == observation["artifact_hash"]
    end)
  end

  test "heal is idempotent: reconciling the same torn state twice in a row (before it ever reaches ready) heals once and is in_sync the second time" do
    loop_id = "LOOP-003"
    script = FixtureAgent.script_from_golden!()

    {:ok, _} =
      Loop.start(File.read!(Path.join(@golden, "workspace/idea.yaml")),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: script,
        now_iso: @now_iso
      )

    {:ok, rp_doc} = FixtureAgent.produce(:researcher, 0, %{key: "golden"})
    assert :ok = StageShell.persist_document(:research_pack, rp_doc, loop_id)

    # First reconcile heals the missing researcher entry (born here,
    # entries == [researcher]) and enqueues the creator — the loop is
    # still "running", nothing drained yet.
    assert {:ok, :repaired} = Reconciler.reconcile(loop_id)
    assert Loops.get!(loop_id).status == "running"

    assert {:ok, view_after_first} = View.build(loop_id)
    assert length(view_after_first.exchange_log["entries"]) == 1

    jobs_before = length(all_enqueued(queue: :product))

    # Second reconcile, same torn state, nothing new to heal: the
    # researcher entry it just healed is already there.
    assert {:ok, :in_sync} = Reconciler.reconcile(loop_id)

    assert length(all_enqueued(queue: :product)) == jobs_before

    assert {:ok, view_after_second} = View.build(loop_id)
    assert length(view_after_second.exchange_log["entries"]) == 1
    assert view_after_second.exchange_log == view_after_first.exchange_log
  end

  test "a genuine exchange-log corruption (not a missing entry) stays fail-closed instead of being healed" do
    loop_id = "LOOP-004"
    script = FixtureAgent.script_from_golden!()

    {:ok, _} =
      Loop.start(File.read!(Path.join(@golden, "workspace/idea.yaml")),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: script,
        now_iso: @now_iso
      )

    {:ok, rp_doc} = FixtureAgent.produce(:researcher, 0, %{key: "golden"})
    {:ok, cd_doc} = FixtureAgent.produce(:creator, 0, %{key: "golden"})
    assert :ok = StageShell.persist_document(:research_pack, rp_doc, loop_id)
    assert :ok = StageShell.persist_document(:concept_draft, cd_doc, loop_id)

    # Both entries are present — nothing is *missing* — but the creator
    # entry is written before the researcher entry for the same
    # iteration: a `:chain_violation` of kind `:exchange_log`, but rule
    # `:entry_order`, not a `:missing_*_entry` — outside the heal's
    # narrow trigger, so this must stay fail-closed exactly as before
    # this fix.
    corrupted_log = %{
      "id" => "XL-001",
      "proposal_ref" => "proposal://PP-001",
      "entries" => [
        %{
          "iteration" => 0,
          "actor" => "creator",
          "artifact_kind" => "concept_draft",
          "artifact_ref" => "concept-draft://" <> cd_doc["id"],
          "at" => @now_iso
        },
        %{
          "iteration" => 0,
          "actor" => "researcher",
          "artifact_kind" => "research_pack",
          "artifact_ref" => "research-pack://" <> rp_doc["id"],
          "at" => @now_iso
        }
      ]
    }

    assert :ok = StageShell.persist_document(:exchange_log, corrupted_log, loop_id)

    assert {:error, {:chain_violation, %{kind: :exchange_log, rule: :entry_order}}} =
             Reconciler.reconcile(loop_id)

    assert Loops.get!(loop_id).status == "failed"
  end

  test "a concurrent heal/append race that lands the same entry with a different timestamp is a tolerated no-op, not a conflict failure" do
    loop_id = "LOOP-005"
    script = FixtureAgent.script_from_golden!()

    {:ok, _} =
      Loop.start(File.read!(Path.join(@golden, "workspace/idea.yaml")),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: script,
        now_iso: @now_iso
      )

    {:ok, rp_doc} = FixtureAgent.produce(:researcher, 0, %{key: "golden"})
    assert :ok = StageShell.persist_document(:research_pack, rp_doc, loop_id)

    loop = Loops.get!(loop_id)

    # Simulate the concurrent winner: a `Reconciler` sweep's own heal (or
    # another worker's own append) lands FIRST, at revision 1, stamped
    # with its own clock reading.
    winner_entry = %{
      "iteration" => 0,
      "actor" => "researcher",
      "artifact_kind" => "research_pack",
      "artifact_ref" => "research-pack://" <> rp_doc["id"],
      "at" => "2020-01-01T00:00:00Z"
    }

    winner_doc = %{
      "id" => loop.exchange_log_id,
      "proposal_ref" => "proposal://" <> loop.proposal_id,
      "entries" => [winner_entry]
    }

    assert :ok = StageShell.persist_document(:exchange_log, winner_doc, loop_id)

    # The racing caller's own view was captured BEFORE the winner's write
    # landed (`exchange_log: nil`, exactly the view a researcher's own
    # `execute/3` would have held going into its own append) — it
    # independently builds the SAME logical entry, stamped with its own
    # (different) clock reading, and tries to append it.
    stale_view = %View{loop_id: loop_id}

    racing_entry = %{
      "iteration" => 0,
      "actor" => "researcher",
      "artifact_kind" => "research_pack",
      "artifact_ref" => "research-pack://" <> rp_doc["id"],
      "at" => @now_iso
    }

    assert :ok = StageShell.append_exchange_entry(loop, stale_view, racing_entry)

    # Tolerated: no duplicate, no corruption, no failure — the winner's
    # own entry (its own timestamp) is what's actually stored.
    assert {:ok, view} = View.build(loop_id)
    assert view.exchange_log["entries"] == [winner_entry]
    assert Loops.get!(loop_id).status == "running"

    # Same tolerance from the heal side: reconciling this loop now must
    # not re-attempt (or fail over) an entry that's already effectively
    # there.
    assert {:ok, :repaired} = Reconciler.reconcile(loop_id)
    assert Loops.get!(loop_id).status == "running"
  end

  test "a genuinely divergent exchange-log conflict (not just a differing timestamp) still fails closed" do
    loop_id = "LOOP-006"
    script = FixtureAgent.script_from_golden!()

    {:ok, _} =
      Loop.start(File.read!(Path.join(@golden, "workspace/idea.yaml")),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: script,
        now_iso: @now_iso
      )

    {:ok, rp_doc} = FixtureAgent.produce(:researcher, 0, %{key: "golden"})
    assert :ok = StageShell.persist_document(:research_pack, rp_doc, loop_id)

    loop = Loops.get!(loop_id)

    # A winner that names a DIFFERENT artifact entirely — a real,
    # semantic disagreement, not merely a differing timestamp.
    winner_entry = %{
      "iteration" => 0,
      "actor" => "researcher",
      "artifact_kind" => "research_pack",
      "artifact_ref" => "research-pack://SOME-OTHER-PACK",
      "at" => "2020-01-01T00:00:00Z"
    }

    winner_doc = %{
      "id" => loop.exchange_log_id,
      "proposal_ref" => "proposal://" <> loop.proposal_id,
      "entries" => [winner_entry]
    }

    assert :ok = StageShell.persist_document(:exchange_log, winner_doc, loop_id)

    stale_view = %View{loop_id: loop_id}

    racing_entry = %{
      "iteration" => 0,
      "actor" => "researcher",
      "artifact_kind" => "research_pack",
      "artifact_ref" => "research-pack://" <> rp_doc["id"],
      "at" => @now_iso
    }

    assert {:error, {:artifact_conflict, :exchange_log, _id, _existing_hash, _new_hash}} =
             StageShell.append_exchange_entry(loop, stale_view, racing_entry)
  end
end
