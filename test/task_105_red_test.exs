defmodule Kapelle.Task105RedTest do
  @moduledoc """
  RED test for TASK-105 (spec/m2-tasks.md): the needs-human hold path,
  walked end to end through the ordinary `product` queue worker contour
  (`Loop.start/2` + drained workers, never a direct `NextStage.compute/2`
  call), against a fixture agent scripted with a critical unresolved
  gap/assumption the concept draft never resolves — mirroring
  `test/kapelle/product/e2e_happy_test.exs`'s pattern for the other
  terminal branch.
  """

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Product.{Events, FixtureAgent, Loop, Loops, Reconciler, StrictParse, Store, View}

  @golden "test/support/fixtures/golden/needs_human"
  @now_iso "2026-08-12T18:00:00Z"

  setup do
    Application.put_env(:kapelle, :product_clock, fn -> @now_iso end)
    on_exit(fn -> Application.delete_env(:kapelle, :product_clock) end)
    :ok
  end

  defp idea_yaml, do: File.read!(Path.join(@golden, "workspace/idea.yaml"))

  # `FixtureAgent.script_from_golden!/0` is hardcoded to the happy-path
  # workspace; the needs-human scenario has no scripting helper of its
  # own yet, so the script is built by hand here from the same golden
  # workspace docs (`rp-*.yaml`/`cd-*.yaml`, each carrying a critical,
  # unresolved gap/assumption the paired concept draft never answers).
  defp needs_human_script! do
    script = Map.new(golden_docs("rp-*.yaml", :researcher) ++ golden_docs("cd-*.yaml", :creator))
    FixtureAgent.install_script!("needs_human", script)
    "fixture:needs_human"
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

  defp golden_stop do
    @golden
    |> Path.join("workspace/loop.state")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("stop")
  end

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

  test "a critical unresolved gap/assumption holds the loop at needs_human through the ordinary worker contour, with inspectable causal state, an empty queue, and an in_sync repeat reconcile" do
    loop_id = start_loop!("LOOP-TASK-105")

    assert %{discard: 0, failure: 0} = drain_product!()

    # The evaluator itself (StageShell/Loops), not a direct NextStage
    # call, moved the loop into the hold.
    loop = Loops.get!(loop_id)
    assert loop.status == "needs_human"
    assert loop.stop_reason == golden_stop()["reason"]

    # The causal artifacts behind the hold are inspectable through the
    # canonical View alone -- a person can see *why* without the DB.
    assert {:ok, view} = View.build(loop_id)

    assert [%{"blocks_approval" => true} = gap] = view.research_packs[1]["gaps"]
    assert gap["what"] == "critical gap"
    assert gap["closed"] != true

    assert [%{"blocks_approval" => true} = assumption] = view.concept_drafts[1]["assumptions"]
    assert assumption["text"] == "critical assumption"
    assert is_nil(assumption["answered_by"])
    assert is_nil(assumption["human_waiver"])

    # A hold, not a business approval: the proposal itself never reached
    # ready_for_business.
    assert view.proposal["status"] == "in_iteration"

    # No next job is enqueued once the loop holds.
    assert all_enqueued() == []

    # The domain observations agree with the golden needs-human oracle.
    observations = normalized_artifact_observations()
    assert length(observations) == 4
    stored = Store.all(loop_id)
    Enum.each(observations, &assert_observation_stored(&1, stored))

    # A repeated reconcile neither duplicates nor advances anything: two
    # calls in a row on the held loop both report `:in_sync`.
    :ok = Events.subscribe(loop_id)

    assert {:ok, :in_sync} = Reconciler.reconcile(loop_id)
    assert {:ok, :in_sync} = Reconciler.reconcile(loop_id)

    assert Store.all(loop_id) == stored
    assert all_enqueued() == []
    refute_receive _any_event, 100
  end
end
