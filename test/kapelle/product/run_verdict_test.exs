defmodule Kapelle.Product.RunVerdictTest do
  @moduledoc """
  The two-axis verdict (design doc §1, exit §9.3) over real loops driven
  through the real contour — every case here is one of the committed
  golden scenarios replayed by `FixtureAgent`, so the product axis is
  judged against runs the parity suite already proves agree with the
  reference runner.

  The load-bearing claim is that the axes do not collapse: a loop that
  produced the right thing still reports `harness: :observability_gap`
  while cost is un-instrumented, and a loop whose evidence is damaged
  reports the damage even though its product result was recorded.
  """

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

  import Ecto.Query, only: [from: 2]

  alias Kapelle.Product.{FixtureAgent, Loop, RunVerdict, Store, StrictParse}
  alias Kapelle.Product.Records.ArtifactRow

  @golden_root "test/support/fixtures/golden"
  @now_iso "2026-08-12T18:00:00Z"

  setup do
    Application.put_env(:kapelle, :product_clock, fn -> @now_iso end)
    on_exit(fn -> Application.delete_env(:kapelle, :product_clock) end)
    :ok
  end

  test "unknown loop is data, not an exception" do
    assert {:error, :not_found} = RunVerdict.for_loop("LOOP-NOPE")
  end

  test "happy run: product passes, harness reports the cost gap, cost and interventions are real" do
    loop_id = run_golden!("happy")

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)

    assert verdict.product == :pass

    # The claim this whole module exists for: a product pass does NOT buy
    # a harness pass while cost is un-instrumented.
    assert verdict.harness == :observability_gap

    assert [%{class: :cost_not_instrumented, severity: :gap, detail: :tokens}] =
             verdict.harness_findings

    cost = verdict.cost
    assert cost.iterations_used == 2
    assert cost.max_iterations == 2
    # Two iterations x (research, concept, apply) = six stage jobs.
    assert cost.stage_jobs == 6
    assert cost.attempts == 6
    assert cost.retries == 0
    assert cost.discarded_jobs == 0
    assert cost.artifact_revisions > 0
    assert is_integer(cost.wall_ms) and cost.wall_ms >= 0

    # Un-instrumented is nil with a reason — never a zero that reads as a
    # measurement.
    assert cost.tokens == nil
    assert cost.tokens_unavailable == :not_instrumented

    assert verdict.interventions == %{
             holds: 0,
             resumes: 0,
             resume_refs: [],
             waivers: 0,
             waiver_refs: []
           }
  end

  test "human_waiver run: the waiver is counted as a human intervention, with its artifact ref" do
    loop_id = run_golden!("human_waiver")

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)

    assert verdict.product == :pass
    assert verdict.interventions.waivers == 1
    assert verdict.interventions.waiver_refs == ["concept-draft://CD-002"]
    assert verdict.interventions.resumes == 0
    assert verdict.interventions.holds == 0
  end

  test "needs_human run: product is blocked, and the open hold counts as one intervention" do
    loop_id = run_golden!("needs_human")

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)

    assert verdict.product == :blocked
    assert verdict.product_reason =~ "max_iterations reached"
    assert verdict.interventions.holds == 1
    assert verdict.interventions.resumes == 0
    assert verdict.cost.iterations_used == 2
  end

  test "resumed run: the consumed decision is counted, and the hold it lifted with it" do
    loop_id = "LOOP-001"
    agent = install_golden_script!("resume", loop_id)

    start_loop!(loop_id, "resume", agent, 2)
    drain!()

    assert {:ok, %{decision_ref: "loop-resume-decision://LRD-001"}} =
             Kapelle.Product.Resume.consume(loop_id, [golden_decision!()])

    drain!()

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)

    assert verdict.product == :pass
    assert verdict.interventions.resumes == 1
    assert verdict.interventions.resume_refs == ["loop-resume-decision://LRD-001"]
    # The hold that decision lifted is history the lifecycle does not keep;
    # it is derived from the consumed decision, and the loop is no longer
    # held, so exactly one hold is reported.
    assert verdict.interventions.holds == 1
    assert verdict.cost.iterations_used == 3
  end

  test "invalid-artifact run: product fails, harness stays honest about what it can see" do
    loop_id = "LOOP-001"

    FixtureAgent.install_script!(loop_id, %{{:researcher, 0} => broken_rp!()})
    start_loop!(loop_id, "invalid_artifact", "fixture:" <> loop_id, 2)
    drain!()

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)

    assert verdict.product == :fail
    # Nothing was persisted and nothing was lost by the harness: the only
    # finding is the standing cost gap, NOT a durability failure. A
    # fail-closed refusal is the harness working, not breaking.
    assert verdict.harness == :observability_gap
    assert Enum.map(verdict.harness_findings, & &1.class) == [:cost_not_instrumented]
    # What cost counts here is the loop's own init evidence (idea + the
    # initial proposal snapshot, both written before any stage ran) — the
    # refused research pack is precisely what is NOT among them.
    assert verdict.cost.artifact_revisions == 2

    assert loop_id |> Store.all() |> Enum.map(& &1.kind) |> Enum.sort() ==
             [:idea, :product_proposal]

    # The refusal itself is visible as a fact, just not as damage.
    assert verdict.cost.cancelled_jobs == 1
    assert verdict.cost.discarded_jobs == 0
  end

  test "damaged evidence: the harness fails, the product axis says unknown, counts say nil" do
    loop_id = run_golden!("happy")

    # Tamper with a stored artifact's recorded hash the way a silent edit
    # would: the view re-hashes every row and fails closed on the mismatch.
    {1, _} =
      Repo.update_all(
        from(a in ArtifactRow,
          where: a.loop_id == ^loop_id and a.kind == "idea"
        ),
        set: [canonical_hash: String.duplicate("0", 64)]
      )

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)

    assert verdict.product == :unknown
    assert verdict.product_reason =~ "evidence unreadable"
    assert verdict.harness == :fail
    assert Enum.any?(verdict.harness_findings, &(&1.class == :evidence_unreadable))

    # Unknown is not zero — a half-counted tally would be worse than none.
    assert verdict.interventions.waivers == nil
    assert verdict.interventions.holds == nil
    assert verdict.cost.iterations_used == nil
  end

  # --- helpers ---

  defp run_golden!(scenario) do
    loop_id = "LOOP-001"
    agent = install_golden_script!(scenario, loop_id)
    start_loop!(loop_id, scenario, agent, 2)
    drain!()
    loop_id
  end

  defp start_loop!(loop_id, scenario, agent, max_iterations) do
    {:ok, _row} =
      Loop.start(File.read!(Path.join(workspace(scenario), "idea.yaml")),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: max_iterations,
        agent: agent,
        now_iso: @now_iso
      )
  end

  defp drain! do
    assert %{discard: 0, failure: 0} = Oban.drain_queue(queue: :product, with_recursion: true)
  end

  defp install_golden_script!(scenario, key) do
    script =
      Map.new(
        docs_for(scenario, "rp-*.yaml", :researcher) ++
          docs_for(scenario, "cd-*.yaml", :creator)
      )

    :ok = FixtureAgent.install_script!(key, script)
    "fixture:" <> key
  end

  defp docs_for(scenario, glob, role) do
    scenario
    |> workspace()
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.map(fn path ->
      {:ok, doc} = path |> File.read!() |> StrictParse.parse()
      {{role, doc["iteration"]}, doc}
    end)
  end

  defp golden_decision! do
    {:ok, doc} =
      "resume"
      |> workspace()
      |> Path.join("decisions/lrd-001.yaml")
      |> File.read!()
      |> StrictParse.parse()

    doc
  end

  # The producer's broken fixture, rebuilt the same way the invalid-artifact
  # parity test rebuilds it: a real golden research pack with its
  # `brief_for_creator` blanked.
  defp broken_rp! do
    {:ok, doc} =
      "needs_human"
      |> workspace()
      |> Path.join("rp-001.yaml")
      |> File.read!()
      |> StrictParse.parse()

    Map.put(doc, "brief_for_creator", "")
  end

  defp workspace(scenario), do: Path.join([@golden_root, scenario, "workspace"])
end
