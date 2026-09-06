defmodule Mix.Tasks.Kapelle.Product.ReportTest do
  @moduledoc """
  The rendering half of "cost and interventions are visible per run"
  (design doc §9.3): what an operator actually reads. Driven by a real
  golden run rather than a hand-built struct, so the block under test is
  the one a real loop produces.
  """

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

  import Ecto.Query, only: [from: 2]

  alias Kapelle.Product.{FixtureAgent, Loop, RunVerdict, StrictParse}
  alias Mix.Tasks.Kapelle.Product.Report

  @workspace "test/support/fixtures/golden/human_waiver/workspace"
  @now_iso "2026-08-12T18:00:00Z"

  setup do
    Application.put_env(:kapelle, :product_clock, fn -> @now_iso end)
    on_exit(fn -> Application.delete_env(:kapelle, :product_clock) end)
    :ok
  end

  test "the printed block keeps the axes apart and refuses to print a measured-looking zero" do
    loop_id = run_waiver_loop!()

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)
    output = Report.format(verdict)

    # Two axes, two lines — never one rolled-up verdict.
    assert output =~ "product: pass"
    assert output =~ "harness: pass"

    # The note is printed even though it costs the axis nothing: an
    # operator must be able to see that no provider was ever called.
    assert output =~ "cost_not_applicable (info)"

    # An inapplicable cost says so instead of printing 0.
    assert output =~ "tokens:             not applicable (fixture-backed agents)"
    refute output =~ "tokens:             0"

    # The human act that carried this loop is named, not just counted.
    assert output =~ "waivers:            1 (concept-draft://CD-002)"
    assert output =~ "iterations:         2 / 2"
  end

  test "the three token states read differently: not applicable, a measured zero, a lost figure" do
    # Hand-built on purpose: two of the three states cannot occur until a
    # real provider adapter exists (#50), and the distinction between them
    # is exactly what must not rot in the meantime. `n/a` is not `0`, and
    # neither is a figure the provider owed us and never sent.
    assert Report.format(verdict_with_tokens(nil, :not_applicable)) =~
             "tokens:             not applicable (fixture-backed agents)"

    assert Report.format(verdict_with_tokens(0, nil)) =~ "tokens:             0"

    assert Report.format(verdict_with_tokens(nil, :not_instrumented)) =~
             "tokens:             not instrumented"
  end

  test "a stuck run is legible in the block: the executing row and its orphan status are printed" do
    loop_id = run_waiver_loop!()
    strand_job!(loop_id)

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)
    output = Report.format(verdict)

    # Both facts the verdict computes about in-flight work reach the reader:
    # without them a stalled run and a finished one print the same cost block.
    assert output =~ "executing:          1"
    assert output =~ "orphaned:           1"
    assert output =~ "jobs_orphaned (fail)"
  end

  test "the task mutes Oban before booting: looking at a loop cannot run it" do
    config = Application.fetch_env!(:kapelle, Oban)
    read_only = Report.read_only_oban(config)

    # No queue can pick this loop's jobs up, no plugin can move them — the
    # read-only promise `RunVerdict` makes survives its own CLI wrapper.
    assert read_only[:queues] == false
    assert read_only[:plugins] == false
    assert read_only[:repo] == config[:repo]
  end

  # One of the loop's jobs left in `executing` long enough to be orphaned —
  # what a crashed node leaves behind with no Lifeline configured.
  defp strand_job!(loop_id) do
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
        set: [
          state: "executing",
          attempted_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -2 * 60 * 60),
          completed_at: nil
        ]
      )
  end

  defp run_waiver_loop! do
    loop_id = "LOOP-001"

    script =
      Map.new(docs_for("rp-*.yaml", :researcher) ++ docs_for("cd-*.yaml", :creator))

    :ok = FixtureAgent.install_script!(loop_id, script)

    {:ok, _row} =
      Loop.start(File.read!(Path.join(@workspace, "idea.yaml")),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: "fixture:" <> loop_id,
        now_iso: @now_iso
      )

    assert %{discard: 0, failure: 0} = Oban.drain_queue(queue: :product, with_recursion: true)

    loop_id
  end

  defp docs_for(glob, role) do
    @workspace
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.map(fn path ->
      {:ok, doc} = path |> File.read!() |> StrictParse.parse()
      {{role, doc["iteration"]}, doc}
    end)
  end

  defp verdict_with_tokens(tokens, unavailable) do
    %RunVerdict{
      loop_id: "LOOP-FMT",
      product: :pass,
      product_reason: "rendering fixture",
      harness: :pass,
      harness_findings: [],
      cost: %{
        iterations_used: 1,
        max_iterations: 2,
        stage_jobs: 3,
        attempts: 3,
        retries: 0,
        discarded_jobs: 0,
        cancelled_jobs: 0,
        executing_jobs: 0,
        orphaned_jobs: 0,
        artifact_revisions: 4,
        wall_ms: 10,
        tokens: tokens,
        tokens_unavailable: unavailable
      },
      interventions: %{holds: 0, resumes: 0, resume_refs: [], waivers: 0, waiver_refs: []}
    }
  end
end
