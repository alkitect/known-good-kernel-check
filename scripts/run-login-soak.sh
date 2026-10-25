#!/usr/bin/env bash
# PBIT-style login soak: Tier D only (gate), once per boot, non-blocking for systemd.
# Ledger append + stamp after completion. Does NOT require --acceptance preflight.
# Env: KCG_PROFILE, KCG_EVIDENCE, KCG_SKIP_LOGIN_SOAK=1, KCG_LOGIN_SOAK_DRY=1,
#      KCG_BOOT_ID, KCG_CANDIDATE_PROFILE, KCG_LOGIN_SOAK_NOTIFY=0 to silence notify-send
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KCG_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/kcg-common.sh
source "${SCRIPT_DIR}/lib/kcg-common.sh"
# shellcheck source=lib/kcg-lane.sh
source "${SCRIPT_DIR}/lib/kcg-lane.sh"
kcg_require_root
kcg_lane_apply_if_needed

EVIDENCE="${KCG_EVIDENCE:-${KCG_ROOT}/evidence}"
mkdir -p "${EVIDENCE}"
TRACKING="${KCG_CAMPAIGN_TRACKING:-${KCG_ROOT}/docs/campaign-tracking.example.md}"
BASELINES="${KCG_BASELINES:-${KCG_ROOT}/baselines}"

BOOT_ID="${KCG_BOOT_ID:-}"
if [[ -z "${BOOT_ID}" && -r /proc/sys/kernel/random/boot_id ]]; then
  BOOT_ID="$(tr -d '[:space:]' </proc/sys/kernel/random/boot_id)"
fi
BOOT_ID="${BOOT_ID:-unknown}"

# systemd user units often lack DISPLAY — fall back to GNOME defaults
export DISPLAY="${DISPLAY:-:0}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

UNAME="$(uname -r)"
PROFILE="${KCG_PROFILE:?set KCG_PROFILE or use lane resolver}"
# Once per systemd activation (each graphical login) or once per boot for manual runs
if [[ -n "${INVOCATION_ID:-}" ]]; then
  STAMP_FILE="${EVIDENCE}/login-soak-stamp-inv-${INVOCATION_ID}"
elif [[ -n "${XDG_SESSION_ID:-}" ]]; then
  STAMP_FILE="${EVIDENCE}/login-soak-stamp-sess-${XDG_SESSION_ID}"
else
  STAMP_FILE="${EVIDENCE}/login-soak-stamp-boot-${BOOT_ID}"
fi
LEDGER="${EVIDENCE}/soak-ledger.jsonl"

notify_user() {
  local summary="$1" body="$2"
  [[ "${KCG_LOGIN_SOAK_NOTIFY:-1}" == "1" ]] || return 0
  if command -v notify-send >/dev/null 2>&1; then
    notify-send --app-name="known-good-kernel-check" --urgency=normal \
      "${summary}" "${body}" 2>/dev/null || true
  fi
}

set_tracking_enabled() {
  local val="$1"
  [[ -f "${TRACKING}" ]] || return 0
  (
    flock -x 9
    if grep -q 'login_soak_enabled:' "${TRACKING}"; then
      sed -i "s/login_soak_enabled: .*/login_soak_enabled: ${val}/" "${TRACKING}" || true
    fi
  ) 9>"${TRACKING}.lock"
}

ledger_skip() {
  local reason="$1"
  python3 "${SCRIPT_DIR}/lib/kcg_ledger.py" append \
    --ledger "${LEDGER}" \
    --boot-id "${BOOT_ID}" \
    --uname-r "${UNAME}" \
    --profile "$(basename "${PROFILE}")" \
    --mode gate \
    --decision SKIP \
    --source login \
    --suite-version "${KCG_SUITE_VERSION}" \
    --detail "${reason}" >/dev/null
  echo "login-soak SKIP: ${reason}"
}

stamp_boot() {
  : >"${STAMP_FILE}"
}

if [[ "${KCG_SKIP_LOGIN_SOAK:-0}" == "1" ]]; then
  ledger_skip "KCG_SKIP_LOGIN_SOAK=1"
  stamp_boot
  exit 0
fi

if [[ -f "${STAMP_FILE}" ]]; then
  ledger_skip "once-per-boot stamp exists (${STAMP_FILE})"
  exit 0
fi

# Require lane baseline before Tier D — do NOT stamp (same-session collect after capture)
if [[ ! -L "${BASELINES}/CURRENT" && ! -f "${BASELINES}/CURRENT" ]]; then
  ledger_skip "no baselines/CURRENT under ${BASELINES} — run capture-baseline.sh for this lane"
  notify_user "KCG login soak skipped" "Capture baseline for ${UNAME} first"
  exit 0
fi

