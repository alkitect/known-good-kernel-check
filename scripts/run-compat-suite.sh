#!/usr/bin/env bash
# Known-good kernel check runner → PROMOTE (0) / HOLD (1) / REJECT (2)
# Plan 1b: KCG_PROFILE / --profile must match capture-baseline + capture-preflight.
set -euo pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KCG_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/kcg-common.sh
source "${SCRIPT_DIR}/lib/kcg-common.sh"
# shellcheck source=lib/kcg-lane.sh
source "${SCRIPT_DIR}/lib/kcg-lane.sh"
kcg_require_root

PROFILE="${KCG_PROFILE:-}"
BASELINES="${KCG_BASELINES:-}"
EVIDENCE="${KCG_EVIDENCE:-${KCG_ROOT}/evidence}"
ACCEPTANCE=0
SKIP_SOAK=0
SELF_TEST_REJECT=0
OFFLINE_SCHEMA=0
SOAK_SECONDS=""
PROGRESS_MODE=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

  --acceptance          Require preflight CURRENT_PREFLIGHT; refuse --skip-soak
  --skip-soak           Skip Tier D (dev only; forbidden with --acceptance)
  --soak-seconds N      Override soak wall (seconds); mode still gate|deep
  --self-test-reject    Inject synthetic Type I fail → expect REJECT
  --offline-schema      Validate last report JSON schema fields and exit
  --profile PATH        Profile YAML (or lane resolver / KCG_PROFILE)
  --progress MODE       Progress UX: auto|tty|plain|off (default: KCG_PROGRESS or auto)
  -h, --help            This help

Env: KCG_PROGRESS=auto|tty|plain|off — live step/phase/soak ticks on stderr only
     (never mixed into KCG_RESULT / RESULTS). off = banner + decision only.
     KCG_SOAK_MODE=gate|deep — override profile soak.mode
     KCG_SOAK_SMOKE=1 — shortened gate soak for Agent verify
     --acceptance forces gate unless KCG_SOAK_MODE=deep
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --acceptance) ACCEPTANCE=1; shift ;;
    --skip-soak) SKIP_SOAK=1; shift ;;
    --soak-seconds) SOAK_SECONDS="$2"; shift 2 ;;
    --self-test-reject) SELF_TEST_REJECT=1; shift ;;
    --offline-schema) OFFLINE_SCHEMA=1; shift ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --progress) PROGRESS_MODE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -n "${PROGRESS_MODE}" ]]; then
  case "${PROGRESS_MODE}" in
    auto|tty|plain|off) export KCG_PROGRESS="${PROGRESS_MODE}" ;;
    *) echo "ERROR: --progress must be auto|tty|plain|off" >&2; exit 2 ;;
  esac
fi
export KCG_PROGRESS="${KCG_PROGRESS:-auto}"
export KCG_PROGRESS_PY="${SCRIPT_DIR}/lib/kcg_progress.py"

# Lane resolve when --profile / KCG_PROFILE unset
if [[ -z "${PROFILE}" ]]; then
  kcg_lane_apply_if_needed
  PROFILE="${KCG_PROFILE}"
  BASELINES="${KCG_BASELINES:-${KCG_ROOT}/baselines}"
else
  export KCG_PROFILE="${PROFILE}"
  kcg_lane_apply_if_needed
  BASELINES="${KCG_BASELINES:-${KCG_ROOT}/baselines}"
fi
[[ -f "${PROFILE}" ]] || { echo "ERROR: profile not found: ${PROFILE}" >&2; exit 2; }

if [[ "${ACCEPTANCE}" -eq 1 && "${SKIP_SOAK}" -eq 1 ]]; then
  echo "ERROR: --acceptance refuses --skip-soak" >&2
  exit 2
fi

mkdir -p "${EVIDENCE}" "${BASELINES}"

if [[ "${OFFLINE_SCHEMA}" -eq 1 ]]; then
  LAST="$(ls -1t "${EVIDENCE}"/report-*.json 2>/dev/null | head -1 || true)"
  [[ -n "${LAST}" ]] || { echo "ERROR: no report-*.json under evidence/" >&2; exit 2; }
  python3 - "${LAST}" <<'PY'
import json, sys
from pathlib import Path
req = {"schema_version","suite_version","decision","exit_code","uname","profile_id",
       "profile_path","profile_hash","baseline_id","started_at","checks"}
doc = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
missing = sorted(req - set(doc))
if missing:
    print("SCHEMA FAIL missing:", ", ".join(missing))
    sys.exit(2)
if not isinstance(doc.get("checks"), list):
    print("SCHEMA FAIL checks not list")
    sys.exit(2)
print("SCHEMA OK", sys.argv[1])
PY
  exit 0
fi

