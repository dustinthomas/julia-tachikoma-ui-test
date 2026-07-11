#!/usr/bin/env bash
# packaging/relocatable_container_smoke.sh — host + optional container --smoke
#
# Usage (from qci-kanban/ or any cwd):
#   ./packaging/relocatable_container_smoke.sh
#   ./packaging/relocatable_container_smoke.sh /path/to/qci-kanban-linux
#
# Env:
#   QCI_SMOKE_IMAGE      container image (default: ubuntu:24.04)
#   QCI_SMOKE_SKIP_HOST  if 1, skip host smoke (container only)
#   QCI_SMOKE_RUNTIME    force docker|podman (default: auto-detect)
#
# Exit codes:
#   0 — host smoke ok, and container smoke ok if a runtime was available
#   1 — missing dist/binary, host smoke failed, or container smoke failed
#
# Does not claim multi-machine redistribution success. See relocatable_smoke.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_DIST="${ROOT}/dist/qci-kanban-linux"

if [[ -n "${1:-}" ]]; then
  if [[ ! -d "$1" ]]; then
    echo "ERROR: dist dir not found: $1" >&2
    exit 1
  fi
  DIST="$(cd "$1" && pwd)"
else
  DIST="${DEFAULT_DIST}"
fi

BIN="${DIST}/bin/qci-kanban"
IMAGE="${QCI_SMOKE_IMAGE:-ubuntu:24.04}"
SKIP_HOST="${QCI_SMOKE_SKIP_HOST:-0}"

echo "== relocatable_container_smoke =="
echo "dist:  ${DIST}"
echo "bin:   ${BIN}"
echo "image: ${IMAGE}"

if [[ ! -f "${BIN}" ]]; then
  echo "ERROR: missing binary at ${BIN}" >&2
  echo "Build first: julia --project=packaging packaging/build_linux_app.jl" >&2
  echo "Or pass a path to an existing dist tree (not committed; may live elsewhere)." >&2
  exit 1
fi

if [[ ! -x "${BIN}" ]]; then
  echo "ERROR: binary exists but is not executable: ${BIN}" >&2
  exit 1
fi

run_host_smoke() {
  echo "-- host smoke --"
  # Clear vars that can shadow the bundle (same guidance as README)
  env -u JULIA_PROJECT -u JULIA_LOAD_PATH -u JULIA_DEPOT_PATH \
    "${BIN}" --smoke
  echo "host smoke: exit 0"
}

if [[ "${SKIP_HOST}" != "1" ]]; then
  run_host_smoke
else
  echo "-- host smoke skipped (QCI_SMOKE_SKIP_HOST=1) --"
fi

detect_runtime() {
  if [[ -n "${QCI_SMOKE_RUNTIME:-}" ]]; then
    echo "${QCI_SMOKE_RUNTIME}"
    return
  fi
  if command -v docker >/dev/null 2>&1; then
    echo docker
    return
  fi
  if command -v podman >/dev/null 2>&1; then
    echo podman
    return
  fi
  echo ""
}

RUNTIME="$(detect_runtime)"

if [[ -z "${RUNTIME}" ]]; then
  echo "-- container smoke skipped: neither docker nor podman found --"
  echo "Host smoke only. Not a multi-machine verification claim."
  echo "See packaging/relocatable_smoke.md for manual / second-host steps."
  exit 0
fi

if ! command -v "${RUNTIME}" >/dev/null 2>&1; then
  echo "ERROR: QCI_SMOKE_RUNTIME=${RUNTIME} not found on PATH" >&2
  exit 1
fi

echo "-- container smoke (${RUNTIME}, ${IMAGE}) --"
# Mount whole tree RO; run bundled binary without Julia from the image.
set +e
"${RUNTIME}" run --rm \
  -v "${DIST}:/qci-kanban-linux:ro" \
  "${IMAGE}" \
  /qci-kanban-linux/bin/qci-kanban --smoke
c_exit=$?
set -e

if [[ "${c_exit}" -ne 0 ]]; then
  echo "container smoke: FAILED exit=${c_exit}" >&2
  echo "Common cause: target image glibc older than build host (GLIBC_* not found)." >&2
  echo "Try QCI_SMOKE_IMAGE=ubuntu:24.04 or rebuild on an older base OS." >&2
  echo "This is NOT a successful off-machine verification." >&2
  exit "${c_exit}"
fi

echo "container smoke: exit 0"
echo "Note: container proxy only (${RUNTIME}/${IMAGE}). Record evidence; Stage 1 remains internal until broader multi-machine checks."
exit 0
