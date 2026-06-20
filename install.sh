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
echo -e "${N}  KVM VPS Management Panel — Installer v1\n"

# ─── 1. System packages ───────────────────────────────────────────────────────
sep "1/4  System packages"
apt-get update -y
apt-get install -y python3 python3-pip python3-venv python3-full curl tmate nodejs npm
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
import os, re, shutil, subprocess, logging, time, hashlib, json, uuid, secrets, threading
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

# ── Supabase client ────────────────────────────────────────────────────────────
try:
    from supabase import create_client, Client as SupabaseClient
    _SB_URL = os.environ.get("SUPABASE_URL", "https://vompmplmluxwtwgofgks.supabase.co")
    _SB_KEY = os.environ.get("SUPABASE_KEY", "sb_secret_9E5gznEQ0m-6w2zkYT2j4Q_OEBJyWO8")
    _sb: SupabaseClient = create_client(_SB_URL, _SB_KEY)
    HAS_SUPABASE = True
    logging.getLogger(__name__).info("Supabase connected ✓")
except Exception as _sb_err:
    _sb = None
    HAS_SUPABASE = False
    logging.getLogger(__name__).warning(f"Supabase not available ({_sb_err}) — using local JSON fallback")

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

_DEFAULT_FEATURES = {
    "dashboard":     {"name":"Dashboard",            "category":"System",       "tier":"free",    "usage":0},
    "system_stats":  {"name":"System Statistics",    "category":"Monitoring",   "tier":"free",    "usage":0},
    "vps_list":      {"name":"View VPS Instances",   "category":"VPS",          "tier":"free",    "usage":0},
    "vps_stop":      {"name":"Stop VPS",             "category":"VPS Control",  "tier":"free",    "usage":0},
    "vps_start":     {"name":"Start VPS",            "category":"VPS Control",  "tier":"premium", "usage":0},
    "vps_restart":   {"name":"Restart VPS",          "category":"VPS Control",  "tier":"premium", "usage":0},
    "vps_delete":    {"name":"Delete VPS",           "category":"VPS Control",  "tier":"premium", "usage":0},
    "vps_create":    {"name":"Create VPS",           "category":"VPS Control",  "tier":"premium", "usage":0},
    "ssh_access":    {"name":"SSH Access (tmate)",   "category":"Connectivity", "tier":"premium", "usage":0},
    "file_manager":  {"name":"File Manager",         "category":"Storage",      "tier":"premium", "usage":0},
    "file_upload":   {"name":"Upload File",          "category":"Storage",      "tier":"premium", "usage":0},
    "file_download": {"name":"Download File",        "category":"Storage",      "tier":"premium", "usage":0},
    "ui_customize":  {"name":"UI Customization",     "category":"Appearance",   "tier":"premium", "usage":0},
}

def _hash(k): return hashlib.sha256(k.encode()).hexdigest()
def _now(): return datetime.now(timezone.utc).isoformat()

# ── Supabase helpers ───────────────────────────────────────────────────────────

def _sb_load():
    """Load full data dict from Supabase cpm_config table."""
    try:
        rows = _sb.table("cpm_config").select("key,value").execute().data
        d = {"premium_keys": [], "features": dict(_DEFAULT_FEATURES), "activation_logs": [], "owner_key_hash": None}
        for row in rows:
            if row["key"] == "owner_key_hash":
                d["owner_key_hash"] = row["value"].get("v") if isinstance(row["value"], dict) else row["value"]
            elif row["key"] == "features":
                d["features"] = row["value"]
        # Load premium keys from dedicated table
        keys = _sb.table("cpm_premium_keys").select("*").execute().data or []
        d["premium_keys"] = keys
        # Load activation logs
        logs = _sb.table("cpm_activation_logs").select("*").order("activated_at", desc=False).execute().data or []
        d["activation_logs"] = logs
        return d
    except Exception as e:
        log.error(f"Supabase load failed: {e}")
        return None

def _sb_save_config(key, value):
    """Upsert a single config key into cpm_config."""
    try:
        _sb.table("cpm_config").upsert({"id": key, "key": key, "value": value, "updated_at": _now()}).execute()
    except Exception as e:
        log.error(f"Supabase config save failed ({key}): {e}")

def _sb_audit(action, details=None, actor="owner"):
    try:
        _sb.table("cpm_audit_log").insert({"action": action, "actor": actor, "details": details or {}, "created_at": _now()}).execute()
    except Exception as e:
        log.warning(f"Audit log failed: {e}")

# ── JSON fallback helpers ──────────────────────────────────────────────────────

def _json_load():
    if not os.path.exists(_DATA_FILE):
        d = {"owner_key_hash": "4a91e7573bef598f06cc8abfae6234b8d4a024bd65a1c17985e309bd6fd87dd2", "premium_keys": [], "features": dict(_DEFAULT_FEATURES), "activation_logs": []}
        _json_save(d); return d
    try:
        with open(_DATA_FILE) as f:
            d = json.load(f)
        for k, v in _DEFAULT_FEATURES.items():
            d.setdefault("features", {})[k] = d["features"].get(k, v)
        return d
    except Exception:
        d = {"owner_key_hash": "4a91e7573bef598f06cc8abfae6234b8d4a024bd65a1c17985e309bd6fd87dd2", "premium_keys": [], "features": dict(_DEFAULT_FEATURES), "activation_logs": []}
        _json_save(d); return d

def _json_save(d):
    try:
        with open(_DATA_FILE, "w") as f:
            json.dump(d, f, indent=2, default=str)
    except Exception as e:
        log.error(f"JSON save failed: {e}")

# ── Unified load/save (Supabase primary, JSON fallback) ───────────────────────

def _load():
    if HAS_SUPABASE:
        d = _sb_load()
        if d is not None:
            return d
    return _json_load()

def _save(d):
    """Save full data dict. Supabase = primary, JSON = fallback."""
    if HAS_SUPABASE:
        try:
            # Save owner_key_hash
            if "owner_key_hash" in d:
                _sb_save_config("owner_key_hash", {"v": d["owner_key_hash"]})
            # Save features
            if "features" in d:
                _sb_save_config("features", d["features"])
            return
        except Exception as e:
            log.error(f"Supabase save failed, falling back to JSON: {e}")
    _json_save(d)

def _key_status(k):
    now = datetime.now(timezone.utc)
    if k.get("revoked"): return "revoked"
    if k.get("expires_at"):
        try:
            exp = datetime.fromisoformat(str(k["expires_at"]).replace("Z", "+00:00"))
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
    h = _hash(k)
    if HAS_SUPABASE:
        _sb_save_config("owner_key_hash", {"v": h})
        _sb_audit("owner_setup", {"action": "first_time_owner_key_set"})
    else:
        d["owner_key_hash"] = h; _json_save(d)
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
    if HAS_SUPABASE:
        keys = _sb.table("cpm_premium_keys").select("*").order("created_at", desc=True).execute().data or []
    else:
        keys = _load().get("premium_keys", [])
    for k in keys: k["status"] = _key_status(k)
    return jsonify({"keys": keys})

@app.route("/api/owner/keys/generate", methods=["POST"])
def owner_keygen():
    data = request.get_json() or {}
    if not _verify_owner(data): return jsonify({"error": "Unauthorized"}), 403
    custom = data.get("custom_key", "").strip().upper()
    if custom:
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
             "revoked": False, "activated_by": [], "note": data.get("note", "")}
    if HAS_SUPABASE:
        try:
            existing = _sb.table("cpm_premium_keys").select("id").eq("key", new_key).execute().data
            if existing:
                return jsonify({"error": "Key already exists"}), 400
            _sb.table("cpm_premium_keys").insert(entry).execute()
            _sb_audit("keygen", {"key": new_key, "expires_at": expires_at, "uses_max": uses_max})
        except Exception as e:
            return jsonify({"error": f"DB error: {e}"}), 500
    else:
        d = _load()
        if any(k["key"] == new_key for k in d.get("premium_keys", [])):
            return jsonify({"error": "Key already exists"}), 400
        d.setdefault("premium_keys", []).append(entry); _json_save(d)
    log.info(f"Premium key generated: {new_key}")
    entry["status"] = "active"
    return jsonify({"success": True, "key": entry})

@app.route("/api/owner/keys/revoke", methods=["POST"])
def owner_revoke():
    data = request.get_json() or {}
    if not _verify_owner(data): return jsonify({"error": "Unauthorized"}), 403
    kid = data.get("id", "")
    if HAS_SUPABASE:
        r = _sb.table("cpm_premium_keys").update({"revoked": True}).eq("id", kid).execute()
        if r.data:
            _sb_audit("revoke_key", {"key_id": kid})
            return jsonify({"success": True})
        return jsonify({"error": "Not found"}), 404
    d = _load()
    for k in d.get("premium_keys", []):
        if k["id"] == kid:
            k["revoked"] = True; k["status"] = "revoked"; _json_save(d)
            return jsonify({"success": True})
    return jsonify({"error": "Not found"}), 404

