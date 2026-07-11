#!/usr/bin/env bash
# packaging/package_tarball.sh — internal-only helper to archive a create_app bundle.
#
# Stage 1 shipping is private dist/ or a tarball handed off offline — NOT a
# public GitHub Release. This script packs dist/qci-kanban-linux into
# dist/qci-kanban-linux-<stamp>.tar.gz (or .tar.zst when zstd is available).
#
# Usage (from qci-kanban/):
#   ./packaging/package_tarball.sh
#   ./packaging/package_tarball.sh /path/to/dist/qci-kanban-linux
#
# Requires: tar; optional zstd for smaller archives.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${1:-$ROOT/dist/qci-kanban-linux}"
DIST_DIR="$(dirname "$BUNDLE")"
NAME="$(basename "$BUNDLE")"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
HOST="$(uname -m 2>/dev/null || echo unknown)"

if [[ ! -d "$BUNDLE" ]]; then
  echo "error: bundle directory not found: $BUNDLE" >&2
  echo "Build first: julia --project=packaging packaging/build_linux_app.jl" >&2
  exit 1
fi

if [[ ! -x "$BUNDLE/bin/qci-kanban" && ! -f "$BUNDLE/bin/qci-kanban" ]]; then
  echo "warning: $BUNDLE/bin/qci-kanban missing — archiving anyway" >&2
fi

mkdir -p "$DIST_DIR"

if command -v zstd >/dev/null 2>&1; then
  OUT="$DIST_DIR/${NAME}-${STAMP}-${HOST}.tar.zst"
  # tar --zstd when supported; fall back to pipe
  if tar --help 2>&1 | grep -q -- '--zstd'; then
    tar --zstd -cf "$OUT" -C "$DIST_DIR" "$NAME"
  else
    tar -cf - -C "$DIST_DIR" "$NAME" | zstd -T0 -q -o "$OUT"
  fi
else
  OUT="$DIST_DIR/${NAME}-${STAMP}-${HOST}.tar.gz"
  tar -czf "$OUT" -C "$DIST_DIR" "$NAME"
fi

BYTES=$(wc -c <"$OUT" | tr -d ' ')
echo "created $OUT ($BYTES bytes)"
ls -lh "$OUT"
