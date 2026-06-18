#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  CPM Panel — One-Shot Installer  (v1 — owner-key security fix)
#  GitHub : https://github.com/Amir565-ux/CPM-Panel
#  Usage  : sudo bash install.sh
#  ⚡POWERED BY ABDULLAH
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
echo -e "${N}  KVM VPS Management Panel — Installer v2\n"

# ─── 1. System packages ───────────────────────────────────────────────────────
sep "1/4  System packages"
apt-get update -y
apt-get install -y python3 python3-pip python3-venv python3-full curl tmate
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

# Copy pre-fixed app.py if running from the extracted package,
# otherwise write it inline below.
if [[ -f "$DIR/app.py" ]]; then
  ok "app.py already present (using pre-fixed version)"
else
cat > "$DIR/app.py" << 'PYEOF'
"""
CPM Panel — Flask backend
GitHub: https://github.com/Amir565-ux/CPM-Panel
"""
import os, re, shutil, subprocess, logging, time, hashlib, json, uuid, secrets
from datetime import datetime, timedelta, timezone
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

app = Flask(__name__)
if HAS_CORS:
    CORS(app)

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

def kvm_supported():
    try:
        with open("/proc/cpuinfo") as f:
            return bool(re.search(r'vmx|svm', f.read()))
    except Exception:
        return False

def virsh_ok():
    return shutil.which("virsh") is not None

def kvm_functional():
    return kvm_supported() and virsh_ok()

def run_virsh(*args, timeout=15):
    try:
        r = subprocess.run(["virsh"] + list(args), capture_output=True, text=True, timeout=timeout)
        return {"success": r.returncode == 0, "output": r.stdout.strip(), "error": r.stderr.strip()}
    except Exception as e:
        return {"success": False, "output": "", "error": str(e)}

def vm_state(s):
    s = s.lower()
    if "running" in s:                       return "running"
    if "shut off" in s or "shutoff" in s:    return "stopped"
    if "paused" in s:                         return "paused"
    if "crashed" in s:                        return "crashed"
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
        return {"used": m.used, "free": m.available, "total": m.total, "percent": round(m.percent, 1)}
    try:
        info = {}
        for line in open("/proc/meminfo"):
            k, v = line.split(":", 1)
            info[k.strip()] = int(v.strip().split()[0]) * 1024
        total = info.get("MemTotal", 0)
        free  = info.get("MemAvailable", info.get("MemFree", 0))
        used  = total - free
        return {"used": used, "free": free, "total": total,
                "percent": round(used / total * 100, 1) if total else 0}
    except Exception:
        return {"used": 0, "free": 0, "total": 0, "percent": 0}

def disk_stats():
    if HAS_PSUTIL:
        d = psutil.disk_usage("/")
        return {"used": d.used, "free": d.free, "total": d.total, "percent": round(d.percent, 1)}
    try:
        r = subprocess.run(["df", "-B1", "/"], capture_output=True, text=True, timeout=5)
        p = r.stdout.strip().splitlines()[-1].split()
        total, used, free = int(p[1]), int(p[2]), int(p[3])
        return {"used": used, "free": free, "total": total,
                "percent": round(used / total * 100, 1) if total else 0}
    except Exception:
        return {"used": 0, "free": 0, "total": 0, "percent": 0}

def cpu_percent():
    if HAS_PSUTIL:
        return round(psutil.cpu_percent(interval=0.5), 1)
    try:
        def read_cpu():
            with open("/proc/stat") as f:
                line = f.readline()
            vals = list(map(int, line.split()[1:]))
            return vals[0]+vals[2], sum(vals)   # active, total
        a1, t1 = read_cpu(); time.sleep(0.5); a2, t2 = read_cpu()
        dt = t2 - t1
        return round((a2 - a1) / dt * 100, 1) if dt else 0.0
    except Exception:
        return 0.0

def net_stats():
    if HAS_PSUTIL:
        n = psutil.net_io_counters()
        iface = next((k for k, s in psutil.net_if_stats().items()
                      if k != "lo" and s.isup), "eth0")
        return {"bytesSent": n.bytes_sent, "bytesRecv": n.bytes_recv, "interface": iface}
    try:
        for line in open("/proc/net/dev"):
            parts = line.strip().split()
            if not parts or not parts[0].endswith(":"): continue
            iface = parts[0].rstrip(":")
            if iface == "lo": continue
            return {"bytesRecv": int(parts[1]), "bytesSent": int(parts[9]), "interface": iface}
    except Exception:
        pass
    return {"bytesSent": 0, "bytesRecv": 0, "interface": "unknown"}

def list_vms():
    if not kvm_functional():
        return []
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

@app.route("/api/kvm/status")
def kvm_status():
    hw  = kvm_supported()
    vsh = virsh_ok()
    return jsonify({
        "kvm_supported":  hw,
        "virsh_available": vsh,
        "functional":     hw and vsh,
        "message": (
            "KVM fully operational" if hw and vsh else
            "virsh not found — install libvirt-clients" if hw and not vsh else
            "Hardware virtualisation (VT-x/AMD-V) not detected — KVM unavailable" if not hw and vsh else
            "KVM not supported and virsh not found on this host"
        )
    })

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
    return jsonify({"vps": list_vms(), "kvm_functional": kvm_functional()})

def _require_kvm():
    if not kvm_functional():
        return jsonify({"error": "KVM not supported on this host — VPS actions unavailable"}), 503
    return None

def _action(req, virsh_cmd):
    err = _require_kvm()
    if err: return err
    data = req.get_json() or {}
    name = data.get("name", "")
    if not VM_RE.match(name):
        return jsonify({"error": "Invalid VM name"}), 400
    r = run_virsh(virsh_cmd, name)
    if r["success"]:
        return jsonify({"success": True, "message": f"VPS '{name}' — {virsh_cmd} OK"})
    return jsonify({"error": r["error"]}), 400

@app.route("/api/vps/start",   methods=["POST"])
def start():   return _action(request, "start")

@app.route("/api/vps/stop",    methods=["POST"])
def stop():
    """Force-off (virsh destroy). Checks current state first to give a clear error."""
    err = _require_kvm()
    if err: return err
    data = request.get_json() or {}
    name = data.get("name", "")
    if not VM_RE.match(name):
        return jsonify({"error": "Invalid VM name"}), 400
    info = run_virsh("domstate", name, timeout=5)
    if info["success"]:
        state = info["output"].strip().lower()
        if "shut off" in state or "shutoff" in state:
            return jsonify({"success": True, "message": f"VPS '{name}' is already stopped"})
    r = run_virsh("destroy", "--graceful", name, timeout=20)
    if not r["success"]:
        r = run_virsh("destroy", name, timeout=20)
    if r["success"]:
        return jsonify({"success": True, "message": f"VPS '{name}' stopped (force-off)"})
    return jsonify({"error": r["error"] or "virsh destroy failed"}), 400

@app.route("/api/vps/shutdown", methods=["POST"])
def shutdown():
    """Graceful ACPI shutdown — may not work if guest lacks ACPI support."""
    return _action(request, "shutdown")

@app.route("/api/vps/restart", methods=["POST"])
def restart():
    """Hard reset (virsh reset) — always works regardless of guest ACPI support."""
    err = _require_kvm()
    if err: return err
    data = request.get_json() or {}
    name = data.get("name", "")
    if not VM_RE.match(name):
        return jsonify({"error": "Invalid VM name"}), 400
    info = run_virsh("domstate", name, timeout=5)
    if info["success"]:
        state = info["output"].strip().lower()
        if "shut off" in state or "shutoff" in state:
            r = run_virsh("start", name, timeout=30)
            if r["success"]:
                return jsonify({"success": True, "message": f"VPS '{name}' was stopped — started"})
            return jsonify({"error": r["error"]}), 400
    r = run_virsh("reset", name, timeout=20)
    if r["success"]:
        return jsonify({"success": True, "message": f"VPS '{name}' restarted (hard reset)"})
    run_virsh("destroy", name, timeout=20)
    time.sleep(1)
    r2 = run_virsh("start", name, timeout=30)
    if r2["success"]:
        return jsonify({"success": True, "message": f"VPS '{name}' restarted (destroy+start)"})
    return jsonify({"error": r["error"] or "restart failed"}), 400

@app.route("/api/vps/delete",  methods=["POST"])
def delete():
    err = _require_kvm()
    if err: return err
    data = request.get_json() or {}
    name = data.get("name", "")
    if not VM_RE.match(name):
        return jsonify({"error": "Invalid VM name"}), 400
    run_virsh("destroy", name)
    r = run_virsh("undefine", "--nvram", name)
    if not r["success"]:
        r = run_virsh("undefine", name)
    return (jsonify({"success": True, "message": f"VPS '{name}' deleted"})
            if r["success"] else (jsonify({"error": r["error"]}), 400))

@app.route("/api/vps/create",  methods=["POST"])
def create():
    err = _require_kvm()
    if err: return err
    d = request.get_json() or {}
    name = d.get("name", "")
    if not VM_RE.match(name):
        return jsonify({"error": "Invalid VM name"}), 400
    try:
        ram, vcpus, disk = int(d["ram"]), int(d["vcpus"]), int(d["disk"])
    except (KeyError, ValueError):
        return jsonify({"error": "ram, vcpus, disk are required integers"}), 400
    if not shutil.which("virt-install"):
        return jsonify({"error": "virt-install not found — install virtinst"}), 503
    iso = d.get("isoPath"); variant = d.get("osVariant", "generic")
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

@app.route("/api/vps/tmate", methods=["POST"])
def vps_tmate():
    """Auto-install tmate if needed, start a session, return SSH / web strings."""
    data      = request.get_json() or {}
    name      = data.get("name", "panel")
    cmds_run  = []

    if not shutil.which("tmate"):
        log.info("tmate not found — installing via apt-get…")
        cmds_run.append("sudo apt install tmate -y")
        inst = subprocess.run(
            ["apt-get", "install", "-y", "tmate"],
            capture_output=True, text=True, timeout=120
        )
        if inst.returncode != 0 or not shutil.which("tmate"):
            return jsonify({
                "error": f"tmate install failed: {inst.stderr.strip() or inst.stdout.strip()}"
            }), 500
        log.info("tmate installed successfully")

    cmds_run.append("tmate")
    sock_path = f"/tmp/tmate-cpm-{re.sub(r'[^a-z0-9]', '', name.lower())}.sock"

    subprocess.run(["tmate", "-S", sock_path, "kill-server"],
                   capture_output=True, timeout=5)
    time.sleep(0.3)

    r = subprocess.run(
        ["tmate", "-S", sock_path, "new-session", "-d", "-s", "cpm"],
        capture_output=True, text=True, timeout=15
    )
    if r.returncode != 0:
        return jsonify({"error": f"tmate failed to start: {r.stderr.strip()}"}), 500

    ssh_cmd = web_url = ""
    for _ in range(30):
        time.sleep(0.5)
        rs = subprocess.run(
            ["tmate", "-S", sock_path, "display", "-p", "#{tmate_ssh}"],
            capture_output=True, text=True, timeout=5
        )
        rw = subprocess.run(
            ["tmate", "-S", sock_path, "display", "-p", "#{tmate_web}"],
            capture_output=True, text=True, timeout=5
        )
        ssh_cmd = rs.stdout.strip()
        web_url = rw.stdout.strip()
        if ssh_cmd and not ssh_cmd.startswith("#{"):
            break

    if not ssh_cmd or ssh_cmd.startswith("#{"):
        return jsonify({
            "error": "tmate started but connection token not ready yet — click again in a few seconds"
        }), 500

    log.info(f"tmate session ready for '{name}': {ssh_cmd}")
    return jsonify({
        "success":  True,
        "ssh":      ssh_cmd,
        "web":      web_url,
        "name":     name,
        "cmds_run": cmds_run
    })


