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

  alias Kapelle.Product.{CanonicalHash, Loader, NextStage, Oracle.Normalizer, Store, View}

  @golden "test/support/fixtures/golden/happy"

  test "the golden happy-path artifacts walk to :ready through view+next_stage" do
    loop_id = "LOOP-GOLDEN"
    seed_golden_workspace(loop_id)

    assert {:ok, view} = View.build(loop_id)

    max = view.loop_state["max_iterations"]
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
    assert view.loop_state["idea_input_hash"] == CanonicalHash.hash(view.idea)
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
  defp seed_golden_workspace(loop_id) do
    ws = Path.join(@golden, "workspace")

    for {kind, file} <-
          [
            {:idea, "idea.yaml"},
            {:product_proposal, "proposal.yaml"},
            {:exchange_log, "exchange-log.yaml"},
            {:loop_state, "loop.state"}
          ] ++ iteration_files(ws) do
      {:ok, record} = Loader.load(kind, File.read!(Path.join(ws, file)))
      {:ok, _} = Store.put(record, loop_id)
    end
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
