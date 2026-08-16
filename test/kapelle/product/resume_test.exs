defmodule Kapelle.Product.ResumeTest do
  @moduledoc """
  `Kapelle.Product.Resume` (spec/m2-tasks.md TASK-106): the resume-policy
  adapter that gives a TASK-105 `needs_human` hold its typed exit by
  consuming a presented `loop-resume-decision/v1` document. Covers the
  parts of the checklist the frozen `test/task_106_red_test.exs` doesn't:
  idempotency, the refusal matrix, the superseded-chain resolution rule,
  and the golden-oracle parity flip (TASK-105's hold assertion, flipped
  to a resume assertion).

  Every test walks the same needs-human hold as `test/task_105_red_test.exs`
  and `test/task_106_red_test.exs` — same golden fixtures, same
  `max_iterations: 2`, held at iteration 1 — so a valid decision always
  widens to at least 3. No test performs network I/O or invokes a live
  producer: the agent is `Kapelle.Product.FixtureAgent`, scripted from
  the vendored golden workspace.
  """

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Product.{
    Events,
    FixtureAgent,
    Loop,
    Loops,
    Reconciler,
    Resume,
    Store,
    StrictParse
  }

  alias Kapelle.Product.Workers.ResearchWorker

  @golden "test/support/fixtures/golden/needs_human"
  @now_iso "2026-08-12T18:00:00Z"

  setup do
    Application.put_env(:kapelle, :product_clock, fn -> @now_iso end)
    on_exit(fn -> Application.delete_env(:kapelle, :product_clock) end)
    :ok
  end

  defp idea_yaml, do: File.read!(Path.join(@golden, "workspace/idea.yaml"))

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

  defp needs_human_script!(key) do
    script = Map.new(golden_docs("rp-*.yaml", :researcher) ++ golden_docs("cd-*.yaml", :creator))
    FixtureAgent.install_script!(key, script)
    "fixture:" <> key
  end

  defp start_held_loop!(loop_id) do
    agent = needs_human_script!(loop_id)

    {:ok, _loop_row} =
      Loop.start(idea_yaml(),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: agent,
        now_iso: @now_iso
      )

    assert %{discard: 0, failure: 0} = Oban.drain_queue(queue: :product, with_recursion: true)
    assert Loops.get!(loop_id).status == "needs_human"

    loop_id
  end

  # Subject matches the held loop's own wait `(loop_id, iteration: 1)`
  # (same golden oracle every test in this file shares) unless overridden.
  defp decision(loop_id, decision_id, overrides \\ %{}) do
    Map.merge(
      %{
        "decision_id" => decision_id,
        "subject" => %{"loop_id" => loop_id, "iteration" => 1},
        "new_max_iterations" => 3,
        "decided_by" => %{"kind" => "human", "id" => "andrei"},
        "decided_at" => "2026-08-13T09:00:00Z",
        "reason" => "owner resolved the blocking critical items"
      },
      overrides
    )
  end

  defp enqueued_count, do: all_enqueued() |> length()

  defp assert_hold_intact(loop_id, jobs_before) do
    assert Loops.get!(loop_id).status == "needs_human"
    assert enqueued_count() == jobs_before
  end

  describe "idempotency" do
    test "re-presenting the consumed decision is a no-op; a second reconcile reports in_sync" do
      loop_id = start_held_loop!("LOOP-601")
      d = decision(loop_id, "LRD-001")

      assert {:ok, %{decision_ref: ref, stage: {:research, 2}} = first} =
               Resume.consume(loop_id, [d])

      assert ref == "loop-resume-decision://LRD-001"

      stored_before = Store.all(loop_id)
      jobs_before = enqueued_count()

      :ok = Events.subscribe(loop_id)
      assert {:ok, ^first} = Resume.consume(loop_id, [d])
      refute_receive _any_event, 100

      assert Store.all(loop_id) == stored_before
      assert enqueued_count() == jobs_before

      assert {:ok, :in_sync} = Reconciler.reconcile(loop_id)
      assert {:ok, :in_sync} = Reconciler.reconcile(loop_id)
      assert enqueued_count() == jobs_before
    end
  end

  describe "refusal matrix" do
    test "no decision presented" do
      loop_id = start_held_loop!("LOOP-602")
      jobs_before = enqueued_count()

      assert {:error, :no_decision} = Resume.consume(loop_id, [])
      assert_hold_intact(loop_id, jobs_before)
    end

    test "schema-invalid decision" do
      loop_id = start_held_loop!("LOOP-603")
      jobs_before = enqueued_count()

      invalid = decision(loop_id, "LRD-001", %{"reason" => ""})

      assert {:error, {:invalid_decision, _reason}} = Resume.consume(loop_id, [invalid])
      assert_hold_intact(loop_id, jobs_before)
    end

    test "foreign subject" do
      loop_id = start_held_loop!("LOOP-604")
      jobs_before = enqueued_count()

      foreign =
        decision(loop_id, "LRD-001", %{"subject" => %{"loop_id" => loop_id, "iteration" => 99}})

      assert {:error, {:foreign_subject, %{"iteration" => 99}}} =
               Resume.consume(loop_id, [foreign])

      assert_hold_intact(loop_id, jobs_before)
    end

    test "non-widening budget" do
      loop_id = start_held_loop!("LOOP-605")
      jobs_before = enqueued_count()

      not_wider = decision(loop_id, "LRD-001", %{"new_max_iterations" => 2})

      assert {:error, {:non_widening_budget, %{current: 2, requested: 2}}} =
               Resume.consume(loop_id, [not_wider])

      assert_hold_intact(loop_id, jobs_before)
    end

    test "a superseded decision is never consumed as a fallback for its failing successor" do
      loop_id = start_held_loop!("LOOP-606")
      jobs_before = enqueued_count()

      # LRD-001 alone would satisfy every check (right subject, widens the
      # budget). LRD-002 supersedes it under the same subject (an
      # admissible edge) but itself fails to widen the budget. The whole
      # call refuses on LRD-002's own failure — LRD-001 is never
      # reconsidered just because its successor turned out bad.
      original = decision(loop_id, "LRD-001", %{"new_max_iterations" => 3})

      successor =
        decision(loop_id, "LRD-002", %{
          "new_max_iterations" => 2,
          "supersedes" => "loop-resume-decision://LRD-001"
        })

      assert {:error, {:non_widening_budget, %{requested: 2}}} =
               Resume.consume(loop_id, [original, successor])

      assert_hold_intact(loop_id, jobs_before)
      refute Enum.any?(Store.all(loop_id), &(&1.kind == :loop_resume_decision))
    end

    test "self-referential supersedes" do
      loop_id = start_held_loop!("LOOP-607")
      jobs_before = enqueued_count()

      self_loop =
        decision(loop_id, "LRD-001", %{"supersedes" => "loop-resume-decision://LRD-001"})

      assert {:error, {:inadmissible_supersedes, :self_loop, "LRD-001"}} =
               Resume.consume(loop_id, [self_loop])

      assert_hold_intact(loop_id, jobs_before)
    end

    test "cyclic supersedes" do
      loop_id = start_held_loop!("LOOP-608")
      jobs_before = enqueued_count()

      a = decision(loop_id, "LRD-001", %{"supersedes" => "loop-resume-decision://LRD-002"})
      b = decision(loop_id, "LRD-002", %{"supersedes" => "loop-resume-decision://LRD-001"})

      assert {:error, {:inadmissible_supersedes, :cycle}} = Resume.consume(loop_id, [a, b])
      assert_hold_intact(loop_id, jobs_before)
    end

    test "more than one active decision" do
      loop_id = start_held_loop!("LOOP-609")
      jobs_before = enqueued_count()

      a = decision(loop_id, "LRD-001")
      b = decision(loop_id, "LRD-002")

      assert {:error, {:multiple_active_decisions, ids}} = Resume.consume(loop_id, [a, b])
      assert Enum.sort(ids) == ["LRD-001", "LRD-002"]
      assert_hold_intact(loop_id, jobs_before)
    end
  end

  test "a superseded chain (LRD-001 <- LRD-002) consumes the successor, never the superseded original" do
    loop_id = start_held_loop!("LOOP-610")

    original = decision(loop_id, "LRD-001", %{"new_max_iterations" => 3})

    successor =
      decision(loop_id, "LRD-002", %{
        "new_max_iterations" => 4,
        "supersedes" => "loop-resume-decision://LRD-001"
      })

    assert {:ok, %{decision_ref: "loop-resume-decision://LRD-002", stage: {:research, 2}}} =
             Resume.consume(loop_id, [original, successor])

    assert Loops.get!(loop_id).max_iterations == 4
    assert Loops.get!(loop_id).status == "running"

    stored = Store.all(loop_id)
    assert Enum.find(stored, &(&1.kind == :loop_resume_decision and &1.id == "LRD-002"))
    refute Enum.find(stored, &(&1.kind == :loop_resume_decision and &1.id == "LRD-001"))

    assert_enqueued(
      worker: ResearchWorker,
      args: %{"loop_id" => loop_id, "iteration" => 2, "stage" => "research"}
    )
  end

  test "the resume case's domain observations agree with the golden needs-human oracle, and the hold flips to running" do
    loop_id = start_held_loop!("LOOP-611")

    observations =
      @golden
      |> Path.join("normalized.json")
      |> File.read!()
      |> Jason.decode!()
      |> Enum.filter(&Map.has_key?(&1, "artifact_hash"))

    stored_before_resume = Store.all(loop_id)
    assert length(observations) == 4

    Enum.each(observations, fn observation ->
      kind = String.to_existing_atom(observation["artifact_kind"])
      identity = observation["artifact_ref"] |> String.split("://") |> List.last()

      row = Enum.find(stored_before_resume, &(&1.kind == kind and &1.id == identity))
      assert row, "no artifact stored in Store.all/1 for #{observation["artifact_ref"]}"
      assert row.canonical_hash == observation["artifact_hash"]
    end)

    # TASK-105's own parity assertion is `loop.status == "needs_human"`;
    # here it flips to "running" once the presented decision is consumed.
    assert {:ok, %{stage: {:research, 2}}} =
             Resume.consume(loop_id, [decision(loop_id, "LRD-001")])

    assert Loops.get!(loop_id).status == "running"

    # The artifacts the golden oracle asserts on are untouched by resume.
    Enum.each(observations, fn observation ->
      kind = String.to_existing_atom(observation["artifact_kind"])
      identity = observation["artifact_ref"] |> String.split("://") |> List.last()

      row = Enum.find(Store.all(loop_id), &(&1.kind == kind and &1.id == identity))
      assert row.canonical_hash == observation["artifact_hash"]
    end)
  end
end
