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
SHA="$(git -C "$IMPRESARIO" rev-parse "$COMMIT")"
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
