#!/usr/bin/env bash
# Post-enable / post-login proof for PBIT hook (read-only checks).
# Exit 0 = hook installed correctly; exit 1 = install gaps.
# Missing first login PASS is a NOTE (exit 0) until after next graphical session.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KCG_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EVIDENCE="${KCG_EVIDENCE:-${KCG_ROOT}/evidence}"
TRACKING="${KCG_ROOT}/docs/campaign-tracking.example.md"
LEDGER="${EVIDENCE}/soak-ledger.jsonl"
CANDIDATE="${KCG_CANDIDATE_PROFILE:-${KCG_ROOT}/profile/example-generic.yaml.example}"
EC=0

ok() { echo "OK: $*"; }
bad() { echo "NO: $*"; EC=1; }

echo "=== verify-login-soak-hook ==="
echo "uname=$(uname -r) evidence=${EVIDENCE}"

if systemctl --user is-enabled kcg-login-soak.service >/dev/null 2>&1; then
  ok "unit enabled"
else
  bad "unit not enabled (run enable-login-soak.sh)"
fi

if [[ -x "${HOME}/.local/bin/kcg-login-soak" ]]; then
  ok "wrapper ~/.local/bin/kcg-login-soak"
else
  bad "missing wrapper"
fi

if [[ -f "${CANDIDATE}" ]]; then
  CKV="$(python3 -c "import yaml,sys; print(yaml.safe_load(open(sys.argv[1])).get('kernel_version',''))" "${CANDIDATE}")"
  if [[ "${CKV}" == "$(uname -r)" ]]; then
    ok "candidate kernel_version matches uname (${CKV})"
  else
    bad "candidate kernel_version=${CKV} != uname=$(uname -r)"
  fi
else
  bad "missing candidate profile ${CANDIDATE}"
fi

if [[ -f "${TRACKING}" ]] && grep -q 'login_soak_enabled: yes' "${TRACKING}"; then
  ok "TRACKING login_soak_enabled: yes"
else
  bad "TRACKING login_soak_enabled not yes"
fi

if [[ -f "${LEDGER}" ]]; then
  LOGIN_PASS="$(
    python3 -c "
import sys
sys.path.insert(0, '${SCRIPT_DIR}/lib')
from pathlib import Path
from kcg_ledger import load_rows, observe_start_from_tracking, is_dry_or_smoke, _parse_ts
rows = load_rows(Path('${LEDGER}'))
since = observe_start_from_tracking(Path('${TRACKING}'))
n = 0
for r in rows:
    if is_dry_or_smoke(r):
        continue
    if str(r.get('source')) != 'login':
        continue
    if str(r.get('decision') or '').upper() != 'PASS':
        continue
    st = _parse_ts(str(r.get('stamp') or ''))
    if since and st and st < since:
        continue
    dur = int(r.get('duration_s') or 0)
    if dur <= 0 and not r.get('load_recipe'):
        continue
    n += 1
print(n)
"
  )"
  ok "ledger exists; real login PASS rows since observe_start=${LOGIN_PASS}"
  if grep -qE 'dry-run|"source":"smoke"' "${LEDGER}" 2>/dev/null; then
    echo "NOTE: smoke/dry-run rows present (excluded from promote count)"
  fi
  if [[ "${LOGIN_PASS}" -lt 1 ]]; then
    echo "NOTE: no real login PASS yet — wait for next graphical login (~45s after session)"
  fi
else
  echo "NOTE: no ledger yet — expected until first real login soak"
fi

echo "Recent unit journal (if any):"
journalctl --user -u kcg-login-soak.service -n 15 --no-pager 2>/dev/null || true

exit "${EC}"
