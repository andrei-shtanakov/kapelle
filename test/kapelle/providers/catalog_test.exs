defmodule Kapelle.Providers.CatalogTest do
  use ExUnit.Case, async: true

  alias Kapelle.Providers.Catalog
  alias Kapelle.Providers.Catalog.Entry

  defp fixture(name) do
    Path.join([__DIR__, "..", "..", "support", "fixtures", "catalog", name])
  end

  describe "load/1" do
    test "returns {:ok, entries} for a well-formed catalog" do
      assert {:ok, entries} = Catalog.load(fixture("valid.toml"))

      assert [
               %Entry{
                 id: "anthropic@claude-sonnet-5",
                 provider: "anthropic",
                 model: "claude-sonnet-5",
                 params: %{"temperature" => 0.7, "max_tokens" => 4096}
               },
               %Entry{
                 id: "openai@gpt-5",
                 provider: "openai",
                 model: "gpt-5",
                 params: %{"temperature" => 0.5, "max_tokens" => 8192}
               }
             ] = entries
    end

    test "defaults params to an empty map when absent" do
      assert {:ok, [entry]} = Catalog.load(fixture("missing_params.toml"))
      assert entry.params == %{}
    end

    test "load/0 default arg resolves the real priv/catalog/models.toml" do
      assert {:ok, entries} = Catalog.load()
      assert entries != []
      assert Enum.any?(entries, &(&1.id == "anthropic@claude-sonnet-5"))
    end

    test "missing file returns {:error, {:catalog_file_not_found, path}}" do
      path = fixture("does_not_exist.toml")
      assert {:error, {:catalog_file_not_found, ^path}} = Catalog.load(path)
    end

    test "invalid TOML syntax returns {:error, {:invalid_toml, message}}" do
      assert {:error, {:invalid_toml, message}} = Catalog.load(fixture("malformed_syntax.toml"))
      assert is_binary(message)
      assert message != ""
    end

    test "non-models top-level shape returns {:error, {:invalid_catalog_shape, decoded}}" do
      assert {:error, {:invalid_catalog_shape, decoded}} =
               Catalog.load(fixture("invalid_shape.toml"))

      assert decoded == %{"models" => %{"foo" => "bar"}}
    end

    test "missing provider returns {:error, {:invalid_entry, 0, :missing_field, :provider}}" do
      assert {:error, {:invalid_entry, 0, :missing_field, :provider}} =
               Catalog.load(fixture("missing_field.toml"))
    end

    test "missing model returns {:error, {:invalid_entry, 0, :missing_field, :model}}" do
      assert {:error, {:invalid_entry, 0, :missing_field, :model}} =
               Catalog.load(fixture("missing_model.toml"))
    end

    test "non-string provider returns {:error, {:invalid_entry, 0, :missing_field, :provider}}" do
      assert {:error, {:invalid_entry, 0, :missing_field, :provider}} =
               Catalog.load(fixture("invalid_provider_type.toml"))
    end

    test "non-map params returns {:error, {:invalid_entry, 0, :invalid_field, :params}}" do
      assert {:error, {:invalid_entry, 0, :invalid_field, :params}} =
               Catalog.load(fixture("invalid_params.toml"))
    end

    test "first invalid entry short-circuits the whole load, no partial catalog" do
      assert {:error, {:invalid_entry, 1, :missing_field, :provider}} =
               Catalog.load(fixture("short_circuit.toml"))
    end
  end

  describe "list/0" do
    test "returns {:ok, entries} for the real priv/catalog/models.toml" do
      assert {:ok, entries} = Catalog.list()
      assert Enum.any?(entries, &(&1.id == "anthropic@claude-sonnet-5"))
      assert length(entries) >= 2
    end
  end

  describe "get/1" do
    test "returns {:ok, entry} for a known id" do
      assert {:ok, entry} = Catalog.get("anthropic@claude-sonnet-5")
      assert %Entry{id: "anthropic@claude-sonnet-5", provider: "anthropic"} = entry
    end

    test "returns {:error, {:unknown_model_id, id}} for an unknown id" do
      assert {:error, {:unknown_model_id, "nope@nope"}} = Catalog.get("nope@nope")
    end
  end
end
