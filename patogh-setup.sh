#!/usr/bin/env bash
# =============================================================================
#  patogh-setup.sh -- Patogh (chat, voice and video for one community) with
#                     Docker, behind nginx with a Let's Encrypt certificate
#
#  What it does
#    1. asks for the domain and checks that it points here
#    2. installs Docker and the compose plugin (from download.docker.com, or
#       from the distro packages if that is unreachable). On a server in Iran,
#       where Docker Hub, npm and Debian are blocked, it finds mirrors that
#       answer and uses them
#    3. clones the Patogh repository to /opt/patogh, writes its .env (secrets
#       are generated once and kept) and livekit.yaml, builds the image and
#       starts it on 127.0.0.1 with LiveKit for voice and video
#    4. nginx in front (websockets, /livekit, no upload cap: the app enforces
#       its own) and a Let's Encrypt certificate (HTTP-01, webroot) with
#       auto-renewal
#
#  Then open https://<domain>: the first visitor names the server and becomes
#  its owner. Re-running the script updates Patogh (database snapshot, git
#  pull, rebuild, restart) and keeps its settings.
#
#  This file is independent from dns-setup.sh, n8n-setup.sh, front-deploy.sh
#  and back-deploy.sh: its own nginx file, certificate and folder. When
#  dns-setup.sh owns :443 (nginx stream SNI relay), Patogh listens on
#  127.0.0.1:10446 instead and the relay forwards its domain there.
#
#  Usage:
#    bash patogh-setup.sh                      (asks for the domain)
#    bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/patogh/main/patogh-setup.sh)
#
#  Options: --help
# =============================================================================
set -Eeuo pipefail

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

SCRIPT_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Paths (overridable from the environment)
# ---------------------------------------------------------------------------
PS_DIR="${PS_DIR:-/opt/patogh}"
ENV_FILE="${PS_DIR}/.env"
LOG_FILE="${PS_LOG_FILE:-/var/log/patogh-setup.log}"
NGINX_CONF="${PS_NGINX_CONF:-/etc/nginx/conf.d/patogh.conf}"
ACME_ROOT="${PS_ACME_ROOT:-/var/www/patogh-acme}"
TLS_DIR="${PS_TLS_DIR:-/etc/letsencrypt/live}"
RENEW_HOOK="${PS_RENEW_HOOK:-/etc/letsencrypt/renewal-hooks/deploy/patogh-reload.sh}"
DS_STREAM_CONF="/etc/nginx/stream.d/dns-setup-relay.conf"
SNI_ROUTES_DIR="${PS_SNI_ROUTES_DIR:-/etc/nginx/sni-routes.d}"
SNI_MAP="${SNI_ROUTES_DIR}/patogh.map"
DEFAULT_REPO="https://github.com/FarzinNs83/patogh.git"

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
# plain http on purpose: the image's apt has no CA bundle, and apt checks
# the package signatures itself
DEBIAN_CANDIDATES=(
  http://mirror.arvancloud.ir
  http://linux-mirror.liara.ir
  http://mirror.atlantiscloud.ir
  http://mirrors.pardisco.co
  http://mirror2.chabokan.net
  http://mirror.kargadan.ir
)

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
DOMAIN=""
EMAIL=""
REPO=""
BRANCH=""
APP_PORT=""
TLS_PORT=""
REGISTRY_MIRROR=""
NPM_REGISTRY=""
DEBIAN_MIRROR=""
VOICE=""
SKIP_DNS=0
OPEN_FIREWALL=0
SWAP=1
STAGING=0

EXISTING=0
PUBLIC_IPV4=""
NGINX_RESTART=0
COMPOSE_BIN=()
OS_ID=""
OS_CODENAME=""
JWT_SECRET=""
LIVEKIT_API_KEY=""
LIVEKIT_API_SECRET=""
MAX_UPLOAD_SIZE=""

say() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat << 'EOF'
patogh-setup.sh -- install Patogh (chat, voice and video for one community)
with Docker, behind nginx with a Let's Encrypt certificate.

Usage:
  sudo bash patogh-setup.sh [options]     (asks for the domain)

Options:
  -e, --email <address>     Let's Encrypt account email (default: none)
      --no-voice            no voice / video (no LiveKit, no UDP ports)
      --port <n>            local port Patogh listens on behind nginx
                            (default: 3080)
      --tls-port <n>        loopback HTTPS port when dns-setup.sh owns :443
                            (default: 10446)
      --registry-mirror <url>  Docker Hub mirror, e.g. https://docker.arvancloud.ir
                            (default: found automatically when Docker Hub is blocked)
      --npm-registry <url>  npm registry for the build (default: found
                            automatically when registry.npmjs.org is blocked)
      --debian-mirror <url> Debian mirror for the build (http://host, serving
                            /debian; found automatically when blocked)
      --repo <url>          git repository (default: FarzinNs83/patogh)
      --branch <name>       branch (default: main)
      --skip-dns-check      do not verify that the domain points to this server
      --open-firewall       open 80, 443 and the voice ports in ufw / firewalld
      --no-swap             do not add a 2 GB swap file on small servers
      --staging             Let's Encrypt staging CA (testing only)
  -h, --help                show this help

Then open https://<domain>: the first visitor names the server and becomes
its owner. Do it right away.

Re-running the script updates Patogh: database snapshot, git pull, rebuild,
restart. Settings and secrets are kept.

From /opt/patogh:
  ./backup.sh               database snapshot to data/backups/
  ./restore.sh              list / restore snapshots
  docker compose logs -f    logs
EOF
}

# ---------------------------------------------------------------------------
# Basics
# ---------------------------------------------------------------------------
_on_err() {
  local rc=$? line=$1
  trap - ERR
  printf '\n[x] Setup failed at line %s (exit %s). Log: %s\n' "$line" "$rc" "$LOG_FILE" >&2
  exit "$rc"
}

require_root() {
  if [[ ${EUID} -eq 0 ]]; then
    return 0
  fi
  if command -v sudo > /dev/null 2>&1; then
    if [[ ! -f $0 ]]; then
      die "This one-liner must run as root. Run 'sudo -i' first, then re-run it."
    fi
    exec sudo -E bash "$(readlink -f "$0")" "$@"
  fi
  die "This script must be run as root."
}

setup_logging() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

