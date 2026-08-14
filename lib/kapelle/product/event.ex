defmodule Kapelle.Product.Event do
  @moduledoc """
  A product-artifact lifecycle event, broadcast by `Kapelle.Product.Events`
  after `Kapelle.Product.Store.put/2` commits an insert (design doc §5).
  """

  @enforce_keys [:loop_id, :kind, :artifact_kind, :artifact_ref, :artifact_hash]
  defstruct [:loop_id, :kind, :artifact_kind, :artifact_ref, :artifact_hash, :producer]

  @type t :: %__MODULE__{
          loop_id: String.t(),
          kind: atom(),
          artifact_kind: atom(),
          artifact_ref: String.t(),
          artifact_hash: String.t(),
          producer: term()
        }
end
