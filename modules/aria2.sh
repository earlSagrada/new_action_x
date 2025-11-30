#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$MODULE_DIR/.." && pwd)"
source "$SCRIPT_DIR/modules/common.sh"

# Defaults
ARIA2_CONF_DIR="${ARIA2_CONF_DIR:-/etc/aria2}"
ARIA2_CONF="${ARIA2_CONF:-${ARIA2_CONF_DIR}/aria2.conf}"
ARIA2_SESSION="${ARIA2_SESSION:-${ARIA2_CONF_DIR}/aria2.session}"
ARIA2_DOWNLOAD_DIR="${ARIA2_DOWNLOAD_DIR:-${DOWNLOAD_DIR:-/var/www/${DOMAIN:-example.com}/downloads}}"

ARIA2_USER="${ARIA2_USER:-www-data}"
ARIA2_GROUP="${ARIA2_GROUP:-www-data}"
ARIA2_SERVICE_PATH="${ARIA2_SERVICE_PATH:-/etc/systemd/system/aria2.service}"

RPC_SECRET="${RPC_SECRET:-$(openssl rand -hex 16)}"

mkdir -p "$ARIA2_CONF_DIR" "$ARIA2_DOWNLOAD_DIR" /var/log/aria2 /var/lib/aria2
touch "$ARIA2_SESSION" /var/log/aria2/aria2.log

install_aria2_component() {
  log "Setting up aria2..."

  log "Installing aria2..."
  apt-get update -y
  apt-get install -y aria2

  mkdir -p "$ARIA2_CONF_DIR" "$ARIA2_DOWNLOAD_DIR" /var/log/aria2 /var/lib/aria2
  touch "$ARIA2_SESSION" /var/log/aria2/aria2.log

  chown -R "$ARIA2_USER":"$ARIA2_GROUP" \
    "$ARIA2_CONF_DIR" "$ARIA2_DOWNLOAD_DIR" /var/log/aria2 /var/lib/aria2

  # aria2.conf
  local tpl="${SCRIPT_DIR}/config/aria2.conf.template"
  render_template "$tpl" "$ARIA2_CONF" \
    ARIA2_DOWNLOAD_DIR ARIA2_CONF_DIR RPC_SECRET

  # systemd service
  local tpl_service="${SCRIPT_DIR}/config/systemd/aria2.service"
  render_template "$tpl_service" "$ARIA2_SERVICE_PATH" \
    ARIA2_CONF ARIA2_USER ARIA2_GROUP ARIA2_SESSION

  chmod 644 "$ARIA2_SERVICE_PATH"

  systemctl daemon-reload
  systemctl enable aria2.service
  systemctl restart aria2.service

  if ! systemctl is-active --quiet aria2.service; then
    err "aria2.service failed to start!"
    journalctl -u aria2.service -n 50 --no-pager || true
    exit 1
  fi

  log "aria2 installed and running."

  # Admin message: always print the rpc-secret so the admin can copy it
  cat <<MSG

=============================================================
Aria2 RPC secret (displayed during install):

    ${RPC_SECRET}

IMPORTANT: Keep this secret safe. Use it in AriaNg settings as the
"Secret Token" (paste exactly as shown, no extra prefix). We do NOT
store this visibly in the web UI; this output is shown during
installation so you can save it securely.

The secret is written to: ${ARIA2_CONF}
DO NOT share the secret publicly.
=============================================================

MSG

  log "Aria2 downloads directory: ${ARIA2_DOWNLOAD_DIR}"
}

install_aria2_component "$@"
