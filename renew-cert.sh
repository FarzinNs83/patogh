#!/usr/bin/env bash
# =============================================================================
#  renew-cert.sh -- renew the Let's Encrypt certificate (allinone mode) and
#                   reload nginx
#
#  install.sh runs it daily from /etc/cron.d/patogh-certbot. certbot only
#  renews within 30 days of expiry, so most runs change nothing.
#
#  Usage:
#    ./renew-cert.sh
#
#  Options: --help
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
  "") ;;
  -h | --help)
    printf '%s\n' "renew-cert.sh -- renew the Let's Encrypt certificate and reload nginx." \
      "" "Usage:" "  ./renew-cert.sh" "" "Runs daily from /etc/cron.d/patogh-certbot."
    exit 0
    ;;
  *)
    printf '[x] Unknown option: %s (try --help).\n' "$1" >&2
    exit 1
    ;;
esac

CERTBOT_IMAGE="${CERTBOT_IMAGE:-certbot/certbot:v3.0.1}"

docker run --rm \
  -v /etc/letsencrypt:/etc/letsencrypt \
  -v "$(pwd)/certbot-www:/var/www/certbot" \
  "$CERTBOT_IMAGE" renew --webroot -w /var/www/certbot --quiet

# Reload even when nothing renewed: cheap, and it picks up any earlier renewal.
docker compose exec -T nginx nginx -s reload
