defmodule Kapelle.Product.Agent do
  @moduledoc """
  Port for loop agents (design §4): the single place in the system that
  interprets an agent address string.

  Agent addressing is always a string (owner's ruling, 2026-08-14):
  `Kapelle.Product.Loop.start/2`'s `:agent` opt and `product_loops.agent`
  both hold this string verbatim, and `resolve/1` (or its `resolve!/1`
  wrapper) is the only place that interprets it into something callable.

  Two schemes exist: `fixture:<key>` (test-only, resolves to
  `Kapelle.Product.FixtureAgent`) and `model:<catalog-id>`, where
  `<catalog-id>` has the form `<non-empty>@<non-empty>` and is passed to
  the live adapter verbatim — this module parses only the address shape,
  never the catalog id's semantics (that is the adapter's job). The live
  scheme resolves to a **configured** module
  (`Application.get_env(:kapelle, :product_live_agent,
  Kapelle.Product.LiveAgent)`, read at resolve time so tests can swap in a
  double), not a hardcoded literal.
  """

  @type role :: :researcher | :creator
  @type failure :: {:infrastructure, term()} | {:domain, term()} | {:invalid_artifact, term()}

  @typedoc """
  Metadata for a live agent call — the additive third element `produce/3`
  may return alongside its document. `tokens: nil` means usage was not
  reported (not measured as zero).
  """
  @type call_meta :: %{
          model_id: String.t(),
          tokens:
            %{
              input: integer() | nil,
              output: integer() | nil,
              total: integer() | nil
            }
            | nil
        }

  @typedoc """
  Configuration-class failures a live adapter's `produce/3` may return.
  Deliberately not part of `failure()`: neither is a judgement about the
  proposal, so both route to the failed-outside-domain path (fail-closed,
  terminal, product axis stays `:unknown`) instead of widening the port's
  public failure type.
  """
  @type config_failure ::
          {:provider_auth_failed, String.t(), String.t()}
          | {:unclassified_provider_failure, String.t()}

  @typedoc "Named reasons `resolve/1` returns instead of raising."
  @type address_failure :: {:unknown_scheme, term()} | {:malformed_address, term()}

  @callback produce(role(), iteration :: non_neg_integer(), context :: map()) ::
              {:ok, map()}
              | {:ok, map(), call_meta()}
              | {:error, failure() | config_failure()}

  defmodule AddressError do
    @moduledoc "Raised by `resolve!/1` for an address `resolve/1` could not resolve."
    defexception [:message]
  end

  @known_schemes ~w(fixture model)

  @doc """
  Resolves an agent address string to the `{module, key}` pair a caller
  uses to invoke `produce/3` (`module.produce(role, iteration, context)`,
  threading `key` through `context` as the module needs it — for
  `Kapelle.Product.FixtureAgent` that's `context.key`).

  Total: never raises, not even on an unrecognized scheme or a
  malformed/non-string address. Returns `{:ok, {module, key}}` or a named
  `{:error, address_failure()}` — `{:unknown_scheme, address}` for a
  scheme this module does not know, `{:malformed_address, address}` for a
  known scheme with a malformed tail (or a non-string address). Resolving
  never makes a network call.
  """
  @spec resolve(term()) :: {:ok, {module(), String.t()}} | {:error, address_failure()}
  def resolve(address) when not is_binary(address) do
    {:error, {:malformed_address, address}}
  end

  def resolve("") do
    {:error, {:malformed_address, ""}}
  end

  def resolve(address) do
    case String.split(address, ":", parts: 2) do
      [scheme, tail] when scheme in @known_schemes ->
        resolve_known(scheme, tail, address)

      [scheme] when scheme in @known_schemes ->
        {:error, {:malformed_address, address}}

      _other ->
        {:error, {:unknown_scheme, address}}
    end
  end

  defp resolve_known("fixture", key, _address) when byte_size(key) > 0 do
    {:ok, {Kapelle.Product.FixtureAgent, key}}
  end

  defp resolve_known("fixture", _key, address) do
    {:error, {:malformed_address, address}}
  end

  defp resolve_known("model", catalog_id, address) do
    if valid_catalog_id?(catalog_id) do
      {:ok, {live_agent_module(), catalog_id}}
    else
      {:error, {:malformed_address, address}}
    end
  end

  defp valid_catalog_id?(catalog_id) do
    case String.split(catalog_id, "@", parts: 2) do
      [provider, model] -> byte_size(provider) > 0 and byte_size(model) > 0
      _other -> false
    end
  end

  defp live_agent_module do
    Application.get_env(:kapelle, :product_live_agent, Kapelle.Product.LiveAgent)
  end

  @doc """
  `resolve/1`, raising `AddressError` with a readable message instead of
  returning `{:error, reason}` — for callers that want to fail loudly.
  """
  @spec resolve!(term()) :: {module(), String.t()}
  def resolve!(address) do
    case resolve(address) do
      {:ok, result} ->
        result

      {:error, reason} ->
        raise AddressError, message: address_error_message(reason)
    end
  end

  defp address_error_message({:unknown_scheme, address}) do
    "unknown agent address scheme: #{inspect(address)}"
  end

  defp address_error_message({:malformed_address, address}) do
    "malformed agent address: #{inspect(address)}"
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
