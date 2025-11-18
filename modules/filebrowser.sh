#!/usr/bin/env bash

install_filebrowser_component() {
  log "Installing FileBrowser..."

  if ! command -v filebrowser >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
  else
    log "FileBrowser binary already present; skipping download."
  fi

  mkdir -p "$FILEBROWSER_CONF_DIR" "$FILEBROWSER_DB_DIR"
  touch "$FILEBROWSER_LOG"

  FILEBROWSER_DB="${FILEBROWSER_DB_DIR}/filebrowser.db"

  # Render JSON config
  local tpl="${SCRIPT_DIR}/config/filebrowser.json.template"
  render_template "$tpl" "$FILEBROWSER_CONF" \
    FILEBROWSER_LOG DOWNLOAD_DIR FILEBROWSER_DB

  # Render systemd service
  local tpl_service="${SCRIPT_DIR}/config/systemd/filebrowser.service"
  render_template "$tpl_service" "$FILEBROWSER_SERVICE_PATH" \
    FILEBROWSER_CONF

  systemctl daemon-reload
  systemctl enable filebrowser.service
  systemctl restart filebrowser.service

  if ! systemctl is-active --quiet filebrowser.service; then
    err "filebrowser.service failed to start!"
    journalctl -u filebrowser.service -n 50 --no-pager || true
    exit 1
  fi

  log "FileBrowser installed and running on 127.0.0.1:8080."
  log "Default credentials: admin / admin (change ASAP)."
}
