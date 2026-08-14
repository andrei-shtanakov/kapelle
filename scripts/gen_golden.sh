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
# gen_golden_run.py ports tests/test_loop.py's HAPPY_SCRIPT (init_loop +
# run_loop via ScriptedAgent) rather than importing it, since importing the
# producer's test module would pull in its dev-only pytest dependency, which
# this editable install (main dependencies only) does not provision.
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
