#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_ROOT="$(cd "$MODULE_DIR/.." && pwd)"
TEMPLATE_DIR="$SCRIPT_ROOT/config/xray"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

log() { echo -e "\e[32m[*]\e[0m $*"; }
err() { echo -e "\e[31m[!]\e[0m $*" >&2; }

# ---------------- Xray install check ----------------
install_xray() {
  if ! command -v "$XRAY_BIN" >/dev/null 2>&1; then
    log "Installing Xray core..."
    bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
  else
    log "Xray core already installed."
  fi
}

# ---------------- Firewall ----------------
open_ports() {
  log "Ensuring firewall allows 443 and 8443 (TCP/UDP)..."

  if command -v ufw >/dev/null 2>&1; then
    ufw allow 443/tcp || true
    ufw allow 443/udp || true
    ufw allow 8443/tcp || true
    ufw allow 8443/udp || true
  fi

  if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport 443  -j ACCEPT || true
    iptables -I INPUT -p udp --dport 443  -j ACCEPT || true
    iptables -I INPUT -p tcp --dport 8443 -j ACCEPT || true
    iptables -I INPUT -p udp --dport 8443 -j ACCEPT || true
  fi
}

# ---------------- Reality keypair ----------------
generate_reality_keys() {
  log "Generating Reality keypair..."

  local TMP_KEYS="/tmp/xray_keys_$$.txt"
  rm -f "$TMP_KEYS"

  if ! "$XRAY_BIN" x25519 >"$TMP_KEYS" 2>&1; then
    err "xray x25519 failed:"
    cat "$TMP_KEYS" || true
    exit 1
  fi

  local priv_line pub_line hash_line
  priv_line="$(grep -i 'PrivateKey' "$TMP_KEYS" | head -n1 || true)"
  pub_line="$(grep -i 'PublicKey'  "$TMP_KEYS" | head -n1 || true)"
  hash_line="$(grep -i 'Hash32'    "$TMP_KEYS" | head -n1 || true)"

  PRIVATE_KEY="$(printf '%s\n' "$priv_line" | awk -F': *' '{print $2}' || true)"

  if [[ -n "${pub_line:-}" ]]; then
    PUBLIC_KEY="$(printf '%s\n' "$pub_line" | awk -F': *' '{print $2}')"
  else
    PUBLIC_KEY="$(printf '%s\n' "$hash_line" | awk -F': *' '{print $2}')"
  fi

  rm -f "$TMP_KEYS"

  if [[ -z "${PRIVATE_KEY:-}" || -z "${PUBLIC_KEY:-}" ]]; then
    err "Failed to parse Reality keypair."
    exit 1
  fi

  UUID="$(cat /proc/sys/kernel/random/uuid)"
  SHORT_ID="$(openssl rand -hex 4)"

  export PRIVATE_KEY PUBLIC_KEY UUID SHORT_ID

  log "Reality keys:"
  log "  UUID:      $UUID"
  log "  PublicKey: $PUBLIC_KEY"
  log "  PrivateKey: $PRIVATE_KEY"
  log "  ShortId:   $SHORT_ID"
}

# ---------------- Render template ----------------
render_config() {
  local template_file="$TEMPLATE_DIR/reality.json.template"

  if [[ ! -f "$template_file" ]]; then
    err "Template not found: $template_file"
    exit 1
  fi

  log "Rendering Xray config from template..."

  rm -f "$XRAY_CONFIG"

  sed \
    -e "s|{{UUID}}|$UUID|g" \
    -e "s|{{PRIVATE_KEY}}|$PRIVATE_KEY|g" \
    -e "s|{{SHORT_ID}}|$SHORT_ID|g" \
    "$template_file" > "$XRAY_CONFIG"
}

# ---------------- VLESS link + QR ----------------
generate_vless_link() {
  local domain
  if [[ -n "${DOMAIN:-}" ]]; then
    domain="$DOMAIN"
  elif [[ -f "$SCRIPT_ROOT/config/domain" ]]; then
    domain="$(tr -d '[:space:]' < "$SCRIPT_ROOT/config/domain")"
  else
    domain="icetea-shinchan.xyz"
  fi

  VLESS_LINK="vless://${UUID}@${domain}:443?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&fp=chrome&sni=www.cloudflare.com&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#Reality-${domain}"
  echo "$VLESS_LINK"
}

generate_qr_code() {
  local link="$1"

  if ! command -v qrencode >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y qrencode
  fi

  mkdir -p "$SCRIPT_ROOT/output"

  echo
  log "VLESS Reality link:"
  echo "$link"
  echo

  log "QR Code (terminal):"
  echo "$link" | qrencode -t ANSIUTF8

  local png="$SCRIPT_ROOT/output/xray_reality_qr.png"
  qrencode -o "$png" "$link"
  log "QR Code PNG saved to: $png"
}

# ---------------- Main ----------------
main() {
  install_xray
  open_ports
  generate_reality_keys
  render_config

  log "Restarting Xray..."
  systemctl restart xray || err "Systemd restart failed."

  local link
  link="$(generate_vless_link)"
  generate_qr_code "$link"

  log "Xray VLESS+XTLS-Vision+Reality on 443 is ready."
}

main "$@"
