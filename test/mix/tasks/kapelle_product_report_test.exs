defmodule Mix.Tasks.Kapelle.Product.ReportTest do
  @moduledoc """
  The rendering half of "cost and interventions are visible per run"
  (design doc §9.3): what an operator actually reads. Driven by a real
  golden run rather than a hand-built struct, so the block under test is
  the one a real loop produces.
  """

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

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
    assert output =~ "harness: observability_gap"
    assert output =~ "cost_not_instrumented (gap)"

    # The un-instrumented cost says so instead of printing 0.
    assert output =~ "tokens:             not instrumented"
    refute output =~ "tokens:             0"

    # The human act that carried this loop is named, not just counted.
    assert output =~ "waivers:            1 (concept-draft://CD-002)"
    assert output =~ "iterations:         2 / 2"
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
end
