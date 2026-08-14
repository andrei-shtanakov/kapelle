# Kapelle.Product S2 — State & Oracle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The immutable artifact store with impresario-exact canonical hashing, the identity-only event, the canonical artifact view with its pure next-stage function, and parity-harness v0 with a provenance-carrying golden set.

**Architecture:** Everything stays inside the `Kapelle.Product` bounded context. Authority is the validated artifact set: `Store.put/1` persists immutable rows keyed by per-kind identity with no-op/conflict semantics on the canonical hash; `Event` is published only after the transactional commit; `View.build/1` validates the whole loop's artifacts fail-closed and `NextStage.compute/1` is a pure function over that view, porting the reference loop's stage progression and deterministic evaluator. The oracle side ports `canonical_doc_hash` byte-for-byte (proven by cross-language fixtures generated from the pinned producer), and normalizer v1 reduces reference traces to domain observations for parity.

**Tech Stack:** Elixir/Ecto/Postgres (existing), Jason (`objects: :ordered_objects` for duplicate-key detection in JSON), yamerl `detailed_constr` (duplicate-key detection in YAML), python3 (test-tooling only, runs the pinned producer's `hashing.py` and reference runner).

**Spec:** `docs/superpowers/specs/2026-08-14-product-context-design.md` (§3 invariants, §5 state model, §6 golden oracle, §8 S2 exit gates) **plus the owner's S2 preamble of 2026-08-14** (six carry-forward resolutions — restated as Global Constraints below).

## Global Constraints

- Canonical hash must be the producer's exact algorithm (`src/impresario/hashing.py:10` at the pin): JSON with recursively sorted keys, `separators=(",", ":")`, unicode preserved (`ensure_ascii=False`), SHA-256, `"sha256:<64 lowercase hex>"`. Never an approximate analogue.
- Duplicate keys (YAML or JSON) are a typed validation failure **before** hashing — a parser that silently drops a duplicate must never feed the hasher.
- Identity per kind is a fixed table, never `doc["id"]` guessing, never a path or random UUID: `idea→id`, `research_pack→id`, `concept_draft→id`, `exchange_log→id`, `product_proposal→proposal_id`, `loop_state→loop_id`, `gate_decision→decision_id`. Immutable identity is distinct from the idempotency key `(loop_id, iteration, stage, input_hash)` (the latter is S3's; S2 only must not conflate them).
- Production/release loads vendored schemas via `Application.app_dir(:kapelle, "priv/...")`; CWD-relative paths are allowed only in dev tooling and re-vendor tests.
- Store semantics: identical identity + identical canonical hash → no-op; identical identity + different hash → typed conflict; artifact write and authoritative commit are one transactional boundary; no event before a successful commit.
- Canonical view distinguishes frontier absence from an internal sequence hole; invalid/conflicting/hash-mismatched artifacts fail closed; `loop_state` is a projection and never determines next stage; `gate_decision` is stored but authorizes nothing (resume blocked on impresario#14).
- Oracle: the pinned impresario is reachable only from test tooling (`scripts/`, extracted via `git archive` at `f84d5ac5a2aea1e95f9a52f5a266cf37f42f1fd1`); raw traces are kept with provenance; the normalizer is versioned and deterministic; golden update is an explicit command, never an auto-rewrite; parity compares normalized domain observations.
- The seven-contract vendored set and its PIN/anti-mix/copy-integrity tests must keep passing byte-identically through the priv/ move (only paths change, никогда bytes).
- `mix format --check-formatted` clean; `mix credo --strict` findings unchanged from baseline (4 pre-existing in old files); no network in tests; nothing under `lib/kapelle/orchestrator/` may change; PR review by human + Copilot; the tool never touches `master`.

---

### Task 1: Per-kind identity

**Files:**
- Create: `lib/kapelle/product/identity.ex`
- Modify: `lib/kapelle/product/record.ex` (docs only), `lib/kapelle/product/loader.ex:18`
- Test: `test/kapelle/product/identity_test.exs`, modify `test/kapelle/product/fixture_parity_test.exs`

**Interfaces:**
- Produces: `Kapelle.Product.Identity.field(kind :: atom()) :: String.t()` and `Kapelle.Product.Identity.of(kind, doc :: map()) :: {:ok, String.t()} | {:error, {:missing_identity, kind, field :: String.t()}}`. `Loader` populates `Record.id` via `Identity.of/2`; a valid document can no longer yield a nil id (all seven schemas require their identity field).

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Kapelle.Product.IdentityTest do
  use ExUnit.Case, async: true

  alias Kapelle.Product.Identity

  @table %{
    idea: "id",
    research_pack: "id",
    concept_draft: "id",
    exchange_log: "id",
    product_proposal: "proposal_id",
    loop_state: "loop_id",
    gate_decision: "decision_id"
  }

  test "the identity field table covers exactly the seven kinds" do
    for {kind, field} <- @table, do: assert(Identity.field(kind) == field)
  end

  test "of/2 extracts the identity value" do
    assert {:ok, "PP-101"} = Identity.of(:product_proposal, %{"proposal_id" => "PP-101"})
    assert {:ok, "LOOP-101"} = Identity.of(:loop_state, %{"loop_id" => "LOOP-101"})
    assert {:ok, "GD-001"} = Identity.of(:gate_decision, %{"decision_id" => "GD-001"})
    assert {:ok, "RP-001"} = Identity.of(:research_pack, %{"id" => "RP-001"})
  end

  test "a document missing its identity field is a typed failure, not nil" do
    assert {:error, {:missing_identity, :loop_state, "loop_id"}} =
             Identity.of(:loop_state, %{"id" => "not-the-identity"})
  end
end
```

- [ ] **Step 2: Run to verify failure** — `mix test test/kapelle/product/identity_test.exs` → FAIL (module undefined).

- [ ] **Step 3: Implement**

```elixir
defmodule Kapelle.Product.Identity do
  @moduledoc """
  The per-kind identity table (owner's S2 preamble, item 2). Identity comes
  from the document's own identity field — never from a file path, never a
  generated UUID. Distinct from S3's idempotency key
  `(loop_id, iteration, stage, input_hash)`.
  """

  @fields %{
    idea: "id",
    research_pack: "id",
    concept_draft: "id",
    exchange_log: "id",
    product_proposal: "proposal_id",
    loop_state: "loop_id",
    gate_decision: "decision_id"
  }

  @spec field(atom()) :: String.t()
  def field(kind), do: Map.fetch!(@fields, kind)

  @spec of(atom(), map()) ::
          {:ok, String.t()} | {:error, {:missing_identity, atom(), String.t()}}
  def of(kind, doc) when is_map(doc) do
    field = field(kind)

    case doc do
      %{^field => id} when is_binary(id) -> {:ok, id}
      _ -> {:error, {:missing_identity, kind, field}}
    end
  end
end
```

- [ ] **Step 4: Wire the loader** — in `lib/kapelle/product/loader.ex` replace `{:ok, %Record{kind: kind, id: doc["id"], doc: doc}}` with:

```elixir
    with {:ok, doc} <- parse(yaml),
         :ok <- Validator.validate(kind, doc),
         {:ok, id} <- Identity.of(kind, doc) do
      {:ok, %Record{kind: kind, id: id, doc: doc}}
    end
```

(add `alias Kapelle.Product.Identity`; extend the `@spec` return union with `| {:error, {:missing_identity, atom(), String.t()}}`).

- [ ] **Step 5: Strengthen the parity suite** — in `test/kapelle/product/fixture_parity_test.exs`, replace the guarded identity assertion (`if Map.has_key?(doc, "id"), do: ...`) with an unconditional one:

```elixir
          assert is_binary(record.id) and record.id != "",
                 "#{path}: Record.id must come from the kind's identity field"
```

- [ ] **Step 6: Run** — `mix test test/kapelle/product/identity_test.exs test/kapelle/product/fixture_parity_test.exs` → PASS (identity now asserted for all seven kinds, non-vacuously).

- [ ] **Step 7: Commit** — `git add -A && git commit -m "feat: per-kind identity table; Record.id never nil for a valid artifact"`

### Task 2: Vendored contracts move to priv/, schema loading via app_dir

**Files:**
- Move: `contracts/impresario/` → `priv/contracts/impresario/` (`git mv`)
- Modify: `lib/kapelle/product/contracts.ex` (`@vendor_root`, path resolution), `scripts/revendor_impresario.sh` (DEST), `test/contracts/vendored_impresario_test.exs` (`@vendor_root`), `test/kapelle/product/fixture_parity_test.exs` (fixture dirs come from `Contracts.dir!/1` — verify, no hardcoded paths), `.github/workflows/impresario-contract-drift.yml` (PIN glob path)
- Test: `test/kapelle/product/schema_cwd_independence_test.exs`

**Interfaces:**
- Produces: `Contracts.dir!/1` returns an ABSOLUTE path rooted at `Application.app_dir(:kapelle, "priv/contracts/impresario")`; everything downstream (Task 1 suite, S1 suites) keeps passing with bytes unchanged.

- [ ] **Step 1: Write the CWD-independence test (failing)**

```elixir
defmodule Kapelle.Product.SchemaCwdIndependenceTest do
  use ExUnit.Case, async: false

  alias Kapelle.Product.{Contracts, Validator}

  # Owner's S2 preamble, item 3: production loads schemas via
  # Application.app_dir; this test proves loading works when the OS CWD is
  # NOT the repo root. priv/ is packaged into releases by construction —
  # a full `mix release` smoke is deferred until the repo grows a release
  # config (controller ruling recorded in the plan).
  test "schemas resolve and validate with the process CWD outside the repo" do
    tmp = System.tmp_dir!()
    old = File.cwd!()

    try do
      File.cd!(tmp)
      assert %ExJsonSchema.Schema.Root{} = Contracts.schema!(:idea)

      assert {:error, {:invalid_artifact, :idea, _}} =
               Validator.validate(:idea, %{"nonsense" => true})
    after
      File.cd!(old)
    end
  end
end
```

Note: `Contracts.schema!/1` caches in `:persistent_term` — the test must exercise a kind not yet cached by earlier tests in the same VM, or clear the cache first: add `:persistent_term.erase({Kapelle.Product.Contracts, :idea})` before the assertion.

- [ ] **Step 2: Run to verify it fails** — with CWD moved, the relative `contracts/impresario/...` read raises `File.Error` → the test fails as expected.

- [ ] **Step 3: Move and rewire**

```bash
git mv contracts/impresario priv/contracts/impresario
```

In `lib/kapelle/product/contracts.ex` replace `@vendor_root "contracts/impresario"` and `dir!/1` with:

```elixir
  @vendor_subdir "priv/contracts/impresario"

  @spec dir!(atom()) :: String.t()
  def dir!(kind) do
    Path.join([Application.app_dir(:kapelle, @vendor_subdir) |> strip_app_dir_fallback(), Map.fetch!(@kind_dirs, kind), "v1"])
  end
```

**Correction (keep it simple):** `Application.app_dir/2` works in test/dev too (`_build/.../lib/kapelle/priv/...` — priv is symlinked by Mix). No fallback needed; use exactly:

```elixir
  @vendor_subdir "priv/contracts/impresario"

  @spec dir!(atom()) :: String.t()
  def dir!(kind) do
    Path.join([Application.app_dir(:kapelle, @vendor_subdir), Map.fetch!(@kind_dirs, kind), "v1"])
  end
```

In `scripts/revendor_impresario.sh` change `DEST="$ROOT/contracts/impresario"` to `DEST="$ROOT/priv/contracts/impresario"` (operator tooling stays CWD-relative to the repo — allowed by the preamble).

In `test/contracts/vendored_impresario_test.exs` change `@vendor_root Path.join(File.cwd!(), "contracts/impresario")` to `"priv/contracts/impresario"` (this test IS repo-rooted dev tooling — allowed).

In `.github/workflows/impresario-contract-drift.yml` change `for pin in contracts/impresario/*/v1/PIN` to `for pin in priv/contracts/impresario/*/v1/PIN`.

- [ ] **Step 4: Verify everything** — `mix test` (full suite green; S1 copy-integrity/anti-mix/parity all pass on the moved bytes — `git mv` preserves them), plus the new CWD test passes. `git diff --stat HEAD -- 'priv/contracts'` must show only renames (100% similarity), zero content changes.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: vendored contracts live in priv/, schemas load via Application.app_dir"`

### Task 3: Duplicate-key detection before hashing

**Files:**
- Create: `lib/kapelle/product/strict_parse.ex`
- Modify: `lib/kapelle/product/loader.ex` (parse goes through StrictParse)
- Test: `test/kapelle/product/strict_parse_test.exs`

**Interfaces:**
- Produces: `Kapelle.Product.StrictParse.parse(binary()) :: {:ok, map()} | {:error, {:duplicate_key, key :: String.t()}} | {:error, {:unparseable, term()}}` — detects duplicate keys at ANY nesting depth in both YAML and JSON input before returning a map. `Loader.load/2` uses it, so no duplicate-keyed document can reach validation or hashing.

- [ ] **Step 1: Write the characterization + behavior tests (failing)**

```elixir
defmodule Kapelle.Product.StrictParseTest do
  use ExUnit.Case, async: true

  alias Kapelle.Product.StrictParse

  test "clean YAML parses to a map" do
    assert {:ok, %{"a" => 1, "b" => %{"c" => "x"}}} =
             StrictParse.parse("a: 1\nb:\n  c: x\n")
  end

  test "duplicate top-level YAML key is a typed failure" do
    assert {:error, {:duplicate_key, "a"}} = StrictParse.parse("a: 1\na: 2\n")
  end

  test "duplicate nested YAML key is a typed failure" do
    assert {:error, {:duplicate_key, "c"}} =
             StrictParse.parse("b:\n  c: 1\n  c: 2\n")
  end

  test "clean JSON parses to a map" do
    assert {:ok, %{"a" => 1}} = StrictParse.parse(~s({"a": 1}))
  end

  test "duplicate JSON key (any depth) is a typed failure" do
    assert {:error, {:duplicate_key, "a"}} = StrictParse.parse(~s({"a": 1, "a": 2}))
    assert {:error, {:duplicate_key, "c"}} = StrictParse.parse(~s({"b": {"c": 1, "c": 2}}))
  end

  test "garbage is unparseable, not a crash" do
    assert {:error, {:unparseable, _}} = StrictParse.parse(": : nope : :")
  end
end
```

- [ ] **Step 2: Run to verify failure**, then implement. JSON path: `Jason.decode(input, objects: :ordered_objects)` gives `Jason.OrderedObject` values whose `.values` is a keyword-style pair list preserving duplicates — walk it recursively; if any object's keys contain a duplicate, return it, else convert to plain maps. YAML path: `:yamerl_constr.string(input, detailed_constr: true)` gives node records; mappings are tuples tagged `:yamerl_map` whose pair list preserves duplicates; scalars are `:yamerl_str`/`:yamerl_int`/`:yamerl_bool`/`:yamerl_null`/etc.

```elixir
defmodule Kapelle.Product.StrictParse do
  @moduledoc """
  Parsing that refuses documents with duplicate keys at any depth (owner's
  S2 preamble, item 1: duplicate keys are a validation failure BEFORE
  hashing — a parser that silently drops one must never feed the hasher).
  Accepts YAML and JSON (JSON first: it is a YAML subset, but Jason's
  ordered-object decode preserves duplicate pairs, which yamerl's plain
  constructor would not).
  """

  @spec parse(binary()) ::
          {:ok, map()}
          | {:error, {:duplicate_key, String.t()}}
          | {:error, {:unparseable, term()}}
  def parse(input) when is_binary(input) do
    case Jason.decode(input, objects: :ordered_objects) do
      {:ok, decoded} -> from_json(decoded)
      {:error, _not_json} -> parse_yaml(input)
    end
  end

  defp from_json(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, fn {k, _v} -> k end)

    case keys -- Enum.uniq(keys) do
      [dup | _] ->
        {:error, {:duplicate_key, dup}}

      [] ->
        Enum.reduce_while(pairs, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
          case from_json(v) do
            {:ok, converted} -> {:cont, {:ok, Map.put(acc, k, converted)}}
            error -> {:halt, error}
          end
        end)
    end
  end

  defp from_json(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case from_json(item) do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp from_json(scalar), do: {:ok, scalar}

  defp parse_yaml(input) do
    case :yamerl_constr.string(String.to_charlist(input), detailed_constr: true) do
      [doc] -> from_yamerl(doc)
      [] -> {:error, {:unparseable, :empty}}
      docs when is_list(docs) -> {:error, {:unparseable, {:multiple_documents, length(docs)}}}
    end
  rescue
    e -> {:error, {:unparseable, e}}
  catch
    :throw, e -> {:error, {:unparseable, e}}
  end

  # yamerl detailed records are Erlang tuples; the tag is element 1 and the
  # payload positions are stable per yamerl's include/yamerl_nodes.hrl.
  # The characterization tests in this file are the contract: if a yamerl
  # upgrade shifts a position, these matchers fail loudly, never silently.
  defp from_yamerl(node) when elem(node, 0) == :yamerl_doc, do: from_yamerl(elem(node, 1))

  defp from_yamerl(node) when elem(node, 0) == :yamerl_map do
    pairs = elem(node, tuple_size(node) - 1)
    keys = Enum.map(pairs, fn {k, _v} -> scalar_key(k) end)

    case keys -- Enum.uniq(keys) do
      [dup | _] ->
        {:error, {:duplicate_key, dup}}

      [] ->
        Enum.reduce_while(pairs, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
          case from_yamerl(v) do
            {:ok, converted} -> {:cont, {:ok, Map.put(acc, scalar_key(k), converted)}}
            error -> {:halt, error}
          end
        end)
    end
  end

  defp from_yamerl(node) when elem(node, 0) == :yamerl_seq do
    node
    |> elem(tuple_size(node) - 2)
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case from_yamerl(item) do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp from_yamerl(node) when elem(node, 0) == :yamerl_null, do: {:ok, nil}
  defp from_yamerl(node), do: {:ok, yamerl_scalar(node)}

  defp scalar_key(node), do: node |> yamerl_scalar() |> to_string()

  defp yamerl_scalar(node) do
    case elem(node, tuple_size(node) - 1) do
      text when is_list(text) -> List.to_string(text)
      other -> other
    end
  end
end
```

**IMPORTANT for the implementer:** the yamerl record positions above are a best-effort transcription. Step 3 exists to correct them empirically: run `:yamerl_constr.string(~c"a: 1\nb: [x]\nn: ~\n", detailed_constr: true) |> IO.inspect(limit: :infinity)` in `iex -S mix`, paste the real structure into your report, and adjust the matchers until the tests in Step 1 pass. Do NOT weaken the tests to fit the code.

- [ ] **Step 3: Characterize yamerl's detailed structure and fix the matchers** (see note above). Re-run the test file until PASS.

- [ ] **Step 4: Route the Loader through StrictParse** — in `loader.ex`, replace the `parse/1` private function body with a call to `StrictParse.parse/1`, mapping `{:error, {:duplicate_key, k}}` into the typed validation failure BEFORE hashing/validation:

```elixir
  defp parse(yaml) do
    case StrictParse.parse(yaml) do
      {:ok, doc} when is_map(doc) -> {:ok, doc}
      {:ok, other} -> {:error, {:unparseable, {:not_a_document, other}}}
      {:error, {:duplicate_key, _}} = error -> error
      {:error, {:unparseable, _}} = error -> error
    end
  end
```

Extend `Loader.load/2`'s `@spec` with `| {:error, {:duplicate_key, String.t()}}`. Add one loader-level test: `Loader.load(:idea, "id: A\nid: B\n")` → `{:error, {:duplicate_key, "id"}}`.

- [ ] **Step 5: Full suite + format** — `mix test && mix format --check-formatted` → green (fixture parity unaffected: no vendored fixture has duplicates — if one fails here, STOP and report, that's an upstream data finding).

- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: strict parse — duplicate keys are typed failures before hashing"`

### Task 4: Canonical hash, byte-for-byte, proven cross-language

**Files:**
- Create: `lib/kapelle/product/canonical_hash.ex`, `scripts/gen_hash_fixtures.sh`, `test/support/fixtures/canonical_hash/cases.json` (generated, committed), `test/support/fixtures/canonical_hash/PROVENANCE`
- Test: `test/kapelle/product/canonical_hash_test.exs`

**Interfaces:**
- Produces: `Kapelle.Product.CanonicalHash.hash(map()) :: String.t()` returning `"sha256:<64hex>"`, byte-compatible with the producer's `canonical_doc_hash`.

- [ ] **Step 1: Write the generation script** (test tooling; extracts the pinned producer's hashing module via `git archive`, никогда working tree):

```bash
#!/usr/bin/env bash
# Generate cross-language canonical-hash fixtures from the PINNED producer.
# Usage: scripts/gen_hash_fixtures.sh <path-to-impresario-checkout>
# Test tooling only: runtime never touches the producer (design doc §3 inv.6).
set -euo pipefail

IMPRESARIO="${1:?path to impresario checkout}"
COMMIT="f84d5ac5a2aea1e95f9a52f5a266cf37f42f1fd1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/test/support/fixtures/canonical_hash"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git -C "$IMPRESARIO" archive "$COMMIT" src/impresario/hashing.py | tar -x -C "$TMP"

python3 - "$TMP/src/impresario" > "$OUT/cases.json" <<'PYEOF'
import json, sys
sys.path.insert(0, sys.argv[1])
from hashing import canonical_doc_hash

# Owner's S2 preamble, item 1: reordered keys, whitespace-immaterial forms,
# Unicode, nested structures, numbers, booleans/null. Each case is the parsed
# document (order-insensitive by construction) plus the producer's hash.
cases = [
    {"name": "flat", "doc": {"b": 1, "a": 2}},
    {"name": "nested", "doc": {"z": {"y": [1, 2, {"x": "w"}]}, "a": None}},
    {"name": "unicode", "doc": {"ключ": "значение — π≈3.14159", "emoji": "🎼"}},
    {"name": "numbers", "doc": {"int": 42, "neg": -7, "float": 0.75, "one": 1.0, "big": 123456789012345}},
    {"name": "bools_null", "doc": {"t": True, "f": False, "n": None}},
    {"name": "strings_escapes", "doc": {"q": 'he said "hi"', "bs": "a\\b", "nl": "line1\nline2", "tab": "a\tb"}},
    {"name": "empty_shapes", "doc": {"m": {}, "l": [], "s": ""}},
    {"name": "realistic", "doc": {"id": "RP-001", "idea_ref": "idea://IDEA-001", "iteration": 0,
                                   "findings": [{"claim": "60% типовые", "confidence": "medium",
                                                 "source_ref": "https://example.org/x"}],
                                   "constraints": [], "gaps": ["нет данных по SLA"]}},
]
print(json.dumps(
    [{"name": c["name"], "doc": c["doc"], "hash": canonical_doc_hash(c["doc"])} for c in cases],
    ensure_ascii=False, indent=2, sort_keys=True))
PYEOF

{
  echo "producer: impresario@$COMMIT src/impresario/hashing.py (extracted via git archive)"
  echo "generated: $(date +%Y-%m-%d)"
  echo "generator: scripts/gen_hash_fixtures.sh (this file's sibling)"
  echo "sha256 cases.json: $(shasum -a 256 "$OUT/cases.json" | cut -d' ' -f1)"
} > "$OUT/PROVENANCE"

echo "wrote $OUT/cases.json + PROVENANCE"
```

- [ ] **Step 2: Run it** — `mkdir -p test/support/fixtures/canonical_hash && scripts/gen_hash_fixtures.sh /Users/Andrei_Shtanakov/labs/all_ai_orchestrators/impresario` → cases.json with 8 cases + PROVENANCE.

- [ ] **Step 3: Write the failing test**

```elixir
defmodule Kapelle.Product.CanonicalHashTest do
  use ExUnit.Case, async: true

  alias Kapelle.Product.CanonicalHash

  @cases "test/support/fixtures/canonical_hash/cases.json"
         |> File.read!()
         |> Jason.decode!()

  test "fixture set is non-trivial" do
    assert length(@cases) >= 8
  end

  for %{"name" => name} <- @cases do
    test "matches the producer's hash: #{name}" do
      %{"doc" => doc, "hash" => expected} = Enum.find(@cases, &(&1["name"] == unquote(name)))
      assert CanonicalHash.hash(doc) == expected
    end
  end

  test "key order of the input map is immaterial" do
    a = %{"b" => 1, "a" => %{"d" => 2, "c" => 3}}
    b = %{"a" => %{"c" => 3, "d" => 2}, "b" => 1}
    assert CanonicalHash.hash(a) == CanonicalHash.hash(b)
  end
end
```

- [ ] **Step 4: Run to verify failure**, then implement:

```elixir
defmodule Kapelle.Product.CanonicalHash do
  @moduledoc """
  Byte-exact port of the producer's `canonical_doc_hash`
  (impresario src/impresario/hashing.py at the pin): JSON with recursively
  sorted keys, compact separators, unicode preserved, SHA-256, prefixed
  "sha256:". Proven byte-compatible by the cross-language fixtures in
  test/support/fixtures/canonical_hash/ — regenerate them only via
  scripts/gen_hash_fixtures.sh (explicit, reviewable; never on test failure).
  """

  @spec hash(map()) :: String.t()
  def hash(doc) when is_map(doc) do
    canonical = doc |> encode() |> IO.iodata_to_binary()
    "sha256:" <> (:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower))
  end

  defp encode(map) when is_map(map) do
    inner =
      map
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn key -> [Jason.encode!(key), ":", encode(Map.fetch!(map, key))] end)
      |> Enum.intersperse(",")

    ["{", inner, "}"]
  end

  defp encode(list) when is_list(list) do
    ["[", list |> Enum.map(&encode/1) |> Enum.intersperse(","), "]"]
  end

  defp encode(scalar), do: Jason.encode!(scalar)
end
```

If any fixture case fails (float formatting and string escaping are the plausible offenders), STOP, record the exact byte divergence in your report, and escalate — the resolution is a documented normalization step, decided by the controller, never a silent fixture edit.

- [ ] **Step 5: Run** — the fixture tests pass byte-for-byte. `mix test && mix format --check-formatted` green.

- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: canonical_doc_hash port proven byte-compatible by producer-generated fixtures"`

### Task 5: The immutable artifact store and the post-commit event

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_product_artifacts.exs`, `lib/kapelle/product/records/artifact_row.ex`, `lib/kapelle/product/store.ex`, `lib/kapelle/product/event.ex`, `lib/kapelle/product/events.ex`
- Test: `test/kapelle/product/store_test.exs`

**Interfaces:**
- Produces:
  - `Kapelle.Product.Store.put(Record.t(), loop_id :: String.t()) :: {:ok, :inserted | :noop} | {:error, {:artifact_conflict, kind, id, existing_hash, new_hash}} | {:error, Ecto.Changeset.t()}`
  - `Kapelle.Product.Store.all(loop_id) :: [%{kind: atom(), id: String.t(), doc: map(), canonical_hash: String.t()}]`
  - `Kapelle.Product.Event` struct `%Event{loop_id, kind (e.g. :artifact_stored), artifact_kind, artifact_ref, artifact_hash, producer}`; `Kapelle.Product.Events.subscribe(loop_id)` / broadcast — broadcast happens ONLY after a successful insert commit, never on :noop, never on conflict.

- [ ] **Step 1: Migration**

```elixir
defmodule Kapelle.Repo.Migrations.CreateProductArtifacts do
  use Ecto.Migration

  def change do
    create table(:product_artifacts, primary_key: false) do
      add :loop_id, :string, null: false, primary_key: true
      add :kind, :string, null: false, primary_key: true
      add :identity, :string, null: false, primary_key: true
      add :canonical_hash, :string, null: false
      add :doc, :map, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end
  end
end
```

(Composite PK `(loop_id, kind, identity)` IS the immutable identity; no surrogate UUID — owner's preamble, item 2.)

- [ ] **Step 2: Write the failing store tests**

```elixir
defmodule Kapelle.Product.StoreTest do
  use Kapelle.DataCase, async: true

  alias Kapelle.Product.{Event, Events, Loader, Store}

  defp rp_record do
    {:ok, record} =
      Loader.load(
        :research_pack,
        File.read!(
          Path.join(
            Kapelle.Product.Contracts.dir!(:research_pack),
            "fixtures/valid/rp-001.yaml"
          )
        )
      )

    record
  end

  test "first put inserts and broadcasts one post-commit event" do
    :ok = Events.subscribe("LOOP-T1")
    assert {:ok, :inserted} = Store.put(rp_record(), "LOOP-T1")

    assert_receive %Event{
      loop_id: "LOOP-T1",
      kind: :artifact_stored,
      artifact_kind: :research_pack,
      artifact_ref: "research-pack://RP-001",
      artifact_hash: "sha256:" <> _
    }
  end

  test "identical identity + identical canonical hash is a no-op and NO event" do
    assert {:ok, :inserted} = Store.put(rp_record(), "LOOP-T2")
    :ok = Events.subscribe("LOOP-T2")
    assert {:ok, :noop} = Store.put(rp_record(), "LOOP-T2")
    refute_receive %Event{}, 200
  end

  test "identical identity + different hash is a typed conflict and NO event" do
    record = rp_record()
    assert {:ok, :inserted} = Store.put(record, "LOOP-T3")
    :ok = Events.subscribe("LOOP-T3")

    mutated = %{record | doc: Map.put(record.doc, "gaps", ["tampered"])}

    assert {:error, {:artifact_conflict, :research_pack, "RP-001", "sha256:" <> _, "sha256:" <> _}} =
             Store.put(mutated, "LOOP-T3")

    refute_receive %Event{}, 200
  end

  test "all/1 returns the loop's artifacts with typed kinds" do
    assert {:ok, :inserted} = Store.put(rp_record(), "LOOP-T4")
    assert [%{kind: :research_pack, id: "RP-001", doc: %{"id" => "RP-001"}}] = Store.all("LOOP-T4")
  end
end
```

- [ ] **Step 3: Run to verify failure**, then implement `ArtifactRow` (schema with composite key, `@primary_key false` + three `primary_key: true` fields, jsonb `doc`), `Event`/`Events` (struct + Phoenix.PubSub on `Kapelle.PubSub`, topic `"product:loop:<loop_id>"`), and `Store`:

```elixir
defmodule Kapelle.Product.Store do
  @moduledoc """
  The immutable artifact store (design doc §5; owner's S2 preamble item 4).
  put/2 is idempotent by canonical hash: identical bytes are a no-op,
  divergent bytes under the same identity are a typed conflict. The write
  IS the authoritative commit; the Event goes out only after it succeeds.
  """

  alias Kapelle.Product.{CanonicalHash, Event, Events, Identity, Record}
  alias Kapelle.Product.Records.ArtifactRow
  alias Kapelle.Repo

  @kind_refs %{
    idea: "idea",
    research_pack: "research-pack",
    concept_draft: "concept-draft",
    product_proposal: "proposal",
    exchange_log: "exchange-log",
    loop_state: "loop-state",
    gate_decision: "gate-decision"
  }

  @spec put(Record.t(), String.t()) ::
          {:ok, :inserted | :noop}
          | {:error, {:artifact_conflict, atom(), String.t(), String.t(), String.t()}}
          | {:error, Ecto.Changeset.t()}
  def put(%Record{kind: kind, id: id, doc: doc}, loop_id) when is_binary(loop_id) do
    hash = CanonicalHash.hash(doc)

    case Repo.get_by(ArtifactRow, loop_id: loop_id, kind: to_string(kind), identity: id) do
      %ArtifactRow{canonical_hash: ^hash} ->
        {:ok, :noop}

      %ArtifactRow{canonical_hash: existing} ->
        {:error, {:artifact_conflict, kind, id, existing, hash}}

      nil ->
        %ArtifactRow{}
        |> ArtifactRow.changeset(%{
          loop_id: loop_id,
          kind: to_string(kind),
          identity: id,
          canonical_hash: hash,
          doc: doc
        })
        |> Repo.insert()
        |> case do
          {:ok, _row} ->
            Events.broadcast(%Event{
              loop_id: loop_id,
              kind: :artifact_stored,
              artifact_kind: kind,
              artifact_ref: "#{@kind_refs[kind]}://#{id}",
              artifact_hash: hash,
              producer: nil
            })

            {:ok, :inserted}

          {:error, %Ecto.Changeset{} = changeset} ->
            # Insert race on the composite PK: re-read and reclassify —
            # the winner's bytes decide noop vs conflict.
            if pk_violation?(changeset) do
              put(%Record{kind: kind, id: id, doc: doc}, loop_id)
            else
              {:error, changeset}
            end
        end
    end
  end

  @spec all(String.t()) :: [%{kind: atom(), id: String.t(), doc: map(), canonical_hash: String.t()}]
  def all(loop_id) do
    import Ecto.Query, only: [from: 2]

    Repo.all(from(a in ArtifactRow, where: a.loop_id == ^loop_id, order_by: a.inserted_at))
    |> Enum.map(fn row ->
      %{
        kind: String.to_existing_atom(row.kind),
        id: row.identity,
        doc: row.doc,
        canonical_hash: row.canonical_hash
      }
    end)
  end

  defp pk_violation?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_msg, meta}} ->
      meta[:constraint] == :unique
    end)
  end
end
```

(ArtifactRow.changeset must include `unique_constraint(:identity, name: :product_artifacts_pkey)` so the race path lands in the changeset, mirroring the EvaluateWorker precedent. Identity.of/2 already ran in Loader; Store trusts Record.id.)

- [ ] **Step 4: Run** — store tests green; full suite green; format clean.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: immutable product artifact store with typed conflicts and post-commit events"`

### Task 6: The canonical artifact view

**Files:**
- Create: `lib/kapelle/product/view.ex`
- Test: `test/kapelle/product/view_test.exs`

**Interfaces:**
- Consumes: `Store.all/1` rows; `Validator.validate/2`; `CanonicalHash.hash/1`; `Identity.of/2`.
- Produces: `Kapelle.Product.View.build(loop_id) :: {:ok, %View{loop_id, idea, proposal, exchange_log, research_packs :: %{integer => map()}, concept_drafts :: %{integer => map()}, decisions :: [map()], loop_state :: map() | nil}} | {:error, {:artifact_invalid | :hash_mismatch | :identity_mismatch | :competing_artifacts | :impossible_sequence, term()}}` — the five-step validation of the design doc §5, fail-closed.

- [ ] **Step 1: Write the failing tests** — build them on Store + real fixtures; the key behaviors:

```elixir
defmodule Kapelle.Product.ViewTest do
  use Kapelle.DataCase, async: true

  alias Kapelle.Product.{Loader, Store, View}
  alias Kapelle.Product.Records.ArtifactRow
  alias Kapelle.Repo

  defp load!(kind, rel) do
    {:ok, record} =
      Loader.load(kind, File.read!(Path.join(Kapelle.Product.Contracts.dir!(kind), rel)))

    record
  end

  defp seed_happy(loop_id) do
    {:ok, _} = Store.put(load!(:idea, "fixtures/valid/idea-001.yaml"), loop_id)
    {:ok, _} = Store.put(load!(:research_pack, "fixtures/valid/rp-001.yaml"), loop_id)
    :ok
  end

  test "a consistent set builds a view keyed by iteration" do
    seed_happy("LOOP-V1")
    assert {:ok, view} = View.build("LOOP-V1")
    assert %{0 => %{"id" => "RP-001"}} = view.research_packs
    assert view.idea["id"]
    assert view.loop_state == nil
  end

  test "a stored row whose doc was corrupted post-hoc fails closed on hash mismatch" do
    seed_happy("LOOP-V2")

    row = Repo.get_by!(ArtifactRow, loop_id: "LOOP-V2", kind: "research-pack")
    corrupted = Map.put(row.doc, "gaps", ["tampered"])
    Repo.update_all(Ecto.Query.from(a in ArtifactRow, where: a.loop_id == "LOOP-V2" and a.kind == "research-pack"), set: [doc: corrupted])

    assert {:error, {:hash_mismatch, %{kind: :research_pack}}} = View.build("LOOP-V2")
  end

  test "a concept draft with no research pack of its iteration is an impossible sequence" do
    {:ok, _} = Store.put(load!(:idea, "fixtures/valid/idea-001.yaml"), "LOOP-V3")
    {:ok, _} = Store.put(load!(:concept_draft, "fixtures/valid/cd-001.yaml"), "LOOP-V3")
    assert {:error, {:impossible_sequence, _detail}} = View.build("LOOP-V3")
  end

  test "loop_state is carried as projection but its absence or presence never fails the view" do
    seed_happy("LOOP-V4")
    assert {:ok, %View{loop_state: nil}} = View.build("LOOP-V4")
  end
end
```

(Adjust fixture filenames to the vendored reality — `ls priv/contracts/impresario/<kind>/v1/fixtures/valid/` — and if `concept_draft`'s valid fixture declares iteration 0 while no rp-of-iteration-0 seeding is possible without the research pack, that IS the impossible-sequence case. If a needed combination cannot be built from vendored fixtures alone, construct the doc in the test by loading a valid fixture and asserting through Store — never invent unvalidated docs.)

- [ ] **Step 2: Run to verify failure**, then implement `View.build/1`:

1. `Store.all(loop_id)`; re-validate every doc against its schema (`Validator.validate/2` — a stored row is not trusted, design §5 step 2), re-check `Identity.of/2` matches the row identity, re-compute `CanonicalHash.hash/1` and compare to the stored `canonical_hash` (→ `{:hash_mismatch, %{kind, id}}`).
2. Group: exactly ≤1 idea, ≤1 product_proposal, ≤1 exchange_log, ≤1 loop_state; research_packs/concept_drafts keyed by `doc["iteration"]` — two artifacts of one kind+iteration → `{:competing_artifacts, ...}` (identity uniqueness is store-guaranteed, iteration collision is not).
3. Sequence check: for every iteration `i` present in `concept_drafts`, `research_packs[i]` must exist; iterations must be contiguous from 0 (a hole below the max present iteration → `{:impossible_sequence, ...}`). `loop_state`/`gate_decision` never participate (projection / stored-not-consumed).
4. Return the `%View{}` struct.

- [ ] **Step 3: Run** — green; full suite; format.
- [ ] **Step 4: Commit** — `git add -A && git commit -m "feat: canonical artifact view — validated, fail-closed, projection-blind"`

### Task 7: The pure next-stage function (reference semantics port)

**Files:**
- Create: `lib/kapelle/product/next_stage.ex`
- Test: `test/kapelle/product/next_stage_test.exs`

**Interfaces:**
- Consumes: `%View{}` from Task 6.
- Produces: `Kapelle.Product.NextStage.compute(View.t(), max_iterations :: pos_integer()) :: {:run, {:research | :concept | :apply, iteration :: non_neg_integer()}} | {:evaluate, iteration} | {:terminal, :ready | :needs_human, reason :: String.t()}` — the port of the reference loop's progression (impresario `loop.py:472-658` at the pin):

Reference semantics being ported (documented here so the implementer never reads the producer):
- iteration i: no research_pack(i) → `{:run, {:research, i}}`; else no concept_draft(i) → `{:run, {:concept, i}}`; else proposal's delta for i not applied (proposal.doc["iteration"] < i or refs missing) → `{:run, {:apply, i}}`; else evaluate.
- `evaluate(rp, cd, i, max)` is deterministic: `open_criticals(rp, cd)` = critical assumptions/gaps of the rp not addressed by the cd (port `loop.py:419-433`: an rp critical item is open unless the cd names it as addressed) plus `cd["requests_to_researcher"]`; none open → `{:terminal, :ready, "no open critical assumptions/gaps and no open requests"}`; open and `i + 1 < max` → next iteration (`{:run, {:research, i + 1}}`); open and last iteration → `{:terminal, :needs_human, "max_iterations reached with open critical items: ..."}`.

- [ ] **Step 1: Read the exact `open_criticals` logic from the vendored perspective** — it is 15 lines in the producer (`loop.py:419-433`); the task-brief cannot carry producer code verbatim (runtime must not depend on it, but a PORT is what S2 is for — the design doc §4 mandates native reimplementation). The implementer receives the port below; verify it against the golden trace in Task 8, not against the producer.

```elixir
defmodule Kapelle.Product.NextStage do
  @moduledoc """
  The pure next-stage function over the canonical artifact view (design doc
  §5): a native port of the reference loop's stage progression and its
  deterministic evaluator. No IO, no clocks, no randomness — verified
  against the golden oracle (parity), not against the producer's code.
  """

  alias Kapelle.Product.View

  @type stage :: {:run, {:research | :concept | :apply, non_neg_integer()}}
  @type verdict :: {:terminal, :ready | :needs_human, String.t()}

  @spec compute(View.t(), pos_integer()) :: stage() | verdict()
  def compute(%View{} = view, max_iterations) when max_iterations > 0 do
    walk(view, 0, max_iterations)
  end

  defp walk(_view, i, max) when i >= max do
    {:terminal, :needs_human, "max_iterations reached with open critical items"}
  end

  defp walk(view, i, max) do
    rp = view.research_packs[i]
    cd = view.concept_drafts[i]

    cond do
      rp == nil -> {:run, {:research, i}}
      cd == nil -> {:run, {:concept, i}}
      not delta_applied?(view.proposal, i) -> {:run, {:apply, i}}
      true -> evaluate(rp, cd, i, max)
    end
  end

  defp delta_applied?(nil, _i), do: false
  defp delta_applied?(proposal, i), do: (proposal["iteration"] || -1) >= i

  defp evaluate(rp, cd, i, max) do
    issues = open_criticals(rp, cd)
    requests = Map.get(cd, "requests_to_researcher", [])

    cond do
      issues == [] and requests == [] ->
        {:terminal, :ready, "no open critical assumptions/gaps and no open requests"}

      i + 1 < max ->
        {:run, {:research, i + 1}}

      true ->
        {:terminal, :needs_human,
         "max_iterations reached with open critical items: " <>
           if(issues != [], do: Enum.join(issues, "; "), else: "#{length(requests)} open request(s)")}
    end
  end

  # Port of the producer's open_criticals/2: a critical assumption or gap
  # named by the research pack stays open unless the concept draft's
  # addressed list names it. EXACT field names must be verified against the
  # vendored schemas in Step 2 — the shapes below are the expected ones.
  defp open_criticals(rp, cd) do
    addressed = cd |> Map.get("addresses", []) |> MapSet.new()

    criticals =
      (Map.get(rp, "assumptions", []) |> Enum.filter(&(&1["criticality"] == "critical")) |> Enum.map(& &1["text"])) ++
        (Map.get(rp, "gaps", []) |> Enum.filter(&critical_gap?/1) |> Enum.map(&gap_text/1))

    Enum.reject(criticals, &MapSet.member?(addressed, &1))
  end

  defp critical_gap?(%{"criticality" => "critical"}), do: true
  defp critical_gap?(_), do: false
  defp gap_text(%{"text" => text}), do: text
  defp gap_text(other) when is_binary(other), do: other
end
```

**IMPORTANT for the implementer — Step 2 is mandatory:** the `open_criticals` field shapes above are a best guess. Read the VENDORED schemas (`priv/contracts/impresario/research-pack/v1/schema.json`, `concept-draft/v1/schema.json`) and the vendored valid fixtures, extract the real field names (assumptions/gaps/criticality/addresses or their actual equivalents), and correct the port. Record the actual shapes in your report. The golden parity test (Task 8) is the behavioral referee.

- [ ] **Step 2: Correct the port against vendored schemas** (see note). Write table-driven tests for: empty loop → research 0; rp only → concept 0; rp+cd, proposal behind → apply 0; all applied + nothing open → ready; open items mid-loop → research i+1; open items at max → needs_human; max_iterations exhausted → needs_human.

- [ ] **Step 3: Run** — green; full suite; format.
- [ ] **Step 4: Commit** — `git add -A && git commit -m "feat: pure next-stage over the canonical view — reference progression + deterministic evaluate"`

### Task 8: Oracle v0 — normalizer, golden set with provenance, happy-path parity

**Files:**
- Create: `lib/kapelle/product/oracle/normalizer.ex`, `scripts/gen_golden.sh`, `test/support/fixtures/golden/happy/` (raw + normalized + PROVENANCE, generated then committed), `test/kapelle/product/parity_happy_test.exs`
- Test: `test/kapelle/product/normalizer_test.exs`

**Interfaces:**
- Produces:
  - `Kapelle.Product.Oracle.Normalizer.version() :: "v1"`, `normalize(raw_trace_events :: [map()]) :: [map()]` — deterministic reduction of reference trace events to domain observations: `%{"iteration", "stage", "artifact_kind", "artifact_ref", "artifact_hash", "proposal_transition", "verdict", "stop_reason_class"}` (nil-fields dropped; technical events — timestamps, paths, agent chatter — discarded).
  - Golden layout: `test/support/fixtures/golden/happy/{raw-trace.jsonl, normalized.json, workspace/ (the loop's artifact files), PROVENANCE}`.

- [ ] **Step 1: Write `scripts/gen_golden.sh`** (test tooling; extracts the FULL pinned producer via `git archive`, runs its reference runner on its own fixtures in a temp venv, captures workspace + trace):

```bash
#!/usr/bin/env bash
# Generate the golden happy-path evidence from the PINNED reference runner.
# Usage: scripts/gen_golden.sh <path-to-impresario-checkout>
# Explicit, reviewable golden update (owner's S2 preamble, item 6):
# never run automatically, never on test failure.
set -euo pipefail

IMPRESARIO="${1:?path to impresario checkout}"
COMMIT="f84d5ac5a2aea1e95f9a52f5a266cf37f42f1fd1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/test/support/fixtures/golden/happy"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git -C "$IMPRESARIO" archive "$COMMIT" | tar -x -C "$TMP"

python3 -m venv "$TMP/venv"
"$TMP/venv/bin/pip" -q install -e "$TMP" >/dev/null

# The producer's own test fixtures define the deterministic happy-path agent;
# discover the exact invocation from its docs/tests rather than guessing:
# tests/test_engine.py drives init_loop + run_loop with a scripted agent.
"$TMP/venv/bin/python" "$ROOT/scripts/gen_golden_run.py" "$TMP" "$TMP/ws"

rm -rf "$OUT" && mkdir -p "$OUT"
cp "$TMP/ws/trace.jsonl" "$OUT/raw-trace.jsonl"
mkdir -p "$OUT/workspace" && cp -R "$TMP/ws/." "$OUT/workspace/"

{
  echo "producer: impresario@$COMMIT (full tree via git archive)"
  echo "generated: $(date +%Y-%m-%d)"
  echo "generator: scripts/gen_golden.sh + scripts/gen_golden_run.py"
  echo "normalizer: (see lib/kapelle/product/oracle/normalizer.ex version at commit of this PR)"
  (cd "$OUT" && find . -type f ! -name PROVENANCE | LC_ALL=C sort | while read -r f; do
    echo "sha256 $f: $(shasum -a 256 "$f" | cut -d' ' -f1)"
  done)
} > "$OUT/PROVENANCE"

echo "wrote $OUT"
```

- [ ] **Step 2: Write `scripts/gen_golden_run.py`** — the implementer derives it from the producer's own `tests/test_engine.py` at the pin (extracted in $TMP): construct the scripted deterministic agent the producer's tests use for the READY path, `init_loop` + `run_loop` into `$TMP/ws`, no network. STOP and report if the producer's test helpers cannot drive a ready-case deterministically — do not invent agent behavior.

- [ ] **Step 3: Run the generation** — `scripts/gen_golden.sh /Users/Andrei_Shtanakov/labs/all_ai_orchestrators/impresario` → golden dir with raw trace, workspace, PROVENANCE.

- [ ] **Step 4: TDD the normalizer** — failing tests first (feed 3-4 hand-picked raw events from the actual golden raw-trace.jsonl and assert the normalized shapes; then the determinism property — normalize twice, byte-equal), then implement: map `artifact_written` → `%{"iteration" (from the key "LOOP:i:role"), "stage" (role), "artifact_kind", "artifact_ref", "artifact_hash" (output_hash)}`; `transition` → `%{"proposal_transition" => "from->to"}`; `verdict` → `%{"iteration", "verdict", "stop_reason_class"}` where stop_reason_class is the reason's leading clause up to the first `:` — never the raw string with counts; drop `stopped`/technical events. Write `normalized.json` output via the mix task or a test helper, commit it alongside the raw trace.

- [ ] **Step 5: The happy-path parity test** (the S2 exit gate: no workers involved — replay the golden workspace's artifacts through Loader → Store → View → NextStage and compare the domain walk against the normalized golden):

```elixir
defmodule Kapelle.Product.ParityHappyTest do
  use Kapelle.DataCase, async: false

  alias Kapelle.Product.{Loader, NextStage, Oracle.Normalizer, Store, View}

  @golden "test/support/fixtures/golden/happy"

  test "the golden happy-path artifacts walk to :ready through view+next_stage" do
    ws = Path.join(@golden, "workspace")
    loop_id = "LOOP-GOLDEN"

    # Replay artifacts in file order — the store is order-insensitive.
    for {kind, file} <- [
          {:idea, "idea.yaml"},
          {:product_proposal, "proposal.yaml"},
          {:exchange_log, "exchange-log.yaml"},
          {:loop_state, "loop.state"}
        ] ++ iteration_files(ws) do
      {:ok, record} = Loader.load(kind, File.read!(Path.join(ws, file)))
      {:ok, _} = Store.put(record, loop_id)
    end

    assert {:ok, view} = View.build(loop_id)

    max = view.loop_state["max_iterations"]
    assert {:terminal, :ready, _reason} = NextStage.compute(view, max)
  end

  test "the normalizer reproduces the committed normalized golden byte-for-byte" do
    raw =
      @golden
      |> Path.join("raw-trace.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    expected = @golden |> Path.join("normalized.json") |> File.read!() |> Jason.decode!()
    assert Normalizer.normalize(raw) == expected
  end

  defp iteration_files(ws) do
    for path <- Path.wildcard(Path.join(ws, "rp-*.yaml")), do: {:research_pack, Path.basename(path)},
        into: for(path <- Path.wildcard(Path.join(ws, "cd-*.yaml")), do: {:concept_draft, Path.basename(path)})
  end
end
```

(Adapt file names/`loop.state` handling to the actual golden workspace layout; the loop_state doc's `max_iterations` drives NextStage. If the terminal verdict in the golden run is not READY, the generation script produced the wrong scenario — regenerate, do not adapt the assertion.)

- [ ] **Step 6: Run everything** — parity green, full suite green, `mix format --check-formatted`, `mix credo --strict` baseline.

- [ ] **Step 7: Commit** — `git add -A && git commit -m "feat: oracle v0 — versioned normalizer, provenance-carrying golden set, happy-path parity"`

### Task 9: Docs stitch and the PR

**Files:**
- Modify: `docs/superpowers/specs/2026-08-14-product-context-design.md` (status line), this plan (nothing — history)

- [ ] **Step 1:** Append to the design doc's `Status:` line: `S2 implementation: docs/superpowers/plans/2026-08-14-product-s2-state-and-oracle.md.`
- [ ] **Step 2:** Full verification: `mix test && mix format --check-formatted && mix credo --strict` — green/baseline.
- [ ] **Step 3:** Commit, push, open the PR:

```bash
git add -A && git commit -m "docs: link the S2 plan from the design doc"
git push -u origin plan/product-s2-state-and-oracle
gh pr create --title "Kapelle.Product S2: artifact store, canonical view, next-stage, oracle v0" \
  --body "S2 of the airun-M3 arc per the design doc §5/§6/§8 and the owner's S2 preamble of 2026-08-14. Resolves the S1 carry-forwards up front (per-kind identity, priv/+app_dir schema loading, duplicate-key strictness, atomic script staging is NOT here — S3 ride-along). Adds: canonical_doc_hash port proven byte-compatible by producer-generated cross-language fixtures; the immutable artifact store (no-op/typed-conflict/post-commit events); the fail-closed canonical view; the pure next-stage function porting the reference progression; oracle v0 (versioned normalizer + golden happy-path with full provenance + parity test). Golden updates are explicit script runs, never automatic. S2 exit gates covered by tests: identical re-persist no-op, same-identity-different-hash conflict, fail-closed view, reproducible normalization."
```

- [ ] **Step 4:** Handle Copilot review; human merges.

## Self-Review

- **Spec/preamble coverage:** preamble item 1 (exact hash + dup keys + cross-language fixtures) → Tasks 3+4; item 2 (identity table, no path/UUID identity) → Task 1 + Store's composite key (Task 5); item 3 (app_dir + CWD test) → Task 2 (release smoke deferred — ruling recorded in the test comment); item 4 (store semantics + one transactional boundary + no pre-commit events) → Task 5; item 5 (view distinctions, loop-state projection, gate-decision stored-not-authorizing) → Tasks 6+7 (gate_decision sits in View.decisions, consumed by nothing); item 6 (oracle constraints) → Task 8 (+ generation scripts are explicit commands). §8 S2 exit gates: no-op/conflict (Task 5 tests), fail-closed view (Task 6 tests), reproducible normalization (Task 8 test).
- **Known open risks, stated not hidden:** Task 3's yamerl record positions and Task 7's `open_criticals` field shapes are best-effort transcriptions with mandatory empirical-correction steps and STOP conditions; Task 4 names float/escaping as the plausible divergence and forbids silent fixture edits; Task 8's generation script depends on the producer's test helpers (STOP condition included).
- **Placeholder scan:** none — every step carries code, a command, or an explicit derivation instruction with a stop condition.
- **Type consistency:** `Identity.of/2` return shape used by Loader (T1) and Store docs (T5); `Store.put/2` and `Store.all/1` shapes consumed by View tests (T6) and parity (T8); `View` fields consumed by NextStage (T7) and parity (T8); Event struct fields match the design doc §3 bridge minus the S3-only `run_id/iteration/producer` semantics (producer: nil until workers exist — S3 fills it).
