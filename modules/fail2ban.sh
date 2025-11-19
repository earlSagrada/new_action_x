#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$MODULE_DIR/.." && pwd)"
source "$SCRIPT_DIR/modules/common.sh"

install_fail2ban_protection() {
  log "Configuring fail2ban aggressive protection..."

  if ! command -v fail2ban-server >/dev/null 2>&1; then
    log "Installing fail2ban..."
    apt-get update -y
    apt-get install -y fail2ban
  fi

  mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d

  # Xray Reality jail
  cat >/etc/fail2ban/filter.d/xray-reality.conf <<'EOF'
[Definition]
failregex = ^.*reality.*(fail|error).*
ignoreregex =
EOF

  cat >/etc/fail2ban/jail.d/xray-reality.conf <<EOF
[xray-reality]
enabled   = true
filter    = xray-reality
backend   = systemd
journalmatch = _SYSTEMD_UNIT=xray.service
maxretry  = 3
findtime  = 48h
bantime   = 10d
EOF

  # nginx strict jail
  cat >/etc/fail2ban/filter.d/nginx-hard.conf <<'EOF'
[Definition]
failregex = ^<HOST> -.*"(GET|POST).*HTTP.*" (400|401|403|404)
ignoreregex =
EOF

  cat >/etc/fail2ban/jail.d/nginx-hard.conf <<EOF
[nginx-hard]
enabled  = true
filter   = nginx-hard
port     = http,https
logpath  = /var/log/nginx/access.log
maxretry = 3
findtime = 48h
bantime  = 10d
EOF

  systemctl enable fail2ban
  systemctl restart fail2ban

  if ! systemctl is-active --quiet fail2ban; then
    err "fail2ban failed to start!"
    journalctl -u fail2ban -n 50 --no-pager || true
    exit 1
  fi

  log "Fail2ban installed and configured (nginx + Xray jails, 3 tries/48h → 10d ban)."
}

install_fail2ban_protection "$@"