UNAME="$(uname -r)"
EXPECTED_KV="$(python3 -c "import yaml,sys; print(yaml.safe_load(open(sys.argv[1]))['kernel_version'])" "${PROFILE}")"
PHASH="$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:16])" "${PROFILE}")"

if [[ "${UNAME}" != "${EXPECTED_KV}" ]]; then
  echo "ERROR: running kernel ${UNAME} != profile kernel_version ${EXPECTED_KV}" >&2
  echo "Hard refuse (do not continue)." >&2
  exit 2
fi

BASELINE=""
if [[ -L "${BASELINES}/CURRENT" ]]; then
  BASELINE="${BASELINES}/$(readlink "${BASELINES}/CURRENT")"
fi
if [[ -z "${BASELINE}" || ! -f "${BASELINE}" ]]; then
  echo "ERROR: no baseline CURRENT under ${BASELINES} — run capture-baseline.sh first" >&2
  exit 2
fi

BPHASH="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('profile_hash',''))" "${BASELINE}")"
BKV="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('kernel_version',''))" "${BASELINE}")"
if [[ "${BPHASH}" != "${PHASH}" ]]; then
  echo "ERROR: baseline profile_hash ${BPHASH} != current profile ${PHASH} — re-capture baseline" >&2
  exit 2
fi
if [[ "${BKV}" != "${UNAME}" ]]; then
  echo "ERROR: baseline kernel_version ${BKV} != uname ${UNAME}" >&2
  exit 2
fi

PREFLIGHT_ID=""
if [[ "${ACCEPTANCE}" -eq 1 ]]; then
  if [[ ! -L "${EVIDENCE}/CURRENT_PREFLIGHT" ]]; then
    echo "ERROR: --acceptance requires evidence/CURRENT_PREFLIGHT — run capture-preflight.sh" >&2
    exit 2
  fi
  PF="${EVIDENCE}/$(readlink "${EVIDENCE}/CURRENT_PREFLIGHT")"
  [[ -f "${PF}" ]] || { echo "ERROR: broken CURRENT_PREFLIGHT" >&2; exit 2; }
  PREFLIGHT_ID="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('preflight_id',''))" "${PF}")"
fi

RESULTS="$(mktemp)"
trap 'rm -f "${RESULTS}"' EXIT

run_capture() {
  # Append KCG_RESULT lines from command stdout
  "$@" >>"${RESULTS}" || true
}

# Progress tick helpers (stderr via kcg_progress; step timing in bash)
KCG_STEP_DONE=0
kcg_step_begin() {
  local phase="$1" id="$2"
  KCG_STEP_T0="$(date +%s)"
  kcg_progress step-begin --phase "${phase}" --id "${id}"
}
kcg_step_end() {
  local phase="$1" id="$2"
  local t1 elapsed
  t1="$(date +%s)"
  elapsed=$((t1 - ${KCG_STEP_T0:-t1}))
  KCG_STEP_DONE=$((KCG_STEP_DONE + 1))
  kcg_progress step-end --phase "${phase}" --id "${id}" \
    --elapsed "${elapsed}" --done "${KCG_STEP_DONE}" --total "${KCG_TOTAL_STEPS}"
}

PLUGIN_COUNT="$(python3 -c "
import yaml,sys
p=yaml.safe_load(open(sys.argv[1]))
print(sum(1 for pl in (p.get('plugins') or []) if pl.get('enabled', True) is not False))
" "${PROFILE}")"

# Acceptance forces gate soak (same shape as login PBIT) unless deep explicitly requested
if [[ "${ACCEPTANCE}" -eq 1 && "${KCG_SOAK_MODE:-}" != "deep" ]]; then
  export KCG_SOAK_MODE=gate
fi
export KCG_SOAK_SOURCE="${KCG_SOAK_SOURCE:-$([[ "${ACCEPTANCE}" -eq 1 ]] && echo acceptance || echo manual)}"

SOAK_DUR="$(python3 -c "
import sys
sys.path.insert(0, sys.argv[1])
from kcg_soak import compute_wall_seconds, resolve_mode
import yaml
from pathlib import Path
import os
p = yaml.safe_load(Path(sys.argv[2]).read_text(encoding='utf-8')) or {}
soak = p.get('soak') or {}
smoke = os.environ.get('KCG_SOAK_SMOKE','0') == '1'
mode, wall, _ = compute_wall_seconds(soak, smoke=smoke)
print(wall)
" "${SCRIPT_DIR}/lib" "${PROFILE}")"
if [[ "${SKIP_SOAK}" -eq 1 ]]; then
  SOAK_DUR=0
elif [[ -n "${SOAK_SECONDS}" ]]; then
  SOAK_DUR="${SOAK_SECONDS}"
