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
