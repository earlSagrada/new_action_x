#!/usr/bin/env bash
set -euo pipefail

# If SCRIPT_DIR not preset, assume this file lives in modules/ under repo root
if [[ -z "${SCRIPT_DIR:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

log() {
  echo -e "\033[32m[*]\033[0m $*"
}

warn() {
  echo -e "\033[33m[!]\033[0m $*"
}

err() {
  echo -e "\033[31m[!]\033[0m $*" >&2
}

# Simple template renderer:
#   render_template template_path dest_path VAR1 VAR2 ...
#   Replaces {{VAR1}}, {{VAR2}} with values from environment.
render_template() {
  local template="$1"
  local dest="$2"
  shift 2
  local vars=("$@")

  if [[ ! -f "$template" ]]; then
    err "Template not found: $template"
    exit 1
  fi

  local content
  content="$(<"$template")"

  for var in "${vars[@]}"; do
    local value="${!var-}"
    content="${content//\{\{$var\}\}/$value}"
  done

  printf '%s\n' "$content" > "$dest"
}
