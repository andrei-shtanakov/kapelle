defmodule Kapelle.Product.CanonicalHashTest do
  use ExUnit.Case, async: true

  alias Kapelle.Product.CanonicalHash

  @cases "test/support/fixtures/canonical_hash/cases.json"
         |> File.read!()
         |> Jason.decode!()

  test "fixture set is non-trivial" do
    assert length(@cases) >= 8
  end

  for %{"name" => name} <- @cases do
    test "matches the producer's hash: #{name}" do
      %{"doc" => doc, "hash" => expected} = Enum.find(@cases, &(&1["name"] == unquote(name)))
      assert CanonicalHash.hash(doc) == expected
    end
  end

  test "key order of the input map is immaterial" do
    a = %{"b" => 1, "a" => %{"d" => 2, "c" => 3}}
    b = %{"a" => %{"c" => 3, "d" => 2}, "b" => 1}
    assert CanonicalHash.hash(a) == CanonicalHash.hash(b)
  end
end
