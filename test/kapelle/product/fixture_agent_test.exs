defmodule Kapelle.Product.FixtureAgentTest do
  @moduledoc """
  `Kapelle.Product.Agent` port (design doc §4, Task 5): the resolve!/1
  address scheme and the test-only, persistent_term-scripted FixtureAgent
  it resolves to.
  """

  use ExUnit.Case, async: true

  alias Kapelle.Product.{Agent, FixtureAgent}

  defp unique_key, do: "test-#{System.unique_integer([:positive])}"

  describe "Agent.resolve!/1" do
    test "resolves a fixture: address to the FixtureAgent module and its key" do
      assert {FixtureAgent, "abc"} = Agent.resolve!("fixture:abc")
    end
  end

  describe "FixtureAgent.produce/3" do
    test "returns the scripted document for {role, iteration}" do
      key = unique_key()
      doc = %{"id" => "RP-001", "iteration" => 0}
      :ok = FixtureAgent.install_script!(key, %{{:researcher, 0} => doc})

      assert {:ok, ^doc} = FixtureAgent.produce(:researcher, 0, %{key: key})
    end

    test "returns a scripted typed infrastructure failure verbatim" do
      key = unique_key()

      :ok =
        FixtureAgent.install_script!(key, %{
          {:creator, 1} => {:error, {:infrastructure, :flaky}}
        })

      assert {:error, {:infrastructure, :flaky}} = FixtureAgent.produce(:creator, 1, %{key: key})
    end

    test "a missing script entry for {role, iteration} is a domain failure" do
      key = unique_key()
      :ok = FixtureAgent.install_script!(key, %{})

      assert {:error, {:domain, {:no_script, :researcher, 3}}} =
               FixtureAgent.produce(:researcher, 3, %{key: key})
    end

    test "an unknown key behaves like an empty script — domain failure, not a crash" do
      assert {:error, {:domain, {:no_script, :researcher, 0}}} =
               FixtureAgent.produce(:researcher, 0, %{key: unique_key()})
    end
  end

  describe "FixtureAgent.script_from_golden!/0" do
    test "installs the golden rp/cd script and returns the loop-config agent string" do
      assert "fixture:golden" = FixtureAgent.script_from_golden!()

      assert {:ok, rp0} = FixtureAgent.produce(:researcher, 0, %{key: "golden"})
      assert rp0["id"] == "RP-001"
      assert rp0["iteration"] == 0

      assert {:ok, rp1} = FixtureAgent.produce(:researcher, 1, %{key: "golden"})
      assert rp1["id"] == "RP-002"

      assert {:ok, cd0} = FixtureAgent.produce(:creator, 0, %{key: "golden"})
      assert cd0["id"] == "CD-001"

      assert {:ok, cd1} = FixtureAgent.produce(:creator, 1, %{key: "golden"})
      assert cd1["id"] == "CD-002"
    end
  end
end
