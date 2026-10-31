#!/usr/bin/env bash
# =============================================================================
#  restore.sh -- restore the Patogh database from a snapshot in data/backups/
#
#  What it does
#    1. without an argument, lists the snapshots (newest first)
#    2. with one, stops the patogh container, saves the current database as a
#       pre-restore snapshot, puts the chosen one in place and starts it again
#
#  Usage:
#    ./restore.sh
#    ./restore.sh <snapshot.db>
#
#  Options: --help
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")"

say() { printf '[+] %s\n' "$*"; }
die() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  -h | --help)
    cat << 'EOF'
restore.sh -- restore the Patogh database from a snapshot in data/backups/.

Usage:
  ./restore.sh                  list the snapshots, newest first
  ./restore.sh <snapshot.db>    restore one (file name or path); the current
                                database is saved first as a pre-restore snapshot
  -h, --help                    show this help

Take a snapshot with ./backup.sh.
EOF
    exit 0
    ;;
  -*) die "Unknown option: $1 (try --help)." ;;
esac

BACKUP_DIR="data/backups"
DB="data/patogh.db"

[[ -d "$BACKUP_DIR" ]] || die "No backups folder at $BACKUP_DIR."

# No arg: list snapshots newest-first and exit.
if [[ $# -eq 0 ]]; then
  shopt -s nullglob
  snaps=("$BACKUP_DIR"/*.db)
  shopt -u nullglob
  if [[ ${#snaps[@]} -eq 0 ]]; then
    say "No snapshots in $BACKUP_DIR."
    exit 0
  fi
  echo "Snapshots (newest first):"
  for f in $(ls -1t "$BACKUP_DIR"/*.db); do
    printf "  %s  (%s)\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
  done
  echo ""
  echo "Restore with: ./restore.sh <snapshot>"
  exit 0
fi

# Resolve the snapshot to a basename inside BACKUP_DIR (restore is always from data/backups/).
SNAP_NAME="$(basename "$1")"
[[ -f "$BACKUP_DIR/$SNAP_NAME" ]] || die "Snapshot not found in $BACKUP_DIR: $SNAP_NAME"

echo "About to restore: $BACKUP_DIR/$SNAP_NAME"
echo "This REPLACES $DB. The current database is saved first as a pre-restore snapshot."
read -rp "Continue? [y/N] " yn
[[ "${yn,,}" == "y" ]] || {
  echo "Aborted."
  exit 0
}

say "[1/3] Stopping the patogh container ..."
docker compose stop patogh

# data/patogh.db and data/backups/ are container-owned (uid 1000, the non-root runtime
# user). The host user cannot cp/rm them directly, so do the swap inside a throwaway root
# container that mounts data/ (root can rewrite the uid-1000-owned files).
# (Run as a user in the docker group, or with sudo.)
TS="$(date -u +%Y%m%dT%H%M%S)"
say "[2/3] Swapping the database inside a root container (pre-restore copy, WAL clear, install) ..."
docker run --rm -v "$(pwd)/data:/data" alpine sh -c '
  set -e
  if [ -f /data/patogh.db ]; then
    cp /data/patogh.db "/data/backups/patogh-$1-pre-restore.db"
  fi
  rm -f /data/patogh.db-wal /data/patogh.db-shm
  cp "/data/backups/$2" /data/patogh.db
' sh "$TS" "$SNAP_NAME"

say "[3/3] Starting the patogh container ..."
docker compose start patogh
say "Done. Watch it come up: docker compose logs -f patogh"
