defmodule Kapelle.Product.Workers.ResearchWorkerTest do
  @moduledoc """
  `Kapelle.Product.Workers.ResearchWorker` (design doc §5, Task 7): the
  researcher stage over the shared `StageShell` — produce, validate,
  persist the research pack, append the exchange-log's first entry (the
  log is born here, controller's ruling 2026-08-14), then enqueue the
  creator stage for the same iteration.
  """

  use Kapelle.DataCase, async: true
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Product.{
    CanonicalHash,
    Contracts,
    Event,
    Events,
    FixtureAgent,
    Loop,
    Loops,
    Store
  }

  alias Kapelle.Product.Workers.{CreatorWorker, ResearchWorker}

  defp idea_yaml do
    File.read!(Path.join(Contracts.dir!(:idea), "fixtures/valid/idea-001.yaml"))
  end

  # `proposal_id: "PP-001"`/`exchange_log_id: "XL-001"` matches the
  # golden workspace's own baked-in refs (rp-001.yaml/cd-001.yaml name
  # `proposal://PP-001`) — required for `View`'s reference checks to
  # agree once the golden-scripted docs are persisted under this loop.
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

  defp job_args(loop_id, iteration) do
    %{"loop_id" => loop_id, "iteration" => iteration, "stage" => "research", "input_hash" => "x"}
  end

  test "performing research/0 persists RP-001, appends the log's first entry, enqueues concept/0" do
    loop_id = start_loop!("LOOP-RW1")

    assert :ok = perform_job(ResearchWorker, job_args(loop_id, 0))

    stored = Store.all(loop_id)

    assert %{kind: :research_pack, id: "RP-001", revision: 0} =
             Enum.find(stored, &(&1.kind == :research_pack))

    assert %{kind: :exchange_log, id: "XL-001", revision: 1} =
             Enum.find(stored, &(&1.kind == :exchange_log))

    xl_doc = Enum.find(stored, &(&1.kind == :exchange_log)).doc

    assert [
             %{"iteration" => 0, "actor" => "researcher", "artifact_kind" => "research_pack"} =
               entry
           ] =
             xl_doc["entries"]

    assert entry["artifact_ref"] == "research-pack://RP-001"
    assert is_binary(entry["at"])

    rp_doc = Enum.find(stored, &(&1.kind == :research_pack)).doc
    input_hash = CanonicalHash.hash(rp_doc)

    assert_enqueued(
      worker: CreatorWorker,
      queue: :product,
      args: %{
        "loop_id" => loop_id,
        "iteration" => 0,
        "stage" => "concept",
        "input_hash" => input_hash
      }
    )

    assert Loops.get!(loop_id).status == "running"
  end

  test "a stale replay after the loop already advanced is a no-op — no new artifacts, no new jobs" do
    loop_id = start_loop!("LOOP-RW2")

    assert :ok = perform_job(ResearchWorker, job_args(loop_id, 0))
    before = Store.all(loop_id) |> Enum.map(&{&1.kind, &1.id, &1.revision}) |> Enum.sort()
    jobs_before = all_enqueued() |> length()

    :ok = Events.subscribe(loop_id)

    # The research/0 job replays after concept/0 has already been
    # enqueued (Oban's `unique` only dedups scheduled/available/
    # executing, never `completed` — spec §8's crash/retry exit gate).
    assert :ok = perform_job(ResearchWorker, job_args(loop_id, 0))

    after_replay = Store.all(loop_id) |> Enum.map(&{&1.kind, &1.id, &1.revision}) |> Enum.sort()
    assert after_replay == before
    assert all_enqueued() |> length() == jobs_before
    refute_receive %Event{}, 200
  end
end
