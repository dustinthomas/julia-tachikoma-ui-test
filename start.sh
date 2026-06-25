#!/usr/bin/env bash
# start.sh - Generic starter for julia-tachikoma-ui-test
# Customize for your Julia + UI stack (GPU, nginx proxy, etc.)

set -euo pipefail

echo "=== julia-tachikoma-ui-test start ==="

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found"
  exit 1
fi

# Example: start the node harness container (policy)
docker compose up -d node

echo "Node container started (if defined)."
echo "Customize this script for your julia services / frontend."
echo "Stop with ./stop.sh or: docker compose down"

# Example GPU Julia (uncomment/adapt):
# docker compose up -d julia-gpu frontend
# or
# ./your-julia-start.sh
