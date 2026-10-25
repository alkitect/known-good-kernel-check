#!/usr/bin/env bash
# Write evidence/pre-run-*.json (uname, holds, GRUB, profile/baseline hashes).
# Plan 1b: same KCG_PROFILE (+ optional KCG_EVIDENCE) as capture-baseline / run-compat-suite.
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
EVIDENCE="${KCG_EVIDENCE:-${KCG_ROOT}/evidence}"
BASELINES="${KCG_BASELINES:-${KCG_ROOT}/baselines}"
mkdir -p "${EVIDENCE}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${EVIDENCE}/pre-run-${STAMP}.json"

BASELINE=""
if [[ -L "${BASELINES}/CURRENT" ]]; then
  BASELINE="${BASELINES}/$(readlink "${BASELINES}/CURRENT")"
fi

GRUB_DEFAULT=""
if [[ -f /etc/default/grub ]]; then
  GRUB_DEFAULT="$(grep -E '^GRUB_DEFAULT=' /etc/default/grub | head -1 || true)"
fi

python3 - "${PROFILE}" "${OUT}" "${STAMP}" "${BASELINE}" "${GRUB_DEFAULT}" <<'PY'
import hashlib, json, subprocess, sys
from pathlib import Path

profile_path, out, stamp, baseline, grub = sys.argv[1:6]

def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        return ""

phash = hashlib.sha256(Path(profile_path).read_bytes()).hexdigest()[:16]
bhash = bkv = ""
if baseline and Path(baseline).is_file():
    bhash = hashlib.sha256(Path(baseline).read_bytes()).hexdigest()[:16]
    bkv = json.loads(Path(baseline).read_text(encoding="utf-8")).get("kernel_version", "")

doc = {
    "preflight_id": f"pre-run-{stamp}",
    "captured_at": stamp,
    "uname": sh("uname -r"),
    "hwe_holds": sh("apt-mark showhold 2>/dev/null | grep -i linux || true"),
    "grub_default": grub,
    "profile_path": str(Path(profile_path).resolve()),
    "profile_hash": phash,
    "baseline_path": baseline,
    "baseline_hash": bhash,
    "baseline_kernel_version": bkv,
}
Path(out).write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
print(out)
PY

ln -sfn "$(basename "${OUT}")" "${EVIDENCE}/CURRENT_PREFLIGHT"
echo "Preflight written: ${OUT}"
