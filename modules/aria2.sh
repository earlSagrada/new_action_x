#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

# Default paths for aria2
ARIA2_CONF_DIR="${ARIA2_CONF_DIR:-/etc/aria2}"
ARIA2_CONF="${ARIA2_CONF:-${ARIA2_CONF_DIR}/aria2.conf}"
ARIA2_SESSION="${ARIA2_SESSION:-${ARIA2_CONF_DIR}/aria2.session}"
ARIA2_DOWNLOAD_DIR="${ARIA2_DOWNLOAD_DIR:-/var/www/${DOMAIN}/downloads}"

ARIA2_USER="${ARIA2_USER:-www-data}"
ARIA2_GROUP="${ARIA2_GROUP:-www-data}"

# systemd service path
ARIA2_SERVICE_PATH="${ARIA2_SERVICE_PATH:-/etc/systemd/system/aria2.service}"

# RPC secret
RPC_SECRET="${RPC_SECRET:-$(openssl rand -hex 16)}"

mkdir -p "$ARIA2_CONF_DIR" "$ARIA2_DOWNLOAD_DIR" /var/log/aria2 /var/lib/aria2
touch "$ARIA2_SESSION"
touch /var/log/aria2/aria2.log

install_aria2_component() {
  log "Setting up aria2..."

  mkdir -p "$ARIA2_CONF_DIR" "$ARIA2_DOWNLOAD_DIR" /var/log/aria2 /var/lib/aria2
  touch "${ARIA2_CONF_DIR}/aria2.session"

  # Render aria2.conf from template
  local tpl="${SCRIPT_DIR}/config/aria2.conf.template"
  render_template "$tpl" "$ARIA2_CONF" \
    ARIA2_DOWNLOAD_DIR ARIA2_CONF_DIR RPC_SECRET

  # Render systemd service from template
  local tpl_service="${SCRIPT_DIR}/config/systemd/aria2.service"
  render_template "$tpl_service" "$ARIA2_SERVICE_PATH" \
    ARIA2_CONF ARIA2_USER ARIA2_GROUP ARIA2_SESSION

  systemctl daemon-reload
  systemctl enable aria2.service
  systemctl restart aria2.service

  if ! systemctl is-active --quiet aria2.service; then
    err "aria2.service failed to start!"
    journalctl -u aria2.service -n 50 --no-pager || true
    exit 1
  fi

  log "aria2 installed and running as systemd service."
}

install_aria2_component "$@"
