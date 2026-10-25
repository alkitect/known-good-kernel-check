#!/usr/bin/env bash
# Tier B: PCI bind, modules, DRM cards.
set -euo pipefail
PROFILE="${1:?profile}"

python3 - "${PROFILE}" <<'PY'
import json, subprocess, sys, yaml
from pathlib import Path  # noqa: used for /dev/kfd

profile = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))

def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        return ""

def emit(cid, result, detail):
    print("KCG_RESULT " + json.dumps({
        "id": cid, "tier": "B", "result": result, "detail": detail, "source": "builtin"
    }, separators=(",", ":")))

for entry in profile.get("pci", []):
    vid = entry["id"]
    want = entry.get("driver", "")
    required = entry.get("required", True)
    driver = sh(f"lspci -Dnnk -d {vid} 2>/dev/null | awk '/Kernel driver in use:/{{print $5; exit}}'")
    present = bool(sh(f"lspci -Dnn -d {vid} 2>/dev/null"))
    cid = f"pci-{vid}"
    if not present:
        emit(cid, "fail" if required else "warn", f"device {vid} not found")
    elif driver == want:
        emit(cid, "pass", f"bound to {driver}")
    else:
        emit(cid, "fail" if required else "warn", f"driver={driver!r} want={want!r}")

for m in profile.get("modules", []):
    loaded = bool(sh(f"grep -qE '^{m}[[:space:]]' /proc/modules && echo y"))
    emit(f"mod-{m}", "pass" if loaded else "fail", "loaded" if loaded else "not in /proc/modules")

min_cards = int((profile.get("drm") or {}).get("min_cards", 1))
cards = sh("ls -1 /dev/dri/card* 2>/dev/null | wc -l")
try:
    n = int(cards or "0")
except ValueError:
    n = 0
emit("drm-cards", "pass" if n >= min_cards else "fail", f"cards={n} min={min_cards}")

kfd = profile.get("kfd") or {}
if kfd.get("require_dev_kfd"):
    has_kfd = Path("/dev/kfd").exists()
    emit("dev-kfd", "pass" if has_kfd else "fail", "/dev/kfd present" if has_kfd else "/dev/kfd missing")

# Deferred probe (best-effort; may need root/debugfs)
deferred = sh("cat /sys/kernel/debug/devices_deferred 2>/dev/null || true")
if deferred.strip():
    emit("deferred-probe", "warn", deferred.strip()[:200])
else:
    emit("deferred-probe", "pass", "empty or unavailable")
PY
