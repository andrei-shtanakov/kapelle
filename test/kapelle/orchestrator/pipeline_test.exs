defmodule Kapelle.Orchestrator.PipelineTest do
  use ExUnit.Case, async: true

  alias Kapelle.Evaluator.Verdict
  alias Kapelle.Orchestrator.Pipeline
  alias Kapelle.Router.Decision

  defmodule StubPolicy do
    @moduledoc false
    @behaviour Kapelle.Router.Policy

    @impl true
    def route(%{id: task_id}, _opts) do
      {:ok,
       Decision.new!(%{
         decision_id: "stub-decision-id",
         task_id: task_id,
         target: %{provider: "anthropic", model: "claude-sonnet-5"},
         decided_at: DateTime.utc_now()
       })}
    end
  end

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

    assert verdict.decision_id == "stub-decision-id"
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

  defmodule ExplodingJudge do
    @moduledoc false
    @behaviour Kapelle.Evaluator.Judge

    @impl true
    def evaluate(_task, _result), do: raise("evaluate/2 must not be called")
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
end
