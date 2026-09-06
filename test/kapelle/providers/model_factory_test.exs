defmodule Kapelle.Providers.ModelFactoryTest do
  use ExUnit.Case, async: true

  alias Kapelle.Providers.ModelFactory
  alias LangChain.ChatModels.ChatAnthropic

  describe "build/1" do
    test "builds a %ChatAnthropic{} for a known anthropic catalog id" do
      assert {:ok, %ChatAnthropic{} = model} = ModelFactory.build("anthropic@claude-sonnet-5")

      assert model.model == "claude-sonnet-5"
      assert model.temperature == 0.7
      assert model.max_tokens == 16_000
    end

    test "returns {:error, {:unsupported_provider, provider}} for a catalog entry with no adapter" do
      assert {:error, {:unsupported_provider, "openai"}} = ModelFactory.build("openai@gpt-5")
    end

    test "propagates Catalog's unknown id error" do
      assert {:error, {:unknown_model_id, "nope@nope"}} = ModelFactory.build("nope@nope")
    end

    test "propagates Catalog's invalid id error for non-binary ids" do
      assert {:error, {:invalid_model_id, 42}} = ModelFactory.build(42)
      assert {:error, {:invalid_model_id, nil}} = ModelFactory.build(nil)
    end
  end
end
