#!/usr/bin/env bash
# =============================================================================
#  deploy.sh -- push this checkout to a server set up with install.sh and
#               rebuild Patogh there (for development builds; releases go
#               through ./update.sh on the server)
#
#  What it does
#    1. asks for the server (user@host) unless ./.deploy.local has it
#    2. syncs the checkout with rsync. The server keeps its own .env, data/,
#       livekit.yaml and certificates; none of them are overwritten
#    3. rebuilds the image there from this code and restarts it
#    4. prunes old images and caps the build cache
#
#  ./.deploy.local (git-ignored) can hold the defaults:
#    DEPLOY_HOST=me@<server>
#    DEPLOY_PATH=~/patogh
#
#  Usage:
#    ./deploy.sh                   (asks for the server)
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

usage() {
  cat << 'EOF'
deploy.sh -- push this checkout to a Patogh server set up with install.sh and
rebuild it there. The server keeps its .env, data/, livekit.yaml and
certificates.

Usage:
  ./deploy.sh [user@host] [remote-path]    (asks for the server when not given)

  user@host      ssh target (default: DEPLOY_HOST in ./.deploy.local)
  remote-path    install folder on the server (default: DEPLOY_PATH, ~/patogh)
  -h, --help     show this help
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  -*) die "Unknown option: $1 (try --help)." ;;
esac

DEPLOY_HOST=""
DEPLOY_PATH="~/patogh"
if [[ -f ./.deploy.local ]]; then
  # shellcheck source=/dev/null
  source ./.deploy.local
fi
DEPLOY_HOST="${1:-$DEPLOY_HOST}"
DEPLOY_PATH="${2:-$DEPLOY_PATH}"

if [[ -z "$DEPLOY_HOST" ]]; then
  read -rp "Server (user@host): " DEPLOY_HOST || true
fi
[[ -n "$DEPLOY_HOST" ]] || die "No server given (try --help)."

# Baked into the image so the admin panel can show which commit runs. rsync
# skips .git, so the server cannot work it out itself. Empty without git.
BUILD_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo '')"

EXCLUDES=(
  --exclude='node_modules'
  --exclude='.git'
  --exclude='.env'
  --exclude='.env.local'
  --exclude='.deploy.local'
  --exclude='packages/web/dist'
  --exclude='packages/desktop'
  --exclude='installers'
  --exclude='data'
  --exclude='livekit.yaml'
  --exclude='certbot-www'
  --exclude='tools'
  --exclude='design'
  --exclude='assets/brand'
  --exclude='electronbuild.sh'
  --exclude='.claude'
  --exclude='.worktrees'
  --exclude='.DS_Store'
)

say "Deploying to $DEPLOY_HOST:$DEPLOY_PATH"

say "[1/4] Preparing the remote folder ..."
ssh "$DEPLOY_HOST" "mkdir -p $DEPLOY_PATH"

say "[2/4] Syncing files ..."
rsync -az --delete "${EXCLUDES[@]}" ./ "$DEPLOY_HOST:$DEPLOY_PATH"

say "[3/4] Building and restarting ..."
# --build: always run this checkout's code rather than a pulled image.
ssh "$DEPLOY_HOST" "cd $DEPLOY_PATH && PATOGH_COMMIT='$BUILD_COMMIT' docker compose up -d --build"

# Old images pile up with every build; keep the build cache capped for fast rebuilds.
say "[4/4] Pruning stale Docker data ..."
ssh "$DEPLOY_HOST" "docker image prune -af --filter 'until=24h' >/dev/null 2>&1; docker builder prune -f --keep-storage=2GB >/dev/null 2>&1" || true

say "Done. Logs: ssh $DEPLOY_HOST 'cd $DEPLOY_PATH && docker compose logs -f patogh'"
