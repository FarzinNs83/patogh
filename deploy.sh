#!/usr/bin/env bash
# ============================================================
# Patogh — Quick Deploy Script
# ============================================================
# Syncs this checkout to a server that was set up with install.sh and
# rebuilds the app there. The server keeps its own .env, data/, livekit.yaml
# and certificates; none of them are overwritten.
#
# Usage:
#   ./deploy.sh user@host [remote-path]
#   ./deploy.sh                      Uses DEPLOY_HOST / DEPLOY_PATH from ./.deploy.local
#
# ./.deploy.local (git-ignored) can hold the defaults, e.g.:
#   DEPLOY_HOST=me@chat.example.com
#   DEPLOY_PATH=~/patogh
# ============================================================

set -euo pipefail
cd "$(dirname "$0")"

DEPLOY_HOST=""
DEPLOY_PATH="~/patogh"
if [[ -f ./.deploy.local ]]; then
  # shellcheck source=/dev/null
  source ./.deploy.local
fi
DEPLOY_HOST="${1:-$DEPLOY_HOST}"
DEPLOY_PATH="${2:-$DEPLOY_PATH}"

if [[ -z "$DEPLOY_HOST" ]]; then
  echo "Usage: ./deploy.sh user@host [remote-path]   (or set DEPLOY_HOST in ./.deploy.local)" >&2
  exit 1
fi

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

echo ""
echo "═══ Deploying to $DEPLOY_HOST:$DEPLOY_PATH ═══"
echo ""

echo "  [1/4] Preparing remote directory..."
ssh "$DEPLOY_HOST" "mkdir -p $DEPLOY_PATH"

echo "  [2/4] Syncing files..."
rsync -az --delete "${EXCLUDES[@]}" ./ "$DEPLOY_HOST:$DEPLOY_PATH"

echo "  [3/4] Building and restarting..."
# --build: always run this checkout's code rather than a pulled image.
ssh "$DEPLOY_HOST" "cd $DEPLOY_PATH && PATOGH_COMMIT='$BUILD_COMMIT' docker compose up -d --build"

# Old images pile up with every build; keep the build cache capped for fast rebuilds.
echo "  [4/4] Pruning stale Docker data..."
ssh "$DEPLOY_HOST" "docker image prune -af --filter 'until=24h' >/dev/null 2>&1; docker builder prune -f --keep-storage=2GB >/dev/null 2>&1" || true

echo ""
echo "Deployment complete. Logs: ssh $DEPLOY_HOST 'cd $DEPLOY_PATH && docker compose logs -f patogh'"
