defmodule Kapelle.Product.Workers.CreatorWorkerTest do
  @moduledoc """
  `Kapelle.Product.Workers.CreatorWorker` (design doc §5, Task 7): the
  creator stage over the shared `StageShell` — rejects a stale
  research-pack reference *before* persisting anything (the producer's
  own check, loop.py:580), otherwise validates, persists the concept
  draft, appends its exchange-log entry, and enqueues the apply stage.
  """

  use Kapelle.DataCase, async: true
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Product.{CanonicalHash, Contracts, FixtureAgent, Loop, Loops, Store}
  alias Kapelle.Product.Workers.{CreatorWorker, EvaluateWorker, ResearchWorker}

  defp idea_yaml do
    File.read!(Path.join(Contracts.dir!(:idea), "fixtures/valid/idea-001.yaml"))
  end

  defp start_loop!(loop_id, agent) do
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

  defp job_args(loop_id, iteration) do
    %{"loop_id" => loop_id, "iteration" => iteration, "stage" => "concept", "input_hash" => "x"}
  end

  # `Store.all/1` returns every revision of a multi-revision kind
  # (exchange_log/product_proposal); tests always want the latest one.
  defp latest(stored, kind) do
    stored |> Enum.filter(&(&1.kind == kind)) |> Enum.max_by(& &1.revision)
  end

  test "performing concept/0 after research/0 persists CD-001, appends the log's 2nd entry, enqueues apply/0" do
    loop_id = start_loop!("LOOP-CW1", FixtureAgent.script_from_golden!())
    assert :ok = perform_job(ResearchWorker, %{job_args(loop_id, 0) | "stage" => "research"})

    assert :ok = perform_job(CreatorWorker, job_args(loop_id, 0))

    stored = Store.all(loop_id)

    assert %{kind: :concept_draft, id: "CD-001", revision: 0} =
             Enum.find(stored, &(&1.kind == :concept_draft))

    xl_doc = latest(stored, :exchange_log).doc
    assert length(xl_doc["entries"]) == 2
    [_researcher_entry, creator_entry] = xl_doc["entries"]
    assert creator_entry["actor"] == "creator"
    assert creator_entry["artifact_kind"] == "concept_draft"
    assert creator_entry["artifact_ref"] == "concept-draft://CD-001"

    cd_doc = Enum.find(stored, &(&1.kind == :concept_draft)).doc
    input_hash = CanonicalHash.hash(cd_doc)

    assert_enqueued(
      worker: EvaluateWorker,
      queue: :product,
      args: %{
        "loop_id" => loop_id,
        "iteration" => 0,
        "stage" => "apply",
        "input_hash" => input_hash
      }
    )
  end

  test "a stale research-pack reference is a domain failure — cancelled, loop marked failed, nothing persisted" do
    key = "creator-stale-#{System.unique_integer([:positive])}"

    rp = %{
      "id" => "RP-900",
      "idea_ref" => "idea://IDEA-001",
      "proposal_ref" => "proposal://PP-001",
      "iteration" => 0,
      "findings" => [],
      "constraints" => [],
      "gaps" => [],
      "brief_for_creator" => "brief",
      "requests_to_creator" => [],
      "produced_by" => %{
        "kind" => "agent",
        "id" => "researcher",
        "model" => "m",
        "prompt_version" => "v1"
      },
      "produced_at" => "2026-08-12T18:00:00Z"
    }

    stale_cd = %{
      "id" => "CD-900",
      "idea_ref" => "idea://IDEA-001",
      "proposal_ref" => "proposal://PP-001",
      "iteration" => 0,
      "based_on_research" => %{"ref" => "research-pack://RP-WRONG", "iteration" => 0},
      "value_prop" => "value",
      "alternatives" => [%{"direction" => "a", "summary" => "s"}],
      "chosen_direction" => %{"direction" => "a", "why" => "w"},
      "business_models" => ["m"],
      "assumptions" => [],
      "requests_to_researcher" => [],
      "proposal_delta" => "delta",
      "produced_by" => %{
        "kind" => "agent",
        "id" => "creator",
        "model" => "m",
        "prompt_version" => "v1"
      },
      "produced_at" => "2026-08-12T18:00:00Z"
    }

    :ok = FixtureAgent.install_script!(key, %{{:researcher, 0} => rp, {:creator, 0} => stale_cd})
    loop_id = start_loop!("LOOP-CW2", "fixture:#{key}")

    assert :ok = perform_job(ResearchWorker, %{job_args(loop_id, 0) | "stage" => "research"})

    assert {:cancel, {:stale_reference, _detail}} =
             perform_job(CreatorWorker, job_args(loop_id, 0))

    refute Enum.any?(Store.all(loop_id), &(&1.kind == :concept_draft))
    xl_doc = Enum.find(Store.all(loop_id), &(&1.kind == :exchange_log)).doc
    assert length(xl_doc["entries"]) == 1

    assert %{status: "failed"} = Loops.get!(loop_id)
    assert all_enqueued(worker: EvaluateWorker) == []
  end
end
