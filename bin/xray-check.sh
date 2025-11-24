#!/usr/bin/env bash
set -eo pipefail

echo "=== Xray Health Check ==="
echo

# 1. Service status
echo "[1] Systemd service status:"
systemctl is-active --quiet xray && echo "✔ Xray is running" || echo "✘ Xray is NOT running"
echo

# 2. Check config validity
echo "[2] Checking config validity:"
if xray run -test -config /usr/local/etc/xray/config.json >/tmp/xray_test.out 2>&1; then
    echo "✔ Config is valid"
else
    echo "✘ Config ERROR:"
    sed 's/^/    /' /tmp/xray_test.out
fi
echo

# 3. Check port listening
echo "[3] Checking if port 443 is open:"
if ss -tulnp | grep -q ':443'; then
    echo "✔ Port 443 bound"
else
    echo "✘ Port 443 NOT listening"
fi
echo

# 4. Check Reality config fields
echo "[4] Checking Reality fields in config:"
json_file="/usr/local/etc/xray/config.json"

for key in privateKey publicKey shortIds; do
    if grep -q "$key" "$json_file"; then
        echo "✔ Found $key"
    else
        echo "✘ Missing $key"
    fi
done

echo
echo "=== Health check complete ==="

echo "[5] Testing external reachability (basic HTTP check):"
TARGETS=(
  "https://www.google.com"
  "https://www.cloudflare.com"
  "https://www.bing.com"
  "https://www.youtube.com"
)

for url in "${TARGETS[@]}"; do
    if curl -Is --max-time 5 "$url" >/dev/null 2>&1; then
        echo "✔ OK: $url"
    else
        echo "✘ FAIL: $url"
    fi
done
echo

echo "[6] Testing if your own VPS hostname resolves:"
HOSTNAME_IP="$(hostname -I | awk '{print $1}')"
echo "Server IPv4: $HOSTNAME_IP"


echo "[7] Testing Xray inbound loopback (basic):"

JSON_FILE="/usr/local/etc/xray/config.json"

UUID="$(grep -oP '(?<="id": ")[^"]+' "$JSON_FILE" | head -n1 || true)"
PBK="$(grep -oP '(?<="publicKey": ")[^"]+' "$JSON_FILE" | head -n1 || true)"
SID="$(grep -oP '(?<="shortIds": \["?)([^"]+)' "$JSON_FILE" | head -n1 || true)"

UUID="${UUID:-}"
PBK="${PBK:-}"
SID="${SID:-}"

if [[ -z "$UUID" ]]; then
    echo "Skipping loopback test: UUID not found in config."
    exit 0
fi

if curl --proxy "vless://${UUID}@127.0.0.1:443" -Is https://www.cloudflare.com >/dev/null 2>&1; then
    echo "✔ Xray inbound reachable from VPS"
else
    echo "✘ Xray inbound NOT reachable from VPS"
fi
