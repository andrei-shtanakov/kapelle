defmodule Kapelle.Product.E2eHappyTest do
  @moduledoc """
  The S3 exit gate (Task 8): `Loop.start/2` against the golden workspace's
  own idea, scripted through `FixtureAgent.script_from_golden!()`, drained
  end to end through the real `product` queue workers — no manual job
  args, no shortcuts — then judged against the golden oracle three ways:
  every `artifact_written` observation's hash, the proposal chain's own
  status-flip sequence, and the final proposal document's canonical hash.

  Timestamps are the one sanctioned divergence the plan anticipated
  (`Kapelle.Product.Workers.StageShell.now_iso/0`'s moduledoc): every
  timestamp in the golden fixture happens to be the same fixed instant
  (`2026-08-12T18:00:00Z`), so pinning `now_iso` to it for the whole run
  (both `Loop.start/2`'s own opt and the workers' shared clock) reaches
  full canonical-hash equality — no field-exclusion fallback needed.
  """

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Product.{CanonicalHash, Events, FixtureAgent, Loader, Loop, Loops, Store, View}
  alias Kapelle.Product.Workers.ResearchWorker

  @golden "test/support/fixtures/golden/happy"
  @now_iso "2026-08-12T18:00:00Z"

  setup do
    Application.put_env(:kapelle, :product_clock, fn -> @now_iso end)
    on_exit(fn -> Application.delete_env(:kapelle, :product_clock) end)
    :ok
  end

  defp idea_yaml, do: File.read!(Path.join(@golden, "workspace/idea.yaml"))

  defp start_golden_loop!(loop_id) do
    script = FixtureAgent.script_from_golden!()

    {:ok, _loop_row} =
      Loop.start(idea_yaml(),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: script,
        now_iso: @now_iso
      )

    loop_id
  end

  test "Loop.start + drained product queue reaches ready_for_business and matches the golden oracle" do
    loop_id = start_golden_loop!("LOOP-001")

    assert %{discard: 0, failure: 0} = drain_product!()

    loop = Loops.get!(loop_id)
    assert loop.status == "ready"

    assert {:ok, view} = View.build(loop_id)
    stored = Store.all(loop_id)

    # (1) every golden artifact_written observation has a matching Store
    # row (kind, identity) with an EQUAL canonical hash.
    observations = normalized_artifact_observations()
    assert length(observations) == 4
    Enum.each(observations, &assert_observation_stored(&1, stored))

    # (2) our proposal chain's (from, to, version) status-flip pairs equal
    # the golden trace's own transition observations exactly. Delta bumps
    # (v3 round-0 apply, v4 round-1 apply) are not transitions — filtered
    # to actual status changes.
    assert status_flips(view.proposal_chain) == golden_transitions()

    # (3) final proposal doc equals the golden workspace's proposal.yaml
    # by canonical hash.
    {:ok, golden_proposal} =
      Loader.load(:product_proposal, File.read!(Path.join(@golden, "workspace/proposal.yaml")))

    assert CanonicalHash.hash(view.proposal) == CanonicalHash.hash(golden_proposal.doc)

    # Bonus (beyond the plan's three required checks, same fixed-clock
    # guarantee): the final exchange log is also byte-identical to the
    # golden's — six entries (two rounds x three actors, correction 2).
    {:ok, golden_xlog} =
      Loader.load(:exchange_log, File.read!(Path.join(@golden, "workspace/exchange-log.yaml")))

    assert length(view.exchange_log["entries"]) == 6
    assert CanonicalHash.hash(view.exchange_log) == CanonicalHash.hash(golden_xlog.doc)
  end

  test "crash/retry no-dup: re-performing an already-completed stage job does nothing new" do
    loop_id = start_golden_loop!("LOOP-002")
    assert %{discard: 0, failure: 0} = drain_product!()
    assert Loops.get!(loop_id).status == "ready"

    stored_before = Store.all(loop_id)
    jobs_before = all_enqueued()
    :ok = Events.subscribe(loop_id)

    # The loop is terminal, so re-performing ANY of its already-completed
    # stage jobs (research/0 here) hits `StageShell.run/2`'s very first
    # guard clause — the crash/retry exit gate the moduledoc describes.
    assert :ok =
             perform_job(ResearchWorker, %{
               "loop_id" => loop_id,
               "iteration" => 0,
               "stage" => "research",
               "input_hash" => "stale-replay"
             })

    assert Store.all(loop_id) == stored_before
    assert all_enqueued() == jobs_before
    refute_receive _any_event, 100
  end

  defp drain_product!, do: Oban.drain_queue(queue: :product, with_recursion: true)

  defp normalized_artifact_observations do
    @golden
    |> Path.join("normalized.json")
    |> File.read!()
    |> Jason.decode!()
    |> Enum.filter(&Map.has_key?(&1, "artifact_hash"))
  end

  defp assert_observation_stored(observation, stored) do
    kind = String.to_existing_atom(observation["artifact_kind"])
    identity = observation["artifact_ref"] |> String.split("://") |> List.last()

    row = Enum.find(stored, &(&1.kind == kind and &1.id == identity))

    assert row, "no artifact stored in Store.all/1 for #{observation["artifact_ref"]}"
    assert row.canonical_hash == observation["artifact_hash"]
  end

  defp status_flips(chain) do
    chain
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [a, b] -> a["status"] != b["status"] end)
    |> Enum.map(fn [a, b] -> {a["status"], b["status"], b["version"]} end)
  end

  defp golden_transitions do
    @golden
    |> Path.join("raw-trace.jsonl")
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["event"] == "transition"))
    |> Enum.map(&{&1["from"], &1["to"], &1["proposal_version"]})
  end
end
