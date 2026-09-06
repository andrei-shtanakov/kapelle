defmodule Kapelle.Product.Agent do
  @moduledoc """
  Port for loop agents (design §4): fixture-backed in M3, real adapters
  later.

  Agent addressing is always a string (owner's ruling, 2026-08-14):
  `Kapelle.Product.Loop.start/2`'s `:agent` opt and `product_loops.agent`
  both hold this string verbatim, and `resolve!/1` is the only place that
  interprets it into something callable.
  """

  @type role :: :researcher | :creator
  @type failure :: {:infrastructure, term()} | {:domain, term()} | {:invalid_artifact, term()}

  @callback produce(role(), iteration :: non_neg_integer(), context :: map()) ::
              {:ok, map()} | {:error, failure()}

  @doc """
  Resolves an agent address string to the `{module, key}` pair a caller
  uses to invoke `produce/3` (`module.produce(role, iteration, context)`,
  threading `key` through `context` as the module needs it — for
  `Kapelle.Product.FixtureAgent` that's `context.key`).

  Only the `fixture:<key>` scheme exists in M3; a live adapter scheme is
  a later slice.
  """
  @spec resolve!(String.t()) :: {module(), String.t()}
  def resolve!("fixture:" <> key) when byte_size(key) > 0 do
    {Kapelle.Product.FixtureAgent, key}
  end

  @doc """
  True only for a well-formed fixture address — the one scheme this slice
  can call, and therefore the only address that proves no provider was
  reached.

  Everything else is `false` on purpose: an unknown scheme, a malformed
  address, a live adapter added by a later slice. A caller asking "was a
  provider really not called?" must be able to fail closed on the answer,
  so this predicate never widens on its own as schemes are added — adding
  one means deciding, at the call site, what its absent usage means.
  """
  @spec fixture?(term()) :: boolean()
  def fixture?("fixture:" <> key), do: byte_size(key) > 0
  def fixture?(_address), do: false
end
