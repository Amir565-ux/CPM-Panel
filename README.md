# CPM Panel — KVM VPS Management System

**A modern web dashboard for managing KVM virtual machines on Linux.**

> **Author:** [Abdullah](https://github.com/Amir565-ux)  
> **Repo:** [github.com/Amir565-ux/CPM-Panel](https://github.com/Amir565-ux/CPM-Panel)

---

## What is this?

CPM Panel is a self-hosted control panel that runs on your Linux VPS.
Open it in any browser and you get:

- **Live system stats** — RAM, CPU, Disk, Network, Uptime
- **VPS Manager** — list, start, stop, restart, delete your KVM virtual machines
- **Create VPS** — deploy new KVM instances from a simple form

### Does it show real stats?

| Stat | Real? |
|---|---|
| RAM / CPU / Disk / Network / Uptime | **Always real** — reads from Linux `/proc` |
| VPS list & actions | **Real when KVM is installed**, demo data otherwise |

---

## Files in this repo

| File | Purpose |
|---|---|
| `install.sh` | One-time setup (installs KVM, Python, creates `app.py` + `index.html`) |
| `run.sh` | Start the panel |
| `README.md` | This file |

> `install.sh` creates two extra files when you run it:
> - `app.py` — Python Flask API server
> - `index.html` — full web UI (no build step needed)

---

## Quick start (on your VPS)

bash
# 1. Clone
```
git clone https://Amir565-ux@github.com/Amir565-ux/CPM-Panel.git
cd CPM-Panel
```

# 2. Install (run once, needs root)
```
sudo bash install.sh
```
# 4. Installing Npm
```
apt install npm
```
# 4. Installing Local Tunnel
```
npm install -g localtunnel
```
# 5. For First Time Runing it On Local Host
```
bash run.sh & lt --port 5000
```
# 6. For Runing From Normal Home dashboard
```
cd CPM-Panel && bash run.sh & lt --port 5000
```

---

## Requirements

- Ubuntu 20.04 / 22.04 / 24.04
- Python 3.10+
- KVM/QEMU (installed automatically by `install.sh`)

---

## Troubleshooting

| Problem | Fix |
|---|---|
| VPS list shows demo data | `systemctl status libvirtd` — start it if stopped |
| Port refused | `sudo ufw allow 5000/tcp` |
| `app.py not found` | Run `sudo bash install.sh` first |
| virsh permission denied | Log out and back in (group change takes effect on re-login) |

---

## Security note

All VM names are validated with `^[a-zA-Z0-9_\-]{1,64}$` before being passed to virsh — no shell injection possible.  
**Recommended:** do not expose port 5000 to the internet without adding a password. The panel has no login page by default.

---

## License

MADE BY ABDULLAH
