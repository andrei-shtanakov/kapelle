# Kapelle.Product S1 — Vendoring & Skeleton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Vendor the seven impresario contracts at one producer snapshot with copy-integrity, anti-mix, and a drift watch — and stand up the `Kapelle.Product` skeleton (schema loading, validation, typed records) that consumes them.

**Architecture:** New bounded context `lib/kapelle/product/`. Contracts live as byte-exact vendored copies under `contracts/impresario/<name>/v1/` (schema + fixtures + PIN), extracted from one pinned impresario commit by a re-vendor script that reads `git archive`, never the working tree. Copy-integrity and anti-mix are offline ExUnit tests (guarantee A); upstream drift is a scheduled GitHub workflow (guarantee B). The skeleton exposes a schema registry, a typed validator, and one typed record per contract kind, all consuming only the vendored bytes.

**Tech Stack:** Elixir/Phoenix (existing), `ex_json_schema` (new dep) for JSON Schema validation, `yaml_elixir` (new dep) for artifact/fixture YAML, GitHub Actions for the drift watch.

**Spec:** `docs/superpowers/specs/2026-08-14-product-context-design.md` (§3 invariants, §7 vendored set, §8 S1 exit gates)

## Global Constraints

- Producer pin for S1: `impresario@f84d5ac5a2ae` — every PIN must carry exactly this commit (anti-mix invariant, spec §7).
- Seven contracts, no more, no fewer: `idea`, `research-pack`, `concept-draft`, `product-proposal`, `exchange-log`, `loop-state`, `gate-decision` (spec §7).
- Zero runtime references to `../impresario` or `_cowork_output`: nothing under `lib/` may name them; only `scripts/` (operator tooling) and CI may (spec §3 invariant 6, §8 S1 exit).
- An unknown or invalid contract kind/version is a typed product validation failure, never a generic success (spec §3 invariant 4).
- `Kapelle.Orchestrator` modules must not be touched by this plan at all (spec §3).
- S1 validates `gate-decision` form only — no resume semantics anywhere (spec §7; blocked on impresario#14).
- Repo rules: `mix format` + `mix credo --strict` clean; tests network-free; PR review by human + Copilot; the tool never touches `master`.

---

### Task 1: Dependencies and the 2020-12 characterization test

**Files:**
- Modify: `mix.exs` (deps list, around line 70)
- Test: `test/kapelle/product/schema_compat_test.exs`

**Interfaces:**
- Produces: `{:ex_json_schema, "~> 0.10"}` and `{:yaml_elixir, "~> 2.9"}` available to later tasks.

- [ ] **Step 1: Add the deps**

In `mix.exs`, inside the deps list (after `{:toml, "~> 0.7"}`):

```elixir
      {:ex_json_schema, "~> 0.10"},
      {:yaml_elixir, "~> 2.9"},
```

- [ ] **Step 2: Fetch and compile**

Run: `mix deps.get && mix compile`
Expected: compiles clean.

- [ ] **Step 3: Write the characterization test**

The impresario schemas declare `"$schema": "https://json-schema.org/draft/2020-12/schema"` but use only draft-7-compatible keywords (verified: no `prefixItems`/`unevaluated*`/`dynamic*`; only `$defs`/`$ref`/`enum`/`const`/`oneOf`/`allOf`/`format`). This test pins the load strategy: we strip the `$schema` member before resolving, so `ex_json_schema` applies its default draft to a keyword set that is draft-compatible by construction. If upstream ever adds a 2020-12-only keyword, the fixture-parity suite (Task 5) is what catches it.

```elixir
defmodule Kapelle.Product.SchemaCompatTest do
  use ExUnit.Case, async: true

  test "a 2020-12-declaring schema with draft-7-compatible keywords resolves and validates after $schema strip" do
    schema =
      %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["id"],
        "properties" => %{"id" => %{"type" => "string", "pattern" => "^RP-[0-9]{3,}$"}},
        "$defs" => %{"x" => %{"type" => "integer"}}
      }
      |> Map.delete("$schema")
      |> ExJsonSchema.Schema.resolve()

    assert :ok = ExJsonSchema.Validator.validate(schema, %{"id" => "RP-001"})
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, %{"id" => "nope"})
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, %{"id" => "RP-001", "extra" => 1})
  end
end
```

- [ ] **Step 4: Run it**

Run: `mix test test/kapelle/product/schema_compat_test.exs`
Expected: PASS. If `resolve/1` raises even after the strip, stop and report — the library choice needs revisiting before anything else builds on it.

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock test/kapelle/product/schema_compat_test.exs
git commit -m "deps: ex_json_schema + yaml_elixir, with the 2020-12 strip characterization"
```

### Task 2: Copy-integrity and anti-mix tests (failing first)

**Files:**
- Test: `test/contracts/vendored_impresario_test.exs`

**Interfaces:**
- Consumes: PIN file format produced by Task 3 (defined here, test-first):

```
source: impresario@<full-or-12-hex-sha> contracts/<name>/v1
vendored: <YYYY-MM-DD>
purpose: airun M3 — Kapelle.Product consumer copy (design doc §7)
sha256 schema.json: <64 lowercase hex>
sha256 fixtures/valid/<file>: <64 lowercase hex>
sha256 fixtures/invalid/<file>: <64 lowercase hex>
```

- Produces: auto-discovery of `contracts/impresario/*/v1/PIN` that Task 3's script must satisfy.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Kapelle.Contracts.VendoredImpresarioTest do
  use ExUnit.Case, async: true

  @vendor_root Path.join(File.cwd!(), "contracts/impresario")
  @expected_kinds ~w(idea research-pack concept-draft product-proposal exchange-log loop-state gate-decision)

  defp pins do
    Path.wildcard(Path.join(@vendor_root, "*/v1/PIN"))
  end

  defp parse_pin(pin_path) do
    lines = pin_path |> File.read!() |> String.split("\n", trim: true)

    source =
      Enum.find_value(lines, fn line ->
        case Regex.run(~r/^source: impresario@([0-9a-f]{7,40}) (.+)$/, line) do
          [_, sha, path] -> %{producer_commit: sha, producer_path: path}
          nil -> nil
        end
      end)

    hashes =
      for line <- lines,
          [_, rel, hex] <- [Regex.run(~r/^sha256 (.+): ([0-9a-f]{64})$/, line)],
          do: {rel, hex}

    %{source: source, hashes: hashes, dir: Path.dirname(pin_path)}
  end

  test "exactly the seven expected contracts are vendored, each with a PIN" do
    found = pins() |> Enum.map(&(&1 |> Path.dirname() |> Path.dirname() |> Path.basename())) |> Enum.sort()
    assert found == Enum.sort(@expected_kinds)
  end

  test "every vendored file is byte-identical to its PIN hash, and no file is unpinned" do
    for pin <- pins() do
      %{source: source, hashes: hashes, dir: dir} = parse_pin(pin)
      assert source, "#{pin}: missing/invalid source line"
      assert hashes != [], "#{pin}: no sha256 lines"

      for {rel, hex} <- hashes do
        bytes = File.read!(Path.join(dir, rel))
        actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        assert actual == hex, "#{dir}/#{rel}: vendored bytes differ from PIN"
      end

      on_disk =
        dir
        |> Path.join("**")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, dir))
        |> Enum.reject(&(&1 == "PIN"))
        |> Enum.sort()

      assert on_disk == hashes |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
             "#{dir}: files on disk and files pinned diverge"
    end
  end

  test "anti-mix: every PIN carries the same producer_commit" do
    commits = pins() |> Enum.map(&parse_pin(&1).source.producer_commit) |> Enum.uniq()
    assert length(commits) == 1, "mixed producer commits: #{inspect(commits)}"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/contracts/vendored_impresario_test.exs`
Expected: FAIL — `contracts/impresario` does not exist yet (first test: `found == []`).

- [ ] **Step 3: Commit the red**

```bash
git add test/contracts/vendored_impresario_test.exs
git commit -m "test: copy-integrity, completeness and anti-mix for vendored impresario contracts (red)"
```

### Task 3: The atomic re-vendor script, and the first vendoring

**Files:**
- Create: `scripts/revendor_impresario.sh`
- Create (generated): `contracts/impresario/<name>/v1/{PIN,schema.json,fixtures/...}` × 7

**Interfaces:**
- Consumes: PIN format from Task 2.
- Produces: vendored bytes all later tasks read; the script is the only sanctioned way to change them.

- [ ] **Step 1: Write the script**

Operator tooling (not runtime): takes an impresario checkout path and a commit, extracts contract bytes **from that commit** via `git archive` (never the working tree), writes PINs. One invocation rewrites all seven — atomic by construction, no mixed pins possible.

```bash
#!/usr/bin/env bash
# Re-vendor the seven impresario contracts at one producer commit.
# Usage: scripts/revendor_impresario.sh <path-to-impresario-checkout> <commit>
# Operator tooling: runtime code never references the impresario checkout.
set -euo pipefail

