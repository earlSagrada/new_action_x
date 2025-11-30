#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$MODULE_DIR/.." && pwd)"
source "$SCRIPT_DIR/modules/common.sh"

FILEBROWSER_CONF_DIR="${FILEBROWSER_CONF_DIR:-/etc/filebrowser}"
FILEBROWSER_CONF="${FILEBROWSER_CONF:-${FILEBROWSER_CONF_DIR}/filebrowser.json}"

FILEBROWSER_DB_DIR="${FILEBROWSER_DB_DIR:-/var/lib/filebrowser}"
FILEBROWSER_DB="${FILEBROWSER_DB:-${FILEBROWSER_DB_DIR}/filebrowser.db}"

FILEBROWSER_LOG="${FILEBROWSER_LOG:-/var/log/filebrowser.log}"
FILEBROWSER_SERVICE_PATH="${FILEBROWSER_SERVICE_PATH:-/etc/systemd/system/filebrowser.service}"

DOWNLOAD_DIR="${DOWNLOAD_DIR:-/var/www/${DOMAIN:-example.com}/downloads}"

mkdir -p "$FILEBROWSER_CONF_DIR" "$FILEBROWSER_DB_DIR" /var/log
touch "$FILEBROWSER_LOG"

chown -R www-data:www-data "$FILEBROWSER_DB_DIR"

install_filebrowser_component() {
  log "Installing FileBrowser..."

  if ! command -v filebrowser >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
  else
    log "FileBrowser binary already present; skipping download."
  fi

  # Config
  local tpl="${SCRIPT_DIR}/config/filebrowser.json.template"
  render_template "$tpl" "$FILEBROWSER_CONF" \
    FILEBROWSER_LOG DOWNLOAD_DIR FILEBROWSER_DB

  # Systemd service
  local tpl_service="${SCRIPT_DIR}/config/systemd/filebrowser.service"
  render_template "$tpl_service" "$FILEBROWSER_SERVICE_PATH" \
    FILEBROWSER_CONF

  chmod 644 "$FILEBROWSER_SERVICE_PATH"

  systemctl daemon-reload
  systemctl enable filebrowser.service
  systemctl restart filebrowser.service

  if ! systemctl is-active --quiet filebrowser.service; then
    err "filebrowser.service failed to start!"
    journalctl -u filebrowser.service -n 50 --no-pager || true
    exit 1
  fi

  log "FileBrowser running at http://127.0.0.1:8080 (default admin/admin)."

  # Informational post-install instructions for first-time login
  if [[ -n "${DOMAIN:-}" ]]; then
    cat <<MSG

=============================================================
FileBrowser is installed and running.

Web UI (local):  http://127.0.0.1:8080/
Web UI (public): https://file.${DOMAIN}/  (after nginx + certs finished)

Default credentials:
  username: admin
  password: admin

IMPORTANT: Please change the default password immediately after your first login.
You can change it from the FileBrowser web UI (Settings → Users → Edit the admin user),
or create a new user and remove the default admin account.

Config + DB locations:
  - Config: /etc/filebrowser/filebrowser.json
  - Database: /var/lib/filebrowser/filebrowser.db

To check service status on the server:
  systemctl status filebrowser
  journalctl -u filebrowser -n 50 --no-pager

Once DNS (file.${DOMAIN}) has propagated and certbot finishes, visit the public URL
above in a private/incognito browser to sign in for the first time.

DO NOT leave the default admin/admin credentials in production.
=============================================================

MSG
  else
    cat <<MSG

=============================================================
FileBrowser is installed and running at http://127.0.0.1:8080/

Default credentials: admin / admin

Please change the default password immediately after first login via the UI
(Settings → Users → Edit admin) or create a new admin account and delete the default.

Config + DB locations: /etc/filebrowser/filebrowser.json, /var/lib/filebrowser/filebrowser.db

To check service status: systemctl status filebrowser

MSG
  fi
}

install_filebrowser_component "$@"