load_os() {
  local f pretty id like codename ubuntu_codename
  for f in /etc/os-release /usr/lib/os-release; do
    [[ -r $f ]] || continue
    # shellcheck disable=SC1090
    pretty=$(. "$f" && printf '%s' "${PRETTY_NAME:-${ID:-unknown}}")
    # shellcheck disable=SC1090
    id=$(. "$f" && printf '%s' "${ID:-}")
    # shellcheck disable=SC1090
    like=$(. "$f" && printf '%s' "${ID_LIKE:-}")
    # shellcheck disable=SC1090
    codename=$(. "$f" && printf '%s' "${VERSION_CODENAME:-}")
    # shellcheck disable=SC1090
    ubuntu_codename=$(. "$f" && printf '%s' "${UBUNTU_CODENAME:-}")
    if [[ $id == ubuntu || $id == debian ]]; then
      OS_ID=$id
      OS_CODENAME=$codename
    elif [[ $like == *ubuntu* && -n $ubuntu_codename ]]; then
      OS_ID=ubuntu
      OS_CODENAME=$ubuntu_codename
    elif [[ $like == *debian* ]]; then
      OS_ID=debian
      OS_CODENAME=$codename
    fi
    if [[ ${pretty,,} != *ubuntu* && ${pretty,,} != *debian* ]]; then
      warn "This script targets Ubuntu/Debian; '${pretty}' is untested."
    fi
    say "OS: ${pretty}"
    return 0
  done
  die "Cannot read /etc/os-release; unsupported OS."
}

