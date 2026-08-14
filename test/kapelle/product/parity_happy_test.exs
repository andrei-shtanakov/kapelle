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

    @golden
    |> Path.join("normalized.json")
    |> File.read!()
    |> Jason.decode!()
    |> Enum.filter(&Map.has_key?(&1, "artifact_hash"))
    |> Enum.each(&assert_observation_stored(&1, stored))

    # Pins cross-language hash agreement on a real document: the golden
    # loop.state's own idea_input_hash (computed by the Python producer) must
    # equal what Kapelle.Product.CanonicalHash — this codebase's hash — gets
    # from the same idea document once it is in the view.
    assert Loops.get!(loop_id).latest_state["idea_input_hash"] == CanonicalHash.hash(view.idea)
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
