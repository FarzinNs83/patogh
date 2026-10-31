#!/usr/bin/env bash
# =============================================================================
#  backup.sh -- snapshot of the Patogh database to data/backups/, taken
#               inside the running container
#
#  Usage:
#    ./backup.sh
#    ./restore.sh                  (list / restore snapshots)
#
#  Options: --help
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
  "") ;;
  -h | --help)
    printf '%s\n' "backup.sh -- snapshot of the Patogh database to data/backups/." \
      "" "Usage:" "  ./backup.sh" "" "Restore one with ./restore.sh."
    exit 0
    ;;
  *)
    printf '[x] Unknown option: %s (try --help).\n' "$1" >&2
    exit 1
    ;;
esac

if ! docker ps --format '{{.Names}}' | grep -x patogh > /dev/null; then
  printf '[x] The patogh container is not running.\n' >&2
  exit 1
fi

docker exec -w /app/packages/server patogh \
  node --import tsx/esm src/scripts/snapshot.ts
