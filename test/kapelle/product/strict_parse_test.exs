defmodule Kapelle.Product.StrictParseTest do
  use ExUnit.Case, async: true

  alias Kapelle.Product.StrictParse

  test "clean YAML parses to a map" do
    assert {:ok, %{"a" => 1, "b" => %{"c" => "x"}}} =
             StrictParse.parse("a: 1\nb:\n  c: x\n")
  end

  test "duplicate top-level YAML key is a typed failure" do
    assert {:error, {:duplicate_key, "a"}} = StrictParse.parse("a: 1\na: 2\n")
  end

  test "duplicate nested YAML key is a typed failure" do
    assert {:error, {:duplicate_key, "c"}} =
             StrictParse.parse("b:\n  c: 1\n  c: 2\n")
  end

  test "clean JSON parses to a map" do
    assert {:ok, %{"a" => 1}} = StrictParse.parse(~s({"a": 1}))
  end

  test "duplicate JSON key (any depth) is a typed failure" do
    assert {:error, {:duplicate_key, "a"}} = StrictParse.parse(~s({"a": 1, "a": 2}))
    assert {:error, {:duplicate_key, "c"}} = StrictParse.parse(~s({"b": {"c": 1, "c": 2}}))
  end

  test "garbage is unparseable, not a crash" do
    assert {:error, {:unparseable, _}} = StrictParse.parse(": : nope : :")
  end

  test "a bare JSON scalar is not a document" do
    assert {:error, {:unparseable, {:not_a_document, 1}}} = StrictParse.parse("1")
  end

  test "a bare JSON array is not a document" do
    assert {:error, {:unparseable, {:not_a_document, [1, 2]}}} = StrictParse.parse("[1, 2]")
  end

  test "a bare YAML sequence is not a document" do
    assert {:error, {:unparseable, {:not_a_document, ["a", "b"]}}} =
             StrictParse.parse("- a\n- b\n")
  end
end
