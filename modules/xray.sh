#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

# Default inbound type
XRAY_INBOUND="${XRAY_INBOUND:-reality}"

install_xray_component() {
  log "Installing Xray core..."

  if ! command -v xray >/dev/null 2>&1; then
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
  else
    log "Xray binary already present; skipping core installation."
  fi

  # Ensure qrencode is available for QR generation
  if ! command -v qrencode >/dev/null 2>&1; then
    log "Installing qrencode for QR code generation..."
    apt-get update -y
    apt-get install -y qrencode
  fi

  # Ensure firewall allows Xray port(s)
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 443/tcp  || true
    ufw allow 443/udp  || true
    log "Ensured UFW allows TCP/UDP 443 for Xray."
  fi

  case "$XRAY_INBOUND" in
    reality)
      install_xray_reality_inbound
      ;;
    *)
      err "Xray inbound type '$XRAY_INBOUND' is not implemented yet."
      err "Currently supported: reality (VLESS + Reality on UDP/443)"
      exit 1
      ;;
  esac
}

install_xray_reality_inbound() {
  log "Configuring Xray: VLESS + Reality on UDP/443 (xtls-rprx-vision)..."

  mkdir -p /etc/xray /var/log/xray
  local tpl="${SCRIPT_DIR}/config/xray/reality.json.template"
  local out="/etc/xray/config.json"

  # Generate key pair
  local XRAY_KEYS
  XRAY_KEYS="$(xray x25519)"
  REALITY_PRIVATE_KEY="$(echo "$XRAY_KEYS" | grep Private | awk '{print $3}')"
  REALITY_PUBLIC_KEY="$(echo "$XRAY_KEYS" | grep Public | awk '{print $3}')"
  UUID="$(cat /proc/sys/kernel/random/uuid)"
  SHORT_ID="$(openssl rand -hex 4)"

  log "Reality public key: ${REALITY_PUBLIC_KEY}"
  log "User UUID:          ${UUID}"
  log "ShortId:            ${SHORT_ID}"

  # Render config from template
  render_template "$tpl" "$out" \
    REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY UUID SHORT_ID

  # Make sure service is enabled and restarted
  systemctl enable xray || true
  systemctl restart xray

  if ! systemctl is-active --quiet xray; then
    err "Xray failed to start!"
    journalctl -u xray -n 50 --no-pager || true
    exit 1
  fi

  log "Xray (Reality) installed and running on TCP/UDP 443."

  echo
  echo "--------- Xray Reality client info ---------"
  echo "UUID:        ${UUID}"
  echo "PublicKey:   ${REALITY_PUBLIC_KEY}"
  echo "ShortId:     ${SHORT_ID}"
  echo "ServerName:  www.cloudflare.com"
  echo "Flow:        xtls-rprx-vision"
  echo "Port:        443"
  echo "Address:     (your VPS domain or IP)"
  echo "--------------------------------------------"
  echo "In v2rayNG, create a VLESS+Reality profile and fill these fields accordingly."
  echo

  # Auto-detect domain/IP for QR link
  if [[ -z "${DOMAIN:-}" ]]; then
    DOMAIN=$(hostname -I | awk '{print $1}')
  fi

  # Generate VLESS Reality link (v2rayng / v2rayN format)
  VLESS_LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.cloudflare.com&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality-${DOMAIN}"

  echo
  echo "VLESS link:"
  echo "${VLESS_LINK}"
  echo

  # Generate QR code image and terminal QR
  QR_PATH="/root/xray-qr.png"
  qrencode -o "${QR_PATH}" -s 8 "${VLESS_LINK}"

  log "QR code generated at: ${QR_PATH}"
  log "You can download it by: scp root@your-server:${QR_PATH} ."
  echo

  qrencode -t ANSIUTF8 "${VLESS_LINK}"
  echo
}

install_xray_component "$@"
