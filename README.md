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

During install you can choose:
- **Xray only**
- **Full suite (Nginx + Aria2 + Filebrowser + Fail2ban + Xray)**

---

## ⚙️ How the Modules Work
### **1. xray.sh** (VLESS + Reality on UDP/443)
- Installs Xray-core
- Generates private key, public key, short id
- Creates VLESS-Reality inbound
- Writes systemd service
- Generates **client config + QR code** stored under `/etc/xray/client/`

### **2. nginx.sh** (QUIC/HTTP3)
- Installs latest Nginx
- Enables `quic`, `http3`, `tlsv1.3`
- Configures reverse proxy structure

### **3. aria2.sh + ariang.sh**
- Deploys Aria2 daemon + RPC interface
- Deploys AriaNg UI via Nginx
- Uses your `aria2.conf.template`

### **4. filebrowser.sh**
- Deploys Filebrowser binary
- Uses your template config and sets up a systemd service

### **5. fail2ban.sh**
- Installs Fail2ban
- Adds a strict jail:
    - Ban IP for **10 days**
    - Trigger if 3 failures within **48 hours**

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
```

---

## 🔧 Configuration Locations
| Component | Config Path |
|----------|-------------|
| Xray inbound | `/etc/xray/config.json` |
| Xray client configs | `/etc/xray/client/` |
| Aria2 core | `/etc/aria2/aria2.conf` |
| AriaNg UI | `/usr/share/ariang/` |
| Filebrowser | `/etc/filebrowser/filebrowser.json` |
| Nginx QUIC configs | `/etc/nginx/conf.d/` |
| Fail2ban jail | `/etc/fail2ban/jail.local` |

---

## 🔑 Regenerate Client QR Code
You can re-run just the Xray module:

```bash
sudo bash modules/xray.sh --regen
```

It will:
- Read existing keys
- Recreate client.json
- Produce a fresh QR code

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
sudo ./install.sh --update
```

The update mode will:
- Reapply updated configs
- Restart services
- Preserve existing keys and settings

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