# Cadence: 1 login soak/day (local) × max_runs_for_campaign (default 7) ⇒ ≥7 local days
CADENCE_JSON="$(python3 -c "
import json,yaml,sys
p=yaml.safe_load(open(sys.argv[1])) or {}
c=(p.get('soak') or {}).get('cadence') or {}
print(json.dumps({
  'max_runs': int(c.get('max_runs_for_campaign', 7)),
  'per_day': int(c.get('max_login_soaks_per_day', 1)),
}))
" "${PROFILE}" 2>/dev/null || echo '{"max_runs":7,"per_day":1}')"
MAX_RUNS="$(python3 -c "import json,sys; print(json.load(sys.stdin)['max_runs'])" <<<"${CADENCE_JSON}")"
PER_DAY="$(python3 -c "import json,sys; print(json.load(sys.stdin)['per_day'])" <<<"${CADENCE_JSON}")"

COUNT="$(python3 "${SCRIPT_DIR}/lib/kcg_ledger.py" count \
  --ledger "${LEDGER}" \
  --tracking "${TRACKING}" \
  --uname-r "${UNAME}" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo 0)"
if [[ "${COUNT}" -ge "${MAX_RUNS}" ]]; then
  ledger_skip "campaign_cap login_count=${COUNT} max_runs=${MAX_RUNS}"
  stamp_boot
  systemctl --user disable --now kcg-login-soak.service 2>/dev/null || true
  set_tracking_enabled no
  exit 0
fi

if [[ "${PER_DAY}" -gt 0 ]]; then
  DAY_CAP_JSON="$(python3 "${SCRIPT_DIR}/lib/kcg_ledger.py" daily-cap \
    --ledger "${LEDGER}" \
    --tracking "${TRACKING}" \
    --uname-r "${UNAME}" \
    --per-day "${PER_DAY}" 2>/dev/null || echo '{"allow":true,"reason":"daily_cap_error"}')"
  DAY_ALLOW="$(python3 -c "import json,sys; print('1' if json.load(sys.stdin).get('allow') else '0')" <<<"${DAY_CAP_JSON}")"
  if [[ "${DAY_ALLOW}" != "1" ]]; then
    DAY_N="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('count',0))" <<<"${DAY_CAP_JSON}")"
    LAST_D="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('last_decision') or '')" <<<"${DAY_CAP_JSON}")"
    ledger_skip "daily_cap login_today=${DAY_N} max_per_day=${PER_DAY} last=${LAST_D} (campaign ${COUNT}/${MAX_RUNS}; FAIL grants one same-day retry)"
    stamp_boot
    exit 0
  fi
  DAY_REASON="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('reason') or '')" <<<"${DAY_CAP_JSON}")"
  if [[ "${DAY_REASON}" == "fail_retry" ]]; then
    echo "login-soak: daily FAIL retry — one extra soak allowed today"
  fi
fi

# Kernel must match profile — stamp so misconfig does not re-fire every graphical-session
EXPECTED_KV="$(python3 -c "import yaml,sys; print(yaml.safe_load(open(sys.argv[1]))['kernel_version'])" "${PROFILE}")"
if [[ "${UNAME}" != "${EXPECTED_KV}" ]]; then
  echo "ERROR: uname ${UNAME} != profile kernel_version ${EXPECTED_KV}" >&2
  echo "HINT: set KCG_PROFILE / candidate yaml for Plan 1b observe on ${UNAME}" >&2
  ledger_skip "profile_mismatch uname=${UNAME} want=${EXPECTED_KV}"
  stamp_boot
  notify_user "KCG login soak skipped" "Kernel ${UNAME} ≠ profile ${EXPECTED_KV}"
  exit 0
fi

if [[ "${KCG_LOGIN_SOAK_DRY:-0}" == "1" ]]; then
  echo "login-soak DRY: would run Tier D on ${PROFILE} boot_id=${BOOT_ID}"
  # source=smoke — excluded from campaign count + promote summarize
  python3 "${SCRIPT_DIR}/lib/kcg_ledger.py" append \
    --ledger "${LEDGER}" \
    --boot-id "${BOOT_ID}" \
    --uname-r "${UNAME}" \
    --profile "$(basename "${PROFILE}")" \
    --mode gate \
    --duration-s 0 \
    --decision PASS \
    --source smoke \
    --suite-version "${KCG_SUITE_VERSION}" \
    --detail "dry-run" >/dev/null
  stamp_boot
  echo "login-soak DRY: stamp written ${STAMP_FILE} (not counted toward promote)"
  exit 0
fi

export KCG_LOGIN_SOAK=1
export KCG_SOAK_MODE=gate
# Smoke prove must not consume campaign login cap
if [[ "${KCG_SOAK_SMOKE:-0}" == "1" ]]; then
  export KCG_SOAK_SOURCE=smoke
else
  export KCG_SOAK_SOURCE="${KCG_SOAK_SOURCE:-login}"
fi
export KCG_EVIDENCE="${EVIDENCE}"
export KCG_PROGRESS="${KCG_PROGRESS:-auto}"
export KCG_PROGRESS_PY="${SCRIPT_DIR}/lib/kcg_progress.py"

RESULTS="$(mktemp)"
trap 'rm -f "${RESULTS}"' EXIT

set +e
"${SCRIPT_DIR}/checks/tier-d-soak.sh" "${PROFILE}" >"${RESULTS}"
TIER_EC=$?
set -e

