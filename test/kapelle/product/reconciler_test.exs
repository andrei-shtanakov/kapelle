defmodule Kapelle.Product.ReconcilerTest do
  @moduledoc """
  `Kapelle.Product.Reconciler` (design doc §5, Task 8): re-derives a
  loop's stage from its own stored artifacts and repairs whatever has
  drifted — a stale/missing projection row, and/or a next-stage job that
  was never actually enqueued (the crash-after-authoritative-commit
  case: the durable boundary order guarantees the artifact landed before
  any enqueue, so a crash between those two steps leaves exactly this
  gap). Pure repair: a healthy loop's second `reconcile/1` call is
  `:in_sync`, not a duplicate anything.
  """

  use Kapelle.DataCase, async: true
  use Oban.Testing, repo: Kapelle.Repo

  import Ecto.Query, only: [from: 2]

  alias Kapelle.Product.{CanonicalHash, Contracts, FixtureAgent, Loop, Loops, Reconciler}
  alias Kapelle.Product.Records.LoopRow
  alias Kapelle.Product.Workers.{CreatorWorker, EvaluateWorker, ResearchWorker, StageShell}

  defp idea_yaml do
    File.read!(Path.join(Contracts.dir!(:idea), "fixtures/valid/idea-001.yaml"))
  end

  # `proposal_id: "PP-001"`/`exchange_log_id: "XL-001"` matches the golden
  # workspace's own baked-in refs, same convention as the Task 7 worker
  # tests — required for `View`'s reference checks to agree once the
  # golden-scripted docs are persisted under this loop.
  defp start_loop!(loop_id) do
    agent = FixtureAgent.script_from_golden!()

    {:ok, _loop_row} =
      Loop.start(idea_yaml(),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: agent,
        now_iso: "2026-08-01T00:00:00Z"
      )

    loop_id
  end

  defp job_args(loop_id, stage, iteration) do
    %{"loop_id" => loop_id, "iteration" => iteration, "stage" => stage, "input_hash" => "x"}
  end

  defp run_round!(loop_id, iteration) do
    assert :ok = perform_job(ResearchWorker, job_args(loop_id, "research", iteration))
    assert :ok = perform_job(CreatorWorker, job_args(loop_id, "concept", iteration))
  end

  defp corrupt_latest_state!(loop_id) do
    {1, _} =
      Repo.update_all(from(l in LoopRow, where: l.loop_id == ^loop_id), set: [latest_state: nil])

    :ok
  end

  test "a) a deleted projection row is repaired byte-identically to what the artifacts imply" do
    loop_id = start_loop!("LOOP-REC-A")
    run_round!(loop_id, 0)
    assert :ok = perform_job(EvaluateWorker, job_args(loop_id, "apply", 0))

    original_projection = Loops.get!(loop_id).latest_state
    assert is_map(original_projection)

    corrupt_latest_state!(loop_id)
    assert Loops.get!(loop_id).latest_state == nil

    assert {:ok, :repaired} = Reconciler.reconcile(loop_id)
    assert Loops.get!(loop_id).latest_state == original_projection
  end

  test "b) an authoritative commit stranded without its enqueue is repaired by enqueueing exactly the missing job; a second reconcile is in_sync" do
    loop_id = start_loop!("LOOP-REC-B")

    # Crash-after-authoritative-commit: persist RP-001 via the worker's
    # own store path (`StageShell.persist_document/3`, identical to what
    # `ResearchWorker.execute/3` calls) without ever running the worker
    # itself — so the exchange-log append and the creator enqueue that
    # would normally follow never happened.
    {:ok, rp_doc} = FixtureAgent.produce(:researcher, 0, %{key: "golden"})
    assert :ok = StageShell.persist_document(:research_pack, rp_doc, loop_id)

    refute_enqueued(worker: CreatorWorker, queue: :product)

    expected_input_hash = CanonicalHash.hash(rp_doc)

    assert {:ok, :repaired} = Reconciler.reconcile(loop_id)

    assert_enqueued(
      worker: CreatorWorker,
      queue: :product,
      args: %{
        "loop_id" => loop_id,
        "iteration" => 0,
        "stage" => "concept",
        "input_hash" => expected_input_hash
      }
    )

    creator_jobs_before = all_enqueued(worker: CreatorWorker) |> length()
    assert {:ok, :in_sync} = Reconciler.reconcile(loop_id)
    assert all_enqueued(worker: CreatorWorker) |> length() == creator_jobs_before
  end

  test "c) a terminal loop reconciles to :terminal and enqueues nothing" do
    loop_id = start_loop!("LOOP-REC-C")
    run_round!(loop_id, 0)
    assert :ok = perform_job(EvaluateWorker, job_args(loop_id, "apply", 0))
    run_round!(loop_id, 1)
    assert :ok = perform_job(EvaluateWorker, job_args(loop_id, "apply", 1))

    assert Loops.get!(loop_id).status == "ready"

    jobs_before = all_enqueued() |> length()
    assert {:ok, :terminal} = Reconciler.reconcile(loop_id)
    assert all_enqueued() |> length() == jobs_before
  end
end
