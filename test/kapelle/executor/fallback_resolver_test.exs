defmodule Kapelle.Executor.FallbackResolverTest do
  use ExUnit.Case, async: true

  alias Kapelle.Executor.FallbackResolver
  alias Kapelle.Executor.Result
  alias Kapelle.Providers.Catalog.Entry

  defp entry(id, fallback \\ []) do
    %Entry{id: id, provider: "anthropic", model: "claude-sonnet-5", fallback: fallback}
  end

  defp pass(id), do: {:ok, Result.new!(%{task_id: "task-1", status: :pass, output: id})}
  defp fail(id), do: {:ok, Result.new!(%{task_id: "task-1", status: :fail, output: id})}

  defp provider_error(id),
    do: {:ok, Result.new!(%{task_id: "task-1", status: :error, output: id})}

  defp adapter_error(id), do: {:error, {:down, id}}

  defp attempt_from(outcomes) do
    fn id -> Map.fetch!(outcomes, id) end
  end

  describe "resolve/2" do
    test "no chain: a single entry that succeeds serves directly" do
      outcomes = %{"a" => pass("a")}

      assert {:ok, result} = FallbackResolver.resolve(entry("a"), attempt_from(outcomes))
      assert result.status == :pass
      assert result.target == "a"
      assert result.rejected == []
    end

    test "one hop: the first target errors, the fallback serves" do
      outcomes = %{"a" => provider_error("a"), "b" => pass("b")}

      assert {:ok, result} = FallbackResolver.resolve(entry("a", ["b"]), attempt_from(outcomes))
      assert result.status == :pass
      assert result.target == "b"
      assert result.rejected == [{"a", outcomes["a"] |> elem(1)}]
    end

    test "several hops: multiple targets error before one serves" do
      outcomes = %{
        "a" => provider_error("a"),
        "b" => adapter_error("b"),
        "c" => provider_error("c"),
        "d" => pass("d")
      }

      assert {:ok, result} =
               FallbackResolver.resolve(entry("a", ["b", "c", "d"]), attempt_from(outcomes))

      assert result.target == "d"
      assert Enum.map(result.rejected, &elem(&1, 0)) == ["a", "b", "c"]
      assert {_id, {:down, "b"}} = Enum.at(result.rejected, 1)
    end

    test "all targets erroring: returns {:error, {:all_targets_errored, rejections}}" do
      outcomes = %{
        "a" => provider_error("a"),
        "b" => adapter_error("b")
      }

      assert {:error, {:all_targets_errored, rejections}} =
               FallbackResolver.resolve(entry("a", ["b"]), attempt_from(outcomes))

      assert Enum.map(rejections, &elem(&1, 0)) == ["a", "b"]
    end

    test ":fail on the first target is returned as-is, never triggering a fallback" do
      outcomes = %{"a" => fail("a"), "b" => pass("b")}

      assert {:ok, result} = FallbackResolver.resolve(entry("a", ["b"]), attempt_from(outcomes))
      assert result.status == :fail
      assert result.target == "a"
      assert result.rejected == []
    end
  end
end
