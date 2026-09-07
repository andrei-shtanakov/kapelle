defmodule Kapelle.Product.BoundaryGuardTest do
  @moduledoc """
  DT-06 boundary invariants (workstreams/real-llm-provider-adapters-20260907/
  spec/15-behaviour-spec.md): BEH-02 (address-prefix parsing confined to
  `Kapelle.Product.Agent`), BEH-07 (no second model-addressing mechanism
  duplicating the catalog) and BEH-31 (the m1 execution plane stays
  untouched this milestone). Each is a static scan or a pinned-hash check
  over the checked-in sources — no fixtures, no network, no dependence on
  git/branch state (design doc: BEH-31's check MUST NOT be built on `git
  diff`, since the test must not depend on the state of the branch).
  """

  use ExUnit.Case, async: true

  alias Kapelle.Providers.Catalog

  @forbidden [
    ~r/\.\.\/impresario/,
    ~r/_cowork_output/,
    ~r/labs\/(all_ai_orchestrators\/)?impresario/
  ]

  test "no runtime module references the impresario checkout or _cowork_output" do
    offenders =
      (Path.wildcard("lib/**/*.{ex,exs,heex}") ++ Path.wildcard("config/*.exs"))
      |> Enum.filter(fn path ->
        source = File.read!(path)
        Enum.any?(@forbidden, &Regex.match?(&1, source))
      end)

    assert offenders == [],
           "runtime files referencing the producer checkout: #{inspect(offenders)}"
  end

  # --- BEH-02: workers do not know whether the agent in front of them is
  # live or a fixture — enforced here as "no module outside
  # Kapelle.Product.Agent parses an address-prefix". Patterns are the
  # concrete Elixir syntax for prefix matching (binary-match sugar,
  # String.starts_with?/2), not the bare substrings "fixture:"/"model:" —
  # a moduledoc mentioning the scheme in prose is not a violator. ---

  @address_port "lib/kapelle/product/agent.ex"

  @address_prefix_patterns [
    ~r/"fixture:"\s*<>/,
    ~r/"model:"\s*<>/,
    ~r/<<\s*"fixture:"/,
    ~r/<<\s*"model:"/,
    ~r/starts_with\?\([^)]*"fixture:"/,
    ~r/starts_with\?\([^)]*"model:"/
  ]

  test "only Kapelle.Product.Agent parses an agent address prefix (BEH-02)" do
    offenders =
      "lib/**/*.{ex,exs}"
      |> Path.wildcard()
      |> Enum.reject(&(&1 == @address_port))
      |> Enum.filter(fn path ->
        source = File.read!(path)
        Enum.any?(@address_prefix_patterns, &Regex.match?(&1, source))
      end)

    assert offenders == [],
           "address-prefix parsing found outside #{@address_port} (BEH-02): " <>
             "#{inspect(offenders)} — workers must stay ignorant of whether " <>
             "the agent in front of them is live or a fixture"
  end

  # --- BEH-07: no second model-addressing mechanism appears. Model-name
  # literals are read live from the real catalog (not hardcoded in this
  # test), so the check keeps working as the catalog grows. The chat-model
  # construction check catches a second module reaching straight for a
  # langchain chat model instead of going through ModelFactory. ---

  @product_context_glob "lib/kapelle/product/**/*.{ex,exs}"
  @model_addressing_adapter "lib/kapelle/providers/model_factory.ex"

  test "model addressing goes only through Catalog and ModelFactory (BEH-07)" do
    {:ok, entries} = Catalog.load()
    model_literals = Enum.map(entries, & &1.model)

    scanned = Path.wildcard(@product_context_glob) ++ [@model_addressing_adapter]

    literal_offenders =
      Enum.filter(scanned, fn path ->
        source = File.read!(path)
        Enum.any?(model_literals, &String.contains?(source, &1))
      end)

    assert literal_offenders == [],
           "catalog model-name literal duplicated outside the catalog (BEH-07): " <>
             "#{inspect(literal_offenders)} — the product context must carry no " <>
             "model list of its own"

    chat_model_builders =
      "lib/**/*.{ex,exs}"
      |> Path.wildcard()
      |> Enum.reject(&(&1 == @model_addressing_adapter))
      |> Enum.filter(fn path ->
        File.read!(path) |> String.contains?("alias LangChain.ChatModels")
      end)

    assert chat_model_builders == [],
           "a second model-addressing mechanism was found outside " <>
             "Kapelle.Providers.ModelFactory (BEH-07): #{inspect(chat_model_builders)}"
  end

  # --- BEH-31: the m1 execution plane stays untouched for this milestone.
  # Pinned per-file SHA-256 (not a git diff, per the design doc's explicit
  # MUST — this check must not depend on the state of the branch): any edit
  # to these files, however small, flips the hash and fails the test. ---

  @m1_execution_plane %{
    "lib/kapelle/executor/adapter.ex" =>
      "7f5fd8fe552b3e9d4c522ffced892b2c83b0587c3941e3db9ce89f59f5d26b26",
    "lib/kapelle/executor/chain_adapter.ex" =>
      "7def70a02a4cc9a4691ebef545157cc9bc3b021f77c080cabef0a1eae21147af",
    "lib/kapelle/executor/fallback_resolver.ex" =>
      "a89835564377eeb97ccf120b317a06cfb10d2d5ad8c4655818c8aa12d61d8d50",
    "lib/kapelle/product/contracts.ex" =>
      "94fd9dd8a04cb60368a5ae31d5d50a5f61c5e2bcf15e2f8b69c41452e5dad5c5",
    "lib/kapelle/product/oracle/normalizer.ex" =>
      "d3c44eda4697d4e976c355ca281c8265a697289a52a337cb504c6896349ae969"
  }

  test "the m1 execution plane is not modified within this milestone (BEH-31)" do
    offenders =
      Enum.reject(@m1_execution_plane, fn {path, expected_sha256} ->
        actual_sha256 =
          path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

        actual_sha256 == expected_sha256
      end)

    assert offenders == [],
           "m1 execution plane changed within this milestone (BEH-31): " <>
             "#{inspect(Enum.map(offenders, &elem(&1, 0)))} — Executor.Adapter, " <>
             "Executor.ChainAdapter, FallbackResolver and the artifact " <>
             "contract/normalizer must stay byte-identical until m1 reopens"
  end
end
