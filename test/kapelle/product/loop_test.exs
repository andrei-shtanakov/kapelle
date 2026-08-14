defmodule Kapelle.Product.LoopTest do
  @moduledoc """
  `Kapelle.Product.Loop.start/2` — the port of the producer's `init_loop`
  (design doc §5, Task 6): idea document -> idea + proposal v1 artifacts
  + loop config/projection + one enqueued research job. No exchange-log
  snapshot is written at init (controller's ruling, 2026-08-14): the
  pinned producer's own `init_loop` writes no log file either — it is
  born at the first `_append_exchange`, already carrying one entry.
  """

  use Kapelle.DataCase, async: true
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Product.{CanonicalHash, Contracts, Loops, Store}
  alias Kapelle.Product.Loop
  alias Kapelle.Product.Workers.ResearchWorker

  defp idea_yaml(fixture) do
    File.read!(Path.join(Contracts.dir!(:idea), "fixtures/#{fixture}"))
  end

  defp opts(loop_id) do
    [
      loop_id: loop_id,
      proposal_id: "PP-101",
      exchange_log_id: "XL-101",
      max_iterations: 2,
      agent: "fixture:golden",
      now_iso: "2026-08-01T00:00:00Z"
    ]
  end

  test "start/2 persists idea + proposal v1 + projection and enqueues exactly one research/0 job — no exchange-log at init" do
    loop_id = "LOOP-101"

    assert {:ok, loop_row} = Loop.start(idea_yaml("valid/idea-001.yaml"), opts(loop_id))

    assert loop_row.loop_id == loop_id
    assert loop_row.status == "running"

    stored = Store.all(loop_id)
    assert %{kind: :idea, id: "IDEA-001"} = Enum.find(stored, &(&1.kind == :idea))

    assert %{kind: :product_proposal, id: "PP-101", revision: 1} =
             Enum.find(stored, &(&1.kind == :product_proposal))

    assert Enum.sort(Enum.map(stored, & &1.kind)) == [:idea, :product_proposal]

    idea_doc = Enum.find(stored, &(&1.kind == :idea)).doc

    loop = Loops.get!(loop_id)
    assert loop.max_iterations == 2
    assert loop.agent == "fixture:golden"
    assert loop.latest_state["idea_input_hash"] == CanonicalHash.hash(idea_doc)
    assert loop.latest_state["stop"] == nil

    input_hash = CanonicalHash.hash(idea_doc)

    assert_enqueued(
      worker: ResearchWorker,
      queue: :product,
      args: %{
        "loop_id" => loop_id,
        "iteration" => 0,
        "stage" => "research",
        "input_hash" => input_hash
      }
    )

    assert [_single_job] = all_enqueued(worker: ResearchWorker)
  end

  test "start/2 on an already-initialized loop_id refuses without duplicating artifacts or jobs" do
    loop_id = "LOOP-102"
    assert {:ok, _} = Loop.start(idea_yaml("valid/idea-001.yaml"), opts(loop_id))

    assert {:error, :already_initialized} =
             Loop.start(idea_yaml("valid/idea-001.yaml"), opts(loop_id))

    assert [_single_job] = all_enqueued(worker: ResearchWorker)
  end

  test "start/2 with an invalid idea returns a typed error and persists nothing" do
    loop_id = "LOOP-103"

    assert {:error, {:invalid_artifact, :idea, _errors}} =
             Loop.start(idea_yaml("invalid/missing-hypothesis.yaml"), opts(loop_id))

    assert Store.all(loop_id) == []
    assert_raise Ecto.NoResultsError, fn -> Loops.get!(loop_id) end
    assert all_enqueued(worker: ResearchWorker) == []
  end
end
