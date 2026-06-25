#!/usr/bin/env bash
# stop.sh - Clean shutdown for julia-tachikoma-ui-test containers

set -euo pipefail

echo "=== Stopping julia-tachikoma-ui-test stack ==="
docker compose down

echo "Containers stopped. (docker compose down -v to also drop volumes)"
echo "Done."
