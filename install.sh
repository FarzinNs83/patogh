#!/usr/bin/env bash
# ============================================================
#  install.sh -- Patogh on a Linux server with Docker, behind nginx with a
#                Let's Encrypt certificate, with voice and video (LiveKit)
#
#  What it does
#    1. installs Docker and the compose plugin (from get.docker.com, or from
#       the distro packages if that is unreachable)
#    2. checks Docker Hub, npm and Debian; on a server in Iran, where they are
#       blocked, it finds local mirrors that answer and uses them
#    3. asks for the domain (only on the first run) and picks the mode:
#         allinone  the bundled nginx owns 80/443, gets a Let's Encrypt
#                   certificate and renews it daily (when 80/443 are free)
#         proxy     you already run a reverse proxy (nginx, Traefik, Caddy,
#                   Nginx Proxy Manager, ...): Patogh listens on
#                   127.0.0.1:APP_PORT and ready-to-paste config is printed
#         tunnel    Cloudflare Tunnel, Tailscale, ...: like proxy, no voice
#                   (WebRTC/UDP cannot cross a tunnel)
#    4. writes .env and livekit.yaml (secrets are generated once and kept on
#       re-runs), pulls the prebuilt image (or builds it from source) and
#       starts it, then checks that https://<domain> answers
#
#  The server's name and owner are not asked here: the first person to open
#  the site names it on the setup page and becomes its owner. Re-running the
#  script upgrades the install and keeps its settings.
#
#  Usage:
#    ./install.sh                  (asks for the domain)
#    ./update.sh                   (later: update to the newest release)
#
#  Options: --help
# ============================================================
set -Eeuo pipefail
cd "$(dirname "$0")"

usage() {
  cat << 'EOF'
install.sh -- install Patogh with Docker, behind nginx with a Let's Encrypt
certificate, with voice and video (LiveKit).

Usage:
  ./install.sh                (asks for the domain on the first run)

Everything else is automatic. Optional overrides, as environment variables:
  DEPLOY_MODE=allinone|proxy|tunnel   default: allinone when 80/443 are free,
                                      else proxy
  APP_PORT=<port>                     loopback port in proxy / tunnel mode
  ENABLE_VOICE=false                  no voice / video (no LiveKit)
  CERTBOT_EMAIL=<address>             Let's Encrypt expiry notices
  MAX_UPLOAD_SIZE=<bytes>             upload limit (default: 100 MB)
  DOCKER_MIRRORS="https://a https://b"
  NPM_REGISTRY=<url>                  mirrors; found automatically when the
  DEBIAN_MIRROR=<url>                 originals are blocked
  PATOGH_BUILD=true                   build from source instead of pulling
                                      the prebuilt image (forks)

  -h, --help                          show this help

After the install (from this directory):
  ./update.sh                 snapshot the database, update, roll back on failure
  ./backup.sh                 database snapshot to data/backups/
  ./restore.sh                list snapshots / restore one
  docker compose logs -f      logs
EOF
}

case "${1:-}" in
  "") ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    printf '[x] Unknown option: %s (try --help).\n' "$1" >&2
    exit 1
    ;;
esac

# -- Output helpers ------------------------------------------

info() { printf '[+] %s\n' "$*"; }
success() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
error() { printf '[x] %s\n' "$*" >&2; }
step() { printf '\n== %s ==\n\n' "$*"; }

trap 'rc=$?; trap - ERR; printf "\n[x] Install failed at line %s (exit %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

# Root needs no sudo (and minimal images may not even have it).
SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

# Track whether we need sudo for docker commands
DOCKER="docker"
COMPOSE="docker compose"

# -- Phase 1: Prerequisites ---------------------------------

step "Checking prerequisites"

# Must be Linux -- host networking (LiveKit) is Linux-only
if [[ "$(uname -s)" != "Linux" ]]; then
  error "Patogh production deployment requires Linux."
  error "Detected: $(uname -s)"
  error "For development, use: npm run dev"
  exit 1
fi
success "Linux detected"

# Check Docker
if ! command -v docker &>/dev/null; then
  info "Docker is not installed -- installing it..."
  # Docker's own script first. Its download servers refuse Iranian IPs, so on
  # failure fall back to the distribution's packages, which come from the
  # server's own (usually local) apt mirror.
  # A fresh server runs unattended-upgrades right after boot and holds the dpkg
  # lock for minutes. Wait for it here (an empty install only takes the lock):
  # Docker's script calls apt-get without a lock timeout and would just fail.
  APT=(apt-get -o DPkg::Lock::Timeout=600)
  if command -v apt-get &>/dev/null; then
    info "Waiting for other apt runs (unattended-upgrades) to finish..."
    $SUDO "${APT[@]}" install -y -qq >/dev/null || true
  fi
  if ! { curl -fsSL --max-time 30 https://get.docker.com -o /tmp/get-docker.sh && $SUDO sh /tmp/get-docker.sh; }; then
    warn "Docker's install script is unreachable or failed -- using the distribution's packages."
    if ! command -v apt-get &>/dev/null; then
      error "Could not install Docker automatically. Install Docker Engine with the Compose plugin and re-run."
      exit 1
    fi
    $SUDO "${APT[@]}" update
    $SUDO "${APT[@]}" install -y docker.io
    # The Compose v2 plugin has a different name per distribution release.
    $SUDO "${APT[@]}" install -y docker-compose-v2 || $SUDO "${APT[@]}" install -y docker-compose-plugin || true
  fi
  rm -f /tmp/get-docker.sh
  $SUDO systemctl enable --now docker 2>/dev/null || true
  # Resolve the current user via `id -un`, not $USER: under `set -u`, $USER is
  # not guaranteed to be set (sudo, `su` without -l, cron, some `docker exec`
  # contexts) and an unset reference would abort the script right after Docker
  # was installed, leaving it half-configured.
  run_user="$(id -un)"
  $SUDO usermod -aG docker "$run_user"
  warn "Added $run_user to docker group. You may need to log out and back in."
  # Use sudo for the rest of this session
  DOCKER="$SUDO docker"
  COMPOSE="$SUDO docker compose"
else
  # Check if current user can talk to Docker daemon
  if ! docker info &>/dev/null 2>&1; then
    if $SUDO docker info &>/dev/null 2>&1; then
      DOCKER="$SUDO docker"
      COMPOSE="$SUDO docker compose"
    else
      error "Cannot connect to Docker daemon."
      error "Is Docker running? Try: sudo systemctl start docker"
      exit 1
    fi
  fi
  success "Docker $(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo 'installed')"
fi

# Check Docker Compose
if ! $COMPOSE version &>/dev/null 2>&1; then
  error "Docker Compose plugin is not installed."
  error "Install: https://docs.docker.com/compose/install/linux/"
  exit 1
fi
success "Docker Compose $($COMPOSE version --short 2>/dev/null || echo 'installed')"

# -- Mirrors for restricted networks (Iran) -----------------
# Docker Hub, npm and Debian can be blocked or sanctioned from Iranian servers.
# Each is tried directly first; only if that fails are local mirrors probed and
# the ones that answer used. Mirror health changes over time, so they are
# probed on every run instead of being trusted blindly. Overrides:
#   DOCKER_MIRRORS="https://a https://b"   NPM_REGISTRY=https://...   DEBIAN_MIRROR=http://...

# HTTP status of a URL, or 000 when unreachable. Never fails (safe under set -e).
# curl prints the status even when it then times out mid-body; a server that
# answered is reachable, so that status counts.
http_code() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-10}" "$1" 2>/dev/null) || true
  echo "${code:-000}"
}

