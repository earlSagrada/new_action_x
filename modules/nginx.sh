#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$MODULE_DIR/.." && pwd)"
source "$SCRIPT_DIR/modules/common.sh"

install_nginx_component() {
  if [[ -z "${DOMAIN:-}" ]]; then
    err "DOMAIN is not set. Pass --domain to install.sh."
    exit 1
  fi
  if [[ -z "${EMAIL:-}" ]]; then
    err "EMAIL is not set. Pass --email to install.sh."
    exit 1
  fi

  # Shared webroot for this domain
  WEBROOT="${WEBROOT:-/var/www/${DOMAIN}/html}"

  log "Installing nginx and certbot..."
  if ! command -v nginx >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y nginx python3-certbot-nginx
  fi

  # UFW for HTTP/HTTPS
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp  || true
    ufw allow 443/tcp || true
    log "Ensured UFW allows HTTP/HTTPS on 80/443."
  fi

  mkdir -p "$WEBROOT"

  local NGINX_SITE="/etc/nginx/sites-available/aria2_suite.conf"
  local HTTP_TPL="${SCRIPT_DIR}/config/nginx/http-only.conf.template"

  log "Configuring temporary HTTP-only nginx site for ACME..."
  render_template "$HTTP_TPL" "$NGINX_SITE" DOMAIN WEBROOT

  ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/aria2_suite.conf
  if [[ -e /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi

  log "Testing nginx configuration (HTTP-only)..."
  nginx -t
  systemctl enable nginx
  systemctl restart nginx

  # Cert files
  local CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
  local CERT_FULLCHAIN="${CERT_DIR}/fullchain.pem"
  local CERT_PRIVKEY="${CERT_DIR}/privkey.pem"

  # Skip certbot if cert valid > 30 days
  local SKIP_CERTBOT=false
  if [[ -f "$CERT_FULLCHAIN" ]]; then
    if openssl x509 -checkend $((30*24*3600)) -noout -in "$CERT_FULLCHAIN"; then
      log "Existing certificate still valid (>30 days). Skipping certbot."
      SKIP_CERTBOT=true
    fi
  fi

  if [[ "$SKIP_CERTBOT" != true ]]; then
    log "Requesting/renewing Let's Encrypt certificate for $DOMAIN ..."
    certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" \
      --email "$EMAIL" --agree-tos --non-interactive \
      --rsa-key-size 4096 --keep-until-expiring
  fi

  if [[ ! -f "$CERT_FULLCHAIN" || ! -f "$CERT_PRIVKEY" ]]; then
    err "Certificate files not found in $CERT_DIR"
    exit 1
  fi

  # Final QUIC/HTTP3 config
  local QUIC_TPL="${SCRIPT_DIR}/config/nginx/quic.conf.template"

  log "Configuring final QUIC/HTTP3 nginx site..."
  render_template "$QUIC_TPL" "$NGINX_SITE" \
    DOMAIN WEBROOT CERT_FULLCHAIN CERT_PRIVKEY

  log "Testing final nginx configuration..."
  nginx -t
  systemctl reload nginx

  log "Nginx with HTTP/3/QUIC configured for $DOMAIN."
}

install_nginx_component "$@"