IMPRESARIO="${1:?path to impresario checkout}"
COMMIT="${2:?producer commit}"
KINDS=(idea research-pack concept-draft product-proposal exchange-log loop-state gate-decision)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/contracts/impresario"
SHA="$(git -C "$IMPRESARIO" rev-parse --short=12 "$COMMIT")"
STAMP="$(date +%Y-%m-%d)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for kind in "${KINDS[@]}"; do
  git -C "$IMPRESARIO" archive "$COMMIT" "contracts/$kind/v1" | tar -x -C "$TMP"
done

rm -rf "$DEST"
for kind in "${KINDS[@]}"; do
  src="$TMP/contracts/$kind/v1"
  dst="$DEST/$kind/v1"
  [ -f "$src/schema.json" ] || { echo "!! $kind: no schema.json at $COMMIT"; exit 1; }
  mkdir -p "$dst"
  cp -R "$src/." "$dst/"

  {
    echo "source: impresario@$SHA contracts/$kind/v1"
    echo "vendored: $STAMP"
    echo "purpose: airun M3 — Kapelle.Product consumer copy (design doc §7)"
    (cd "$dst" && find . -type f ! -name PIN | sed 's|^\./||' | LC_ALL=C sort | while read -r f; do
      echo "sha256 $f: $(shasum -a 256 "$f" | cut -d' ' -f1)"
    done)
  } > "$dst/PIN"
