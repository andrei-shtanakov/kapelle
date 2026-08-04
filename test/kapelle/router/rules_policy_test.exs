defmodule Kapelle.Router.RulesPolicyTest do
  use ExUnit.Case, async: true

  alias Kapelle.Router.Decision
  alias Kapelle.Router.RulesPolicy

  @table [
    {%{id: "task-1", type: :code_gen}, %{provider: "anthropic", model: "claude-sonnet-5"}},
    {%{id: "task-2", type: :summarize}, %{provider: "anthropic", model: "claude-haiku-4-5"}},
    {%{id: "task-3", type: :general}, %{provider: "anthropic", model: "claude-sonnet-5"}}
  ]

  test "route/2 returns a Decision with the expected target for each known task shape" do
    for {task, expected_target} <- @table do
      assert {:ok, %Decision{} = decision} = RulesPolicy.route(task, [])
      assert decision.target == expected_target
      assert decision.task_id == task.id
    end
  end

  test "route/2 is deterministic: same task always yields the same target" do
    for {task, _expected_target} <- @table do
      {:ok, first} = RulesPolicy.route(task, [])
      {:ok, second} = RulesPolicy.route(task, [])

      assert first.target == second.target
      assert first.task_id == second.task_id
    end
  end

  test "route/2 returns a unique decision_id on every call" do
    task = %{id: "task-1", type: :code_gen}

    {:ok, first} = RulesPolicy.route(task, [])
    {:ok, second} = RulesPolicy.route(task, [])

    assert first.decision_id != second.decision_id
    assert {:ok, _} = Ecto.UUID.cast(first.decision_id)
    assert {:ok, _} = Ecto.UUID.cast(second.decision_id)
  end

  test "route/2 returns {:error, _} for an unknown task shape" do
    assert {:error, _reason} = RulesPolicy.route(%{id: "task-1", type: :unsupported}, [])
    assert {:error, _reason} = RulesPolicy.route(%{id: "task-1"}, [])
    assert {:error, _reason} = RulesPolicy.route(%{type: :code_gen}, [])
    assert {:error, _reason} = RulesPolicy.route(%{}, [])
  end

  test "RulesPolicy implements the Kapelle.Router.Policy behaviour" do
    assert Kapelle.Router.Policy in (RulesPolicy.module_info(:attributes)
                                     |> Keyword.get_values(:behaviour)
                                     |> List.flatten())
  end
end
