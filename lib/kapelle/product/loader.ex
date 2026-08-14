defmodule Kapelle.Product.Loader do
  @moduledoc """
  YAML → validated `Kapelle.Product.Record`. Validation happens before any
  record exists: there is no way to hold an invalid document in a typed
  record (design doc §3, invariant 4).
  """

  alias Kapelle.Product.{Identity, Record, Validator}

  @spec load(atom(), binary()) ::
          {:ok, Record.t()}
          | {:error, {:invalid_artifact, atom(), list()}}
          | {:error, {:unknown_contract, term()}}
          | {:error, {:unparseable, term()}}
          | {:error, {:missing_identity, atom(), String.t()}}
  def load(kind, yaml) when is_binary(yaml) do
    with {:ok, doc} <- parse(yaml),
         :ok <- Validator.validate(kind, doc),
         {:ok, id} <- Identity.of(kind, doc) do
      {:ok, %Record{kind: kind, id: id, doc: doc}}
    end
  end

  defp parse(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, doc} when is_map(doc) -> {:ok, doc}
      {:ok, other} -> {:error, {:unparseable, {:not_a_document, other}}}
      {:error, reason} -> {:error, {:unparseable, reason}}
    end
  end
end
