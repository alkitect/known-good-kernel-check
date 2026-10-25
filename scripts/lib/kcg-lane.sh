#!/usr/bin/env bash
# Multi-lane resolver — source after KCG_ROOT is set.
# shellcheck shell=bash

kcg_lane_resolve() {
  local py="${KCG_ROOT}/scripts/lib/kcg_lane.py"
  local tpl="${KCG_LANE_TEMPLATE:-${KCG_ROOT}/profile/example-generic.yaml.example}"
  local args=(--root "${KCG_ROOT}" --exports --template "${tpl}")
  # shellcheck disable=SC1090
  eval "$(python3 "${py}" "${args[@]}")"
}

kcg_lane_apply_if_needed() {
  if [[ -n "${KCG_PROFILE:-}" ]]; then
    local py="${KCG_ROOT}/scripts/lib/kcg_lane.py"
    # shellcheck disable=SC1090
    eval "$(python3 "${py}" --root "${KCG_ROOT}" --exports --no-bootstrap 2>/dev/null || true)"
    return 0
  fi
  kcg_lane_resolve
}
