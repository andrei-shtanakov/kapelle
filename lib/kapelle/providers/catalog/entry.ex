defmodule Kapelle.Providers.Catalog.Entry do
  @moduledoc """
  A single catalog entry: a provider/model pair addressable by
  `"<provider>@<model>"` id, with per-entry invocation params.
  """

  @enforce_keys [:id, :provider, :model]
  defstruct [:id, :provider, :model, params: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          provider: String.t(),
          model: String.t(),
          params: map()
        }
end