DOCKER_MIRROR_CANDIDATES=(
  https://docker.arvancloud.ir
  https://mirror-docker.runflare.com
  https://docker.iranserver.com
  https://docker.mobinhost.com
  https://registry.docker.ir
  https://focker.ir
  https://hub.hamdocker.ir
  https://docker.kernel.ir
)
NPM_CANDIDATES=(
  https://mirror-npm.runflare.com/
  https://mirror.kargadan.ir/repository/npm-group/
  https://package-mirror.liara.ir/repository/npm/
)
# Plain http on purpose: the image's apt has no CA bundle, and apt verifies
# package signatures itself.
DEBIAN_CANDIDATES=(
  http://mirror.arvancloud.ir
  http://linux-mirror.liara.ir
  http://mirror.atlantiscloud.ir
  http://mirrors.pardisco.co
  http://mirror2.chabokan.net
  http://mirror.kargadan.ir
)

step "Checking network access (Docker Hub, npm, Debian)"

# Docker Hub: Iranian IPs get 403 from its token service.
if [[ -n "${DOCKER_MIRRORS:-}" ]]; then
  read -ra docker_mirrors <<< "$DOCKER_MIRRORS"
elif [[ "$(http_code 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/alpine:pull')" == "200" ]]; then
  docker_mirrors=()
  success "Docker Hub is reachable directly"
