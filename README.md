# NEW_ACTION_X

A modular, production-friendly automation toolkit for deploying **Xray + VLESS-Reality**, **Aria2**, **Filebrowser**, Nginx QUIC/HTTP3 configs, and system hardening modules (Fail2ban, systemd services). Everything is controlled via a unified `install.sh` entrypoint.

This README gives you:
- What each module does
- How to install, update, debug
- How to customise configs
- How to run tests for each component

---

## 📦 Project Overview
Your project contains:

```
NEW_ACTION_X/
├── install.sh                 # Main installer entrypoint
├── modules/
│   ├── aria2.sh               # Installs Aria2 RPC + systemd
│   ├── ariang.sh              # Deploys AriaNg static UI
│   ├── fail2ban.sh            # Fail2ban rules + jails
│   ├── filebrowser.sh         # Filebrowser server + config
│   ├── nginx.sh               # Nginx + QUIC/HTTP3 configs
│   └── xray.sh                # Xray core + VLESS-Reality inbound
└── config/
    ├── nginx/
    ├── systemd/
    ├── aria2.conf.template
    └── filebrowser.json.template
```

Everything is designed to set up a fully working VPS with:
- HTTP/3 & QUIC support
- Aria2 RPC + AriaNg UI
- Filebrowser file manager
- Xray VLESS-Reality on UDP/443
- Fail2ban IP banning
- Auto-generated client configs and QR codes

---

## 🚀 Quick Installation
Run this on a **fresh Ubuntu server**:


```bash
curl -O https://raw.githubusercontent.com/earlSagrada/new_action_x/main/install.sh
chmod +x install.sh
sudo ./install.sh
```


If you do **not** pass `--domain` or `--email`, the installer will ask you interactively.


### Common command examples


**Interactive menu:**
```bash
sudo ./install.sh
```


**Full install (QUIC Nginx + Aria2 + AriaNg + Filebrowser + Fail2ban + Xray):**
```bash
sudo ./install.sh --full --domain example.com --email admin@example.com
```


**Xray-only:**
```bash
sudo ./install.sh --xray --domain example.com --email admin@example.com
```


**Update all components (keeps Xray keys, regenerates QR only):**
```bash
sudo ./install.sh --update --domain example.com --email admin@example.com
```


**Update all components except Xray:**
```bash
sudo ./install.sh --update-no-xray --domain example.com --email admin@example.com
```


**Debug mode:**
```bash
sudo bash -x ./install.sh --full --domain example.com --email admin@example.com
```

---

## ⚙️ How the Modules Work
### **1. xray.sh** (VLESS + Reality on TCP/443)
- Installs Xray-core
- Generates private key, public key, UUID, and short ID
- Creates VLESS-Reality inbound on **TCP/443** with fallback to port **8443** (Nginx)
- Generates VLESS connection link + QR code stored under `output/xray_reality_qr.png`
- Writes systemd service (`/etc/systemd/system/xray.service`)

### **2. nginx.sh** (QUIC/HTTP/2 with TLS 1.3)
- Installs latest Nginx with HTTP/2 and QUIC support
- Obtains Let's Encrypt certificate via certbot
- Configures **listening on 0.0.0.0:8443** (HTTP/2 + QUIC on all interfaces)
- Redirects HTTP (80) to HTTPS (443)
- Serves as fallback for Xray Reality (receives non-VLESS traffic on port 443)

### **3. aria2.sh + ariang.sh**
- Installs Aria2 daemon with RPC interface on **port 6800**
    - Installer prints the rpc-secret to the console during installation so you can copy it (the secret may change on each run).
- Deploys AriaNg UI (static web UI) via Nginx proxy
- Downloads stored in `/var/www/{DOMAIN}/downloads/`
- Uses RPC secret for authentication

### **4. filebrowser.sh**
- Installs Filebrowser binary
- Runs on **port 8080** (internally) and exposed via Nginx proxy
- Provides file manager access to downloads directory
- Default credentials: admin/admin (change recommended)

### **5. fail2ban.sh**
- Installs Fail2ban with strict jails for security
- **Xray Reality jail**: monitors Xray errors via systemd logs
- **Nginx jail**: monitors HTTP error responses (400/401/403/404)
- Ban policy: **3 failures within 48 hours → 10-day ban**

---

## 🧪 Testing & Debugging
### Check service status
```
systemctl status xray
systemctl status nginx
systemctl status aria2
systemctl status filebrowser
systemctl status fail2ban
```

### Reload services
```
systemctl restart xray
systemctl reload nginx
```

### View Xray logs
```
journalctl -u xray -f
```

