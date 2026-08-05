defmodule Kapelle.Orchestrator.Workers.OverrideRegistryTest do
  use ExUnit.Case, async: false

  alias Kapelle.Evaluator.FakeJudge
  alias Kapelle.Executor.FakeAdapter
  alias Kapelle.Orchestrator.Workers.OverrideRegistry
  alias Kapelle.Router.RulesPolicy

  @base_table [
    {:policy, "rules_policy", RulesPolicy},
    {:adapter, "fake_adapter", FakeAdapter},
    {:judge, "fake_judge", FakeJudge}
  ]

  test "key_for/2 and resolve!/2 round-trip for each base kind" do
    for {kind, key, module} <- @base_table do
      assert OverrideRegistry.key_for(kind, module) == key
      assert OverrideRegistry.resolve!(kind, key) == module
    end
  end

  test "resolve!/2 raises a clear, descriptive error (not a bare KeyError) for an unknown key" do
    error =
      assert_raise ArgumentError, fn ->
        OverrideRegistry.resolve!(:policy, "does_not_exist")
      end

    assert error.message =~ "does_not_exist"
    assert error.message =~ "policy"
  end

  test "key_for/2 raises a clear, descriptive error for an unregistered module" do
    error =
      assert_raise ArgumentError, fn ->
        OverrideRegistry.key_for(:policy, Enum)
      end

    assert error.message =~ "Enum"
    assert error.message =~ "policy"
  end

  test "resolve!/2 raises a clear, descriptive error for an unknown kind" do
    error =
      assert_raise ArgumentError, fn ->
        OverrideRegistry.resolve!(:bogus, "rules_policy")
      end

    assert error.message =~ "bogus"
  end

  describe "test override merge" do
    setup do
      previous = Application.get_env(:kapelle, :orchestrator_overrides, %{})

      merged =
        Map.update(previous, :policy, %{"stub_policy" => Kapelle.Test.StubPolicy}, fn policies ->
          Map.put(policies, "stub_policy", Kapelle.Test.StubPolicy)
        end)

      Application.put_env(:kapelle, :orchestrator_overrides, merged)

      on_exit(fn ->
        Application.put_env(:kapelle, :orchestrator_overrides, previous)
      end)
    end

    test "resolve!/2 finds a registered test override" do
      assert OverrideRegistry.resolve!(:policy, "stub_policy") == Kapelle.Test.StubPolicy
    end

    test "key_for/2 finds a registered test override" do
      assert OverrideRegistry.key_for(:policy, Kapelle.Test.StubPolicy) == "stub_policy"
    end

    test "base entries remain resolvable alongside overrides" do
      assert OverrideRegistry.resolve!(:policy, "rules_policy") == RulesPolicy
      assert OverrideRegistry.resolve!(:adapter, "fake_adapter") == FakeAdapter
    end

    test "overrides for one kind do not leak into another kind" do
      assert_raise ArgumentError, fn ->
        OverrideRegistry.resolve!(:judge, "stub_policy")
      end
    end
  end

  test "an override reusing a base key's name shadows the base entry" do
    previous = Application.get_env(:kapelle, :orchestrator_overrides, %{})

    merged =
      Map.update(previous, :policy, %{"rules_policy" => Kapelle.Test.StubPolicy}, fn policies ->
        Map.put(policies, "rules_policy", Kapelle.Test.StubPolicy)
      end)

    Application.put_env(:kapelle, :orchestrator_overrides, merged)

    on_exit(fn ->
      Application.put_env(:kapelle, :orchestrator_overrides, previous)
    end)

    assert OverrideRegistry.resolve!(:policy, "rules_policy") == Kapelle.Test.StubPolicy
  end

  test "resolve!/2 with no orchestrator_overrides configured falls back to the base registry" do
    previous = Application.get_env(:kapelle, :orchestrator_overrides)
    Application.delete_env(:kapelle, :orchestrator_overrides)

    on_exit(fn ->
      if previous, do: Application.put_env(:kapelle, :orchestrator_overrides, previous)
    end)

    assert OverrideRegistry.resolve!(:policy, "rules_policy") == RulesPolicy
  end
end
