defmodule Kapelle.Product.ParityInvalidArtifactTest do
  @moduledoc """
  The invalid-artifact case of the parity matrix (design doc §8, S4). The
  golden set is a literal replay of the producer's own
  `test_invalid_artifact_fails_closed` at the vendored pin (see
  `test/support/fixtures/golden/invalid_artifact/PROVENANCE`): the
  researcher's iteration-0 document violates the research-pack schema,
  the runner refuses to persist it (`artifact_rejected`) and stops
  fail-closed with verdict `failed` at iteration 0 — no artifact, no
  exchange log, ever.

  This test walks the same path through kapelle's own contour with the
  same broken document (the needs_human golden's RP-001 with its
  `brief_for_creator` blanked — the exact mutation the producer's
  fixture makes) and checks kapelle lands on the same domain facts the
  oracle records: rejection of that kind at that stage and iteration,
  nothing persisted, terminal failed.
  """

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Product.{
    FixtureAgent,
    Loop,
    Loops,
    Oracle.Normalizer,
    Store,
    StrictParse
  }

  @golden "test/support/fixtures/golden/invalid_artifact"
  @needs_human_ws "test/support/fixtures/golden/needs_human/workspace"
  @now_iso "2026-08-12T18:00:00Z"

  setup do
    Application.put_env(:kapelle, :product_clock, fn -> @now_iso end)
    on_exit(fn -> Application.delete_env(:kapelle, :product_clock) end)
    :ok
  end

  # The producer's broken fixture is its valid iteration-0 research pack
  # with `brief_for_creator` blanked; rebuild it the same way from a real
  # golden document instead of hand-writing a double.
  defp broken_rp! do
    {:ok, doc} =
      @needs_human_ws
      |> Path.join("rp-001.yaml")
      |> File.read!()
      |> StrictParse.parse()

    Map.put(doc, "brief_for_creator", "")
  end

  test "an invalid researcher artifact fails the loop closed: nothing persisted, terminal failed — the oracle's own domain facts" do
    loop_id = "LOOP-001"
    FixtureAgent.install_script!(loop_id, %{{:researcher, 0} => broken_rp!()})

    {:ok, _} =
      Loop.start(File.read!(Path.join(@golden, "workspace/idea.yaml")),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: "fixture:" <> loop_id,
        now_iso: @now_iso
      )

    assert %{discard: 0, failure: 0} =
             Oban.drain_queue(queue: :product, with_recursion: true)

    observations =
      @golden
      |> Path.join("normalized.json")
      |> File.read!()
      |> Jason.decode!()

    # The oracle records exactly one rejection: iteration 0, researcher
    # stage, research_pack kind.
    assert [rejection] = Enum.filter(observations, & &1["rejected"])
    assert rejection["iteration"] == 0
    assert rejection["stage"] == "researcher"
    assert rejection["artifact_kind"] == "research_pack"

    # ...and a fail-closed terminal at the same iteration.
    assert [stopped] = Enum.filter(observations, &Map.has_key?(&1, "verdict"))
    assert stopped["verdict"] == "failed"
    assert stopped["iteration"] == 0

    # Kapelle's walk reproduces those facts: the loop is failed for the
    # invalid artifact...
    loop = Loops.get!(loop_id)
    assert loop.status == "failed"
    assert loop.stop_reason =~ "invalid_artifact"

    # ...and the rejected kind was never persisted — nor anything
    # downstream of it. Only the init-time idea + proposal snapshot exist,
    # mirroring the producer's workspace (idea.yaml, proposal.yaml,
    # loop.state and nothing else).
    stored_kinds = loop_id |> Store.all() |> Enum.map(& &1.kind) |> Enum.sort()
    assert stored_kinds == [:idea, :product_proposal]

    # No further job was enqueued after the fail-closed stop.
    assert [] = all_enqueued(queue: :product)
  end

  test "the normalizer matches the committed invalid_artifact normalized golden" do
    raw =
      @golden
      |> Path.join("raw-trace.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    expected = @golden |> Path.join("normalized.json") |> File.read!() |> Jason.decode!()
    assert Normalizer.normalize(raw) == expected
  end
end
