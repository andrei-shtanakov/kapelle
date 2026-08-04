defmodule Kapelle.Evaluator.VerdictTest do
  use ExUnit.Case, async: true

  alias Kapelle.Evaluator.Verdict

  @valid_attrs %{decision_id: "dec-1", task_id: "task-1", total_score: 0.75}

  test "new!/1 builds a Verdict with default score_components" do
    assert %Verdict{
             decision_id: "dec-1",
             task_id: "task-1",
             total_score: 0.75,
             score_components: %{}
           } = Verdict.new!(@valid_attrs)
  end

  test "new!/1 keeps given score_components" do
    attrs = Map.put(@valid_attrs, :score_components, %{correctness: 1.0})

    assert %Verdict{score_components: %{correctness: 1.0}} = Verdict.new!(attrs)
  end

  test "new!/1 accepts an integer total_score" do
    attrs = Map.put(@valid_attrs, :total_score, 1)

    assert %Verdict{total_score: 1} = Verdict.new!(attrs)
  end

  test "new!/1 raises when a required key is missing" do
    attrs = Map.delete(@valid_attrs, :total_score)

    assert_raise ArgumentError, fn -> Verdict.new!(attrs) end
  end

  test "new!/1 raises when total_score is not a number" do
    attrs = Map.put(@valid_attrs, :total_score, "high")

    assert_raise ArgumentError, fn -> Verdict.new!(attrs) end
  end

  test "new!/1 raises ArgumentError (not KeyError) for an unknown attrs key" do
    attrs = Map.put(@valid_attrs, :bogus, "value")

    assert_raise ArgumentError, fn -> Verdict.new!(attrs) end
  end

  test "new!/1 raises when score_components is not a map" do
    for bad <- [nil, [], "components", 42] do
      attrs = Map.put(@valid_attrs, :score_components, bad)

      assert_raise ArgumentError, fn -> Verdict.new!(attrs) end
    end
  end
end
