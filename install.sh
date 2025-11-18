#!/usr/bin/env bash
#
# Unified installer for:
#  - aria2 (+ systemd service)
#  - AriaNg (latest from GitHub)
#  - FileBrowser
#  - nginx + certbot (HTTP/2 + HTTP/3 if supported)
#  - Xray (VLESS+Reality on UDP/443; others as future options)
#
# Ubuntu/Debian only.

set -euo pipefail

########################
# Paths / Globals
########################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_ARIA2=false
INSTALL_ARIANG=false
INSTALL_FILEBROWSER=false
INSTALL_NGINX=false
INSTALL_XRAY=false

XRAY_ONLY=false
XRAY_INBOUND="reality"   # currently supported: "reality" (VLESS+Reality on UDP/443)

DOMAIN=""
EMAIL=""
RPC_SECRET=""
NON_INTERACTIVE=false
DEBUG=false

DOWNLOAD_DIR="/srv/downloads"
ARIA2_CONF_DIR="/etc/aria2"
ARIA2_CONF="${ARIA2_CONF_DIR}/aria2.conf"
ARIA2_SERVICE_PATH="/etc/systemd/system/aria2.service"

FILEBROWSER_CONF_DIR="/etc/filebrowser"
FILEBROWSER_DB_DIR="/var/lib/filebrowser"
FILEBROWSER_LOG="/var/log/filebrowser.log"
FILEBROWSER_CONF="${FILEBROWSER_CONF_DIR}/filebrowser.json"
FILEBROWSER_SERVICE_PATH="/etc/systemd/system/filebrowser.service"

WEBROOT="/var/www/ariang"
NGINX_SITE="/etc/nginx/sites-available/aria2_suite.conf"

LOG_DIR="/var/log/aria2suite"
LOG_FILE="${LOG_DIR}/install.log"

########################
# Logging / utils
########################

log() {
  echo -e "[+] $*"
}

err() {
  echo -e "[!] $*" >&2
}

usage() {
  cat <<EOF
Usage: sudo $0 [options]

Component flags:
  --all                Install everything (aria2 + AriaNg + FileBrowser + nginx)
  --aria2              Install aria2 (with systemd service)
  --ariang             Install AriaNg (web UI)
  --filebrowser        Install FileBrowser
  --nginx              Install nginx + certbot + reverse proxy
  --xray               Install Xray (plus other selected components)
  --xray-only          Install Xray only (no aria2/nginx/etc)

Xray options:
  --xray-inbound TYPE  Xray inbound type (currently: reality)
                       "reality" = VLESS + Reality on UDP/443 (xtls-rprx-vision)

Common options:
  --domain DOMAIN      Your primary domain (for nginx/certbot)
  --email EMAIL        Email for certbot/Let's Encrypt
  --rpc-secret SECRET  RPC secret for aria2 JSON-RPC; if omitted, a random one is generated
  -y, --non-interactive  Do not prompt (fail if required info is missing)
  --debug              Enable verbose debug output and log to ${LOG_FILE}
  -h, --help           Show this help message

Examples:
  sudo $0 --all --domain example.com --email admin@example.com
  sudo $0 --aria2 --ariang --nginx --domain dl.example.com --email me@example.com
  sudo $0 --xray-only --xray-inbound reality
EOF
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "This script must be run as root (sudo)."
    exit 1
  fi
}

enable_debug_if_requested() {
  if $DEBUG; then
    mkdir -p "$LOG_DIR"
    echo "Debug mode enabled. Logging to $LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    set -x
  fi
}

generate_rpc_secret() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    INSTALL_ARIA2=true
    INSTALL_ARIANG=true
    INSTALL_FILEBROWSER=true
    INSTALL_NGINX=true
    return
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)
        INSTALL_ARIA2=true
        INSTALL_ARIANG=true
        INSTALL_FILEBROWSER=true
        INSTALL_NGINX=true
        ;;
      --aria2)        INSTALL_ARIA2=true ;;
      --ariang)       INSTALL_ARIANG=true ;;
      --filebrowser)  INSTALL_FILEBROWSER=true ;;
      --nginx)        INSTALL_NGINX=true ;;
      --xray)         INSTALL_XRAY=true ;;
      --xray-only)
        XRAY_ONLY=true
        INSTALL_XRAY=true
        ;;
      --xray-inbound)
        XRAY_INBOUND="${2:-}"
        shift
        ;;
      --domain)
        DOMAIN="${2:-}"
        shift
        ;;
      --email)
        EMAIL="${2:-}"
        shift
        ;;
      --rpc-secret)
        RPC_SECRET="${2:-}"
        shift
        ;;
      -y|--non-interactive)
        NON_INTERACTIVE=true
        ;;
      --debug)
        DEBUG=true
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done

  # If xray-only is requested, force other components off
  if $XRAY_ONLY; then
    INSTALL_ARIA2=false
    INSTALL_ARIANG=false
    INSTALL_FILEBROWSER=false
    INSTALL_NGINX=false
  fi

  # If nothing selected at all (and not xray-only), default to all
  if ! $INSTALL_ARIA2 && ! $INSTALL_ARIANG && ! $INSTALL_FILEBROWSER && ! $INSTALL_NGINX && ! $INSTALL_XRAY; then
    log "No components specified; defaulting to --all."
    INSTALL_ARIA2=true
    INSTALL_ARIANG=true
    INSTALL_FILEBROWSER=true
    INSTALL_NGINX=true
  fi

  # Xray inbound sanity check
  if $INSTALL_XRAY; then
    if [[ -z "$XRAY_INBOUND" ]]; then
      err "Xray installation requested but no --xray-inbound specified."
      exit 1
    fi
  fi
}

