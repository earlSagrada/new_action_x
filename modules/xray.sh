#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$MODULE_DIR/.." && pwd)"
source "$SCRIPT_DIR/modules/common.sh"

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"

TLS_CERT_BASE="/etc/letsencrypt/live/${DOMAIN:-}"
TLS_CERT_FULLCHAIN="${TLS_CERT_BASE}/fullchain.pem"
TLS_CERT_PRIVKEY="${TLS_CERT_BASE}/privkey.pem"

install_xray() {
  if ! command -v xray >/dev/null 2>&1; then
    log "[*] Installing Xray core..."
    bash <(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
  else
    log "[*] Xray core already installed."
  fi
}

generate_reality_keys() {
  log "[*] Generating reality keypair..."
  log "[*] Generating Reality keypair..."

  # Run keygen safely
  KEY_JSON=$("${XRAY_BIN}" x25519 2>/dev/null || true)

  # Newer versions output pure JSON, older versions output plaintext.
  if echo "$KEY_JSON" | grep -q "Private"; then
      # Old style plaintext output
      PRIVATE_KEY=$(echo "$KEY_JSON" | awk '/Private/ {print $2}')
      PUBLIC_KEY=$(echo "$KEY_JSON" | awk '/Public/ {print $2}')
  else
      # JSON format
      PRIVATE_KEY=$(echo "$KEY_JSON" | grep private | sed 's/.*: "\(.*\)".*/\1/')
      PUBLIC_KEY=$(echo "$KEY_JSON" | grep public | sed 's/.*: "\(.*\)".*/\1/')
  fi

  if [[ -z "${PRIVATE_KEY:-}" || -z "${PUBLIC_KEY:-}" ]]; then
      err "Failed to generate Reality keys! Output was: $KEY_JSON"
      exit 1
  fi

  UUID=$(cat /proc/sys/kernel/random/uuid)
  SHORT_ID=$(openssl rand -hex 4)

  export PRIVATE_KEY PUBLIC_KEY UUID SHORT_ID

  log "[*] Reality keys generated:"
  echo "  Private: $PRIVATE_KEY"
  echo "  Public:  $PUBLIC_KEY"
  echo "  UUID:    $UUID"
  echo "  ShortId: $SHORT_ID"

  log "[*] Reality keypair generated:"
  echo "  PrivateKey: $PRIVATE_KEY"
  echo "  PublicKey:  $PUBLIC_KEY"

  UUID=$(cat /proc/sys/kernel/random/uuid)
  SHORT_ID=$(openssl rand -hex 4)

  export PRIVATE_KEY PUBLIC_KEY UUID SHORT_ID
}

render_reality_inbound() {
  local TEMPLATE="$SCRIPT_DIR/config/xray/reality.json.template"
  local OUTPUT="/tmp/inbound_reality.json"

  log "[*] Rendering Reality inbound (port 24443)..."
  render_template "$TEMPLATE" "$OUTPUT" PRIVATE_KEY PUBLIC_KEY UUID SHORT_ID

  cat "$OUTPUT"
}

render_tls_fallback_inbound() {
  local OUTPUT="/tmp/inbound_tls_fallback.json"

  log "[*] Rendering TLS fallback inbound (port 443)..."

  cat > "$OUTPUT" <<EOF
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
          "certificateFile": "${TLS_CERT_FULLCHAIN}",
          "keyFile": "${TLS_CERT_PRIVKEY}"
        }
      ]
    }
  }
}
EOF

  cat "$OUTPUT"
}

merge_config() {
  log "[*] Combining TLS fallback + Reality inbound into final config.json..."

  cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "error": "/var/log/xray/error.log",
    "access": "/var/log/xray/access.log"
  },
  "inbounds": [
$(cat /tmp/inbound_tls_fallback.json),
$(cat /tmp/inbound_reality.json)
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

restart_xray() {
  log "[*] Restarting Xray..."
  systemctl restart xray
  sleep 1
  systemctl status xray --no-pager
}

print_client_link() {
  local LINK="vless://${UUID}@${DOMAIN}:24443?security=reality&encryption=none&type=tcp&flow=xtls-rprx-vision&sni=www.cloudflare.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#Reality-${DOMAIN}"
  echo
  echo "[*] Your Reality client link:"
  echo "$LINK"
  echo
}

main() {
  if [[ -z "${DOMAIN:-}" ]]; then
    err "DOMAIN environment variable is required!"
    exit 1
  fi

  install_xray
  generate_reality_keys
  render_tls_fallback_inbound
  render_reality_inbound
  merge_config
  restart_xray
  print_client_link

  log "[*] Xray setup complete."
}

main "$@"
