defmodule Kapelle.Product.Workers.EvaluateWorkerTest do
  @moduledoc """
  `Kapelle.Product.Workers.EvaluateWorker` (design doc §5, Task 7): the
  apply stage over the shared `StageShell` — no agent call. Flips
  `draft -> in_iteration` on the very first apply, applies the round's
  delta, appends the exchange log's `"orchestration"` entry, then either
  continues (`enqueue research/i+1`) or reaches `ready` (one more
  proposal snapshot to `"ready_for_business"`, the loop's own status set
  to `"ready"`, no further job) — derived against the golden proposal
  chain's version arithmetic (v1 draft init -> v2 status flip -> v3/v4
  delta-applies for rounds 0/1 -> v5 ready).
  """

  use Kapelle.DataCase, async: true
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Product.{Contracts, FixtureAgent, Loop, Loops, Store}
  alias Kapelle.Product.Workers.{CreatorWorker, EvaluateWorker, ResearchWorker}

  defp idea_yaml do
    File.read!(Path.join(Contracts.dir!(:idea), "fixtures/valid/idea-001.yaml"))
  end

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

  # `Store.all/1` returns every revision of a multi-revision kind
  # (product_proposal/exchange_log); tests always want the latest one.
  defp latest(loop_id, kind) do
    loop_id |> Store.all() |> Enum.filter(&(&1.kind == kind)) |> Enum.max_by(& &1.revision)
  end

  defp proposal_doc(loop_id), do: latest(loop_id, :product_proposal).doc

  test "apply/0 flips draft -> in_iteration, records the round 0 delta, and continues to research/1" do
    loop_id = start_loop!("LOOP-EW1")
    run_round!(loop_id, 0)

    assert :ok = perform_job(EvaluateWorker, job_args(loop_id, "apply", 0))

    proposal = proposal_doc(loop_id)
    assert proposal["status"] == "in_iteration"
    assert proposal["version"] == 3
    assert proposal["iteration"] == 0

    assert [%{"iteration" => 0, "concept_draft" => "CD-001", "delta" => "delta 0"}] =
             proposal["content"]["delta_log"]

    assert proposal["refs"]["latest_research_pack"] == "research-pack://RP-001"
    assert proposal["refs"]["latest_concept_draft"] == "concept-draft://CD-001"

    xl_doc = latest(loop_id, :exchange_log).doc
    assert length(xl_doc["entries"]) == 3
    orchestration_entry = List.last(xl_doc["entries"])
    assert orchestration_entry["actor"] == "orchestration"
    assert orchestration_entry["artifact_kind"] == "product_proposal_patch"
    assert orchestration_entry["artifact_ref"] == "proposal://PP-001"

    assert_enqueued(
      worker: ResearchWorker,
      queue: :product,
      args: %{"loop_id" => loop_id, "iteration" => 1, "stage" => "research"}
    )

    assert Loops.get!(loop_id).status == "running"
  end

  test "apply/1 reaches ready: one more proposal snapshot, loop status ready, no further job enqueued" do
    loop_id = start_loop!("LOOP-EW2")
    run_round!(loop_id, 0)
    assert :ok = perform_job(EvaluateWorker, job_args(loop_id, "apply", 0))
    run_round!(loop_id, 1)

    jobs_before = all_enqueued() |> length()

    assert :ok = perform_job(EvaluateWorker, job_args(loop_id, "apply", 1))

    proposal = proposal_doc(loop_id)
    assert proposal["status"] == "ready_for_business"
    assert proposal["version"] == 5
    assert proposal["iteration"] == 1

    assert [
             %{"iteration" => 0, "concept_draft" => "CD-001", "delta" => "delta 0"},
             %{"iteration" => 1, "concept_draft" => "CD-002", "delta" => "delta 1"}
           ] = proposal["content"]["delta_log"]

    assert proposal["refs"]["latest_research_pack"] == "research-pack://RP-002"
    assert proposal["refs"]["latest_concept_draft"] == "concept-draft://CD-002"

    xl_doc = latest(loop_id, :exchange_log).doc
    assert length(xl_doc["entries"]) == 6

    loop = Loops.get!(loop_id)
    assert loop.status == "ready"
    assert loop.stop_reason =~ "no open critical"
    assert loop.latest_state["stop"]["verdict"] == "ready_for_business"
    assert loop.latest_state["stop"]["iteration"] == 1

    assert all_enqueued() |> length() == jobs_before
  end
end
