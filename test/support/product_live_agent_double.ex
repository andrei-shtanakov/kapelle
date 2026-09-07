defmodule Kapelle.Test.ProductLiveAgentDouble do
  @moduledoc """
  Test-only `Kapelle.Product.Agent` double for the live `model:` scheme
  (test/support — never compiled outside `:test`). Scripted via
  `:persistent_term`, keyed by the resolved catalog id (`context.key`) —
  the same registration shape `Kapelle.Product.FixtureAgent` uses for
  `fixture:` — but a script entry is a full `produce/3` return value
  (`{:ok, doc}`, `{:ok, doc, call_meta}`, or `{:error, reason}`) rather
  than a bare document, so a scenario can drive every shape a real live
  adapter may return, including reported usage and configuration
  failures, with no network call.

  Registered the way design doc §"Точка подмены живого адаптера"
  describes: `Application.put_env(:kapelle, :product_live_agent,
  __MODULE__)` in an `async: false` test, restoring the previous value
  on exit.
  """

  @behaviour Kapelle.Product.Agent

  @doc "Installs `script` under `key`, overwriting any script already there."
  @spec install_script!(String.t(), map()) :: :ok
  def install_script!(key, script) when is_binary(key) and is_map(script) do
    :persistent_term.put(term_key(key), script)
    :ok
  end

  @doc """
  Erases `key`'s script — used to prove a verdict rebuild reads only
  durable storage, not any live memory of the run.
  """
  @spec erase_script!(String.t()) :: :ok
  def erase_script!(key) when is_binary(key) do
    :persistent_term.erase(term_key(key))
    :ok
  end

  @impl Kapelle.Product.Agent
  def produce(role, iteration, %{key: key}) do
    script = :persistent_term.get(term_key(key), %{})

    case Map.fetch(script, {role, iteration}) do
      {:ok, result} -> result
      :error -> {:error, {:domain, {:no_script, role, iteration}}}
    end
  end

  defp term_key(key), do: {__MODULE__, key}
end
