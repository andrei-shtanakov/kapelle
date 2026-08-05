defmodule Kapelle.Orchestrator.PipelineTest do
  use Kapelle.DataCase, async: true
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Evaluator.Verdict
  alias Kapelle.Orchestrator.Pipeline
  alias Kapelle.Orchestrator.Records.Decision, as: DecisionRecord
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.Records.RunTask
  alias Kapelle.Orchestrator.Records.Verdict, as: VerdictRecord
  alias Kapelle.Orchestrator.Workers.RouteWorker
  alias Kapelle.Test.ExplodingJudge
  alias Kapelle.Test.StubPolicy

  test "run_sync/2 takes a submitted task through route -> execute -> evaluate to a Verdict" do
    task = %{id: "task-1", type: :code_gen}

    assert {:ok, %Verdict{} = verdict} = Pipeline.run_sync(task, [])

    assert verdict.task_id == "task-1"
    assert verdict.total_score == 1.0
    assert verdict.score_components != %{}
  end

  test "run_sync/2 produces a Verdict referencing the originating decision_id" do
    task = %{id: "task-2", type: :summarize}

    assert {:ok, %Verdict{} = verdict} = Pipeline.run_sync(task, policy: StubPolicy)

    assert verdict.decision_id == "11111111-1111-1111-1111-111111111111"
  end

  test "run_sync/2 with the default RulesPolicy still yields a valid decision_id" do
    task = %{id: "task-3", type: :general}

    assert {:ok, %Verdict{} = verdict} = Pipeline.run_sync(task, [])

    assert {:ok, _} = Ecto.UUID.cast(verdict.decision_id)
  end

  test "run_sync/2 derives the Verdict score from the executed Result's status" do
    task = %{id: "task-4", type: :code_gen, fake_result: %{status: :fail}}

    assert {:ok, %Verdict{} = verdict} = Pipeline.run_sync(task, [])
    assert verdict.total_score == 0.0
  end

  test "run_sync/2 propagates a routing error without executing or evaluating" do
    task = %{id: "task-5", type: :unsupported}

    assert {:error, _reason} = Pipeline.run_sync(task, [])
  end

  test "run_sync/2 propagates an execution error without evaluating" do
    task = %{id: "task-7", type: :code_gen, fake_result: {:error, :boom}}

    assert {:error, :boom} = Pipeline.run_sync(task, judge: ExplodingJudge)
  end

  # FakeAdapter and FakeJudge issue no HTTP/network calls of any kind, so a
  # successful run_sync/2 here proves the e2e path is network-free.
  test "run_sync/2 completes end-to-end with only fakes (zero network)" do
    task = %{id: "task-6", type: :code_gen}

    assert {:ok, %Verdict{}} = Pipeline.run_sync(task, [])
  end

  describe "submit/2" do
    test "returns {:ok, run_id} and persists a pending Run carrying the task payload" do
      task = %{id: "task-submit-1", type: :code_gen}

      assert {:ok, run_id} = Pipeline.submit(task, [])

      run = Repo.get!(Run, run_id)
      assert run.task_id == "task-submit-1"
      assert run.status == "pending"
      assert run.payload == %{"id" => "task-submit-1", "type" => "code_gen"}
    end

    test "enqueues a RouteWorker job carrying only run_id and OverrideRegistry keys" do
      task = %{id: "task-submit-2", type: :code_gen}

      assert {:ok, run_id} = Pipeline.submit(task, [])

      assert_enqueued(
        worker: RouteWorker,
        queue: :orchestrator,
        args: %{
          "run_id" => run_id,
          "policy" => "rules_policy",
          "adapter" => "fake_adapter",
          "judge" => "fake_judge"
        }
      )
    end

    test "resolves a :policy override to its OverrideRegistry key" do
      task = %{id: "task-submit-3", type: :code_gen}

      assert {:ok, run_id} = Pipeline.submit(task, policy: StubPolicy)

      assert_enqueued(worker: RouteWorker, args: %{"run_id" => run_id, "policy" => "stub_policy"})
    end

    test "resolves an :adapter override to its OverrideRegistry key" do
      task = %{id: "task-submit-3b", type: :code_gen}

      assert {:ok, run_id} = Pipeline.submit(task, adapter: Kapelle.Test.ExecuteAdapter)

      assert_enqueued(
        worker: RouteWorker,
        args: %{"run_id" => run_id, "adapter" => "execute_adapter"}
      )
    end

    test "resolves a :judge override to its OverrideRegistry key" do
      task = %{id: "task-submit-3c", type: :code_gen}

      assert {:ok, run_id} = Pipeline.submit(task, judge: Kapelle.Test.FailingJudge)

      assert_enqueued(
        worker: RouteWorker,
        args: %{"run_id" => run_id, "judge" => "failing_judge"}
      )
    end

    test "never invokes routing, execution, or evaluation synchronously" do
      task = %{id: "task-submit-4", type: :unsupported}

      assert {:ok, _run_id} = Pipeline.submit(task, [])

      refute Repo.get_by(DecisionRecord, task_id: "task-submit-4")
      refute Repo.get_by(RunTask, task_id: "task-submit-4")
      refute Repo.get_by(VerdictRecord, task_id: "task-submit-4")
      assert [%{worker: "Kapelle.Orchestrator.Workers.RouteWorker"}] = all_enqueued()
    end

    test "returns {:error, changeset} without enqueueing a job when the Run insert fails" do
      assert {:error, %Ecto.Changeset{valid?: false}} = Pipeline.submit(%{id: 123}, [])

      refute_enqueued(worker: RouteWorker)
    end
  end
end
