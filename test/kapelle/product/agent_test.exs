defmodule Kapelle.Product.AgentTest do
  @moduledoc """
  Contract for `Kapelle.Product.Agent`'s address resolution (design doc
  §Q-01/Q-02, DT-01): a total `resolve/1`, its `resolve!/1` wrapper, and
  the boundary of `fixture?/1` against the live scheme.

  BEH-01: a live address resolves through the same port into a callable
  implementation. BEH-03: an unknown scheme and a malformed address are a
  named failure, never a raised `FunctionClauseError`. BEH-20:
  `fixture?/1` does not widen onto the live scheme.
  """

  use ExUnit.Case, async: false

  alias Kapelle.Product.Agent
  alias Kapelle.Product.Agent.AddressError
  alias Kapelle.Product.FixtureAgent

  describe "Agent.resolve/1 — BEH-01: live address resolves like fixture:" do
    test "a well-formed model: address resolves to the configured live module and the catalog id as key" do
      assert {:ok, {Kapelle.Product.LiveAgent, "anthropic@claude-sonnet-5"}} =
               Agent.resolve("model:anthropic@claude-sonnet-5")
    end

    test "a catalog id with more than one '@' is passed through verbatim as the key" do
      assert {:ok, {Kapelle.Product.LiveAgent, "anthropic@claude@sonnet-5"}} =
               Agent.resolve("model:anthropic@claude@sonnet-5")
    end

    test "resolution reads the live module from config at call time, same {module, key} contract as fixture:" do
      previous = Application.get_env(:kapelle, :product_live_agent)
      Application.put_env(:kapelle, :product_live_agent, Kapelle.Test.ProductLiveAgentDouble)

      on_exit(fn ->
        if previous do
          Application.put_env(:kapelle, :product_live_agent, previous)
        else
          Application.delete_env(:kapelle, :product_live_agent)
        end
      end)

      assert {:ok, {Kapelle.Test.ProductLiveAgentDouble, "anthropic@claude-sonnet-5"}} =
               Agent.resolve("model:anthropic@claude-sonnet-5")

      assert {:ok, {FixtureAgent, "abc"}} = Agent.resolve("fixture:abc")
    end
  end

  describe "Agent.resolve/1 — BEH-03: unknown scheme and malformed address are named, not raised" do
    test "an unknown scheme before the live scheme existed is a named unknown_scheme error" do
      assert {:error, {:unknown_scheme, "provider:gpt-5"}} = Agent.resolve("provider:gpt-5")
    end

    test "an arbitrary string is a named unknown_scheme error" do
      assert {:error, {:unknown_scheme, "totally-not-an-address"}} =
               Agent.resolve("totally-not-an-address")
    end

    test "an empty key on a known scheme is a named malformed_address error" do
      assert {:error, {:malformed_address, "fixture:"}} = Agent.resolve("fixture:")
    end

    test "a missing separator on a known scheme is a named malformed_address error" do
      assert {:error, {:malformed_address, "fixture"}} = Agent.resolve("fixture")
    end

    test "the empty string is a named malformed_address error" do
      assert {:error, {:malformed_address, ""}} = Agent.resolve("")
    end

    test "an empty tail on the live scheme is a named malformed_address error" do
      assert {:error, {:malformed_address, "model:"}} = Agent.resolve("model:")
    end

    test "a live-scheme tail without the <provider>@<model> form is a named malformed_address error" do
      assert {:error, {:malformed_address, "model:anthropic"}} = Agent.resolve("model:anthropic")
    end

    test "a non-string address is a named malformed_address error, not a raise" do
      assert {:error, {:malformed_address, nil}} = Agent.resolve(nil)
      assert {:error, {:malformed_address, :fixture}} = Agent.resolve(:fixture)
    end

    test "unknown_scheme and malformed_address are distinguishable" do
      assert {:error, {:unknown_scheme, _}} = Agent.resolve("provider:gpt-5")
      assert {:error, {:malformed_address, _}} = Agent.resolve("fixture:")
      refute match?({:error, {:malformed_address, _}}, Agent.resolve("provider:gpt-5"))
      refute match?({:error, {:unknown_scheme, _}}, Agent.resolve("fixture:"))
    end

    test "resolve!/1 raises a readable AddressError instead of a FunctionClauseError" do
      assert_raise AddressError, ~r/unknown agent address scheme/, fn ->
        Agent.resolve!("provider:gpt-5")
      end

      assert_raise AddressError, ~r/malformed agent address/, fn ->
        Agent.resolve!("fixture:")
      end
    end

    test "resolve!/1 still returns the {module, key} pair for a well-formed address" do
      assert {FixtureAgent, "abc"} = Agent.resolve!("fixture:abc")
    end

    test "resolve!/1 raises a readable AddressError for a non-string address" do
      assert_raise AddressError, ~r/malformed agent address/, fn ->
        Agent.resolve!(nil)
      end
    end
  end

  describe "Agent.fixture?/1 — BEH-20: the predicate does not widen onto the live scheme" do
    test "a well-formed live address is not a fixture address" do
      refute Agent.fixture?("model:anthropic@claude-sonnet-5")
    end

    test "a well-formed fixture address is still true, exactly as before" do
      assert Agent.fixture?("fixture:abc")
    end

    test "a malformed fixture: address (same string resolve/1 rejects) is not a fixture address" do
      refute Agent.fixture?("fixture:")
    end

    test "an unknown-scheme address is not a fixture address" do
      refute Agent.fixture?("provider:gpt-5")
    end

    test "a non-string address is not a fixture address" do
      refute Agent.fixture?(nil)
    end
  end
end
