#!/usr/bin/env bash
set -euo pipefail

# Resolve repo root
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

  # qrencode required for QR code output
  if ! command -v qrencode >/dev/null 2>&1; then
    log "Installing qrencode..."
    apt-get update -y
    apt-get install -y qrencode
  fi

  # Open port 443
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 443/tcp  || true
    ufw allow 443/udp  || true
    log "Ensured UFW allows TCP/UDP 443 for Xray Reality."
  fi

  case "$XRAY_INBOUND" in
    reality) install_xray_reality_inbound ;;
    *) err "Unsupported XRAY_INBOUND type: $XRAY_INBOUND"; exit 1 ;;
  esac
}

install_xray_reality_inbound() {
  log "Configuring Xray (VLESS + Reality on TCP/UDP 443, xtls-rprx-vision)..."

  mkdir -p /usr/local/etc/xray /var/log/xray

  # Ensure Xray can write logs
  touch /var/log/xray/access.log /var/log/xray/error.log
  chmod 644 /var/log/xray/*log
  chown root:root /var/log/xray/*log

  local tpl="${SCRIPT_DIR}/config/xray/reality.json.template"
  local out="/usr/local/etc/xray/config.json"

  # ---------------- Keypair Generation ----------------
  log "Generating Reality keypair..."

  local TMP_KEYS="/tmp/xray_keys_$$.txt"
  rm -f "$TMP_KEYS"

  if ! xray x25519 >"$TMP_KEYS" 2>&1; then
    err "xray x25519 failed; raw output:"
    cat "$TMP_KEYS" || true
    exit 1
  fi

  log "Raw xray x25519 output:"
  sed 's/^/    /' "$TMP_KEYS" || true

  # Support new/old Xray key formats
  local priv_line pub_line hash_line
  priv_line="$(grep -i 'PrivateKey' "$TMP_KEYS" | head -n1 || true)"
  pub_line="$(grep -i 'PublicKey'  "$TMP_KEYS" | head -n1 || true)"
  hash_line="$(grep -i 'Hash32'    "$TMP_KEYS" | head -n1 || true)"

  REALITY_PRIVATE_KEY="$(printf '%s\n' "$priv_line" | awk -F': *' '{print $2}' || true)"

  # If PublicKey missing → fallback to Hash32 (new Xray)
  if [[ -n "${pub_line:-}" ]]; then
    REALITY_PUBLIC_KEY="$(printf '%s\n' "$pub_line" | awk -F': *' '{print $2}')"
  else
    REALITY_PUBLIC_KEY="$(printf '%s\n' "$hash_line" | awk -F': *' '{print $2}')"
  fi

  rm -f "$TMP_KEYS"

  if [[ -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" ]]; then
    err "Failed to parse Reality keypair. Private or public key empty."
    exit 1
  fi

  UUID="$(cat /proc/sys/kernel/random/uuid)"
  SHORT_ID="$(openssl rand -hex 4)"

  log "Parsed Reality keys:"
  log "  PublicKey: $REALITY_PUBLIC_KEY"
  log "  UUID:      $UUID"
  log "  ShortId:   $SHORT_ID"

  # ---------------- Render Config ----------------
  render_template "$tpl" "$out" \
    REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY UUID SHORT_ID

  chmod 600 "$out"
  chmod 644 /usr/local/etc/xray/config.json

  # ---------------- Restart Xray ----------------
  # Ensure Xray runs as root (required for Reality + port 443 + reading config)
  XRAY_SERVICE="/etc/systemd/system/xray.service"
  if grep -q 'User=nobody' "$XRAY_SERVICE"; then
      sed -i 's/User=nobody/User=root/' "$XRAY_SERVICE"
      log "Patched xray.service to run as root"
  fi

  sed -i 's/User=nobody/User=root/' /etc/systemd/system/xray.service
  systemctl daemon-reload

  systemctl enable xray || true
  systemctl restart xray

  if ! systemctl is-active --quiet xray; then
    err "Xray failed to start!"
    journalctl -u xray -n 50 --no-pager || true
    exit 1
  fi

  log "Xray Reality is now active on TCP/UDP 443."

  # ---------------- V2RayNG Client Link ----------------
  local HOSTNAME_FOR_LINK="${DOMAIN:-}"
  if [[ -z "$HOSTNAME_FOR_LINK" ]]; then
    HOSTNAME_FOR_LINK=$(hostname -I | awk '{print $1}')
  fi

  local SNI="www.cloudflare.com"

  VLESS_LINK="vless://${UUID}@${HOSTNAME_FOR_LINK}:443?security=reality&encryption=none&flow=xtls-rprx-vision&type=tcp&fp=chrome&sni=${SNI}&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}#Reality-${HOSTNAME_FOR_LINK}"

  log "Generated VLESS Reality link:"
  echo "$VLESS_LINK"
  echo

  # ---------------- QR Code ----------------
  local QR_IMG="/root/xray-reality-${HOSTNAME_FOR_LINK}.png"
  qrencode -o "$QR_IMG" -s 8 "$VLESS_LINK"

  log "QR code saved to: $QR_IMG"
  echo "Download via:"
  echo "  scp root@${HOSTNAME_FOR_LINK}:${QR_IMG} ."
  echo

  qrencode -t ANSIUTF8 "$VLESS_LINK" || true
  echo

  log "Xray Reality configuration completed."
}

install_xray_component "$@"
