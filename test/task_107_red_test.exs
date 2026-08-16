defmodule Kapelle.Task107RedTest do
  @moduledoc """
  RED test for TASK-107 (spec/m2-tasks.md): the evaluate/apply tear the
  task makes non-optional — `EvaluateWorker.execute/3` persists its own
  `apply_delta` proposal snapshot (a durable, authoritative write) and
  only then calls `StageShell.append_exchange_entry/3` for the
  `"orchestration"` entry; a crash landing between those two persists
  leaves the proposal's `delta_log` carrying the round while the
  exchange log has no matching entry for it. `StageShell`'s own
  moduledoc records this window as currently UNDETECTED by `View` (no
  chain rule fires on a missing orchestration entry, unlike the
  `:missing_researcher_entry` rule that already covers the
  researcher/creator tear) and NOT healed by `heal_missing_exchange_entries/1`
  (which only derives entries from `:research_pack`/`:concept_draft`
  rows, never from a proposal's own `delta_log`) — so today this tear
  reconciles silently to `:repaired`/`:in_sync` with a permanently
  incomplete exchange log instead of ever surfacing.

  The task decides this must be healed the same way the research/concept
  tear already is: the missing `"orchestration"` entry is mechanically
  re-derivable from the proposal's own `delta_log` entry for the round
  (`iteration`, the delta's own `concept_draft` id), so a repair should
  reconstruct it — mirroring `heal_missing_exchange_entries/1`'s
  existing researcher/creator heal instead of leaving the log
  incomplete forever. This test injects exactly that tear through the
  ordinary contour (workers for research/creator, a hand-simulated
  `apply_delta`-only persist for the tear itself — no direct
  `NextStage` call) and asserts the decided behavior: after
  `Kapelle.Product.Reconciler.reconcile/1`, the exchange log carries the
  healed orchestration entry for the round, so a rebuilt view's log is
  no longer silently short of what the uncrashed worker would have
  produced.
  """

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Product.{FixtureAgent, Loop, Reconciler, View}
  alias Kapelle.Product.Workers.{CreatorWorker, ResearchWorker, StageShell}

  @golden "test/support/fixtures/golden/happy"
  @now_iso "2026-08-12T18:00:00Z"

  setup do
    Application.put_env(:kapelle, :product_clock, fn -> @now_iso end)
    on_exit(fn -> Application.delete_env(:kapelle, :product_clock) end)
    :ok
  end

  defp job_args(loop_id, stage, iteration) do
    %{"loop_id" => loop_id, "iteration" => iteration, "stage" => stage, "input_hash" => "x"}
  end

  defp start_loop!(loop_id) do
    script = FixtureAgent.script_from_golden!()

    {:ok, _loop_row} =
      Loop.start(File.read!(Path.join(@golden, "workspace/idea.yaml")),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: script,
        now_iso: @now_iso
      )

    loop_id
  end

  # Mirrors `EvaluateWorker.execute/3`'s own first two persists
  # (`maybe_flip_to_in_iteration/3` + `apply_delta/6`) byte-for-byte,
  # then stops exactly where a real crash would: never reaching its own
  # `StageShell.append_exchange_entry/3` call for the round's
  # `"orchestration"` entry. This is the durable-boundary tear itself,
  # injected through the same store path the worker uses — not a direct
  # `NextStage` call.
  defp simulate_apply_delta_tear!(loop_id, iteration) do
    {:ok, view} = View.build(loop_id)
    rp = view.research_packs[iteration]
    cd = view.concept_drafts[iteration]

    flipped = %{
      view.proposal
      | "status" => "in_iteration",
        "version" => view.proposal["version"] + 1,
        "updated_at" => @now_iso
    }

    assert :ok = StageShell.persist_document(:product_proposal, flipped, loop_id)

    delta_log = get_in(flipped, ["content", "delta_log"]) || []

    entry = %{
      "iteration" => iteration,
      "concept_draft" => cd["id"],
      "delta" => cd["proposal_delta"]
    }

    applied = %{
      flipped
      | "version" => flipped["version"] + 1,
        "iteration" => iteration,
        "content" => Map.put(flipped["content"] || %{}, "delta_log", delta_log ++ [entry]),
        "refs" =>
          Map.merge(flipped["refs"], %{
            "latest_research_pack" => "research-pack://" <> rp["id"],
            "latest_concept_draft" => "concept-draft://" <> cd["id"]
          }),
        "updated_at" => @now_iso
    }

    assert :ok = StageShell.persist_document(:product_proposal, applied, loop_id)
  end

  test "the evaluate/apply tear (proposal delta persisted, orchestration exchange entry lost) heals the missing entry on reconcile" do
    loop_id = start_loop!("LOOP-107-EVAL-TEAR")

    assert :ok = perform_job(ResearchWorker, job_args(loop_id, "research", 0))
    assert :ok = perform_job(CreatorWorker, job_args(loop_id, "concept", 0))

    simulate_apply_delta_tear!(loop_id, 0)

    assert {:ok, view_before} = View.build(loop_id)

    refute Enum.any?(
             view_before.exchange_log["entries"],
             &(&1["iteration"] == 0 and &1["actor"] == "orchestration")
           ),
           "test setup invariant broken: the orchestration entry must be absent before repair"

    assert {:ok, _} = Reconciler.reconcile(loop_id)

    assert {:ok, view_after} = View.build(loop_id)

    healed_entry =
      Enum.find(
        view_after.exchange_log["entries"],
        &(&1["iteration"] == 0 and &1["actor"] == "orchestration")
      )

    assert healed_entry,
           "expected the evaluate/apply tear to heal the missing orchestration exchange " <>
             "entry (derivable from the proposal's own delta_log), but reconcile left the " <>
             "exchange log silently incomplete"

    assert healed_entry["artifact_kind"] == "product_proposal_patch"
    assert healed_entry["artifact_ref"] == "proposal://PP-001"
  end
end
