defmodule Kapelle.Router.DecisionTest do
  use ExUnit.Case, async: true

  alias Kapelle.Router.Decision

  @valid_attrs %{
    decision_id: "dec-1",
    task_id: "task-1",
    target: %{provider: "anthropic", model: "claude-sonnet-5"},
    decided_at: ~U[2026-08-04 12:00:00Z]
  }

  test "new!/1 builds a Decision with the given attrs and default features" do
    decision = Decision.new!(@valid_attrs)

    assert %Decision{
             decision_id: "dec-1",
             task_id: "task-1",
             target: %{provider: "anthropic", model: "claude-sonnet-5"},
             decided_at: ~U[2026-08-04 12:00:00Z],
             features: %{}
           } = decision
  end

  test "new!/1 keeps a given features map" do
    attrs = Map.put(@valid_attrs, :features, %{temperature: 0.2})

    assert %Decision{features: %{temperature: 0.2}} = Decision.new!(attrs)
  end

  test "new!/1 raises when a required key is missing" do
    attrs = Map.delete(@valid_attrs, :task_id)

    assert_raise ArgumentError, fn -> Decision.new!(attrs) end
  end

  test "new!/1 raises when target is not a provider/model map" do
    attrs = Map.put(@valid_attrs, :target, %{provider: "anthropic"})

    assert_raise ArgumentError, fn -> Decision.new!(attrs) end
  end

  test "new!/1 raises when target is not a map at all" do
    attrs = Map.put(@valid_attrs, :target, "anthropic/claude-sonnet-5")

    assert_raise ArgumentError, fn -> Decision.new!(attrs) end
  end

  test "new!/1 raises when target has extra keys" do
    attrs = Map.put(@valid_attrs, :target, %{provider: "anthropic", model: "x", extra: "y"})

    assert_raise ArgumentError, fn -> Decision.new!(attrs) end
  end

  test "new!/1 raises when provider or model is not a string" do
    attrs = Map.put(@valid_attrs, :target, %{provider: :anthropic, model: "x"})

    assert_raise ArgumentError, fn -> Decision.new!(attrs) end
  end

  test "new!/1 raises ArgumentError (not KeyError) for an unknown attrs key" do
    attrs = Map.put(@valid_attrs, :bogus, "value")

    assert_raise ArgumentError, fn -> Decision.new!(attrs) end
  end

  test "new!/1 raises when features is not a map" do
    for bad <- [nil, [], "features", 42] do
      attrs = Map.put(@valid_attrs, :features, bad)

      assert_raise ArgumentError, fn -> Decision.new!(attrs) end
    end
  end
end
