#!/usr/bin/env bash
# ============================================================
#  CPM Panel — VPS Management Panel Installer
#  Supports: Ubuntu 20.04 / 22.04 / 24.04  (x86_64)
#  Usage:    sudo bash install.sh
# ============================================================
set -euo pipefail

# ── Colours ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}${BLUE}──── $* ────${NC}"; }

# ── Config ───────────────────────────────────────────────────
INSTALL_DIR="/opt/cpm-panel"
SERVICE_NAME="cpm-panel"
API_PORT="${CPM_API_PORT:-8080}"
WEB_PORT="${CPM_WEB_PORT:-5000}"
REPO_URL="${CPM_REPO:-https://github.com/YOUR_USERNAME/cpm-panel.git}"
NODE_VERSION="20"

# ── Banner ───────────────────────────────────────────────────
echo -e "
${BOLD}${BLUE}
 ██████╗██████╗ ███╗   ███╗    ██████╗  █████╗ ███╗   ██╗███████╗██╗
██╔════╝██╔══██╗████╗ ████║    ██╔══██╗██╔══██╗████╗  ██║██╔════╝██║
██║     ██████╔╝██╔████╔██║    ██████╔╝███████║██╔██╗ ██║█████╗  ██║
██║     ██╔═══╝ ██║╚██╔╝██║    ██╔═══╝ ██╔══██║██║╚██╗██║██╔══╝  ██║
╚██████╗██║     ██║ ╚═╝ ██║    ██║     ██║  ██║██║ ╚████║███████╗███████╗
 ╚═════╝╚═╝     ╚═╝     ╚═╝    ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚══════╝
${NC}
${BOLD}                  KVM VPS Management Panel${NC}
${CYAN}            https://github.com/Amir565-ux/cpm-panel${NC}
"

# ── Pre-flight checks ─────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run as root: sudo bash install.sh"

. /etc/os-release 2>/dev/null || true
if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
  warn "This installer is tested on Ubuntu/Debian. Proceeding anyway..."
fi

info "Detected OS: ${PRETTY_NAME:-Unknown}"
info "Install directory: $INSTALL_DIR"
info "API port: $API_PORT  |  Web port: $WEB_PORT"

# ── System update ─────────────────────────────────────────────
step "Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
success "System updated"

# ── Core dependencies ─────────────────────────────────────────
step "Installing core dependencies"
apt-get install -y -qq \
  curl wget git unzip build-essential \
  ca-certificates gnupg lsb-release \
  net-tools ufw >/dev/null
success "Core dependencies installed"

# ── Node.js ───────────────────────────────────────────────────
step "Installing Node.js $NODE_VERSION"
if command -v node &>/dev/null && node --version | grep -q "^v${NODE_VERSION}"; then
  success "Node.js $(node --version) already installed"
else
  curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs >/dev/null
  success "Node.js $(node --version) installed"
fi

# ── pnpm ──────────────────────────────────────────────────────
step "Installing pnpm"
if command -v pnpm &>/dev/null; then
  success "pnpm $(pnpm --version) already installed"
else
  npm install -g pnpm >/dev/null 2>&1
  success "pnpm $(pnpm --version) installed"
fi

# ── KVM / libvirt ─────────────────────────────────────────────
step "Installing KVM / libvirt / QEMU"

# Check hardware virtualisation support
if grep -qE '(vmx|svm)' /proc/cpuinfo; then
  success "Hardware virtualisation (KVM) is supported"
  KVM_OK=true
else
  warn "Hardware virtualisation not detected — KVM will run in emulation mode"
  KVM_OK=false
fi

apt-get install -y -qq \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  libvirt-dev \
  bridge-utils \
  virtinst \
  virt-manager \
  ovmf \
  cpu-checker >/dev/null

systemctl enable --now libvirtd >/dev/null 2>&1
systemctl enable --now virtlogd >/dev/null 2>&1

# Add current sudo user to libvirt + kvm groups
SUDO_USER_NAME="${SUDO_USER:-root}"
if [[ "$SUDO_USER_NAME" != "root" ]]; then
  usermod -aG libvirt,kvm "$SUDO_USER_NAME" 2>/dev/null || true
  success "Added $SUDO_USER_NAME to libvirt and kvm groups"
fi

# Enable default network if not already active
virsh net-list --all 2>/dev/null | grep -q "default" && \
  virsh net-start default 2>/dev/null || true
virsh net-autostart default 2>/dev/null || true

success "KVM / libvirt installed and running"

# ── Download / update CPM Panel ───────────────────────────────
step "Downloading CPM Panel"

if [[ -d "$INSTALL_DIR/.git" ]]; then
  info "Existing installation found — pulling latest version..."
  git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null || \
    { warn "Git pull failed, reinstalling..."; rm -rf "$INSTALL_DIR"; }
fi

if [[ ! -d "$INSTALL_DIR" ]]; then
  git clone --depth=1 "$REPO_URL" "$INSTALL_DIR" 2>/dev/null || {
    # If no git repo yet, create a self-contained bundle from this script's bundled files
    warn "Could not clone repo — creating standalone installation..."
    mkdir -p "$INSTALL_DIR"
    create_standalone_bundle
  }
