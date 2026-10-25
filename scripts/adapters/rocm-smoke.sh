#!/usr/bin/env bash
# Adapter: light ROCm / KFD smoke — warn by default; skip if stack absent.
set -euo pipefail
WEIGHT="${1:-warn}"

emit() {
  python3 -c 'import json,sys; print("KCG_RESULT "+json.dumps({"id":"plugin-rocm-smoke","tier":"C","result":sys.argv[1],"detail":sys.argv[2],"source":"plugin","plugin_exit":int(sys.argv[3]),"mapped_result":sys.argv[1]},separators=(",",":")))' "$1" "$2" "$3"
}

# Prefer /dev/kfd presence
if [[ ! -e /dev/kfd ]]; then
  if [[ "${WEIGHT}" == "hard" ]]; then
    emit fail "/dev/kfd missing" 1
  else
    emit skip "/dev/kfd missing" 0
  fi
  exit 0
fi

if ! command -v rocminfo >/dev/null 2>&1; then
  emit warn "/dev/kfd present but rocminfo not in PATH" 0
  exit 0
fi

set +e
OUT="$(rocminfo 2>&1)"
EC=$?
set -e

if [[ "${EC}" -eq 0 ]] && echo "${OUT}" | grep -qiE 'Agent|Marketing Name|GPU'; then
  emit pass "rocminfo ok" "${EC}"
elif [[ "${WEIGHT}" == "hard" ]]; then
  emit fail "rocminfo failed" "${EC}"
else
  emit warn "rocminfo failed or empty agents" "${EC}"
fi
