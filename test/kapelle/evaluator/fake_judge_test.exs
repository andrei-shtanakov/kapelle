defmodule Kapelle.Evaluator.FakeJudgeTest do
  use ExUnit.Case, async: true

  alias Kapelle.Evaluator.FakeJudge
  alias Kapelle.Evaluator.Verdict
  alias Kapelle.Executor.Result

  @table [
    {:pass, 1.0},
    {:fail, 0.0},
    {:error, 0.0}
  ]

  test "evaluate/2 derives total_score from Result.status" do
    for {status, expected_score} <- @table do
      result = Result.new!(%{task_id: "task-1", status: status})
      task = %{id: "task-1", decision_id: "decision-1"}

      assert {:ok, %Verdict{} = verdict} = FakeJudge.evaluate(task, result)
      assert verdict.total_score == expected_score
    end
  end

  test "evaluate/2 returns a Verdict referencing task[:decision_id] and the Result's task_id" do
    result = Result.new!(%{task_id: "task-1", status: :pass})
    task = %{id: "task-1", decision_id: "decision-1"}

    assert {:ok, %Verdict{} = verdict} = FakeJudge.evaluate(task, result)
    assert verdict.decision_id == "decision-1"
    assert verdict.task_id == "task-1"
  end

  test "evaluate/2 returns non-empty score_components" do
    result = Result.new!(%{task_id: "task-1", status: :pass})
    task = %{id: "task-1", decision_id: "decision-1"}

    assert {:ok, %Verdict{score_components: components}} = FakeJudge.evaluate(task, result)
    assert map_size(components) > 0
  end

  test "FakeJudge implements the Kapelle.Evaluator.Judge behaviour" do
    assert Kapelle.Evaluator.Judge in (FakeJudge.module_info(:attributes)
                                       |> Keyword.get_values(:behaviour)
                                       |> List.flatten())
  end
end
