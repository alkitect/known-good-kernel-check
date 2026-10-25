#!/usr/bin/env bash
# Opt-in suspend advisory plugin — never a hard promote gate; maps to warn/skip.
# Real suspend is lab-only (see docs/PUBLIC-ROADMAP.md). This wraps check-suspend-resume.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KCG_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WEIGHT="${1:-warn}"
CHECK="${KCG_ROOT}/scripts/check-suspend-resume.sh"

emit() {
  python3 -c 'import json,sys; print("KCG_RESULT "+json.dumps({"id":"plugin-suspend","tier":"C","result":sys.argv[1],"detail":sys.argv[2],"source":"plugin","plugin_exit":int(sys.argv[3]),"mapped_result":sys.argv[1]},separators=(",",":")))' "$1" "$2" "$3"
}

if [[ ! -x "${CHECK}" && ! -f "${CHECK}" ]]; then
  emit skip "check-suspend-resume.sh missing" 0
  exit 0
fi

set +e
OUT="$("${CHECK}" 2>&1)"
EC=$?
set -e

# Always advisory: pass→pass, else warn (never fail unless weight hard — still prefer warn)
DETAIL="$(echo "${OUT}" | grep -E 'RESULT=|sys/power|KCG_RESULT' | tail -n 1 | tr -d '\n' | cut -c1-160)"
DETAIL="${DETAIL:-suspend advisory ran}"
if [[ "${EC}" -eq 0 ]] && echo "${OUT}" | grep -q 'RESULT=warn'; then
  emit warn "${DETAIL}" "${EC}"
elif [[ "${EC}" -eq 0 ]]; then
  emit warn "${DETAIL}" "${EC}"
elif [[ "${WEIGHT}" == "hard" ]]; then
  emit fail "${DETAIL}" "${EC}"
else
  emit warn "${DETAIL}" "${EC}"
fi