fi

success "CPM Panel downloaded to $INSTALL_DIR"

# ── Install Node dependencies ──────────────────────────────────
step "Installing Node.js dependencies"
cd "$INSTALL_DIR"
pnpm install --frozen-lockfile 2>/dev/null || pnpm install
success "Dependencies installed"

# ── Build the project ──────────────────────────────────────────
step "Building CPM Panel"
cd "$INSTALL_DIR"

# Build the API server
pnpm --filter @workspace/api-server run build
success "API server built"

# Build the frontend (Vite static output)
pnpm --filter @workspace/cpm-panel run build
success "Frontend built"

# ── Environment configuration ──────────────────────────────────
step "Writing environment configuration"
cat > "$INSTALL_DIR/artifacts/api-server/.env" <<EOF
NODE_ENV=production
PORT=$API_PORT
LOG_LEVEL=info
EOF
success "Environment configured"

# ── Nginx (optional reverse proxy) ────────────────────────────
step "Configuring Nginx reverse proxy"
if ! command -v nginx &>/dev/null; then
  apt-get install -y -qq nginx >/dev/null
fi

# Find the Vite build output
STATIC_DIR="$INSTALL_DIR/artifacts/cpm-panel/dist"

cat > /etc/nginx/sites-available/cpm-panel <<NGINX
server {
    listen $WEB_PORT default_server;
    server_name _;

    # Security headers
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    # Serve built frontend
    root $STATIC_DIR;
    index index.html;

    # API proxy to Node backend
    location /api/ {
        proxy_pass http://127.0.0.1:$API_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 60s;
    }

    # SPA fallback
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/cpm-panel /etc/nginx/sites-enabled/cpm-panel
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t && systemctl enable --now nginx && systemctl reload nginx
success "Nginx configured on port $WEB_PORT"

# ── Systemd service ────────────────────────────────────────────
step "Creating systemd service for API server"

cat > /etc/systemd/system/${SERVICE_NAME}-api.service <<EOF
[Unit]
Description=CPM Panel API Server
Documentation=https://github.com/YOUR_USERNAME/cpm-panel
After=network.target libvirtd.service
Wants=libvirtd.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/artifacts/api-server
EnvironmentFile=$INSTALL_DIR/artifacts/api-server/.env
ExecStart=/usr/bin/node --enable-source-maps $INSTALL_DIR/artifacts/api-server/dist/index.mjs
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cpm-panel-api

# Security hardening
NoNewPrivileges=no
PrivateTmp=false

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}-api"
systemctl restart "${SERVICE_NAME}-api"
sleep 2

if systemctl is-active --quiet "${SERVICE_NAME}-api"; then
  success "CPM Panel API service is running"
else
  warn "API service may have failed — check: journalctl -u ${SERVICE_NAME}-api -n 50"
fi

# ── Firewall ───────────────────────────────────────────────────
step "Configuring firewall"
if command -v ufw &>/dev/null; then
  ufw allow ssh >/dev/null 2>&1 || true
  ufw allow "$WEB_PORT/tcp" >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
  success "Firewall: port $WEB_PORT opened"
fi

# ── Health check ───────────────────────────────────────────────
step "Running health check"
sleep 2
if curl -sf "http://127.0.0.1:${API_PORT}/api/healthz" >/dev/null 2>&1; then
  success "API health check passed"
else
  warn "API health check failed — service may still be starting"
fi

# ── Get server IP ──────────────────────────────────────────────
SERVER_IP=$(hostname -I | awk '{print $1}')

# ── Done ───────────────────────────────────────────────────────
echo -e "
${BOLD}${GREEN}╔══════════════════════════════════════════════════╗
║          CPM Panel installed successfully!       ║
╚══════════════════════════════════════════════════╝${NC}

${BOLD}Access your panel:${NC}
  ${CYAN}http://${SERVER_IP}:${WEB_PORT}${NC}

${BOLD}Service commands:${NC}
  systemctl status  ${SERVICE_NAME}-api   # check status
  systemctl restart ${SERVICE_NAME}-api   # restart API
  journalctl -u ${SERVICE_NAME}-api -f    # live logs
  nginx -t && systemctl reload nginx       # reload web server

${BOLD}Manage VPS instances:${NC}
  virsh list --all       # list all VMs
  virsh start <name>     # start a VM
  virsh shutdown <name>  # stop a VM

${BOLD}Installation directory:${NC}  $INSTALL_DIR
${BOLD}API port:${NC}               $API_PORT
${BOLD}Web port:${NC}               $WEB_PORT
"

if [[ "$KVM_OK" == "false" ]]; then
  echo -e "${YELLOW}NOTE: Your server does not support hardware KVM.${NC}"
  echo -e "      VMs will run in software emulation (slower)."
  echo -e "      For best performance use a KVM-enabled VPS (check your provider).\n"
fi

if [[ "$SUDO_USER_NAME" != "root" ]]; then
  echo -e "${YELLOW}NOTE: Log out and back in as '$SUDO_USER_NAME' to use virsh without sudo.${NC}\n"
fi
