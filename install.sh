#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  CPM Panel — One-Shot Installer
#  GitHub : https://github.com/Amir565-ux/CPM-Panel
#  Usage  : sudo bash install.sh
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m' N='\033[0m'
ok()  { echo -e "${G}[OK]${N}  $1"; }
inf() { echo -e "${B}[..]${N}  $1"; }
wrn() { echo -e "${Y}[!!]${N}  $1"; }
die() { echo -e "${R}[ERR]${N} $1"; exit 1; }
sep() { echo -e "\n${B}────────────────────────────────────────────${N}  $1\n"; }

[[ $EUID -eq 0 ]] || die "Run as root:  sudo bash install.sh"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${B}"
cat <<'BANNER'
   ██████╗██████╗ ███╗   ███╗    ██████╗  █████╗ ███╗   ██╗███████╗██╗
  ██╔════╝██╔══██╗████╗ ████║    ██╔══██╗██╔══██╗████╗  ██║██╔════╝██║
  ██║     ██████╔╝██╔████╔██║    ██████╔╝███████║██╔██╗ ██║█████╗  ██║
  ██║     ██╔═══╝ ██║╚██╔╝██║    ██╔═══╝ ██╔══██║██║╚██╗██║██╔══╝  ██║
  ╚██████╗██║     ██║ ╚═╝ ██║    ██║     ██║  ██║██║ ╚████║███████╗███████╗
   ╚═════╝╚═╝     ╚═╝     ╚═╝    ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚══════╝
BANNER
echo -e "${N}  KVM VPS Management Panel — Installer\n"

# ─── 1. System packages ───────────────────────────────────────────────────────
sep "1/4  System packages"
apt-get update -y
apt-get install -y python3 python3-pip python3-venv python3-full curl
# Try installing Flask via apt (most reliable — no pip conflicts)
apt-get install -y python3-flask python3-psutil 2>/dev/null || true

# ─── 2. KVM / libvirt ─────────────────────────────────────────────────────────
sep "2/4  KVM / QEMU / libvirt"
grep -qE 'vmx|svm' /proc/cpuinfo || wrn "Hardware virtualisation not detected — KVM installs but VMs may not start"
apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst cpu-checker
systemctl enable --now libvirtd
[[ -n "${SUDO_USER:-}" ]] && { usermod -aG libvirt "$SUDO_USER"; usermod -aG kvm "$SUDO_USER"; ok "Added $SUDO_USER to libvirt + kvm groups"; }
ok "KVM stack installed"

# ─── 3. Write app.py ──────────────────────────────────────────────────────────
sep "3/4  Writing backend (app.py) and frontend (index.html)"

cat > "$DIR/app.py" << 'PYEOF'
"""
CPM Panel — Flask backend
GitHub: https://github.com/Amir565-ux/CPM-Panel
"""
import os, re, shutil, subprocess, logging, select, threading
from flask import Flask, jsonify, request, send_file

try:
    from flask_cors import CORS
    HAS_CORS = True
except ImportError:
    HAS_CORS = False

try:
    import psutil
    HAS_PSUTIL = True
except ImportError:
    HAS_PSUTIL = False

try:
    from flask_sock import Sock
    HAS_SOCK = True
except ImportError:
    HAS_SOCK = False

app = Flask(__name__)
if HAS_CORS:
    CORS(app)
if HAS_SOCK:
    sock = Sock(app)

@app.after_request
def add_cors(r):
    r.headers["Access-Control-Allow-Origin"]  = "*"
    r.headers["Access-Control-Allow-Headers"] = "Content-Type"
    r.headers["Access-Control-Allow-Methods"] = "GET,POST,OPTIONS"
    return r

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

VM_RE = re.compile(r'^[a-zA-Z0-9_\-]{1,64}$')


# ── helpers ───────────────────────────────────────────────────────────────────

def virsh_ok():
    return shutil.which("virsh") is not None

def run_virsh(*args, timeout=15):
    try:
        r = subprocess.run(["virsh"] + list(args), capture_output=True, text=True, timeout=timeout)
        return {"success": r.returncode == 0, "output": r.stdout.strip(), "error": r.stderr.strip()}
    except Exception as e:
        return {"success": False, "output": "", "error": str(e)}

def vm_state(s):
    s = s.lower()
    if "running" in s:   return "running"
    if "shut off" in s or "shutoff" in s: return "stopped"
    if "paused" in s:    return "paused"
    if "crashed" in s:   return "crashed"
    return "unknown"

def cpu_model():
    try:
        for line in open("/proc/cpuinfo"):
            if line.startswith("model name"):
                return line.split(":", 1)[1].strip()
    except Exception:
        pass
    return "Unknown CPU"

def uptime():
    try:
        return float(open("/proc/uptime").read().split()[0])
    except Exception:
        return 0.0

def mem_stats():
    if HAS_PSUTIL:
        m = psutil.virtual_memory()
        return {"used": m.used, "free": m.available, "total": m.total, "percent": m.percent}
    try:
        info = {}
        for line in open("/proc/meminfo"):
            k, v = line.split(":", 1)
            info[k.strip()] = int(v.strip().split()[0]) * 1024
        total = info.get("MemTotal", 0)
        free  = info.get("MemAvailable", info.get("MemFree", 0))
        used  = total - free
        return {"used": used, "free": free, "total": total,
                "percent": round(used / total * 100) if total else 0}
    except Exception:
        return {"used": 0, "free": 0, "total": 0, "percent": 0}

def disk_stats():
    if HAS_PSUTIL:
        d = psutil.disk_usage("/")
        return {"used": d.used, "free": d.free, "total": d.total, "percent": d.percent}
    try:
        r = subprocess.run(["df", "-B1", "/"], capture_output=True, text=True, timeout=5)
        p = r.stdout.strip().splitlines()[-1].split()
        total, used, free = int(p[1]), int(p[2]), int(p[3])
        return {"used": used, "free": free, "total": total,
                "percent": round(used / total * 100) if total else 0}
    except Exception:
        return {"used": 0, "free": 0, "total": 0, "percent": 0}

def cpu_percent():
    if HAS_PSUTIL:
        return psutil.cpu_percent(interval=0.5)
    try:
        r = subprocess.run(
            ["awk", "/^cpu /{u=($2+$4)*100/($2+$3+$4+$5); printf \"%.1f\",u}", "/proc/stat"],
            capture_output=True, text=True, timeout=3)
        return float(r.stdout.strip() or 0)
    except Exception:
        return 0.0

def net_stats():
    if HAS_PSUTIL:
        n = psutil.net_io_counters()
        iface = next((k for k, s in psutil.net_if_stats().items() if k != "lo" and s.isup), "eth0")
        return {"bytesSent": n.bytes_sent, "bytesRecv": n.bytes_recv, "interface": iface}
    try:
        for line in open("/proc/net/dev"):
            parts = line.strip().split()
            if not parts or parts[0].endswith(":") is False: continue
            iface = parts[0].rstrip(":")
            if iface == "lo": continue
            return {"bytesRecv": int(parts[1]), "bytesSent": int(parts[9]), "interface": iface}
    except Exception:
        pass
    return {"bytesSent": 0, "bytesRecv": 0, "interface": "unknown"}

def mock_vps():
    return [
        {"id": "1", "name": "web-server-01", "state": "running", "vcpus": 2, "memory": 2048},
        {"id": "2", "name": "db-server-01",  "state": "stopped", "vcpus": 4, "memory": 4096},
        {"id": "3", "name": "dev-sandbox",   "state": "paused",  "vcpus": 1, "memory": 1024},
    ]

def list_vms():
    if not virsh_ok():
        return mock_vps()
    r = run_virsh("list", "--all", timeout=10)
    if not r["success"]:
        return []
    vms = []
    for line in r["output"].splitlines()[2:]:
        parts = line.split(None, 2)
        if len(parts) < 3: continue
        name = parts[1]
        vcpus = memory = None
        info = run_virsh("dominfo", name, timeout=5)
        if info["success"]:
            cm = re.search(r"CPU\(s\):\s+(\d+)", info["output"])
            mm = re.search(r"Max memory:\s+(\d+)\s+KiB", info["output"])
            if cm: vcpus  = int(cm.group(1))
            if mm: memory = round(int(mm.group(1)) / 1024)
        vms.append({"id": parts[0], "name": name, "state": vm_state(parts[2]),
                    "vcpus": vcpus, "memory": memory})
    return vms


# ── routes ────────────────────────────────────────────────────────────────────

@app.route("/")
def index():
    here = os.path.dirname(os.path.abspath(__file__))
    return send_file(os.path.join(here, "index.html"))

@app.route("/api/healthz")
def healthz():
    return jsonify({"status": "ok"})

@app.route("/api/system")
def system_stats():
    return jsonify({
        "ram":     mem_stats(),
        "cpu":     {"percent": cpu_percent(), "cores": os.cpu_count() or 1, "model": cpu_model()},
        "disk":    disk_stats(),
        "network": net_stats(),
        "uptime":  uptime(),
    })

@app.route("/api/vps/list")
def vps_list():
    return jsonify({"vps": list_vms()})

def _action(req, virsh_cmd):
    data = req.get_json() or {}
    name = data.get("name", "")
    if not VM_RE.match(name):
        return jsonify({"error": "Invalid VM name"}), 400
    if not virsh_ok():
        return jsonify({"success": True, "message": f"[DEMO] {virsh_cmd} {name}"})
    r = run_virsh(virsh_cmd, name)
    if r["success"]:
        return jsonify({"success": True, "message": f"VPS '{name}' — {virsh_cmd} OK"})
    return jsonify({"error": r["error"]}), 400

@app.route("/api/vps/start",   methods=["POST"]) 
def start():   return _action(request, "start")

@app.route("/api/vps/stop",    methods=["POST"])
def stop():    return _action(request, "shutdown")

@app.route("/api/vps/restart", methods=["POST"])
def restart(): return _action(request, "reboot")

@app.route("/api/vps/delete",  methods=["POST"])
def delete():
    data = request.get_json() or {}
    name = data.get("name", "")
    if not VM_RE.match(name):
        return jsonify({"error": "Invalid VM name"}), 400
    if not virsh_ok():
        return jsonify({"success": True, "message": f"[DEMO] deleted {name}"})
    run_virsh("destroy", name)
    r = run_virsh("undefine", "--nvram", name)
    if not r["success"]:
        r = run_virsh("undefine", name)
    return (jsonify({"success": True, "message": f"VPS '{name}' deleted"})
            if r["success"] else jsonify({"error": r["error"]}), 400)

@app.route("/api/vps/create",  methods=["POST"])
def create():
    d = request.get_json() or {}
    name = d.get("name", "")
    if not VM_RE.match(name):
        return jsonify({"error": "Invalid VM name"}), 400
    try:
        ram, vcpus, disk = int(d["ram"]), int(d["vcpus"]), int(d["disk"])
    except (KeyError, ValueError):
        return jsonify({"error": "ram, vcpus, disk are required integers"}), 400
    iso = d.get("isoPath"); variant = d.get("osVariant", "generic")
    if not virsh_ok() or not shutil.which("virt-install"):
        return jsonify({"success": True,
                        "message": f"[DEMO] created {name} ({vcpus}vCPU {ram}MB {disk}GB)"})
    cmd = ["virt-install","--connect","qemu:///system",
           "--name", name,"--ram", str(ram),"--vcpus", str(vcpus),
           "--disk", f"size={disk}","--graphics","none","--noautoconsole",
           "--os-variant", variant or "generic"]
    if iso:
        cmd += ["--cdrom", iso]
    else:
        cmd += ["--pxe"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if r.returncode == 0:
        return jsonify({"success": True, "message": f"VPS '{name}' created"})
    return jsonify({"error": r.stderr.strip()}), 400

@app.route("/logo.png")
def logo():
    here = os.path.dirname(os.path.abspath(__file__))
    p = os.path.join(here, "logo.png")
    if os.path.exists(p):
        return send_file(p, mimetype="image/png")
    return "", 404

if HAS_SOCK:
    @sock.route("/ws/terminal/<name>")
    def ws_terminal(ws, name):
        import pty, fcntl, struct, termios
        if not VM_RE.match(name):
            ws.send("\r\n[ERROR] Invalid VM name\r\n")
            return
        if not virsh_ok():
            ws.send("\r\n\x1b[33m[DEMO MODE]\x1b[0m virsh not available — no real console\r\n")
            ws.send("This is a simulated terminal session.\r\n$ ")
            try:
                while True:
                    msg = ws.receive(timeout=60)
                    if msg is None:
                        break
                    ws.send(f"\r\n$ ")
            except Exception:
                pass
            return
        master_fd, slave_fd = pty.openpty()
        try:
            fcntl.ioctl(slave_fd, termios.TIOCSWINSZ,
                        struct.pack("HHHH", 30, 100, 0, 0))
        except Exception:
            pass
        proc = subprocess.Popen(
            ["virsh", "console", name],
            stdin=slave_fd, stdout=slave_fd, stderr=slave_fd,
            close_fds=True, preexec_fn=os.setsid
        )
        os.close(slave_fd)
        try:
            while proc.poll() is None:
                r, _, _ = select.select([master_fd], [], [], 0.05)
                if r:
                    try:
                        data = os.read(master_fd, 4096)
                        if data:
                            ws.send(data.decode("utf-8", errors="replace"))
                    except OSError:
                        break
                try:
                    msg = ws.receive(timeout=0.01)
                    if msg is not None:
                        os.write(master_fd, msg.encode() if isinstance(msg, str) else msg)
                except Exception:
                    pass
        except Exception:
            pass
        finally:
            try:
                proc.terminate()
            except Exception:
                pass
            try:
                os.close(master_fd)
            except Exception:
                pass

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    log.info(f"CPM Panel listening on port {port}")
    app.run(host="0.0.0.0", port=port)
PYEOF

ok "app.py written"

# ── Write index.html ──────────────────────────────────────────────────────────
cat > "$DIR/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>CPM Panel - KVM VPS Management System</title>
<meta name="description" content="Modern VPS management panel with KVM virtualization support"/>
<meta name="keywords" content="VPS panel, KVM manager, cloud VPS, Linux VPS control panel"/>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  :root{
    --bg:#f0f4f8;--sidebar:#ffffff;--card:#ffffff;
    --blue:#2563eb;--blue-light:#eff6ff;--blue-mid:#bfdbfe;
    --text:#0f172a;--muted:#64748b;--border:#e2e8f0;
    --green:#16a34a;--red:#dc2626;--amber:#d97706;--gray:#94a3b8;
    --radius:12px;--shadow:0 1px 3px rgba(0,0,0,.08),0 1px 2px rgba(0,0,0,.04);
  }
  body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);display:flex;min-height:100vh}

  /* ── sidebar ── */
  aside{width:220px;background:var(--sidebar);border-right:1px solid var(--border);display:flex;flex-direction:column;padding:0 0 16px;flex-shrink:0;position:sticky;top:0;height:100vh}
  .brand{display:flex;align-items:center;gap:10px;padding:14px 16px;border-bottom:1px solid var(--border)}
  .brand-logo{width:42px;height:42px;object-fit:contain;flex-shrink:0}
  .brand-icon{width:36px;height:36px;background:var(--blue);border-radius:8px;display:flex;align-items:center;justify-content:center;color:#fff;font-weight:700;font-size:15px}
  .brand-name{font-weight:700;font-size:15px;color:var(--text)}
  /* ── terminal ── */
  .term-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.75);z-index:200;align-items:center;justify-content:center;padding:16px}
  .term-overlay.open{display:flex}
  .term-window{background:#0f172a;border-radius:14px;overflow:hidden;width:min(960px,98vw);box-shadow:0 30px 80px rgba(0,0,0,.6);display:flex;flex-direction:column}
  .term-header{background:#1e293b;padding:10px 16px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #334155;flex-shrink:0}
  .term-dots{display:flex;gap:6px}
  .term-dot{width:12px;height:12px;border-radius:50%}
  .term-close{background:none;border:none;color:#64748b;cursor:pointer;font-size:20px;line-height:1;padding:0 4px;transition:.15s}
  .term-close:hover{color:#f1f5f9}
  #term-container{padding:6px;min-height:300px;max-height:70vh;overflow:hidden}
  .btn-terminal{background:#1e293b;color:#60a5fa}.btn-terminal:hover{background:#334155}
  .qa-terminal{background:#1e293b;color:#60a5fa}.qa-terminal:hover:not(:disabled){background:#334155}
  nav{padding:12px 10px;flex:1}
  nav a{display:flex;align-items:center;gap:10px;padding:9px 12px;border-radius:8px;text-decoration:none;color:var(--muted);font-size:14px;font-weight:500;transition:.15s;cursor:pointer;border:none;background:none;width:100%;text-align:left}
  nav a:hover{background:var(--blue-light);color:var(--blue)}
  nav a.active{background:var(--blue);color:#fff}
  nav a svg{flex-shrink:0}
  .sidebar-footer{padding:12px 16px;border-top:1px solid var(--border)}
  .status-dot{width:8px;height:8px;border-radius:50%;background:var(--green);display:inline-block;margin-right:6px}
  .status-label{font-size:12px;color:var(--muted)}
  .version{font-size:11px;color:var(--gray);margin-top:4px}

  /* ── header bar ── */
  .topbar{background:var(--card);border-bottom:1px solid var(--border);padding:0 28px;height:52px;display:flex;align-items:center;gap:8px;position:sticky;top:0;z-index:10}
  .topbar-icon{color:var(--blue);display:flex}
  .topbar-text{font-size:13px;color:var(--muted)}

  /* ── main ── */
  .main{flex:1;display:flex;flex-direction:column;min-width:0}
  .content{padding:28px;flex:1}
  .page{display:none}.page.active{display:block}
  h1{font-size:26px;font-weight:700;letter-spacing:-.5px}
  .subtitle{color:var(--muted);font-size:14px;margin-top:4px;margin-bottom:24px}

  /* ── cards ── */
  .card{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);box-shadow:var(--shadow)}
  .card-header{padding:18px 20px 10px;border-bottom:1px solid var(--border)}
  .card-title{font-size:15px;font-weight:600;display:flex;align-items:center;gap:8px}
  .card-title svg{color:var(--blue)}
  .card-desc{font-size:12px;color:var(--muted);margin-top:3px}
  .card-body{padding:20px}
  .grid-2{display:grid;grid-template-columns:1fr 1fr;gap:20px}
  .grid-3{display:grid;grid-template-columns:repeat(3,1fr);gap:20px}

  /* ── arc meters ── */
  .meter-wrap{display:flex;justify-content:center;align-items:center;padding:8px 0}

  /* ── stat cards ── */
  .stat-label{font-size:12px;color:var(--muted);font-weight:500;display:flex;justify-content:space-between;align-items:center}
  .stat-value{font-size:26px;font-weight:700;margin-top:6px}
  .stat-sub{font-size:12px;color:var(--muted);margin-top:3px}

  /* ── vm summary ── */
  .vm-summary{display:flex;align-items:center;justify-content:space-between;padding:16px 20px;background:var(--blue-light);border-radius:10px;margin-top:4px}
  .vm-total{font-size:34px;font-weight:700}
  .vm-counts{display:flex;gap:24px}
  .vm-count{text-align:center}
  .vm-count-num{font-size:22px;font-weight:700}
  .vm-count-label{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.05em;margin-top:2px}

  /* ── vps manager ── */
  .two-panel{display:grid;grid-template-columns:1fr 380px;gap:20px;align-items:start}
  .vps-list{list-style:none}
  .vps-item{display:flex;align-items:center;justify-content:space-between;padding:14px 16px;border-radius:10px;cursor:pointer;transition:.15s;border:2px solid transparent;margin-bottom:8px}
  .vps-item:hover{background:var(--blue-light)}
  .vps-item.selected{border-color:var(--blue);background:var(--blue-light)}
  .vps-info{display:flex;flex-direction:column;gap:3px}
  .vps-name{font-weight:600;font-size:14px}
  .vps-meta{font-size:12px;color:var(--muted);display:flex;gap:10px}
  .badge{display:inline-flex;align-items:center;padding:3px 10px;border-radius:20px;font-size:12px;font-weight:600}
  .badge-running{background:#dcfce7;color:#166534}
  .badge-stopped{background:#fee2e2;color:#991b1b}
  .badge-paused {background:#fef9c3;color:#854d0e}
  .badge-unknown{background:#f1f5f9;color:#64748b}
  .no-selection{display:flex;flex-direction:column;align-items:center;justify-content:center;padding:48px 20px;color:var(--muted);text-align:center;gap:12px}
  .no-selection svg{opacity:.3}
  .action-btns{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:16px}
  .btn{padding:10px 16px;border-radius:8px;font-size:13px;font-weight:600;border:none;cursor:pointer;transition:.15s;display:flex;align-items:center;justify-content:center;gap:6px}
  .btn:disabled{opacity:.45;cursor:not-allowed}
  .btn-start  {background:#dcfce7;color:#166534}.btn-start:hover:not(:disabled)  {background:#bbf7d0}
  .btn-stop   {background:#fee2e2;color:#991b1b}.btn-stop:hover:not(:disabled)   {background:#fecaca}
  .btn-restart{background:#fef9c3;color:#854d0e}.btn-restart:hover:not(:disabled){background:#fef08a}
  .btn-delete {background:#fee2e2;color:#991b1b}.btn-delete:hover:not(:disabled) {background:#fecaca}
  .btn-primary{background:var(--blue);color:#fff;grid-column:1/-1}.btn-primary:hover:not(:disabled){background:#1d4ed8}
  .selected-name{font-size:15px;font-weight:700;padding-bottom:12px;border-bottom:1px solid var(--border);margin-bottom:12px;display:flex;align-items:center;gap:8px}

  /* ── create form ── */
  .form-grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}
  .form-field{display:flex;flex-direction:column;gap:6px}
  .form-field.full{grid-column:1/-1}
  label{font-size:13px;font-weight:500;color:var(--muted)}
  input{padding:9px 12px;border:1px solid var(--border);border-radius:8px;font-size:14px;outline:none;transition:.15s;background:#fff}
  input:focus{border-color:var(--blue);box-shadow:0 0 0 3px rgba(37,99,235,.1)}
  .hint{font-size:11px;color:var(--gray)}

  /* ── toast ── */
  #toast-wrap{position:fixed;bottom:24px;right:24px;display:flex;flex-direction:column;gap:8px;z-index:9999}
  .toast{padding:12px 18px;border-radius:10px;font-size:13px;font-weight:500;box-shadow:0 4px 12px rgba(0,0,0,.15);animation:slide-in .25s ease;max-width:320px}
  .toast-ok  {background:#166534;color:#fff}
  .toast-err {background:#991b1b;color:#fff}
  @keyframes slide-in{from{transform:translateX(100%);opacity:0}to{transform:none;opacity:1}}

  /* ── modal ── */
  .overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.4);z-index:100;align-items:center;justify-content:center}
  .overlay.open{display:flex}
  .modal{background:#fff;border-radius:16px;padding:28px;width:380px;box-shadow:0 20px 60px rgba(0,0,0,.2)}
  .modal h3{font-size:18px;font-weight:700;margin-bottom:8px}
  .modal p{color:var(--muted);font-size:14px;margin-bottom:20px}
  .modal-btns{display:flex;gap:10px;justify-content:flex-end}
  .btn-cancel{padding:9px 18px;border-radius:8px;border:1px solid var(--border);background:#fff;cursor:pointer;font-size:13px;font-weight:600}
  .btn-confirm{padding:9px 18px;border-radius:8px;border:none;background:#dc2626;color:#fff;cursor:pointer;font-size:13px;font-weight:600}

  /* ── mobile nav ── */
  .mob-nav{display:none;position:fixed;bottom:0;left:0;right:0;background:#fff;border-top:1px solid var(--border);z-index:50;padding:6px 0 env(safe-area-inset-bottom,6px)}
  .mob-nav-inner{display:flex;justify-content:space-around}
  .mob-nav a{display:flex;flex-direction:column;align-items:center;gap:3px;padding:6px 12px;border-radius:8px;text-decoration:none;color:var(--muted);font-size:10px;font-weight:500;border:none;background:none;cursor:pointer;min-width:60px}
  .mob-nav a.active{color:var(--blue)}
  .mob-nav a svg{flex-shrink:0}

  /* ── dashboard quick panel ── */
  .dash-bottom{display:grid;grid-template-columns:1fr 320px;gap:20px;margin-top:20px}
  .dash-vps-list{list-style:none;max-height:280px;overflow-y:auto}
  .dash-vps-item{display:flex;align-items:center;justify-content:space-between;padding:10px 12px;border-radius:8px;cursor:pointer;transition:.15s;border:2px solid transparent;margin-bottom:6px}
  .dash-vps-item:hover{background:var(--blue-light)}
  .dash-vps-item.selected{border-color:var(--blue);background:var(--blue-light)}
  .qa-btns{display:flex;flex-direction:column;gap:10px;margin-top:12px}
  .qa-btn{padding:12px 16px;border-radius:8px;font-size:14px;font-weight:600;border:none;cursor:pointer;transition:.15s;display:flex;align-items:center;gap:8px}
  .qa-btn:disabled{opacity:.4;cursor:not-allowed}
  .qa-start  {background:#dcfce7;color:#166534}.qa-start:hover:not(:disabled)  {background:#bbf7d0}
  .qa-stop   {background:#fee2e2;color:#991b1b}.qa-stop:hover:not(:disabled)   {background:#fecaca}
  .qa-restart{background:#fef9c3;color:#854d0e}.qa-restart:hover:not(:disabled){background:#fef08a}
  .qa-none{color:var(--muted);font-size:13px;padding:24px 0;text-align:center}

  @media(max-width:900px){
    aside{display:none}
    .mob-nav{display:block}
    .main{padding-bottom:64px}
    .content{padding:16px}
    .grid-2,.grid-3,.two-panel,.dash-bottom{grid-template-columns:1fr}
    .form-grid{grid-template-columns:1fr}
    h1{font-size:20px}
    .topbar{padding:0 16px}
    .card-body{padding:14px}
  }
</style>
</head>
<body>

<aside>
  <div class="brand">
    <img src="/logo.png" class="brand-logo" alt="CPM Panel" onerror="this.style.display='none';this.nextElementSibling.style.display='flex'"/>
    <div class="brand-icon" style="display:none">CP</div>
    <span class="brand-name">CPM Panel</span>
  </div>
  <nav>
    <a class="active" onclick="showPage('dashboard',this)">
      <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/></svg>
      Dashboard
    </a>
    <a onclick="showPage('vps',this)">
      <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><rect x="2" y="3" width="20" height="8" rx="1"/><rect x="2" y="13" width="20" height="8" rx="1"/><circle cx="6" cy="7" r="1" fill="currentColor"/><circle cx="6" cy="17" r="1" fill="currentColor"/></svg>
      VPS Manager
    </a>
    <a onclick="showPage('create',this)">
      <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="16"/><line x1="8" y1="12" x2="16" y2="12"/></svg>
      Create VPS
    </a>
  </nav>
  <div class="sidebar-footer">
    <div><span class="status-dot" id="dot"></span><span class="status-label" id="status-txt">Connecting…</span></div>
    <div class="version">v1.0.0</div>
  </div>
</aside>

<div class="main">
  <div class="topbar">
    <div class="topbar-icon">
      <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>
    </div>
    <span class="topbar-text" id="kvm-status">Checking KVM…</span>
  </div>

  <main class="content">

    <!-- DASHBOARD -->
    <section class="page active" id="page-dashboard">
      <h1>Dashboard</h1>
      <p class="subtitle">System overview and resource utilisation.</p>

      <div class="grid-2" style="margin-bottom:20px">
        <div class="card">
          <div class="card-header">
            <div class="card-title">
              <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg>
              Memory Usage
            </div>
            <div class="card-desc">System RAM utilisation</div>
          </div>
          <div class="card-body meter-wrap"><svg id="meter-ram" viewBox="0 0 200 132" width="200" height="132"></svg></div>
        </div>
        <div class="card">
          <div class="card-header">
            <div class="card-title">
              <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><rect x="2" y="2" width="20" height="20" rx="2"/><circle cx="12" cy="12" r="3"/></svg>
              Storage Usage
            </div>
            <div class="card-desc">System disk utilisation</div>
          </div>
          <div class="card-body meter-wrap"><svg id="meter-disk" viewBox="0 0 200 132" width="200" height="132"></svg></div>
        </div>
      </div>

      <div class="grid-3" style="margin-bottom:20px">
        <div class="card card-body">
          <div class="stat-label">CPU Usage <svg width="14" height="14" fill="none" stroke="#2563eb" stroke-width="2" viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/><line x1="9" y1="2" x2="9" y2="4"/><line x1="15" y1="2" x2="15" y2="4"/><line x1="9" y1="20" x2="9" y2="22"/><line x1="15" y1="20" x2="15" y2="22"/><line x1="2" y1="9" x2="4" y2="9"/><line x1="2" y1="15" x2="4" y2="15"/><line x1="20" y1="9" x2="22" y2="9"/><line x1="20" y1="15" x2="22" y2="15"/></svg></div>
          <div class="stat-value" id="cpu-pct">—</div>
          <div class="stat-sub" id="cpu-model">—</div>
        </div>
        <div class="card card-body">
          <div class="stat-label">Network Traffic <svg width="14" height="14" fill="none" stroke="#2563eb" stroke-width="2" viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><line x1="12" y1="3" x2="12" y2="9"/><line x1="12" y1="15" x2="12" y2="21"/><line x1="3" y1="12" x2="9" y2="12"/><line x1="15" y1="12" x2="21" y2="12"/></svg></div>
          <div style="display:flex;justify-content:space-between;margin-top:6px">
            <div><div class="stat-value" style="font-size:18px" id="net-rx">—</div><div class="stat-sub">Received (RX)</div></div>
            <div><div class="stat-value" style="font-size:18px;text-align:right" id="net-tx">—</div><div class="stat-sub">Sent (TX)</div></div>
          </div>
        </div>
        <div class="card card-body">
          <div class="stat-label">System Uptime <svg width="14" height="14" fill="none" stroke="#2563eb" stroke-width="2" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg></div>
          <div class="stat-value" id="uptime">—</div>
          <div class="stat-sub">Total continuous uptime</div>
        </div>
      </div>

      <!-- VM summary counts -->
      <div class="card">
        <div class="card-header"><div class="card-title">
          <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><rect x="2" y="3" width="20" height="8" rx="1"/><rect x="2" y="13" width="20" height="8" rx="1"/></svg>
          Virtual Machines
        </div></div>
        <div class="card-body">
          <div class="vm-summary">
            <div><div class="vm-total" id="vm-total">—</div><div class="stat-sub">Total Instances</div></div>
            <div class="vm-counts">
              <div class="vm-count"><div class="vm-count-num" style="color:var(--green)" id="vm-running">—</div><div class="vm-count-label">Running</div></div>
              <div class="vm-count"><div class="vm-count-num" style="color:var(--red)" id="vm-stopped">—</div><div class="vm-count-label">Stopped</div></div>
              <div class="vm-count"><div class="vm-count-num" style="color:var(--amber)" id="vm-paused">—</div><div class="vm-count-label">Paused</div></div>
            </div>
          </div>
        </div>
      </div>

      <!-- Dashboard bottom: VPS list + Quick Actions -->
      <div class="dash-bottom">
        <div class="card">
          <div class="card-header">
            <div class="card-title">
              <svg width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><rect x="2" y="3" width="20" height="8" rx="1"/><rect x="2" y="13" width="20" height="8" rx="1"/></svg>
              Instances
            </div>
            <div class="card-desc">Select an instance to control it</div>
          </div>
          <div class="card-body">
            <ul class="dash-vps-list" id="dash-vps-list">
              <li style="color:var(--muted);font-size:13px">Loading…</li>
            </ul>
          </div>
        </div>
        <div class="card">
          <div class="card-header">
            <div class="card-title">
              <svg width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>
              Quick Actions
            </div>
            <div class="card-desc" id="qa-selected-name">No instance selected</div>
          </div>
          <div class="card-body" id="qa-body">
            <div class="qa-none">Select an instance from the list</div>
          </div>
        </div>
      </div>
    </section>

    <!-- VPS MANAGER -->
    <section class="page" id="page-vps">
      <h1>VPS Manager</h1>
      <p class="subtitle">Manage, monitor, and control your virtual instances.</p>
      <div class="two-panel">
        <div class="card">
          <div class="card-header"><div class="card-title">Instances</div></div>
          <div class="card-body"><ul class="vps-list" id="vps-list"><li style="color:var(--muted);font-size:14px">Loading…</li></ul></div>
        </div>
        <div class="card">
          <div class="card-header"><div class="card-title">Controls</div></div>
          <div class="card-body" id="controls-body">
            <div class="no-selection">
              <svg width="40" height="40" fill="none" stroke="currentColor" stroke-width="1.5" viewBox="0 0 24 24"><rect x="2" y="3" width="20" height="8" rx="1"/><rect x="2" y="13" width="20" height="8" rx="1"/></svg>
              <span style="font-size:14px">Select an instance to manage</span>
            </div>
          </div>
        </div>
      </div>
    </section>

    <!-- CREATE VPS -->
    <section class="page" id="page-create">
      <h1>Create Instance</h1>
      <p class="subtitle">Deploy a new KVM virtual machine.</p>
      <div class="card" style="max-width:680px">
        <div class="card-header">
          <div class="card-title">
            <svg width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><rect x="2" y="3" width="20" height="8" rx="1"/><rect x="2" y="13" width="20" height="8" rx="1"/></svg>
            Instance Details
          </div>
        </div>
        <div class="card-body">
          <form id="create-form" onsubmit="submitCreate(event)">
            <div class="form-grid">
              <div class="form-field">
                <label>Instance Name *</label>
                <input id="f-name" placeholder="e.g. web-server-01" required pattern="[a-zA-Z0-9_\-]{1,64}"/>
                <span class="hint">Letters, numbers, dash, underscore only.</span>
              </div>
              <div class="form-field">
                <label>OS Variant</label>
                <input id="f-variant" value="ubuntu22.04" placeholder="ubuntu22.04"/>
                <span class="hint">Used by virt-install for optimisations.</span>
              </div>
              <div class="form-field">
                <label>RAM (MB) *</label>
                <input id="f-ram" type="number" min="128" max="524288" value="1024" required/>
                <span class="hint">Minimum 128 MB.</span>
              </div>
              <div class="form-field">
                <label>vCPUs *</label>
                <input id="f-vcpus" type="number" min="1" max="128" value="1" required/>
              </div>
              <div class="form-field">
                <label>Disk (GB) *</label>
                <input id="f-disk" type="number" min="1" max="10000" value="20" required/>
              </div>
              <div class="form-field">
                <label>ISO Path (optional)</label>
                <input id="f-iso" placeholder="/var/lib/libvirt/images/ubuntu.iso"/>
                <span class="hint">Leave blank for network/template install.</span>
              </div>
              <div class="form-field full" style="margin-top:8px">
                <button type="submit" class="btn btn-primary">
                  <svg width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="16"/><line x1="8" y1="12" x2="16" y2="12"/></svg>
                  Create Instance
                </button>
              </div>
            </div>
          </form>
        </div>
      </div>
    </section>

  </main>
</div>

<!-- Terminal Modal -->
<div class="term-overlay" id="term-overlay">
  <div class="term-window">
    <div class="term-header">
      <div style="display:flex;align-items:center;gap:12px">
        <div class="term-dots">
          <div class="term-dot" style="background:#ef4444"></div>
          <div class="term-dot" style="background:#f59e0b"></div>
          <div class="term-dot" style="background:#22c55e"></div>
        </div>
        <span id="term-title" style="font-size:13px;font-weight:600;color:#94a3b8">Terminal</span>
      </div>
      <button class="term-close" onclick="closeTerm()">✕</button>
    </div>
    <div id="term-container"></div>
  </div>
</div>

<!-- Delete confirm modal -->
<div class="overlay" id="del-modal">
  <div class="modal">
    <h3>Delete instance?</h3>
    <p id="del-msg">This will permanently destroy the VM and cannot be undone.</p>
    <div class="modal-btns">
      <button class="btn-cancel" onclick="closeModal()">Cancel</button>
      <button class="btn-confirm" id="del-confirm">Delete</button>
    </div>
  </div>
</div>

<!-- Mobile bottom nav -->
<nav class="mob-nav">
  <div class="mob-nav-inner">
    <a class="active" onclick="showPage('dashboard',this)" id="mob-dash">
      <svg width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/></svg>
      Dashboard
    </a>
    <a onclick="showPage('vps',this)" id="mob-vps">
      <svg width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><rect x="2" y="3" width="20" height="8" rx="1"/><rect x="2" y="13" width="20" height="8" rx="1"/><circle cx="6" cy="7" r="1" fill="currentColor"/><circle cx="6" cy="17" r="1" fill="currentColor"/></svg>
      Instances
    </a>
    <a onclick="showPage('create',this)" id="mob-create">
      <svg width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="16"/><line x1="8" y1="12" x2="16" y2="12"/></svg>
      Create
    </a>
  </div>
</nav>

<div id="toast-wrap"></div>

<script>
// ── state ──────────────────────────────────────────────────────────────────
let selectedVps = null;
let vpsData = [];
let deleteTarget = null;

// ── navigation ─────────────────────────────────────────────────────────────
const MOB_IDS = {dashboard:'mob-dash', vps:'mob-vps', create:'mob-create'};
function showPage(id, el) {
  document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('nav a, .mob-nav a').forEach(a => a.classList.remove('active'));
  document.getElementById('page-' + id).classList.add('active');
  if (el) el.classList.add('active');
  // sync mobile nav
  const mobEl = document.getElementById(MOB_IDS[id]);
  if (mobEl) mobEl.classList.add('active');
  window.scrollTo(0,0);
}

// ── formatting ─────────────────────────────────────────────────────────────
function fmtBytes(b) {
  if (b >= 1e9) return (b / 1e9).toFixed(2) + ' GB';
  if (b >= 1e6) return (b / 1e6).toFixed(2) + ' MB';
  if (b >= 1e3) return (b / 1e3).toFixed(1) + ' KB';
  return b + ' B';
}
function fmtUptime(s) {
  const d = Math.floor(s/86400), h = Math.floor((s%86400)/3600),
        m = Math.floor((s%3600)/60);
  if (d > 0) return `${d}d ${h}h ${m}m`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m} mins`;
}

// ── arc meter ──────────────────────────────────────────────────────────────
function drawMeter(svgId, pct, label, sub) {
  const svg = document.getElementById(svgId);
  if (!svg) return;
  const cx=100,cy=100,r=72,sw=14;
  const arc = `M ${cx-r} ${cy} A ${r} ${r} 0 0 1 ${cx+r} ${cy}`;
  const total = Math.PI * r;
  const fill  = Math.min(Math.max(pct,0),100) / 100 * total;
  const color = pct > 85 ? '#dc2626' : pct > 60 ? '#d97706' : '#2563eb';
  svg.innerHTML = `
    <path d="${arc}" fill="none" stroke="#e2e8f0" stroke-width="${sw}" stroke-linecap="round"/>
    ${pct > 0 ? `<path d="${arc}" fill="none" stroke="${color}" stroke-width="${sw}" stroke-linecap="round"
      stroke-dasharray="${fill} ${total}" style="transition:stroke-dasharray 1s ease"/>` : ''}
    <text x="${cx}" y="${cy-8}" text-anchor="middle" font-size="28" font-weight="700" fill="#0f172a">${Math.round(pct)}%</text>
    <text x="${cx}" y="${cy+14}" text-anchor="middle" font-size="12" font-weight="500" fill="#64748b">${label}</text>
    <text x="${cx}" y="${cy+32}" text-anchor="middle" font-size="11" fill="#94a3b8">${sub}</text>`;
}

// ── fetch helpers ──────────────────────────────────────────────────────────
async function api(path, opts={}) {
  const r = await fetch(path, {headers:{'Content-Type':'application/json'},...opts});
  return r.json();
}

// ── toast ──────────────────────────────────────────────────────────────────
function toast(msg, ok=true) {
  const w = document.getElementById('toast-wrap');
  const el = document.createElement('div');
  el.className = 'toast ' + (ok ? 'toast-ok' : 'toast-err');
  el.textContent = msg;
  w.appendChild(el);
  setTimeout(() => el.remove(), 3500);
}

// ── load system stats ──────────────────────────────────────────────────────
async function loadStats() {
  try {
    const d = await api('/api/system');
    drawMeter('meter-ram',  d.ram.percent,  'RAM Used',  `${fmtBytes(d.ram.used)} / ${fmtBytes(d.ram.total)}`);
    drawMeter('meter-disk', d.disk.percent, 'Disk Used', `${fmtBytes(d.disk.used)} / ${fmtBytes(d.disk.total)}`);
    document.getElementById('cpu-pct').textContent   = d.cpu.percent.toFixed(1) + '%';
    document.getElementById('cpu-model').textContent = `${d.cpu.cores} Cores · ${d.cpu.model}`;
    document.getElementById('net-rx').textContent    = fmtBytes(d.network.bytesRecv);
    document.getElementById('net-tx').textContent    = fmtBytes(d.network.bytesSent);
    document.getElementById('uptime').textContent    = fmtUptime(d.uptime);
    document.getElementById('status-txt').textContent = 'System OK';
    document.getElementById('dot').style.background  = '#16a34a';
    document.getElementById('kvm-status').textContent = 'KVM Virtualisation Active';
  } catch (e) {
    document.getElementById('status-txt').textContent = 'Offline';
    document.getElementById('dot').style.background  = '#dc2626';
  }
}

// ── load VPS list ──────────────────────────────────────────────────────────
let dashSelected = null;
async function loadVps() {
  try {
    const d = await api('/api/vps/list');
    vpsData = d.vps || [];
    const running = vpsData.filter(v=>v.state==='running').length;
    const stopped = vpsData.filter(v=>['stopped','crashed'].includes(v.state)).length;
    const paused  = vpsData.filter(v=>v.state==='paused').length;
    document.getElementById('vm-total').textContent   = vpsData.length;
    document.getElementById('vm-running').textContent = running;
    document.getElementById('vm-stopped').textContent = stopped;
    document.getElementById('vm-paused').textContent  = paused;
    renderVpsList();
    renderDashList();
    if (dashSelected) renderQuickActions(dashSelected);
  } catch (e) {}
}

function renderDashList() {
  const ul = document.getElementById('dash-vps-list');
  if (!ul) return;
  if (!vpsData.length) { ul.innerHTML = '<li style="color:var(--muted);font-size:13px;padding:8px">No instances found.</li>'; return; }
  ul.innerHTML = vpsData.map(v => `
    <li class="dash-vps-item${dashSelected===v.name?' selected':''}" onclick="dashSelectVps('${v.name}')">
      <span style="font-weight:600;font-size:13px">${v.name}</span>
      <span class="badge ${badgeClass(v.state)}">${v.state.charAt(0).toUpperCase()+v.state.slice(1)}</span>
    </li>`).join('');
}

function dashSelectVps(name) {
  dashSelected = name;
  renderDashList();
  renderQuickActions(name);
}

function renderQuickActions(name) {
  const vm = vpsData.find(v=>v.name===name);
  const nameEl = document.getElementById('qa-selected-name');
  const body   = document.getElementById('qa-body');
  if (!vm || !nameEl || !body) return;
  nameEl.textContent = name;
  const isRunning = vm.state==='running';
  const isStopped = vm.state==='stopped';
  body.innerHTML = `
    <div class="qa-btns">
      <button class="qa-btn qa-start"   ${isRunning?'disabled':''} onclick="dashAction('start')">
        <svg width="15" height="15" fill="currentColor" viewBox="0 0 24 24"><polygon points="5 3 19 12 5 21 5 3"/></svg> Start Instance
      </button>
      <button class="qa-btn qa-stop"    ${isStopped?'disabled':''} onclick="dashAction('stop')">
        <svg width="15" height="15" fill="currentColor" viewBox="0 0 24 24"><rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/></svg> Stop Instance
      </button>
      <button class="qa-btn qa-restart" ${isStopped?'disabled':''} onclick="dashAction('restart')">
        <svg width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/></svg> Restart Instance
      </button>
      <button class="qa-btn qa-terminal" onclick="openTerminal('${name}')">
        <svg width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg> Open Terminal
      </button>
    </div>`;
}

async function dashAction(action) {
  if (!dashSelected) return;
  try {
    const d = await api(`/api/vps/${action}`, {method:'POST', body:JSON.stringify({name:dashSelected})});
    if (d.success) { toast(d.message); await loadVps(); }
    else toast(d.error || 'Action failed', false);
  } catch(e) { toast('Request failed', false); }
}

function badgeClass(state) {
  return {running:'badge-running',stopped:'badge-stopped',paused:'badge-paused'}[state] || 'badge-unknown';
}

function renderVpsList() {
  const ul = document.getElementById('vps-list');
  if (!vpsData.length) { ul.innerHTML = '<li style="color:var(--muted);font-size:14px;padding:8px">No instances found.</li>'; return; }
  ul.innerHTML = vpsData.map(v => `
    <li class="vps-item${selectedVps===v.name?' selected':''}" onclick="selectVps('${v.name}')">
      <div class="vps-info">
        <span class="vps-name">${v.name}</span>
        <span class="vps-meta">
          ${v.vcpus ? `<span>${v.vcpus} vCPU</span>` : ''}
          ${v.memory ? `<span>${v.memory} MB</span>` : ''}
        </span>
      </div>
      <span class="badge ${badgeClass(v.state)}">${v.state.charAt(0).toUpperCase()+v.state.slice(1)}</span>
    </li>`).join('');
}

function selectVps(name) {
  selectedVps = name;
  renderVpsList();
  const vm = vpsData.find(v=>v.name===name);
  const isRunning = vm?.state === 'running';
  const isStopped = vm?.state === 'stopped';
  document.getElementById('controls-body').innerHTML = `
    <div class="selected-name">
      <svg width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><rect x="2" y="3" width="20" height="8" rx="1"/><rect x="2" y="13" width="20" height="8" rx="1"/></svg>
      ${name}
      <span class="badge ${badgeClass(vm?.state||'unknown')}" style="margin-left:auto">${vm?.state||'unknown'}</span>
    </div>
    <div class="action-btns">
      <button class="btn btn-start"   onclick="doAction('start')"   ${isRunning?'disabled':''}>
        <svg width="13" height="13" fill="currentColor" viewBox="0 0 24 24"><polygon points="5 3 19 12 5 21 5 3"/></svg>Start</button>
      <button class="btn btn-stop"    onclick="doAction('stop')"    ${isStopped?'disabled':''}>
        <svg width="13" height="13" fill="currentColor" viewBox="0 0 24 24"><rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/></svg>Stop</button>
      <button class="btn btn-restart" onclick="doAction('restart')" ${isStopped?'disabled':''}>
        <svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/></svg>Restart</button>
      <button class="btn btn-delete"  onclick="confirmDelete('${name}')">
        <svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14H6L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/><path d="M9 6V4h6v2"/></svg>Delete</button>
      <button class="btn btn-terminal" onclick="openTerminal('${name}')" style="grid-column:1/-1">
        <svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>Open Terminal</button>
    </div>`;
}

async function doAction(action) {
  if (!selectedVps) return;
  try {
    const d = await api(`/api/vps/${action}`, {method:'POST', body:JSON.stringify({name:selectedVps})});
    if (d.success) { toast(d.message); await loadVps(); selectVps(selectedVps); }
    else toast(d.error || 'Action failed', false);
  } catch(e) { toast('Request failed', false); }
}

// ── delete modal ──────────────────────────────────────────────────────────
function confirmDelete(name) {
  deleteTarget = name;
  document.getElementById('del-msg').textContent = `This will permanently destroy "${name}" and cannot be undone.`;
  document.getElementById('del-modal').classList.add('open');
  document.getElementById('del-confirm').onclick = async () => {
    closeModal();
    try {
      const d = await api('/api/vps/delete', {method:'POST', body:JSON.stringify({name:deleteTarget})});
      if (d.success) { toast(d.message); selectedVps=null; await loadVps(); document.getElementById('controls-body').innerHTML='<div class="no-selection"><span style="font-size:14px">Select an instance to manage</span></div>'; }
      else toast(d.error||'Delete failed', false);
    } catch(e) { toast('Request failed', false); }
  };
}
function closeModal() { document.getElementById('del-modal').classList.remove('open'); }

// ── create form ───────────────────────────────────────────────────────────
async function submitCreate(e) {
  e.preventDefault();
  const btn = e.target.querySelector('button[type=submit]');
  btn.disabled = true; btn.textContent = 'Creating…';
  try {
    const iso = document.getElementById('f-iso').value.trim();
    const d = await api('/api/vps/create', {method:'POST', body:JSON.stringify({
      name:    document.getElementById('f-name').value.trim(),
      ram:     parseInt(document.getElementById('f-ram').value),
      vcpus:   parseInt(document.getElementById('f-vcpus').value),
      disk:    parseInt(document.getElementById('f-disk').value),
      osVariant: document.getElementById('f-variant').value.trim() || 'generic',
      ...(iso ? {isoPath: iso} : {})
    })});
    if (d.success) {
      document.getElementById('create-form').reset();
      await loadVps();
      // Show success toast with Start Now option
      const w = document.getElementById('toast-wrap');
      const el = document.createElement('div');
      el.className = 'toast toast-ok';
      el.style.cssText = 'display:flex;align-items:center;justify-content:space-between;gap:12px;min-width:280px';
      const vmName = document.getElementById('f-name') ? document.getElementById('f-name').value || '' : '';
      el.innerHTML = `<span>${d.message}</span><button onclick="startNewVm('${vmName || d.message}')" style="background:rgba(255,255,255,.25);border:none;color:#fff;font-weight:700;padding:4px 10px;border-radius:6px;cursor:pointer;font-size:12px;flex-shrink:0">Start Now</button>`;
      w.appendChild(el);
      setTimeout(() => el.remove(), 6000);
    }
    else toast(d.error || 'Create failed', false);
  } catch(e) { toast('Request failed', false); }
  btn.disabled = false; btn.innerHTML = '<svg width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="16"/><line x1="8" y1="12" x2="16" y2="12"/></svg> Create Instance';
}

// ── xterm.js web terminal ─────────────────────────────────────────────────
let term = null, termWs = null, xtermReady = false;

function loadXterm(cb) {
  if (xtermReady) { cb(); return; }
  const css = document.createElement('link');
  css.rel = 'stylesheet';
  css.href = 'https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.css';
  document.head.appendChild(css);
  const s = document.createElement('script');
  s.src = 'https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.js';
  s.onload = () => { xtermReady = true; cb(); };
  s.onerror = () => { document.getElementById('term-container').innerHTML =
    '<p style="color:#f87171;padding:20px;font-family:monospace">Failed to load xterm.js — check internet connection</p>'; };
  document.head.appendChild(s);
}

function openTerminal(name) {
  document.getElementById('term-title').textContent = 'Terminal — ' + name;
  document.getElementById('term-overlay').classList.add('open');
  loadXterm(() => {
    const container = document.getElementById('term-container');
    container.innerHTML = '';
    if (term) { try { term.dispose(); } catch(e){} }
    term = new Terminal({
      theme: { background:'#0f172a', foreground:'#e2e8f0', cursor:'#60a5fa',
                selectionBackground:'#334155', black:'#1e293b', brightBlack:'#475569',
                blue:'#60a5fa', brightBlue:'#93c5fd' },
      fontSize: 14, fontFamily: '"Cascadia Code","Fira Code",monospace',
      cursorBlink: true, cols: 100, rows: 28, scrollback: 1000
    });
    term.open(container);
    term.write('\x1b[34m Connecting to \x1b[1m' + name + '\x1b[0m\x1b[34m console…\x1b[0m\r\n');
    if (termWs) { try { termWs.close(); } catch(e){} }
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    termWs = new WebSocket(proto + '//' + location.host + '/ws/terminal/' + name);
    termWs.onopen  = () => term.write('\x1b[32m[Connected]\x1b[0m\r\n');
    termWs.onmessage = e => term.write(e.data);
    termWs.onclose = () => term.write('\r\n\x1b[31m[Connection closed]\x1b[0m\r\n');
    termWs.onerror = () => term.write('\r\n\x1b[31m[WebSocket error — make sure flask-sock is installed]\x1b[0m\r\n');
    term.onData(d => { if (termWs && termWs.readyState === WebSocket.OPEN) termWs.send(d); });
  });
}

function closeTerm() {
  document.getElementById('term-overlay').classList.remove('open');
  if (termWs) { try { termWs.close(); } catch(e){} termWs = null; }
  if (term)   { try { term.dispose(); } catch(e){} term = null; }
}

// close terminal on Escape key
document.addEventListener('keydown', e => { if (e.key === 'Escape') closeTerm(); });

// ── start newly created VM ────────────────────────────────────────────────
async function startNewVm(name) {
  try {
    const d = await api('/api/vps/start', {method:'POST', body:JSON.stringify({name})});
    if (d.success) { toast(`${name} started!`); await loadVps(); dashSelectVps(name); showPage('dashboard', document.getElementById('mob-dash')); }
    else toast(d.error || 'Could not start', false);
  } catch(e) { toast('Request failed', false); }
}

// ── init & poll ───────────────────────────────────────────────────────────
loadStats(); loadVps();
setInterval(loadStats, 5000);
setInterval(loadVps, 10000);
</script>
</body>
</html>
HTMLEOF

ok "index.html written"

# ── Write requirements.txt ────────────────────────────────────────────────────
cat > "$DIR/requirements.txt" << 'EOF'
flask>=3.0.0
flask-cors>=4.0.0
flask-sock>=0.7.0
psutil>=6.0.0
EOF

# Copy logo if it exists next to install.sh
[[ -f "$DIR/logo.png" ]] && ok "logo.png found" || wrn "logo.png not found in $DIR — sidebar will show text brand"

# ── 4. Install Python packages ─────────────────────────────────────────────────
sep "4/4  Installing Python packages"

PKGS="flask flask-cors flask-sock psutil"

# ── Step 4a: Build / ensure venv ──────────────────────────────────────────────
inf "Creating virtual environment…"
if python3 -m venv "$DIR/venv" 2>/dev/null && [[ -f "$DIR/venv/bin/pip" ]]; then
  ok "venv ready at $DIR/venv"
else
  wrn "venv creation failed — will install system-wide"
  rm -rf "$DIR/venv"
fi

# ── Resolve Python / pip to use ───────────────────────────────────────────────
if [[ -f "$DIR/venv/bin/python3" ]]; then
  PYTHON="$DIR/venv/bin/python3"
  PIP="$DIR/venv/bin/pip"
else
  PYTHON="$(which python3)"
  PIP=""   # determined per-attempt below
fi
ok "Python: $PYTHON"

# ── Helper: install one package, trying every known method ───────────────────
install_pkg() {
  local pkg="$1"
  # Already installed?
  if "$PYTHON" -c "import ${pkg//-/_}" 2>/dev/null; then
    ok "$pkg already available"
    return 0
  fi
  inf "Installing $pkg…"
  # venv pip (fastest, cleanest)
  if [[ -n "$PIP" ]] && "$PIP" install "$pkg" -q 2>/dev/null; then
    ok "$pkg installed (venv pip)"
    return 0
  fi
  # pip3 --break-system-packages  (Ubuntu 22.04+ / Debian 12+)
  if pip3 install --break-system-packages "$pkg" -q 2>/dev/null; then
    ok "$pkg installed (pip3 --break-system-packages)"
    return 0
  fi
  # pip3 plain  (older systems)
  if pip3 install "$pkg" -q 2>/dev/null; then
    ok "$pkg installed (pip3)"
    return 0
  fi
  # python3 -m pip variants
  if "$PYTHON" -m pip install --break-system-packages "$pkg" -q 2>/dev/null; then
    ok "$pkg installed (python3 -m pip --break-system-packages)"
    return 0
  fi
  if "$PYTHON" -m pip install "$pkg" -q 2>/dev/null; then
    ok "$pkg installed (python3 -m pip)"
    return 0
  fi
  # pipx as absolute last resort (available on some systems)
  if command -v pipx &>/dev/null && pipx install "$pkg" -q 2>/dev/null; then
    ok "$pkg installed (pipx)"
    return 0
  fi
  die "FAILED to install $pkg — check your network / pip setup and re-run install.sh"
}

# ── Step 4b: Install every package (individually so one failure doesn't block others) ──
for pkg in $PKGS; do
  install_pkg "$pkg"
done

# ── Step 4c: Final verification — every package must import ──────────────────
sep "Verifying all packages"
ALL_OK=true
for pkg in flask flask_cors flask_sock psutil; do
  if "$PYTHON" -c "import $pkg" 2>/dev/null; then
    ok "$pkg importable"
  else
    wrn "$pkg NOT importable — attempting emergency install of ${pkg//_/-}…"
    install_pkg "${pkg//_/-}"
    if "$PYTHON" -c "import $pkg" 2>/dev/null; then
      ok "$pkg now importable after emergency install"
    else
      ALL_OK=false
      die "$pkg still not importable. Run:  $PYTHON -m pip install --break-system-packages ${pkg//_/-}"
    fi
  fi
done
[[ "$ALL_OK" == true ]] && ok "All packages verified — WebSocket terminal will work"

# ── done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${G}═══════════════════════════════════════════════${N}"
echo -e "${G}  Installation complete!${N}"
echo -e "${G}═══════════════════════════════════════════════${N}"
echo ""
echo -e "  Start the panel:"
echo -e "    ${Y}bash run.sh${N}"
echo ""
echo -e "  Then open:"
echo -e "    ${Y}http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo localhost):5000${N}"
echo ""
[[ -n "${SUDO_USER:-}" ]] && echo -e "  ${Y}NOTE:${N} Log out and back in so '$SUDO_USER' can use virsh without sudo."