done

echo "Vendored ${#KINDS[@]} contracts at impresario@$SHA into $DEST"
```

- [ ] **Step 2: Make it executable and run it**

Run: `chmod +x scripts/revendor_impresario.sh && scripts/revendor_impresario.sh ../all_ai_orchestrators/impresario f84d5ac5a2ae`
Expected: "Vendored 7 contracts at impresario@f84d5ac5a2ae".

- [ ] **Step 3: Run the Task 2 tests to verify they pass**

Run: `mix test test/contracts/vendored_impresario_test.exs`
Expected: PASS (all three tests).

- [ ] **Step 4: Commit**

```bash
git add scripts/revendor_impresario.sh contracts/impresario
git commit -m "feat: vendor seven impresario contracts at f84d5ac5a2ae via atomic re-vendor script"
```

### Task 4: Schema registry and typed validator

**Files:**
- Create: `lib/kapelle/product/contracts.ex`
- Create: `lib/kapelle/product/validator.ex`
- Test: `test/kapelle/product/validator_test.exs`

**Interfaces:**
- Produces:
  - `Kapelle.Product.Contracts.kinds() :: [atom()]` — the seven kinds as atoms (`:idea`, `:research_pack`, `:concept_draft`, `:product_proposal`, `:exchange_log`, `:loop_state`, `:gate_decision`).
  - `Kapelle.Product.Contracts.schema!(kind) :: ExJsonSchema.Schema.Root.t()` — resolved schema; raises on unknown kind (programmer error).
  - `Kapelle.Product.Validator.validate(kind, doc :: map()) :: :ok | {:error, {:invalid_artifact, kind :: atom(), errors :: list()}} | {:error, {:unknown_contract, term()}}`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Kapelle.Product.ValidatorTest do
  use ExUnit.Case, async: true

  alias Kapelle.Product.Contracts
  alias Kapelle.Product.Validator

  test "kinds/0 lists exactly the seven vendored kinds" do
    assert Enum.sort(Contracts.kinds()) ==
             Enum.sort(~w(idea research_pack concept_draft product_proposal exchange_log loop_state gate_decision)a)
  end

  test "a valid document validates :ok" do
    doc =
      "contracts/impresario/research-pack/v1/fixtures/valid/rp-001.yaml"
      |> File.read!()
      |> YamlElixir.read_from_string!()

    assert :ok = Validator.validate(:research_pack, doc)
  end

  test "an invalid document is a typed invalid_artifact, never a generic success" do
    assert {:error, {:invalid_artifact, :research_pack, errors}} =
             Validator.validate(:research_pack, %{"id" => "RP-001"})

    assert is_list(errors) and errors != []
  end

  test "an unknown kind is a typed unknown_contract failure" do
    assert {:error, {:unknown_contract, :no_such_kind}} = Validator.validate(:no_such_kind, %{})
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/kapelle/product/validator_test.exs`
Expected: FAIL — modules not defined.

- [ ] **Step 3: Implement the registry**