META="$(python3 - "${RESULTS}" <<'PY'
import json, sys
from pathlib import Path
results = Path(sys.argv[1]).read_text(encoding="utf-8")
decision = "PASS"
detail = ""
mode = "gate"
duration = 0
samples = ""
meta_path = ""
journal_hits = 0
load_recipe = ""
for line in results.splitlines():
    if not line.startswith("KCG_RESULT "):
        continue
    obj = json.loads(line[len("KCG_RESULT "):])
    if obj.get("id") == "soak":
        r = obj.get("result", "fail")
        decision = {"pass": "PASS", "fail": "FAIL", "warn": "WARN", "skip": "SKIP"}.get(r, r.upper())
        detail = obj.get("detail") or ""
        mode = obj.get("soak_mode") or "gate"
        duration = int(obj.get("soak_wall_s") or 0)
        samples = obj.get("samples_path") or ""
        meta_path = obj.get("meta_path") or ""
        journal_hits = int(obj.get("journal_hits") or 0)
        load_recipe = obj.get("load_recipe") or ""
print(json.dumps({
    "decision": decision, "detail": detail, "mode": mode, "duration_s": duration,
    "samples_path": samples, "meta_path": meta_path, "journal_hits": journal_hits,
    "load_recipe": load_recipe,
}))
PY
)"

DECISION="$(python3 -c "import json,sys; print(json.load(sys.stdin)['decision'])" <<<"${META}")"
DETAIL="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('detail',''))" <<<"${META}")"
MODE="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('mode','gate'))" <<<"${META}")"
DUR="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('duration_s',0))" <<<"${META}")"
SAMPLES="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('samples_path',''))" <<<"${META}")"
JHITS="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('journal_hits',0))" <<<"${META}")"
RECIPE="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('load_recipe',''))" <<<"${META}")"
META_PATH="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('meta_path',''))" <<<"${META}")"
PACKS_JSON='[]'
if [[ -n "${META_PATH}" && -f "${META_PATH}" ]]; then
  PACKS_JSON="$(python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get('packs_matched') or []))" "${META_PATH}")"
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
MINI="${EVIDENCE}/login-soak-${STAMP}.json"
python3 -c "
import json, sys
from pathlib import Path
doc = {
  'schema_version': '1.0',
  'suite_version': sys.argv[1],
  'kind': 'login-soak',
  'decision': sys.argv[2],
  'uname': sys.argv[3],
  'profile_path': sys.argv[4],
  'boot_id': sys.argv[5],
  'mode': sys.argv[6],
  'detail': sys.argv[7],
  'load_recipe': sys.argv[8],
  'started_at': '${STAMP}',
}
Path(sys.argv[9]).write_text(json.dumps(doc, indent=2)+'\n', encoding='utf-8')
" "${KCG_SUITE_VERSION}" "${DECISION}" "${UNAME}" "${PROFILE}" "${BOOT_ID}" "${MODE}" "${DETAIL}" "${RECIPE}" "${MINI}"

python3 "${SCRIPT_DIR}/lib/kcg_ledger.py" append \
  --ledger "${LEDGER}" \
  --stamp "${STAMP}" \
  --boot-id "${BOOT_ID}" \
  --uname-r "${UNAME}" \
  --profile "$(basename "${PROFILE}")" \
  --mode "${MODE}" \
  --duration-s "${DUR}" \
  --decision "${DECISION}" \
  --report-path "${MINI}" \
  --samples-path "${SAMPLES}" \
  --journal-hits "${JHITS}" \
  --packs-matched "${PACKS_JSON}" \
  --load-recipe "${RECIPE}" \
  --source "${KCG_SOAK_SOURCE}" \
  --suite-version "${KCG_SUITE_VERSION}" \
  --detail "${DETAIL}" >/dev/null

stamp_boot

echo "login-soak ${DECISION}: source=${KCG_SOAK_SOURCE} ledger=${LEDGER} report=${MINI} stamp=${STAMP_FILE}"

if [[ "${KCG_SOAK_SOURCE}" == "login" ]]; then
  if [[ "${DECISION}" == "FAIL" ]]; then
    notify_user "KCG login soak FAIL" "${DETAIL:0:200}"
  elif [[ "${DECISION}" == "WARN" ]]; then
    notify_user "KCG login soak WARN" "${DETAIL:0:200}"
  fi

  NEW_COUNT="$(python3 "${SCRIPT_DIR}/lib/kcg_ledger.py" count \
    --ledger "${LEDGER}" --tracking "${TRACKING}" --uname-r "${UNAME}" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo 0)"
  if [[ "${NEW_COUNT}" -ge "${MAX_RUNS}" ]]; then
    echo "login-soak: campaign_cap ${NEW_COUNT}/${MAX_RUNS} — disabling user unit"
    systemctl --user disable --now kcg-login-soak.service 2>/dev/null || true
    set_tracking_enabled no
    notify_user "KCG login soak complete" "Reached ${NEW_COUNT}/${MAX_RUNS} login soaks — unit disabled"
  fi
fi

# Always exit 0 after ledger+stamp so systemd does not restart-storm
exit 0
