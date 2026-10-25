#!/usr/bin/env bash
# Tier C: Wi-Fi iface / ethernet fallback + BT policy from profile.
set -euo pipefail
PROFILE="${1:?profile}"

python3 - "${PROFILE}" <<'PY'
import json, subprocess, sys, yaml
from pathlib import Path

profile = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))

def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        return ""

def emit(cid, result, detail):
    print("KCG_RESULT " + json.dumps({
        "id": cid, "tier": "C", "result": result, "detail": detail, "source": "builtin"
    }, separators=(",", ":")))

wifi = profile.get("wifi") or {}
iface = wifi.get("iface", "")
required = wifi.get("required", True)
fallback = wifi.get("ethernet_fallback", True)

state = sh(f"nmcli -g GENERAL.STATE device show {iface} 2>/dev/null || true")
connected = "connected" in state.lower() if state else False
if connected:
    emit("wifi-iface", "pass", f"{iface} {state}")
elif fallback:
    defroute = sh("ip route show default 2>/dev/null | head -1")
    if defroute:
        emit("wifi-iface", "warn", f"{iface} not connected; ethernet/default route ok: {defroute[:80]}")
    else:
        emit("wifi-iface", "fail" if required else "warn", f"{iface} down and no default route")
else:
    emit("wifi-iface", "fail" if required else "warn", f"{iface} state={state!r}")

bt = profile.get("bluetooth") or {}
req = bt.get("required_hci", "hci0")
# hciconfig or bluetoothctl
hci_list = sh("hciconfig 2>/dev/null || true")
if not hci_list:
    hci_list = sh("bluetoothctl list 2>/dev/null || true")

up = False
if f"{req}:" in hci_list or req in hci_list:
    block = sh(f"hciconfig {req} 2>/dev/null || true")
    up = "UP" in block and "RUNNING" in block
    if not up:
        # bluetoothctl show
        info = sh(f"bluetoothctl show {req} 2>/dev/null || bluetoothctl show 2>/dev/null || true")
        up = "Powered: yes" in info
emit(f"bt-{req}", "pass" if up else "fail", "UP RUNNING" if up else "not UP/RUNNING")

for exp in bt.get("expected") or []:
    hci = exp.get("hci", "")
    note = exp.get("note", "expected fail")
    block = sh(f"hciconfig {hci} 2>/dev/null || true")
    if "UP" in block and "RUNNING" in block:
        emit(f"bt-{hci}-expected", "warn", f"{hci} unexpectedly UP ({note})")
    else:
        emit(f"bt-{hci}-expected", "expected", note)
PY