else
  warn "Docker Hub is blocked from this server -- looking for a working mirror..."
  docker_mirrors=()
  for m in "${DOCKER_MIRROR_CANDIDATES[@]}"; do
    code="$(http_code "$m/v2/" 8)"
    # A registry answers /v2/ with 200, or 401 when it wants a token.
    if [[ "$code" == "200" || "$code" == "401" ]]; then
      docker_mirrors+=("$m")
      success "  $m"
    fi
  done
  if (( ${#docker_mirrors[@]} == 0 )); then
    error "Docker Hub is blocked and none of the known mirrors answered."
    error "Set DOCKER_MIRRORS=\"https://your-mirror\" and re-run ./install.sh."
    exit 1
  fi
fi

if (( ${#docker_mirrors[@]} > 0 )); then
  current_mirrors="$($DOCKER info --format '{{json .RegistryConfig.Mirrors}}' 2>/dev/null || true)"
  wanted_json="$(printf '"%s/",' "${docker_mirrors[@]}")"; wanted_json="[${wanted_json%,}]"
  if [[ "$current_mirrors" == "$wanted_json" ]]; then
    success "Docker already uses these mirrors"
  else
    # Merge into daemon.json so other settings in it survive.
    if command -v python3 &>/dev/null; then
      $SUDO mkdir -p /etc/docker
      $SUDO python3 - "${docker_mirrors[@]}" << 'PYEOF'
import json, os, sys
path = "/etc/docker/daemon.json"
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        text = f.read().strip()
    cfg = json.loads(text) if text else {}
cfg["registry-mirrors"] = sys.argv[1:]
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF
    elif [[ ! -s /etc/docker/daemon.json ]]; then
      $SUDO mkdir -p /etc/docker
      printf '{\n  "registry-mirrors": [%s]\n}\n' "$(printf '"%s",' "${docker_mirrors[@]}" | sed 's/,$//')" \
        | $SUDO tee /etc/docker/daemon.json >/dev/null
    else
      error "/etc/docker/daemon.json exists and python3 is missing to merge into it."
      error "Add \"registry-mirrors\": [${docker_mirrors[*]}] to it yourself and re-run."
      exit 1
    fi
    info "Restarting Docker to apply the registry mirrors..."
    $SUDO systemctl restart docker
    success "Docker now pulls through: ${docker_mirrors[*]}"
  fi
fi

# npm registry, used while building the image.
if [[ -z "${NPM_REGISTRY:-}" ]]; then
  if [[ "$(http_code https://registry.npmjs.org/isarray)" == "200" ]]; then
    success "npm registry is reachable directly"
  else
    warn "registry.npmjs.org is blocked -- looking for a working npm mirror..."
    for m in "${NPM_CANDIDATES[@]}"; do
      if [[ "$(http_code "${m}isarray" 15)" == "200" ]]; then
        NPM_REGISTRY="$m"
        success "  using $m"
        break
      fi
    done
    [[ -z "${NPM_REGISTRY:-}" ]] && warn "No npm mirror answered; building the image may fail. Set NPM_REGISTRY and re-run."
  fi
fi
NPM_REGISTRY="${NPM_REGISTRY:-}"

# Debian packages installed inside the image (ffmpeg).
if [[ -z "${DEBIAN_MIRROR:-}" ]]; then
  if [[ "$(http_code http://deb.debian.org/debian/dists/stable/Release)" == "200" ]]; then
    success "Debian package mirror is reachable directly"
  else
    warn "deb.debian.org is blocked -- looking for a working Debian mirror..."
    for m in "${DEBIAN_CANDIDATES[@]}"; do
      if [[ "$(http_code "$m/debian/dists/stable/Release" 15)" == "200" ]]; then
        DEBIAN_MIRROR="$m"
        success "  using $m"
        break
      fi
    done
    [[ -z "${DEBIAN_MIRROR:-}" ]] && warn "No Debian mirror answered; building the image may fail. Set DEBIAN_MIRROR and re-run."
  fi
fi
DEBIAN_MIRROR="${DEBIAN_MIRROR:-}"

# -- Port helpers --------------------------------------------
# A host port can be held in two ways this installer must detect:
#   1. A normal listening socket (host process)          -> visible via `ss -tln`.
#   2. A Docker-published port. With the userland proxy *disabled*
#      (`userland-proxy: false`, common on tuned hosts), Docker DNATs the port
#      with iptables and there is NO listening socket for `ss` to see. So we must
#      also consult `docker ps` -- otherwise a box whose nginx already owns 80/443
#      via iptables would be misreported as "ports free".

# Does any running container publish this host port? (matches "...:<port>->" in the
# Ports column; the ":" before the port and "->" after pin it to the HOST port,
# so :80 doesn't match :8080 and never matches the container-side port.)
docker_publishes_port() {
  $DOCKER ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -qE ":${1}->"
}

# Same, but ignore Patogh's own container (used when re-running on a host that
# already runs this instance -- its published port must not count as a conflict).
docker_publishes_port_other() {
  $DOCKER ps --format '{{.Names}} {{.Ports}}' 2>/dev/null \
    | grep -vE '^patogh ' | grep -qE ":${1}->"
}

# Is the port in use by anything (host socket OR any container)?
port_in_use() {
  local port=$1
  if ss -tln 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
    return 0
  fi
  docker_publishes_port "$port"
}

# In use by something OTHER than our own Patogh container?
port_in_use_by_other() {
  local port=$1
  if ss -tln 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
    return 0
  fi
  docker_publishes_port_other "$port"
}

# Best-effort human description of what holds a port (for helpful warnings).
port_holder() {
  local port=$1 holder=""
  holder=$($DOCKER ps --format '{{.Names}} {{.Ports}}' 2>/dev/null \
    | grep -E ":${port}->" | awk '{print $1}' | head -1 || true)
  if [[ -n "$holder" ]]; then
    echo "docker container '$holder'"
    return
  fi
  holder=$(ss -tlnp 2>/dev/null | grep -E ":${port}[[:space:]]" \
    | grep -oP 'users:\(\("\K[^"]+' | head -1 || true)
  echo "${holder:-another process}"
}

# -- openssl (needed for secret generation) ------------------
if ! command -v openssl &>/dev/null; then
  error "openssl is required for generating secrets."
  error "Install: sudo apt-get install openssl"
  exit 1
fi

# Disk space check
available_kb=$(df -k . 2>/dev/null | tail -1 | awk '{print $4}' || true)
if [[ -n "$available_kb" ]] && (( available_kb < 3000000 )); then
  warn "Low disk space: $((available_kb / 1024))MB available (recommend 3GB+)"
  warn "The prebuilt image (~1.6GB pulled) needs less than a from-source build."
else
  success "Disk space OK"
fi

# -- Phase 2: Configuration ---------------------------------

step "Configuration"

# Detect existing installation
if [[ -f .env ]]; then
  info "Existing .env detected -- secrets and settings will be preserved."
fi

# Helper: read existing .env value (|| true prevents set -e from killing
# the script when grep finds no match and returns exit code 1)
env_val() {
  if [[ -f .env ]]; then
    grep "^${1}=" .env 2>/dev/null | head -1 | cut -d= -f2- || true
  fi
}

# -- Deployment mode -----------------------------------------
# Chosen without asking: an explicit DEPLOY_MODE wins, then the existing .env,
# then All-in-One when ports 80/443 are free (or held by our own nginx).
# If something else owns them, fall back to proxy mode behind it.

existing_mode=$(env_val DEPLOY_MODE)
# Our own bundled nginx (an upgrade re-run) legitimately holds 80/443.
NGINX_RUNNING=false
if $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -q '^nginx$'; then
  NGINX_RUNNING=true
fi

port80_free=true; port443_free=true
port_in_use 80  && port80_free=false
port_in_use 443 && port443_free=false

if [[ -n "${DEPLOY_MODE:-}" ]]; then
  info "Deployment mode: ${DEPLOY_MODE} (from environment)"
elif [[ -n "$existing_mode" ]]; then
  DEPLOY_MODE="$existing_mode"
  info "Deployment mode: ${DEPLOY_MODE} (from existing .env)"
elif [[ "$NGINX_RUNNING" == true || ( "$port80_free" == true && "$port443_free" == true ) ]]; then
  DEPLOY_MODE=allinone
  info "Deployment mode: allinone (bundled nginx with HTTPS on ports 80/443)"
else
  DEPLOY_MODE=proxy
  warn "Ports 80/443 are in use on this host:"
  [[ "$port80_free"  == false ]] && warn "  80  -> held by $(port_holder 80)"
  [[ "$port443_free" == false ]] && warn "  443 -> held by $(port_holder 443)"
  warn "Using proxy mode: point your existing reverse proxy at Patogh (config printed at the end)."
  warn "To get the fully automatic setup instead, free 80/443 and re-run with DEPLOY_MODE=allinone."
fi

case "$DEPLOY_MODE" in
  allinone|proxy|tunnel) ;;
  *)
    error "Invalid DEPLOY_MODE='${DEPLOY_MODE}'. Use allinone, proxy, or tunnel."
    exit 1
    ;;
esac

# All-in-One requires 80/443 -- but a re-run over an existing All-in-One instance
# legitimately finds *its own* nginx holding them (an upgrade), which is fine.
if [[ "$DEPLOY_MODE" == "allinone" ]]; then
  if [[ "$NGINX_RUNNING" == true ]]; then
    success "nginx is already running (All-in-One upgrade)"
  elif [[ "$port80_free" == false || "$port443_free" == false ]]; then
    error "All-in-One mode needs ports 80 and 443 free, but:"
    [[ "$port80_free"  == false ]] && error "  80  is held by $(port_holder 80)"
    [[ "$port443_free" == false ]] && error "  443 is held by $(port_holder 443)"
    error "Free them, or re-run with DEPLOY_MODE=proxy (or =tunnel) to run behind them."
    exit 1
  else
    success "Ports 80 and 443 are available"
  fi
fi

# In proxy/tunnel mode, layer the proxy override so nginx is dropped and the app
# is published on a loopback port. Compose reads COMPOSE_FILE (from the shell and
# from .env) to pick up both files for every command -- the operator never needs
# to remember `-f` flags afterwards.
if [[ "$DEPLOY_MODE" == "proxy" || "$DEPLOY_MODE" == "tunnel" ]]; then
  export COMPOSE_FILE="docker-compose.yml:docker-compose.proxy.yml"
else
  unset COMPOSE_FILE 2>/dev/null || true
fi

# -- Domain --------------------------------------------------
# Required in every mode: it's the public hostname clients use and it drives the
# federation identity + LiveKit URL. In proxy/tunnel mode TLS is terminated at
# your edge, but the app still advertises https://DOMAIN.

existing_domain=$(env_val DOMAIN)
# The only question this installer asks, and only on the first run.
if [[ -n "${DOMAIN:-}" ]]; then
  :
elif [[ -n "$existing_domain" ]]; then
  DOMAIN="$existing_domain"
  info "Domain: ${DOMAIN} (from existing .env)"
else
  read -rp "Domain (e.g., chat.example.com): " DOMAIN || DOMAIN=""
fi

if [[ -z "${DOMAIN:-}" ]]; then
  error "Domain is required. Set it via the DOMAIN environment variable or enter it interactively."
  exit 1
fi

if [[ "$DOMAIN" == *://* || "$DOMAIN" == */* ]]; then
  error "DOMAIN is a hostname, not a URL: use chat.example.com, not ${DOMAIN}."
  exit 1
fi

# A public port other than 443 belongs in DOMAIN itself (chat.example.com:1443):
# it is the host clients type, and every URL the instance advertises is built
# from it. Only proxy mode can honour one. The bundled nginx owns 80/443 and
# needs them for certificate issuance, and a tunnel always answers on 443 at
# the provider's edge.
DOMAIN_HOST="${DOMAIN%%:*}"
DOMAIN_PORT=""
if [[ "$DOMAIN" == *:* ]]; then
  DOMAIN_PORT="${DOMAIN##*:}"
  if ! [[ "$DOMAIN_PORT" =~ ^[0-9]+$ ]] || (( 10#$DOMAIN_PORT < 1 || 10#$DOMAIN_PORT > 65535 )); then
    error "DOMAIN='${DOMAIN}' is not a hostname or hostname:port."
    exit 1
  fi
  if [[ "$DEPLOY_MODE" != "proxy" ]]; then
    error "A custom public port (DOMAIN=${DOMAIN}) only works in proxy mode."
    error "All-in-One needs 80/443 for nginx and its certificates; a tunnel serves on 443 at its edge."
    error "Re-run with DEPLOY_MODE=proxy, or drop the port from DOMAIN."
    exit 1
  fi
  info "Public port ${DOMAIN_PORT}: your reverse proxy listens there and must pass the Host header through unchanged (the snippets below do)."
fi

# DNS verification is meaningful for All-in-One (Let's Encrypt must reach this host to
# issue a certificate). In proxy/tunnel mode the DNS record points at your proxy
# or tunnel edge -- often NOT this host's IP (that's the whole point) -- so we only
# note what it resolves to, without warning about a mismatch.
info "Checking DNS for ${DOMAIN_HOST}..."
resolved_ip=""
if command -v dig &>/dev/null; then
  resolved_ip=$(dig +short "$DOMAIN_HOST" A 2>/dev/null | tail -1 || true)
elif command -v getent &>/dev/null; then
  resolved_ip=$(getent hosts "$DOMAIN_HOST" 2>/dev/null | awk '{print $1}' | head -1 || true)
fi

my_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || curl -s4 --max-time 5 icanhazip.com 2>/dev/null || curl -s4 --max-time 5 api.ipify.org 2>/dev/null || echo "")
[[ "$my_ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || my_ip=""

# The address LiveKit advertises for media. Found here rather than by LiveKit's
# own STUN lookup, which uses Google's servers (often unreachable from Iran).
PUBLIC_IP="$my_ip"
if [[ -z "$PUBLIC_IP" && "$DEPLOY_MODE" == "allinone" ]]; then PUBLIC_IP="$resolved_ip"; fi
if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1 || true)
fi

if [[ "$DEPLOY_MODE" == "allinone" ]]; then
  if [[ -z "$resolved_ip" ]]; then
    warn "Could not resolve ${DOMAIN_HOST}. Point DNS here first, or the certificate cannot be issued."
  elif [[ -n "$my_ip" && "$resolved_ip" != "$my_ip" ]]; then
    warn "${DOMAIN_HOST} resolves to ${resolved_ip}, but this server appears to be ${my_ip}"
    warn "Let's Encrypt certificate issuance may fail if DNS doesn't point here."
  else
    success "${DOMAIN_HOST} resolves to ${resolved_ip:-verified}"
  fi
else
  if [[ -n "$resolved_ip" ]]; then
    info "${DOMAIN_HOST} currently resolves to ${resolved_ip} (should point at your proxy/tunnel edge)."
  else
    info "${DOMAIN_HOST} does not resolve yet -- point it at your proxy/tunnel edge when ready."
  fi
fi

# -- App port (proxy / tunnel only) --------------------------
# The loopback host port your proxy/tunnel forwards to. Auto-picked to avoid
# common clashes (3000/8080 are frequently taken) unless APP_PORT is set.

pick_free_port() {
  if [[ -n "${APP_PORT:-}" ]]; then
    if port_in_use_by_other "$APP_PORT"; then
      error "Requested APP_PORT=$APP_PORT is already in use by $(port_holder "$APP_PORT")."
      exit 1
    fi
    echo "$APP_PORT"; return
  fi
  local existing; existing=$(env_val APP_PORT)
  if [[ -n "$existing" ]]; then
    # Re-run: keep the existing port so the proxy/tunnel config stays valid, even
    # though our own container is currently publishing it.
    echo "$existing"; return
  fi
  local p
  for p in 8080 8081 8082 8090 8095 3001 3002 18080 28080; do
    if ! port_in_use "$p"; then echo "$p"; return; fi
  done
  for p in $(seq 8100 8200); do
    if ! port_in_use "$p"; then echo "$p"; return; fi
  done
  error "Could not find a free host port for the app. Set APP_PORT to a free port and re-run."
  exit 1
}

APP_PORT_FINAL=""
if [[ "$DEPLOY_MODE" == "proxy" || "$DEPLOY_MODE" == "tunnel" ]]; then
  APP_PORT_FINAL="$(pick_free_port)"
  success "App will be published on 127.0.0.1:${APP_PORT_FINAL}"
fi

# -- Voice/Video ---------------------------------------------
# Voice needs open UDP media ports and (in proxy mode) a /livekit route. Over a
# tunnel, WebRTC/UDP cannot traverse the edge at all -- so voice is force-disabled
# in tunnel mode rather than silently configured and then failing at call time.

existing_profiles=$(env_val COMPOSE_PROFILES)
if [[ "$DEPLOY_MODE" == "tunnel" ]]; then
  if [[ "${ENABLE_VOICE:-}" == "true" ]]; then
    warn "Voice cannot work over a tunnel (WebRTC/UDP can't traverse it) -- disabling it."
  fi
  ENABLE_VOICE=false
  info "Voice/video is disabled in tunnel mode (a known, unavoidable limitation)."
elif [[ -n "${ENABLE_VOICE:-}" ]]; then
  :
elif [[ -f .env && "$existing_profiles" != *"voice"* ]]; then
  # Re-run of an install that had voice off: keep it off.
  ENABLE_VOICE=false
else
  ENABLE_VOICE=true
fi
if [[ "$ENABLE_VOICE" == true && "$DEPLOY_MODE" == "proxy" ]]; then
  info "Voice needs open UDP media ports AND a /livekit route in your proxy (snippet printed at the end)."
fi

# -- Certificate email (All-in-One only) ---------------------
# Let's Encrypt mails expiry warnings here if renewal ever stops working.
# Optional and never asked: pass CERTBOT_EMAIL=... to set one.

CERTBOT_EMAIL="${CERTBOT_EMAIL:-$(env_val CERTBOT_EMAIL)}"

# -- Max upload size -----------------------------------------
# Cloudflare (free/pro) hard-caps request bodies at 100MB, so a 100MB app limit
# lets uploads fail at the edge instead of in-app. In tunnel mode we default the
# cap below that (90MB) with headroom for multipart overhead. An explicit
# MAX_UPLOAD_SIZE (env or existing .env) always wins.
existing_max=$(env_val MAX_UPLOAD_SIZE)
if [[ -n "${MAX_UPLOAD_SIZE:-}" ]]; then
  :
elif [[ -n "$existing_max" ]]; then
  MAX_UPLOAD_SIZE="$existing_max"
elif [[ "$DEPLOY_MODE" == "tunnel" ]]; then
  MAX_UPLOAD_SIZE=94371840   # 90 MB -- under Cloudflare's 100MB body cap
else
  MAX_UPLOAD_SIZE=104857600  # 100 MB
fi

# -- Trusted proxy hops --------------------------------------
# The number of proxies in front of the app that may be trusted to have written
# X-Forwarded-For. Every rate limit keys on the address it produces. All three
# deployment modes are one hop, which is the app's default, so this is written
# commented-out and only becomes a live line when an operator (or a previous
# run) set one: 0 for an app exposed with nothing in front, 2 for a CDN ahead
# of an appending reverse proxy. An explicit env value or an existing .env
# value always wins; neither is second-guessed here, because only the operator
# knows their topology.
existing_hops=$(env_val TRUSTED_PROXY_HOPS)
TRUSTED_PROXY_HOPS="${TRUSTED_PROXY_HOPS:-${existing_hops}}"

# -- Phase 3: Generate Secrets -------------------------------

step "Generating configuration"

# Preserve existing secrets, generate new ones where missing
JWT_SECRET=$(env_val JWT_SECRET)
if [[ -z "$JWT_SECRET" || "$JWT_SECRET" == "change_me"* ]]; then
  JWT_SECRET=$(openssl rand -hex 32)
  info "Generated new JWT_SECRET"
else
  info "Preserved existing JWT_SECRET"
fi

LIVEKIT_API_KEY=$(env_val LIVEKIT_API_KEY)
LIVEKIT_API_SECRET=$(env_val LIVEKIT_API_SECRET)
if [[ "$ENABLE_VOICE" == true ]]; then
  if [[ -z "$LIVEKIT_API_KEY" ]]; then
    LIVEKIT_API_KEY="API$(openssl rand -hex 8)"
    info "Generated new LIVEKIT_API_KEY"
  else
    info "Preserved existing LIVEKIT_API_KEY"
  fi
  if [[ -z "$LIVEKIT_API_SECRET" ]]; then
    LIVEKIT_API_SECRET=$(openssl rand -hex 24)
    info "Generated new LIVEKIT_API_SECRET"
  else
    info "Preserved existing LIVEKIT_API_SECRET"
  fi
fi

# -- Phase 4: Write Configuration Files ---------------------

step "Writing configuration files"

# -- .env ----------------------------------------------------

{
  cat << EOF
# Patogh Configuration
# Generated by install.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")

DOMAIN=${DOMAIN}

# Deployment mode: allinone | proxy | tunnel  (see the header of install.sh)
DEPLOY_MODE=${DEPLOY_MODE}
EOF

  if [[ "$DEPLOY_MODE" == "allinone" ]]; then
    cat << EOF

# Let's Encrypt account email for expiry notices (empty = none). Read by
# install.sh on re-runs; renewal itself needs nothing from here.
CERTBOT_EMAIL=${CERTBOT_EMAIL}
EOF
  fi

  if [[ "$DEPLOY_MODE" == "proxy" || "$DEPLOY_MODE" == "tunnel" ]]; then
    cat << EOF

# Reverse-proxy / tunnel mode: layer the proxy override so the bundled nginx is
# dropped and the app is published on 127.0.0.1:APP_PORT for your edge to reach.
# COMPOSE_FILE makes every 'docker compose' command in this directory use both
# files automatically -- no -f flags needed.
COMPOSE_FILE=docker-compose.yml:docker-compose.proxy.yml
APP_PORT=${APP_PORT_FINAL}
EOF
  fi

  if [[ -n "$TRUSTED_PROXY_HOPS" ]]; then
    cat << EOF

# Proxies in front of this app that may be trusted to have written
# X-Forwarded-For. Preserved from your previous configuration or from the
# environment; see .env.example for what each value means.
TRUSTED_PROXY_HOPS=${TRUSTED_PROXY_HOPS}
EOF
  else
    cat << 'EOF'

# How many proxies sit in front of this app and may be trusted to have written
# X-Forwarded-For. It is the address every rate limit counts a request against.
# The default of 1 is right for all three deployment modes above: the bundled
# nginx, your own reverse proxy and a tunnel daemon are each one hop. Change it
# only if your topology differs:
#   0  nothing in front at all (the app exposed directly). Leaving such an
#      instance at 1 lets a client send its own X-Forwarded-For and choose the
#      address its rate limits are counted against.
#   2  a CDN in front of your own reverse proxy, when that proxy APPENDS to
#      X-Forwarded-For (the bundled nginx does).
# Any value that is not a non-negative integer, or is above 4, stops the server
# at boot with a message instead of quietly running a number you did not pick.
# Leaving the line blank is not a value: it reads as unset and you get 1.
# TRUSTED_PROXY_HOPS=1
EOF
  fi

  cat << EOF

# Server
PORT=3000
HOST=0.0.0.0

# Authentication
JWT_SECRET=${JWT_SECRET}

# Registration
REGISTRATION_OPEN=true

# Max upload size in bytes
MAX_UPLOAD_SIZE=${MAX_UPLOAD_SIZE}

# Mirrors used while building the image, for networks where the originals are
# blocked. Empty = the original registry. Picked by install.sh on each run.
NPM_REGISTRY=${NPM_REGISTRY}
DEBIAN_MIRROR=${DEBIAN_MIRROR}
EOF

  if [[ "$ENABLE_VOICE" == true ]]; then
    cat << EOF

# LiveKit Voice/Video
LIVEKIT_URL=wss://${DOMAIN}/livekit
LIVEKIT_API_KEY=${LIVEKIT_API_KEY}
LIVEKIT_API_SECRET=${LIVEKIT_API_SECRET}

# Activate the LiveKit service in Docker Compose
COMPOSE_PROFILES=voice
EOF
  else
    cat << EOF

# LiveKit Voice/Video (disabled)
# To enable: fill in credentials and add COMPOSE_PROFILES=voice
# LIVEKIT_URL=wss://${DOMAIN}/livekit
# LIVEKIT_API_KEY=
# LIVEKIT_API_SECRET=
EOF
  fi
} > .env

success ".env"

# -- livekit.yaml --------------------------------------------

# Always generate livekit.yaml so docker-compose config doesn't complain
# about a missing bind mount if someone inspects the full compose file.
if [[ "$ENABLE_VOICE" == true ]]; then
  # A known public IP is given to LiveKit directly; only without one does it
  # fall back to discovering it over STUN.
  if [[ -n "$PUBLIC_IP" ]]; then
    lk_ip_config="  use_external_ip: false
  node_ip: ${PUBLIC_IP}"
  else
    lk_ip_config="  use_external_ip: true"
  fi
  cat > livekit.yaml << EOF
# LiveKit Server Configuration
# Generated by install.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")

port: 7880

rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 60000
${lk_ip_config}

turn:
  enabled: true
  domain: ${DOMAIN}
  udp_port: 3478

keys:
  ${LIVEKIT_API_KEY}: ${LIVEKIT_API_SECRET}

room:
  auto_create: true
  empty_timeout: 300
  departure_timeout: 20

logging:
  level: info
EOF
  success "livekit.yaml"
else
  cat > livekit.yaml << EOF
# LiveKit is disabled. Run install.sh and enable voice to configure.
port: 7880
keys: {}
logging:
  level: info
EOF
  info "livekit.yaml (placeholder -- voice disabled)"
fi

# -- Data directory ------------------------------------------

mkdir -p ./data/uploads
success "data/"

# -- Phase 5: TLS certificate (All-in-One only) -------------
# nginx serves HTTPS from /etc/letsencrypt but cannot obtain a certificate
# itself, and will not start without one. So the first certificate is issued
# here with certbot's standalone server while port 80 is still free, and
# renewal (renew-cert.sh) is scheduled daily; it answers the challenge through
# the webroot nginx serves at /.well-known/acme-challenge/.
# Choosing All-in-One accepts the Let's Encrypt Subscriber Agreement.

mkdir -p ./certbot-www
CERTBOT_IMAGE="${CERTBOT_IMAGE:-certbot/certbot:v3.0.1}"

if [[ "$DEPLOY_MODE" == "allinone" ]]; then
  step "TLS certificate"
  # /etc/letsencrypt/live is root-only, so look through a container.
  if $DOCKER run --rm -v /etc/letsencrypt:/etc/letsencrypt:ro alpine \
      test -f "/etc/letsencrypt/live/${DOMAIN_HOST}/fullchain.pem" 2>/dev/null; then
    success "Certificate for ${DOMAIN_HOST} already present"
  else
    if [[ "$NGINX_RUNNING" == true ]]; then
      info "Stopping the running nginx so certbot can answer on port 80..."
      $DOCKER stop nginx >/dev/null
    fi
    certbot_email_args=(--register-unsafely-without-email)
    if [[ -n "$CERTBOT_EMAIL" ]]; then
      certbot_email_args=(--email "$CERTBOT_EMAIL")
    fi
    info "Requesting a Let's Encrypt certificate for ${DOMAIN_HOST} (port 80 must be reachable from the internet)..."
    if $DOCKER run --rm -p 80:80 -v /etc/letsencrypt:/etc/letsencrypt "$CERTBOT_IMAGE" \
        certonly --standalone --non-interactive --agree-tos "${certbot_email_args[@]}" -d "$DOMAIN_HOST"; then
      success "Certificate issued for ${DOMAIN_HOST}"
    else
      error "Could not get a certificate for ${DOMAIN_HOST}. Without one nginx cannot start."
      error "Check that ${DOMAIN_HOST} resolves to this host and port 80 is open to the internet, then re-run ./install.sh."
      exit 1
    fi
  fi

  # Daily renewal. certbot only renews within 30 days of expiry, so most runs
  # change nothing. /etc/cron.d is system config, written with sudo when needed.
  cron_line="17 3 * * * root \"$(pwd)/renew-cert.sh\" >> /var/log/patogh-certbot.log 2>&1"
  if [[ -d /etc/cron.d ]] && echo "$cron_line" | $SUDO tee /etc/cron.d/patogh-certbot >/dev/null; then
    success "Certificate renewal scheduled (/etc/cron.d/patogh-certbot, daily)"
  else
    warn "Could not schedule renewal. Add this line to root's crontab yourself:"
    warn "  $cron_line"
  fi
fi

# -- Phase 6: Build & Deploy --------------------------------

step "Deploying Patogh"

# AGPL-3.0 section 13 source offer: bake the running build's git commit into the image
# so GET /api/instance/info advertises the exact source version. Passed straight
# to the build as --build-arg (survives the sudo/non-sudo $COMPOSE split, unlike
# an exported env var). Empty when this isn't a git checkout (e.g. tarball
# install) or git is unavailable -> the server treats the commit as null. A pulled
# prebuilt image already carries the commit baked at CI build time.
BUILD_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo '')"

build_from_source() {
  if [[ -n "$BUILD_COMMIT" ]]; then
    info "Building Patogh image from commit ${BUILD_COMMIT} (first build takes a few minutes)..."
  else
    info "Building Patogh image (first build takes a few minutes)..."
  fi
  $COMPOSE build --build-arg PATOGH_COMMIT="$BUILD_COMMIT"
}

# Default path: pull the prebuilt multi-arch image (fast, and it spares weak/ARM
# hosts the ~1.6GB local build that OOMs small boxes). Fall back to a from-source
# build if the image can't be pulled (not published yet, private, or offline), or
# if the operator forces a build (PATOGH_BUILD=true -- e.g. running a fork).
# Records which path this install actually took, so the admin Updates panel can
# say which it is.
# Written *after* the decision resolves rather than alongside the rest of .env,
# so a fallback-to-build is recorded truthfully instead of as the pull that was
# attempted first.
record_install_channel() {
  local channel="$1"
  local tmp
  if [[ -f .env ]] && grep -q '^PATOGH_INSTALL_CHANNEL=' .env; then
    # Rewritten through a temp file rather than with sed -i: GNU and BSD sed
    # disagree about -i, and this script is also read on macOS.
    tmp="$(mktemp)"
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == PATOGH_INSTALL_CHANNEL=* ]]; then
        printf '%s\n' "PATOGH_INSTALL_CHANNEL=${channel}"
      else
        printf '%s\n' "$line"
      fi
    done < .env > "$tmp"
    mv "$tmp" .env
  else
    cat >> .env << EOF

# How this instance gets its image: prebuilt | source
# Written by install.sh after the pull-or-build decision; the admin Updates panel shows it.
PATOGH_INSTALL_CHANNEL=${channel}
EOF
  fi
}

if [[ "${PATOGH_BUILD:-false}" == "true" ]]; then
  info "PATOGH_BUILD=true -- building from source (skipping the prebuilt image)."
  build_from_source
  record_install_channel source
else
  image_ref="${PATOGH_IMAGE:-ghcr.io/farzinns83/patogh}:${PATOGH_IMAGE_TAG:-latest}"
  registry_host="${image_ref%%/*}"
  registry_code="$(http_code "https://${registry_host}/v2/" 8)"
  # The Docker Hub mirrors above do not cover other registries; when this one is
  # blocked, skip a pull that would only hang and build instead.
  if [[ "$registry_code" != "200" && "$registry_code" != "401" ]]; then
    warn "${registry_host} is unreachable from this server -- skipping the prebuilt image."
  else
    info "Fetching prebuilt image ${image_ref} ..."
  fi
  if [[ ( "$registry_code" == "200" || "$registry_code" == "401" ) ]] && $COMPOSE pull patogh; then
    success "Pulled prebuilt image"
    record_install_channel prebuilt
  elif $DOCKER image inspect "$image_ref" >/dev/null 2>&1; then
    # Pull failed (offline / registry hiccup / private) but a usable copy is
    # already on this host (a prior run, an air-gapped `docker load`, or a
    # previous from-source build tagged under this ref) -- use it instead of
    # forcing a needless multi-hundred-MB rebuild.
    warn "Could not pull ${image_ref} -- using the copy already present on this host."
    record_install_channel prebuilt
  else
    warn "Prebuilt image unavailable (not published yet, private, or offline)."
    warn "Falling back to a from-source build -- slower, and heavy on low-RAM/ARM hosts."
    build_from_source
    record_install_channel source
  fi
fi

info "Starting services..."
$COMPOSE up -d

# Wait for health check
info "Waiting for Patogh to become healthy..."
healthy=false
for i in $(seq 1 60); do
  status=$($DOCKER inspect patogh --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  if [[ "$status" == "healthy" ]]; then
    healthy=true
    break
  fi
  sleep 2
done

if [[ "$healthy" == true ]]; then
  success "Patogh is healthy"
else
  warn "Health check hasn't passed yet. Check logs: docker compose logs patogh"
fi

# -- Phase 7: Post-deploy reachability check ----------------
# What's verifiable differs by mode:
#   allinone      -> prove https://DOMAIN works end-to-end (nginx serves a valid,
#                   publicly-trusted certificate AND the app answers over it).
#   proxy/tunnel  -> prove the app answers on its loopback port (your edge then
#                   fronts it); TLS is your proxy/tunnel's job, not ours to test.

https_status="skipped"
app_reachable="unknown"

if [[ "$DEPLOY_MODE" == "allinone" ]]; then
  if [[ "$healthy" == true ]]; then
    step "Verifying HTTPS"
    https_status="pending"
    # `curl --resolve DOMAIN:443:127.0.0.1` connects to the LOCAL nginx but
    # presents the real SNI/Host and does full certificate verification. A pass
    # proves a valid public cert is installed AND the app answers over it -- and
    # it's hairpin-safe (many self-hosted boxes can't reach their own public IP).
    info "Checking HTTPS on ${DOMAIN}..."
    for i in $(seq 1 15); do
      if curl -fsS --max-time 6 --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/api/health" >/dev/null 2>&1; then
        https_status="live"
        break
      fi
      sleep 2
    done
    if [[ "$https_status" == "live" ]]; then
      success "HTTPS is live -- a valid TLS certificate is installed and Patogh is serving over it."
    else
      warn "HTTPS is not answering yet -- check: docker compose logs nginx"
    fi
  fi
else
  if [[ "$healthy" == true ]]; then
    step "Verifying the app"
    app_reachable="no"
    for i in $(seq 1 10); do
      if curl -fsS --max-time 6 "http://127.0.0.1:${APP_PORT_FINAL}/api/health" >/dev/null 2>&1; then
        app_reachable="yes"
        break
      fi
      sleep 1
    done
    if [[ "$app_reachable" == "yes" ]]; then
      success "Patogh is answering on http://127.0.0.1:${APP_PORT_FINAL} -- point your $( [[ "$DEPLOY_MODE" == tunnel ]] && echo tunnel || echo 'reverse proxy') at it."
    else
      warn "Could not reach http://127.0.0.1:${APP_PORT_FINAL}/api/health yet -- check: docker compose logs patogh"
    fi
  fi
fi

# -- Reverse-proxy / tunnel snippet generators --------------
# Paste-ready configs with WebSocket upgrade, X-Forwarded-*, and a body-size cap
# already correct. Printed for proxy/tunnel modes so the operator's edge routes
# to 127.0.0.1:APP_PORT (and, if voice is on, /livekit -> the host LiveKit).

hr()   { echo "------------------------------------------------------------"; }
snip() { echo "$*"; }

# Body-size cap in the proxy should match the app's MAX_UPLOAD_SIZE. Express it in
# MB for the human-facing proxy directives (round up so the proxy never rejects a
# body the app would accept).
max_mb=$(( (MAX_UPLOAD_SIZE + 1048575) / 1048576 ))

print_nginx_snippet() {
  snip "nginx  -- add the map once inside http { }, then a server block:"
  hr
  cat << EOF
# --- inside http { } (once) --------------------------------
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen ${DOMAIN_PORT:-443} ssl;
    server_name ${DOMAIN_HOST};

    # Your TLS certs (certbot, your proxy manager, etc.):
    # ssl_certificate     /etc/letsencrypt/live/${DOMAIN_HOST}/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_HOST}/privkey.pem;

    client_max_body_size ${max_mb}m;   # match MAX_UPLOAD_SIZE (${MAX_UPLOAD_SIZE} bytes)
EOF
  if [[ "$ENABLE_VOICE" == true ]]; then
    cat << EOF

    # Voice signaling -> host-networked LiveKit (strips the /livekit prefix):
    location /livekit/ {
        proxy_pass http://127.0.0.1:7880/;
        proxy_http_version 1.1;
        proxy_set_header Host              \$http_host;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \$connection_upgrade;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
EOF
  fi
  cat << EOF

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT_FINAL};
        proxy_http_version 1.1;
        # \$http_host, not \$host: \$host drops the port, and the app must see
        # the host clients actually use when the public port is not 443.
        proxy_set_header Host              \$http_host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host  \$http_host;
        # WebSocket upgrade (chat, live events, voice signaling):
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF
  hr
}

print_caddy_snippet() {
  snip "Caddy  -- if you run your OWN Caddy (it auto-handles WebSocket + HTTPS):"
  hr
  cat << EOF
${DOMAIN} {
EOF
  if [[ "$ENABLE_VOICE" == true ]]; then
    cat << EOF
    handle_path /livekit/* {
        reverse_proxy 127.0.0.1:7880
    }
    handle {
        reverse_proxy 127.0.0.1:${APP_PORT_FINAL}
    }
EOF
  else
    cat << EOF
    reverse_proxy 127.0.0.1:${APP_PORT_FINAL}
EOF
  fi
  cat << EOF
    request_body {
        max_size ${max_mb}MB
    }
}
EOF
  hr
}

print_traefik_snippet() {
  snip "Traefik -- dynamic (file-provider) config; Traefik handles WebSocket itself:"
  hr
  cat << EOF
http:
  routers:
    patogh:
      rule: "Host(\`${DOMAIN_HOST}\`)"
      entryPoints: [websecure]
      service: patogh
      tls:
        certResolver: letsencrypt
EOF
  if [[ "$ENABLE_VOICE" == true ]]; then
    cat << EOF
    patogh-livekit:
      rule: "Host(\`${DOMAIN_HOST}\`) && PathPrefix(\`/livekit\`)"
      entryPoints: [websecure]
      service: patogh-livekit
      priority: 100
      middlewares: [strip-livekit]
      tls:
        certResolver: letsencrypt
  middlewares:
    strip-livekit:
      stripPrefix:
        prefixes: ["/livekit"]
EOF
  fi
  cat << EOF
  services:
    patogh:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:${APP_PORT_FINAL}"
EOF
  if [[ "$ENABLE_VOICE" == true ]]; then
    cat << EOF
    patogh-livekit:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:7880"
EOF
  fi
  hr
}

print_tunnel_snippet() {
  snip "Cloudflare Tunnel -- ingress rule (cloudflared config.yml):"
  hr
  cat << EOF
tunnel: <YOUR-TUNNEL-ID>
credentials-file: /root/.cloudflared/<YOUR-TUNNEL-ID>.json

ingress:
  - hostname: ${DOMAIN}
    service: http://127.0.0.1:${APP_PORT_FINAL}
  - service: http_status:404
EOF
  hr
  echo "  Then map the hostname to the tunnel (once):"
  echo "    cloudflared tunnel route dns <YOUR-TUNNEL-ID> ${DOMAIN}"
}

# -- Phase 8: Summary ---------------------------------------

step "Patogh is running"

echo "  URL:       https://${DOMAIN}"
echo "  Mode:      ${DEPLOY_MODE}"
echo "  Voice:     $(if [[ "$ENABLE_VOICE" == true ]]; then echo 'Enabled'; else echo 'Disabled'; fi)"

if [[ "$DEPLOY_MODE" == "allinone" ]]; then
  case "$https_status" in
    live)    echo "  HTTPS:     Live" ;;
    pending) echo "  HTTPS:     Not live yet" ;;
  esac
  echo ""
  if [[ "$https_status" == "pending" ]]; then
    echo "  The app is up, but HTTPS isn't answering yet. Check that port 443 is open"
    echo "  to this host, then look at: docker compose logs -f nginx"
    echo ""
  fi
  echo "  Open https://${DOMAIN} to set up the server: you name it and become its owner."
  echo "  Certificate renewal runs daily from /etc/cron.d/patogh-certbot (./renew-cert.sh)."

  echo ""
  # Best-effort primary LAN IP (the address a router would port-forward to).
  LAN_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1 || true)
  echo "  Ports to open -- on this host's firewall (ufw / firewalld / cloud"
  echo "  security group) and, if the host is behind a router, also"
  echo "  port-forward them to this host${LAN_IP:+ (${LAN_IP})}:"
  echo ""
  echo "    80/TCP            HTTP  -- cert challenge + HTTP->HTTPS redirect      (required)"
  echo "    443/TCP           HTTPS -- web app, API, WebSocket, LiveKit signal   (required)"
  if [[ "$ENABLE_VOICE" == true ]]; then
    echo "    3478/UDP          TURN  -- WebRTC NAT traversal                       (voice)"
    echo "    7881/TCP          WebRTC TCP fallback                              (voice)"
    echo "    50000-60000/UDP   WebRTC media -- voice / video / screen-share      (voice)"
  fi
  echo ""
  echo "  80 and 443 must be reachable from the internet before HTTPS can come up."
  if [[ "$ENABLE_VOICE" == true ]]; then
    echo "  Voice/video won't connect until the voice ports above are reachable too."
  fi
  echo "  LiveKit's own signaling port (7880) stays internal -- do not forward it."

elif [[ "$DEPLOY_MODE" == "proxy" ]]; then
  echo ""
  echo "  Patogh listens on 127.0.0.1:${APP_PORT_FINAL} (loopback only -- never expose it directly)."
  echo "  Point your reverse proxy at it, then open https://${DOMAIN} to set up the server (you become its owner)."
  echo ""
  echo "  Paste one of these into your reverse proxy (WebSocket, X-Forwarded-*, and body cap already set):"
  echo ""
  print_nginx_snippet
  echo ""
  print_caddy_snippet
  echo ""
  print_traefik_snippet
  echo ""
  echo "  Nginx Proxy Manager / other GUI proxies: forward to 127.0.0.1:${APP_PORT_FINAL},"
  echo "  enable 'Websockets Support', and set client_max_body_size ${max_mb}m in the Advanced tab."
  if [[ "$ENABLE_VOICE" == true ]]; then
    echo ""
    echo "  Voice is enabled -- in addition to the /livekit route above, open these UDP/TCP"
    echo "  media ports on the firewall and forward them to this host:"
    echo "    3478/UDP          TURN  -- WebRTC NAT traversal"
    echo "    7881/TCP          WebRTC TCP fallback"
    echo "    50000-60000/UDP   WebRTC media -- voice / video / screen-share"
    echo "  Media flows host->client directly, NOT through your reverse proxy."
  fi

elif [[ "$DEPLOY_MODE" == "tunnel" ]]; then
  echo ""
  echo "  Patogh listens on 127.0.0.1:${APP_PORT_FINAL} (loopback only). Your tunnel fronts it."
  echo "  Once the ingress rule is live, open https://${DOMAIN} to set up the server (you become its owner)."
  echo ""
  print_tunnel_snippet
  echo ""
  echo "  Upload cap: MAX_UPLOAD_SIZE is set to ${max_mb}MB to stay under Cloudflare's 100MB"
  echo "  request-body limit. Raising it above ~100MB will make large uploads fail at the edge."
  echo ""
  echo "  Voice/video is not available over a tunnel -- WebRTC/UDP media can't traverse it."
  echo "  If you need voice, run Patogh behind a reverse proxy (proxy mode) with the"
  echo "  media ports opened, or use All-in-One with ports 80/443."
fi

echo ""
echo "  Commands (run from this directory):"
echo "    ./update.sh                     # Update (snapshot first, rolls back on failure)"
echo "    ./backup.sh                     # Database snapshot to data/backups/"
echo "    ./restore.sh                    # List / restore snapshots"
echo "    docker compose logs -f          # Watch logs"
echo "    docker compose restart          # Restart all services"
echo "    docker compose down             # Stop everything"
echo ""

