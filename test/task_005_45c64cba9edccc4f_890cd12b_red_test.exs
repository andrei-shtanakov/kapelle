defmodule Task00545c64cba9edccc4f890cd12bRedTest do
  @moduledoc false

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Product.{FixtureAgent, Loop, RunVerdict, StrictParse}
  alias Mix.Tasks.Kapelle.Product.Report

  @workspace "test/support/fixtures/golden/happy/workspace"
  @now_iso "2026-08-12T18:00:00Z"

  setup do
    Application.put_env(:kapelle, :product_clock, fn -> @now_iso end)
    on_exit(fn -> Application.delete_env(:kapelle, :product_clock) end)
    :ok
  end

  test "the printed report names the run's agent address (BEH-22)" do
    loop_id = "LOOP-TASK005"
    agent = "fixture:" <> loop_id

    script = Map.new(docs_for("rp-*.yaml", :researcher) ++ docs_for("cd-*.yaml", :creator))
    :ok = FixtureAgent.install_script!(loop_id, script)

    {:ok, _row} =
      Loop.start(File.read!(Path.join(@workspace, "idea.yaml")),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: agent,
        now_iso: @now_iso
      )

    assert %{discard: 0, failure: 0} = Oban.drain_queue(queue: :product, with_recursion: true)

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)
    output = Report.format(verdict)

    assert output =~ agent
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
