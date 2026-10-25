#!/usr/bin/env bash
# Optional Plan 1b suspend probe — WARN ONLY. Must NOT feed promote-candidate-checklist GO.
# Does not call systemctl suspend. Documents presence of sleep capability + recent resume markers.
set -euo pipefail

KCG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/kcg-common.sh
source "${KCG_ROOT}/scripts/lib/kcg-common.sh"
kcg_require_root

echo "check-suspend-resume: advisory only (never a promotion gate)"
echo "Non-goal: this script must not be an input to promote-candidate-checklist.sh"

STATE=warn
DETAIL=""

if [[ -r /sys/power/state ]]; then
  STATES="$(tr ' ' ',' </sys/power/state)"
  DETAIL="sys/power/state=${STATES}"
  if ! grep -qw mem /sys/power/state; then
    DETAIL="${DETAIL}; mem not listed"
  fi
else
  DETAIL="no /sys/power/state"
fi

# Recent resume / suspend journal hints (best-effort, last boot)
RESUME_HINT="$(journalctl -b -q -o short-iso 2>/dev/null | grep -Ei 'PM: suspend|System resumed|suspend entry' | tail -n 3 || true)"
if [[ -n "${RESUME_HINT}" ]]; then
  DETAIL="${DETAIL}; recent_pm_lines=$(echo "${RESUME_HINT}" | wc -l)"
else
  DETAIL="${DETAIL}; no suspend/resume journal lines this boot"
fi

# Always warn — never pass/fail for suite aggregation unless user wires it (don't)
kcg_emit "suspend-resume-advisory" "D" "${STATE}" "${DETAIL}"
echo "RESULT=warn (advisory). Do not use for checklist GO."
exit 0
