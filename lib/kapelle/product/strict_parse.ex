defmodule Kapelle.Product.StrictParse do
  @moduledoc """
  Parsing that refuses documents with duplicate keys at any depth (owner's
  S2 preamble, item 1: duplicate keys are a validation failure BEFORE
  hashing — a parser that silently drops one must never feed the hasher).
  Accepts YAML and JSON (JSON first: it is a YAML subset, but Jason's
  ordered-object decode preserves duplicate pairs, which yamerl's plain
  constructor would not).
  """

  @spec parse(binary()) ::
          {:ok, map()}
          | {:error, {:duplicate_key, String.t()}}
          | {:error, {:unparseable, term()}}
  def parse(input) when is_binary(input) do
    case Jason.decode(input, objects: :ordered_objects) do
      {:ok, decoded} -> from_json(decoded)
      {:error, _not_json} -> parse_yaml(input)
    end
  end

  defp from_json(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, fn {k, _v} -> k end)

    case keys -- Enum.uniq(keys) do
      [dup | _] ->
        {:error, {:duplicate_key, dup}}

      [] ->
        Enum.reduce_while(pairs, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
          case from_json(v) do
            {:ok, converted} -> {:cont, {:ok, Map.put(acc, k, converted)}}
            error -> {:halt, error}
          end
        end)
    end
  end

  defp from_json(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case from_json(item) do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp from_json(scalar), do: {:ok, scalar}

  # `keep_duplicate_keys: true` is load-bearing, not cosmetic: yamerl's
  # `detailed_constr` mode alone still collapses duplicate mapping keys to
  # last-wins before the pairs list is ever built (see
  # yamerl_node_map.erl), so without this flag every duplicate-key check
  # below would silently never fire. Characterized empirically in
  # task-3-report.md — do not remove.
  @yamerl_opts [:detailed_constr, keep_duplicate_keys: true]

  defp parse_yaml(input) do
    case :yamerl_constr.string(String.to_charlist(input), @yamerl_opts) do
      [doc] -> from_yamerl(doc)
      [] -> {:error, {:unparseable, :empty}}
      docs when is_list(docs) -> {:error, {:unparseable, {:multiple_documents, length(docs)}}}
    end
  rescue
    e -> {:error, {:unparseable, e}}
  catch
    :throw, e -> {:error, {:unparseable, e}}
  end

  # yamerl's detailed-construction nodes are Erlang tuples; the tag is
  # element 0 and payload positions are stable per yamerl's
  # include/yamerl_nodes.hrl. Verified empirically against yamerl 2.x
  # output (task-3-report.md): the document wrapper is a plain 2-tuple
  # `{:yamerl_doc, Node}`, not a record.
  defp from_yamerl({:yamerl_doc, node}), do: from_yamerl(node)

  defp from_yamerl(node) when elem(node, 0) == :yamerl_map do
    pairs = elem(node, tuple_size(node) - 1)
    keys = Enum.map(pairs, fn {k, _v} -> scalar_key(k) end)

    case keys -- Enum.uniq(keys) do
      [dup | _] ->
        {:error, {:duplicate_key, dup}}

      [] ->
        Enum.reduce_while(pairs, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
          case from_yamerl(v) do
            {:ok, converted} -> {:cont, {:ok, Map.put(acc, scalar_key(k), converted)}}
            error -> {:halt, error}
          end
        end)
    end
  end

  defp from_yamerl(node) when elem(node, 0) == :yamerl_seq do
    node
    |> elem(tuple_size(node) - 2)
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case from_yamerl(item) do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp from_yamerl(node) when elem(node, 0) == :yamerl_null, do: {:ok, nil}
  defp from_yamerl(node), do: {:ok, yamerl_scalar(node)}

  defp scalar_key(node), do: node |> yamerl_scalar() |> to_string()

  defp yamerl_scalar(node) do
    case elem(node, tuple_size(node) - 1) do
      text when is_list(text) -> List.to_string(text)
      other -> other
    end
  end
end
