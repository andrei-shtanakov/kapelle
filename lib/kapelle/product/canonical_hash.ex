defmodule Kapelle.Product.CanonicalHash do
  @moduledoc """
  Byte-exact port of the producer's `canonical_doc_hash`
  (impresario src/impresario/hashing.py at the pin): JSON with recursively
  sorted keys, compact separators, unicode preserved, SHA-256, prefixed
  "sha256:". Proven byte-compatible by the cross-language fixtures in
  test/support/fixtures/canonical_hash/ — regenerate them only via
  scripts/gen_hash_fixtures.sh (explicit, reviewable; never on test failure).
  """

  @spec hash(map()) :: String.t()
  def hash(doc) when is_map(doc) do
    canonical = doc |> encode() |> IO.iodata_to_binary()
    "sha256:" <> (:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower))
  end

  defp encode(map) when is_map(map) do
    inner =
      map
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn key -> [Jason.encode!(key), ":", encode(Map.fetch!(map, key))] end)
      |> Enum.intersperse(",")

    ["{", inner, "}"]
  end

  defp encode(list) when is_list(list) do
    ["[", list |> Enum.map(&encode/1) |> Enum.intersperse(","), "]"]
  end

  defp encode(scalar), do: Jason.encode!(scalar)
end
