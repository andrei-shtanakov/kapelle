defmodule Kapelle.Product.Contracts do
  @moduledoc """
  Registry of the seven vendored impresario contract schemas (design doc §7).
  Reads only the vendored bytes under `priv/contracts/impresario/` — never
  the neighbouring impresario checkout. Schemas declare JSON Schema 2020-12
  but use only draft-compatible keywords; the `$schema` member is stripped
  before resolving (characterized in schema_compat_test.exs; the fixture
  parity suite guards the assumption against upstream keyword drift).

  Schema paths resolve via `Application.app_dir/2` so loading works
  regardless of the process's OS CWD — required for production, where the
  CWD is not the repo root (owner's S2 preamble, item 3).
  """

  @vendor_subdir "priv/contracts/impresario"

  @kind_dirs %{
    idea: "idea",
    research_pack: "research-pack",
    concept_draft: "concept-draft",
    product_proposal: "product-proposal",
    exchange_log: "exchange-log",
    loop_state: "loop-state",
    gate_decision: "gate-decision"
  }

  @spec kinds() :: [atom()]
  def kinds, do: Map.keys(@kind_dirs)

  @spec dir!(atom()) :: String.t()
  def dir!(kind) do
    Path.join([Application.app_dir(:kapelle, @vendor_subdir), Map.fetch!(@kind_dirs, kind), "v1"])
  end

  @spec fetch_schema(atom()) ::
          {:ok, ExJsonSchema.Schema.Root.t()} | {:error, {:unknown_contract, term()}}
  def fetch_schema(kind) do
    case Map.fetch(@kind_dirs, kind) do
      {:ok, _dir} -> {:ok, schema!(kind)}
      :error -> {:error, {:unknown_contract, kind}}
    end
  end

  @spec schema!(atom()) :: ExJsonSchema.Schema.Root.t()
  def schema!(kind) do
    key = {__MODULE__, kind}

    case :persistent_term.get(key, nil) do
      nil ->
        schema =
          dir!(kind)
          |> Path.join("schema.json")
          |> File.read!()
          |> Jason.decode!()
          |> Map.delete("$schema")
          |> ExJsonSchema.Schema.resolve()

        :persistent_term.put(key, schema)
        schema

      schema ->
        schema
    end
  end
end
