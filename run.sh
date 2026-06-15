#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  CPM Panel — Run Script
#  GitHub : https://github.com/Amir565-ux/CPM-Panel
#  Usage  : bash run.sh
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m' B='\033[0;34m' N='\033[0m'
ok()  { echo -e "${G}[OK]${N}  $1"; }
wrn() { echo -e "${Y}[!!]${N}  $1"; }
die() { echo -e "${R}[ERR]${N} $1"; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-5000}"

echo -e "${B}"
cat <<'BANNER'
   ██████╗██████╗ ███╗   ███╗    ██████╗  █████╗ ███╗   ██╗███████╗██╗
  ██╔════╝██╔══██╗████╗ ████║    ██╔══██╗██╔══██╗████╗  ██║██╔════╝██║
  ██║     ██████╔╝██╔████╔██║    ██████╔╝███████║██╔██╗ ██║█████╗  ██║
  ██║     ██╔═══╝ ██║╚██╔╝██║    ██╔═══╝ ██╔══██║██║╚██╗██║██╔══╝  ██║
  ╚██████╗██║     ██║ ╚═╝ ██║    ██║     ██║  ██║██║ ╚████║███████╗███████╗
   ╚═════╝╚═╝     ╚═╝     ╚═╝    ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚══════╝
BANNER
echo -e "${N}"
echo -e "  KVM VPS Management Panel"
echo -e "  Port: ${Y}${PORT}${N}  (set PORT=XXXX to change)\n"

# ── checks ─────────────────────────────────────────────────────────────────────
[[ -f "$DIR/app.py" ]]     || die "app.py not found. Run:  sudo bash install.sh"
[[ -f "$DIR/index.html" ]] || die "index.html not found. Run:  sudo bash install.sh"

# Use venv python if available, otherwise fall back to system python3
if [[ -f "$DIR/venv/bin/python3" ]]; then
  PYTHON="$DIR/venv/bin/python3"
  ok "Using virtualenv python"
else
  command -v python3 &>/dev/null || die "python3 not found. Run:  sudo bash install.sh"
  PYTHON="python3"
  ok "Using system python3"
fi

# ── libvirtd ───────────────────────────────────────────────────────────────────
if command -v virsh &>/dev/null; then
  if command -v systemctl &>/dev/null; then
    systemctl is-active --quiet libvirtd 2>/dev/null \
      || sudo systemctl start libvirtd 2>/dev/null \
      || wrn "Could not start libvirtd — VPS list will show demo data"
  fi
  ok "virsh found — real KVM data will be used"
else
  wrn "virsh not found — running in DEMO mode (mock VPS list)"
  wrn "Install KVM:  sudo bash install.sh"
fi

# ── start ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${G}Starting CPM Panel…${N}"
echo -e "  Browser: ${Y}http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo localhost):${PORT}${N}"
echo -e "  Press ${Y}Ctrl+C${N} to stop.\n"

cd "$DIR"
exec env PORT="$PORT" "$PYTHON" app.py
