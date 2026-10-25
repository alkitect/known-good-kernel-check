#!/usr/bin/env bash
# Capture baseline snapshot on known-good kernel (binds kernel_version + profile_hash).
# Plan 1b: export KCG_PROFILE=…/example-generic.yaml.example (same env as preflight/suite).
# Optional: KCG_BASELINES to isolate named baselines; restore baselines/CURRENT before -124 gate.
set -euo pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KCG_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/kcg-common.sh
source "${SCRIPT_DIR}/lib/kcg-common.sh"
# shellcheck source=lib/kcg-lane.sh
source "${SCRIPT_DIR}/lib/kcg-lane.sh"
kcg_require_root
kcg_lane_apply_if_needed

PROFILE="${KCG_PROFILE:?set KCG_PROFILE or use lane resolver}"
OUT_DIR="${KCG_BASELINES:-${KCG_ROOT}/baselines}"
mkdir -p "${OUT_DIR}"

UNAME="$(uname -r)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PHASH="$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:16])" "${PROFILE}")"

EXPECTED_KV="$(python3 -c "import yaml,sys; print(yaml.safe_load(open(sys.argv[1]))['kernel_version'])" "${PROFILE}")"
if [[ "${UNAME}" != "${EXPECTED_KV}" ]]; then
  echo "ERROR: running kernel ${UNAME} != profile kernel_version ${EXPECTED_KV}" >&2
  echo "Boot known-good before capturing baseline." >&2
  exit 2
fi

BASE_ID="baseline-${UNAME}-${STAMP}"
OUT="${OUT_DIR}/${BASE_ID}.json"

python3 - "${PROFILE}" "${OUT}" "${UNAME}" "${PHASH}" "${BASE_ID}" "${STAMP}" <<'PY'
import json, subprocess, sys, yaml
from pathlib import Path

profile_path, out, uname, phash, base_id, stamp = sys.argv[1:7]
profile = yaml.safe_load(Path(profile_path).read_text(encoding="utf-8"))

def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        return ""

inventory = {
    "os_pretty": sh(". /etc/os-release 2>/dev/null; echo ${PRETTY_NAME}"),
    "hwe_holds": sh("apt-mark showhold 2>/dev/null | grep -i linux || true"),
    "lockdown": sh("cat /sys/kernel/security/lockdown 2>/dev/null || true"),
    "board_name": sh("cat /sys/devices/virtual/dmi/id/board_name 2>/dev/null || true"),
    "linux_firmware_version": sh("dpkg-query -W -f='${Version}' linux-firmware 2>/dev/null || true"),
}

pci_bind = {}
for entry in profile.get("pci", []):
    vid = entry["id"]
    # lspci -Dnnd : show bus and driver
    line = sh(f"lspci -Dnnd '*:{vid.split(':')[1]}' 2>/dev/null | head -1")
    driver = sh(f"lspci -Dnnk -d {vid} 2>/dev/null | awk '/Kernel driver in use:/{{print $5; exit}}'")
    pci_bind[vid] = {"lspci": line, "driver": driver}

modules = {}
for m in profile.get("modules", []):
    modules[m] = bool(sh(f"grep -qE '^{m}[[:space:]]' /proc/modules && echo yes"))

doc = {
    "baseline_id": base_id,
    "captured_at": stamp,
    "kernel_version": uname,
    "profile_path": str(Path(profile_path).resolve()),
    "profile_hash": phash,
    "inventory": inventory,
    "pci_bind": pci_bind,
    "modules": modules,
}
Path(out).write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
print(out)
PY

# Pointer for runner default
ln -sfn "$(basename "${OUT}")" "${OUT_DIR}/CURRENT"
echo "Baseline written: ${OUT}"
echo "CURRENT -> $(basename "${OUT}")"