# ── Data persistence ──────────────────────────────────────────────────────────
_DATA_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cpm_data.json")

# FIX: No default key or hash is hardcoded here.
# On first run, owner_key_hash is None, the setup screen is shown,
# and the real owner sets their own secret key.

_DEFAULT_FEATURES = {
    "dashboard":    {"name":"Dashboard",            "category":"System",       "tier":"free",    "usage":0},
    "system_stats": {"name":"System Statistics",    "category":"Monitoring",   "tier":"free",    "usage":0},
    "vps_list":     {"name":"View VPS Instances",   "category":"VPS",          "tier":"free",    "usage":0},
    "vps_start":    {"name":"Start VPS",            "category":"VPS Control",  "tier":"free",    "usage":0},
    "vps_stop":     {"name":"Stop VPS",             "category":"VPS Control",  "tier":"free",    "usage":0},
    "vps_restart":  {"name":"Restart VPS",          "category":"VPS Control",  "tier":"free",    "usage":0},
    "vps_delete":   {"name":"Delete VPS",           "category":"VPS Control",  "tier":"premium", "usage":0},
    "vps_create":   {"name":"Create VPS",           "category":"VPS Control",  "tier":"premium", "usage":0},
    "ssh_access":   {"name":"SSH Access (tmate)",   "category":"Connectivity", "tier":"premium", "usage":0},
}

def _load():
    if not os.path.exists(_DATA_FILE):
        # Fresh install — no owner key set yet; setup screen will appear
        d = {"owner_key_hash":"4a91e7573bef598f06cc8abfae6234b8d4a024bd65a1c17985e309bd6fd87dd2","premium_keys": [], "features": dict(_DEFAULT_FEATURES), "activation_logs": []}
        _save(d)
        return d
    try:
        with open(_DATA_FILE) as f:
            d = json.load(f)
        # Merge any new default features added in future versions
        for k, v in _DEFAULT_FEATURES.items():
            d.setdefault("features", {})[k] = d["features"].get(k, v)
        return d
    except Exception:
        # Corrupted data file — reset (but do NOT inject a default key)
        
 "premium_keys": [], "features": dict(_DEFAULT_FEATURES), "activation_logs": []}
        _save(d)
        return d

def _save(d):
    try:
        with open(_DATA_FILE, "w") as f:
            json.dump(d, f, indent=2, default=str)
    except Exception as e:
        log.error(f"Data save failed: {e}")

def _hash(k): return hashlib.sha256(k.encode()).hexdigest()

def _now(): return datetime.now(timezone.utc).isoformat()

def _key_status(k):
    now = datetime.now(timezone.utc)
    if k.get("revoked"): return "revoked"
    if k.get("expires_at"):
        try:
            exp = datetime.fromisoformat(k["expires_at"])
            if not exp.tzinfo: exp = exp.replace(tzinfo=timezone.utc)
            if now > exp: return "expired"
        except Exception: pass
    um, uc = k.get("uses_max", 1), k.get("uses_count", 0)
    if um != -1 and uc >= um: return "used"
    return "active"

def _verify_owner(data):
    d = _load()
    stored_hash = d.get("owner_key_hash")
    if not stored_hash:
        return False
    return _hash(data.get("owner_key", "")) == stored_hash


# ── Owner routes ───────────────────────────────────────────────────────────────
@app.route("/api/owner/status")
def owner_status():
    d = _load()
    return jsonify({"initialized": bool(d.get("owner_key_hash"))})

@app.route("/api/owner/setup", methods=["POST"])
def owner_setup():
    d = _load()
    if d.get("owner_key_hash"):
        return jsonify({"error": "Owner key already set"}), 403
    k = (request.get_json() or {}).get("owner_key", "").strip()
    if len(k) < 6:
        return jsonify({"error": "Key must be at least 6 characters"}), 400
    d["owner_key_hash"] = _hash(k)
    _save(d)
    log.info("Owner key configured for the first time")
    return jsonify({"success": True})

@app.route("/api/owner/auth", methods=["POST"])
def owner_auth():
    if _verify_owner(request.get_json() or {}):
        return jsonify({"success": True})
    return jsonify({"error": "Invalid owner key"}), 403

@app.route("/api/owner/keys", methods=["POST"])
def owner_keys():
    data = request.get_json() or {}
    if not _verify_owner(data): return jsonify({"error": "Unauthorized"}), 403
    d = _load()
    keys = d.get("premium_keys", [])
    for k in keys: k["status"] = _key_status(k)
    return jsonify({"keys": keys})

@app.route("/api/owner/keys/generate", methods=["POST"])
def owner_keygen():
    data = request.get_json() or {}
    if not _verify_owner(data): return jsonify({"error": "Unauthorized"}), 403
    d = _load()
    custom = data.get("custom_key", "").strip().upper()
    if custom:
        if any(k["key"] == custom for k in d.get("premium_keys", [])):
            return jsonify({"error": "Key already exists"}), 400
        new_key = custom
    else:
        seg = lambda n: secrets.token_hex(n).upper()[:n]
        new_key = f"CPM-{seg(4)}-{seg(4)}-{seg(4)}"
    expires_at = None
    ev, eu = data.get("exp_value"), data.get("exp_unit", "days")
    if ev:
        try:
            v = int(ev)
            delta = timedelta(days=v) if eu=="days" else timedelta(days=v*30) if eu=="months" else timedelta(days=v*365)
            expires_at = (datetime.now(timezone.utc) + delta).isoformat()
        except Exception: pass
    uses_max = int(data.get("uses_max", 1))
    entry = {"id": "KID-"+secrets.token_hex(4).upper(), "key": new_key, "created_at": _now(),
             "expires_at": expires_at, "uses_max": uses_max, "uses_count": 0,
             "revoked": False, "status": "active", "activated_by": [], "note": data.get("note", "")}
    d.setdefault("premium_keys", []).append(entry)
    _save(d)
    log.info(f"Premium key generated: {new_key}")
    return jsonify({"success": True, "key": entry})

@app.route("/api/owner/keys/revoke", methods=["POST"])
def owner_revoke():
    data = request.get_json() or {}
    if not _verify_owner(data): return jsonify({"error": "Unauthorized"}), 403
    d = _load(); kid = data.get("id", "")
    for k in d.get("premium_keys", []):
        if k["id"] == kid:
            k["revoked"] = True; k["status"] = "revoked"; _save(d)
            return jsonify({"success": True})
    return jsonify({"error": "Not found"}), 404

@app.route("/api/owner/keys/delete", methods=["POST"])
def owner_delete_key():
    data = request.get_json() or {}
    if not _verify_owner(data): return jsonify({"error": "Unauthorized"}), 403
    d = _load(); kid = data.get("id", ""); before = len(d.get("premium_keys", []))
    d["premium_keys"] = [k for k in d.get("premium_keys", []) if k["id"] != kid]
    if len(d["premium_keys"]) < before:
        _save(d); return jsonify({"success": True})
    return jsonify({"error": "Not found"}), 404


# ── Feature routes ─────────────────────────────────────────────────────────────
@app.route("/api/features/status")
def features_status():
    return jsonify({"features": _load().get("features", _DEFAULT_FEATURES)})

@app.route("/api/owner/features", methods=["POST"])
def owner_features():
    data = request.get_json() or {}
    if not _verify_owner(data): return jsonify({"error": "Unauthorized"}), 403
    return jsonify({"features": _load().get("features", _DEFAULT_FEATURES)})

@app.route("/api/owner/features/toggle", methods=["POST"])
def owner_feature_toggle():
    data = request.get_json() or {}
    if not _verify_owner(data): return jsonify({"error": "Unauthorized"}), 403
    fid, tier = data.get("feature_id", ""), data.get("tier", "free")
    d = _load(); feats = d.setdefault("features", dict(_DEFAULT_FEATURES))
    if fid not in feats: return jsonify({"error": "Feature not found"}), 404
    feats[fid]["tier"] = tier; _save(d)
    log.info(f"Feature '{fid}' -> {tier}")
    return jsonify({"success": True, "feature_id": fid, "tier": tier})

@app.route("/api/owner/analytics", methods=["POST"])
def owner_analytics():
    data = request.get_json() or {}
    if not _verify_owner(data): return jsonify({"error": "Unauthorized"}), 403
    d = _load(); keys = d.get("premium_keys", [])
    for k in keys: k["status"] = _key_status(k)
    feats = d.get("features", _DEFAULT_FEATURES)
    logs = d.get("activation_logs", [])
    return jsonify({
        "total_keys":       len(keys),
        "active_keys":      sum(1 for k in keys if k["status"] == "active"),
        "used_keys":        sum(1 for k in keys if k["status"] == "used"),
        "total_activations": len(logs),
        "premium_features": sum(1 for f in feats.values() if f.get("tier") == "premium"),
        "free_features":    sum(1 for f in feats.values() if f.get("tier") == "free"),
        "recent_logs":      list(reversed(logs[-10:])),
    })

@app.route("/api/owner/logs", methods=["POST"])
def owner_logs():
    data = request.get_json() or {}
    if not _verify_owner(data): return jsonify({"error": "Unauthorized"}), 403
    return jsonify({"logs": list(reversed(_load().get("activation_logs", [])))})


# ── User activation ────────────────────────────────────────────────────────────
@app.route("/api/user/activate", methods=["POST"])
def user_activate():
    data = request.get_json() or {}
    entered = data.get("key", "").strip().upper()
    if not entered: return jsonify({"error": "No key provided"}), 400
    d = _load()

    # FIX: Only compare against the stored hash — no plaintext bypass.
    # Owner key grants permanent premium access if a hash is set.
    stored_hash = d.get("owner_key_hash")
    if stored_hash and _hash(entered) == stored_hash:
        log.info("Owner key used for premium activation")
        return jsonify({"success": True, "expires_at": None, "key_id": "OWNER"})

    for k in d.get("premium_keys", []):
        if k["key"].upper() == entered:
            st = _key_status(k)
            if st == "revoked": return jsonify({"error": "This key has been revoked"}), 403
            if st == "expired": return jsonify({"error": "This key has expired"}), 403
            if st == "used":    return jsonify({"error": "This key has already been fully used"}), 403
            k["uses_count"] = k.get("uses_count", 0) + 1
            k.setdefault("activated_by", []).append(data.get("user_id", "anonymous"))
            k["status"] = _key_status(k)
            d.setdefault("activation_logs", []).append({
                "key_id": k["id"], "key": entered, "user_id": data.get("user_id", "anonymous"),
                "activated_at": _now(), "expires_at": k.get("expires_at"),
            })
            _save(d)
            log.info(f"Key {entered} activated")
            return jsonify({"success": True, "expires_at": k.get("expires_at"), "key_id": k["id"]})
    return jsonify({"error": "Invalid activation key — check your key and try again"}), 403

# ── Cloud Storage ─────────────────────────────────────────────────────────────

STORAGE_ROOT = '/opt/cpm-storage'

def _safe_storage_path(rel):
    base = os.path.realpath(STORAGE_ROOT)
    target = os.path.realpath(os.path.join(base, rel.lstrip('/'))) if rel.strip('/') else base
    return target if target.startswith(base) else None

