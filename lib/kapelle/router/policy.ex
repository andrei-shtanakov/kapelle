defmodule Kapelle.Router.Policy do
  @moduledoc """
  Behaviour for routing a task to a provider/model target.

  Implementations decide, from a task's attributes, which provider/model
  should execute it, and record that choice as a `Kapelle.Router.Decision`.
  """

  alias Kapelle.Router.Decision

  @callback route(task :: map(), opts :: keyword()) ::
              {:ok, Decision.t()} | {:error, term()}
end