```elixir
defmodule Kapelle.Product.Contracts do
  @moduledoc """
  Registry of the seven vendored impresario contract schemas (design doc §7).
  Reads only the vendored bytes under `contracts/impresario/` — never the
  neighbouring impresario checkout. Schemas declare JSON Schema 2020-12 but
  use only draft-compatible keywords; the `$schema` member is stripped
  before resolving (characterized in schema_compat_test.exs; the fixture
  parity suite guards the assumption against upstream keyword drift).
  """

  @vendor_root "contracts/impresario"

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
  def dir!(kind), do: Path.join([@vendor_root, Map.fetch!(@kind_dirs, kind), "v1"])

  @spec fetch_schema(atom()) :: {:ok, ExJsonSchema.Schema.Root.t()} | {:error, {:unknown_contract, term()}}
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
```

- [ ] **Step 4: Implement the validator**

```elixir
defmodule Kapelle.Product.Validator do
  @moduledoc """
  Typed validation of product documents against the vendored schemas.
  An unknown kind or an invalid document is a typed failure, never a
  generic success (design doc §3, invariant 4).
  """

  alias Kapelle.Product.Contracts

  @spec validate(atom(), map()) ::
          :ok
          | {:error, {:invalid_artifact, atom(), list()}}
          | {:error, {:unknown_contract, term()}}
  def validate(kind, doc) when is_map(doc) do
    with {:ok, schema} <- Contracts.fetch_schema(kind) do
      case ExJsonSchema.Validator.validate(schema, doc) do
        :ok -> :ok
        {:error, errors} -> {:error, {:invalid_artifact, kind, errors}}
      end
    end
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/kapelle/product/validator_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/kapelle/product/contracts.ex lib/kapelle/product/validator.ex test/kapelle/product/validator_test.exs
git commit -m "feat: Kapelle.Product schema registry and typed validator over vendored contracts"
```

### Task 5: Typed records, YAML loader, and the fixture-parity suite

**Files:**
- Create: `lib/kapelle/product/record.ex`
- Create: `lib/kapelle/product/loader.ex`
- Test: `test/kapelle/product/fixture_parity_test.exs`

**Interfaces:**
- Produces:
  - `Kapelle.Product.Record` struct: `%Record{kind, id, doc}` — `kind :: atom()`, `id :: String.t() | nil`, `doc :: map()` (the full validated document). S2 adds hashing/refs on top; S1 deliberately carries identity + validated payload only (YAGNI — per-field typing grows per consumer need).
  - `Kapelle.Product.Loader.load(kind, yaml :: binary()) :: {:ok, Record.t()} | {:error, {:invalid_artifact, atom(), list()}} | {:error, {:unknown_contract, term()}} | {:error, {:unparseable, term()}}`

- [ ] **Step 1: Write the failing fixture-parity test**

Every valid fixture of every kind must load into a record; every invalid fixture must produce the typed error. This is the suite that also guards the `$schema`-strip assumption from Task 1.

```elixir
defmodule Kapelle.Product.FixtureParityTest do
  use ExUnit.Case, async: true

  alias Kapelle.Product.{Contracts, Loader, Record}

  for kind <- ~w(idea research_pack concept_draft product_proposal exchange_log loop_state gate_decision)a do
    describe "#{kind} fixtures" do
      test "every valid fixture loads into a typed record" do
        dir = Path.join(Contracts.dir!(unquote(kind)), "fixtures/valid")

        for path <- Path.wildcard(Path.join(dir, "*.yaml")) do
          assert {:ok, %Record{kind: unquote(kind), doc: doc} = record} =
                   Loader.load(unquote(kind), File.read!(path)),
                 "expected #{path} to load"

          assert is_map(doc)
          if Map.has_key?(doc, "id"), do: assert(record.id == doc["id"])
        end
      end

      test "every invalid fixture is a typed invalid_artifact" do
        dir = Path.join(Contracts.dir!(unquote(kind)), "fixtures/invalid")

        for path <- Path.wildcard(Path.join(dir, "*.yaml")) do
          assert {:error, {:invalid_artifact, unquote(kind), _errors}} =
                   Loader.load(unquote(kind), File.read!(path)),
                 "expected #{path} to be rejected"
        end
      end
    end
  end

  test "unparseable YAML is a typed unparseable error, not a crash" do
    assert {:error, {:unparseable, _}} = Loader.load(:idea, ": : definitely not yaml : :")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/kapelle/product/fixture_parity_test.exs`
Expected: FAIL — `Loader`/`Record` not defined.

- [ ] **Step 3: Implement record and loader**