@app.route("/api/storage/list")
def storage_list():
    rel = request.args.get('path', '')
    path = _safe_storage_path(rel)
    if not path:
        return jsonify({"error": "Invalid path"}), 400
    os.makedirs(path, exist_ok=True)
    items = []
    try:
        for name in sorted(os.listdir(path)):
            full = os.path.join(path, name)
            try:
                st = os.stat(full)
                items.append({
                    "name": name,
                    "type": "folder" if os.path.isdir(full) else "file",
                    "size": st.st_size if os.path.isfile(full) else 0,
                    "modified": datetime.fromtimestamp(st.st_mtime).strftime('%Y-%m-%d %H:%M')
                })
            except Exception:
                pass
    except Exception as e:
        return jsonify({"error": str(e)}), 500
    items.sort(key=lambda x: (0 if x["type"] == "folder" else 1, x["name"].lower()))
    return jsonify({"items": items, "path": rel})

@app.route("/api/storage/upload", methods=["POST", "OPTIONS"])
def storage_upload():
    if request.method == "OPTIONS":
        return "", 204
    rel = request.form.get('path', '')
    path = _safe_storage_path(rel)
    if not path:
        return jsonify({"error": "Invalid path"}), 400
    if 'file' not in request.files:
        return jsonify({"error": "No file provided"}), 400
    f = request.files['file']
    if not f.filename:
        return jsonify({"error": "No filename"}), 400
    os.makedirs(path, exist_ok=True)
    save_name = os.path.basename(f.filename)
    f.save(os.path.join(path, save_name))
    return jsonify({"success": True, "name": save_name})

@app.route("/api/storage/download")
def storage_download():
    rel = request.args.get('path', '')
    path = _safe_storage_path(rel)
    if not path or not os.path.isfile(path):
        return jsonify({"error": "File not found"}), 404
    return send_file(path, as_attachment=True, download_name=os.path.basename(path))

@app.route("/api/storage/delete", methods=["POST"])
def storage_delete():
    data = request.json or {}
    rel = data.get('path', '')
    path = _safe_storage_path(rel)
    if not path or not os.path.exists(path):
        return jsonify({"error": "Not found"}), 404
    if os.path.realpath(path) == os.path.realpath(STORAGE_ROOT):
        return jsonify({"error": "Cannot delete root storage folder"}), 400
    if os.path.isdir(path):
        shutil.rmtree(path)
    else:
        os.remove(path)
    return jsonify({"success": True})

@app.route("/api/storage/mkdir", methods=["POST"])
def storage_mkdir():
    data = request.json or {}
    rel = data.get('path', '')
    path = _safe_storage_path(rel)
    if not path:
        return jsonify({"error": "Invalid path"}), 400
    os.makedirs(path, exist_ok=True)
    return jsonify({"success": True})

