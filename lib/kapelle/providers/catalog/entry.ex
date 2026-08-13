defmodule Kapelle.Providers.Catalog.Entry do
  @moduledoc """
  A single catalog entry: a provider/model pair addressable by
  `"<provider>@<model>"` id, with per-entry invocation params and an
  optional, data-declared `fallback` chain of other entry ids to try when
  this one errors.
  """

  @enforce_keys [:id, :provider, :model]
  defstruct [:id, :provider, :model, params: %{}, fallback: []]

  @type t :: %__MODULE__{
          id: String.t(),
          provider: String.t(),
          model: String.t(),
          params: map(),
          fallback: [String.t()]
        }
end
