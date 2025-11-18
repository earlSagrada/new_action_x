#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"

install_fail2ban_protection() {
  log "Configuring fail2ban aggressive protection..."

  # Ensure directories
  mkdir -p /etc/fail2ban/jail.d
  mkdir -p /etc/fail2ban/filter.d

  #############################
  # Fail2ban: Xray Reality
  #############################
  cat >/etc/fail2ban/filter.d/xray-reality.conf <<'EOF'
[Definition]
failregex = ^.*reality.*(fail|error).*
ignoreregex =
EOF

  cat >/etc/fail2ban/jail.d/xray-reality.conf <<EOF
[xray-reality]
enabled = true
filter = xray-reality
backend = systemd
journalmatch = _SYSTEMD_UNIT=xray.service
maxretry = 3
findtime = 48h
bantime = 10d
EOF


  #############################
  # Fail2ban: nginx brute force
  #############################
  cat >/etc/fail2ban/filter.d/nginx-hard.conf <<'EOF'
[Definition]
failregex = ^<HOST> -.*"(GET|POST).*HTTP.*" (400|401|403|404)
ignoreregex =
EOF

  cat >/etc/fail2ban/jail.d/nginx-hard.conf <<EOF
[nginx-hard]
enabled = true
filter = nginx-hard
port = http,https
logpath = /var/log/nginx/access.log
maxretry = 3
findtime = 48h
bantime = 10d
EOF

  systemctl restart fail2ban
  log "Fail2ban installed and configured with strict protection."
}

install_fail2ban_protection "$@"
