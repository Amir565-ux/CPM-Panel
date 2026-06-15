# CPM Panel — KVM VPS Management System

A modern, production-ready VPS management dashboard for Linux servers running KVM/libvirt.

**Live panel features:**
- Real-time RAM and Disk usage arc meters
- Live CPU %, uptime, hostname, and VPS count
- Full VPS lifecycle control (start / stop / restart / delete / create)
- Virsh-powered backend with demo mode when KVM is unavailable

---

## One-Command Install (Ubuntu 20.04 / 22.04 / 24.04)

```bash
curl -fsSL https://raw.githubusercontent.com/Amir565-ux/cpm-panel/main/install.sh | sudo bash
```

Or download and inspect first (recommended):

```bash
wget https://raw.githubusercontent.com/YOUR_USERNAME/cpm-panel/main/install.sh
chmod +x install.sh
sudo bash install.sh
```

After install, open: **`http://YOUR_SERVER_IP:5000`**

---

## What the installer does

| Step | Action |
|------|--------|
| 1 | Updates system packages |
| 2 | Installs Node.js 20 LTS + pnpm |
| 3 | Installs KVM, QEMU, libvirt, bridge-utils, virtinst |
| 4 | Downloads CPM Panel and builds it |
| 5 | Configures Nginx as a reverse proxy on port 5000 |
| 6 | Creates a `systemd` service (`cpm-panel-api`) that auto-starts on boot |
| 7 | Opens firewall port 5000 |

---

## Manual / Development Setup

### Requirements
- Ubuntu 20.04+ or Debian 11+
- Node.js 20+ and pnpm 9+
- KVM-capable server (optional — demo mode works without it)

### Steps

```bash
# 1. Clone
git clone https://github.com/YOUR_USERNAME/cpm-panel.git
cd cpm-panel

# 2. Install dependencies
pnpm install

# 3. Start in development mode (API + frontend dev servers)
pnpm --filter @workspace/api-server run dev &
pnpm --filter @workspace/cpm-panel run dev

# Open: http://localhost:5173
```

---

## Service Management

```bash
# Check API status
systemctl status cpm-panel-api

# View live logs
journalctl -u cpm-panel-api -f

# Restart
systemctl restart cpm-panel-api

# Stop
systemctl stop cpm-panel-api
```

---

## KVM Commands (manual)

```bash
virsh list --all          # list all VMs
virsh start myvm          # start a VM
virsh shutdown myvm       # graceful stop
virsh destroy myvm        # force stop
virsh undefine myvm       # delete definition
virsh dominfo myvm        # VM details
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CPM_API_PORT` | `8080` | Internal API server port |
| `CPM_WEB_PORT` | `5000` | Public web panel port |
| `CPM_REPO` | GitHub URL | Repo to clone during install |

Example custom install:

```bash
CPM_WEB_PORT=80 CPM_API_PORT=3001 sudo bash install.sh
```

---

## Stack

| Layer | Technology |
|-------|-----------|
| Frontend | React 18, Vite, Tailwind CSS, shadcn/ui |
| Backend | Node.js 20, Express 5, TypeScript |
| System stats | Node.js `os` module + `df` |
| KVM control | `virsh` (libvirt) via `child_process` |
| API contract | OpenAPI 3.1 + Orval codegen |
| Process manager | systemd |
| Web server | Nginx |

---

## Project Structure

```
cpm-panel/
├── artifacts/
│   ├── api-server/          # Express REST API
│   │   └── src/routes/
│   │       ├── system.ts    # CPU / RAM / disk stats
│   │       └── vps.ts       # virsh KVM control
│   └── cpm-panel/           # React frontend (Vite)
│       └── src/
│           ├── pages/
│           │   ├── dashboard.tsx
│           │   └── vps.tsx
│           └── components/
│               └── meter.tsx  # SVG arc meters
├── lib/
│   ├── api-spec/            # OpenAPI contract
│   ├── api-client-react/    # Generated React Query hooks
│   └── api-zod/             # Generated Zod validators
├── install.sh               # One-command VPS installer
├── run.sh                   # Manual start script
└── README.md
```

---

## Security Notes

- VPS names are validated (alphanumeric, hyphens, underscores, dots only — max 64 chars)
- All virsh commands are invoked with explicit arguments, no shell interpolation
- The API runs on localhost only; Nginx proxies public traffic
- Add authentication before exposing to the public internet (planned feature)

---

## Roadmap

- [ ] Login system (admin / user roles)
- [ ] VPS console via WebSocket (xterm.js)
- [ ] Snapshot and backup management
- [ ] Multi-node cluster support
- [ ] Billing / reseller API
- [ ] Email alerts on VPS state changes