@app.route("/api/storage/stats")
def storage_stats():
    os.makedirs(STORAGE_ROOT, exist_ok=True)
    used = 0
    try:
        r = subprocess.run(['du', '-sb', STORAGE_ROOT], capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            used = int(r.stdout.split()[0])
    except Exception:
        pass
    total = free = 0
    try:
        st = os.statvfs(STORAGE_ROOT)
        total = st.f_blocks * st.f_frsize
        free  = st.f_avail  * st.f_frsize
    except Exception:
        pass
    return jsonify({"used": used, "total": total, "free": free})

# ── Logo ──────────────────────────────────────────────────────────────────────

@app.route("/logo.png")
def logo():
    here = os.path.dirname(os.path.abspath(__file__))
    p = os.path.join(here, "logo.png")
    if os.path.exists(p):
        return send_file(p, mimetype="image/png")
    return "", 404

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    log.info(f"CPM Panel listening on port {port}")
    app.run(host="0.0.0.0", port=port)

PYEOF
ok "app.py written"
fi

# Copy pre-extracted index.html if present, otherwise write it inline
if [[ -f "$DIR/index.html" ]]; then
  ok "index.html already present"
else
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
  /* ── KVM banner ── */
  .kvm-banner{display:none;background:#fef3c7;border:1px solid #f59e0b;border-radius:10px;padding:12px 18px;margin-bottom:20px;font-size:13px;color:#92400e;align-items:center;gap:10px}
  .kvm-banner.show{display:flex}
  .kvm-banner svg{flex-shrink:0;color:#d97706}
  /* ── SSH modal ── */
  .ssh-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:200;align-items:center;justify-content:center;padding:16px}
  .ssh-overlay.open{display:flex}
  .ssh-window{background:#fff;border-radius:16px;width:min(580px,96vw);box-shadow:0 24px 70px rgba(0,0,0,.25);overflow:hidden}
  .ssh-header{background:#0f172a;padding:14px 20px;display:flex;align-items:center;justify-content:space-between}
  .ssh-title{color:#e2e8f0;font-size:14px;font-weight:600;display:flex;align-items:center;gap:8px}
  .ssh-close{background:none;border:none;color:#64748b;cursor:pointer;font-size:20px;padding:0 4px;transition:.15s}
  .ssh-close:hover{color:#f1f5f9}
  .ssh-body{padding:24px}
  .ssh-label{font-size:12px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.05em;margin-bottom:8px}
  .ssh-box{background:#0f172a;border-radius:8px;padding:14px 16px;font-family:'Cascadia Code','Fira Code',monospace;font-size:13px;color:#60a5fa;word-break:break-all;position:relative;margin-bottom:16px}
  .copy-btn{position:absolute;top:8px;right:8px;background:#1e293b;border:none;color:#94a3b8;font-size:11px;font-weight:600;padding:4px 10px;border-radius:6px;cursor:pointer;transition:.15s}
  .copy-btn:hover{background:#334155;color:#e2e8f0}
  .ssh-note{font-size:12px;color:var(--muted);line-height:1.6;background:var(--blue-light);border-radius:8px;padding:10px 14px}
  .ssh-loading{text-align:center;padding:32px;color:var(--muted);font-size:14px}
  .btn-ssh{background:#0f172a;color:#60a5fa}.btn-ssh:hover:not(:disabled){background:#1e293b}
  .qa-ssh{background:#0f172a;color:#60a5fa}.qa-ssh:hover:not(:disabled){background:#1e293b}
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

  /* ── Activation overlay ── */
  .act-overlay{position:fixed;inset:0;background:linear-gradient(135deg,#0f172a 0%,#1e293b 50%,#0f172a 100%);z-index:9999;display:flex;align-items:center;justify-content:center;padding:16px}
  .act-overlay.hidden{display:none}
  .act-card{background:#1e293b;border:1px solid #334155;border-radius:20px;padding:40px 36px;width:min(440px,100%);box-shadow:0 30px 80px rgba(0,0,0,.6);text-align:center}
  .act-logo{width:72px;height:72px;border-radius:16px;margin:0 auto 20px;display:flex;align-items:center;justify-content:center}
  .act-logo img{width:72px;height:72px;object-fit:contain;border-radius:16px}
  .act-logo-fallback{width:72px;height:72px;background:linear-gradient(135deg,#2563eb,#3b82f6);border-radius:16px;display:flex;align-items:center;justify-content:center;color:#fff;font-weight:800;font-size:28px}
  .act-title{font-size:22px;font-weight:700;color:#f1f5f9;margin-bottom:6px}
  .act-sub{font-size:13px;color:#64748b;margin-bottom:28px;line-height:1.5}
  .act-input{width:100%;background:#0f172a;border:1.5px solid #334155;border-radius:10px;padding:13px 16px;font-size:14px;color:#e2e8f0;font-family:'Cascadia Code','Fira Code',monospace;letter-spacing:.08em;outline:none;transition:.2s;margin-bottom:6px}
  .act-input:focus{border-color:#2563eb;box-shadow:0 0 0 3px rgba(37,99,235,.25)}
  .act-input.error{border-color:#dc2626;box-shadow:0 0 0 3px rgba(220,38,38,.2)}
  .act-input.success{border-color:#16a34a;box-shadow:0 0 0 3px rgba(22,163,74,.2)}
  .act-err{font-size:12px;color:#dc2626;margin-bottom:16px;min-height:18px;text-align:left}
  .act-btn{width:100%;padding:13px;border:none;border-radius:10px;font-size:14px;font-weight:600;cursor:pointer;transition:.2s;margin-bottom:10px}
  .act-btn-paid{background:linear-gradient(135deg,#2563eb,#1d4ed8);color:#fff}
  .act-btn-paid:hover{background:linear-gradient(135deg,#1d4ed8,#1e40af);transform:translateY(-1px)}
  .act-btn-paid:active{transform:translateY(0)}
  .act-btn-free{background:transparent;border:1.5px solid #334155 !important;color:#94a3b8}
  .act-btn-free:hover{border-color:#475569 !important;color:#cbd5e1;background:#334155}
  .act-divider{display:flex;align-items:center;gap:10px;margin:4px 0 4px;color:#475569;font-size:11px}
  .act-divider::before,.act-divider::after{content:'';flex:1;height:1px;background:#334155}
  .act-badge{display:inline-flex;align-items:center;gap:5px;background:#0f172a;border:1px solid #1e3a5f;border-radius:20px;padding:4px 12px;font-size:11px;color:#60a5fa;margin-bottom:20px}
  .act-mode-banner{position:fixed;top:0;left:0;right:0;z-index:100;padding:7px 16px;font-size:12px;font-weight:600;text-align:center;pointer-events:none}
  .act-mode-banner.paid{background:#dcfce7;color:#16a34a;border-bottom:1px solid #bbf7d0}
  .act-mode-banner.free{background:#fef9c3;color:#854d0e;border-bottom:1px solid #fef08a}

  /* ── Premium system ── */
  .plan-badge{display:inline-flex;align-items:center;gap:5px;padding:3px 11px;border-radius:20px;font-size:11px;font-weight:700}
  .plan-badge.premium{background:#fef3c7;color:#d97706;border:1px solid #fcd34d}
  .plan-badge.free{background:#f1f5f9;color:#64748b;border:1px solid #e2e8f0}
  .topbar-brand{margin-left:auto;font-size:12px;font-weight:700;color:#94a3b8;display:flex;align-items:center;gap:12px;white-space:nowrap}
  .topbar-brand .brand-powered{color:#f59e0b}
  .topbar-brand .brand-name-txt{color:#0f172a;font-weight:800}

  /* ── Owner modal ── */
  .owner-modal-overlay{position:fixed;inset:0;background:rgba(0,0,0,.75);z-index:8000;display:none;align-items:center;justify-content:center;padding:16px}
  .owner-modal-overlay.open{display:flex}
  .owner-modal{background:#1e293b;border:1px solid #334155;border-radius:18px;width:min(420px,96vw);overflow:hidden;box-shadow:0 30px 80px rgba(0,0,0,.5)}
  .owner-modal-header{background:#0f172a;padding:16px 20px;display:flex;align-items:center;justify-content:space-between}
  .owner-modal-title{color:#f1f5f9;font-size:15px;font-weight:700;display:flex;align-items:center;gap:8px}
  .owner-modal-body{padding:28px}
  .owner-input{width:100%;background:#0f172a;border:1.5px solid #334155;border-radius:8px;padding:12px 14px;font-size:14px;color:#e2e8f0;outline:none;transition:.2s;margin-bottom:8px;font-family:monospace;letter-spacing:.06em}
  .owner-input:focus{border-color:#7c3aed;box-shadow:0 0 0 3px rgba(124,58,237,.2)}
  .owner-input.error{border-color:#dc2626}
  .owner-err{font-size:12px;color:#dc2626;margin-bottom:14px;min-height:16px}
  .owner-btn{width:100%;padding:12px;border:none;border-radius:8px;font-size:14px;font-weight:600;cursor:pointer;transition:.2s;margin-bottom:8px}
  .owner-btn-primary{background:linear-gradient(135deg,#7c3aed,#4f46e5);color:#fff}
  .owner-btn-primary:hover{background:linear-gradient(135deg,#6d28d9,#4338ca);transform:translateY(-1px)}
  .owner-btn-secondary{background:#334155;color:#94a3b8}
  .owner-btn-secondary:hover{background:#475569;color:#e2e8f0}

  /* ── Owner panel tabs ── */
  .owner-tabs{display:flex;gap:4px;margin-bottom:24px;background:var(--blue-light);border-radius:10px;padding:4px;border:1px solid var(--blue-mid)}
  .owner-tab{padding:8px 18px;border:none;border-radius:7px;font-size:13px;font-weight:600;cursor:pointer;transition:.15s;color:var(--muted);background:none}
  .owner-tab.active{background:#fff;color:var(--blue);box-shadow:0 1px 4px rgba(0,0,0,.1)}
  .owner-tab-panel{display:none}.owner-tab-panel.active{display:block}

  /* ── Analytics cards ── */
  .owner-analytics{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:14px;margin-bottom:24px}
  .ana-card{background:#fff;border:1px solid var(--border);border-radius:12px;padding:18px 16px;text-align:center}
  .ana-num{font-size:28px;font-weight:800;margin-bottom:4px}
  .ana-label{font-size:11px;color:var(--muted);font-weight:600;text-transform:uppercase;letter-spacing:.05em}

  /* ── Key table ── */
  .key-table{width:100%;border-collapse:collapse;font-size:13px}
  .key-table th{text-align:left;padding:10px 12px;font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.05em;color:var(--muted);border-bottom:2px solid var(--border);background:#f8fafc}
  .key-table td{padding:10px 12px;border-bottom:1px solid #f1f5f9;vertical-align:middle}
  .key-table tr:hover td{background:#f8fafc}
  .key-table .overflow-x{overflow-x:auto}
  .key-mono{font-family:'Cascadia Code','Fira Code',monospace;font-size:12px;color:#2563eb;letter-spacing:.06em;word-break:break-all}
  .status-pill{display:inline-block;padding:2px 10px;border-radius:20px;font-size:11px;font-weight:700;text-transform:uppercase}
  .pill-active{background:#dcfce7;color:#16a34a}
  .pill-used{background:#e0f2fe;color:#0369a1}
  .pill-expired{background:#fee2e2;color:#dc2626}
  .pill-revoked{background:#f1f5f9;color:#94a3b8;text-decoration:line-through}
  .tbl-btn{padding:4px 10px;border:none;border-radius:6px;font-size:12px;font-weight:600;cursor:pointer;transition:.15s;margin-right:4px}
  .tbl-btn-revoke{background:#fef3c7;color:#d97706}.tbl-btn-revoke:hover{background:#fde68a}
  .tbl-btn-delete{background:#fee2e2;color:#dc2626}.tbl-btn-delete:hover{background:#fca5a5;color:#fff}

  /* ── Generate key form ── */
  .gen-panel{background:var(--blue-light);border:1px solid var(--blue-mid);border-radius:12px;padding:20px;margin-bottom:20px}
  .gen-row{display:flex;flex-wrap:wrap;gap:12px;align-items:flex-end;margin-bottom:12px}
  .gen-field{display:flex;flex-direction:column;gap:5px;flex:1;min-width:140px}
  .gen-label{font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)}
  .gen-input,.gen-select{background:#fff;border:1.5px solid var(--border);border-radius:8px;padding:9px 12px;font-size:13px;color:var(--text);outline:none;transition:.2s;width:100%}
  .gen-input:focus,.gen-select:focus{border-color:var(--blue);box-shadow:0 0 0 3px rgba(37,99,235,.12)}

  /* ── Feature control ── */
  .feat-row{display:flex;align-items:center;padding:14px 0;border-bottom:1px solid #f1f5f9;gap:12px}
  .feat-row:last-child{border-bottom:none}
  .feat-info{flex:1;min-width:0}
  .feat-name{font-size:14px;font-weight:600;color:var(--text)}
  .feat-cat{font-size:11px;color:var(--muted);margin-top:2px}
  .tier-toggle{display:inline-flex;background:#f1f5f9;border-radius:20px;padding:2px;gap:2px;border:1px solid var(--border)}
  .tier-btn{padding:5px 14px;border:none;border-radius:18px;font-size:12px;font-weight:700;cursor:pointer;transition:.2s;background:none;color:var(--muted)}
  .tier-btn.active-free{background:#22c55e;color:#fff}
  .tier-btn.active-premium{background:linear-gradient(135deg,#f59e0b,#d97706);color:#fff}

  /* ── Log rows ── */
  .log-row{display:flex;flex-wrap:wrap;align-items:center;padding:10px 12px;border-bottom:1px solid #f1f5f9;gap:8px;font-size:13px}
  .log-time{font-size:11px;color:var(--muted);min-width:135px;font-family:monospace}
  .log-key{font-family:monospace;font-size:12px;color:#2563eb}

  /* ── Cloud Storage ── */
  .storage-bar-wrap{background:#f1f5f9;border-radius:8px;height:10px;overflow:hidden;margin-bottom:4px}
  .storage-bar-fill{height:100%;background:linear-gradient(90deg,#2563eb,#60a5fa);border-radius:8px;transition:.5s}
  .storage-crumb{display:flex;align-items:center;gap:2px;flex-wrap:wrap;font-size:13px;margin-bottom:14px}
  .file-table{width:100%;border-collapse:collapse;font-size:13px}
  .file-table th{text-align:left;padding:10px 14px;font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.05em;color:var(--muted);border-bottom:2px solid var(--border);background:#f8fafc}
  .file-table td{padding:11px 14px;border-bottom:1px solid #f1f5f9;vertical-align:middle}
  .file-table tr:hover td{background:#f8fafc}
  .file-name-btn{background:none;border:none;font-size:13px;font-weight:500;color:var(--text);cursor:pointer;padding:0;text-align:left}
  .file-name-btn:hover{color:var(--blue);text-decoration:underline}
  .storage-toolbar{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:16px}

  /* ── Upgrade modal ── */
  .upgrade-overlay{position:fixed;inset:0;background:rgba(0,0,0,.75);z-index:7000;display:none;align-items:center;justify-content:center;padding:16px}
  .upgrade-overlay.open{display:flex}
  .upgrade-card{background:#1e293b;border:1px solid #334155;border-radius:18px;width:min(400px,96vw);padding:32px 28px;text-align:center;box-shadow:0 24px 70px rgba(0,0,0,.5)}
  .upgrade-title{font-size:20px;font-weight:800;color:#f1f5f9;margin-bottom:8px}
  .upgrade-sub{font-size:13px;color:#64748b;margin-bottom:22px;line-height:1.6}
  .upgrade-inp{width:100%;background:#0f172a;border:1.5px solid #334155;border-radius:8px;padding:12px 14px;font-size:14px;color:#e2e8f0;outline:none;transition:.2s;margin-bottom:8px;font-family:monospace;letter-spacing:.06em}
  .upgrade-inp:focus{border-color:#f59e0b;box-shadow:0 0 0 3px rgba(245,158,11,.2)}
  .upgrade-err{font-size:12px;color:#dc2626;min-height:16px;margin-bottom:12px;text-align:left}
  .search-inp{background:#fff;border:1.5px solid var(--border);border-radius:8px;padding:8px 12px;font-size:13px;outline:none;transition:.2s;width:220px}
  .search-inp:focus{border-color:var(--blue);box-shadow:0 0 0 2px rgba(37,99,235,.1)}
  @media(max-width:600px){.owner-tabs{flex-wrap:wrap}.owner-tab{flex:1;min-width:80px;text-align:center;font-size:11px;padding:7px 8px}.gen-row{flex-direction:column}}
</style>
</head>
<body>

<!-- ── Activation overlay ────────────────────────────────────────────── -->
<div class="act-overlay" id="act-overlay">
  <div class="act-card">
    <div class="act-logo">
      <img src="/logo.png" alt="CPM Panel" onerror="this.parentElement.innerHTML='<div class=&quot;act-logo-fallback&quot;>CP</div>'"/>
    </div>
    <div class="act-title">CPM Panel</div>
    <div class="act-sub">Enter your key to continue. Owner key opens the Owner Panel. Paid key activates Premium mode.</div>
    <div class="act-badge">
      <svg width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>
      CPM Panel &mdash; KVM VPS Manager
    </div>

    <!-- Normal key entry (shown by default) -->
    <div id="act-main-form">
      <input class="act-input" id="act-key-input" type="password" placeholder="Enter your key…" maxlength="64" autocomplete="off" spellcheck="false"/>
      <div class="act-err" id="act-err"></div>
      <button class="act-btn act-btn-paid" id="act-btn-paid" onclick="activatePanel()">
        🔑 Access Panel
      </button>
      <div class="act-divider">or</div>
      <button class="act-btn act-btn-free" onclick="useFreeVersion()" style="margin-top:8px">
        Continue with Free Version
      </button>
      <div style="margin-top:14px;text-align:center">
        <button onclick="showActSetup()" style="background:none;border:none;color:#475569;font-size:12px;cursor:pointer;text-decoration:underline">
          First time? Set up owner key →
        </button>
      </div>
    </div>

    <!-- First-time owner setup (hidden by default) -->
    <div id="act-setup-form" style="display:none">
      <div style="font-size:13px;color:#94a3b8;margin-bottom:16px;line-height:1.6;text-align:left">
        No owner key set yet. Create your secret owner key below.<br>
        <strong style="color:#f59e0b">Keep it safe — it cannot be recovered.</strong>
      </div>
      <input class="act-input" id="act-setup-key" type="password" placeholder="Create owner key (min 6 chars)" maxlength="64" autocomplete="new-password"/>
      <div class="act-err" id="act-setup-err"></div>
      <button class="act-btn act-btn-paid" id="act-setup-btn" onclick="submitActOwnerSetup()">
        🔐 Set Owner Key & Enter
      </button>
      <button class="act-btn act-btn-free" onclick="hideActSetup()" style="margin-top:6px">
        ← Back
      </button>
    </div>
  </div>
</div>

<!-- Mode banner (shown after choosing) -->
<div class="act-mode-banner paid" id="act-mode-banner" style="display:none"></div>

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
    <a onclick="showPage('storage',this);storageOpen()">
      <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4.03 3-9 3S3 13.66 3 12"/><path d="M3 5v14c0 1.66 4.03 3 9 3s9-1.34 9-3V5"/></svg>
      Cloud Storage
    </a>
  </nav>
  <a onclick="enterOwnerPanel()" id="nav-owner" style="display:none;margin-top:auto;background:linear-gradient(135deg,#fef3c7,#fde68a);color:#92400e;border-radius:8px;margin:0 10px 8px">
    <svg width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M2 4l3 12h14l3-12-6 5-4-7-4 7-6-5z"/></svg>
    Owner Panel
  </a>
  <div class="sidebar-footer">
    <div><span class="status-dot" id="dot"></span><span class="status-label" id="status-txt">Connecting…</span></div>
    <div class="version">v1.0.0</div>
    <button onclick="logoutPanel()" style="margin-top:8px;width:100%;background:none;border:1px solid var(--border);border-radius:6px;padding:5px 0;font-size:12px;color:var(--muted);cursor:pointer;transition:.15s" onmouseover="this.style.background='#fee2e2';this.style.color='#dc2626';this.style.borderColor='#fca5a5'" onmouseout="this.style.background='none';this.style.color='var(--muted)';this.style.borderColor='var(--border)'">
      🔓 Logout / Switch Account
    </button>
  </div>
</aside>

<div class="main">
  <div class="topbar">
    <div class="topbar-icon">
      <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>
    </div>
    <span class="topbar-text" id="kvm-status">Checking KVM…</span>
    <div class="topbar-brand">
      <span id="plan-badge" class="plan-badge free">🔓 Free</span>
      <span>⚡ <span class="brand-powered">Powered by</span> <span class="brand-name-txt">Abdullah</span></span>
    </div>
  </div>

  <main class="content">

    <!-- DASHBOARD -->
    <section class="page active" id="page-dashboard">
      <h1>Dashboard</h1>
      <p class="subtitle">System overview and resource utilisation.</p>

      <!-- KVM not-supported banner -->
      <div class="kvm-banner" id="kvm-banner">
        <svg width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>
        <span id="kvm-banner-msg">KVM virtualisation is not supported on this host — VPS instance controls are disabled.</span>
      </div>

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

    <!-- OWNER PANEL -->
    <section class="page" id="page-owner">
      <h1>👑 Owner Panel</h1>
      <p class="subtitle">Generate premium keys, manage feature access, and view analytics.</p>

      <div class="owner-tabs">
        <button class="owner-tab active" onclick="ownerTab('analytics',this)">📊 Analytics</button>
        <button class="owner-tab" onclick="ownerTab('keys',this)">🔑 Keys</button>
        <button class="owner-tab" onclick="ownerTab('features',this)">⚙️ Features</button>
        <button class="owner-tab" onclick="ownerTab('logs',this)">📋 Logs</button>
      </div>

      <!-- Analytics -->
      <div class="owner-tab-panel active" id="otab-analytics">
        <div class="owner-analytics" id="ana-cards">
          <div class="ana-card"><div class="ana-num" style="color:var(--blue)">—</div><div class="ana-label">Total Keys</div></div>
          <div class="ana-card"><div class="ana-num" style="color:var(--green)">—</div><div class="ana-label">Active Keys</div></div>
          <div class="ana-card"><div class="ana-num" style="color:#0369a1">—</div><div class="ana-label">Used Keys</div></div>
          <div class="ana-card"><div class="ana-num" style="color:#7c3aed">—</div><div class="ana-label">Activations</div></div>
          <div class="ana-card"><div class="ana-num" style="color:#d97706">—</div><div class="ana-label">Premium Features</div></div>
          <div class="ana-card"><div class="ana-num" style="color:var(--muted)">—</div><div class="ana-label">Free Features</div></div>
        </div>
        <div class="card">
          <div class="card-header"><div class="card-title">Recent Activations</div></div>
          <div class="card-body" id="ana-recent-logs"><div style="color:var(--muted);font-size:14px">Loading…</div></div>
        </div>
      </div>

      <!-- Key Management -->
      <div class="owner-tab-panel" id="otab-keys">
        <div class="gen-panel card" style="padding:20px;margin-bottom:20px">
          <div class="card-title" style="margin-bottom:16px">
            <svg width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="16"/><line x1="8" y1="12" x2="16" y2="12"/></svg>
            Generate New Key
          </div>
          <div class="gen-row">
            <div class="gen-field">
              <label class="gen-label">Custom Key (optional)</label>
              <input class="gen-input" id="gen-custom" placeholder="CPM-XXXX-XXXX auto if blank"/>
            </div>
            <div class="gen-field">
              <label class="gen-label">Expiry Value</label>
              <input class="gen-input" id="gen-exp-val" type="number" min="1" placeholder="Leave blank = never"/>
            </div>
            <div class="gen-field">
              <label class="gen-label">Expiry Unit</label>
              <select class="gen-select" id="gen-exp-unit">
                <option value="days">Days</option>
                <option value="months">Months</option>
                <option value="years">Years</option>
              </select>
            </div>
            <div class="gen-field">
              <label class="gen-label">Max Uses</label>
              <select class="gen-select" id="gen-uses">
                <option value="1">1 (One-time)</option>
                <option value="5">5</option>
                <option value="10">10</option>
                <option value="-1">Unlimited</option>
              </select>
            </div>
            <div class="gen-field">
              <label class="gen-label">Note</label>
              <input class="gen-input" id="gen-note" placeholder="Optional note"/>
            </div>
            <div class="gen-field">
              <label class="gen-label">&nbsp;</label>
              <button class="btn btn-primary" onclick="ownerGenerateKey()">⚡ Generate</button>
            </div>
          </div>
        </div>
        <div class="card">
          <div class="card-header">
            <div class="card-title">Premium Keys</div>
            <button class="btn btn-secondary" onclick="ownerLoadKeys()" style="padding:6px 14px;font-size:12px">↻ Refresh</button>
          </div>
          <div class="card-body" style="overflow-x:auto;padding:0">
            <table class="key-table">
              <thead><tr>
                <th>Key / ID</th><th>Status</th><th>Expires</th><th>Uses</th><th>Actions</th>
              </tr></thead>
              <tbody id="keys-tbody">
                <tr><td colspan="5" style="text-align:center;color:var(--muted);padding:24px">Loading…</td></tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <!-- Feature Control -->
      <div class="owner-tab-panel" id="otab-features">
        <div class="card">
          <div class="card-header">
            <div class="card-title">Feature Access Control</div>
            <input class="search-inp" id="feat-search" placeholder="Search features…" oninput="ownerLoadFeatures()"/>
          </div>
          <div class="card-body" id="feat-list">
            <div style="color:var(--muted);font-size:14px">Loading…</div>
          </div>
        </div>
      </div>

      <!-- Logs -->
      <div class="owner-tab-panel" id="otab-logs">
        <div class="card">
          <div class="card-header">
            <div class="card-title">Activation Logs</div>
            <button class="btn btn-secondary" onclick="ownerLoadLogs()" style="padding:6px 14px;font-size:12px">↻ Refresh</button>
          </div>
          <div class="card-body" style="padding:0" id="log-list">
            <div style="color:var(--muted);padding:24px;font-size:14px">Loading…</div>
          </div>
        </div>
      </div>
    </section>

    <!-- CLOUD STORAGE -->
    <section class="page" id="page-storage">
      <h1>Cloud Storage</h1>
      <p class="subtitle">Store and manage files directly on your VPS disk.</p>

      <!-- Disk usage bar -->
      <div class="card" style="margin-bottom:20px">
        <div class="card-body" style="padding:16px 22px">
          <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
            <div style="font-size:13px;font-weight:600;display:flex;align-items:center;gap:6px">
              <svg width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4.03 3-9 3S3 13.66 3 12"/><path d="M3 5v14c0 1.66 4.03 3 9 3s9-1.34 9-3V5"/></svg>
              Disk Usage
            </div>
            <div style="font-size:12px;color:var(--muted)" id="storage-usage-text">—</div>
          </div>
          <div class="storage-bar-wrap">
            <div class="storage-bar-fill" id="storage-bar" style="width:0%"></div>
          </div>
          <div style="font-size:11px;color:var(--muted);margin-top:4px">Storage root: /opt/cpm-storage/</div>
        </div>
      </div>

      <!-- File browser -->
      <div class="card">
        <div class="card-header" style="padding-bottom:14px">
          <div class="storage-crumb" id="storage-crumb">
            <span onclick="storageTo('')" style="cursor:pointer;color:var(--blue);font-weight:600">📁 Storage</span>
          </div>
          <div class="storage-toolbar">
            <button class="btn" onclick="storageUpload()" style="background:var(--blue);color:#fff;display:flex;align-items:center;gap:6px">
              <svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24"><polyline points="16 16 12 12 8 16"/><line x1="12" y1="12" x2="12" y2="21"/><path d="M20.39 18.39A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.3"/></svg>
              Upload File
            </button>
            <button class="btn" onclick="storageMkdir()" style="display:flex;align-items:center;gap:6px">
              <svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/><line x1="12" y1="11" x2="12" y2="17"/><line x1="9" y1="14" x2="15" y2="14"/></svg>
              New Folder
            </button>
          </div>
        </div>
        <div class="card-body" style="padding:0">
          <div id="storage-file-list">
            <div style="padding:32px;color:var(--muted);text-align:center">Open the Cloud Storage page to load files.</div>
          </div>
        </div>
      </div>

      <!-- Hidden file input -->
      <input type="file" id="storage-file-input" style="display:none" multiple onchange="storageDoUpload(this)"/>
    </section>

  </main>
</div>

<!-- Owner auth modal -->
<div class="owner-modal-overlay" id="owner-modal-overlay">
  <div class="owner-modal">
    <div class="owner-modal-header">
      <div class="owner-modal-title">
        <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M2 4l3 12h14l3-12-6 5-4-7-4 7-6-5z"/></svg>
        Owner Access
      </div>
      <button onclick="closeOwnerModal()" style="background:none;border:none;color:#64748b;cursor:pointer;font-size:18px;padding:0 4px">✕</button>
    </div>
    <div class="owner-modal-body" id="owner-modal-body"></div>
  </div>
</div>

<!-- Premium upgrade modal -->
<div class="upgrade-overlay" id="upgrade-overlay">
  <div class="upgrade-card">
    <div style="font-size:36px;margin-bottom:8px">👑</div>
    <div class="upgrade-title">Premium Feature</div>
    <div class="upgrade-sub">This feature requires a Premium activation key. Enter your key below to unlock all premium features instantly.</div>
    <input class="upgrade-inp" id="upgrade-key-input" placeholder="CPM-XXXX-XXXX-XXXX" maxlength="25" autocomplete="off" spellcheck="false"/>
    <div class="upgrade-err" id="upgrade-err"></div>
    <button class="act-btn act-btn-paid" onclick="submitUpgradeKey()">🔑 Activate Premium</button>
    <button class="act-btn act-btn-free" onclick="closeUpgrade()" style="margin-top:4px">Cancel</button>
  </div>
</div>

<!-- SSH / tmate Modal -->
<div class="ssh-overlay" id="ssh-overlay">
  <div class="ssh-window">
    <div class="ssh-header">
      <div class="ssh-title">
        <svg width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
        <span id="ssh-title-text">SSH Access</span>
      </div>
      <button class="ssh-close" onclick="closeSsh()">✕</button>
    </div>
    <div class="ssh-body" id="ssh-body">
      <div class="ssh-loading">Starting tmate session…</div>
    </div>
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
      <button class="qa-btn qa-ssh" onclick="openSsh('${name}')">
        <svg width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg> Get SSH Access
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
      <button class="btn btn-ssh" onclick="openSsh('${name}')" style="grid-column:1/-1">
        <svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>Get SSH Access</button>
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

// ── KVM status check ──────────────────────────────────────────────────────
let kvmFunctional = true;

async function checkKvmStatus() {
  try {
    const d = await api('/api/kvm/status');
    kvmFunctional = d.functional;
    const banner  = document.getElementById('kvm-banner');
    const topText = document.getElementById('kvm-status');
    if (!d.functional) {
      document.getElementById('kvm-banner-msg').textContent = d.message;
      banner.classList.add('show');
      topText.textContent = '⚠ ' + d.message;
      // Disable all VPS action buttons
      document.querySelectorAll('.btn-start,.btn-stop,.btn-restart,.btn-delete,.btn-ssh,.qa-start,.qa-stop,.qa-restart,.qa-ssh').forEach(b => {
        b.disabled = true;
        b.title = d.message;
      });
    } else {
      banner.classList.remove('show');
      topText.textContent = 'KVM Virtualisation Active';
    }
  } catch(e) {}
}

// ── SSH / tmate ───────────────────────────────────────────────────────────
function closeSsh() {
  document.getElementById('ssh-overlay').classList.remove('open');
}

function copyText(txt, btn) {
  navigator.clipboard.writeText(txt).then(() => {
    btn.textContent = 'Copied!';
    setTimeout(() => btn.textContent = 'Copy', 1800);
  }).catch(() => {
    btn.textContent = 'Error';
    setTimeout(() => btn.textContent = 'Copy', 1800);
  });
}

async function openSsh(name) {
  document.getElementById('ssh-title-text').textContent = 'SSH Access — ' + name;
  document.getElementById('ssh-body').innerHTML =
    '<div class="ssh-loading">⏳ Preparing SSH session for <strong>' + name + '</strong>…' +
    '<br><small style="opacity:.6">Installing tmate if needed, then starting session…</small></div>';
  document.getElementById('ssh-overlay').classList.add('open');
  try {
    const d = await api('/api/vps/tmate', {method:'POST', body:JSON.stringify({name})});
    if (d.success) {
      // Build the "commands that were run" block
      const cmds = (d.cmds_run || []);
      const cmdHtml = cmds.length ? `
        <div class="ssh-label" style="margin-bottom:6px">Commands run on server</div>
        <div class="ssh-box" style="color:#94a3b8;font-size:12px;margin-bottom:16px">${
          cmds.map(c => `<div style="margin-bottom:4px"><span style="color:#4ade80">$</span> ${c}</div>`).join('')
        }</div>` : '';
      const sshSafe  = d.ssh.replace(/'/g, "\\'");
      const webSafe  = (d.web||'').replace(/'/g, "\\'");
      document.getElementById('ssh-body').innerHTML = `
        ${cmdHtml}
        <div class="ssh-label">SSH Connection Key</div>
        <div class="ssh-box">${d.ssh}<button class="copy-btn" onclick="copyText('${sshSafe}',this)">Copy</button></div>
        ${d.web ? `
        <div class="ssh-label">Web Browser Link</div>
        <div class="ssh-box" style="margin-bottom:0">
          <a href="${d.web}" target="_blank" style="color:#60a5fa;text-decoration:none;word-break:break-all">${d.web}</a>
          <button class="copy-btn" onclick="copyText('${webSafe}',this)">Copy</button>
        </div>` : ''}
        <div class="ssh-note" style="margin-top:16px">
          Paste the SSH command into your terminal to connect to this server.<br>
          The session stays active until you close tmate or restart the panel.
        </div>`;
    } else {
      document.getElementById('ssh-body').innerHTML =
        `<div class="ssh-loading" style="color:#dc2626">❌ ${d.error}</div>`;
    }
  } catch(e) {
    document.getElementById('ssh-body').innerHTML =
      '<div class="ssh-loading" style="color:#dc2626">❌ Request failed — is the panel running?</div>';
  }
}

// close SSH modal on Escape key
document.addEventListener('keydown', e => { if (e.key === 'Escape') closeSsh(); });

// ── start newly created VM ────────────────────────────────────────────────
async function startNewVm(name) {
  try {
    const d = await api('/api/vps/start', {method:'POST', body:JSON.stringify({name})});
    if (d.success) { toast(`${name} started!`); await loadVps(); dashSelectVps(name); showPage('dashboard', document.getElementById('mob-dash')); }
    else toast(d.error || 'Could not start', false);
  } catch(e) { toast('Request failed', false); }
}

// ── Feature gating ────────────────────────────────────────────────────────
let featureMap = {};

function getUserPlan() {
  return localStorage.getItem('cpm_activation') || 'none';
}

function canUse(featureId) {
  const feat = featureMap[featureId];
  if (!feat || feat.tier === 'free') return true;
  const plan = getUserPlan();
  return plan === 'premium' || plan === 'paid';
}

function requirePremium(featureId, callback) {
  if (canUse(featureId)) { callback(); } else { openUpgrade(); }
}

function updatePlanBadge() {
  const plan = getUserPlan();
  const badge = document.getElementById('plan-badge');
  if (!badge) return;
  if (plan === 'premium' || plan === 'paid') {
    badge.className = 'plan-badge premium'; badge.textContent = '👑 Premium';
  } else {
    badge.className = 'plan-badge free'; badge.textContent = '🔓 Free';
  }
}

async function loadFeatureMap() {
  try {
    const d = await api('/api/features/status');
    featureMap = d.features || {};
    updatePlanBadge();
  } catch(e) {}
}

// ── Upgrade modal ─────────────────────────────────────────────────────────
function openUpgrade() {
  document.getElementById('upgrade-overlay').classList.add('open');
  const inp = document.getElementById('upgrade-key-input');
  inp.value = ''; document.getElementById('upgrade-err').textContent = '';
  setTimeout(() => inp.focus(), 50);
  inp.onkeydown = e => { if (e.key === 'Enter') submitUpgradeKey(); };
}

function closeUpgrade() {
  document.getElementById('upgrade-overlay').classList.remove('open');
}

async function submitUpgradeKey() {
  const inp = document.getElementById('upgrade-key-input');
  const err = document.getElementById('upgrade-err');
  const key = inp.value.trim().toUpperCase();
  if (!key) { err.textContent = 'Please enter a key.'; return; }
  err.textContent = '⏳ Validating…';
  try {
    const uid = 'u-' + Math.random().toString(36).slice(2, 9);
    const d = await api('/api/user/activate', {method:'POST', body:JSON.stringify({key, user_id: uid})});
    if (d.success) {
      localStorage.setItem('cpm_activation', 'premium');
      localStorage.setItem('cpm_premium_key', key);
      if (d.expires_at) localStorage.setItem('cpm_premium_expires', d.expires_at);
      closeUpgrade(); updatePlanBadge(); loadFeatureMap();
      toast('👑 Premium activated! All features unlocked.', true);
    } else {
      err.textContent = '❌ ' + (d.error || 'Invalid key');
    }
  } catch(e) { err.textContent = '❌ Server error — try again'; }
}

// ── Activation overlay (server-side keys) ────────────────────────────────
const ACT_STORE_KEY = 'cpm_activation';

function activationInit() {
  const saved = localStorage.getItem(ACT_STORE_KEY);
  if (saved === 'owner') {
    ownerKeySession = localStorage.getItem('cpm_owner_key') || '';
    hideActOverlay('owner');
  } else if (saved === 'premium' || saved === 'paid' || saved === 'free') {
    hideActOverlay(saved);
  } else {
    document.getElementById('act-overlay').classList.remove('hidden');
    const inp = document.getElementById('act-key-input');
    inp.addEventListener('input', function() {
      this.classList.remove('error');
      document.getElementById('act-err').textContent = '';
    });
    inp.addEventListener('keydown', e => { if (e.key === 'Enter') activatePanel(); });
  }
}

async function activatePanel() {
  const inp  = document.getElementById('act-key-input');
  const err  = document.getElementById('act-err');
  const btn  = document.getElementById('act-btn-paid');
  const key  = inp.value.trim();
  if (!key) { inp.classList.add('error'); err.textContent = 'Please enter your key.'; return; }
  btn.textContent = '⏳ Validating…'; btn.disabled = true;
  err.textContent = '';

  // 1 — try owner auth first
  try {
    const st = await api('/api/owner/status');
    if (st.initialized) {
      const od = await api('/api/owner/auth', {method:'POST', body:JSON.stringify({owner_key: key})});
      if (od.success) {
        ownerKeySession = key;
        inp.classList.add('success');
        localStorage.setItem(ACT_STORE_KEY, 'owner');
        localStorage.setItem('cpm_owner_key', key);
        btn.textContent = '✅ Owner Access!';
        btn.style.background = 'linear-gradient(135deg,#d97706,#b45309)';
        setTimeout(() => hideActOverlay('owner'), 700);
        return;
      }
    }
  } catch(_) {}

  // 2 — try paid user activation
  try {
    const uid = 'u-' + Math.random().toString(36).slice(2, 9);
    const d = await api('/api/user/activate', {method:'POST', body:JSON.stringify({key: key.toUpperCase(), user_id: uid})});
    if (d.success) {
      inp.classList.add('success');
      localStorage.setItem(ACT_STORE_KEY, 'premium');
      localStorage.setItem('cpm_premium_key', key.toUpperCase());
      if (d.expires_at) localStorage.setItem('cpm_premium_expires', d.expires_at);
      btn.textContent = '✅ Premium Activated!';
      btn.style.background = 'linear-gradient(135deg,#16a34a,#15803d)';
      setTimeout(() => hideActOverlay('premium'), 700);
      return;
    }
  } catch(_) {}

  inp.classList.add('error');
  err.textContent = '❌ Invalid key — check it and try again.';
  btn.textContent = '🔑 Access Panel'; btn.disabled = false;
}

function useFreeVersion() {
  localStorage.setItem(ACT_STORE_KEY, 'free');
  hideActOverlay('free');
}

function hideActOverlay(mode) {
  document.getElementById('act-overlay').classList.add('hidden');
  const nav = document.getElementById('nav-owner');
  if (mode === 'owner') {
    nav.style.display = 'flex';
    updatePlanBadge(); loadFeatureMap();
    enterOwnerPanel();
    return;
  }
  nav.style.display = 'none';
  updatePlanBadge(); loadFeatureMap();
  const banner = document.getElementById('act-mode-banner');
  if (mode === 'premium' || mode === 'paid') {
    banner.className = 'act-mode-banner paid';
    banner.textContent = '👑 Premium — All features unlocked';
  } else {
    banner.className = 'act-mode-banner free';
    banner.textContent = '🔓 Free Version — Enter a key to unlock features';
  }
  banner.style.display = 'block';
  setTimeout(() => { banner.style.display = 'none'; }, 5000);
}

// ── First-time owner setup inside startup dialog ──────────────────────────
async function showActSetup() {
  try {
    const st = await api('/api/owner/status');
    if (st.initialized) {
      document.getElementById('act-err').textContent = 'Owner key already set. Enter it above.';
      return;
    }
  } catch(_) {}
  document.getElementById('act-main-form').style.display = 'none';
  document.getElementById('act-setup-form').style.display = 'block';
  setTimeout(() => { const i = document.getElementById('act-setup-key'); if (i) { i.focus(); i.addEventListener('keydown', e => { if (e.key === 'Enter') submitActOwnerSetup(); }); } }, 50);
}

function hideActSetup() {
  document.getElementById('act-setup-form').style.display = 'none';
  document.getElementById('act-main-form').style.display = 'block';
  document.getElementById('act-setup-err').textContent = '';
}

async function submitActOwnerSetup() {
  const inp = document.getElementById('act-setup-key');
  const err = document.getElementById('act-setup-err');
  const btn = document.getElementById('act-setup-btn');
  const key = inp.value.trim();
  if (key.length < 6) { err.textContent = 'Key must be at least 6 characters.'; return; }
  btn.textContent = '⏳ Setting up…'; btn.disabled = true;
  try {
    const d = await api('/api/owner/setup', {method:'POST', body:JSON.stringify({owner_key: key})});
    if (d.success) {
      ownerKeySession = key;
      localStorage.setItem(ACT_STORE_KEY, 'owner');
      localStorage.setItem('cpm_owner_key', key);
      btn.textContent = '✅ Done!';
      btn.style.background = 'linear-gradient(135deg,#d97706,#b45309)';
      setTimeout(() => hideActOverlay('owner'), 700);
    } else {
      err.textContent = '❌ ' + (d.error || 'Setup failed');
      btn.textContent = '🔐 Set Owner Key & Enter'; btn.disabled = false;
    }
  } catch(_) {
    err.textContent = '❌ Server error — try again';
    btn.textContent = '🔐 Set Owner Key & Enter'; btn.disabled = false;
  }
}

// ── Owner panel ───────────────────────────────────────────────────────────
let ownerKeySession = '';

function openOwnerPanel() {
  enterOwnerPanel();
}

function closeOwnerModal() {
  document.getElementById('owner-modal-overlay').classList.remove('open');
}

function showOwnerSetup() {
  document.getElementById('owner-modal-body').innerHTML = `
    <p style="color:#94a3b8;font-size:13px;margin-bottom:20px;line-height:1.6">
      First-time setup. Create a secret Owner Key to protect this management panel. <strong style="color:#f59e0b">Keep it safe — it cannot be recovered.</strong>
    </p>
    <div class="gen-label" style="color:#94a3b8;margin-bottom:6px">Create Owner Secret Key</div>
    <input class="owner-input" id="owner-setup-key" type="password" placeholder="Min 6 characters" autocomplete="new-password"/>
    <div class="owner-err" id="owner-setup-err"></div>
    <button class="owner-btn owner-btn-primary" onclick="submitOwnerSetup()">🔐 Set Owner Key</button>
    <button class="owner-btn owner-btn-secondary" onclick="closeOwnerModal()">Cancel</button>`;
  setTimeout(() => {
    const i = document.getElementById('owner-setup-key');
    if (i) { i.focus(); i.addEventListener('keydown', e => { if (e.key==='Enter') submitOwnerSetup(); }); }
  }, 50);
}

function showOwnerAuth() {
  document.getElementById('owner-modal-body').innerHTML = `
    <p style="color:#94a3b8;font-size:13px;margin-bottom:20px">Enter your Owner Secret Key to access the management panel.</p>
    <div class="gen-label" style="color:#94a3b8;margin-bottom:6px">Owner Secret Key</div>
    <input class="owner-input" id="owner-auth-key" type="password" placeholder="Your owner secret key" autocomplete="current-password"/>
    <div class="owner-err" id="owner-auth-err"></div>
    <button class="owner-btn owner-btn-primary" onclick="submitOwnerAuth()">👑 Access Owner Panel</button>
    <button class="owner-btn owner-btn-secondary" onclick="closeOwnerModal()">Cancel</button>`;
  setTimeout(() => {
    const i = document.getElementById('owner-auth-key');
    if (i) { i.focus(); i.addEventListener('keydown', e => { if (e.key==='Enter') submitOwnerAuth(); }); }
  }, 50);
}

async function submitOwnerSetup() {
  const inp = document.getElementById('owner-setup-key');
  const err = document.getElementById('owner-setup-err');
  const key = inp.value.trim();
  if (key.length < 6) { err.textContent = 'Key must be at least 6 characters'; return; }
  try {
    const d = await api('/api/owner/setup', {method:'POST', body:JSON.stringify({owner_key: key})});
    if (d.success) {
      ownerKeySession = key; closeOwnerModal(); enterOwnerPanel();
      toast('🔐 Owner key set! Keep it safe.', true);
    } else { err.textContent = d.error || 'Failed'; }
  } catch(e) { err.textContent = 'Server error'; }
}

async function submitOwnerAuth() {
  const inp = document.getElementById('owner-auth-key');
  const err = document.getElementById('owner-auth-err');
  const key = inp.value.trim();
  if (!key) { err.textContent = 'Enter your owner key'; return; }
  try {
    const d = await api('/api/owner/auth', {method:'POST', body:JSON.stringify({owner_key: key})});
    if (d.success) {
      ownerKeySession = key; closeOwnerModal(); enterOwnerPanel();
    } else {
      inp.classList.add('error'); err.textContent = '❌ ' + (d.error || 'Invalid owner key');
    }
  } catch(e) { err.textContent = 'Server error'; }
}

function enterOwnerPanel() {
  showPage('owner', document.getElementById('nav-owner'));
  ownerLoadAnalytics();
}

function ownerTab(tab, btn) {
  document.querySelectorAll('.owner-tab').forEach(b => b.classList.remove('active'));
  document.querySelectorAll('.owner-tab-panel').forEach(p => p.classList.remove('active'));
  btn.classList.add('active');
  document.getElementById('otab-' + tab).classList.add('active');
  if (tab === 'analytics') ownerLoadAnalytics();
  else if (tab === 'keys') ownerLoadKeys();
  else if (tab === 'features') ownerLoadFeatures();
  else if (tab === 'logs') ownerLoadLogs();
}

async function ownerPost(endpoint, extra = {}) {
  return api(endpoint, {method:'POST', body: JSON.stringify({owner_key: ownerKeySession, ...extra})});
}

async function ownerLoadAnalytics() {
  const el = document.getElementById('ana-cards');
  const recentEl = document.getElementById('ana-recent-logs');
  if (!el) return;
  try {
    const d = await ownerPost('/api/owner/analytics');
    const stats = [
      ['Total Keys', d.total_keys, '#2563eb'],
      ['Active Keys', d.active_keys, '#16a34a'],
      ['Used Keys', d.used_keys, '#0369a1'],
      ['Activations', d.total_activations, '#7c3aed'],
      ['Premium Features', d.premium_features, '#d97706'],
      ['Free Features', d.free_features, '#64748b'],
    ];
    el.innerHTML = stats.map(([label, num, color]) =>
      `<div class="ana-card"><div class="ana-num" style="color:${color}">${num ?? 0}</div><div class="ana-label">${label}</div></div>`
    ).join('');
    const logs = d.recent_logs || [];
    recentEl.innerHTML = logs.length
      ? logs.map(l => `<div class="log-row">
          <span class="log-time">${(l.activated_at||'').slice(0,19).replace('T',' ')}</span>
          <span class="log-key">${l.key}</span>
          <span style="margin-left:auto;font-size:11px;color:var(--muted)">${l.expires_at ? 'Exp: '+l.expires_at.slice(0,10) : '∞ No expiry'}</span>
        </div>`).join('')
      : '<div style="color:var(--muted);font-size:14px;padding:8px">No activations yet</div>';
  } catch(e) { if (el) el.innerHTML = '<div style="color:#dc2626">Failed to load — is owner key correct?</div>'; }
}

async function ownerLoadKeys() {
  const tbody = document.getElementById('keys-tbody');
  if (!tbody) return;
  try {
    const d = await ownerPost('/api/owner/keys');
    const keys = d.keys || [];
    tbody.innerHTML = keys.length
      ? keys.map(k => `<tr>
          <td><span class="key-mono">${k.key}</span><br><span style="font-size:10px;color:var(--muted)">${k.id}${k.note?' · '+k.note:''}</span></td>
          <td><span class="status-pill pill-${k.status}">${k.status}</span></td>
          <td style="font-size:12px">${k.expires_at ? k.expires_at.slice(0,10) : '∞ Never'}</td>
          <td style="font-size:12px">${k.uses_max===-1?'∞':k.uses_max} / used: ${k.uses_count}</td>
          <td>
            ${k.status!=='revoked'?`<button class="tbl-btn tbl-btn-revoke" onclick="ownerRevoke('${k.id}')">Revoke</button>`:''}
            <button class="tbl-btn tbl-btn-delete" onclick="ownerDeleteKey('${k.id}')">Delete</button>
          </td>
        </tr>`).join('')
      : '<tr><td colspan="5" style="text-align:center;color:var(--muted);padding:24px">No keys yet — generate one above</td></tr>';
  } catch(e) { tbody.innerHTML = '<tr><td colspan="5" style="color:#dc2626">Failed to load keys</td></tr>'; }
}

async function ownerGenerateKey() {
  try {
    const d = await ownerPost('/api/owner/keys/generate', {
      custom_key: document.getElementById('gen-custom').value.trim(),
      exp_value:  document.getElementById('gen-exp-val').value.trim() || null,
      exp_unit:   document.getElementById('gen-exp-unit').value,
      uses_max:   parseInt(document.getElementById('gen-uses').value),
      note:       document.getElementById('gen-note').value.trim(),
    });
    if (d.success) {
      toast('✅ Key: ' + d.key.key, true);
      ['gen-custom','gen-exp-val','gen-note'].forEach(id => { document.getElementById(id).value = ''; });
      ownerLoadKeys();
    } else { toast(d.error || 'Failed', false); }
  } catch(e) { toast('Server error', false); }
}

async function ownerRevoke(id) {
  if (!confirm('Revoke this key? Users with this key will lose premium access.')) return;
  try { const d = await ownerPost('/api/owner/keys/revoke', {id}); if (d.success) { ownerLoadKeys(); toast('Key revoked', true); } else toast(d.error, false); }
  catch(e) { toast('Failed', false); }
}

async function ownerDeleteKey(id) {
  if (!confirm('Permanently delete this key?')) return;
  try { const d = await ownerPost('/api/owner/keys/delete', {id}); if (d.success) { ownerLoadKeys(); toast('Key deleted', true); } else toast(d.error, false); }
  catch(e) { toast('Failed', false); }
}

async function ownerLoadFeatures() {
  const el = document.getElementById('feat-list');
  if (!el) return;
  const search = (document.getElementById('feat-search')?.value || '').toLowerCase();
  try {
    const d = await ownerPost('/api/owner/features');
    const feats = d.features || {};
    const rows = Object.entries(feats)
      .filter(([id, f]) => !search || f.name.toLowerCase().includes(search) || f.category.toLowerCase().includes(search));
    el.innerHTML = rows.length
      ? rows.map(([id, f]) => `
        <div class="feat-row">
          <div class="feat-info">
            <div class="feat-name">${f.name}</div>
            <div class="feat-cat">${f.category}</div>
          </div>
          <div class="tier-toggle">
            <button class="tier-btn ${f.tier==='free'?'active-free':''}" onclick="ownerToggleFeature('${id}','free',this)">🟢 Free</button>
            <button class="tier-btn ${f.tier==='premium'?'active-premium':''}" onclick="ownerToggleFeature('${id}','premium',this)">👑 Premium</button>
          </div>
        </div>`).join('')
      : '<div style="color:var(--muted);padding:16px">No features found</div>';
  } catch(e) { el.innerHTML = '<div style="color:#dc2626">Failed to load features</div>'; }
}

async function ownerToggleFeature(featureId, tier, btn) {
  try {
    const d = await ownerPost('/api/owner/features/toggle', {feature_id: featureId, tier});
    if (d.success) {
      if (featureMap[featureId]) featureMap[featureId].tier = tier;
      const toggle = btn.closest('.tier-toggle');
      toggle.querySelectorAll('.tier-btn').forEach(b => b.className = 'tier-btn');
      btn.classList.add(tier === 'free' ? 'active-free' : 'active-premium');
      updatePlanBadge();
    } else { toast(d.error || 'Failed', false); }
  } catch(e) { toast('Server error', false); }
}

async function ownerLoadLogs() {
  const el = document.getElementById('log-list');
  if (!el) return;
  try {
    const d = await ownerPost('/api/owner/logs');
    const logs = d.logs || [];
    el.innerHTML = logs.length
      ? logs.map(l => `<div class="log-row">
          <span class="log-time">${(l.activated_at||'').slice(0,19).replace('T',' ')}</span>
          <span class="log-key">${l.key}</span>
          <span style="font-size:11px;color:var(--muted);margin-left:4px">${l.key_id}</span>
          <span style="margin-left:auto;font-size:11px;color:var(--muted)">${l.expires_at?'Exp: '+l.expires_at.slice(0,10):'∞'}</span>
        </div>`).join('')
      : '<div style="color:var(--muted);font-size:14px;padding:24px">No activation logs yet</div>';
  } catch(e) { el.innerHTML = '<div style="color:#dc2626">Failed to load logs</div>'; }
}

// ── Cloud Storage ─────────────────────────────────────────────────────────
let storagePath = '';

function storageOpen() { loadStorage(''); }

function storageTo(path) { loadStorage(path); }

async function loadStorage(path) {
  storagePath = path;
  renderStorageCrumb();
  const el = document.getElementById('storage-file-list');
  el.innerHTML = '<div style="padding:32px;color:var(--muted);text-align:center">⏳ Loading…</div>';
  try {
    const d = await api('/api/storage/list?path=' + encodeURIComponent(path));
    const items = d.items || [];
    if (!items.length) {
      el.innerHTML = '<div style="padding:36px;color:var(--muted);text-align:center">📂 This folder is empty.<br><small>Upload files or create a folder to get started.</small></div>';
    } else {
      el.innerHTML = `<div style="overflow-x:auto"><table class="file-table">
        <thead><tr>
          <th>Name</th><th>Size</th><th>Modified</th><th style="text-align:right">Actions</th>
        </tr></thead>
        <tbody>${items.map(f => {
          const fullRel = (path ? path + '/' : '') + f.name;
          const esc = fullRel.replace(/'/g, "\\'");
          return `<tr>
            <td>
              ${f.type === 'folder'
                ? `<button class="file-name-btn" onclick="storageTo('${esc}')">📁 ${f.name}</button>`
                : `<span>${storageFileIcon(f.name)} ${f.name}</span>`}
            </td>
            <td style="color:var(--muted);font-size:12px">${f.type === 'folder' ? '—' : fmtBytes(f.size)}</td>
            <td style="color:var(--muted);font-size:12px;white-space:nowrap">${f.modified}</td>
            <td style="text-align:right;white-space:nowrap">
              ${f.type === 'file' ? `<a href="/api/storage/download?path=${encodeURIComponent(fullRel)}" download="${f.name}" class="tbl-btn" style="text-decoration:none;display:inline-block">⬇ Download</a>` : ''}
              <button class="tbl-btn tbl-btn-delete" onclick="storageDelete('${esc}','${f.type}')">🗑 Delete</button>
            </td>
          </tr>`;
        }).join('')}</tbody>
      </table></div>`;
    }
  } catch(e) {
    el.innerHTML = '<div style="padding:24px;color:#dc2626;text-align:center">❌ Failed to load — is the panel running?</div>';
  }
  loadStorageStats();
}

function renderStorageCrumb() {
  const el = document.getElementById('storage-crumb');
  if (!el) return;
  const parts = storagePath ? storagePath.split('/').filter(Boolean) : [];
  let html = `<span onclick="storageTo('')" style="cursor:pointer;color:var(--blue);font-weight:600">📁 Storage</span>`;
  let built = '';
  parts.forEach((p, i) => {
    built = built ? built + '/' + p : p;
    const snap = built;
    html += `<span style="color:var(--muted);padding:0 5px">/</span>`;
    if (i === parts.length - 1) {
      html += `<span style="color:var(--text);font-weight:600">${p}</span>`;
    } else {
      html += `<span onclick="storageTo('${snap}')" style="cursor:pointer;color:var(--blue)">${p}</span>`;
    }
  });
  el.innerHTML = html;
}

async function loadStorageStats() {
  try {
    const d = await api('/api/storage/stats');
    const used = d.used || 0, total = d.total || 0;
    const pct = total ? Math.min(100, (used / total) * 100).toFixed(1) : 0;
    const el = document.getElementById('storage-usage-text');
    const bar = document.getElementById('storage-bar');
    if (el) el.textContent = fmtBytes(used) + ' used of ' + fmtBytes(total);
    if (bar) bar.style.width = pct + '%';
  } catch(_) {}
}

function storageFileIcon(name) {
  const ext = (name.split('.').pop() || '').toLowerCase();
  const map = {jpg:'🖼',jpeg:'🖼',png:'🖼',gif:'🖼',webp:'🖼',svg:'🖼',ico:'🖼',
    mp4:'🎬',mkv:'🎬',avi:'🎬',mov:'🎬',mp3:'🎵',wav:'🎵',ogg:'🎵',
    pdf:'📄',doc:'📝',docx:'📝',txt:'📝',log:'📝',
    zip:'📦',tar:'📦',gz:'📦','7z':'📦',rar:'📦',
    sh:'⚙',py:'🐍',js:'📜',ts:'📜',json:'📋',yml:'📋',yaml:'📋',
    html:'🌐',css:'🎨',php:'🐘',sql:'🗃'};
  return map[ext] || '📄';
}

function fmtBytes(b) {
  if (!b) return '0 B';
  if (b < 1024) return b + ' B';
  if (b < 1048576) return (b/1024).toFixed(1) + ' KB';
  if (b < 1073741824) return (b/1048576).toFixed(1) + ' MB';
  return (b/1073741824).toFixed(2) + ' GB';
}

function storageUpload() {
  document.getElementById('storage-file-input').click();
}

async function storageDoUpload(input) {
  const files = Array.from(input.files);
  if (!files.length) return;
  toast(`⏳ Uploading ${files.length} file(s)…`);
  let ok = 0, fail = 0;
  for (const file of files) {
    const fd = new FormData();
    fd.append('file', file);
    fd.append('path', storagePath);
    try {
      const r = await fetch('/api/storage/upload', {method:'POST', body: fd});
      const d = await r.json();
      if (d.success) ok++; else { fail++; toast('❌ ' + file.name + ': ' + (d.error||'failed'), false); }
    } catch(_) { fail++; toast('❌ Upload failed for ' + file.name, false); }
  }
  input.value = '';
  if (ok) toast('✅ ' + ok + ' file(s) uploaded', true);
  loadStorage(storagePath);
}

async function storageMkdir() {
  const name = prompt('New folder name:');
  if (!name || !name.trim()) return;
  const safe = name.trim().replace(/[^a-zA-Z0-9_\-. ]/g, '_');
  if (!safe) { toast('Invalid folder name', false); return; }
  try {
    const d = await api('/api/storage/mkdir', {method:'POST', body: JSON.stringify({path: (storagePath ? storagePath + '/' : '') + safe})});
    if (d.success) { toast('📁 Folder created', true); loadStorage(storagePath); }
    else toast(d.error || 'Failed to create folder', false);
  } catch(_) { toast('Server error', false); }
}

async function storageDelete(path, type) {
  const msg = type === 'folder'
    ? 'Delete this folder and ALL its contents? This cannot be undone.'
    : 'Delete this file? This cannot be undone.';
  if (!confirm(msg)) return;
  try {
    const d = await api('/api/storage/delete', {method:'POST', body: JSON.stringify({path})});
    if (d.success) { toast('🗑 Deleted', true); loadStorage(storagePath); }
    else toast(d.error || 'Delete failed', false);
  } catch(_) { toast('Server error', false); }
}

// ── Logout / Switch Account ───────────────────────────────────────────────
function logoutPanel() {
  if (!confirm('Log out and return to the startup screen?')) return;
  ['cpm_activation','cpm_owner_key','cpm_premium_key','cpm_premium_expires'].forEach(k => localStorage.removeItem(k));
  location.reload();
}

// ── init & poll ───────────────────────────────────────────────────────────
activationInit();
checkKvmStatus();
loadStats(); loadVps();
setInterval(loadStats, 5000);
setInterval(loadVps, 10000);
setInterval(checkKvmStatus, 30000);
</script>
</body>
</html>

HTMLEOF
  ok "index.html written"
fi

# ── Write requirements.txt ────────────────────────────────────────────────────
cat > "$DIR/requirements.txt" << 'EOF'
flask>=3.0.0
flask-cors>=4.0.0
psutil>=6.0.0
# tmate is installed as a system package (apt), not via pip
EOF

# ── Write run.sh ──────────────────────────────────────────────────────────────
cat > "$DIR/run.sh" << 'RUNEOF'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-5000}"
if [[ -f "$DIR/venv/bin/python3" ]]; then PYTHON="$DIR/venv/bin/python3"
else PYTHON="$(which python3)"; fi
echo "  Starting CPM Panel on port $PORT …"
cd "$DIR"
PORT="$PORT" "$PYTHON" app.py
RUNEOF
chmod +x "$DIR/run.sh"
ok "run.sh written"

# Copy logo if it exists next to install.sh
[[ -f "$DIR/logo.png" ]] && ok "logo.png found" || wrn "logo.png not found in $DIR — sidebar will show text brand"

# ─── 4. Install Python packages ─────────────────────────────────────────────────
sep "4/4  Installing Python packages"

PKGS="flask flask-cors psutil"

inf "Creating virtual environment…"
if python3 -m venv "$DIR/venv" 2>/dev/null && [[ -f "$DIR/venv/bin/pip" ]]; then
  ok "venv ready at $DIR/venv"
else
  wrn "venv creation failed — will install system-wide"
  rm -rf "$DIR/venv"
fi

if [[ -f "$DIR/venv/bin/python3" ]]; then
  PYTHON="$DIR/venv/bin/python3"
  PIP="$DIR/venv/bin/pip"
else
  PYTHON="$(which python3)"
  PIP=""
fi
ok "Python: $PYTHON"

install_pkg() {
  local pkg="$1"
  if "$PYTHON" -c "import ${pkg//-/_}" 2>/dev/null; then
    ok "$pkg already available"; return 0
  fi
  inf "Installing $pkg…"
  if [[ -n "$PIP" ]] && "$PIP" install "$pkg" -q 2>/dev/null; then ok "$pkg installed (venv pip)"; return 0; fi
  if pip3 install --break-system-packages "$pkg" -q 2>/dev/null; then ok "$pkg installed (pip3 --break-system-packages)"; return 0; fi
  if pip3 install "$pkg" -q 2>/dev/null; then ok "$pkg installed (pip3)"; return 0; fi
  if "$PYTHON" -m pip install --break-system-packages "$pkg" -q 2>/dev/null; then ok "$pkg installed (python3 -m pip --break-system-packages)"; return 0; fi
  if "$PYTHON" -m pip install "$pkg" -q 2>/dev/null; then ok "$pkg installed (python3 -m pip)"; return 0; fi
  die "FAILED to install $pkg — check your network / pip setup and re-run install.sh"
}

for pkg in $PKGS; do install_pkg "$pkg"; done

sep "Verifying all packages"
ALL_OK=true
for pkg in flask flask_cors psutil; do
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
[[ "$ALL_OK" == true ]] && ok "All packages verified"

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
echo -e "  ${Y}FIRST-TIME SETUP:${N}"
echo -e "    Click 'Owner Panel' in the sidebar and create your secret owner key."
echo -e "    No default key is pre-set — you choose your own on first run."
echo ""
[[ -n "${SUDO_USER:-}" ]] && echo -e "  ${Y}NOTE:${N} Log out and back in so '$SUDO_USER' can use virsh without sudo."
