defmodule Kapelle.Task106RedTest do
  @moduledoc """
  RED test for TASK-106 (spec/m2-tasks.md): the resume-policy adapter
  that gives the TASK-105 `needs_human` hold its typed exit by consuming
  a valid, active `loop-resume-decision/v1` document — the vendored
  contract at `priv/contracts/impresario/loop-resume-decision/v1`
  (pinned to `impresario@8082e53`). Walks the exact same needs-human
  hold as `test/task_105_red_test.exs` (same golden fixtures, same
  `max_iterations: 2`), then presents a decision widening the budget to
  3 to the not-yet-existing `Kapelle.Product.Resume.consume/2`, which
  must atomically re-check the wait, widen the budget, clear the hold,
  enqueue the next stage, and record the resume under the decision's own
  ref.
  """

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Product.{CanonicalHash, FixtureAgent, Loop, Loops, Resume, Store, StrictParse}
  alias Kapelle.Product.Workers.ResearchWorker

  @golden "test/support/fixtures/golden/needs_human"
  @now_iso "2026-08-12T18:00:00Z"

  setup do
    Application.put_env(:kapelle, :product_clock, fn -> @now_iso end)
    on_exit(fn -> Application.delete_env(:kapelle, :product_clock) end)
    :ok
  end

  defp idea_yaml, do: File.read!(Path.join(@golden, "workspace/idea.yaml"))

  defp needs_human_script! do
    script = Map.new(golden_docs("rp-*.yaml", :researcher) ++ golden_docs("cd-*.yaml", :creator))
    FixtureAgent.install_script!("task_106_needs_human", script)
    "fixture:task_106_needs_human"
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

  defp start_loop!(loop_id) do
    agent = needs_human_script!()

    {:ok, _loop_row} =
      Loop.start(idea_yaml(),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: agent,
        now_iso: @now_iso
      )

    loop_id
  end

  defp drain_product!, do: Oban.drain_queue(queue: :product, with_recursion: true)

  # Producer-shaped decision (schema at
  # priv/contracts/impresario/loop-resume-decision/v1/schema.json,
  # mirroring the vendored fixtures/valid/lrd-001.yaml): subject matches
  # the held loop's own wait `(loop_id, iteration: 1)` — the golden
  # oracle's `workspace/loop.state` records the hold at iteration 1 — and
  # `new_max_iterations: 3` strictly widens the loop's current budget of 2.
  defp resume_decision(loop_id) do
    %{
      "decision_id" => "LRD-001",
      "subject" => %{"loop_id" => loop_id, "iteration" => 1},
      "new_max_iterations" => 3,
      "decided_by" => %{"kind" => "human", "id" => "andrei"},
      "decided_at" => "2026-08-13T09:00:00Z",
      "reason" => "owner resolved the blocking critical items"
    }
  end

  test "the resume adapter consumes a valid active decision: budget widened, hold cleared, next stage enqueued, resume recorded with the decision ref" do
    loop_id = "LOOP-106"
    start_loop!(loop_id)

    assert %{discard: 0, failure: 0} = drain_product!()
    assert Loops.get!(loop_id).status == "needs_human"

    decision = resume_decision(loop_id)

    assert {:ok, %{decision_ref: "loop-resume-decision://LRD-001", stage: {:research, 2}}} =
             Resume.consume(loop_id, [decision])

    loop = Loops.get!(loop_id)
    assert loop.max_iterations == 3
    assert loop.status == "running"

    assert_enqueued(
      worker: ResearchWorker,
      args: %{"loop_id" => loop_id, "iteration" => 2, "stage" => "research"}
    )

    stored =
      Enum.find(Store.all(loop_id), &(&1.kind == :loop_resume_decision and &1.id == "LRD-001"))

    assert stored, "no loop_resume_decision artifact stored in Store.all/1 for LRD-001"
    assert stored.canonical_hash == CanonicalHash.hash(decision)
  end
end
