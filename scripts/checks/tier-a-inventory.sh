#!/usr/bin/env bash
# Tier A inventory vs baseline (warn on drift unless reject_on_drift).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${1:?profile}"
BASELINE="${2:?baseline}"

python3 - "${PROFILE}" "${BASELINE}" <<'PY'
import json, subprocess, sys, yaml
from pathlib import Path

profile = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
base = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
reject = set(profile.get("reject_on_drift") or [])
inv = base.get("inventory") or {}

def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        return ""

def emit(cid, result, detail):
    print("KCG_RESULT " + json.dumps({
        "id": cid, "tier": "A", "result": result, "detail": detail, "source": "builtin"
    }, separators=(",", ":")))

current = {
    "os_pretty": sh(". /etc/os-release 2>/dev/null; echo ${PRETTY_NAME}"),
    "hwe_holds": sh("apt-mark showhold 2>/dev/null | grep -i linux || true"),
    "lockdown": sh("cat /sys/kernel/security/lockdown 2>/dev/null || true"),
    "board_name": sh("cat /sys/devices/virtual/dmi/id/board_name 2>/dev/null || true"),
    "linux_firmware_version": sh("dpkg-query -W -f='${Version}' linux-firmware 2>/dev/null || true"),
}

for key in profile.get("inventory_keys") or list(current.keys()):
    old = inv.get(key, "")
    new = current.get(key, "")
    if old == new:
        emit(f"inv-{key}", "pass", "unchanged")
    elif key in reject:
        emit(f"inv-{key}", "fail", f"drift reject_on_drift: {old!r} -> {new!r}")
    else:
        emit(f"inv-{key}", "warn", f"drift: {old!r} -> {new!r}")
PY
