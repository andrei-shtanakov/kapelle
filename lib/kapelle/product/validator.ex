defmodule Kapelle.Product.Validator do
  @moduledoc """
  Typed validation of product documents against the vendored schemas.
  An unknown kind or an invalid document is a typed failure, never a
  generic success (design doc §3, invariant 4).
  """

  alias Kapelle.Product.Contracts

  @spec validate(atom(), term()) ::
          :ok
          | {:error, {:invalid_artifact, atom(), list()}}
          | {:error, {:unknown_contract, term()}}
          | {:error, {:unparseable, term()}}
  def validate(kind, doc) when is_map(doc) do
    with {:ok, schema} <- Contracts.fetch_schema(kind) do
      case ExJsonSchema.Validator.validate(schema, doc) do
        :ok -> :ok
        {:error, errors} -> {:error, {:invalid_artifact, kind, errors}}
      end
    end
  end

  def validate(_kind, doc) do
    {:error, {:unparseable, {:not_a_document, doc}}}
  end
end
