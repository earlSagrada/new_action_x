#!/usr/bin/env bash
set -euo pipefail

# Resolve paths
MODULE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$MODULE_DIR/.." && pwd)"
source "$SCRIPT_DIR/modules/common.sh"

usage() {
  cat <<EOF
Usage: $0 --domain example.com --email you@example.com [--webroot /var/www/example.com/html]

Installs and configures nginx + Let's Encrypt certificate + HTTP/3/QUIC
for the given domain, using the templates in config/nginx/.
EOF
}

parse_args() {
  # Allow env overrides but default to empty
  DOMAIN="${DOMAIN:-}"
  EMAIL="${EMAIL:-}"
  WEBROOT="${WEBROOT:-}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        DOMAIN="$2"
        shift 2
        ;;
      --email)
        EMAIL="$2"
        shift 2
        ;;
      --webroot)
        WEBROOT="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$DOMAIN" ]]; then
    err "DOMAIN is not set. Use --domain or export DOMAIN."
    exit 1
  fi
  if [[ -z "$EMAIL" ]]; then
    err "EMAIL is not set. Use --email or export EMAIL."
    exit 1
  fi

  # Default webroot if not provided
  if [[ -z "$WEBROOT" ]]; then
    WEBROOT="/var/www/${DOMAIN}/html"
  fi
}

install_nginx_and_certbot() {
  log "Installing nginx and certbot (if needed)..."

  if ! command -v nginx >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y nginx
  fi

  if ! command -v certbot >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y certbot python3-certbot-nginx
  fi

  # UFW rules
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp  || true
    ufw allow 443/tcp || true
    log "Ensured UFW allows HTTP/HTTPS on 80/443."
  fi
}

setup_http_only_site() {
  local NGINX_SITE="/etc/nginx/sites-available/aria2_suite.conf"
  local HTTP_TPL="${SCRIPT_DIR}/config/nginx/http-only.conf.template"

  mkdir -p "$WEBROOT"

  log "Configuring temporary HTTP-only nginx site for ACME challenge..."
  # Render http-only template with DOMAIN + WEBROOT
  render_template "$HTTP_TPL" "$NGINX_SITE" DOMAIN WEBROOT

  ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/aria2_suite.conf
  if [[ -e /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi

  log "Testing nginx configuration (HTTP-only)..."
  nginx -t
  systemctl enable nginx
  systemctl restart nginx
}

obtain_or_renew_cert() {
  local CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
  CERT_FULLCHAIN="${CERT_DIR}/fullchain.pem"
  CERT_PRIVKEY="${CERT_DIR}/privkey.pem"

  local SKIP_CERTBOT=false

  if [[ -f "$CERT_FULLCHAIN" ]]; then
    if openssl x509 -checkend $((30*24*3600)) -noout -in "$CERT_FULLCHAIN"; then
      log "Existing certificate for $DOMAIN is valid for >30 days. Skipping certbot."
      SKIP_CERTBOT=true
    fi
  fi

  if [[ "$SKIP_CERTBOT" != true ]]; then
    log "Requesting/renewing Let's Encrypt certificate for $DOMAIN ..."
    certbot certonly \
      --webroot -w "$WEBROOT" \
      -d "$DOMAIN" \
      --email "$EMAIL" \
      --agree-tos --non-interactive \
      --rsa-key-size 4096 \
      --keep-until-expiring
  fi

  if [[ ! -f "$CERT_FULLCHAIN" || ! -f "$CERT_PRIVKEY" ]]; then
    err "Certificate files not found in $CERT_DIR after certbot run."
    exit 1
  fi
}

configure_quic_site() {
  local NGINX_SITE="/etc/nginx/sites-available/aria2_suite.conf"
  local QUIC_TPL="${SCRIPT_DIR}/config/nginx/quic.conf.template"
  local INDEX_TPL="${SCRIPT_DIR}/config/nginx/index.html.template"
  local INDEX_FILE="${WEBROOT}/index.html"

  log "Rendering final QUIC/HTTP3 nginx site for $DOMAIN..."

  # Ensure variables are exported so render_template can see them
  export DOMAIN WEBROOT CERT_FULLCHAIN CERT_PRIVKEY

  render_template "$QUIC_TPL" "$NGINX_SITE" \
    DOMAIN WEBROOT CERT_FULLCHAIN CERT_PRIVKEY

  ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/aria2_suite.conf

  log "Generating default index.html from template..."
  render_template "$INDEX_TPL" "$INDEX_FILE" DOMAIN

  log "Testing final nginx configuration..."
  nginx -t
  systemctl reload nginx

  log "Nginx with TLS + HTTP/3/QUIC configured for $DOMAIN (listening on 0.0.0.0:443)."
}

main() {
  parse_args "$@"
  install_nginx_and_certbot
  setup_http_only_site
  obtain_or_renew_cert
  configure_quic_site
}

main "$@"
