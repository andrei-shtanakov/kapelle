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

  alias Kapelle.Product.{
    CanonicalHash,
    Contracts,
    FixtureAgent,
    Loop,
    Loops,
    Reconciler,
    Store,
    View
  }

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

  test "d) a stranded delta-apply v4 (round 1's ready snapshot never persisted) fails closed instead of claiming ready" do
    loop_id = start_loop!("LOOP-REC-D")
    run_round!(loop_id, 0)
    assert :ok = perform_job(EvaluateWorker, job_args(loop_id, "apply", 0))
    run_round!(loop_id, 1)

    # Simulate a crash between `EvaluateWorker`'s own `apply_delta` persist
    # and `maybe_finalize_ready`'s: build round 1's delta-apply snapshot
    # (v4, still "in_iteration") and its exchange-log entry by hand, via
    # the same store path the worker itself uses, but stop there — never
    # persist the v5 "ready_for_business" snapshot. `NextStage.compute/2`
    # still reads round 1's own rp/cd as fully resolved (RP-002's gap
    # closed, CD-002's assumption answered) and computes `{:terminal,
    # :ready, ...}` from the artifacts alone — the guard under test is
    # that repair refuses to trust that verdict against a proposal doc
    # that still says "in_iteration".
    {:ok, view} = View.build(loop_id)
    v3 = view.proposal

    v4 = %{
      v3
      | "version" => 4,
        "iteration" => 1,
        "content" =>
          Map.put(
            v3["content"],
            "delta_log",
            v3["content"]["delta_log"] ++
              [%{"iteration" => 1, "concept_draft" => "CD-002", "delta" => "delta 1"}]
          ),
        "refs" =>
          Map.merge(v3["refs"], %{
            "latest_research_pack" => "research-pack://RP-002",
            "latest_concept_draft" => "concept-draft://CD-002"
          }),
        "updated_at" => "2026-08-01T00:00:00Z"
    }

    assert :ok = StageShell.persist_document(:product_proposal, v4, loop_id)

    {:ok, view2} = View.build(loop_id)

    assert :ok =
             StageShell.append_exchange_entry(Loops.get!(loop_id), view2, %{
               "iteration" => 1,
               "actor" => "orchestration",
               "artifact_kind" => "product_proposal_patch",
               "artifact_ref" => "proposal://PP-001",
               "at" => "2026-08-01T00:00:00Z"
             })

    # (TASK-107 PR #25 review, C2) baseline right before the failing
    # reconcile, so "zero new artifact revisions written" — the claim
    # `fault_injection_matrix_test.exs`'s own moduledoc makes about this
    # test — is asserted here explicitly rather than merely implied.
    stored_before = Store.all(loop_id)

    assert {:error,
            {:projection_drift, %{expected: "ready_for_business", actual: "in_iteration"}}} =
             Reconciler.reconcile(loop_id)

    assert Loops.get!(loop_id).status == "failed"
    assert Store.all(loop_id) == stored_before
  end

  test "e) a config row with no persisted idea reconciles to a typed error instead of raising" do
    {:ok, _loop_row} =
      Loops.create(%{
        loop_id: "LOOP-REC-E",
        idea_identity: "IDEA-001",
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: "fixture:golden"
      })

    assert {:error, {:view_incomplete, :idea_missing}} = Reconciler.reconcile("LOOP-REC-E")
    assert Loops.get!("LOOP-REC-E").status == "failed"
  end
end
