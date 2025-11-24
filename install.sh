#!/usr/bin/env bash
set -euo pipefail

# ============================================
# NEW_ACTION_X One-Click Installer
# Repo: https://github.com/earlSagrada/new_action_x
# ============================================

REPO_URL="https://github.com/earlSagrada/new_action_x.git"
WORK_DIR="/opt/new_action_x"
INTERNAL_FLAG="--internal-run"

CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"

# Global options
MODE="interactive"
DOMAIN=""
EMAIL=""

# Load shared functions (log, err)
source "$WORK_DIR/modules/common.sh"

# ------------- Helper: colored echo -------------
cecho() {
  local color="$1"; shift
  local code=""
  case "$color" in
    red)    code="31";;
    green)  code="32";;
    yellow) code="33";;
    blue)   code="34";;
    *)      code="0";;
  esac
  printf "\033[%sm%s\033[0m\n" "$code" "$*"
}

# ------------- Helper: ensure root --------------
ensure_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    cecho red "[!] This script must be run as root (use sudo)."
    exit 1
  fi
}

# ------------- Helper: ensure git ---------------
ensure_git() {
  if ! command -v git >/dev/null 2>&1; then
    cecho yellow "[*] git not found. Installing git..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y
      apt-get install -y git
    else
      cecho red "[!] apt-get not available. Please install git manually and re-run."
      exit 1
    fi
  fi
}

# ------------- Stage 1: bootstrap ---------------
bootstrap_repo() {
  ensure_root
  ensure_git

  cecho blue "[*] Bootstrapping NEW_ACTION_X into $WORK_DIR"
  if [[ ! -d "$WORK_DIR/.git" ]]; then
    mkdir -p "$WORK_DIR"
    cecho blue "[*] Cloning $REPO_URL ..."
    git clone "$REPO_URL" "$WORK_DIR"
  else
    cecho blue "[*] Repo exists – resetting to latest remote version..."
    git -C "$WORK_DIR" fetch --all
    git -C "$WORK_DIR" reset --hard origin/main
  fi

  cecho green "[*] Repo ready at $WORK_DIR"
  cecho blue "[*] Handing control to repo-managed installer..."

  # Re-exec installer from inside the repo, preserving user args
  exec bash "$WORK_DIR/$SCRIPT_NAME" "$INTERNAL_FLAG" "$@"
}

# If not internal and not running from WORK_DIR → bootstrap mode
if [[ "${1:-}" != "$INTERNAL_FLAG" ]] || [[ "$CURRENT_DIR" != "$WORK_DIR" ]]; then
  bootstrap_repo "$@"
  # never returns
fi

# ------------- Stage 2: actual installer --------
# We are now:
# - running from $WORK_DIR
# - first argument is --internal-run
shift || true  # drop --internal-run

ensure_root

# Logging
LOG_FILE="/tmp/new_action_x_install_$(date +%Y%m%d_%H%M%S).log"
cecho blue "[*] Logging installation to: $LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# Re-detect current dir (should be WORK_DIR)
CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_DIR="$CURRENT_DIR/modules"

# ------------- Util for modules -----------------
check_module_exists() {
  local mod="$1"
  if [[ ! -f "$MODULE_DIR/$mod" ]]; then
    cecho red "[!] Required module not found: $MODULE_DIR/$mod"
    exit 1
  fi
}

run_module() {
  local mod="$1"
  check_module_exists "$mod"
  cecho blue "[*] Running module: $mod"
  bash "$MODULE_DIR/$mod"
}

banner() {
  echo "=========================================="
  echo "        NEW_ACTION_X – Installer          "
  echo " Repo: $REPO_URL"
  echo " Work dir: $WORK_DIR"
  echo " Log: $LOG_FILE"
  echo "=========================================="
}

