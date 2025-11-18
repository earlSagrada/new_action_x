#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

install_nginx_component() {
  # DOMAIN and EMAIL must come from install.sh
  if [[ -z "${DOMAIN:-}" ]]; then
    err "DOMAIN is not set. It should be passed via install.sh (--domain) or interactive prompt."
    exit 1
  fi

  if [[ -z "${EMAIL:-}" ]]; then
    err "EMAIL is not set. It should be passed via install.sh (--email) or interactive prompt."
    exit 1
  fi

  # Defaults
  WEBROOT="${WEBROOT:-/var/www/$DOMAIN/html}"
  NGINX_SITE="/etc/nginx/sites-available/aria2_suite.conf"

  log "Installing nginx and certbot (if not installed)..."
  if ! command -v nginx >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y nginx python3-certbot-nginx
  fi

  mkdir -p "$WEBROOT"

  log "Configuring temporary HTTP-only nginx config for ACME challenges..."
  local http_tpl="${SCRIPT_DIR}/config/nginx/http-only.conf.template"
  if [[ ! -f "$http_tpl" ]]; then
    err "HTTP-only template not found: $http_tpl"
    exit 1
  fi

  render_template "$http_tpl" "$NGINX_SITE" DOMAIN WEBROOT

  ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/aria2_suite.conf
  if [[ -e /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi

  log "Testing nginx configuration (nginx -t)..."
  nginx -t

  systemctl enable nginx
  systemctl restart nginx

  # Auto-fix UFW firewall so certbot can be reached
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp  || true
    ufw allow 443/tcp || true
    log "Ensured UFW allows ports 80 and 443"
  fi

  log "Requesting/renewing Let's Encrypt certificate for $DOMAIN ..."
  certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" \
    --email "$EMAIL" --agree-tos --non-interactive \
    --rsa-key-size 4096 --keep-until-expiring

  local CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
  local CERT_FULLCHAIN="${CERT_DIR}/fullchain.pem"
  local CERT_PRIVKEY="${CERT_DIR}/privkey.pem"

  if [[ ! -f "$CERT_FULLCHAIN" || ! -f "$CERT_PRIVKEY" ]]; then
    err "Certificate files not found in $CERT_DIR"
    exit 1
  fi

  log "Configuring final HTTP/3 (QUIC) nginx config..."
  local quic_tpl="${SCRIPT_DIR}/config/nginx/quic.conf.template"
  if [[ ! -f "$quic_tpl" ]]; then
    warn "QUIC template not found: $quic_tpl. Keeping HTTP-only config."
  else
    render_template "$quic_tpl" "$NGINX_SITE" DOMAIN WEBROOT CERT_FULLCHAIN CERT_PRIVKEY
  fi

  log "Testing final nginx configuration..."
  nginx -t
  systemctl reload nginx

  log "Nginx installation and configuration completed."
}

install_nginx_component "$@"
