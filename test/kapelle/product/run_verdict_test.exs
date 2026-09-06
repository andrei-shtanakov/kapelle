defmodule Kapelle.Product.RunVerdictTest do
  @moduledoc """
  The two-axis verdict (design doc §1, exit §9.3) over real loops driven
  through the real contour — every case here is one of the committed
  golden scenarios replayed by `FixtureAgent`, so the product axis is
  judged against runs the parity suite already proves agree with the
  reference runner.

  The load-bearing claim is that the axes do not collapse: a loop whose
  evidence is damaged reports the damage even though its product result
  was recorded, and a fail-closed refusal is a product failure with a
  clean harness.

  Cost carries the other half of that discipline. With fixture-backed
  agents no provider is ever called, so an absent token figure is
  *evidence* — `:cost_not_applicable`, severity `:info` — and not a
  defect: it is recorded in the findings and does not lower the harness
  axis (owner ruling 2026-09-06). A provider that is called but whose
  usage never arrives is the other thing entirely, and stays reserved for
  `:cost_not_instrumented`/`:gap` when real adapters land (#50).
  """

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

  import Ecto.Query, only: [from: 2]

  alias Kapelle.Product.{FixtureAgent, Loop, Loops, Reconciler, RunVerdict, Store, StrictParse}
  alias Kapelle.Product.Records.{ArtifactRow, LoopRow}

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

  test "the axis mapping never rounds a gap up to a pass, and never over a failure" do
    # No producer emits `:gap` until real adapters land (#50), so the
    # contract is guarded here rather than through a run: without this, a
    # `cond` "simplified" to :fail/:pass — or with its branches swapped —
    # would keep every suite green while the two-axis type lies.
    gap = %{class: :cost_not_instrumented, severity: :gap, detail: :tokens}
    failure = %{class: :jobs_orphaned, severity: :fail, detail: 1}
    note = %{class: :cost_not_applicable, severity: :info, detail: :no_provider_call}

    assert RunVerdict.harness_axis([gap]) == :observability_gap

    # Order matters: a lone gap catches a deleted branch, not a branch
    # moved ahead of :fail. A failure outranks a gap in either arrangement.
    assert RunVerdict.harness_axis([gap, failure]) == :fail
    assert RunVerdict.harness_axis([failure, gap]) == :fail

    # And the note that M3 actually produces stays weightless.
    assert RunVerdict.harness_axis([note]) == :pass
    assert RunVerdict.harness_axis([]) == :pass
  end

  test "happy run: both axes pass, the absent token figure is evidence, cost and interventions are real" do
    loop_id = run_golden!("happy")

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)

    assert verdict.product == :pass

    # A finding of severity :info is evidence, not a defect: it is
    # reported AND the axis still passes. That pairing is the whole point
    # — dropping the finding would hide that no provider was ever called.
    assert verdict.harness == :pass

    assert [%{class: :cost_not_applicable, severity: :info, detail: :no_provider_call}] =
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

    # Not applicable is nil with a reason — never a zero that reads as a
    # measurement of a call that never happened.
    assert cost.tokens == nil
    assert cost.tokens_unavailable == :not_applicable

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
    # finding is the not-applicable cost note, NOT a durability failure. A
    # fail-closed refusal is the harness working, not breaking.
    assert verdict.harness == :pass
    assert Enum.map(verdict.harness_findings, & &1.class) == [:cost_not_applicable]
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

  test "a lifecycle failure that is not the domain's fault is charged to the harness" do
    loop_id = "LOOP-STRANDED"

    # Exactly the crash window StageShell documents: the config row exists,
    # `Loop.start/2` died before the idea was ever written, and an ordinary
    # Reconciler sweep is what finds the stranded loop.
    {:ok, _row} =
      Loops.create(%{
        loop_id: loop_id,
        idea_identity: "IDEA-001",
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: "fixture:golden"
      })

    assert {:error, {:view_incomplete, :idea_missing}} = Reconciler.reconcile(loop_id)
    assert Loops.get!(loop_id).status == "failed"

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)

    # Nothing was ever produced or judged: reporting `product: :fail` here
    # would blame the proposal for a durability failure — the one confusion
    # the two axes exist to prevent. Compare with the invalid-artifact case
    # above, whose `failed` IS the domain's own refusal.
    assert verdict.product == :unknown
    assert verdict.product_reason =~ "lifecycle failed off the domain"
    assert verdict.harness == :fail
    assert Enum.any?(verdict.harness_findings, &(&1.class == :lifecycle_failed_off_domain))
  end

  test "an orphaned executing job is a harness failure, not a loop still working" do
    loop_id = run_golden!("happy")

    # A raw BEAM crash mid-`perform/1` leaves the row in `executing`
    # forever: this app configures no Lifeline, and StageShell's own
    # contract says so. Model exactly that — an old `executing` row under a
    # loop whose lifecycle never got its terminal write.
    strand_job!(loop_id, minutes_ago(120))
    reopen_loop!(loop_id, NaiveDateTime.utc_now())

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)

    assert verdict.harness == :fail
    assert Enum.any?(verdict.harness_findings, &(&1.class == :jobs_orphaned))
    assert verdict.cost.orphaned_jobs == 1
    assert verdict.cost.executing_jobs == 1

    # The stuck row costs the harness its axis and nothing else: the
    # artifacts already decided the domain verdict.
    assert verdict.product == :pass
  end

  test "a job that started moments ago is in flight, and reads as such" do
    loop_id = run_golden!("happy")

    strand_job!(loop_id, NaiveDateTime.utc_now())
    reopen_loop!(loop_id, NaiveDateTime.utc_now())

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)

    # Nothing is wrong yet: the row is young, so no orphan finding — and no
    # stall finding either, because something IS executing.
    assert verdict.harness == :pass
    assert Enum.map(verdict.harness_findings, & &1.class) == [:cost_not_applicable]
    assert verdict.cost.executing_jobs == 1
    assert verdict.cost.orphaned_jobs == 0
    assert verdict.product == :pass
  end

  test "a running loop with nothing left to run at all is stalled — once it has sat there" do
    loop_id = run_golden!("happy")
    reopen_loop!(loop_id, minutes_ago(10))

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)

    # Every job is completed, the walk is terminal, and the lifecycle never
    # recorded it — the result exists in the evidence and no one wrote it down.
    assert verdict.harness == :fail
    assert Enum.any?(verdict.harness_findings, &(&1.class == :terminal_not_recorded))

    # And the produced result is still reported as produced: one
    # infrastructure fault must cost one axis, not both. Judging product by
    # the lifecycle write would demote a finished proposal to "open" for a
    # crash that happened after it was already durable.
    assert verdict.product == :pass
    assert verdict.product_reason =~ "not recorded in the lifecycle"
  end

  test "a loop that has only just been touched is a live window, not a stall" do
    loop_id = run_golden!("happy")
    reopen_loop!(loop_id, NaiveDateTime.utc_now())

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)

    # Same shape as the stall above — running, nothing runnable — but
    # seconds old. `Loop.start/2` is not transactional and this module's
    # own reads are not one snapshot, so this shape occurs in the ordinary
    # course of progress; calling it a durability failure would make the
    # loudest finding here the one it cries most often.
    assert verdict.harness == :pass
    assert Enum.map(verdict.harness_findings, & &1.class) == [:cost_not_applicable]
  end

  test "a loop still being started, with no jobs yet, is not accused of stalling" do
    loop_id = "LOOP-STARTING"

    # The window `Loop.start/2` genuinely has: the config row is written
    # before the idea and before the first job is ever enqueued.
    {:ok, _row} =
      Loops.create(%{
        loop_id: loop_id,
        idea_identity: "IDEA-001",
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: "fixture:golden"
      })

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)

    assert verdict.harness == :pass
    assert verdict.product == :open
  end

  # --- helpers ---

  defp minutes_ago(minutes), do: NaiveDateTime.add(NaiveDateTime.utc_now(), -minutes * 60)

  # Puts one of the loop's completed jobs back into `executing` as of
  # `attempted_at`, the state a crashed node leaves behind.
  defp strand_job!(loop_id, attempted_at) do
    job =
      Repo.one!(
        from(j in Oban.Job,
          where: fragment("? ->> 'loop_id' = ?", j.args, ^loop_id),
          order_by: [asc: j.id],
          limit: 1
        )
      )

    {1, _} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: "executing", attempted_at: attempted_at, completed_at: nil]
      )
  end

  # Puts the loop back to `running` as of `updated_at` — the lifecycle
  # state a crash leaves, with its own age, since age is what separates a
  # stalled loop from one that is simply mid-progress.
  defp reopen_loop!(loop_id, updated_at) do
    {1, _} =
      Repo.update_all(from(l in LoopRow, where: l.loop_id == ^loop_id),
        set: [status: "running", stop_reason: nil, updated_at: updated_at]
      )
  end

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