usage() {
  cat <<EOF
Usage:
  sudo ./install.sh                     # interactive menu
  sudo ./install.sh --full   [--domain example.com --email admin@example.com]
  sudo ./install.sh --xray   [--domain example.com --email admin@example.com]
  sudo ./install.sh --update [--domain example.com --email admin@example.com]

Options:
  --full      Full install (nginx + aria2 + AriaNg + filebrowser + fail2ban + xray)
  --xray      Xray-only (VLESS + Reality)
  --update    Update all components
  --domain    Primary domain name (used for nginx, certbot, etc.)
  --email     Email for Let's Encrypt registration
  -h, --help  Show this help

If --domain / --email are omitted, you will be prompted interactively.
EOF
}

# Install health-check tools
install_health_checks() {
    mkdir -p /usr/local/bin
    cp "$WORK_DIR/bin/xray-check.sh" /usr/local/bin/xray-check
    chmod +x /usr/local/bin/xray-check
    log "Installed xray-check tool: use 'xray-check' anytime to debug Xray."
}

# ------------- Argument parsing -----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full)
      MODE="full"
      shift
      ;;
    --xray)
      MODE="xray"
      shift
      ;;
    --update)
      MODE="update"
      shift
      ;;
    --domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    --email)
      EMAIL="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      cecho red "[!] Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

# ------------- Ask for domain/email if needed ---
ask_domain_email_if_missing() {
  if [[ -z "$DOMAIN" ]]; then
    read -rp "Enter your domain (e.g. example.com): " DOMAIN
  fi

  if [[ -z "$EMAIL" ]]; then
    read -rp "Enter your email for Let's Encrypt: " EMAIL
  fi

  export DOMAIN
  export EMAIL
  # Let modules know they should NOT try to be interactive anymore
  export NON_INTERACTIVE=true
}

# ------------- Actions --------------------------
full_install() {
  banner
  ask_domain_email_if_missing

  cecho green "[*] Starting FULL install (nginx + aria2 + AriaNg + filebrowser + fail2ban + xray)..."
  
  chmod +x /opt/new_action_x/modules/common.sh
  chmod +x /opt/new_action_x/modules/nginx.sh

  run_module "nginx.sh"
  run_module "aria2.sh"
  run_module "ariang.sh"
  run_module "filebrowser.sh"
  run_module "fail2ban.sh"
  run_module "xray.sh"

  cecho green "[✓] Full install completed."
  install_health_checks
}

xray_only_install() {
  banner
  ask_domain_email_if_missing

  cecho green "[*] Starting XRAY-ONLY install (VLESS + Reality on UDP/443)..."

  run_module "xray.sh"

  cecho green "[✓] Xray-only install completed."
  install_health_checks
}

update_all() {
  banner
  ask_domain_email_if_missing

  cecho green "[*] Updating NEW_ACTION_X components..."

  chmod +x /opt/new_action_x/modules/common.sh
  chmod +x /opt/new_action_x/modules/nginx.sh
  
  run_module "nginx.sh"
  run_module "aria2.sh"
  run_module "ariang.sh"
  run_module "filebrowser.sh"
  run_module "fail2ban.sh"
  run_module "xray.sh"

  cecho green "[✓] Update completed."
  install_health_checks
}

interactive_menu() {
  banner
  echo
  echo "Choose installation mode:"
  echo "  1) Full install (nginx + aria2 + AriaNg + filebrowser + fail2ban + xray)"
  echo "  2) Xray-only (VLESS + Reality)"
  echo "  3) Update existing installation"
  echo "  4) Exit"
  echo
  read -rp "Enter choice [1-4]: " choice

  case "$choice" in
    1) full_install ;;
    2) xray_only_install ;;
    3) update_all ;;
    4) cecho yellow "[*] Exit requested. Nothing done."; exit 0 ;;
    *) cecho red "[!] Invalid choice."; exit 1 ;;
  esac
}

# ------------- Dispatch -------------------------
case "$MODE" in
  full)      full_install ;;
  xray)      xray_only_install ;;
  update)    update_all ;;
  *)         interactive_menu ;;
esac