@app.route("/api/owner/keys/delete", methods=["POST"])
def owner_delete_key():
    data = request.get_json() or {}
    if not _verify_owner(data): return jsonify({"error": "Unauthorized"}), 403
    kid = data.get("id", "")
    if HAS_SUPABASE:
        r = _sb.table("cpm_premium_keys").delete().eq("id", kid).execute()
        if r.data:
            _sb_audit("delete_key", {"key_id": kid})
            return jsonify({"success": True})
        return jsonify({"error": "Not found"}), 404
    d = _load(); before = len(d.get("premium_keys", []))
    d["premium_keys"] = [k for k in d.get("premium_keys", []) if k["id"] != kid]
    if len(d["premium_keys"]) < before:
        _json_save(d); return jsonify({"success": True})
    return jsonify({"error": "Not found"}), 404


# ── Feature routes ─────────────────────────────────────────────────────────────
@app.route("/api/features/status")
def features_status():
    # Features are hardcoded — tiers cannot be changed via UI
    return jsonify({"features": _DEFAULT_FEATURES})

@app.route("/api/owner/analytics", methods=["POST"])
def owner_analytics():
    data = request.get_json() or {}
    if not _verify_owner(data): return jsonify({"error": "Unauthorized"}), 403
    if HAS_SUPABASE:
        try:
            keys = _sb.table("cpm_premium_keys").select("*").execute().data or []
            for k in keys: k["status"] = _key_status(k)
            logs = _sb.table("cpm_activation_logs").select("*").order("activated_at", desc=True).limit(10).execute().data or []
            feats = _load().get("features", _DEFAULT_FEATURES)
            total_logs = _sb.table("cpm_activation_logs").select("id", count="exact").execute().count or 0
            return jsonify({
                "total_keys":        len(keys),
                "active_keys":       sum(1 for k in keys if k["status"] == "active"),
                "used_keys":         sum(1 for k in keys if k["status"] == "used"),
                "total_activations": total_logs,
                "premium_features":  sum(1 for f in feats.values() if f.get("tier") == "premium"),
                "free_features":     sum(1 for f in feats.values() if f.get("tier") == "free"),
                "recent_logs":       logs,
            })
        except Exception as e:
            log.error(f"Analytics Supabase error: {e}")
    d = _load(); keys = d.get("premium_keys", [])
    for k in keys: k["status"] = _key_status(k)
    feats = d.get("features", _DEFAULT_FEATURES)
    logs = d.get("activation_logs", [])
    return jsonify({
        "total_keys":        len(keys),
        "active_keys":       sum(1 for k in keys if k["status"] == "active"),
        "used_keys":         sum(1 for k in keys if k["status"] == "used"),
        "total_activations": len(logs),
        "premium_features":  sum(1 for f in feats.values() if f.get("tier") == "premium"),
        "free_features":     sum(1 for f in feats.values() if f.get("tier") == "free"),
        "recent_logs":       list(reversed(logs[-10:])),
    })

@app.route("/api/owner/logs", methods=["POST"])
def owner_logs():
    data = request.get_json() or {}
    if not _verify_owner(data): return jsonify({"error": "Unauthorized"}), 403
    if HAS_SUPABASE:
        try:
            logs = _sb.table("cpm_activation_logs").select("*").order("activated_at", desc=True).limit(200).execute().data or []
            return jsonify({"logs": logs})
        except Exception as e:
            log.error(f"Logs Supabase error: {e}")
    return jsonify({"logs": list(reversed(_load().get("activation_logs", [])))})


# ── User activation ────────────────────────────────────────────────────────────
@app.route("/api/user/activate", methods=["POST"])
def user_activate():
    data = request.get_json() or {}
    entered = data.get("key", "").strip().upper()
    if not entered: return jsonify({"error": "No key provided"}), 400
    user_id = data.get("user_id", "anonymous")
    ip = request.remote_addr or ""

    d = _load()
    stored_hash = d.get("owner_key_hash")
    if stored_hash and _hash(entered) == stored_hash:
        log.info("Owner key used for premium activation")
        if HAS_SUPABASE:
            _sb_audit("owner_activate", {"user_id": user_id, "ip": ip}, actor="user")
        return jsonify({"success": True, "expires_at": None, "key_id": "OWNER"})

    if HAS_SUPABASE:
        try:
            rows = _sb.table("cpm_premium_keys").select("*").eq("key", entered).execute().data
            if not rows:
                return jsonify({"error": "Invalid activation key — check your key and try again"}), 403
            k = rows[0]
            st = _key_status(k)
            if st == "revoked": return jsonify({"error": "This key has been revoked"}), 403
            if st == "expired": return jsonify({"error": "This key has expired"}), 403
            if st == "used":    return jsonify({"error": "This key has already been fully used"}), 403
            new_count = k.get("uses_count", 0) + 1
            activated_by = k.get("activated_by") or []
            if isinstance(activated_by, str):
                try: activated_by = json.loads(activated_by)
                except: activated_by = []
            activated_by.append(user_id)
            _sb.table("cpm_premium_keys").update({
                "uses_count": new_count,
                "activated_by": activated_by
            }).eq("id", k["id"]).execute()
            _sb.table("cpm_activation_logs").insert({
                "key_id": k["id"], "key": entered, "user_id": user_id,
                "activated_at": _now(), "expires_at": k.get("expires_at"), "ip_address": ip
            }).execute()
            _sb_audit("key_activate", {"key": entered, "user_id": user_id, "ip": ip}, actor="user")
            log.info(f"Key {entered} activated (Supabase)")
            return jsonify({"success": True, "expires_at": k.get("expires_at"), "key_id": k["id"]})
        except Exception as e:
            log.error(f"Supabase activate error: {e}")
            return jsonify({"error": "Server error during activation"}), 500

    # JSON fallback
    for k in d.get("premium_keys", []):
        if k["key"].upper() == entered:
            st = _key_status(k)
            if st == "revoked": return jsonify({"error": "This key has been revoked"}), 403
            if st == "expired": return jsonify({"error": "This key has expired"}), 403
            if st == "used":    return jsonify({"error": "This key has already been fully used"}), 403
            k["uses_count"] = k.get("uses_count", 0) + 1
            k.setdefault("activated_by", []).append(user_id)
            k["status"] = _key_status(k)
            d.setdefault("activation_logs", []).append({
                "key_id": k["id"], "key": entered, "user_id": user_id,
                "activated_at": _now(), "expires_at": k.get("expires_at"),
            })
            _json_save(d)
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

# ── local.lt tunnel ───────────────────────────────────────────────────────────
_tunnel_url = None
_tunnel_ready = False

_URL_FILE = "/tmp/cpm-tunnel.url"

