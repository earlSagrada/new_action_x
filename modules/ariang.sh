#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"

install_ariang_component() {
  log "Installing latest AriaNg..."

  mkdir -p "$WEBROOT"

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

  rm -rf "${WEBROOT:?}"/*
  unzip -q "$tmp_zip" -d "$WEBROOT"
  rm -f "$tmp_zip"

  log "AriaNg extracted to ${WEBROOT}."
}

install_ariang_component "$@"
