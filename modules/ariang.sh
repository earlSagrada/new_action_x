#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$MODULE_DIR/.." && pwd)"
source "$SCRIPT_DIR/modules/common.sh"

WEBROOT="${WEBROOT:-/var/www/${DOMAIN:-example.com}/html}"
ARIANG_DIR="${ARIANG_DIR:-/usr/share/ariang}"

install_ariang_component() {
  log "Installing latest AriaNg..."

  # jq for GitHub API
  if ! command -v jq >/dev/null 2>&1; then
    log "Installing jq..."
    apt-get update -y
    apt-get install -y jq
  fi

  mkdir -p "$ARIANG_DIR"

  local api_url="https://api.github.com/repos/mayswind/AriaNg/releases/latest"
  local latest_tag
  latest_tag="$(curl -fsSL "$api_url" | jq -r '.tag_name')"

  if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
    err "Failed to detect latest AriaNg version from GitHub."
    exit 1
  fi

  log "Latest AriaNg release: ${latest_tag}"

  local zip_url="https://github.com/mayswind/AriaNg/releases/download/${latest_tag}/AriaNg-${latest_tag#v}.zip"
  if ! curl -I -fsSL "$zip_url" >/dev/null 2>&1; then
    zip_url="https://github.com/mayswind/AriaNg/releases/download/${latest_tag}/AriaNg.zip"
  fi

  local tmp_zip="/tmp/AriaNg.zip"
  rm -f "$tmp_zip"
  curl -fLo "$tmp_zip" "$zip_url"

  rm -rf "${ARIANG_DIR:?}"/*
  unzip -q "$tmp_zip" -d "$ARIANG_DIR"
  rm -f "$tmp_zip"

  log "AriaNg extracted to ${ARIANG_DIR}."

  # NOTE: We intentionally do not inject any defaults/auto-sanitizer JS into the shipped
  # AriaNg distribution. Automatic UI manipulation proved unreliable for some browser
  # environments and caused confusion; admins should adjust AriaNg connection settings
  # manually. See README for guidance.

  # (no default UI script installed)

  # Inject script tag into index.html if not present (idempotent)
  local index_html="$ARIANG_DIR/index.html"
  if [[ -f "$index_html" ]]; then
    # Do not inject runtime UI patches. Instead print a clear message so the admin knows
    # to configure the AriaNg connection settings manually.
    log "index.html present; NOT injecting runtime UI defaults or sanitizers (removed)."
    cat <<MSG

=====================================================================
IMPORTANT: AriaNg connection settings must be configured manually in the UI

  - Host: ${DOMAIN:-<your-domain>}
  - Port: (set 443 when using HTTPS)
  - Secure/TLS: ON
  - Path: /jsonrpc

After installation, open: https://${DOMAIN:-<your-domain>}/ariang/
and edit the connection profile accordingly.

Note: aria2's one-time RPC secret is still printed during aria2 installation
      and stored in /etc/aria2/aria2.conf — copy it and paste it into AriaNg
      as the "Secret Token" (we do not inject the RPC secret into the UI).
=====================================================================

MSG
  fi

  # nginx alias for /ariang
  local nginx_alias="/etc/nginx/snippets/ariang.conf"
  cat > "$nginx_alias" <<EOF
location /ariang {
    alias ${ARIANG_DIR}/;
    index index.html;
}
EOF

  log "Created nginx alias configuration: $nginx_alias"
  log "Reloading nginx..."
  nginx -t
  systemctl reload nginx

  log "AriaNg installation completed."
}

install_ariang_component "$@"