```elixir
defmodule Kapelle.Product.Record do
  @moduledoc """
  A validated product document of one of the seven vendored kinds
  (design doc §7). Carries identity plus the full validated document;
  per-field typing grows per consumer need in later slices.
  """

  @enforce_keys [:kind, :doc]
  defstruct [:kind, :id, :doc]

  @type t :: %__MODULE__{kind: atom(), id: String.t() | nil, doc: map()}
end

defmodule Kapelle.Product.Loader do
  @moduledoc """
  YAML → validated `Kapelle.Product.Record`. Validation happens before any
  record exists: there is no way to hold an invalid document in a typed
  record (design doc §3, invariant 4).
  """

  alias Kapelle.Product.{Record, Validator}

  @spec load(atom(), binary()) ::
          {:ok, Record.t()}
          | {:error, {:invalid_artifact, atom(), list()}}
          | {:error, {:unknown_contract, term()}}
          | {:error, {:unparseable, term()}}
  def load(kind, yaml) when is_binary(yaml) do
    with {:ok, doc} <- parse(yaml),
         :ok <- Validator.validate(kind, doc) do
      {:ok, %Record{kind: kind, id: doc["id"], doc: doc}}
    end
  end

  defp parse(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, doc} when is_map(doc) -> {:ok, doc}
      {:ok, other} -> {:error, {:unparseable, {:not_a_document, other}}}
      {:error, reason} -> {:error, {:unparseable, reason}}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/kapelle/product/fixture_parity_test.exs`
Expected: PASS. If any *valid* fixture fails validation here, that is the Task 1 assumption breaking on real data — stop and report rather than loosening the schema or the fixture.

- [ ] **Step 5: Run the full suite, format, credo**

Run: `mix test && mix format --check-formatted && mix credo --strict`
Expected: all green; credo findings unchanged from master baseline.

- [ ] **Step 6: Commit**

```bash
git add lib/kapelle/product/record.ex lib/kapelle/product/loader.ex test/kapelle/product/fixture_parity_test.exs
git commit -m "feat: typed Record + YAML Loader with full fixture-parity coverage over all seven kinds"
```

### Task 6: The no-runtime-reference guard

**Files:**
- Test: `test/kapelle/product/boundary_guard_test.exs`

**Interfaces:**
- Consumes: nothing; guards spec §3 invariant 6 / §8 S1 exit ("zero runtime references to impresario").

- [ ] **Step 1: Write the guard test**

```elixir
defmodule Kapelle.Product.BoundaryGuardTest do
  use ExUnit.Case, async: true

  @forbidden [~r/\.\.\/impresario/, ~r/_cowork_output/, ~r/labs\/(all_ai_orchestrators\/)?impresario/]

  test "no runtime module references the impresario checkout or _cowork_output" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        source = File.read!(path)
        Enum.any?(@forbidden, &Regex.match?(&1, source))
      end)

    assert offenders == [],
           "runtime files referencing the producer checkout: #{inspect(offenders)}"
  end
end
```

- [ ] **Step 2: Run it**

Run: `mix test test/kapelle/product/boundary_guard_test.exs`
Expected: PASS immediately (nothing under `lib/` references those paths; the re-vendor script lives in `scripts/`, which the glob does not cover — by design).

- [ ] **Step 3: Commit**

```bash
git add test/kapelle/product/boundary_guard_test.exs
git commit -m "test: boundary guard — runtime never references the impresario checkout"
```

### Task 7: Upstream drift watch (guarantee B)

**Files:**
- Create: `.github/workflows/impresario-contract-drift.yml`

**Interfaces:**
- Consumes: PIN format (producer path from the `source:` line) and vendored bytes.
- Produces: a scheduled red/green signal, plus a `workflow_dispatch` with `synthetic=drift` for controlled-failure acceptance (the steward pattern; acceptance is by observed runs post-merge, never by merge).

- [ ] **Step 1: Write the workflow**

