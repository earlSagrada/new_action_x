#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_ROOT="$(cd "$MODULE_DIR/.." && pwd)"
TEMPLATE_DIR="$SCRIPT_ROOT/config/xray"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

log() { echo -e "\e[32m[*]\e[0m $*"; }
err() { echo -e "\e[31m[!]\e[0m $*" >&2; }

# ---------------- Check DOMAIN ----------------
ensure_domain() {
  if [[ -z "${DOMAIN:-}" ]]; then
    if [[ -f "$SCRIPT_ROOT/config/domain" ]]; then
      DOMAIN="$(cat "$SCRIPT_ROOT/config/domain" | tr -d '[:space:]')"
      export DOMAIN
    fi
  fi

  if [[ -z "${DOMAIN:-}" ]]; then
    err "DOMAIN is not set. Please export DOMAIN or put it in config/domain."
    exit 1
  fi

  log "Using DOMAIN: $DOMAIN"
}

# ---------------- Install Xray if missing ----------------
install_xray() {
  if ! command -v xray >/dev/null 2>&1; then
    log "Installing Xray core..."
    bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
  else
    log "Xray core already installed."
  fi
}

# ---------------- Firewall for 443/8443 ----------------
open_ports() {
  log "Ensuring firewall allows ports 443 and 8443..."

  if command -v ufw >/dev/null 2>&1; then
    ufw allow 443/tcp || true
    ufw allow 443/udp || true
    ufw allow 8443/tcp || true
    ufw allow 8443/udp || true
  fi

  if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT || true
    iptables -I INPUT -p udp --dport 443 -j ACCEPT || true
    iptables -I INPUT -p tcp --dport 8443 -j ACCEPT || true
    iptables -I INPUT -p udp --dport 8443 -j ACCEPT || true
  fi
}

# ---------------- Keypair generation ----------------
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

  log "Reality keys generated:"
  log "  UUID:       $UUID"
  log "  PublicKey:  $PUBLIC_KEY"
  log "  ShortId:    $SHORT_ID"
}

# ---------------- Template rendering ----------------
render_reality_inbound() {
  local template_file="$TEMPLATE_DIR/reality.json.template"
  local output_file="/tmp/reality_inbound.json"

  if [[ ! -f "$template_file" ]]; then
    err "Template not found: $template_file"
    exit 1
  fi

  sed \
    -e "s|{{UUID}}|$UUID|g" \
    -e "s|{{PRIVATE_KEY}}|$PRIVATE_KEY|g" \
    -e "s|{{PUBLIC_KEY}}|$PUBLIC_KEY|g" \
    -e "s|{{SHORT_ID}}|$SHORT_ID|g" \
    -e "s|{{DOMAIN}}|$DOMAIN|g" \
    "$template_file" > "$output_file"
}

# ---------------- Write final config ----------------
write_final_config() {
  log "Writing Xray final config (overwrite mode)..."

  rm -f "$XRAY_CONFIG"

  cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "error": "/var/log/xray/error.log",
    "access": "/var/log/xray/access.log"
  },

  "inbounds": [
$(cat /tmp/reality_inbound.json)
  ],

  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

# ---------------- VLESS link + QR ----------------
generate_vless_link() {
  local port=443
  local sni="www.cloudflare.com"

  VLESS_LINK="vless://${UUID}@${DOMAIN}:${port}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&fp=chrome&sni=${sni}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#Reality-${DOMAIN}"
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
  ensure_domain
  install_xray
  open_ports
  generate_reality_keys
  render_reality_inbound
  write_final_config

  log "Restarting Xray..."
  systemctl restart xray || err "Systemd restart failed."

  local link
  link="$(generate_vless_link)"
  generate_qr_code "$link"

  log "Xray Reality on 443 is ready."
}

main "$@"
