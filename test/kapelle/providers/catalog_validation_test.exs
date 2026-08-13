defmodule Kapelle.Providers.CatalogValidationTest do
  @moduledoc """
  Review-authored validation tests for `Kapelle.Providers.Catalog.load/1`.

  These four tests were written by the TASK-101 review agent against
  `catalog_test.exs`. They live in their own file because that file's bytes
  are the claimed RED evidence of checkpoint a9a0a5a0a1a8 (spec-runner TDD
  claim): the claim must keep matching, and the tests must keep running.
  """
  use ExUnit.Case, async: true

  alias Kapelle.Providers.Catalog

  defp fixture(name) do
    Path.join([__DIR__, "catalog", "fixtures", name])
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
