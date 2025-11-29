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
// - Sets same-origin host, prefers HTTPS where applicable, clears port to use default
// - Sets the default path to /jsonrpc
// This script auto-fills the settings UI on first visit and does NOT store secrets.
(function(){
  var host = window.location.hostname || '';

  function setField(el, value, eventType){
    try {
      eventType = eventType || 'input';
      el.focus && el.focus();
      el.value = value;
      el.dispatchEvent(new Event(eventType, { bubbles: true }));
    } catch (e) {/* best effort */}
  }

  // Try to patch any JSON config objects in localStorage that look like RPC settings.
  // Helper: recursively replace :6800 occurrences in arbitrary objects/strings
  function walkReplace(obj) {
    try {
      if (obj === null || obj === undefined) return obj;
      if (typeof obj === 'string') {
        // replace common loopback with current hostname and strip bare :6800
        return obj.replace(/127\.0\.0\.1:6800/g, host)
                  .replace(/localhost:6800/g, host)
                  .replace(/:6800(?![0-9])/g, '');
      }
      if (Array.isArray(obj)) return obj.map(walkReplace);
      if (typeof obj === 'object') {
        Object.keys(obj).forEach(function(k){ obj[k] = walkReplace(obj[k]); });
        return obj;
      }
    } catch(e){ /* best effort */ }
    return obj;
  }

  function applyLocalStorageDefaults() {
    try {
      if (!window.localStorage) return;
      for (var i = 0; i < localStorage.length; i++) {
        var key = localStorage.key(i);
        if (!key) continue;
        var raw = localStorage.getItem(key);
        if (!raw) continue;
        // skip obvious tokens / secrets
        if (/token|secret|auth|password/i.test(key)) continue;
        try {
          var obj = JSON.parse(raw);
          if (obj && typeof obj === 'object') {
            var changed = false;
            // check common fields and fallback: run a recursive sanitize pass
            var hostFields = ['host','address','server','rpcHost','rpcAddress'];
            hostFields.forEach(function(f){
              if (f in obj) {
                if (!obj[f] || /:6800/.test(obj[f]) || /127\.0\.0\.1:6800/.test(obj[f])) { obj[f] = host; changed = true; }
              }
            });
            if ('port' in obj && (obj.port === '6800' || obj.port === 6800)) { obj.port = ''; changed = true; }
            if ('path' in obj && (!obj.path || obj.path === '/')) { obj.path = '/jsonrpc'; changed = true; }
            // recursive sanitization of any strings containing :6800
            try {
              var cleaned = walkReplace(obj);
              if (JSON.stringify(cleaned) !== JSON.stringify(obj)) { obj = cleaned; changed = true; }
            } catch(e){ /* best effort */ }

            if (changed) {
              try { localStorage.setItem(key, JSON.stringify(obj)); } catch(e) { /* best effort */ }
            }
          }
        } catch(e) {
          // If value is not JSON but contains :6800 (eg. legacy string), replace it.
          try {
            if (/(:6800|127\.0\.0\.1:6800|localhost:6800)/.test(raw)) {
              var raw2 = raw.replace(/127\.0\.0\.1:6800/g, host).replace(/localhost:6800/g, host).replace(/:6800(?![0-9])/g, '');
              localStorage.setItem(key, raw2);
            }
          } catch(e2){ /* best effort */ }
        }
      }
    } catch(e) { /* ignore */ }
  }

  function applyOnce() {
    try {
      var root = document;

      // Heuristics for various AriaNg versions: find Host/Address/Port/Path fields
      // Look for inputs with name/id/placeholder/aria-label matching keywords
      var inputs = Array.from(root.querySelectorAll('input, textarea'));

      var hostCandidates = inputs.filter(function(i){
        var s = (i.name||'')+' '+(i.id||'')+' '+(i.placeholder||'')+' '+(i.getAttribute('aria-label')||'');
        return /host|address|server|rpc-address|rpc-host/i.test(s);
      });
      var applied = false;
      if(hostCandidates.length){
        // pick first candidate that isn't hidden
        var hi = hostCandidates.find(function(el){ return el.offsetParent !== null && el.type !== 'hidden'; }) || hostCandidates[0];
        // only override if empty or contains ':6800' or is '127.0.0.1:6800'
        if(hi) {
          // If the current value looks like it includes :6800, or is empty, overwrite.
          if(!hi.value || /:6800/.test(hi.value) || /127\.0\.0\.1:6800/.test(hi.value)) {
            setField(hi, host);
            applied = true;
          } else {
            // If the value still contains a port anywhere, try to sanitize it.
            if(/:6800/.test(hi.value)) {
              setField(hi, (hi.value||'').replace(/:6800/g, ''));
              applied = true;
            }
          }
        }
      }

      var pathCandidates = inputs.filter(function(i){
        var s = (i.name||'')+' '+(i.id||'')+' '+(i.placeholder||'')+' '+(i.getAttribute('aria-label')||'');
        return /path|jsonrpc|rpc_path|rpcpath/i.test(s);
      });
      if(pathCandidates.length){
        var pi = pathCandidates.find(function(el){ return el.offsetParent !== null; }) || pathCandidates[0];
        if(pi){
          if(!pi.value || pi.value === '/' || !/jsonrpc/i.test(pi.value)){
            setField(pi, '/jsonrpc');
            applied = true;
          } else if(/:6800/.test(pi.value)) {
            // strip stray :6800 that some malformed UIs store in path fields
            setField(pi, (pi.value||'').replace(/:6800/g, ''));
            applied = true;
          }
        }
      }

      var portCandidates = inputs.filter(function(i){
        var s = (i.name||'')+' '+(i.id||'')+' '+(i.placeholder||'')+' '+(i.getAttribute('aria-label')||'');
        return /port/i.test(s);
      });
      if(portCandidates.length){
        var pti = portCandidates.find(function(el){ return el.offsetParent !== null; }) || portCandidates[0];
        // Clear default 6800 (or any non-empty value) so browser uses default HTTPS port
        if(pti){
          try {
            // Force-clear the port field and also override attribute/defaultValue
            if(pti.value === '6800' || pti.value) {
              setField(pti, '');
              applied = true;
              pti.defaultValue = '';
              pti.setAttribute && pti.setAttribute('value', '');
            }
          } catch(e) { /* best effort */ }
        }
      }

      // Set protocol select if present
      var selects = Array.from(root.querySelectorAll('select'));
      var proto = selects.find(function(s){
        var l = (s.name||'') + ' ' + (s.id||'') + ' ' + (s.getAttribute('aria-label')||'');
        return /protocol/i.test(l);
      });
      if(proto){
        for(var oi=0; oi<proto.options.length; oi++){
          var opt = proto.options[oi];
          if(/https/i.test(opt.value||opt.text)){
            proto.value = opt.value;
            proto.selectedIndex = oi;
            proto.dispatchEvent(new Event('change', { bubbles: true }));
            applied = true;
            break;
          }
        }
      }

      // Return true only if we actually applied a change; otherwise caller should retry
      return applied;
    } catch(e){
      return false;
    }
  }

  // Mutation observer to catch SPA-mounted settings elements
  var observer = new MutationObserver(function(mutations){
    if(applyOnce()){
      // we succeeded applying fields; disconnect
      observer.disconnect();
    }
  });

  function start() {
    // try localStorage defaults first
    try { applyLocalStorageDefaults(); } catch(e) {}
    // try immediately
    if(applyOnce()) return;
    // observe DOM mutations for a while and retry for longer so frameworks that set values
    // asynchronously are still overridden.
    observer.observe(document.documentElement || document.body, { childList: true, subtree: true });
    // fallback retries (extended)
    var tries = 0;
    var id = setInterval(function(){
      tries++;
      try { applyLocalStorageDefaults(); } catch(e){}
      if(applyOnce() || tries > 50) {
        clearInterval(id);
        observer.disconnect();
      }
    }, 250);
  }

  if(document.readyState === 'loading'){
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }

})();
EOF

  # Inject script tag into index.html if not present (idempotent)
  local index_html="$ARIANG_DIR/index.html"
  if [[ -f "$index_html" ]]; then
    if ! grep -q "aria-defaults.js" "$index_html" 2>/dev/null; then
      # Insert as early as possible so our defaults run before AriaNg initializes.
      # Prefer placing inside <head>, otherwise fall back to before </body>.
      if grep -qi "<head" "$index_html"; then
        awk 'BEGIN{added=0} /<\/head>/{ if(!added){ print "    <script src=\"/ariang/aria-defaults.js\"></script>"; added=1 } } {print}' "$index_html" > "$index_html.tmp" && mv "$index_html.tmp" "$index_html"
      else
        awk 'BEGIN{added=0} /<\/body>/{ if(!added){ print "    <script src=\"/ariang/aria-defaults.js\"></script>"; added=1 } } {print}' "$index_html" > "$index_html.tmp" && mv "$index_html.tmp" "$index_html"
      fi
      log "Injected aria-defaults.js into index.html"
      # Also add a very small inline sanitizer so the browser runs a simple localStorage/port-clean pass
      # as early as possible (helps with some SPA load orders / caching).
      if ! grep -q "aria-defaults-inline" "$index_html" 2>/dev/null; then
        local tmpfile="$index_html.tmp2"
        if grep -qi "<head" "$index_html"; then
          awk 'BEGIN{added=0} /<\/head>/{ if(!added){ print "    <script id=\"aria-defaults-inline\">(function(){try{var h=location.hostname||''; for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i); if(!k) continue; try{ var v=localStorage.getItem(k); if(/(:6800|127\\.0\\.0\\.1:6800|localhost:6800)/.test(v) && !/token|secret|auth|password/i.test(k)){ localStorage.setItem(k, v.replace(/127\\.0\\.0\\.1:6800/g,h).replace(/localhost:6800/g,h).replace(/:6800(?![0-9])/g,'')); } }catch(e){} } }catch(e){} })();</script>"; added=1 } } {print}' "$index_html" > "$tmpfile" && mv "$tmpfile" "$index_html"
        else
          awk 'BEGIN{added=0} /<\/body>/{ if(!added){ print "    <script id=\"aria-defaults-inline\">(function(){try{var h=location.hostname||''; for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i); if(!k) continue; try{ var v=localStorage.getItem(k); if(/(:6800|127\\.0\\.0\\.1:6800|localhost:6800)/.test(v) && !/token|secret|auth|password/i.test(k)){ localStorage.setItem(k, v.replace(/127\\.0\\.0\\.1:6800/g,h).replace(/localhost:6800/g,h).replace(/:6800(?![0-9])/g,'')); } }catch(e){} } }catch(e){} })();</script>"; added=1 } } {print}' "$index_html" > "$tmpfile" && mv "$tmpfile" "$index_html"
        fi
        log "Injected inline aria-defaults sanitizer into index.html"
      fi
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
