defmodule Kapelle.Product.Record do
  @moduledoc """
  A validated product document of one of the seven vendored kinds
  (design doc §7). Carries identity plus the full validated document;
  per-field typing grows per consumer need in later slices.
  """

  @enforce_keys [:kind, :doc]
  defstruct [:kind, :id, :doc]

  @type t :: %__MODULE__{kind: atom(), id: String.t() | nil, doc: map()}
end