def _start_localtunnel(port):
    global _tunnel_url, _tunnel_ready
    # Clear old URL file
    try:
        if os.path.exists(_URL_FILE): os.remove(_URL_FILE)
    except Exception: pass
    try:
        lt_path = shutil.which("lt") or shutil.which("localtunnel")
        if not lt_path:
            log.warning("localtunnel (lt) not found — tunnel disabled")
            return
        log.info("Starting local.lt tunnel…")
        proc = subprocess.Popen(
            [lt_path, "--port", str(port)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        for line in proc.stdout:
            line = line.strip()
            m = re.search(r'https?://[^\s]+loca\.lt[^\s]*', line)
            if not m:
                m = re.search(r'https?://[^\s]+', line)
            if m:
                _tunnel_url = m.group(0).rstrip('.')
                _tunnel_ready = True
                log.info(f"Tunnel ready: {_tunnel_url}")
                # Write URL to file so login message can read it
                try:
                    with open(_URL_FILE, "w") as f:
                        f.write(_tunnel_url + "\n")
                except Exception: pass
                break
    except Exception as e:
        log.warning(f"Tunnel error: {e}")

@app.route("/api/tunnel/status")
def tunnel_status():
    return jsonify({"ready": _tunnel_ready, "url": _tunnel_url})


# ── UI Settings (server-side persistence) ─────────────────────────────────────

_UI_DIR  = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ui_data')
_UI_SETS = os.path.join(_UI_DIR, 'settings.json')
_ALLOWED_BG_MIME = {'image/jpeg','image/png','image/gif','image/webp','video/mp4','video/webm','video/ogg'}

def _ui_ensure():
    os.makedirs(_UI_DIR, exist_ok=True)
    if not os.path.exists(_UI_SETS):
        with open(_UI_SETS, 'w') as f: json.dump({}, f)

def _ui_load_all():
    _ui_ensure()
    try:
        with open(_UI_SETS) as f: return json.load(f)
    except Exception:
        return {}

def _ui_save_all(d):
    _ui_ensure()
    try:
        tmp = _UI_SETS + '.tmp'
        with open(tmp, 'w') as f: json.dump(d, f, indent=2)
        os.replace(tmp, _UI_SETS)
    except Exception as e:
        log.error(f"UI settings save failed: {e}")

def _ui_token():
    t = (request.headers.get('X-Client-Token') or '').strip()
    # Only allow safe characters; ignore obviously invalid tokens
    return t[:128] if re.match(r'^[a-zA-Z0-9_\-]{8,128}$', t) else ''

@app.route('/api/ui/settings', methods=['GET'])
def ui_settings_get():
    token = _ui_token()
    if not token: return jsonify({}), 200
    all_s = _ui_load_all()
    return jsonify(all_s.get(token, {}))

@app.route('/api/ui/settings', methods=['POST'])
def ui_settings_save():
    token = _ui_token()
    if not token: return jsonify({'error': 'No token'}), 400
    data = request.get_json() or {}
    # Strip out base64 blobs if somehow sent
    data.pop('cpm_ui_bg_img', None)
    data.pop('cpm_ui_bg_video', None)
    all_s = _ui_load_all()
    existing = all_s.get(token, {})
    # Preserve server-side bg fields (set only by background upload route)
    for k in ('bg_url', 'bg_type'):
        if k not in data and k in existing:
            data[k] = existing[k]
    data['updated_at'] = _now()
    all_s[token] = data
    _ui_save_all(all_s)
    return jsonify({'ok': True})

@app.route('/api/ui/background', methods=['POST'])
def ui_bg_upload():
    token = _ui_token()
    if not token: return jsonify({'error': 'No token'}), 400
    f = request.files.get('file')
    if not f: return jsonify({'error': 'No file'}), 400
    if f.mimetype not in _ALLOWED_BG_MIME:
        return jsonify({'error': 'File type not allowed'}), 400
    ext = (f.filename.rsplit('.', 1)[-1].lower() if f.filename and '.' in f.filename else 'bin')
    ext = re.sub(r'[^a-z0-9]', '', ext)[:6] or 'bin'
    safe_tok = re.sub(r'[^a-zA-Z0-9]', '', token)[:24]
    fname = f'{safe_tok}_bg.{ext}'
    _ui_ensure()
    save_path = os.path.join(_UI_DIR, fname)
    # Remove old bg file for this token
    all_s = _ui_load_all()
    old = all_s.get(token, {}).get('bg_url', '')
    if old:
        old_fname = old.split('/')[-1]
        old_path = os.path.join(_UI_DIR, old_fname)
        try:
            if os.path.exists(old_path): os.remove(old_path)
        except Exception: pass
    f.save(save_path)
    bg_url = f'/api/ui/assets/{fname}'
    bg_type = 'video' if f.mimetype.startswith('video') else 'image'
    s = all_s.get(token, {})
    s['bg_url'] = bg_url
    s['bg_type'] = bg_type
    s['updated_at'] = _now()
    all_s[token] = s
    _ui_save_all(all_s)
    log.info(f"UI background saved for token ..{token[-6:]}: {fname}")
    return jsonify({'ok': True, 'url': bg_url, 'type': bg_type})

@app.route('/api/ui/background', methods=['DELETE'])
def ui_bg_delete():
    token = _ui_token()
    if not token: return jsonify({'error': 'No token'}), 400
    all_s = _ui_load_all()
    s = all_s.get(token, {})
    old_url = s.pop('bg_url', None)
    s.pop('bg_type', None)
    s['updated_at'] = _now()
    all_s[token] = s
    _ui_save_all(all_s)
    if old_url:
        fname = old_url.split('/')[-1]
        fpath = os.path.join(_UI_DIR, fname)
        try:
            if os.path.exists(fpath): os.remove(fpath)
        except Exception: pass
    return jsonify({'ok': True})

@app.route('/api/ui/assets/<path:filename>')
def ui_assets(filename):
    _ui_ensure()
    fname = os.path.basename(filename)
    fpath = os.path.join(_UI_DIR, fname)
    if not os.path.exists(fpath): return '', 404
    return send_file(fpath)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    log.info(f"CPM Panel listening on port {port}")
    threading.Thread(target=_start_localtunnel, args=(port,), daemon=True).start()
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
  html,body{overflow-x:hidden}
  body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);display:flex;min-height:100vh;margin:0}

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
  .two-panel{display:grid;grid-template-columns:1fr minmax(0,380px);gap:20px;align-items:start}
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

  .hamburger{display:none;background:none;border:none;cursor:pointer;padding:6px 8px;border-radius:6px;color:var(--text);flex-shrink:0}
  .hamburger:hover{background:var(--blue-light)}
  .hamburger svg{display:block}
  .sidebar-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.4);z-index:40}
  .sidebar-overlay.open{display:block}
  /* ── tunnel banner ── */
  .tunnel-banner{display:none;background:#0f172a;color:#60a5fa;font-size:12px;font-family:monospace;padding:7px 16px;align-items:center;gap:10px;border-bottom:1px solid #1e3a5f;flex-wrap:wrap}
  .tunnel-banner.show{display:flex}
  .tunnel-url{flex:1;word-break:break-all;letter-spacing:.03em}
  .tunnel-copy{background:#1e293b;border:none;color:#94a3b8;font-size:11px;font-weight:600;padding:4px 10px;border-radius:6px;cursor:pointer;white-space:nowrap;flex-shrink:0}
  .tunnel-copy:hover{background:#334155;color:#e2e8f0}
  @media(max-width:900px){
    aside{display:none;position:fixed;top:0;left:0;bottom:0;width:260px;z-index:50;box-shadow:4px 0 24px rgba(0,0,0,.18);overflow-y:auto}
    aside.open{display:flex !important}
    .mob-nav{display:none}
    .main{padding-bottom:0}
    .content{padding:16px}
    .grid-2,.grid-3,.two-panel,.dash-bottom{grid-template-columns:1fr}
    .form-grid{grid-template-columns:1fr}
    h1{font-size:20px}
    .topbar{padding:0 16px}
    .card-body{padding:14px}
    .hamburger{display:inline-flex !important;align-items:center;justify-content:center}
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

  /* ── UI Customization ── */
  .uic-section{margin-bottom:22px}
  .uic-label{font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);margin-bottom:10px;display:flex;align-items:center;gap:6px}
  .uic-presets{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:4px}
  .uic-preset{padding:8px 16px;border-radius:20px;border:2px solid var(--border);background:var(--card);color:var(--text);font-size:13px;font-weight:600;cursor:pointer;transition:.2s}
  .uic-preset:hover{border-color:var(--blue);color:var(--blue)}
  .uic-preset.active{border-color:var(--blue);background:var(--blue);color:#fff}
  .uic-color-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(175px,1fr));gap:10px}
  .uic-color-row{display:flex;align-items:center;gap:10px;padding:10px 12px;background:var(--blue-light);border:1px solid var(--blue-mid);border-radius:10px}
  .uic-swatch{width:36px;height:36px;border-radius:8px;border:2px solid var(--border);cursor:pointer;flex-shrink:0;padding:0;overflow:hidden;position:relative}
  .uic-swatch input[type=color]{position:absolute;inset:-4px;width:calc(100% + 8px);height:calc(100% + 8px);border:none;cursor:pointer;padding:0}
  .uic-color-name{font-size:12px;font-weight:600;color:var(--text);flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .uic-bg-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:12px;margin-bottom:12px}
  .uic-bg-card{border-radius:12px;overflow:hidden;cursor:pointer;border:3px solid transparent;transition:.2s;box-shadow:var(--shadow)}
  .uic-bg-card:hover{border-color:var(--blue);transform:translateY(-2px)}
  .uic-bg-card.active{border-color:var(--blue);box-shadow:0 0 0 3px rgba(37,99,235,.25)}
  .uic-bg-thumb{height:80px;width:100%;display:block;background-size:cover;background-position:center;background-size:200% 200%;animation:cpm-thumb-idle 6s ease infinite}
  .uic-bg-name{padding:6px 10px;font-size:12px;font-weight:600;background:var(--card);color:var(--text);text-align:center}
  .uic-custom-row{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-top:8px}
  .uic-url-inp{flex:1;min-width:200px;padding:9px 12px;border:1.5px solid var(--border);border-radius:8px;font-size:13px;background:var(--card);color:var(--text);outline:none;transition:.2s}
  .uic-url-inp:focus{border-color:var(--blue);box-shadow:0 0 0 3px rgba(37,99,235,.1)}
  .uic-apply-btn{padding:9px 18px;border-radius:8px;border:none;background:var(--blue);color:#fff;font-size:13px;font-weight:600;cursor:pointer;transition:.2s;white-space:nowrap}
  .uic-apply-btn:hover{background:#1d4ed8}
  .uic-font-row{display:flex;gap:12px;align-items:center;flex-wrap:wrap}
  .uic-select{padding:9px 12px;border:1.5px solid var(--border);border-radius:8px;font-size:13px;background:var(--card);color:var(--text);outline:none;transition:.2s;cursor:pointer;width:100%;max-width:340px}
  .uic-select:focus{border-color:var(--blue)}
  .uic-range-row{display:flex;align-items:center;gap:12px}
  .uic-range{flex:1;accent-color:var(--blue);height:5px;max-width:300px}
  .uic-range-val{font-size:13px;font-weight:700;color:var(--blue);min-width:40px}
  .uic-action-bar{display:flex;gap:12px;flex-wrap:wrap;padding-top:8px}
  .uic-save-btn{padding:11px 26px;background:var(--blue);color:#fff;border:none;border-radius:10px;font-size:14px;font-weight:700;cursor:pointer;transition:.2s}
  .uic-save-btn:hover{background:#1d4ed8;transform:translateY(-1px)}
  .uic-reset-btn{padding:11px 26px;background:var(--card);color:var(--muted);border:1.5px solid var(--border);border-radius:10px;font-size:14px;font-weight:600;cursor:pointer;transition:.2s}
  .uic-reset-btn:hover{border-color:#dc2626;color:#dc2626}
  .uic-radius-row{display:flex;gap:8px;flex-wrap:wrap}
  .uic-radius-opt{padding:8px 16px;border-radius:8px;border:2px solid var(--border);background:var(--card);color:var(--text);font-size:13px;font-weight:600;cursor:pointer;transition:.2s}
  .uic-radius-opt:hover{border-color:var(--blue);color:var(--blue)}
  .uic-radius-opt.active{border-color:var(--blue);background:var(--blue);color:#fff}
  .uic-upload-grid{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:14px}
  .uic-upload-drop{border:2px dashed var(--border);border-radius:12px;height:140px;display:flex;align-items:center;justify-content:center;cursor:pointer;transition:.2s;overflow:hidden;background:var(--blue-light);margin-bottom:8px}
  .uic-upload-drop:hover{border-color:var(--blue)}
  .uic-clear-btn{width:100%;padding:8px;border:none;border-radius:8px;background:#fee2e2;color:#dc2626;font-size:12px;font-weight:600;cursor:pointer;transition:.15s}
  .uic-clear-btn:hover{background:#fca5a5}
  .uic-tip{font-size:12px;color:var(--muted);padding:8px 12px;background:var(--blue-light);border-radius:8px;margin-top:8px}
  @keyframes cpm-grad{0%{background-position:0% 50%}50%{background-position:100% 50%}100%{background-position:0% 50%}}
  @keyframes cpm-thumb-idle{0%{background-position:0% 50%}50%{background-position:100% 50%}100%{background-position:0% 50%}}
</style>
</head>
<body>
<div id="cpm-bg-layer" style="position:fixed;inset:0;z-index:-2;pointer-events:none;transition:background .6s,background-image .6s"></div>
<div id="cpm-bg-style"></div>
<video id="cpm-bg-video" autoplay loop muted playsinline style="display:none;position:fixed;inset:0;z-index:-3;width:100%;height:100%;object-fit:cover;pointer-events:none"></video>

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
    <a onclick="openStorageWithCheck(this)">
      <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4.03 3-9 3S3 13.66 3 12"/><path d="M3 5v14c0 1.66 4.03 3 9 3s9-1.34 9-3V5"/></svg>
      Cloud Storage
    </a>
    <a onclick="openUiCustomizeWithCheck(this)">
      <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M12 22C6.5 22 2 17.5 2 12c0-5.5 4.5-10 10-10 4.5 0 8 3.1 8 7 0 2.8-2.2 5-5 5h-1.4c-.6 0-1 .5-1 1.1 0 .3.1.5.1.8.1.5-.2 1-.7 1.1z"/><circle cx="8.5" cy="9.5" r="1.5" fill="currentColor" stroke="none"/><circle cx="12" cy="7" r="1.5" fill="currentColor" stroke="none"/><circle cx="15.5" cy="9.5" r="1.5" fill="currentColor" stroke="none"/></svg>
      UI Customize
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
  <!-- Tunnel banner -->
  <div class="tunnel-banner" id="tunnel-banner">
    <svg width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 010 20M12 2a15.3 15.3 0 000 20"/></svg>
    <span style="color:#94a3b8;white-space:nowrap">Public URL:</span>
    <span class="tunnel-url" id="tunnel-url-text">—</span>
    <button class="tunnel-copy" onclick="copyTunnelUrl()">Copy</button>
  </div>

  <div class="topbar">
    <button class="hamburger" onclick="toggleSidebar()" aria-label="Toggle menu">
      <svg width="20" height="20" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24"><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="18" x2="21" y2="18"/></svg>
    </button>
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
        <button class="owner-tab" onclick="ownerTab('logs',this)">📋 Logs</button>
      </div>

      <!-- Analytics -->
      <div class="owner-tab-panel active" id="otab-analytics">
        <div class="owner-analytics" id="ana-cards">
          <div class="ana-card"><div class="ana-num" style="color:var(--blue)">—</div><div class="ana-label">Total Keys</div></div>
          <div class="ana-card"><div class="ana-num" style="color:var(--green)">—</div><div class="ana-label">Active Keys</div></div>
          <div class="ana-card"><div class="ana-num" style="color:#0369a1">—</div><div class="ana-label">Used Keys</div></div>
          <div class="ana-card"><div class="ana-num" style="color:#7c3aed">—</div><div class="ana-label">Activations</div></div>
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
            <button class="btn" onclick="requirePremium('file_upload',()=>storageUpload())" style="background:var(--blue);color:#fff;display:flex;align-items:center;gap:6px">
              <svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24"><polyline points="16 16 12 12 8 16"/><line x1="12" y1="12" x2="12" y2="21"/><path d="M20.39 18.39A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.3"/></svg>
              Upload File 👑
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

    <!-- UI CUSTOMIZATION -->
    <section class="page" id="page-uicustom">
      <h1>🎨 UI Customization</h1>
      <p class="subtitle">Personalize every aspect of your panel's appearance — changes apply live instantly.</p>

      <!-- Color Themes -->
      <div class="card" style="margin-bottom:20px">
        <div class="card-header">
          <div class="card-title">
            <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M12 22C6.5 22 2 17.5 2 12c0-5.5 4.5-10 10-10 4.5 0 8 3.1 8 7 0 2.8-2.2 5-5 5h-1.4c-.6 0-1 .5-1 1.1 0 .3.1.5.1.8.1.5-.2 1-.7 1.1z"/><circle cx="8.5" cy="9.5" r="1.5" fill="currentColor" stroke="none"/><circle cx="12" cy="7" r="1.5" fill="currentColor" stroke="none"/><circle cx="15.5" cy="9.5" r="1.5" fill="currentColor" stroke="none"/></svg>
            Color Themes
          </div>
          <p class="card-desc">One-click presets that style the whole panel instantly</p>
        </div>
        <div class="card-body">
          <div class="uic-section">
            <div class="uic-label">Theme Presets</div>
            <div class="uic-presets" id="uic-preset-btns"></div>
          </div>
          <div class="uic-section" style="margin-top:16px;padding-top:14px;border-top:1px solid var(--border)">
            <div class="uic-label">Quick Color Adjustments</div>
            <div style="display:flex;gap:20px;flex-wrap:wrap;margin-top:10px">
              <div class="uic-color-row">
                <div class="uic-swatch" id="sw-text"><input type="color" id="uic-clr-text" oninput="uicPickColor('text',this)" onchange="uicPickColor('text',this)"/></div>
                <span class="uic-color-name">Text Color</span>
              </div>
              <div class="uic-color-row">
                <div class="uic-swatch" id="sw-blue"><input type="color" id="uic-clr-blue" oninput="uicPickColor('blue',this)" onchange="uicPickColor('blue',this)"/></div>
                <span class="uic-color-name">Button Color</span>
              </div>
            </div>
            <div class="uic-tip" style="margin-top:10px">💡 These adjustments override the current theme. Select any preset to reset them.</div>
          </div>
        </div>
      </div>

      <!-- Background -->
      <div class="card" style="margin-bottom:20px">
        <div class="card-header">
          <div class="card-title">
            <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8M12 17v4"/></svg>
            Background
          </div>
          <p class="card-desc">Upload your own image or video as a full-screen panel background</p>
        </div>
        <div class="card-body">
          <div class="uic-upload-grid">
            <div>
              <div class="uic-label">📷 Background Image</div>
              <div class="uic-upload-drop" id="uic-img-drop" onclick="document.getElementById('uic-img-file').click()" ondragover="event.preventDefault()" ondrop="uicDropImage(event)">
                <div id="uic-img-preview-wrap" style="display:flex;flex-direction:column;align-items:center;gap:8px;color:var(--muted)">
                  <svg width="32" height="32" fill="none" stroke="currentColor" stroke-width="1.5" viewBox="0 0 24 24"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="M21 15l-5-5L5 21"/></svg>
                  <span style="font-size:13px;font-weight:600">Click or drag an image here</span>
                  <span style="font-size:11px">JPG, PNG, GIF, WebP — max 8 MB</span>
                </div>
              </div>
              <input type="file" id="uic-img-file" accept="image/*" style="display:none" onchange="uicUploadImage(this)"/>
              <button id="uic-img-clear-btn" class="uic-clear-btn" onclick="uicClearImage()" style="display:none">✕ Remove Image</button>
            </div>
            <div>
              <div class="uic-label">🎬 Background Video</div>
              <div class="uic-upload-drop" id="uic-vid-drop" onclick="document.getElementById('uic-vid-file').click()" ondragover="event.preventDefault()" ondrop="uicDropVideo(event)">
                <div id="uic-vid-preview-wrap" style="display:flex;flex-direction:column;align-items:center;gap:8px;color:var(--muted)">
                  <svg width="32" height="32" fill="none" stroke="currentColor" stroke-width="1.5" viewBox="0 0 24 24"><polygon points="23 7 16 12 23 17 23 7"/><rect x="1" y="5" width="15" height="14" rx="2"/></svg>
                  <span style="font-size:13px;font-weight:600">Click or drag a video here</span>
                  <span style="font-size:11px">MP4, WebM — max 20 MB</span>
                </div>
              </div>
              <input type="file" id="uic-vid-file" accept="video/*" style="display:none" onchange="uicUploadVideo(this)"/>
              <button id="uic-vid-clear-btn" class="uic-clear-btn" onclick="uicClearVideo()" style="display:none">✕ Remove Video</button>
            </div>
          </div>
          <div class="uic-tip">💡 Tip: After setting a background, pick a dark theme (Dark, Ocean, Midnight) so text stays readable on top.</div>
        </div>
      </div>

      <!-- Typography -->
      <div class="card" style="margin-bottom:20px">
        <div class="card-header">
          <div class="card-title">
            <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><polyline points="4 7 4 4 20 4 20 7"/><line x1="9" y1="20" x2="15" y2="20"/><line x1="12" y1="4" x2="12" y2="20"/></svg>
            Typography
          </div>
          <p class="card-desc">Font family and base size</p>
        </div>
        <div class="card-body">
          <div class="uic-section">
            <div class="uic-label">Font Family</div>
            <div class="uic-font-row">
              <select class="uic-select" id="uic-font-select" onchange="uicApplyFont()">
                <option value="">System Default (Segoe UI)</option>
                <option value="Inter">Inter</option>
                <option value="Roboto">Roboto</option>
                <option value="Poppins">Poppins</option>
                <option value="Nunito">Nunito</option>
                <option value="Raleway">Raleway</option>
                <option value="'JetBrains Mono','Fira Code',monospace">JetBrains Mono (Code)</option>
                <option value="'Courier New',monospace">Courier New (Monospace)</option>
                <option value="Georgia,serif">Georgia (Serif)</option>
              </select>
            </div>
          </div>
          <div class="uic-section">
            <div class="uic-label">Font Size — <span id="uic-size-val" style="color:var(--blue);font-size:13px">14px</span></div>
            <div class="uic-range-row">
              <input type="range" class="uic-range" id="uic-font-size" min="11" max="20" value="14" oninput="uicApplyFont()"/>
            </div>
          </div>
        </div>
      </div>

      <!-- Corner Style -->
      <div class="card" style="margin-bottom:20px">
        <div class="card-header">
          <div class="card-title">
            <svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><rect x="3" y="3" width="18" height="18" rx="5"/></svg>
            Corner Style
          </div>
          <p class="card-desc">Controls roundness of cards and buttons across the whole panel</p>
        </div>
        <div class="card-body">
          <div class="uic-radius-row">
            <button class="uic-radius-opt" data-r="0px" onclick="uicApplyRadius('0px')">⬜ Sharp</button>
            <button class="uic-radius-opt" data-r="6px" onclick="uicApplyRadius('6px')">▫️ Slight</button>
            <button class="uic-radius-opt active" data-r="12px" onclick="uicApplyRadius('12px')">🔲 Rounded (Default)</button>
            <button class="uic-radius-opt" data-r="20px" onclick="uicApplyRadius('20px')">⭕ Extra Round</button>
          </div>
        </div>
      </div>

      <!-- Save / Reset -->
      <div class="uic-action-bar">
        <button class="uic-save-btn" onclick="saveUiCustomize()">💾 Save Settings</button>
        <button class="uic-reset-btn" onclick="resetUiCustomize()">↩ Reset to Default</button>
      </div>
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

<!-- Sidebar overlay (mobile) -->
<div class="sidebar-overlay" id="sidebar-overlay" onclick="closeSidebar()"></div>

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

// ── sidebar drawer (mobile) ─────────────────────────────────────────────────
function toggleSidebar() {
  const aside = document.querySelector('aside');
  const overlay = document.getElementById('sidebar-overlay');
  const isOpen = aside.classList.contains('open');
  aside.classList.toggle('open', !isOpen);
  overlay.classList.toggle('open', !isOpen);
}
function closeSidebar() {
  document.querySelector('aside').classList.remove('open');
  document.getElementById('sidebar-overlay').classList.remove('open');
}

// ── navigation ─────────────────────────────────────────────────────────────
const MOB_IDS = {dashboard:'mob-dash', vps:'mob-vps', create:'mob-create'};
function showPage(id, el) {
  closeSidebar();
  document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('nav a, .mob-nav a').forEach(a => a.classList.remove('active'));
  document.getElementById('page-' + id).classList.add('active');
  if (el) el.classList.add('active');
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

// ── client token (only a lookup key — actual data lives on server) ──────────
function getClientToken() {
  let t = localStorage.getItem('cpm_client_token');
  if (!t || t.length < 16) {
    const arr = new Uint8Array(24);
    crypto.getRandomValues(arr);
    t = Array.from(arr, b => b.toString(16).padStart(2,'0')).join('');
    localStorage.setItem('cpm_client_token', t);
  }
  return t;
}

// ── fetch helpers ──────────────────────────────────────────────────────────
async function api(path, opts={}) {
  const hdrs = {'Content-Type':'application/json','X-Client-Token':getClientToken(),...(opts.headers||{})};
  const r = await fetch(path, {...opts, headers:hdrs});
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
      <button class="qa-btn qa-start"   ${isRunning?'disabled':''} onclick="requirePremium('vps_start',()=>dashAction('start'))">
        <svg width="15" height="15" fill="currentColor" viewBox="0 0 24 24"><polygon points="5 3 19 12 5 21 5 3"/></svg> Start Instance 👑
      </button>
      <button class="qa-btn qa-stop"    ${isStopped?'disabled':''} onclick="dashAction('stop')">
        <svg width="15" height="15" fill="currentColor" viewBox="0 0 24 24"><rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/></svg> Stop Instance
      </button>
      <button class="qa-btn qa-restart" ${isStopped?'disabled':''} onclick="requirePremium('vps_restart',()=>dashAction('restart'))">
        <svg width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/></svg> Restart Instance 👑
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
      <button class="btn btn-start"   onclick="requirePremium('vps_start',()=>doAction('start'))"   ${isRunning?'disabled':''}>
        <svg width="13" height="13" fill="currentColor" viewBox="0 0 24 24"><polygon points="5 3 19 12 5 21 5 3"/></svg>Start</button>
      <button class="btn btn-stop"    onclick="doAction('stop')"    ${isStopped?'disabled':''}>
        <svg width="13" height="13" fill="currentColor" viewBox="0 0 24 24"><rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/></svg>Stop</button>
      <button class="btn btn-restart" onclick="requirePremium('vps_restart',()=>doAction('restart'))" ${isStopped?'disabled':''}>
        <svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/></svg>Restart</button>
      <button class="btn btn-delete"  onclick="confirmDelete('${name}')">
        <svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14H6L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/><path d="M9 6V4h6v2"/></svg>Delete</button>
      <button class="btn btn-ssh" onclick="openSsh('${name}')" style="grid-column:1/-1">
        <svg width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>Get SSH Access 👑</button>
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
  if (!canUse('vps_delete')) { openUpgrade(); return; }
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
  if (!canUse('vps_create')) { openUpgrade(); return; }
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
      topText.textContent = '⚠ KVM not available';
      // Disable all VPS action buttons
      document.querySelectorAll('.btn-start,.btn-stop,.btn-restart,.btn-delete,.btn-ssh,.qa-start,.qa-stop,.qa-restart,.qa-ssh').forEach(b => {
        b.disabled = true; b.title = d.message;
      });
      // Overlay VPS list with clear message
      const vl = document.getElementById('vps-list');
      if (vl) vl.innerHTML = `<li style="padding:24px 12px;text-align:center">
        <div style="font-size:28px;margin-bottom:10px">⚠️</div>
        <div style="font-weight:700;font-size:15px;color:var(--red);margin-bottom:6px">KVM Not Available on This Host</div>
        <div style="font-size:13px;color:var(--muted);line-height:1.6">${d.message}<br><br>
        To create real VPS instances, your server must support KVM hardware virtualisation.<br>
        Most shared VPS providers do not allow nested KVM.<br>
        You need a <strong>dedicated server or bare-metal host</strong> with KVM enabled.</div>
      </li>`;
      // Disable create form
      const cf = document.getElementById('create-form');
      if (cf) {
        const sub = cf.querySelector('button[type=submit]');
        if (sub) { sub.disabled = true; sub.textContent = '⚠ KVM Not Available'; }
        if (!document.getElementById('kvm-create-notice')) {
          const notice = document.createElement('div');
          notice.id = 'kvm-create-notice';
          notice.style.cssText = 'background:#fef3c7;border:1px solid #f59e0b;border-radius:10px;padding:14px 18px;margin-bottom:18px;font-size:13px;color:#92400e;line-height:1.6';
          notice.innerHTML = `<strong>⚠ KVM virtualisation is not available on this host.</strong><br>Creating VPS instances requires a dedicated/bare-metal server with KVM enabled. Your current host does not support it.`;
          cf.insertBefore(notice, cf.firstChild);
        }
      }
    } else {
      banner.classList.remove('show');
      topText.textContent = 'KVM Virtualisation Active';
      const notice = document.getElementById('kvm-create-notice');
      if (notice) notice.remove();
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
  if (!canUse('ssh_access')) { openUpgrade(); return; }
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
  return plan === 'premium' || plan === 'paid' || plan === 'owner';
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

function openStorageWithCheck(el) {
  requirePremium('file_manager', () => { showPage('storage', el); storageOpen(); });
}

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
              ${f.type === 'file' ? `<button class="tbl-btn" onclick="requirePremium('file_download',()=>{ window.location='/api/storage/download?path=${encodeURIComponent(fullRel)}'; })" style="display:inline-block">⬇ Download 👑</button>` : ''}
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

// ── Tunnel URL ────────────────────────────────────────────────────────────
let _tunnelUrl = null;

async function loadTunnelUrl() {
  try {
    const d = await api('/api/tunnel/status');
    if (d.ready && d.url) {
      _tunnelUrl = d.url;
      const banner = document.getElementById('tunnel-banner');
      const urlEl  = document.getElementById('tunnel-url-text');
      if (banner && urlEl) {
        urlEl.textContent = d.url;
        banner.classList.add('show');
      }
    }
  } catch(e) {}
}

function copyTunnelUrl() {
  if (!_tunnelUrl) return;
  navigator.clipboard.writeText(_tunnelUrl).then(() => {
    const btn = document.querySelector('.tunnel-copy');
    if (btn) { btn.textContent = 'Copied!'; setTimeout(() => btn.textContent = 'Copy', 2000); }
  });
}

// Poll tunnel every 5s until ready (lt can take a few seconds to connect)
function pollTunnel(tries=0) {
  loadTunnelUrl().then(() => {
    if (!_tunnelUrl && tries < 24) setTimeout(() => pollTunnel(tries+1), 5000);
  });
}

// ── UI Customization ──────────────────────────────────────────────────────
const UIC_PRESETS = {
  default:  { label:'☀️ Default',    bg:'#f0f4f8', sidebar:'#ffffff', card:'#ffffff', blue:'#2563eb', text:'#0f172a', muted:'#64748b', border:'#e2e8f0', green:'#16a34a', red:'#dc2626', amber:'#d97706' },
  dark:     { label:'🌙 Dark',       bg:'#0f172a', sidebar:'#1e293b', card:'#1e293b', blue:'#3b82f6', text:'#f1f5f9', muted:'#94a3b8', border:'#334155', green:'#22c55e', red:'#ef4444', amber:'#f59e0b' },
  ocean:    { label:'🌊 Ocean',      bg:'#0c1a2e', sidebar:'#0f2744', card:'#122f50', blue:'#38bdf8', text:'#e0f2fe', muted:'#7dd3fc', border:'#1e4976', green:'#34d399', red:'#f87171', amber:'#fbbf24' },
  sakura:   { label:'🌸 Sakura',     bg:'#fff0f5', sidebar:'#ffe4ef', card:'#fff8fb', blue:'#e879a0', text:'#4a1942', muted:'#be8aac', border:'#f9c6db', green:'#22c55e', red:'#ef4444', amber:'#f59e0b' },
  forest:   { label:'🌿 Forest',     bg:'#0a1f0f', sidebar:'#0f2b15', card:'#122b18', blue:'#4ade80', text:'#dcfce7', muted:'#86efac', border:'#1a4225', green:'#86efac', red:'#f87171', amber:'#fbbf24' },
  sunset:   { label:'🌅 Sunset',     bg:'#1c0a00', sidebar:'#2d1a00', card:'#2d1a00', blue:'#f97316', text:'#fff7ed', muted:'#fdba74', border:'#431a00', green:'#86efac', red:'#f87171', amber:'#fbbf24' },
  midnight: { label:'🌃 Midnight',   bg:'#0a0a1a', sidebar:'#0d0d2b', card:'#12122e', blue:'#818cf8', text:'#e0e7ff', muted:'#a5b4fc', border:'#1e1e4a', green:'#4ade80', red:'#f87171', amber:'#fbbf24' },
  cyber:    { label:'⚡ Cyber',      bg:'#000d0d', sidebar:'#001a1a', card:'#001a1a', blue:'#00ffcc', text:'#ccffee', muted:'#00aa88', border:'#004433', green:'#00ffaa', red:'#ff4466', amber:'#ffcc00' },
  candy:    { label:'🍬 Candy',      bg:'#fff0ff', sidebar:'#ffe0ff', card:'#fff0ff', blue:'#a855f7', text:'#2e1065', muted:'#c084fc', border:'#f5d0fe', green:'#22c55e', red:'#ef4444', amber:'#f59e0b' },
  steel:    { label:'🔩 Steel',      bg:'#1c1f26', sidebar:'#22262f', card:'#22262f', blue:'#60a5fa', text:'#e2e8f0', muted:'#94a3b8', border:'#2d333b', green:'#4ade80', red:'#f87171', amber:'#fbbf24' },
  glass:    { label:'💎 Light Transparent', bg:'transparent', sidebar:'rgba(255,255,255,0.15)', card:'rgba(255,255,255,0.12)', blue:'#60a5fa', text:'#f8fafc', muted:'#e2e8f0', border:'rgba(255,255,255,0.25)', green:'#4ade80', red:'#f87171', amber:'#fbbf24' },
};

// Background handled via file uploads — no preset gallery

let uicCurrentPreset = 'default';
let uicCurrentBg = 'none';
let uicSettings = {};

function openUiCustomizeWithCheck(el) {
  requirePremium('ui_customize', () => { showPage('uicustom', el); uicRenderPage(); });
}

function uicRenderPage() {
  const presetEl = document.getElementById('uic-preset-btns');
  if (presetEl) {
    presetEl.innerHTML = Object.entries(UIC_PRESETS).map(([key, p]) =>
      `<button class="uic-preset ${uicCurrentPreset===key?'active':''}" onclick="uicApplyPreset('${key}')">${p.label}</button>`
    ).join('');
  }
  const savedFont = uicSettings.fontFamily || '';
  const savedSize = uicSettings.fontSize || '14';
  const fontEl = document.getElementById('uic-font-select');
  if (fontEl) fontEl.value = savedFont;
  const sizeEl = document.getElementById('uic-font-size');
  if (sizeEl) { sizeEl.value = savedSize; const v=document.getElementById('uic-size-val'); if(v)v.textContent=savedSize+'px'; }
  const savedRadius = uicSettings.radius || '12px';
  document.querySelectorAll('.uic-radius-opt').forEach(b => b.classList.toggle('active', b.dataset.r===savedRadius));
  uicSyncPickers();
  // Restore image preview from server settings
  if (uicSettings.bg_type === 'image' && uicSettings.bg_url) {
    const wrap = document.getElementById('uic-img-preview-wrap');
    if (wrap) wrap.innerHTML = `<img src="${uicSettings.bg_url}" style="width:100%;height:100%;object-fit:cover;border-radius:10px"/>`;
    const btn = document.getElementById('uic-img-clear-btn');
    if (btn) btn.style.display = 'block';
  }
  // Restore video preview from server settings
  if (uicSettings.bg_type === 'video' && uicSettings.bg_url) {
    const wrap = document.getElementById('uic-vid-preview-wrap');
    if (wrap) wrap.innerHTML = `<video src="${uicSettings.bg_url}" autoplay loop muted playsinline style="width:100%;height:100%;object-fit:cover;border-radius:10px"></video>`;
    const btn = document.getElementById('uic-vid-clear-btn');
    if (btn) btn.style.display = 'block';
  }
}

function uicSyncPickers() {
  const pairs = [['bg','sw-bg'],['sidebar','sw-sidebar'],['card','sw-card'],['blue','sw-blue'],['text','sw-text'],['muted','sw-muted'],['border','sw-bord'],['green','sw-green'],['red','sw-red'],['amber','sw-amber']];
  pairs.forEach(([varN, swId]) => {
    const inp = document.getElementById('uic-clr-' + varN);
    const sw  = document.getElementById(swId);
    if (!inp) return;
    const val = getComputedStyle(document.documentElement).getPropertyValue('--' + varN).trim();
    const hex = uicToHex(val);
    inp.value = hex;
    if (sw) sw.style.background = hex;
  });
}

function uicToHex(color) {
  if (!color) return '#000000';
  const m = color.trim().match(/^#([0-9a-fA-F]{6})/);
  if (m) return '#' + m[1];
  const m3 = color.trim().match(/^#([0-9a-fA-F]{3})$/);
  if (m3) { const [r,g,b]=m3[1].split('').map(c=>c+c); return '#'+r+g+b; }
  const tmp = document.createElement('canvas').getContext('2d');
  tmp.fillStyle = color;
  const c = tmp.fillStyle;
  if (c.startsWith('#')) return c.slice(0,7);
  const rgb = c.match(/\d+/g);
  if (rgb) return '#'+rgb.slice(0,3).map(x=>parseInt(x).toString(16).padStart(2,'0')).join('');
  return '#000000';
}

function uicPickColor(varName, el) {
  const val = el.value;
  document.documentElement.style.setProperty('--' + varName, val);
  const sw = el.parentElement;
  if (sw) sw.style.background = val;
  uicCurrentPreset = 'custom';
  document.querySelectorAll('.uic-preset').forEach(b => b.classList.remove('active'));
  uicSettings.colors = uicSettings.colors || {};
  uicSettings.colors['--' + varName] = val;
}

function uicHexAlpha(hex, a) {
  if (!hex || !hex.startsWith('#')) return `rgba(0,0,0,${a})`;
  const r=parseInt(hex.slice(1,3),16), g=parseInt(hex.slice(3,5),16), b=parseInt(hex.slice(5,7),16);
  return `rgba(${r},${g},${b},${a})`;
}

function uicApplyPreset(key) {
  const p = UIC_PRESETS[key];
  if (!p) return;
  const root = document.documentElement;
  root.style.setProperty('--bg',     p.bg);
  root.style.setProperty('--sidebar',p.sidebar);
  root.style.setProperty('--card',   p.card);
  root.style.setProperty('--blue',   p.blue);
  root.style.setProperty('--blue-light', uicHexAlpha(p.blue, 0.12));
  root.style.setProperty('--blue-mid',   uicHexAlpha(p.blue, 0.30));
  root.style.setProperty('--text',   p.text);
  root.style.setProperty('--muted',  p.muted);
  root.style.setProperty('--border', p.border);
  root.style.setProperty('--green',  p.green);
  root.style.setProperty('--red',    p.red);
  root.style.setProperty('--amber',  p.amber);
  uicCurrentPreset = key;
  uicSettings.preset = key;
  uicSettings.colors = null;
  document.querySelectorAll('.uic-preset').forEach((b,i) => {
    b.classList.toggle('active', Object.keys(UIC_PRESETS)[i] === key);
  });
  uicSyncPickers();
  toast(`Theme applied: ${p.label}`, true);
}

function uicUploadImage(input) {
  const file = input.files[0];
  if (!file) return;
  if (file.size > 20 * 1024 * 1024) { toast('Image too large — max 20 MB', false); return; }
  toast('⏳ Uploading image…', true);
  const form = new FormData();
  form.append('file', file);
  fetch('/api/ui/background', {
    method: 'POST',
    headers: {'X-Client-Token': getClientToken()},
    body: form
  }).then(r => r.json()).then(d => {
    if (!d.ok) { toast('❌ Upload failed: ' + (d.error||''), false); return; }
    const bgLayer = document.getElementById('cpm-bg-layer');
    if (bgLayer) bgLayer.style.cssText = `position:fixed;inset:0;z-index:-2;pointer-events:none;background-image:url('${d.url}');background-size:cover;background-position:center`;
    document.getElementById('cpm-bg-style').innerHTML = '';
    document.documentElement.style.setProperty('--bg', 'transparent');
    const wrap = document.getElementById('uic-img-preview-wrap');
    if (wrap) wrap.innerHTML = `<img src="${d.url}" style="width:100%;height:100%;object-fit:cover;border-radius:10px"/>`;
    const btn = document.getElementById('uic-img-clear-btn');
    if (btn) btn.style.display = 'block';
    uicClearVideoSilent();
    uicSettings.bg_url = d.url; uicSettings.bg_type = 'image'; uicSettings.background = 'upload-img';
    uicCurrentBg = 'upload-img';
    toast('🖼️ Image background saved on server!', true);
  }).catch(() => toast('❌ Upload failed', false));
}

function uicDropImage(ev) {
  ev.preventDefault();
  const file = ev.dataTransfer.files[0];
  if (!file || !file.type.startsWith('image/')) { toast('Please drop an image file', false); return; }
  const fakeInput = { files:[file] };
  uicUploadImage(fakeInput);
}

function uicUploadVideo(input) {
  const file = input.files[0];
  if (!file) return;
  if (file.size > 100 * 1024 * 1024) { toast('Video too large — max 100 MB', false); return; }
  toast('⏳ Uploading video… please wait', true);
  const form = new FormData();
  form.append('file', file);
  fetch('/api/ui/background', {
    method: 'POST',
    headers: {'X-Client-Token': getClientToken()},
    body: form
  }).then(r => r.json()).then(d => {
    if (!d.ok) { toast('❌ Upload failed: ' + (d.error||''), false); return; }
    const vid = document.getElementById('cpm-bg-video');
    if (vid) { vid.src = d.url; vid.style.display = 'block'; vid.load(); vid.play().catch(()=>{}); }
    const bgLayer = document.getElementById('cpm-bg-layer');
    if (bgLayer) bgLayer.style.cssText = 'position:fixed;inset:0;z-index:-2;pointer-events:none';
    document.getElementById('cpm-bg-style').innerHTML = '';
    document.documentElement.style.setProperty('--bg', 'transparent');
    const wrap = document.getElementById('uic-vid-preview-wrap');
    if (wrap) wrap.innerHTML = `<video src="${d.url}" autoplay loop muted playsinline style="width:100%;height:100%;object-fit:cover;border-radius:10px"></video>`;
    const btn = document.getElementById('uic-vid-clear-btn');
    if (btn) btn.style.display = 'block';
    uicClearImageSilent();
    uicSettings.bg_url = d.url; uicSettings.bg_type = 'video'; uicSettings.background = 'upload-vid';
    uicCurrentBg = 'upload-vid';
    toast('🎬 Video background saved on server!', true);
  }).catch(() => toast('❌ Upload failed', false));
}

function uicDropVideo(ev) {
  ev.preventDefault();
  const file = ev.dataTransfer.files[0];
  if (!file || !file.type.startsWith('video/')) { toast('Please drop a video file', false); return; }
  const fakeInput = { files:[file] };
  uicUploadVideo(fakeInput);
}

function uicClearImageSilent() {
  if (uicSettings.bg_type === 'image') {
    fetch('/api/ui/background', {method:'DELETE', headers:{'X-Client-Token':getClientToken()}}).catch(()=>{});
    uicSettings.bg_url = null; uicSettings.bg_type = null;
  }
  uicSettings.background = 'none'; uicCurrentBg = 'none';
  const bgLayer = document.getElementById('cpm-bg-layer');
  if (bgLayer) bgLayer.style.cssText = 'position:fixed;inset:0;z-index:-2;pointer-events:none';
  document.documentElement.style.removeProperty('--bg');
  if (uicSettings.preset && UIC_PRESETS[uicSettings.preset]) {
    document.documentElement.style.setProperty('--bg', UIC_PRESETS[uicSettings.preset].bg);
  }
  const wrap = document.getElementById('uic-img-preview-wrap');
  if (wrap) wrap.innerHTML = `<svg width="32" height="32" fill="none" stroke="currentColor" stroke-width="1.5" viewBox="0 0 24 24"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="M21 15l-5-5L5 21"/></svg><span style="font-size:13px;font-weight:600">Click or drag an image here</span><span style="font-size:11px">JPG, PNG, GIF, WebP — max 20 MB</span>`;
  const btn = document.getElementById('uic-img-clear-btn');
  if (btn) btn.style.display = 'none';
}

function uicClearImage() { uicClearImageSilent(); toast('Image background removed', true); }

function uicClearVideoSilent() {
  if (uicSettings.bg_type === 'video') {
    fetch('/api/ui/background', {method:'DELETE', headers:{'X-Client-Token':getClientToken()}}).catch(()=>{});
    uicSettings.bg_url = null; uicSettings.bg_type = null;
  }
  uicSettings.background = 'none'; uicCurrentBg = 'none';
  const vid = document.getElementById('cpm-bg-video');
  if (vid) { vid.style.display='none'; vid.src=''; }
  const wrap = document.getElementById('uic-vid-preview-wrap');
  if (wrap) wrap.innerHTML = `<svg width="32" height="32" fill="none" stroke="currentColor" stroke-width="1.5" viewBox="0 0 24 24"><polygon points="23 7 16 12 23 17 23 7"/><rect x="1" y="5" width="15" height="14" rx="2"/></svg><span style="font-size:13px;font-weight:600">Click or drag a video here</span><span style="font-size:11px">MP4, WebM, OGG — max 100 MB</span>`;
  const btn = document.getElementById('uic-vid-clear-btn');
  if (btn) btn.style.display = 'none';
}

function uicClearVideo() { uicClearVideoSilent(); toast('Video background removed', true); }

function uicApplyFont() {
  const family = document.getElementById('uic-font-select').value;
  const size   = document.getElementById('uic-font-size').value;
  const valEl  = document.getElementById('uic-size-val');
  if (valEl) valEl.textContent = size + 'px';
  document.body.style.fontFamily = family ? (family + ',Segoe UI,system-ui,sans-serif') : '';
  document.body.style.fontSize   = size ? size + 'px' : '';
  uicSettings.fontFamily = family;
  uicSettings.fontSize   = size;
}

function uicApplyRadius(r) {
  document.documentElement.style.setProperty('--radius', r);
  document.querySelectorAll('.uic-radius-opt').forEach(b => b.classList.toggle('active', b.dataset.r===r));
  uicSettings.radius = r;
}

async function saveUiCustomize() {
  const root = document.documentElement;
  const vars  = ['--bg','--sidebar','--card','--blue','--text','--muted','--border','--green','--red','--amber'];
  const colors = {};
  vars.forEach(v => { const val = root.style.getPropertyValue(v); if (val) colors[v] = val; });
  uicSettings.savedColors = colors;
  uicSettings.preset      = uicCurrentPreset;
  uicSettings.background  = uicCurrentBg;
  uicSettings.radius      = root.style.getPropertyValue('--radius') || '12px';
  uicSettings.fontFamily  = document.getElementById('uic-font-select')?.value || '';
  uicSettings.fontSize    = document.getElementById('uic-font-size')?.value   || '14';
  try {
    const d = await api('/api/ui/settings', {method:'POST', body:JSON.stringify(uicSettings)});
    if (d.ok) toast('✅ UI settings saved on server!', true);
    else toast('❌ Save failed', false);
  } catch(e) { toast('❌ Save failed', false); }
}

async function resetUiCustomize() {
  if (!confirm('Reset all UI customizations to default?')) return;
  // Delete server settings + background
  try {
    await api('/api/ui/settings', {method:'POST', body:JSON.stringify({})});
    await fetch('/api/ui/background', {method:'DELETE', headers:{'X-Client-Token':getClientToken()}}).catch(()=>{});
  } catch(e) {}
  uicSettings = {}; uicCurrentPreset = 'default'; uicCurrentBg = 'none';
  const root = document.documentElement;
  ['--bg','--sidebar','--card','--blue','--blue-light','--blue-mid','--text','--muted','--border','--green','--red','--amber','--radius'].forEach(v=>root.style.removeProperty(v));
  document.body.style.fontFamily = '';
  document.body.style.fontSize   = '';
  const bgLayer = document.getElementById('cpm-bg-layer');
  if (bgLayer) bgLayer.style.cssText = 'position:fixed;inset:0;z-index:-2;pointer-events:none';
  document.getElementById('cpm-bg-style').innerHTML = '';
  const vid = document.getElementById('cpm-bg-video');
  if (vid) { vid.style.display='none'; vid.src=''; }
  uicRenderPage();
  toast('↩ Reset to defaults', true);
}

async function initUiCustomize() {
  try {
    const d = await api('/api/ui/settings');
    if (!d || !Object.keys(d).length) return;
    uicSettings      = d;
    uicCurrentPreset = d.preset || 'default';
    uicCurrentBg     = d.background || 'none';
    const root = document.documentElement;
    // Apply saved color overrides
    if (d.savedColors && Object.keys(d.savedColors).length) {
      Object.entries(d.savedColors).forEach(([v, val]) => root.style.setProperty(v, val));
    } else if (d.preset && UIC_PRESETS[d.preset]) {
      const p = UIC_PRESETS[d.preset];
      root.style.setProperty('--bg',         p.bg);
      root.style.setProperty('--sidebar',    p.sidebar);
      root.style.setProperty('--card',       p.card);
      root.style.setProperty('--blue',       p.blue);
      root.style.setProperty('--blue-light', uicHexAlpha(p.blue,0.12));
      root.style.setProperty('--blue-mid',   uicHexAlpha(p.blue,0.30));
      root.style.setProperty('--text',       p.text);
      root.style.setProperty('--muted',      p.muted);
      root.style.setProperty('--border',     p.border);
      root.style.setProperty('--green',      p.green);
      root.style.setProperty('--red',        p.red);
      root.style.setProperty('--amber',      p.amber);
    }
    // Restore background from server URL
    if (d.bg_url && d.bg_type === 'image') {
      const bgLayer = document.getElementById('cpm-bg-layer');
      if (bgLayer) bgLayer.style.cssText = `position:fixed;inset:0;z-index:-2;pointer-events:none;background-image:url('${d.bg_url}');background-size:cover;background-position:center`;
      root.style.setProperty('--bg','transparent');
    } else if (d.bg_url && d.bg_type === 'video') {
      const vid = document.getElementById('cpm-bg-video');
      if (vid) { vid.src = d.bg_url; vid.style.display = 'block'; vid.load(); vid.play().catch(()=>{}); }
      const bgLayer = document.getElementById('cpm-bg-layer');
      if (bgLayer) bgLayer.style.cssText = 'position:fixed;inset:0;z-index:-2;pointer-events:none';
      root.style.setProperty('--bg','transparent');
    }
    // Apply radius, font
    if (d.radius)     root.style.setProperty('--radius', d.radius);
    if (d.fontFamily) document.body.style.fontFamily = d.fontFamily+',Segoe UI,system-ui,sans-serif';
    if (d.fontSize)   document.body.style.fontSize   = d.fontSize+'px';
  } catch(e) {}
}

// ── Logout / Switch Account ───────────────────────────────────────────────
function logoutPanel() {
  if (!confirm('Log out and return to the startup screen?')) return;
  ['cpm_activation','cpm_owner_key','cpm_premium_key','cpm_premium_expires'].forEach(k => localStorage.removeItem(k));
  location.reload();
}

// ── init & poll ───────────────────────────────────────────────────────────
activationInit();
initUiCustomize().then(() => uicRenderPage());
checkKvmStatus();
loadStats(); loadVps();
pollTunnel();
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

PKGS="flask flask-cors psutil supabase"

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

# ── Install localtunnel (for public URL feature) ───────────────────────────
inf "Installing localtunnel (lt)…"
if npm install -g localtunnel -q 2>/dev/null && which lt &>/dev/null; then
  ok "localtunnel installed (lt command ready)"
else
  wrn "localtunnel install failed — public URL feature will be disabled"
fi

sep "Verifying all packages"
ALL_OK=true
for pkg in flask flask_cors psutil supabase; do
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

# ── Systemd service (auto-start on boot) ──────────────────────────────────────
sep "Auto-start: systemd service"

PYTHON_PATH="$(cd "$DIR" && [[ -f venv/bin/python3 ]] && echo "$DIR/venv/bin/python3" || which python3)"

cat > /etc/systemd/system/cpm-panel.service << SVCEOF
[Unit]
Description=CPM Panel — KVM VPS Management
After=network-online.target libvirtd.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$DIR
ExecStart=$PYTHON_PATH $DIR/app.py
Restart=on-failure
RestartSec=5
Environment=PORT=5000
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable systemd-networkd-wait-online 2>/dev/null || true
systemctl enable cpm-panel
systemctl restart cpm-panel 2>/dev/null || systemctl start cpm-panel
ok "cpm-panel service enabled — auto-starts on every boot (waits for full internet)"

# ── Login message (show panel URL after SSH login) ─────────────────────────────
cat > /etc/profile.d/cpm-url.sh << 'MOTDEOF'
#!/usr/bin/env bash
# CPM Panel — show URL on SSH login
_URL_FILE="/tmp/cpm-tunnel.url"
_LOCAL_URL="http://$(hostname -I 2>/dev/null | awk '{print $1}'):5000"

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║        CPM Panel — KVM Manager           ║"
echo "  ╠══════════════════════════════════════════╣"
printf  "  ║  Local  : %-31s║\n" "$_LOCAL_URL"

# Wait up to 30 seconds for tunnel URL to appear
_TUN=""
if [[ ! -f "$_URL_FILE" ]]; then
  printf "  ║  Public : %-31s║\n" "Waiting for tunnel URL…"
  echo "  ╚══════════════════════════════════════════╝"
  echo ""
  _WAITED=0
  while [[ $_WAITED -lt 30 ]]; do
    sleep 1
    _WAITED=$((_WAITED + 1))
    if [[ -f "$_URL_FILE" ]]; then
      _TUN="$(cat "$_URL_FILE" 2>/dev/null | tr -d '\n')"
      break
    fi
  done
  # Re-print the banner with the result
  echo ""
  echo "  ╔══════════════════════════════════════════╗"
  echo "  ║        CPM Panel — KVM Manager           ║"
  echo "  ╠══════════════════════════════════════════╣"
  printf  "  ║  Local  : %-31s║\n" "$_LOCAL_URL"
  if [[ -n "$_TUN" ]]; then
    printf "  ║  Public : %-31s║\n" "$_TUN"
  else
    echo "  ║  Public : (tunnel not ready — try again) ║"
  fi
  echo "  ╚══════════════════════════════════════════╝"
  echo ""
else
  _TUN="$(cat "$_URL_FILE" 2>/dev/null | tr -d '\n')"
  printf "  ║  Public : %-31s║\n" "$_TUN"
  echo "  ╚══════════════════════════════════════════╝"
  echo ""
fi
MOTDEOF
chmod +x /etc/profile.d/cpm-url.sh
ok "Login message installed — waits up to 30s for loca.lt URL on every SSH login"

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
echo ""
[[ -n "${SUDO_USER:-}" ]] && echo -e "  ${Y}NOTE:${N} Log out and back in so '$SUDO_USER' can