defmodule Kapelle.Providers.Catalog.EntryTest do
  use ExUnit.Case, async: true

  alias Kapelle.Providers.Catalog.Entry

  test "builds a struct with id, provider, model, and params" do
    entry = %Entry{
      id: "anthropic@claude-sonnet-5",
      provider: "anthropic",
      model: "claude-sonnet-5",
      params: %{"temperature" => 0.7, "max_tokens" => 4096}
    }

    assert entry.id == "anthropic@claude-sonnet-5"
    assert entry.provider == "anthropic"
    assert entry.model == "claude-sonnet-5"
    assert entry.params == %{"temperature" => 0.7, "max_tokens" => 4096}
  end

  test "params defaults to an empty map" do
    entry = %Entry{
      id: "anthropic@claude-sonnet-5",
      provider: "anthropic",
      model: "claude-sonnet-5"
    }

    assert entry.params == %{}
  end

  test "raises when required keys are missing" do
    assert_raise ArgumentError, fn ->
      struct!(Entry, provider: "anthropic")
    end
  end
end
