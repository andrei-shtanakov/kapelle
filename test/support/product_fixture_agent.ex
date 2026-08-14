defmodule Kapelle.Product.FixtureAgent do
  @moduledoc """
  Test-only `Kapelle.Product.Agent` implementation (test/support — never
  compiled outside `:test`), scripted via `:persistent_term` so `produce/3`
  stays deterministic and makes no live call.

  A script is a map `%{{role, iteration} => doc_map | {:error, failure}}`
  installed under a caller-chosen string key (`install_script!/2`).
  `produce/3`'s `context` must carry that key at `context.key` — that is
  the piece `Kapelle.Product.Agent.resolve!/1`'s `{module, key}` result
  threads through for this module.
  """

  @behaviour Kapelle.Product.Agent

  alias Kapelle.Product.StrictParse

  @golden_workspace "test/support/fixtures/golden/happy/workspace"

  @doc "Installs `script` under `key`, overwriting any script already there."
  @spec install_script!(String.t(), map()) :: :ok
  def install_script!(key, script) when is_binary(key) and is_map(script) do
    :persistent_term.put(term_key(key), script)
    :ok
  end

  @doc """
  Parses the golden workspace's `rp-*.yaml`/`cd-*.yaml` files — real
  producer documents, via `StrictParse`, not synthetic doubles — into a
  script keyed by `{role, iteration}` (iteration taken from each doc's own
  `"iteration"` field), installs it under the key `"golden"`, and returns
  `"fixture:golden"`: the string `Kapelle.Product.Loop.start/2`'s `:agent`
  opt (and `product_loops.agent`) expects.
  """
  @spec script_from_golden!() :: String.t()
  def script_from_golden! do
    script =
      Map.new(golden_docs("rp-*.yaml", :researcher) ++ golden_docs("cd-*.yaml", :creator))

    install_script!("golden", script)
    "fixture:golden"
  end

  @impl Kapelle.Product.Agent
  def produce(role, iteration, %{key: key} = _context) do
    script = :persistent_term.get(term_key(key), %{})

    case Map.fetch(script, {role, iteration}) do
      {:ok, {:error, _failure} = error} -> error
      {:ok, doc} -> {:ok, doc}
      :error -> {:error, {:domain, {:no_script, role, iteration}}}
    end
  end

  defp golden_docs(glob, role) do
    @golden_workspace
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.map(fn path ->
      {:ok, doc} = path |> File.read!() |> StrictParse.parse()
      {{role, doc["iteration"]}, doc}
    end)
  end

  defp term_key(key), do: {__MODULE__, key}
end
