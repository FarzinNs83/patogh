#!/usr/bin/env bash
# Renew the Let's Encrypt certificate (All-in-One mode) and reload nginx.
# install.sh schedules this daily in /etc/cron.d/patogh-certbot. certbot only
# renews within 30 days of expiry, so most runs change nothing.
set -euo pipefail
cd "$(dirname "$0")"

CERTBOT_IMAGE="${CERTBOT_IMAGE:-certbot/certbot:v3.0.1}"

docker run --rm \
  -v /etc/letsencrypt:/etc/letsencrypt \
  -v "$(pwd)/certbot-www:/var/www/certbot" \
  "$CERTBOT_IMAGE" renew --webroot -w /var/www/certbot --quiet

# Reload even when nothing renewed: cheap, and it picks up any earlier renewal.
docker compose exec -T nginx nginx -s reload
