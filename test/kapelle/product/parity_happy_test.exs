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

  alias Kapelle.Product.{Loader, NextStage, Oracle.Normalizer, Store, View}

  @golden "test/support/fixtures/golden/happy"

  test "the golden happy-path artifacts walk to :ready through view+next_stage" do
    ws = Path.join(@golden, "workspace")
    loop_id = "LOOP-GOLDEN"

    # Replay artifacts in file order — the store is order-insensitive.
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

    assert {:ok, view} = View.build(loop_id)

    max = view.loop_state["max_iterations"]
    assert {:terminal, :ready, _reason} = NextStage.compute(view, max)
  end

  test "the normalizer reproduces the committed normalized golden byte-for-byte" do
    raw =
      @golden
      |> Path.join("raw-trace.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    expected = @golden |> Path.join("normalized.json") |> File.read!() |> Jason.decode!()
    assert Normalizer.normalize(raw) == expected
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
