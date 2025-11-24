#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(dirname "$0")"
TEMPLATE_DIR="/opt/new_action_x/config/xray"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

log() { echo -e "\e[32m[*]\e[0m $*"; }
err() { echo -e "\e[31m[!]\e[0m $*" >&2; }

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

  # Parse fields
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

  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    err "Failed to parse Reality keypair."
    exit 1
  fi

  UUID="$(cat /proc/sys/kernel/random/uuid)"
  SHORT_ID="$(openssl rand -hex 4)"
}

# ---------------- Template rendering ----------------
render_template() {
  local template_file="$1"
  local output_file="$2"

  sed \
    -e "s|{{UUID}}|$UUID|g" \
    -e "s|{{PRIVATE_KEY}}|$PRIVATE_KEY|g" \
    -e "s|{{PUBLIC_KEY}}|$PUBLIC_KEY|g" \
    -e "s|{{SHORT_ID}}|$SHORT_ID|g" \
    -e "s|{{PORT}}|24443|g" \
    "$template_file" > "$output_file"
}

# ---------------- TLS inbound (static) ----------------
render_tls_inbound() {
  local out="/tmp/tls_inbound.json"

  cat > "$out" <<EOF
{
  "tag": "tls-fallback",
  "listen": "0.0.0.0",
  "port": 443,
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none",
    "fallbacks": [
      { "dest": 8443, "xver": 0 }
    ]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "tls",
    "tlsSettings": {
      "alpn": ["http/1.1", "h2"],
      "certificates": [
        {
          "certificateFile": "/etc/letsencrypt/live/icetea-shinchan.xyz/fullchain.pem",
          "keyFile": "/etc/letsencrypt/live/icetea-shinchan.xyz/privkey.pem"
        }
      ]
    }
  }
}
EOF
}

# ---------------- Final config writing ----------------
write_final_config() {
  log "Writing Xray final config (overwrite mode)..."

  # HARD RESET: remove old config completely
  rm -f "$XRAY_CONFIG"

  cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "error": "/var/log/xray/error.log",
    "access": "/var/log/xray/access.log"
  },

  "inbounds": [
$(cat /tmp/tls_inbound.json),
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

generate_vless_link() {
  DOMAIN="icetea-shinchan.xyz"
  PORT=24443

  VLESS_LINK="vless://${UUID}@${DOMAIN}:${PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&fp=chrome&sni=www.cloudflare.com&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#Reality-${DOMAIN}"

  echo "$VLESS_LINK"
}

generate_qr_code() {
  local link="$1"

  if ! command -v qrencode >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y qrencode
  fi
  
  mkdir -p /opt/new_action_x/output

  echo
  log "Your VLESS Reality link:"
  echo "$link"

  echo
  log "QR Code (ANSI):"
  echo "$link" | qrencode -t ANSIUTF8

  qrencode -o /opt/new_action_x/output/xray_reality_qr.png "$link"
  log "PNG saved to /opt/new_action_x/output/xray_reality_qr.png"
}


# ---------------- Main run ----------------

log "Xray core already installed."

log "Ensuring firewall allows Reality port 24443 (TCP/UDP)..."
ufw allow 24443/tcp || true
ufw allow 24443/udp || true

# Fallback for non-UFW systems
if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport 24443 -j ACCEPT || true
    iptables -I INPUT -p udp --dport 24443 -j ACCEPT || true
fi

generate_reality_keys

render_tls_inbound
render_template "$TEMPLATE_DIR/reality.json.template" /tmp/reality_inbound.json

write_final_config

log "Restarting Xray..."
systemctl restart xray || err "Systemd restart failed."

# Create VLESS link
VLESS_LINK="$(generate_vless_link)"

# Generate QR code
generate_qr_code "$VLESS_LINK"

log "Xray installation complete."

