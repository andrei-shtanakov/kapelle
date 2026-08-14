defmodule Kapelle.Product.ParityHappyTest do
  @moduledoc """
  The S2 exit gate (Task 8): no workers involved, no live producer call —
  replay the golden happy-path workspace's artifacts through
  `Loader` -> `Store` -> `View` -> `NextStage` and check the domain walk
  lands on `:ready`, then separately check the normalizer reproduces the
  committed `normalized.json` from the committed `raw-trace.jsonl`.

  The golden workspace was generated once, out of band, by
  `scripts/gen_golden.sh` against the pinned impresario commit (see
  `test/support/fixtures/golden/happy/PROVENANCE`) — this test never runs
  that script itself.
  """

  use Kapelle.DataCase, async: false

  alias Kapelle.Product.{CanonicalHash, Loader, Loops, NextStage, Oracle.Normalizer, Store, View}
  alias Kapelle.Product.Record

  @golden "test/support/fixtures/golden/happy"

  test "the golden happy-path artifacts walk to :ready through view+next_stage" do
    loop_id = "LOOP-GOLDEN"
    seed_golden_workspace(loop_id)

    assert {:ok, view} = View.build(loop_id)

    max = Loops.get!(loop_id).max_iterations
    assert {:terminal, :ready, _reason} = NextStage.compute(view, max)
  end

  test "the golden happy-path artifacts match the oracle's real cross-language hashes" do
    loop_id = "LOOP-GOLDEN-ORACLE"
    seed_golden_workspace(loop_id)

    assert {:ok, view} = View.build(loop_id)

    stored = Store.all(loop_id)

    observations =
      @golden
      |> Path.join("normalized.json")
      |> File.read!()
      |> Jason.decode!()
      |> Enum.filter(&Map.has_key?(&1, "artifact_hash"))

    # N1 (S2 carry-forward): the golden happy path is exactly two
    # iterations of research+creator (RP-001/CD-001, RP-002/CD-002) —
    # asserted explicitly so a future golden regeneration that silently
    # drops or duplicates an artifact_written observation fails loudly
    # here instead of the `Enum.each` below quietly checking fewer rows.
    assert length(observations) == 4

    Enum.each(observations, &assert_observation_stored(&1, stored))

    # Pins cross-language hash agreement on a real document: the golden
    # loop.state's own idea_input_hash (computed by the Python producer) must
    # equal what Kapelle.Product.CanonicalHash — this codebase's hash — gets
    # from the same idea document once it is in the view.
    assert Loops.get!(loop_id).latest_state["idea_input_hash"] == CanonicalHash.hash(view.idea)
  end

  test "the proposal chain's transitions are consistent with the golden trace's transition observations" do
    loop_id = "LOOP-GOLDEN-TRANSITIONS"
    seed_golden_workspace(loop_id)

    assert {:ok, view} = View.build(loop_id)

    trace_transitions =
      @golden
      |> Path.join("raw-trace.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["event"] == "transition"))

    # (a) the golden trace's own transitions are internally consistent:
    # each one names a strictly higher proposal_version than the last.
    versions = Enum.map(trace_transitions, & &1["proposal_version"])
    assert versions == Enum.sort(versions)
    assert Enum.uniq(versions) == versions

    # (b) the workspace ships only the FINAL product-proposal snapshot —
    # the producer overwrites proposal.yaml in place as the loop runs, so
    # earlier versions are not recoverable from a static workspace replay.
    # Our proposal_chain therefore has exactly one stored revision and
    # yields no (from, to) transition pair of its own to compare against
    # the trace's full sequence. What IS honestly checkable here is that
    # our single snapshot agrees with the trace's own last word: the
    # final transition's destination status and version. Full
    # transition-SEQUENCE equality (this test's eventual promise) only
    # becomes meaningful once Kapelle itself produces a multi-snapshot
    # chain by actually running the loop end to end — that is task 8's
    # e2e test, not a workspace replay.
    assert [_single_snapshot] = view.proposal_chain
    last_transition = List.last(trace_transitions)
    assert view.proposal["status"] == last_transition["to"]
    assert view.proposal["version"] == last_transition["proposal_version"]
  end

  test "the normalizer matches the committed normalized golden" do
    raw =
      @golden
      |> Path.join("raw-trace.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    expected = @golden |> Path.join("normalized.json") |> File.read!() |> Jason.decode!()
    assert Normalizer.normalize(raw) == expected
  end

  # Replay artifacts in file order — the store is order-insensitive.
  # loop.state is NOT an authoritative artifact (owner's
  # loop-state-leaves-the-store decision, 2026-08-14): it is still
  # `Loader.load(:loop_state, ...)`-validated (the schema stays vendored;
  # parity still validates the golden file's shape before projecting
  # it), but it lands in `Kapelle.Product.Loops`'s config + projection
  # surface instead of `Store`.
  defp seed_golden_workspace(loop_id) do
    ws = Path.join(@golden, "workspace")

    for {kind, file} <-
          [
            {:idea, "idea.yaml"},
            {:product_proposal, "proposal.yaml"},
            {:exchange_log, "exchange-log.yaml"}
          ] ++ iteration_files(ws) do
      {:ok, record} = Loader.load(kind, File.read!(Path.join(ws, file)))
      {:ok, _} = Store.put(record, loop_id)
    end

    seed_loop_config(loop_id, ws)
  end

  defp seed_loop_config(loop_id, ws) do
    {:ok, %Record{doc: state_doc}} =
      Loader.load(:loop_state, File.read!(Path.join(ws, "loop.state")))

    {:ok, _} =
      Loops.create(%{
        loop_id: loop_id,
        idea_identity: state_doc["idea_ref"] |> String.split("://") |> List.last(),
        proposal_id: state_doc["proposal_id"],
        exchange_log_id: state_doc["exchange_log_id"],
        max_iterations: state_doc["max_iterations"],
        agent: "fixture:golden"
      })

    {:ok, _} = Loops.put_state_projection(loop_id, state_doc)
  end

  defp assert_observation_stored(observation, stored) do
    kind = String.to_existing_atom(observation["artifact_kind"])
    identity = observation["artifact_ref"] |> String.split("://") |> List.last()

    row = Enum.find(stored, &(&1.kind == kind and &1.id == identity))

    assert row, "no artifact stored in Store.all/1 for #{observation["artifact_ref"]}"
    assert row.canonical_hash == observation["artifact_hash"]
  end

  defp iteration_files(ws) do
    rps =
      for path <- Path.wildcard(Path.join(ws, "rp-*.yaml")),
          do: {:research_pack, Path.basename(path)}

    cds =
      for path <- Path.wildcard(Path.join(ws, "cd-*.yaml")),
          do: {:concept_draft, Path.basename(path)}

    rps ++ cds
  end
end
