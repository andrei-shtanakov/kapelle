defmodule Kapelle.Product.ParityHumanWaiverTest do
  @moduledoc """
  The parity case S3 carried forward and S4 left open (TODO
  `@id:human-waiver-parity`): a critical assumption closed by a human's
  `human_waiver` instead of by research, and a loop that reaches
  `ready_for_business` *because* of it. Until this test the field was
  covered only by `next_stage_test.exs` units — nothing proved that kapelle
  and the reference runner agree on what a waiver does to a real loop.

  The golden is the producer's own run at the vendored pin, generated out of
  band by `scripts/gen_golden.sh <impresario> human_waiver` (see
  `test/support/fixtures/golden/human_waiver/PROVENANCE`); this test never
  runs that script. Its workspace differs from the `happy` golden's in
  exactly one field — cd-002's assumption carries `human_waiver` where
  happy's carries `answered_by` — which is what makes the negative control
  here meaningful: delete that single field from the same script and the
  same contour must stop at `needs_human` instead.

  Clock handling is `e2e_happy_test.exs`'s: every timestamp in the golden is
  the same fixed instant, so pinning `now_iso` for the whole run reaches
  full canonical-hash equality with the producer's own documents.
  """

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Product.{
    CanonicalHash,
    FixtureAgent,
    Loader,
    Loop,
    Loops,
    NextStage,
    Oracle.Normalizer,
    Store,
    StrictParse,
    View
  }

  @golden "test/support/fixtures/golden/human_waiver"
  @now_iso "2026-08-12T18:00:00Z"

  setup do
    Application.put_env(:kapelle, :product_clock, fn -> @now_iso end)
    on_exit(fn -> Application.delete_env(:kapelle, :product_clock) end)
    :ok
  end

  test "a waived critical assumption carries the loop to ready with oracle-equal artifact hashes" do
    loop_id = "LOOP-001"
    start_loop!(loop_id, golden_script!(loop_id))

    assert %{discard: 0, failure: 0} = Oban.drain_queue(queue: :product, with_recursion: true)

    loop = Loops.get!(loop_id)
    assert loop.status == "ready"

    assert {:ok, view} = View.build(loop_id)
    assert {:terminal, :ready, _reason} = NextStage.compute(view, loop.max_iterations)

    # The closure under test is the waiver and nothing else: the concept
    # draft that ended the loop still declares the assumption critical, and
    # closes it by a human's waiver rather than by a research pack.
    assert [assumption] = view.concept_drafts[1]["assumptions"]
    assert assumption["blocks_approval"] == true
    assert assumption["human_waiver"] not in [nil, ""]
    refute Map.has_key?(assumption, "answered_by")

    stored = Store.all(loop_id)
    observations = hash_observations()

    # Two iterations of research+creator (RP-001/CD-001, RP-002/CD-002) —
    # asserted explicitly so a regenerated golden that silently drops or
    # duplicates an observation fails loudly here.
    assert length(observations) == 4
    Enum.each(observations, &assert_observation_stored(&1, stored))

    {:ok, golden_proposal} =
      Loader.load(:product_proposal, File.read!(Path.join(@golden, "workspace/proposal.yaml")))

    assert CanonicalHash.hash(view.proposal) == CanonicalHash.hash(golden_proposal.doc)

    # The oracle's last word: ready_for_business at iteration 1 — the waiver
    # ended the loop on schedule, it did not merely fail to break it.
    final_verdict =
      normalized()
      |> Enum.filter(&Map.has_key?(&1, "verdict"))
      |> List.last()

    assert final_verdict["verdict"] == "ready_for_business"
    assert final_verdict["iteration"] == 1
  end

  test "the same script without the waiver holds at needs_human" do
    loop_id = "LOOP-002"
    start_loop!(loop_id, unwaived_script!(loop_id))

    assert %{discard: 0, failure: 0} = Oban.drain_queue(queue: :product, with_recursion: true)

    # One deleted field is the whole difference from the test above: the
    # assumption is critical again, `open_criticals` never empties, and the
    # budget runs out into a hold. This is what makes the ready verdict up
    # there attributable to the waiver.
    assert Loops.get!(loop_id).status == "needs_human"

    assert {:ok, view} = View.build(loop_id)
    assert {:terminal, :needs_human, _reason} = NextStage.compute(view, 2)
  end

  test "the normalizer matches the committed human_waiver normalized golden" do
    raw =
      @golden
      |> Path.join("raw-trace.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    assert Normalizer.normalize(raw) == normalized()
  end

  defp start_loop!(loop_id, agent) do
    {:ok, _loop_row} =
      Loop.start(File.read!(Path.join(@golden, "workspace/idea.yaml")),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: agent,
        now_iso: @now_iso
      )

    loop_id
  end

  defp golden_script!(key), do: install!(key, golden_docs())

  # The producer's own documents with `human_waiver` deleted from the final
  # concept draft — built by subtraction from the golden rather than
  # hand-written, so the control differs from the case in that field alone.
  defp unwaived_script!(key) do
    install!(key, Map.update!(golden_docs(), {:creator, 1}, &strip_waiver/1))
  end

  defp install!(key, script) do
    :ok = FixtureAgent.install_script!(key, script)
    "fixture:" <> key
  end

  defp strip_waiver(doc) do
    Map.update!(doc, "assumptions", fn assumptions ->
      Enum.map(assumptions, &Map.delete(&1, "human_waiver"))
    end)
  end

  defp golden_docs do
    Map.new(docs_for("rp-*.yaml", :researcher) ++ docs_for("cd-*.yaml", :creator))
  end

  defp docs_for(glob, role) do
    @golden
    |> Path.join("workspace")
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.map(fn path ->
      {:ok, doc} = path |> File.read!() |> StrictParse.parse()
      {{role, doc["iteration"]}, doc}
    end)
  end

  defp normalized do
    @golden |> Path.join("normalized.json") |> File.read!() |> Jason.decode!()
  end

  defp hash_observations, do: Enum.filter(normalized(), &Map.has_key?(&1, "artifact_hash"))

  defp assert_observation_stored(observation, stored) do
    kind = String.to_existing_atom(observation["artifact_kind"])
    identity = observation["artifact_ref"] |> String.split("://") |> List.last()

    row = Enum.find(stored, &(&1.kind == kind and &1.id == identity))

    assert row, "no artifact stored in Store.all/1 for #{observation["artifact_ref"]}"
    assert row.canonical_hash == observation["artifact_hash"]
  end
end