fi
SOAK_MODE_SHOW="$(python3 -c "
import sys, os
sys.path.insert(0, sys.argv[1])
from kcg_soak import resolve_mode
import yaml
from pathlib import Path
p = yaml.safe_load(Path(sys.argv[2]).read_text(encoding='utf-8')) or {}
print(resolve_mode(p.get('soak') or {}))
" "${SCRIPT_DIR}/lib" "${PROFILE}")"
KCG_TOTAL_STEPS="$(python3 -c "
import sys
sys.path.insert(0, sys.argv[1])
from kcg_progress import count_suite_steps
print(count_suite_steps(int(sys.argv[2])))
" "${SCRIPT_DIR}/lib" "${PLUGIN_COUNT}")"

echo "=== known-good-kernel-check ${KCG_SUITE_VERSION} ==="
echo "uname=${UNAME} profile_hash=${PHASH} baseline=$(basename "${BASELINE}") soak_mode=${SOAK_MODE_SHOW} soak_wall_s=${SOAK_DUR}"
SKIP_FLAG=()
[[ "${SKIP_SOAK}" -eq 1 ]] && SKIP_FLAG=(--skip-soak)
kcg_progress suite-start --soak-seconds "${SOAK_DUR}" --plugin-count "${PLUGIN_COUNT}" "${SKIP_FLAG[@]+"${SKIP_FLAG[@]}"}"

kcg_step_begin A inventory
run_capture "${SCRIPT_DIR}/checks/tier-a-inventory.sh" "${PROFILE}" "${BASELINE}"
kcg_step_end A inventory

kcg_progress phase-begin --phase B
kcg_step_begin B bind
run_capture "${SCRIPT_DIR}/checks/tier-b-bind.sh" "${PROFILE}"
kcg_step_end B bind
kcg_step_begin B type1
run_capture "${SCRIPT_DIR}/checks/tier-b-type1.sh" "${PROFILE}"
kcg_step_end B type1

kcg_progress phase-end --phase B

kcg_progress phase-begin --phase C
kcg_step_begin C wifi-bt
run_capture "${SCRIPT_DIR}/checks/tier-c-wifi-bt.sh" "${PROFILE}"
kcg_step_end C wifi-bt

# Plugins from profile
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  id="${line%%|*}"
  rest="${line#*|}"
  adapter="${rest%%|*}"
  rest2="${rest#*|}"
  weight="${rest2%%|*}"
  script="${KCG_ROOT}/${adapter}"
  kcg_step_begin C "plugin-${id}"
  if [[ -f "${script}" ]]; then
    run_capture bash "${script}" "${weight}"
  else
    python3 -c 'import json,sys; print("KCG_RESULT "+json.dumps({"id":"plugin-"+sys.argv[1],"tier":"C","result":"fail","detail":"adapter missing","source":"plugin"},separators=(",",":")))' "${id}" >>"${RESULTS}"
  fi
  kcg_step_end C "plugin-${id}"
done < <(python3 -c "
import yaml,sys
p=yaml.safe_load(open(sys.argv[1]))
for pl in p.get('plugins') or []:
    if pl.get('enabled', True) is False:
        continue
    print('|'.join([pl['id'], pl['adapter'], pl.get('decision_weight','hard')]))
" "${PROFILE}")
kcg_progress phase-end --phase C


if [[ "${SKIP_SOAK}" -eq 1 ]]; then
  export KCG_SKIP_SOAK=1
fi
if [[ -n "${SOAK_SECONDS}" ]]; then
  export KCG_SOAK_SECONDS="${SOAK_SECONDS}"
fi
kcg_step_begin D soak
run_capture "${SCRIPT_DIR}/checks/tier-d-soak.sh" "${PROFILE}"
kcg_step_end D soak

if [[ "${SELF_TEST_REJECT}" -eq 1 ]]; then
  echo 'KCG_RESULT {"id":"self-test-reject","tier":"B","result":"fail","detail":"synthetic Type I injection","source":"builtin"}' >>"${RESULTS}"
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_JSON="${EVIDENCE}/report-${STAMP}.json"
OUT_MD="${EVIDENCE}/report-${STAMP}.md"

kcg_step_begin aggregate report
set +e
DECISION="$(python3 "${SCRIPT_DIR}/lib/kcg_aggregate.py" \
  --profile "${PROFILE}" \
  --baseline "${BASELINE}" \
  --preflight-id "${PREFLIGHT_ID}" \
  --results-file "${RESULTS}" \
  --out-json "${OUT_JSON}" \
  --out-md "${OUT_MD}" \
  --uname "${UNAME}")"
EC=$?
set -e
kcg_step_end aggregate report
kcg_progress suite-done --decision "${DECISION}" --exit-code "${EC}"

ln -sfn "$(basename "${OUT_JSON}")" "${EVIDENCE}/CURRENT_REPORT"
echo "decision=${DECISION} exit=${EC}"
echo "report=${OUT_JSON}"
echo "markdown=${OUT_MD}"
exit "${EC}"
