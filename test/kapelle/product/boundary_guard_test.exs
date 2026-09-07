defmodule Kapelle.Product.BoundaryGuardTest do
  @moduledoc """
  DT-06 boundary invariants (workstreams/real-llm-provider-adapters-20260907/
  spec/15-behaviour-spec.md): BEH-02 (address-prefix parsing confined to
  `Kapelle.Product.Agent`), BEH-07 (no second model-addressing mechanism
  duplicating the catalog) and BEH-31, all five "Then" clauses (the m1
  execution plane, the catalog, monetary cost, the artifact contract and
  the impresario write-path all stay untouched this milestone). Each is a
  static scan or a pinned-hash check over the checked-in sources — no
  fixtures, no network, no dependence on git/branch state (design doc:
  BEH-31's check MUST NOT be built on `git diff`, since the test must not
  depend on the state of the branch).
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

  # `Kapelle.Product.Agent.resolve/1` itself parses the prefix by splitting
  # on ":" and matching the head against a scheme allow-list (not
  # concatenation/bitstring/starts_with?) — the most natural idiom to
  # copy-paste into a second module, and the concrete patterns above don't
  # cover it. Flagged only when a file both colon-splits *and* names both
  # scheme literals, so a file that merely mentions "model" or "fixture"
  # in prose doesn't trip it.
  @scheme_split_pattern ~r/String\.split\([^,]+,\s*":"/

  defp scheme_split_offender?(source) do
    Regex.match?(@scheme_split_pattern, source) and
      String.contains?(source, "\"fixture\"") and
      String.contains?(source, "\"model\"")
  end

  test "only Kapelle.Product.Agent parses an agent address prefix (BEH-02)" do
    offenders =
      "lib/**/*.{ex,exs}"
      |> Path.wildcard()
      |> Enum.reject(&(&1 == @address_port))
      |> Enum.filter(fn path ->
        source = File.read!(path)

        Enum.any?(@address_prefix_patterns, &Regex.match?(&1, source)) or
          scheme_split_offender?(source)
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
  # langchain chat model instead of going through ModelFactory.
  #
  # The spec's "Then" clause also names params-*value* duplication (e.g. a
  # hardcoded `temperature: 0.7` mirroring the catalog), deliberately left
  # unchecked here: entry.params values are generic numbers/strings with no
  # signature distinct from ordinary code (timeouts, retry counts, ...), so
  # a literal scan for them would false-positive far more than it would
  # catch. Needs a narrower signal (e.g. a params-shaped literal keyed by
  # the same field names) before it can be added safely. ---

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
        # module-path token, not just the `alias` keyword — a fully
        # qualified `LangChain.ChatModels.ChatX.new/1` call needs no alias
        # and would otherwise slip past this guard.
        File.read!(path) |> then(&Regex.match?(~r/LangChain\.ChatModels\./, &1))
      end)

    assert chat_model_builders == [],
           "a second model-addressing mechanism was found outside " <>
             "Kapelle.Providers.ModelFactory (BEH-07): #{inspect(chat_model_builders)}"
  end

  # --- BEH-31: the milestone diff stays within the agreed boundary. The
  # spec's "Then" clause has five parts; the first, fourth and fifth are
  # checked below, the second and third in the following test:
  #   1. m1 execution plane untouched            -> this test
  #   4. artifact contract/normalizer untouched   -> this test (same map)
  #   5. no write-path from kapelle to impresario -> already covered by
  #      "no runtime module references the impresario checkout ..." above
  #      (that test *is* this invariant, not a different one)
  #   2. catalog not augmented with new providers -> next test
  #   3. no monetary cost introduced              -> next test
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

  defp sha256_hex(path) do
    path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  test "the m1 execution plane is not modified within this milestone (BEH-31)" do
    offenders =
      Enum.reject(@m1_execution_plane, fn {path, expected_sha256} ->
        sha256_hex(path) == expected_sha256
      end)

    assert offenders == [],
           "m1 execution plane changed within this milestone (BEH-31): " <>
             "#{inspect(Enum.map(offenders, &elem(&1, 0)))} — Executor.Adapter, " <>
             "Executor.ChainAdapter, FallbackResolver and the artifact " <>
             "contract/normalizer must stay byte-identical until m1 reopens"
  end

  # --- BEH-31 continued: catalog not augmented, no monetary cost
  # introduced. The catalog file itself is pinned the same way as the m1
  # plane above — any new provider/model entry (or any other edit) flips
  # the hash. Credential-shaped param keys are matched *exactly*, not by
  # substring: the catalog already has a legitimate "max_tokens" key, which
  # a substring match on "token" would wrongly flag. The currency-code scan
  # deliberately does not use the words "cost"/"budget"/"price" — those
  # already denote token/iteration accounting elsewhere in this codebase
  # (e.g. Kapelle.Product.RunVerdict's cost block), so scanning for them
  # would false-positive immediately; ISO 4217 codes are a narrower, real
  # signal for money actually showing up. ---

  @catalog_path "priv/catalog/models.toml"
  @catalog_baseline_sha256 "0746219058463bc44459c214d58fb65835eb93c295cf6d2c41d15b850df61ed1"
  @forbidden_param_keys ~w(api_key key token secret)
  @currency_code_pattern ~r/\b(USD|EUR|GBP|RUB|JPY)\b/

  test "the catalog is not augmented and carries no monetary or credential-shaped fields (BEH-31)" do
    assert sha256_hex(@catalog_path) == @catalog_baseline_sha256,
           "catalog file changed within this milestone (BEH-31): #{@catalog_path} — " <>
             "no new provider or model family may be added until m1 reopens"

    {:ok, entries} = Catalog.load()

    credential_offenders =
      entries
      |> Enum.flat_map(fn entry -> Map.keys(entry.params) end)
      |> Enum.filter(&(&1 in @forbidden_param_keys))
      |> Enum.uniq()

    assert credential_offenders == [],
           "catalog params carry credential-shaped keys (BEH-31): " <>
             "#{inspect(credential_offenders)} — provider secrets must not live in the catalog"

    currency_offenders =
      "lib/**/*.{ex,exs}"
      |> Path.wildcard()
      |> Enum.filter(&Regex.match?(@currency_code_pattern, File.read!(&1)))

    assert currency_offenders == [],
           "a currency code was found in runtime sources (BEH-31): " <>
             "#{inspect(currency_offenders)} — monetary cost must not be introduced this milestone"
  end
end