```yaml
name: impresario-contract-drift
# Guarantee B (two-contract-guarantees): does the producer's contract
# surface still match our vendored bytes? Copy-integrity (guarantee A)
# lives in the test suite; this watch compares against upstream HEAD on a
# schedule. Scheduled observation only — NEVER a required PR check.

on:
  schedule:
    - cron: "10 6 * * *"
  workflow_dispatch:
    inputs:
      synthetic:
        description: "set to 'drift' to verify the red path on a controlled mutation"
        required: false
        default: ""

jobs:
  drift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/checkout@v4
        with:
          repository: andrei-shtanakov/impresario
          path: .upstream
      - name: synthetic drift (controlled red path)
        if: ${{ github.event.inputs.synthetic == 'drift' }}
        run: echo "# synthetic" >> .upstream/contracts/idea/v1/schema.json
      - name: compare vendored copies to upstream HEAD
        run: |
          status=0
          for pin in contracts/impresario/*/v1/PIN; do
            dir="$(dirname "$pin")"
            src="$(grep '^source:' "$pin" | sed -E 's/^source: impresario@[0-9a-f]+ //')"
            if ! diff -r --exclude=PIN "$dir" ".upstream/$src" > /dev/null 2>&1; then
              echo "::warning::drift: $dir vs upstream $src"
              status=1
            fi
          done
          if [ "$status" -ne 0 ]; then
            echo "Upstream contract surface moved — plan a re-vendor (scripts/revendor_impresario.sh)."
            exit 1
          fi
          echo "clean: vendored bytes match upstream HEAD"
```

- [ ] **Step 2: Validate the YAML locally**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/impresario-contract-drift.yml")' 2>/dev/null || python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/impresario-contract-drift.yml'))"`
Expected: exits 0.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/impresario-contract-drift.yml
git commit -m "ci: scheduled impresario contract drift watch with synthetic-drift dispatch"
```

- [ ] **Step 4: Record the acceptance debt**

Add to the PR description (Task 8): acceptance of this watch is by observed runs post-merge — one `workflow_dispatch synthetic=drift` red on the compare step, one clean dispatch, one scheduled run — mirroring the steward `impresario-contract-drift.yml` acceptance of 2026-08-13. Not a checkbox that merge can tick.

### Task 8: Docs stitch and the PR

**Files:**
- Modify: `docs/superpowers/specs/2026-08-14-product-context-design.md` (status line only)
- Create: `docs/superpowers/plans/2026-08-14-product-s1-vendoring-skeleton.md` (this plan — already on the branch)

**Interfaces:** none (documentation + delivery).

- [ ] **Step 1: Mark S1 in the design doc status line**

In the design doc, change the `Status:` line to append: `S1 implementation: docs/superpowers/plans/2026-08-14-product-s1-vendoring-skeleton.md.`

- [ ] **Step 2: Full verification**

Run: `mix test && mix format --check-formatted && mix credo --strict`
Expected: all green (≈ master baseline + ~12 new tests).

- [ ] **Step 3: Commit and open the PR**

```bash
git add -A
git commit -m "docs: link the S1 plan from the design doc"
git push -u origin plan/product-s1-vendoring-skeleton
gh pr create --title "Kapelle.Product S1: seven vendored impresario contracts + typed skeleton" \
  --body "S1 of the airun-M3 arc per docs/superpowers/specs/2026-08-14-product-context-design.md §7/§8. Vendors the seven contracts at impresario@f84d5ac5a2ae (atomic script, per-file PINs, anti-mix test), adds the Kapelle.Product skeleton (registry, typed validator, Record+Loader with full fixture parity), the runtime boundary guard, and the scheduled drift watch (acceptance by observed runs post-merge: synthetic=drift red, clean dispatch, first cron). Exit gates of S1: seven vendored, one pin, schema/fixture parity, zero runtime references — all covered by tests in this PR."
```

- [ ] **Step 4: Handle Copilot review, hand to human merge**

Per repo rules: read Copilot's review, fix valid remarks with new commits, rebut invalid ones with reasoning; the human merges.

## Self-Review

- **Spec coverage (S1 scope)**: seven contracts one snapshot (T3), anti-mix (T2), copy-integrity (T2), atomic re-vendor script (T3), drift watch + synthetic path (T7), schema loading (T4), typed validation incl. unknown-contract invariant (T4), typed records (T5), fixture parity (T5), zero runtime references (T6, glob covers `lib/` only — script exempt by design), gate-decision form-only (falls out of T4/T5: validation without interpretation). Out of S1 scope by spec: artifact store, hashing, events, next-stage (S2); workers (S3); resume policy (S4, blocked on impresario#14).
- **Placeholders**: none — every step carries code or an exact command.
- **Type consistency**: `Contracts.kinds/0`, `dir!/1`, `fetch_schema/1`, `schema!/1` used in T4/T5 tests as defined; `Validator.validate/2` error shapes identical in T4 and T5; `Record` fields `kind/id/doc` consistent; PIN grammar in T2's parser matches T3's writer (incl. 12-hex short sha satisfying `[0-9a-f]{7,40}`).
