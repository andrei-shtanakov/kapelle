defmodule Kapelle.Providers.CatalogValidationTest do
  @moduledoc """
  TASK-101 fallback tests for `Kapelle.Providers.Catalog.load/1` that were
  added to `catalog_test.exs` after its bytes became claimed RED evidence
  (checkpoint a9a0a5a0a1a8, spec-runner TDD claim): four by the green-phase
  implementation, four by the review agent. They live in their own file so
  the claim keeps matching while the tests keep running.
  """
  use ExUnit.Case, async: true

  alias Kapelle.Providers.Catalog

  defp fixture(name) do
    Path.join([__DIR__, "catalog", "fixtures", name])
  end

  describe "load/1 fallback parsing" do
    test "parses a declared fallback chain onto the entry" do
      assert {:ok, [entry, _fallback_entry]} = Catalog.load(fixture("fallback_chain.toml"))
      assert entry.fallback == ["openai@gpt-5"]
    end

    test "defaults fallback to an empty list when absent" do
      assert {:ok, [entry]} = Catalog.load(fixture("missing_params.toml"))
      assert entry.fallback == []
    end

    test "non-list fallback returns {:error, {:invalid_entry, 0, :invalid_field, :fallback}}" do
      assert {:error, {:invalid_entry, 0, :invalid_field, :fallback}} =
               Catalog.load(fixture("invalid_fallback_type.toml"))
    end

    test "a fallback cycle returns {:error, {:fallback_cycle, [ids]}}" do
      assert {:error, {:fallback_cycle, cycle}} = Catalog.load(fixture("fallback_cycle.toml"))

      assert cycle == ["anthropic@claude-sonnet-5", "openai@gpt-5", "anthropic@claude-sonnet-5"]
    end

    # TASK-104 regression: `anthropic@claude-sonnet-5` leads into the
    # `openai@gpt-5 <-> mistral@large` cycle but is not itself part of it.
    # The reported cycle must be the minimal repeating segment, not the
    # entry path that reaches it.
    test "an entry leading into a cycle it is not part of reports only the cycle's minimal segment" do
      assert {:error, {:fallback_cycle, cycle}} =
               Catalog.load(fixture("fallback_cycle_with_leadin.toml"))

      assert cycle == ["openai@gpt-5", "mistral@large", "openai@gpt-5"]
      refute "anthropic@claude-sonnet-5" in cycle
    end
  end

  describe "load/1 validation" do
    test "a self-referencing fallback returns {:error, {:fallback_cycle, [ids]}}" do
      assert {:error, {:fallback_cycle, cycle}} =
               Catalog.load(fixture("fallback_self_cycle.toml"))

      assert cycle == ["anthropic@claude-sonnet-5", "anthropic@claude-sonnet-5"]
    end

    test "a three-node fallback cycle returns {:error, {:fallback_cycle, [ids]}}" do
      assert {:error, {:fallback_cycle, cycle}} =
               Catalog.load(fixture("fallback_cycle_three_nodes.toml"))

      assert cycle == [
               "anthropic@claude-sonnet-5",
               "openai@gpt-5",
               "mistral@large",
               "anthropic@claude-sonnet-5"
             ]
    end

    test "a fallback list mixing valid and invalid element types returns {:error, {:invalid_entry, 0, :invalid_field, :fallback}}" do
      assert {:error, {:invalid_entry, 0, :invalid_field, :fallback}} =
               Catalog.load(fixture("invalid_fallback_element_type.toml"))
    end

    test "duplicate provider/model ids return {:error, {:duplicate_id, id}}" do
      assert {:error, {:duplicate_id, "anthropic@claude-sonnet-5"}} =
               Catalog.load(fixture("duplicate_ids.toml"))
    end
  end
end