### Validate Nginx config
```
nginx -t

### AriaNg common pitfall — wrong connection host/port

If AriaNg reports "disconnected" while aria2 is running and reachable locally, make sure the UI connection uses your public domain + path /jsonrpc (NOT 127.0.0.1:6800). Example AriaNg settings:

- Host: icetea-shinchan.xyz
- Port: (leave blank or 443)
- Secure/TLS: ON
- Path: /jsonrpc
- Token: <your rpc-secret value>

If you put a host value like `icetea-shinchan.xyz:6800` or `127.0.0.1:6800`, AriaNg will sometimes attempt malformed URLs like `/jsonrpc:6800/jsonrpc` and Nginx will return 404. Our Nginx templates include a workaround, but the correct UI setting is to use the domain (or leave the port blank when using HTTPS) and the path `/jsonrpc`.

### ⚠️ AriaNg UI: manual configuration required

We no longer attempt to automatically patch the AriaNg UI during installation (automatic UI edits proved unreliable in some browsers). Instead, the installer prints a clear, post-install reminder so administrators can set the UI connection manually.

How to set a correct connection in AriaNg:

- Open a fresh browser/Incognito and navigate to `https://<your-domain>/ariang/`.
- In AriaNg connection settings set:
    - Host: `<your-domain>`
    - Port: (leave blank or set 443 when using HTTPS)
    - Secure/TLS: ON
    - Path: `/jsonrpc`
    - Token: paste your RPC secret printed during aria2 installation (we do not inject the secret into the UI).

If AriaNg reports "disconnected", clear the site storage (DevTools → Application → Local Storage) or use a fresh browser session and verify the Connection settings are exactly as above.
```

---

## 🔧 Configuration Locations
| Component | Config Path | Listen |
|----------|-------------|--------|
| Xray inbound | `/etc/xray/config.json` | TCP 443 (with fallback to 8443) |
| Xray logs | `/var/log/xray/` | — |
| Xray QR code | `output/xray_reality_qr.png` | — |
| Aria2 daemon | `/etc/aria2/aria2.conf` | TCP 6800 (RPC) |
| AriaNg UI | `/usr/share/ariang/` | Proxied via Nginx |
| Filebrowser | `/etc/filebrowser/filebrowser.json` | TCP 8080 (proxied via Nginx) |
| Nginx QUIC configs | `/etc/nginx/conf.d/` or `/etc/nginx/sites-available/` | TCP/UDP 8443 (all interfaces) |
| Fail2ban jails | `/etc/fail2ban/jail.d/` | — |

---

## 🔑 Regenerate Client QR Code & Keys

### Regenerate QR code only (keep existing keys):
```bash
sudo bash modules/xray.sh --regen
```
This will:
- Read existing UUID, Private Key, Public Key, Short ID from config
- Generate a fresh QR code
- **Does NOT** restart Xray or change any keys

### Regenerate all keys (new UUID, keys, short ID):
```bash
sudo bash modules/xray.sh --regen-keys
```
This will:
- Generate completely new Reality keys
- Update Xray config
- Restart Xray service
- Generate new QR code
- Save public key for future `--regen` use

The QR code PNG is saved to: `output/xray_reality_qr.png`

---

## 🛡️ Fail2ban Rules
Current settings:
- Max retries: **3**
- Time window: **48h**
- Ban time: **10 days**

Your jail is located at:
```
/etc/fail2ban/jail.d/custom.conf
```

View bans:
```
fail2ban-client status sshd
```

---

## 🔄 Updating the Scripts
To pull new updates:

```bash
git pull origin main
sudo ./install.sh --update --domain example.com --email admin@example.com
```

### Update Options

**`--update` (default update mode):**
- Updates nginx, aria2, ariang, filebrowser, fail2ban
- Preserves existing Xray keys (UUID, private/public keys, short ID)
- Regenerates Xray QR code only via `xray.sh --regen`
- Restarts all services

**`--update-no-xray`:**
- Updates all components EXCEPT Xray
- Leaves Xray completely untouched
- Useful when you only want to update other services

**`--full` (full reinstall with new keys):**
- Regenerates all Xray keys (UUID, private/public keys, short ID)
- Reinstalls/updates all other components
- Use this when you want fresh Xray credentials

---

## 📚 Roadmap (Optional Enhancements)
- Add trojan-reality inbound
- Add automatic HTTPS certificates for AriaNg & Filebrowser
- Add GitHub Actions for bash linting
- Add environment profiles (full / lite / xray-only)

---

## 💬 Issues / logs
If something breaks during install, check:
```
/tmp/action_x_install.log
```

---

## Licence
MIT License (feel free to adjust).
