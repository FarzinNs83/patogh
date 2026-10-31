#!/usr/bin/env bash
# Trigger a manual DB snapshot inside the running Patogh container.
set -euo pipefail
cd "$(dirname "$0")"

if ! docker ps --format '{{.Names}}' | grep -q '^patogh$'; then
  echo "Error: patogh container is not running." >&2
  exit 1
fi

docker exec -w /app/packages/server patogh \
  node --import tsx/esm src/scripts/snapshot.ts
