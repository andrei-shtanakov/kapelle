defmodule Kapelle.Router.OutcomeTest do
  use ExUnit.Case, async: true

  alias Kapelle.Evaluator.Verdict
  alias Kapelle.Router.Outcome

  @valid_attrs %{
    decision_id: "dec-1",
    task_id: "task-1",
    type: :success
  }

  test "new!/1 builds an Outcome with the given attrs" do
    assert %Outcome{decision_id: "dec-1", task_id: "task-1", type: :success} =
             Outcome.new!(@valid_attrs)
  end

  test "new!/1 accepts type :failure" do
    attrs = Map.put(@valid_attrs, :type, :failure)

    assert %Outcome{type: :failure} = Outcome.new!(attrs)
  end

  test "new!/1 raises when a required key is missing" do
    attrs = Map.delete(@valid_attrs, :task_id)

    assert_raise ArgumentError, fn -> Outcome.new!(attrs) end
  end

  test "new!/1 raises ArgumentError (not KeyError) for an unknown attrs key" do
    attrs = Map.put(@valid_attrs, :bogus, "value")

    assert_raise ArgumentError, fn -> Outcome.new!(attrs) end
  end

  test "new!/1 raises when type is not :success or :failure" do
    attrs = Map.put(@valid_attrs, :type, :maybe)

    assert_raise ArgumentError, fn -> Outcome.new!(attrs) end
  end

  describe "from_verdict/1" do
    test "derives type :success from a positive total_score" do
      verdict =
        Verdict.new!(%{decision_id: "dec-1", task_id: "task-1", total_score: 1.0})

      assert %Outcome{decision_id: "dec-1", task_id: "task-1", type: :success} =
               Outcome.from_verdict(verdict)
    end

    test "derives type :failure from a zero total_score" do
      verdict =
        Verdict.new!(%{decision_id: "dec-1", task_id: "task-1", total_score: 0.0})

      assert %Outcome{type: :failure} = Outcome.from_verdict(verdict)
    end

    test "carries decision_id and task_id over verbatim from the verdict" do
      verdict =
        Verdict.new!(%{decision_id: "dec-2", task_id: "task-2", total_score: 0.5})

      outcome = Outcome.from_verdict(verdict)

      assert outcome.decision_id == "dec-2"
      assert outcome.task_id == "task-2"
    end
  end
end