ensure_apt() {
  if ! command -v apt >/dev/null 2>&1; then
    err "This installer is intended for Debian/Ubuntu (apt-based) systems."
    exit 1
  fi
}

install_base_packages() {
  log "Updating apt and installing base packages..."
  apt update -y
  apt install -y curl wget unzip jq ufw openssl qrencode fail2ban

  if $INSTALL_NGINX; then
    apt install -y nginx certbot
  fi
  if $INSTALL_ARIA2; then
    apt install -y aria2
  fi
}

diagnose_environment() {
  log "--- Environment diagnostics ---"
  log "Date: $(date)"
  log "OS:"
  (lsb_release -a 2>/dev/null || cat /etc/os-release 2>/dev/null || echo "Unknown OS") | sed 's/^/  /'
  log "Kernel: $(uname -a)"
  log "Root disk usage:"
  df -h / | sed 's/^/  /'
  log "Memory:"
  free -h | sed 's/^/  /'
  log "Firewall (ufw) status:"
  ufw status 2>/dev/null | sed 's/^/  /' || echo "  ufw not installed"
  log "nginx version:"
  nginx -v 2>&1 || echo "  nginx not installed yet"
  log "curl version:"
  curl --version | head -n 1 | sed 's/^/  /'
  log "jq version:"
  jq --version 2>/dev/null | sed 's/^/  /' || echo "  jq not installed"
  log "--------------------------------"
}

configure_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    log "ufw not installed; skipping firewall configuration."
    return
  fi
  if ! ufw status | grep -qi "Status: active"; then
    log "ufw is installed but inactive; not modifying firewall rules."
    return
  fi

  log "Configuring ufw rules..."
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 51413/tcp
  ufw allow 51413/udp
  # Xray Reality on UDP/443 (same as QUIC); no extra rule needed if 443/udp is open
  ufw allow 443/udp
}

nginx_supports_http3() {
  if nginx -V 2>&1 | grep -q 'http_v3_module'; then
    return 0
  fi
  return 1
}

# Simple template renderer:
#   render_template input output VAR1 VAR2 ...
render_template() {
  local in="$1"
  local out="$2"
  shift 2
  local tmp
  tmp="$(cat "$in")"

  local var
  for var in "$@"; do
    local val="${!var:-}"
    tmp="$(printf '%s' "$tmp" | sed "s@{{${var}}}@${val}@g")"
  done

  printf '%s' "$tmp" >"$out"
}

########################
# Source modules
########################

source "${SCRIPT_DIR}/modules/aria2.sh"
source "${SCRIPT_DIR}/modules/ariang.sh"
source "${SCRIPT_DIR}/modules/filebrowser.sh"
source "${SCRIPT_DIR}/modules/nginx.sh"
source "${SCRIPT_DIR}/modules/xray.sh"
source "${SCRIPT_DIR}/modules/fail2ban.sh"

########################
# Main
########################

main() {
  require_root
  parse_args "$@"
  enable_debug_if_requested
  ensure_apt
  install_base_packages
  diagnose_environment
  configure_ufw

  if $INSTALL_ARIA2 && [[ -z "$RPC_SECRET" ]]; then
    RPC_SECRET="$(generate_rpc_secret)"
    log "Generated random aria2 RPC secret."
  fi

  if $INSTALL_ARIA2; then
    install_aria2_component
  fi

  if $INSTALL_FILEBROWSER; then
    install_filebrowser_component
  fi

  if $INSTALL_ARIANG; then
    install_ariang_component
  fi

  if $INSTALL_NGINX; then
    install_nginx_component
  fi

  if $INSTALL_XRAY; then
    install_xray_component
  fi

  echo
  echo "===================================================="
  echo "Installation finished."
  echo "  Downloads directory: ${DOWNLOAD_DIR}"
  if $INSTALL_ARIANG && $INSTALL_NGINX; then
    echo "  AriaNg URL:          https://${DOMAIN}/"
  fi
  if $INSTALL_FILEBROWSER && $INSTALL_NGINX; then
    echo "  FileBrowser URL:     https://file.${DOMAIN}/"
    echo "  FileBrowser default: admin / admin (change ASAP)"
  fi
  if $INSTALL_ARIA2; then
    echo "  aria2 RPC secret:    ${RPC_SECRET}"
    echo "  aria2 listening on:  127.0.0.1:6800 (proxied via nginx /jsonrpc)"
  fi
  if $INSTALL_NGINX; then
    if nginx_supports_http3; then
      echo "  nginx HTTP/3:        ENABLED (QUIC on 443 if certs present)"
    else
      echo "  nginx HTTP/3:        NOT AVAILABLE (no http_v3_module in nginx build)"
    fi
  fi
  if $INSTALL_XRAY; then
    echo "  Xray inbound:        ${XRAY_INBOUND}"
    echo "  See above log for UUID / keys, or re-run with --debug and check ${LOG_FILE}"
  fi

  install_fail2ban_protection

  echo
  echo "If something failed, check: ${LOG_FILE} (if --debug was used)"
  echo "===================================================="
}

main "$@"
