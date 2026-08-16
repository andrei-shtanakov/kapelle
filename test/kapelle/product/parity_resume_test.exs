defmodule Kapelle.Product.ParityResumeTest do
  @moduledoc """
  TASK-106 follow-up: the full resume-golden parity the task's checklist
  deferred. The golden set is a literal replay of the producer's own
  `forconcept resume` run at the vendored pin (see
  `test/support/fixtures/golden/resume/PROVENANCE`): STUCK to
  `needs_human`, the producer's resume authoring `decisions/lrd-001.yaml`,
  then iteration 2 closing the criticals -> `ready_for_business`. This
  test walks the SAME path through kapelle's own contour: the hold via
  workers, `Resume.consume/2` of the producer-authored decision (not a
  hand-written double), a drain AFTER the resume, and hash-level parity
  of every artifact against the oracle.
  """

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Product.{
    FixtureAgent,
    Loop,
    Loops,
    NextStage,
    Oracle.Normalizer,
    Resume,
    Store,
    StrictParse,
    View
  }

  @golden "test/support/fixtures/golden/resume"
  @now_iso "2026-08-12T18:00:00Z"

  setup do
    Application.put_env(:kapelle, :product_clock, fn -> @now_iso end)
    on_exit(fn -> Application.delete_env(:kapelle, :product_clock) end)
    :ok
  end

  defp golden_docs(glob, role) do
    @golden
    |> Path.join("workspace")
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.map(fn path ->
      {:ok, doc} = path |> File.read!() |> StrictParse.parse()
      {{role, doc["iteration"]}, doc}
    end)
  end

  defp resume_script!(key) do
    script =
      Map.new(golden_docs("rp-*.yaml", :researcher) ++ golden_docs("cd-*.yaml", :creator))

    FixtureAgent.install_script!(key, script)
    "fixture:" <> key
  end

  # The producer-authored decision, byte-real from the golden workspace —
  # its subject names the producer's own loop_id, so the loop under test
  # must carry the same id.
  defp golden_decision! do
    {:ok, doc} =
      @golden
      |> Path.join("workspace/decisions/lrd-001.yaml")
      |> File.read!()
      |> StrictParse.parse()

    doc
  end

  test "drain after resume: the producer-authored decision reopens the loop and the walk lands on ready with oracle-equal artifact hashes" do
    loop_id = "LOOP-001"
    agent = resume_script!(loop_id)

    {:ok, _} =
      Loop.start(File.read!(Path.join(@golden, "workspace/idea.yaml")),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: agent,
        now_iso: @now_iso
      )

    assert %{discard: 0, failure: 0} =
             Oban.drain_queue(queue: :product, with_recursion: true)

    assert Loops.get!(loop_id).status == "needs_human"

    assert {:ok, %{decision_ref: "loop-resume-decision://LRD-001"}} =
             Resume.consume(loop_id, [golden_decision!()])

    assert %{discard: 0, failure: 0} =
             Oban.drain_queue(queue: :product, with_recursion: true)

    loop = Loops.get!(loop_id)
    assert loop.status == "ready"
    # Widened by the golden decision's own new_max_iterations, never a call arg.
    assert loop.max_iterations == 3

    assert {:ok, view} = View.build(loop_id)
    assert {:terminal, :ready, _reason} = NextStage.compute(view, loop.max_iterations)

    stored = Store.all(loop_id)

    observations =
      @golden
      |> Path.join("normalized.json")
      |> File.read!()
      |> Jason.decode!()

    hash_observations = Enum.filter(observations, &Map.has_key?(&1, "artifact_hash"))

    # Three full iterations of research+creator: RP-001..003 / CD-001..003 —
    # asserted explicitly so a regenerated golden that silently drops or
    # duplicates an observation fails loudly here.
    assert length(hash_observations) == 6

    Enum.each(hash_observations, fn observation ->
      kind = String.to_existing_atom(observation["artifact_kind"])
      identity = observation["artifact_ref"] |> String.split("://") |> List.last()
      row = Enum.find(stored, &(&1.kind == kind and &1.id == identity))
      assert row, "no artifact stored in Store.all/1 for #{observation["artifact_ref"]}"
      assert row.canonical_hash == observation["artifact_hash"]
    end)

    # The oracle's last word is the one our walk reproduces: a
    # ready_for_business verdict at iteration 2 — i.e. real post-resume
    # progress under the widened budget, not a re-check of the hold.
    final_verdict =
      observations
      |> Enum.filter(&Map.has_key?(&1, "verdict"))
      |> List.last()

    assert final_verdict["verdict"] == "ready_for_business"
    assert final_verdict["iteration"] == 2
  end

  test "the normalizer matches the committed resume normalized golden" do
    raw =
      @golden
      |> Path.join("raw-trace.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    expected = @golden |> Path.join("normalized.json") |> File.read!() |> Jason.decode!()
    assert Normalizer.normalize(raw) == expected
  end
end