normalize_domain() {
  local d=$1
  d=${d#*://}
  d=${d%%/*}
  d=${d%%:*}
  d=${d%.}
  printf '%s\n' "$d" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

is_domain() {
  [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

is_email() {
  [[ $1 =~ ^[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]]
}

is_port() {
  [[ $1 =~ ^[0-9]+$ ]] && (($1 >= 1 && $1 <= 65535))
}

port_in_use() {
  ss -ltn 2> /dev/null | awk -v p=":${1}" '$4 ~ p"$" {found=1} END {exit !found}'
}

port_holder() {
  ss -ltnp 2> /dev/null | awk -v p=":${1}$" '$4 ~ p && !found {print; found=1}'
}

ipv6_enabled() {
  [[ -f /proc/net/if_inet6 ]]
}

public_ipv4() {
  local url ip
  for url in https://api4.ipify.org https://ipv4.icanhazip.com https://4.ident.me; do
    ip=$(curl -4 -fsS --max-time 5 "$url" 2> /dev/null | tr -d '[:space:]"') || true
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

resolve_ipv4() {
  local ip=""
  ip=$(getent ahostsv4 "$1" 2> /dev/null | awk 'NR == 1 {print $1}') || true
  printf '%s\n' "$ip"
}

# HTTP status of a URL, or 000 when unreachable
http_code() { # url [timeout]
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-10}" "$1" 2> /dev/null) || true
  printf '%s\n' "${code:-000}"
}

svc_active() {
  systemctl is-active --quiet "$1" 2> /dev/null
}

apt_update() {
  apt-get -o DPkg::Lock::Timeout=600 update -qq
}

apt_install() {
  command -v apt-get > /dev/null 2>&1 || die "apt-get is required to install: $*"
  apt-get -o DPkg::Lock::Timeout=600 install -y -qq "$@"
}

apt_has() {
  apt-cache show "$1" > /dev/null 2>&1
}

ensure_base_packages() {
  local missing=() p
  for p in curl git openssl python3; do
    command -v "$p" > /dev/null 2>&1 || missing+=("$p")
  done
  command -v ss > /dev/null 2>&1 || missing+=(iproute2)
  [[ -d /etc/ssl/certs ]] || missing+=(ca-certificates)
  if ((${#missing[@]} == 0)); then
    return 0
  fi
  say "Installing packages: ${missing[*]}"
  apt_update || die "apt-get update failed."
  apt_install "${missing[@]}" || die "Could not install: ${missing[*]}"
}

# ---------------------------------------------------------------------------
# Settings: the .env of a previous install is the source of truth
# ---------------------------------------------------------------------------
env_get() { # key
  [[ -r $ENV_FILE ]] || return 0
  sed -n "s/^${1}=//p" "$ENV_FILE" | sed -n '1p'
}

load_settings() {
  local profiles
  if [[ -s $ENV_FILE ]]; then
    EXISTING=1
    say "Patogh is already installed in ${PS_DIR}; updating it."
  fi
  [[ -n $APP_PORT ]] || APP_PORT=$(env_get APP_PORT)
  [[ -n $TLS_PORT ]] || TLS_PORT=$(env_get PATOGH_SETUP_TLS_PORT)
  [[ -n $EMAIL ]] || EMAIL=$(env_get CERTBOT_EMAIL)
  [[ -n $REPO ]] || REPO=$(env_get PATOGH_SETUP_REPO)
  [[ -n $BRANCH ]] || BRANCH=$(env_get PATOGH_SETUP_BRANCH)
  if [[ -z $VOICE ]]; then
    profiles=$(env_get COMPOSE_PROFILES)
    if ((EXISTING)) && [[ $profiles != *voice* ]]; then
      VOICE=0
    else
      VOICE=1
    fi
  fi
  JWT_SECRET=$(env_get JWT_SECRET)
  LIVEKIT_API_KEY=$(env_get LIVEKIT_API_KEY)
  LIVEKIT_API_SECRET=$(env_get LIVEKIT_API_SECRET)
  MAX_UPLOAD_SIZE=$(env_get MAX_UPLOAD_SIZE)

  : "${APP_PORT:=3080}" "${TLS_PORT:=10446}" "${REPO:=$DEFAULT_REPO}" "${BRANCH:=main}"
  : "${MAX_UPLOAD_SIZE:=104857600}"
  is_port "$APP_PORT" || die "Invalid --port '${APP_PORT}'."
  is_port "$TLS_PORT" && ((TLS_PORT != 80 && TLS_PORT != 443)) || die "Invalid --tls-port '${TLS_PORT}'."
  [[ $BRANCH =~ ^[A-Za-z0-9._/-]+$ ]] || die "Invalid branch '${BRANCH}'."
}

# ---------------------------------------------------------------------------
# Pre-checks
# ---------------------------------------------------------------------------
precheck_disk() {
  local avail
  avail=$(df -Pk / 2> /dev/null | awk 'NR == 2 {print $4}') || true
  if [[ $avail =~ ^[0-9]+$ ]] && ((avail < 5242880)); then
    die "At least 5 GB of free disk space is required for Docker and the image build (found $((avail / 1024)) MB)."
  fi
}

precheck_dns() {
  local resolved
  PUBLIC_IPV4=$(public_ipv4) || PUBLIC_IPV4=""
  if [[ $SKIP_DNS -eq 1 ]]; then
    warn "DNS verification skipped (--skip-dns-check)."
    return 0
  fi
  if [[ -z $PUBLIC_IPV4 ]]; then
    warn "Could not detect this server's public IPv4; skipping the DNS check."
    return 0
  fi
  resolved=$(resolve_ipv4 "$DOMAIN")
  if [[ -z $resolved ]]; then
    die "No A record for ${DOMAIN}. Create '${DOMAIN} A ${PUBLIC_IPV4}' (Cloudflare: DNS only / grey cloud) and re-run, or add --skip-dns-check."
  fi
  if [[ $resolved != "$PUBLIC_IPV4" ]]; then
    cat >&2 << EOF
[x] DNS mismatch for ${DOMAIN}
      domain resolves to : ${resolved}
      this server's IPv4 : ${PUBLIC_IPV4}
    Let's Encrypt validates the domain on port 80 of the address it points to,
    and voice / video connect to this address directly.
    Fix the A record (Cloudflare: proxy OFF / grey cloud) and re-run,
    or bypass this check with --skip-dns-check.
EOF
    exit 1
  fi
  say "DNS OK: ${DOMAIN} -> ${PUBLIC_IPV4}"

  # Let's Encrypt prefers IPv6: an AAAA record elsewhere fails the challenge.
  # (ahostsv6 maps a plain A record to ::ffff:a.b.c.d; that is not an AAAA.)
  local v6
  v6=$(getent ahostsv6 "$DOMAIN" 2> /dev/null | awk '$1 !~ /^::ffff:/ {print $1; exit}') || v6=""
  if [[ -n $v6 ]] && ! ip -6 addr show scope global 2> /dev/null | grep -qiF "inet6 ${v6}/"; then
    die "${DOMAIN} also has an AAAA (IPv6) record, ${v6}, that is not this server. Let's Encrypt checks IPv6 first, so the certificate would fail. Delete the AAAA record (or point it here) and re-run."
  fi
}

relay_active() {
  [[ -f $DS_STREAM_CONF ]]
}

# Every setup on the server needs its own (sub)domain.
precheck_domain_free() {
  local entry f key owner d
  for entry in "/etc/dns-setup/state.env|DS_DOMAIN|dns-setup.sh" "/root/3xui-info.env|XUI_DOMAIN|3xui-setup.sh" "/opt/n8n/.env|N8N_DOMAIN|n8n-setup.sh"; do
    IFS='|' read -r f key owner <<< "$entry"
    [[ -r $f ]] || continue
    d=$(sed -n -E "s/^${key}='?([^']*)'?$/\1/p" "$f" | sed -n '1p')
    if [[ $d == "$DOMAIN" ]]; then
      die "${DOMAIN} is already used by ${owner}. Give Patogh its own subdomain (e.g. chat.example.com)."
    fi
  done
  if [[ -f /etc/front-deploy/sites/${DOMAIN}.conf || -f /etc/back-deploy/apps/${DOMAIN}.conf ]]; then
    die "${DOMAIN} is already used by front-deploy.sh / back-deploy.sh. Give Patogh its own subdomain (e.g. chat.example.com)."
  fi
  d=$(env_get DOMAIN)
  if [[ -n $d && $d != "$DOMAIN" ]]; then
    die "Patogh in ${PS_DIR} is set up for ${d}. One Patogh per server; re-run without a domain to update it."
  fi
}

container_exists() {
  command -v docker > /dev/null 2>&1 || return 1
  docker inspect "$1" > /dev/null 2>&1
}

# A container named patogh from another folder (an install.sh run) would
# clash with this one: same container name, same ports.
precheck_old_install() {
  local wd
  container_exists patogh || return 0
  wd=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' patogh 2> /dev/null) || wd=""
  if [[ -n $wd && $wd != "$PS_DIR" ]]; then
    die "A patogh container from ${wd} is running. Stop it first (cd ${wd} && docker compose down), then re-run."
  fi
}

precheck_ports() {
  local p holder
  if relay_active; then
    if ! grep -qF "$SNI_ROUTES_DIR" "$DS_STREAM_CONF"; then
      die "The dns-setup.sh relay on this server is too old for other sites. Re-run the current dns-setup.sh first, then this script."
    fi
    say "dns-setup.sh owns TCP/443; Patogh goes behind its SNI relay (127.0.0.1:${TLS_PORT})."
    if port_in_use "$TLS_PORT"; then
      holder=$(port_holder "$TLS_PORT") || true
      [[ $holder == *'"nginx"'* ]] || die "TCP/${TLS_PORT} is in use: ${holder:-unknown}. Pick another port with --tls-port."
    fi
  fi
  for p in 80 443; do
    port_in_use "$p" || continue
    holder=$(port_holder "$p") || true
    [[ $holder == *'"nginx"'* ]] && continue
    die "TCP/${p} is in use by another program: ${holder:-unknown}. Free it (Apache? Caddy? x-ui? an old Patogh nginx container?) and re-run."
  done
  if port_in_use "$APP_PORT"; then
    holder=$(port_holder "$APP_PORT") || true
    if [[ $holder != *docker-proxy* ]] || ! container_exists patogh; then
      die "TCP/${APP_PORT} is in use: ${holder:-unknown}. Pick another one with --port."
    fi
  fi
  if ((VOICE)); then
    for p in 7880 7881; do
      port_in_use "$p" || continue
      holder=$(port_holder "$p") || true
      [[ $holder == *livekit* ]] && continue
      die "TCP/${p} (LiveKit) is in use: ${holder:-unknown}. Free it, or re-run with --no-voice."
    done
  fi
}

# The image build (npm ci + Vite) needs 1-2 GB; small VPSes get hit by the
# OOM killer without some swap.
ensure_swap() {
  [[ $SWAP -eq 1 ]] || return 0
  local mem_kb swap_kb
  mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2> /dev/null) || return 0
  swap_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2> /dev/null) || return 0
  [[ $mem_kb =~ ^[0-9]+$ && $swap_kb =~ ^[0-9]+$ ]] || return 0
  if ((mem_kb >= 3000000 || swap_kb > 0)); then
    return 0
  fi
  if [[ -e /swapfile ]]; then
    warn "/swapfile exists but is not active; leaving it alone."
    return 0
  fi
  say "Only $((mem_kb / 1024)) MB RAM and no swap: adding a 2 GB swap file for the build ..."
  if ! { fallocate -l 2G /swapfile 2> /dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none; }; then
    rm -f /swapfile
    warn "Could not create /swapfile; continuing without swap."
    return 0
  fi
  chmod 600 /swapfile
  if ! { mkswap /swapfile > /dev/null && swapon /swapfile; }; then
    rm -f /swapfile
    warn "This server does not allow swap (container VPS?); continuing without it."
    return 0
  fi
  grep -qs '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
  say "Swap enabled (/swapfile, 2 GB)."
}

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------
detect_compose() {
  if docker compose version > /dev/null 2>&1; then
    COMPOSE_BIN=(docker compose)
  else
    return 1
  fi
}

# COMPOSE_FILE and COMPOSE_PROFILES come from .env in PS_DIR
compose() {
  [[ ${#COMPOSE_BIN[@]} -gt 0 ]] || detect_compose || die "docker compose is not installed."
  (cd "$PS_DIR" && "${COMPOSE_BIN[@]}" "$@")
}

install_docker_official() {
  [[ $OS_ID == ubuntu || $OS_ID == debian ]] || return 1
  [[ -n $OS_CODENAME ]] || return 1
  local arch key=/etc/apt/keyrings/docker.asc list=/etc/apt/sources.list.d/docker.list
  arch=$(dpkg --print-architecture)
  say "Adding the Docker apt repository (download.docker.com, ${OS_ID} ${OS_CODENAME}) ..."
  install -m 0755 -d /etc/apt/keyrings
  if ! curl -fsSL --max-time 30 "https://download.docker.com/linux/${OS_ID}/gpg" -o "$key"; then
    rm -f "$key"
    return 1
  fi
  chmod a+r "$key"
  printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/%s %s stable\n' \
    "$arch" "$key" "$OS_ID" "$OS_CODENAME" > "$list"
  if apt_update && apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    return 0
  fi
  rm -f "$list" "$key"
  apt_update || true
  return 1
}

# download.docker.com refuses Iranian IPs; the distro packages come from the
# server's own (usually local) apt mirror
install_docker_distro() {
  local pkg
  say "Installing Docker from the distribution repository (docker.io) ..."
  apt_update || die "apt-get update failed."
  apt_install docker.io || die "Could not install docker.io."
  # compose builds through buildx
  apt_has docker-buildx && apt_install docker-buildx || true
  for pkg in docker-compose-v2 docker-compose-plugin; do
    if apt_has "$pkg" && apt_install "$pkg"; then
      return 0
    fi
  done
  die "Docker is installed but no compose v2 package is available (docker-compose-v2)."
}

install_docker() {
  local pkg
  if command -v docker > /dev/null 2>&1 && detect_compose; then
    say "Docker is already installed: $(docker --version 2> /dev/null || printf '?')"
  else
    if command -v docker > /dev/null 2>&1; then
      say "Docker is installed but compose is missing; adding it ..."
      apt_update || true
      for pkg in docker-compose-plugin docker-compose-v2; do
        if apt_has "$pkg" && apt_install "$pkg"; then
          break
        fi
      done
    elif ! install_docker_official; then
      warn "download.docker.com is unreachable or failed; falling back to the distro packages."
      install_docker_distro
    fi
    detect_compose || die "docker compose is still missing after the installation."
    say "Installed: $(docker --version 2> /dev/null || printf 'docker')"
  fi
  systemctl enable --now docker > /dev/null 2>&1 || true
  svc_active docker || systemctl start docker || die "The Docker service does not start (journalctl -u docker)."
}

# Docker Hub gives Iranian IPs a 403 on its token service.
configure_registry_mirror() {
  local mirrors=() m code f=/etc/docker/daemon.json
  if [[ -n $REGISTRY_MIRROR ]]; then
    mirrors=("$REGISTRY_MIRROR")
  elif [[ $(http_code 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/alpine:pull') == 200 ]]; then
    say "Docker Hub is reachable directly."
    return 0
  else
    warn "Docker Hub is blocked from this server; looking for a mirror that answers ..."
    for m in "${DOCKER_MIRROR_CANDIDATES[@]}"; do
      code=$(http_code "${m}/v2/" 8)
      # a registry answers /v2/ with 200, or 401 when it wants a token
      if [[ $code == 200 || $code == 401 ]]; then
        mirrors+=("$m")
        say "  ${m}"
      fi
    done
    ((${#mirrors[@]} > 0)) || die "Docker Hub is blocked and none of the known mirrors answered. Re-run with --registry-mirror https://<mirror>."
  fi
  install -d -m 755 /etc/docker
  if python3 - "$f" "${mirrors[@]}" << 'PY'; then
import json, os, sys
path, mirrors = sys.argv[1], sys.argv[2:]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as fh:
        data = json.load(fh)
if data.get("registry-mirrors") == mirrors:
    sys.exit(3)  # unchanged
data["registry-mirrors"] = mirrors
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
    say "Docker now pulls through: ${mirrors[*]}"
    systemctl restart docker || die "Docker did not restart with the new ${f}."
  elif [[ $? -ne 3 ]]; then
    die "Could not update ${f} (is it valid JSON?)."
  fi
}

# npm and Debian are used inside the image build.
pick_build_mirrors() {
  local m
  if [[ -z $NPM_REGISTRY ]]; then
    if [[ $(http_code https://registry.npmjs.org/isarray) == 200 ]]; then
      say "npm registry is reachable directly."
    else
      warn "registry.npmjs.org is blocked; looking for an npm mirror ..."
      for m in "${NPM_CANDIDATES[@]}"; do
        if [[ $(http_code "${m}isarray" 15) == 200 ]]; then
          NPM_REGISTRY=$m
          say "  using ${m}"
          break
        fi
      done
      [[ -n $NPM_REGISTRY ]] || warn "No npm mirror answered; the build may fail. Re-run with --npm-registry <url>."
    fi
  fi
  if [[ -z $DEBIAN_MIRROR ]]; then
    if [[ $(http_code http://deb.debian.org/debian/dists/stable/Release) == 200 ]]; then
      say "Debian mirror is reachable directly."
    else
      warn "deb.debian.org is blocked; looking for a Debian mirror ..."
      for m in "${DEBIAN_CANDIDATES[@]}"; do
        if [[ $(http_code "${m}/debian/dists/stable/Release" 15) == 200 ]]; then
          DEBIAN_MIRROR=$m
          say "  using ${m}"
          break
        fi
      done
      [[ -n $DEBIAN_MIRROR ]] || warn "No Debian mirror answered; the build may fail. Re-run with --debian-mirror <url>."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Patogh
# ---------------------------------------------------------------------------
fetch_source() {
  if [[ -d ${PS_DIR}/.git ]]; then
    say "Pulling ${BRANCH} in ${PS_DIR} ..."
    git -C "$PS_DIR" remote set-url origin "$REPO"
    git -C "$PS_DIR" fetch --quiet origin "$BRANCH" || die "git fetch failed (is ${REPO} reachable?)."
    git -C "$PS_DIR" checkout --quiet "$BRANCH" 2> /dev/null || git -C "$PS_DIR" checkout --quiet -b "$BRANCH" "origin/${BRANCH}"
    git -C "$PS_DIR" merge --ff-only --quiet "origin/${BRANCH}" \
      || die "${PS_DIR} has local changes or diverged from origin/${BRANCH}; fix it by hand (git -C ${PS_DIR} status) and re-run."
  else
    [[ ! -e $PS_DIR ]] || [[ -z $(ls -A "$PS_DIR" 2> /dev/null) ]] || die "${PS_DIR} exists and is not a git checkout; move it away and re-run."
    say "Cloning ${REPO} (${BRANCH}) to ${PS_DIR} ..."
    git clone --quiet --depth 1 --branch "$BRANCH" "$REPO" "$PS_DIR" || die "git clone failed (is ${REPO} reachable?)."
  fi
  say "Commit: $(git -C "$PS_DIR" log -1 --format='%h %s')"
}

write_env() {
  local tmp
  if [[ -z $JWT_SECRET || $JWT_SECRET == change_me* ]]; then
    JWT_SECRET=$(openssl rand -hex 32)
  fi
  if ((VOICE)); then
    [[ -n $LIVEKIT_API_KEY ]] || LIVEKIT_API_KEY="API$(openssl rand -hex 8)"
    [[ -n $LIVEKIT_API_SECRET ]] || LIVEKIT_API_SECRET=$(openssl rand -hex 24)
  fi
  tmp=$(mktemp)
  {
    printf '# Patogh, written by patogh-setup.sh %s -- re-run the script to change it\n\n' "$(date -Is)"
    printf 'DOMAIN=%s\n' "$DOMAIN"
    printf 'DEPLOY_MODE=proxy\n'
    printf '# the host nginx is the proxy: the bundled one is dropped, the app is on 127.0.0.1:APP_PORT\n'
    printf 'COMPOSE_FILE=docker-compose.yml:docker-compose.proxy.yml\n'
    printf 'APP_PORT=%s\n\n' "$APP_PORT"
    printf 'PORT=3000\nHOST=0.0.0.0\n'
    printf 'JWT_SECRET=%s\n' "$JWT_SECRET"
    printf 'REGISTRATION_OPEN=true\n'
    printf 'MAX_UPLOAD_SIZE=%s\n\n' "$MAX_UPLOAD_SIZE"
    printf '# mirrors used by the image build, empty = the originals\n'
    printf 'NPM_REGISTRY=%s\n' "$NPM_REGISTRY"
    printf 'DEBIAN_MIRROR=%s\n' "$DEBIAN_MIRROR"
    printf 'PATOGH_INSTALL_CHANNEL=source\n\n'
    if ((VOICE)); then
      printf 'LIVEKIT_URL=wss://%s/livekit\n' "$DOMAIN"
      printf 'LIVEKIT_API_KEY=%s\n' "$LIVEKIT_API_KEY"
      printf 'LIVEKIT_API_SECRET=%s\n' "$LIVEKIT_API_SECRET"
      printf 'COMPOSE_PROFILES=voice\n\n'
    else
      printf '# voice / video disabled (--no-voice)\n\n'
    fi
    printf '# read by patogh-setup.sh on re-runs\n'
    printf 'CERTBOT_EMAIL=%s\n' "$EMAIL"
    printf 'PATOGH_SETUP_TLS_PORT=%s\n' "$TLS_PORT"
    printf 'PATOGH_SETUP_REPO=%s\n' "$REPO"
    printf 'PATOGH_SETUP_BRANCH=%s\n' "$BRANCH"
  } > "$tmp"
  install -m 600 "$tmp" "$ENV_FILE"
  rm -f "$tmp"
  say "Wrote ${ENV_FILE}."
}

write_livekit() {
  local ip_conf="  use_external_ip: true"
  if ((VOICE == 0)); then
    # compose mounts it even when the voice profile is off
    printf '# voice disabled (--no-voice)\nport: 7880\nkeys: {}\n' > "${PS_DIR}/livekit.yaml"
    return 0
  fi
  # LiveKit's own lookup uses Google's STUN servers, often unreachable from Iran
  [[ -n $PUBLIC_IPV4 ]] && ip_conf=$(printf '  use_external_ip: false\n  node_ip: %s' "$PUBLIC_IPV4")
  cat > "${PS_DIR}/livekit.yaml" << EOF
# written by patogh-setup.sh
port: 7880

rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 60000
${ip_conf}

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
  chmod 600 "${PS_DIR}/livekit.yaml"
}

# Before an update: a database snapshot to data/backups/ (restore.sh).
snapshot_db() {
  [[ $(docker inspect -f '{{.State.Running}}' patogh 2> /dev/null) == true ]] || return 0
  say "Taking a database snapshot before the update ..."
  if (cd "$PS_DIR" && ./backup.sh); then
    say "Snapshot written to ${PS_DIR}/data/backups/."
  else
    warn "The snapshot failed; continuing. Older snapshots are in ${PS_DIR}/data/backups/."
  fi
}

build_and_start() {
  local commit status i
  install -d -m 755 "${PS_DIR}/data/uploads"
  commit=$(git -C "$PS_DIR" rev-parse --short HEAD)
  say "Building the Patogh image (${commit}); the first build takes several minutes ..."
  (cd "$PS_DIR" && PATOGH_COMMIT=$commit "${COMPOSE_BIN[@]}" build patogh) \
    || die "The image build failed (output above). On a blocked network re-run with --npm-registry / --debian-mirror / --registry-mirror."
  say "Starting Patogh ..."
  compose up -d || die "docker compose up failed (see: cd ${PS_DIR} && docker compose logs)."

  say "Waiting for Patogh to become healthy ..."
  for i in $(seq 1 90); do
    status=$(docker inspect -f '{{.State.Health.Status}}' patogh 2> /dev/null) || status=""
    if [[ $status == healthy ]]; then
      say "Patogh is healthy."
      docker image prune -f > /dev/null 2>&1 || true
      return 0
    fi
    sleep 2
  done
  compose logs --tail 40 patogh || true
  die "Patogh did not become healthy within 3 minutes (logs above)."
}

# ---------------------------------------------------------------------------
# nginx and certificate
# ---------------------------------------------------------------------------
ensure_nginx() {
  local missing=()
  command -v nginx > /dev/null 2>&1 || missing+=(nginx)
  command -v certbot > /dev/null 2>&1 || missing+=(certbot)
  if ((${#missing[@]} > 0)); then
    say "Installing: ${missing[*]}"
    apt_update || die "apt-get update failed."
    apt_install "${missing[@]}" || die "Could not install: ${missing[*]}"
  fi
  [[ -d $(dirname "$NGINX_CONF") ]] || die "$(dirname "$NGINX_CONF") is missing; unexpected nginx layout."
  if ! grep -rqs 'conf\.d/\*\.conf' /etc/nginx/nginx.conf; then
    die "/etc/nginx/nginx.conf does not include conf.d/*.conf; add it and re-run."
  fi
  install -d -m 755 "${ACME_ROOT}/.well-known/acme-challenge"
}

nginx_version_ge() { # x.y.z
  local v
  v=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')
  [[ -n $v ]] || return 1
  [[ $(printf '%s\n%s\n' "$1" "$v" | sort -V | head -n 1) == "$1" ]]
}

listen_mode() { # what NGINX_CONF serves TLS on: public | loopback | none
  if grep -Eqs '^[[:space:]]*listen[[:space:]]+443[[:space:];]' "$NGINX_CONF"; then
    printf 'public\n'
  elif grep -Eqs '^[[:space:]]*listen[[:space:]]+127\.0\.0\.1:[0-9]+[[:space:]]+ssl' "$NGINX_CONF"; then
    printf 'loopback\n'
  else
    printf 'none\n'
  fi
}

# dns-setup.sh owns :443 with an nginx stream SNI relay; its map includes the
# files in SNI_ROUTES_DIR, so this one sends our domain to the loopback
# listener. Patogh then sees 127.0.0.1 as the client address.
sync_sni_route() { # http | https
  if [[ $1 == https ]] && relay_active; then
    install -d -m 755 "$SNI_ROUTES_DIR"
    {
      printf '# Managed by patogh-setup.sh -- SNI route for the dns-setup.sh relay\n'
      printf '"%s" 127.0.0.1:%s;\n' "$DOMAIN" "$TLS_PORT"
    } > "$SNI_MAP"
  else
    rm -f "$SNI_MAP"
  fi
}

proxy_headers() {
  printf '        proxy_http_version 1.1;\n'
  # $http_host, not $host: the app builds its URLs from the host clients use
  printf '        proxy_set_header Host $http_host;\n'
  printf '        proxy_set_header X-Real-IP $remote_addr;\n'
  printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
  printf '        proxy_set_header X-Forwarded-Proto $scheme;\n'
  printf '        proxy_set_header X-Forwarded-Host $http_host;\n'
  printf '        proxy_set_header Upgrade $http_upgrade;\n'
  printf '        proxy_set_header Connection $patogh_connection;\n'
  printf '        proxy_read_timeout 3600s;\n'
  printf '        proxy_send_timeout 3600s;\n'
}

render_nginx() { # http | https
  local mode=$1 v6=0 h2_listen="" h2_line="" before after
  ipv6_enabled && v6=1
  before=$(listen_mode)
  if nginx_version_ge 1.25.1; then
    h2_line='    http2 on;'
  else
    h2_listen=' http2'
  fi
  {
    printf '# Managed by patogh-setup.sh -- re-run the script instead of editing by hand\n'
    if [[ $mode == https ]]; then
      printf 'map $http_upgrade $patogh_connection {\n'
      printf '    default upgrade;\n'
      printf "    ''      close;\n"
      printf '}\n\n'
    fi
    printf 'server {\n'
    printf '    listen 80;\n'
    ((v6)) && printf '    listen [::]:80;\n'
    printf '    server_name %s;\n\n' "$DOMAIN"
    printf '    location ^~ /.well-known/acme-challenge/ {\n'
    printf '        root %s;\n' "${ACME_ROOT%/}"
    printf '        default_type "text/plain";\n'
    printf '    }\n'
    printf '    location / {\n'
    printf '        return 301 https://$host$request_uri;\n'
    printf '    }\n'
    printf '}\n'
    if [[ $mode == https ]]; then
      printf '\nserver {\n'
      if relay_active; then
        printf '    listen 127.0.0.1:%s ssl%s;\n' "$TLS_PORT" "$h2_listen"
      else
        printf '    listen 443 ssl%s;\n' "$h2_listen"
        ((v6)) && printf '    listen [::]:443 ssl%s;\n' "$h2_listen"
      fi
      [[ -n $h2_line ]] && printf '%s\n' "$h2_line"
      printf '    server_name %s;\n\n' "$DOMAIN"
      printf '    ssl_certificate     %s/%s/fullchain.pem;\n' "$TLS_DIR" "$DOMAIN"
      printf '    ssl_certificate_key %s/%s/privkey.pem;\n' "$TLS_DIR" "$DOMAIN"
      printf '    ssl_protocols TLSv1.2 TLSv1.3;\n'
      printf '    ssl_session_cache shared:patogh_ssl:10m;\n'
      printf '    ssl_session_timeout 1d;\n'
      printf '    add_header Strict-Transport-Security "max-age=31536000" always;\n\n'
      printf '    # the app enforces MAX_UPLOAD_SIZE; streaming keeps uploads off the disk\n'
      printf '    client_max_body_size 0;\n'
      printf '    proxy_request_buffering off;\n\n'
      if ((VOICE)); then
        printf '    # LiveKit signaling; the trailing slash strips /livekit\n'
        printf '    location /livekit/ {\n'
        printf '        proxy_pass http://127.0.0.1:7880/;\n'
        proxy_headers
        printf '    }\n\n'
      fi
      printf '    location / {\n'
      printf '        proxy_pass http://127.0.0.1:%s;\n' "$APP_PORT"
      proxy_headers
      printf '    }\n'
      printf '}\n'
    fi
  } > "$NGINX_CONF"
  sync_sni_route "$mode"

  # :443 moves between this http server and the stream relay: a reload would
  # have to hand the socket from one module to the other, a restart is safer
  after=$(listen_mode)
  if [[ $before != none && $after != none && $before != "$after" ]]; then
    NGINX_RESTART=1
  fi
}

apply_nginx() {
  local out
  if ! out=$(nginx -t 2>&1); then
    printf '%s\n' "$out" >&2
    die "nginx configuration test failed (see the output above)."
  fi
  systemctl enable nginx > /dev/null 2>&1 || true
  if svc_active nginx && ((NGINX_RESTART == 0)); then
    systemctl reload nginx || die "Could not reload nginx."
  else
    systemctl restart nginx || die "Could not start nginx."
  fi
  NGINX_RESTART=0
}

cert_valid() {
  local full="${TLS_DIR}/${DOMAIN}/fullchain.pem" san
  [[ -s $full && -s ${TLS_DIR}/${DOMAIN}/privkey.pem ]] || return 1
  openssl x509 -in "$full" -noout -checkend 86400 > /dev/null 2>&1 || return 1
  san=$(openssl x509 -in "$full" -noout -ext subjectAltName 2> /dev/null) || return 1
  [[ $san == *"DNS:${DOMAIN}"* ]]
}

obtain_certificate() {
  if cert_valid; then
    say "A valid certificate for ${DOMAIN} is already present."
    return 0
  fi
  local args=(
    certonly --webroot -w "$ACME_ROOT"
    -d "$DOMAIN" --cert-name "$DOMAIN"
    --agree-tos --no-eff-email
    --non-interactive --keep-until-expiring
  )
  if [[ -n $EMAIL ]]; then
    args+=(--email "$EMAIL")
  else
    args+=(--register-unsafely-without-email)
  fi
  [[ $STAGING -eq 1 ]] && args+=(--staging)

  acme_selftest
  say "Requesting a Let's Encrypt certificate for ${DOMAIN} (HTTP-01, webroot) ..."
  local out i
  out=$(mktemp)
  for i in 1 2 3 4 5 6; do
    certbot "${args[@]}" 2>&1 | tee "$out" && break
    # certbot.timer (or an older certbot container) may be renewing right now
    if grep -q 'Another instance of Certbot is already running' "$out" && ((i < 6)); then
      say "Another certbot is running; waiting 20 s ..."
      sleep 20
      continue
    fi
    rm -f "$out"
    warn "certbot failed (its reason is above). This server answers the challenge itself (checked), so"
    warn "Let's Encrypt cannot reach it: TCP/80 closed in the provider firewall, DNS (A / AAAA) not pointing"
    warn "here, or the Cloudflare proxy on. Details: /var/log/letsencrypt/letsencrypt.log"
    return 1
  done
  rm -f "$out"
  cert_valid || die "certbot reported success but the certificate in ${TLS_DIR}/${DOMAIN} is not usable."
  say "Certificate issued."
}

# Serves a test file the way Let's Encrypt will fetch it, through whatever
# holds :80 here. Catches a port 80 taken by something other than this nginx
# before certbot burns an attempt (Let's Encrypt limits failed validations).
acme_selftest() {
  local tok body holder
  tok="patogh-selftest-$(openssl rand -hex 8)"
  printf '%s\n' "$tok" > "${ACME_ROOT}/.well-known/acme-challenge/${tok}"
  body=$(curl -s --max-time 10 --resolve "${DOMAIN}:80:127.0.0.1" "http://${DOMAIN}/.well-known/acme-challenge/${tok}" 2> /dev/null) || body=""
  rm -f "${ACME_ROOT}/.well-known/acme-challenge/${tok}"
  [[ $body == "$tok" ]] && return 0
  holder=$(port_holder 80) || true
  die "Port 80 on this server does not serve the certificate challenge (held by: ${holder:-nothing}). Free TCP/80 for nginx and re-run."
}

# Containers left on 80/443 by an earlier install.sh run: its certbot (run
# with -p 80:80) and its bundled nginx. They would take the certificate
# challenge away from the host nginx.
free_ports_from_old_install() {
  local name image p wd
  command -v docker > /dev/null 2>&1 || return 0
  for p in 80 443; do
    while read -r name image; do
      [[ -n $name ]] || continue
      wd=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$name" 2> /dev/null) || wd=""
      # only Patogh's own: never someone else's nginx
      if [[ $image == certbot/* || ($name == nginx && -n $wd && -f ${wd}/docker-compose.proxy.yml) ]] \
        && { [[ $image == certbot/* ]] || grep -qs 'container_name: patogh' "${wd}/docker-compose.yml"; }; then
        say "Removing the container ${name} (${image}) left on TCP/${p} by an earlier install ..."
        docker rm -f "$name" > /dev/null
      fi
    done < <(docker ps --filter "publish=${p}" --format '{{.Names}} {{.Image}}' 2> /dev/null)
  done
}

install_renew_hook() {
  install -d -m 755 "$(dirname "$RENEW_HOOK")"
  cat > "$RENEW_HOOK" << 'EOF'
#!/bin/sh
# Added by patogh-setup.sh: reload nginx after a certificate renewal.
systemctl reload nginx 2>/dev/null || true
EOF
  chmod 755 "$RENEW_HOOK"
  systemctl enable --now certbot.timer > /dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
ufw_is_active() {
  command -v ufw > /dev/null 2>&1 || return 1
  [[ $(ufw status 2> /dev/null) == *'Status: active'* ]]
}

firewalld_is_active() {
  command -v firewall-cmd > /dev/null 2>&1 || return 1
  [[ $(firewall-cmd --state 2> /dev/null) == running ]]
}

firewall_ports() {
  printf '%s\n' 80/tcp 443/tcp
  ((VOICE)) && printf '%s\n' 3478/udp 7881/tcp 50000:60000/udp
  return 0
}

open_firewall_rules() {
  local p
  if ufw_is_active; then
    while read -r p; do
      ufw allow "$p" > /dev/null 2>&1 || true
    done < <(firewall_ports)
    say "Opened $(firewall_ports | tr '\n' ' ')in ufw."
  fi
  if firewalld_is_active; then
    while read -r p; do
      firewall-cmd --permanent --add-port="${p/:/-}" > /dev/null 2>&1 || true
    done < <(firewall_ports)
    firewall-cmd --reload > /dev/null 2>&1 || true
    say "Opened $(firewall_ports | tr '\n' ' ')in firewalld."
  fi
}

warn_closed_firewall() {
  [[ $OPEN_FIREWALL -eq 1 ]] && return 0
  if ufw_is_active; then
    warn "ufw is active and may block Patogh; re-run with --open-firewall or allow: $(firewall_ports | tr '\n' ' ')"
  fi
}

# ---------------------------------------------------------------------------
# Checks and output
# ---------------------------------------------------------------------------
verify_https() {
  local args=(-sS -o /dev/null -w '%{http_code}' --max-time 15 --resolve "${DOMAIN}:443:127.0.0.1")
  [[ $STAGING -eq 1 ]] && args+=(-k)
  local code
  code=$(curl "${args[@]}" "https://${DOMAIN}/api/health" 2> /dev/null) || code=000
  [[ $code == 200 ]]
}

print_summary() {
  local expires
  expires=$(openssl x509 -in "${TLS_DIR}/${DOMAIN}/fullchain.pem" -noout -enddate 2> /dev/null | sed -n 's/^notAfter=//p') || expires=""
  printf '\n'
  printf '==============================================================\n'
  if ((EXISTING)); then
    printf ' Patogh was updated\n'
  else
    printf ' Patogh was installed successfully\n'
  fi
  printf '==============================================================\n'
  printf ' URL         : https://%s/\n' "$DOMAIN"
  if ((EXISTING == 0)); then
    printf ' First visit : open the link right away -- the first visitor names\n'
    printf '               the server and becomes its owner.\n'
  fi
  printf ' Commit      : %s\n' "$(git -C "$PS_DIR" log -1 --format='%h %s')"
  printf ' Voice/video : %s\n' "$( ((VOICE)) && printf 'on (LiveKit)' || printf 'off')"
  printf ' Folder      : %s (settings: .env, data: data/)\n' "$PS_DIR"
  printf ' Certificate : expires %s, renews automatically\n' "${expires:-unknown}"
  if [[ $(listen_mode) == loopback ]]; then
    printf ' HTTPS       : 127.0.0.1:%s, reached through the dns-setup.sh relay on :443\n' "$TLS_PORT"
  fi
  printf '%s\n' '--------------------------------------------------------------'
  printf ' Ports       : TCP 80, 443'
  ((VOICE)) && printf ', UDP 3478, TCP 7881, UDP 50000-60000 (voice)'
  printf '\n               must be open in the provider firewall too.\n'
  printf ' Update      : run this script again\n'
  printf ' Backup      : cd %s && ./backup.sh   (restore: ./restore.sh)\n' "$PS_DIR"
  printf ' Logs        : cd %s && docker compose logs -f patogh\n' "$PS_DIR"
  printf '==============================================================\n'
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
parse_args() {
  while (($# > 0)); do
    case "$1" in
      -d | --domain)
        (($# >= 2)) || die "Option $1 needs a value."
        DOMAIN="$2"
        shift 2
        ;;
      -e | --email)
        (($# >= 2)) || die "Option $1 needs a value."
        EMAIL="$2"
        shift 2
        ;;
      --repo)
        (($# >= 2)) || die "Option $1 needs a value."
        REPO="$2"
        shift 2
        ;;
      --branch)
        (($# >= 2)) || die "Option $1 needs a value."
        BRANCH="$2"
        shift 2
        ;;
      --port)
        (($# >= 2)) || die "Option $1 needs a value."
        APP_PORT="$2"
        shift 2
        ;;
      --tls-port)
        (($# >= 2)) || die "Option $1 needs a value."
        TLS_PORT="$2"
        shift 2
        ;;
      --registry-mirror)
        (($# >= 2)) || die "Option $1 needs a value."
        REGISTRY_MIRROR="${2%/}"
        shift 2
        ;;
      --npm-registry)
        (($# >= 2)) || die "Option $1 needs a value."
        NPM_REGISTRY="${2%/}/"
        shift 2
        ;;
      --debian-mirror)
        (($# >= 2)) || die "Option $1 needs a value."
        DEBIAN_MIRROR="${2%/}"
        shift 2
        ;;
      --no-voice)
        VOICE=0
        shift
        ;;
      --skip-dns-check)
        SKIP_DNS=1
        shift
        ;;
      --open-firewall)
        OPEN_FIREWALL=1
        shift
        ;;
      --no-swap)
        SWAP=0
        shift
        ;;
      --staging)
        STAGING=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*)
        die "Unknown option: $1 (try --help)."
        ;;
      *)
        [[ -z $DOMAIN ]] || die "Unexpected argument: $1 (try --help)."
        DOMAIN="$1"
        shift
        ;;
    esac
  done
  if [[ -n $EMAIL ]] && ! is_email "$EMAIL"; then
    die "Invalid --email '${EMAIL}'."
  fi
  local u
  for u in "$REGISTRY_MIRROR" "$NPM_REGISTRY" "$DEBIAN_MIRROR"; do
    [[ -z $u || $u =~ ^https?://[^[:space:]]+$ ]] || die "Invalid mirror URL '${u}'."
  done
}

resolve_domain() {
  # a re-run updates the existing install without asking
  [[ -n $DOMAIN ]] || DOMAIN=$(env_get DOMAIN)
  if [[ -z $DOMAIN ]]; then
    [[ -t 0 ]] || die "No domain given and no terminal to ask for one."
    printf 'Domain for Patogh (e.g. chat.example.com): '
    read -r DOMAIN || die "No input."
  fi
  DOMAIN=$(normalize_domain "$DOMAIN")
  if [[ -z $DOMAIN ]] || ! is_domain "$DOMAIN"; then
    die "Invalid domain '${DOMAIN}'. Use something like chat.example.com."
  fi
}

install_all() {
  parse_args "$@"
  resolve_domain
  setup_logging
  trap '_on_err $LINENO' ERR

  say "=== patogh-setup ${SCRIPT_VERSION}: Patogh + Docker + nginx + Let's Encrypt ==="
  say "domain : ${DOMAIN}"

  load_os
  ensure_base_packages
  load_settings
  precheck_disk
  precheck_dns
  precheck_domain_free
  precheck_old_install
  free_ports_from_old_install
  precheck_ports
  ensure_swap

  # --- 1. Docker and mirrors ---------------------------------------------
  install_docker
  configure_registry_mirror
  pick_build_mirrors

  # --- 2. Patogh -----------------------------------------------------------
  ((EXISTING)) && snapshot_db
  fetch_source
  write_env
  write_livekit
  build_and_start

  # --- 3. nginx (port 80 first: needed for the ACME challenge) ------------
  ensure_nginx
  [[ $OPEN_FIREWALL -eq 1 ]] && open_firewall_rules
  warn_closed_firewall
  if cert_valid; then
    render_nginx https
  else
    render_nginx http
  fi
  apply_nginx

  # --- 4. certificate -----------------------------------------------------
  obtain_certificate || die "Could not obtain a certificate for ${DOMAIN}. Fix the cause above and re-run."
  install_renew_hook
  render_nginx https
  apply_nginx

  # --- 5. check -----------------------------------------------------------
  if verify_https; then
    say "HTTPS check OK: https://${DOMAIN}/api/health"
  else
    warn "https://${DOMAIN}/api/health did not answer 200 through nginx; check: nginx -t, cd ${PS_DIR} && docker compose logs patogh"
  fi
  print_summary
}

main() {
  case "${1-}" in
    -h | --help)
      usage
      exit 0
      ;;
  esac
  require_root "$@"
  install_all "$@"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
