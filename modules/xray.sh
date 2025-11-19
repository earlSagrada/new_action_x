#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$MODULE_DIR/.." && pwd)"
source "$SCRIPT_DIR/modules/common.sh"

XRAY_INBOUND="${XRAY_INBOUND:-reality}"

install_xray_component() {
  log "Installing Xray core..."

  if ! command -v xray >/dev/null 2>&1; then
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
  else
    log "Xray binary already installed; skipping core installation."
  fi

  if ! command -v qrencode >/dev/null 2>&1; then
    log "Installing qrencode..."
    apt-get update -y
    apt-get install -y qrencode
  fi

  if command -v ufw >/dev/null 2>&1; then
    ufw allow 443/tcp  || true
    ufw allow 443/udp  || true
    log "Ensured UFW allows TCP/UDP 443 for Xray Reality."
  fi

  case "$XRAY_INBOUND" in
    reality)
      install_xray_reality_inbound
      ;;
    *)
      err "Unsupported XRAY_INBOUND='$XRAY_INBOUND'. Currently only 'reality' is implemented."
      exit 1
      ;;
  esac
}

install_xray_reality_inbound() {
  log "Configuring Xray (VLESS + Reality on TCP/UDP 443, xtls-rprx-vision)..."

  mkdir -p /usr/local/etc/xray /var/log/xray

  local tpl="${SCRIPT_DIR}/config/xray/reality.json.template"
  local out="/usr/local/etc/xray/config.json"

  # --- Generate keypair safely via temp file ---
  log "Generating Reality keypair..."
  local TMP_KEYS="/tmp/xray_keys_$$.txt"
  xray x25519 > "$TMP_KEYS" 2>/dev/null || true

  REALITY_PRIVATE_KEY="$(grep -i 'PrivateKey' "$TMP_KEYS" | awk '{print $2}')"
  REALITY_PUBLIC_KEY="$(grep -i 'PublicKey' "$TMP_KEYS" 2>/dev/null | awk '{print $2}')"
  if [[ -z "${REALITY_PUBLIC_KEY:-}" ]]; then
    # older versions label it "Public:"
    REALITY_PUBLIC_KEY="$(grep -i 'Public' "$TMP_KEYS" | awk '{print $2}')"
  fi
  rm -f "$TMP_KEYS"

  if [[ -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" ]]; then
    err "Failed to parse Reality keypair from xray x25519 output."
    exit 1
  fi

  UUID="$(cat /proc/sys/kernel/random/uuid)"
  SHORT_ID="$(openssl rand -hex 4)"

  log "Reality public key: $REALITY_PUBLIC_KEY"
  log "UUID:               $UUID"
  log "ShortId:            $SHORT_ID"

  # Render config
  render_template "$tpl" "$out" \
    REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY UUID SHORT_ID

  chmod 600 "$out"

  # Restart Xray
  systemctl enable xray || true
  systemctl restart xray

  if ! systemctl is-active --quiet xray; then
    err "Xray failed to start with new config!"
    journalctl -u xray -n 50 --no-pager || true
    exit 1
  fi

  log "Xray Reality active on TCP/UDP 443."

  # Domain/IP for client link
  local HOSTNAME_FOR_LINK="${DOMAIN:-}"
  if [[ -z "$HOSTNAME_FOR_LINK" ]]; then
    HOSTNAME_FOR_LINK="$(hostname -I | awk '{print $1}')"
  fi

  local SNI="www.cloudflare.com"

  VLESS_LINK="vless://${UUID}@${HOSTNAME_FOR_LINK}:443?security=reality&encryption=none&flow=xtls-rprx-vision&type=tcp&fp=chrome&sni=${SNI}&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}#Reality-${HOSTNAME_FOR_LINK}"

  log "VLESS Reality link:"
  echo "$VLESS_LINK"
  echo

  local QR_IMG="/root/xray-reality-${HOSTNAME_FOR_LINK}.png"
  qrencode -o "$QR_IMG" -s 8 "$VLESS_LINK"
  log "QR code saved to: $QR_IMG"
  echo "Example download command:"
  echo "  scp root@${HOSTNAME_FOR_LINK}:${QR_IMG} ."
  echo

  qrencode -t ANSIUTF8 "$VLESS_LINK"
  echo

  log "Xray Reality configuration completed."
}

install_xray_component "$@"
