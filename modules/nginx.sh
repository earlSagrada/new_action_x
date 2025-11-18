#!/usr/bin/env bash

install_nginx_component() {
  if [[ -z "$DOMAIN" ]]; then
    if $NON_INTERACTIVE; then
      err "--domain is required when installing nginx in non-interactive mode."
      exit 1
    fi
    read -rp "Enter primary domain (e.g. example.com): " DOMAIN
  fi

  if [[ -z "$EMAIL" ]]; then
    if $NON_INTERACTIVE; then
      err "--email is required for certbot in non-interactive mode."
      exit 1
    fi
    read -rp "Enter email for Let's Encrypt: " EMAIL
  fi

  mkdir -p "$WEBROOT"

  log "Configuring temporary HTTP-only nginx config for ACME challenges..."

  local http_tpl="${SCRIPT_DIR}/config/nginx/http-only.conf.template"
  render_template "$http_tpl" "$NGINX_SITE" \
    DOMAIN WEBROOT

  ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/aria2_suite.conf
  if [[ -e /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi

  log "Testing nginx configuration (nginx -t)..."
  if ! nginx -t; then
    err "nginx config test FAILED for HTTP-only config!"
    tail -n 50 /var/log/nginx/error.log 2>/dev/null || true
    exit 1
  fi

  systemctl enable nginx
  systemctl restart nginx

  log "Requesting Let's Encrypt certificates via certbot (webroot)..."

  if certbot certonly --webroot -w "$WEBROOT" \
        -d "$DOMAIN" -d "file.$DOMAIN" \
        -m "$EMAIL" --agree-tos --non-interactive --no-eff-email; then
    log "Certificates obtained successfully."
    configure_nginx_https_from_templates
  else
    err "certbot failed! Dumping last 50 lines of certbot log:"
    tail -n 50 /var/log/letsencrypt/letsencrypt.log 2>/dev/null || true
    err "nginx will remain HTTP-only. Fix DNS / ports and rerun."
    exit 1
  fi
}

configure_nginx_https_from_templates() {
  local cert_path="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  local key_path="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

  if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
    err "Certificates not found at ${cert_path} / ${key_path}; leaving HTTP-only config."
    return
  fi

  CERT_PATH="$cert_path"
  KEY_PATH="$key_path"

  if nginx_supports_http3; then
    log "nginx has http_v3_module; using HTTP/3 template."
    local tpl="${SCRIPT_DIR}/config/nginx/https-http3.conf.template"
    render_template "$tpl" "$NGINX_SITE" \
      DOMAIN WEBROOT CERT_PATH KEY_PATH
  else
    log "nginx lacks http_v3_module; using HTTP/2-only template."
    local tpl="${SCRIPT_DIR}/config/nginx/https-http2.conf.template"
    render_template "$tpl" "$NGINX_SITE" \
      DOMAIN WEBROOT CERT_PATH KEY_PATH
  fi

  log "Testing nginx configuration (nginx -t) for HTTPS..."
  if ! nginx -t; then
    err "nginx config test FAILED for HTTPS config!"
    tail -n 50 /var/log/nginx/error.log 2>/dev/null || true
    exit 1
  fi

  systemctl reload nginx
  log "nginx HTTPS configuration applied."
}
