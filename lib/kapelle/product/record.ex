defmodule Kapelle.Product.Record do
  @moduledoc """
  A validated product document of one of the seven vendored kinds
  (design doc §7). Carries identity plus the full validated document;
  per-field typing grows per consumer need in later slices.

  `id` is populated from the document's own identity field via
  `Kapelle.Product.Identity.of/2` — never a file path, never a generated
  UUID. `Kapelle.Product.Loader.load/2` never produces a record with a
  `nil` id for a valid artifact; the `nil` case in the type below covers
  records built by other means (e.g. tests).
  """

  @enforce_keys [:kind, :doc]
  defstruct [:kind, :id, :doc]

  @type t :: %__MODULE__{kind: atom(), id: String.t() | nil, doc: map()}
end
