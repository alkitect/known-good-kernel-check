#!/usr/bin/env bash
# Shared helpers for known-good-kernel-check. Source only — do not execute.
# Caller must set KCG_ROOT to this repo root before sourcing.
# shellcheck shell=bash

KCG_SUITE_VERSION="0.4.0"
KCG_SCHEMA_VERSION="1.0"

kcg_require_root() {
  if [[ -z "${KCG_ROOT:-}" || ! -d "${KCG_ROOT}/profile" ]]; then
    echo "ERROR: KCG_ROOT unset or invalid (set to the known-good-kernel-check repo root)" >&2
    exit 2
  fi
}

# Emit one check result for the runner (stdout). Never exit 2 from checks/adapters.
kcg_emit() {
  local id="$1" tier="$2" result="$3" detail="${4:-}"
  python3 -c '
import json, sys
id, tier, result, detail = sys.argv[1:5]
print("KCG_RESULT " + json.dumps({
  "id": id, "tier": tier, "result": result, "detail": detail,
  "source": "builtin"
}, separators=(",", ":")))
' "$id" "$tier" "$result" "$detail"
}

kcg_emit_plugin() {
  local id="$1" tier="$2" result="$3" detail="${4:-}" plugin_exit="${5:-}"
  python3 -c '
import json, sys
id, tier, result, detail, pe = sys.argv[1:6]
obj = {"id": id, "tier": tier, "result": result, "detail": detail,
       "source": "plugin", "mapped_result": result}
if pe != "":
  try:
    obj["plugin_exit"] = int(pe)
  except ValueError:
    obj["plugin_exit"] = pe
print("KCG_RESULT " + json.dumps(obj, separators=(",", ":")))
' "$id" "$tier" "$result" "$detail" "$plugin_exit"
}

kcg_load_type1_regex() {
  local sig="${KCG_ROOT}/signatures/amdgpu-type1.txt"
  local parts=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    parts+=("$line")
  done <"$sig"
  local IFS='|'
  echo "${parts[*]}"
}

# Progress UX → stderr only (never KCG_RESULT). Honors KCG_PROGRESS=auto|tty|plain|off.
# Requires SCRIPT_DIR (or KCG_PROGRESS_PY) pointing at scripts/ when called from runner.
kcg_progress() {
  local py="${KCG_PROGRESS_PY:-${SCRIPT_DIR:-}/lib/kcg_progress.py}"
  if [[ ! -f "${py}" ]]; then
    py="${KCG_ROOT}/scripts/lib/kcg_progress.py"
  fi
  python3 "${py}" "$@"
}
