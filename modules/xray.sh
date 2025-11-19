#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

# Default inbound
XRAY_INBOUND="${XRAY_INBOUND:-reality}"

install_xray_component() {
  log "Installing Xray core..."

  # Install Xray if missing
  if ! command -v xray >/dev/null 2>&1; then
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
  else
    log "Xray binary already installed; skipping core installation."
  fi

  # Install qrencode
  if ! command -v qrencode >/dev/null 2>&1; then
    log "Installing qrencode for QR code generation..."
    apt-get update -y
    apt-get install -y qrencode
  fi

  # Open UDP+TCP 443 for Reality
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 443/tcp  || true
    ufw allow 443/udp  || true
    log "Ensured UFW allows TCP/UDP 443 for Xray Reality."
  fi

  # Dispatch to inbound handler
  case "$XRAY_INBOUND" in
    reality)
      install_xray_reality_inbound
      ;;
    *)
      err "Xray inbound type '$XRAY_INBOUND' not supported."
      exit 1
      ;;
  esac
}

install_xray_reality_inbound() {
  log "Configuring Xray (VLESS + Reality on TCP/UDP 443, xtls-rprx-vision)..."

  mkdir -p /usr/local/etc/xray /var/log/xray

  local tpl="${SCRIPT_DIR}/config/xray/reality.json.template"
  local out="/usr/local/etc/xray/config.json"

  #############################
  # Key generation
  #############################
  log "Generating Reality keypair..."

  TMP_KEYS="/tmp/xray_keys_$$.txt"
  xray x25519 > "$TMP_KEYS" 2>/dev/null || true

  REALITY_PRIVATE_KEY="$(grep -i 'Private' "$TMP_KEYS" | awk '{print $3}')"
  REALITY_PUBLIC_KEY="$(grep -i 'Public'  "$TMP_KEYS" | awk '{print $3}')"

  rm -f "$TMP_KEYS"

  if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
    err "Failed to parse Reality keypair. Raw output:"
    cat "$TMP_KEYS"
    exit 1
  fi

  UUID="$(cat /proc/sys/kernel/random/uuid)"
  SHORT_ID="$(openssl rand -hex 4)"

  log "Reality public key: $REALITY_PUBLIC_KEY"
  log "UUID:               $UUID"
  log "ShortId:            $SHORT_ID"

  #############################
  # Render final config
  #############################
  render_template "$tpl" "$out" \
    REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY UUID SHORT_ID

  chmod 600 "$out"

  #############################
  # Restart Xray
  #############################
  systemctl enable xray || true
  systemctl restart xray

  if ! systemctl is-active --quiet xray; then
    err "Xray failed to start!"
    journalctl -u xray -n 50 --no-pager || true
    exit 1
  fi

  log "Xray Reality is now active on TCP/UDP 443."

  #############################
  # Generate client config link
  #############################

  # Domain fallback
  if [[ -z "${DOMAIN:-}" ]]; then
    DOMAIN=$(hostname -I | awk '{print $1}')
  fi

  local SNI="www.cloudflare.com"

  VLESS_LINK="vless://${UUID}@${DOMAIN}:443?security=reality&encryption=none&flow=xtls-rprx-vision&type=tcp&fp=chrome&sni=${SNI}&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}#Reality-${DOMAIN}"

  log "Generated VLESS Reality link:"
  echo "$VLESS_LINK"
  echo

  #############################
  # Generate QR code
  #############################
  local QR_IMG="/root/xray-reality-${DOMAIN}.png"
  qrencode -o "$QR_IMG" -s 8 "$VLESS_LINK"

  log "QR code saved to: $QR_IMG"
  log "Example download command:"
  echo "scp root@${DOMAIN}:${QR_IMG} ."
  echo

  # Terminal QR
  qrencode -t ANSIUTF8 "$VLESS_LINK"
  echo

  log "Xray Reality configuration completed."
}

install_xray_component "$@"
