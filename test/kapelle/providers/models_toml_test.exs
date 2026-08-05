defmodule Kapelle.Providers.ModelsTomlTest do
  use ExUnit.Case, async: true

  @catalog_path Path.join(:code.priv_dir(:kapelle), "catalog/models.toml")

  test "priv/catalog/models.toml parses cleanly via Toml.decode_file!/1" do
    assert %{"models" => models} = Toml.decode_file!(@catalog_path)
    assert is_list(models)
    assert models != []
  end

  test "catalog has entries for at least two distinct providers, including anthropic" do
    %{"models" => models} = Toml.decode_file!(@catalog_path)
    providers = models |> Enum.map(& &1["provider"]) |> Enum.uniq()

    assert "anthropic" in providers
    assert length(providers) >= 2
  end

  test "every entry has a provider, model, and params sub-table" do
    %{"models" => models} = Toml.decode_file!(@catalog_path)

    for entry <- models do
      assert is_binary(entry["provider"]) and entry["provider"] != ""
      assert is_binary(entry["model"]) and entry["model"] != ""
      assert %{"temperature" => _, "max_tokens" => _} = entry["params"]
    end
  end
end
