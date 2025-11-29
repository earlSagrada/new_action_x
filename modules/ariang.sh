#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$MODULE_DIR/.." && pwd)"
source "$SCRIPT_DIR/modules/common.sh"

WEBROOT="${WEBROOT:-/var/www/${DOMAIN:-example.com}/html}"
ARIANG_DIR="${ARIANG_DIR:-/usr/share/ariang}"

install_ariang_component() {
  log "Installing latest AriaNg..."

  # jq for GitHub API
  if ! command -v jq >/dev/null 2>&1; then
    log "Installing jq..."
    apt-get update -y
    apt-get install -y jq
  fi

  mkdir -p "$ARIANG_DIR"

  local api_url="https://api.github.com/repos/mayswind/AriaNg/releases/latest"
  local latest_tag
  latest_tag="$(curl -fsSL "$api_url" | jq -r '.tag_name')"

  if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
    err "Failed to detect latest AriaNg version from GitHub."
    exit 1
  fi

  log "Latest AriaNg release: ${latest_tag}"

  local zip_url="https://github.com/mayswind/AriaNg/releases/download/${latest_tag}/AriaNg-${latest_tag#v}.zip"
  if ! curl -I -fsSL "$zip_url" >/dev/null 2>&1; then
    zip_url="https://github.com/mayswind/AriaNg/releases/download/${latest_tag}/AriaNg.zip"
  fi

  local tmp_zip="/tmp/AriaNg.zip"
  rm -f "$tmp_zip"
  curl -fLo "$tmp_zip" "$zip_url"

  rm -rf "${ARIANG_DIR:?}"/*
  unzip -q "$tmp_zip" -d "$ARIANG_DIR"
  rm -f "$tmp_zip"

  log "AriaNg extracted to ${ARIANG_DIR}."

  # Add a small, safe defaults script so clean browsers use same-origin + /jsonrpc
  # (Option 1) — do NOT inject rpc-secret; this keeps the secret safe.
  local defaults_js="$ARIANG_DIR/aria-defaults.js"
  cat > "$defaults_js" <<'EOF'
// AriaNg safe defaults injector (installed by new_action_x)
// - Sets same-origin host, forces HTTPS where applicable, clears port to use default
// - Sets the default path to /jsonrpc
// This script only auto-fills the settings UI on first visit and does NOT store secrets.
(function(){
  function applyDefaults() {
    try {
      var host = window.location.hostname || '';
      var protocol = (/https:/i.test(window.location.protocol)) ? 'https' : 'http';

      // Small delay: AriaNg SPA loads elements asynchronously, so try to run after UI mounts
      setTimeout(function() {
        // Find likely host input fields and set value if empty
        var inputs = Array.from(document.querySelectorAll('input'));
        // Host/address-like inputs
        var hostInput = inputs.find(function(i){
          var p = (i.placeholder||'') + ' ' + (i.getAttribute('aria-label')||'') + ' ' + (i.name||'');
          return /host|address/i.test(p) && i.offsetParent !== null;
        });
        if(hostInput && (!hostInput.value || hostInput.value.indexOf(':')>=0 && hostInput.value.indexOf('6800')>=0)){
          hostInput.value = host;
          hostInput.dispatchEvent(new Event('input',{bubbles:true}));
        }

        // Path-like inputs
        var pathInput = inputs.find(function(i){
          var p = (i.placeholder||'') + ' ' + (i.getAttribute('aria-label')||'') + ' ' + (i.name||'');
          return /path|jsonrpc/i.test(p) && i.offsetParent !== null;
        });
        if(pathInput && !pathInput.value){
          pathInput.value = '/jsonrpc';
          pathInput.dispatchEvent(new Event('input',{bubbles:true}));
        }

        // Port inputs: clear to use default
        var portInput = inputs.find(function(i){
          var p = (i.placeholder||'') + ' ' + (i.getAttribute('aria-label')||'') + ' ' + (i.name||'');
          return /port/i.test(p) && i.offsetParent !== null;
        });
        if(portInput && (portInput.value === '6800' || portInput.value)){
          portInput.value = '';
          portInput.dispatchEvent(new Event('input',{bubbles:true}));
        }

        // Protocol select: prefer HTTPS if available
        var selects = Array.from(document.querySelectorAll('select'));
        var protoSelect = selects.find(function(s){
          var l = (s.getAttribute('aria-label')||'') + ' ' + (s.name||'');
          return /protocol/i.test(l);
        });
        if(protoSelect){
          for(var oi=0; oi<protoSelect.options.length; oi++){
            var opt = protoSelect.options[oi];
            if(/https/i.test(opt.value||opt.text)){
              protoSelect.value = opt.value;
              protoSelect.dispatchEvent(new Event('change',{bubbles:true}));
              break;
            }
          }
        }

      }, 200);
    } catch (e) {
      // no-op: best-effort only
      console.debug('aria-defaults injector error', e);
    }
  }

  // Run on DOMContentLoaded and also try later if SPA hasn't mounted yet
  if(document.readyState === 'loading'){
    document.addEventListener('DOMContentLoaded', applyDefaults);
  } else {
    applyDefaults();
  }
  // Also attempt again after a short interval to cover SPA mount timing
  setTimeout(applyDefaults, 1000);
})();
EOF

  # Inject script tag into index.html if not present (idempotent)
  local index_html="$ARIANG_DIR/index.html"
  if [[ -f "$index_html" ]]; then
    if ! grep -q "aria-defaults.js" "$index_html" 2>/dev/null; then
      # Insert before closing </body>
      awk 'BEGIN{added=0} /<\/body>/{ if(!added){ print "    <script src=\"/ariang/aria-defaults.js\"></script>"; added=1 } } {print}' "$index_html" > "$index_html.tmp" && mv "$index_html.tmp" "$index_html"
      log "Injected aria-defaults.js into index.html"
    fi
  fi

  # nginx alias for /ariang
  local nginx_alias="/etc/nginx/snippets/ariang.conf"
  cat > "$nginx_alias" <<EOF
location /ariang {
    alias ${ARIANG_DIR}/;
    index index.html;
}
EOF

  log "Created nginx alias configuration: $nginx_alias"
  log "Reloading nginx..."
  nginx -t
  systemctl reload nginx

  log "AriaNg installation completed."
}

install_ariang_component "$@"
