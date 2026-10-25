#!/usr/bin/env bash
# Release gate for known-good-kernel-check (local + CI).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# Patterns encoded so this file is not a false positive.
_p1='topics/'
_p2='.cursor/plans'
_p3='Python/linux'
FORBIDDEN_RE="${_p1}|${_p2}|${_p3}"

hits="$(grep -rE "${FORBIDDEN_RE}" \
  --include='*.sh' --include='*.md' --include='*.yaml' --include='*.yml' \
  --include='*.example' --include='*.json' --include='*.jsonl' --include='*.txt' --include='*.py' . \
  --exclude-dir=.git --exclude-dir=__pycache__ --exclude-dir=baselines --exclude-dir=evidence \
  --exclude='ci-check.sh' 2>/dev/null || true)"
if [[ -n "${hits}" ]]; then
  echo "ci-check: forbidden monorepo path refs found:" >&2
  echo "${hits}" >&2
  exit 1
fi

# Private campaign doc names must not ship (hostboard strings stay out of this file — monorepo rg gates those)
if [[ -e docs/PLAN1B-TRACKING.md || -e docs/PLAN1B-PROMOTE-PROTOCOL.md ]]; then
  echo "ci-check: private Plan1b campaign docs must not ship in the extract" >&2
  exit 1
fi
# Host-named profiles must not ship (only example-generic + ci-smoke)
shopt -s nullglob
for _pf in profile/*.yaml profile/*.yml; do
  base="$(basename "${_pf}")"
  case "${base}" in
    ci-smoke.yaml|example-generic.yaml) ;;
    *)
      echo "ci-check: unexpected profile file (host-named?): ${_pf}" >&2
      exit 1
      ;;
  esac
done
shopt -u nullglob

# baselines/evidence must not be tracked content (dirs gitignored; fail if any regular files committed)
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tracked="$(git ls-files baselines evidence 2>/dev/null || true)"
  if [[ -n "${tracked}" ]]; then
    echo "ci-check: baselines/ or evidence/ must not be tracked:" >&2
    echo "${tracked}" >&2
    exit 1
  fi
fi

REQUIRED_H2=(
  "## What this does"
  "## Who this is for"
  "## Quick start"
  "## Check it works"
  "## Uninstall"
  "## Limits & safety"
  "## License"
)
for h in "${REQUIRED_H2[@]}"; do
  grep -qFx "${h}" README.md || { echo "ci-check: README missing H2: ${h}" >&2; exit 1; }
done
if grep -qE '\bSSOT\b' README.md; then
  echo "ci-check: README must not use SSOT; say release source" >&2
  exit 1
fi

[[ -f .github/FUNDING.yml ]] || { echo "ci-check: missing .github/FUNDING.yml" >&2; exit 1; }
grep -qE '^[[:space:]]*ko_fi:[[:space:]]*alkitect[[:space:]]*$' .github/FUNDING.yml \
  || { echo "ci-check: .github/FUNDING.yml must set ko_fi: alkitect" >&2; exit 1; }
grep -qF 'ko-fi.com/alkitect' README.md \
  || { echo "ci-check: README must include Ko-fi tip link ko-fi.com/alkitect" >&2; exit 1; }
grep -qF 'ko-fi.com/img/githubbutton_sm.svg' README.md \
  || { echo "ci-check: README must include Ko-fi GitHub button (githubbutton_sm.svg)" >&2; exit 1; }
if grep -qiE 'patreon\.com|buymeacoffee\.com' README.md; then
  echo "ci-check: README must not link Patreon or Buy Me a Coffee" >&2
  exit 1
fi

if LC_ALL=C grep -q $'\xe2\x80\x93\|\xe2\x80\x94' README.md; then
  echo "ci-check: README must not use en-dash or em-dash" >&2
  exit 1
fi

# Static: bash -n + py_compile
find scripts -type f -name '*.sh' -print0 | xargs -0 -r bash -n
python3 -m py_compile scripts/lib/kcg_aggregate.py scripts/lib/kcg_journal.py \
  scripts/lib/kcg_ledger.py scripts/lib/kcg_progress.py scripts/lib/kcg_soak.py scripts/lib/kcg_lane.py

# Suite version triad (First public tag stays v0.3.0; Current / suite at 0.4.0)
grep -qF 'KCG_SUITE_VERSION="0.4.0"' scripts/lib/kcg-common.sh \
  || { echo "ci-check: KCG_SUITE_VERSION must be 0.4.0" >&2; exit 1; }
grep -qF 'First public tag: v0.3.0' docs/PUBLISH.md \
  || { echo "ci-check: docs/PUBLISH.md must record First public tag: v0.3.0" >&2; exit 1; }
grep -qF 'Current tag: v0.4.0' docs/PUBLISH.md \
  || { echo "ci-check: docs/PUBLISH.md must record Current tag: v0.4.0" >&2; exit 1; }
grep -qE '^## 0\.3\.0' CHANGELOG.md \
  || { echo "ci-check: CHANGELOG missing ## 0.3.0" >&2; exit 1; }
grep -qE '^## 0\.4\.0' CHANGELOG.md \
  || { echo "ci-check: CHANGELOG missing ## 0.4.0" >&2; exit 1; }

# Required product files
test -f profile/example-generic.yaml.example
test -f profile/ci-smoke.yaml
test -f docs/SYNC.md
test -f docs/CONTRACT.md
test -f docs/PROMOTE-CHECKLIST.md
test -f scripts/adapters/rocm-smoke.sh
test -f scripts/adapters/suspend.sh
test ! -e scripts/adapters/fan.sh
test ! -e scripts/adapters/ollama.sh

# Ledger fixture summarize (soft floor)
python3 scripts/lib/kcg_ledger.py summarize \
  --ledger fixtures/soak-ledger-enough.jsonl \
  --since 2026-10-20T00:00:00Z \
  --uname-r 6.8.0-ci-generic \
  --min-runs 1 --min-pass 1 --min-source-login 0 --min-calendar-days 1 \
  >/dev/null

# Multi-uname filter
python3 scripts/lib/kcg_ledger.py count \
  --ledger fixtures/soak-ledger-multi-uname.jsonl \
  --since 2026-10-20T00:00:00Z \
  --uname-r 6.8.0-136-generic >/dev/null

# Resolver smoke under tmp root (HOME alone is not enough)
_lane_tmp="$(mktemp -d)"
cp -a profile "$_lane_tmp/"
mkdir -p "$_lane_tmp/scripts/lib" "$_lane_tmp/signatures"
cp -a scripts/lib/kcg_lane.py scripts/lib/kcg-lane.sh "$_lane_tmp/scripts/lib/"
# bootstrap twice → same observe_start
eval "$(KCG_ROOT="$_lane_tmp" KCG_LANE_TEMPLATE="$_lane_tmp/profile/example-generic.yaml.example" \
  python3 "$_lane_tmp/scripts/lib/kcg_lane.py" --root "$_lane_tmp" --uname ci-test-abi --exports --template "$_lane_tmp/profile/example-generic.yaml.example")"
_obs1="$(grep -E '^[[:space:]]*observe_start:' "$_lane_tmp/campaigns/ci-test-abi/tracking.md" | head -1)"
eval "$(KCG_ROOT="$_lane_tmp" python3 "$_lane_tmp/scripts/lib/kcg_lane.py" --root "$_lane_tmp" --uname ci-test-abi --exports --no-bootstrap)"
_obs2="$(grep -E '^[[:space:]]*observe_start:' "$_lane_tmp/campaigns/ci-test-abi/tracking.md" | head -1)"
[[ "$_obs1" == "$_obs2" ]] || { echo "ci-check: lane observe_start changed on resume" >&2; exit 1; }
rm -rf "$_lane_tmp"

# Home-path ban in markdown
if grep -rE '/home/[A-Za-z0-9._-]+' --include='*.md' . \
  --exclude-dir=.git --exclude='ci-check.sh' >/dev/null 2>&1; then
  echo "ci-check: public markdown must not contain /home/<user> host paths" >&2
  grep -rE '/home/[A-Za-z0-9._-]+' --include='*.md' . \
    --exclude-dir=.git --exclude='ci-check.sh' >&2 || true
  exit 1
fi

# Versioning gate
if [[ -f docs/PUBLISH.md ]] && grep -qF 'RC-BEFORE-1.0' docs/PUBLISH.md; then
  :
else
  if [[ -f CHANGELOG.md ]] && grep -qE '^## 0\.9\.0' CHANGELOG.md; then
    echo "ci-check: CHANGELOG ## 0.9.0 is not the default first tag; add RC-BEFORE-1.0 to docs/PUBLISH.md or use 0.1.0+" >&2
    exit 1
  fi
  for _vf in docs/PUBLISH.md README.md; do
    if [[ -f "${_vf}" ]] && grep -qE 'v0\.9\.0' "${_vf}"; then
      echo "ci-check: ${_vf} mentions v0.9.0 without RC-BEFORE-1.0" >&2
      exit 1
    fi
  done
fi

tmp="$(mktemp -d)"
cleanup() { rm -rf "${tmp}"; }
trap cleanup EXIT
export HOME="${tmp}"
export XDG_CONFIG_HOME="${tmp}/.config"
export XDG_STATE_HOME="${tmp}/.local/state"
export XDG_RUNTIME_DIR="${tmp}/run"
mkdir -p "${XDG_CONFIG_HOME}" "${XDG_STATE_HOME}" "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"
export ALKITECT_CI_TMP=1

# CI profile + baseline rewritten to this runner's uname
UNAME="$(uname -r)"
PROF="${tmp}/ci-smoke.yaml"
sed "s/CI_REWRITE_UNAME_R/${UNAME}/g" profile/ci-smoke.yaml >"${PROF}"
PHASH="$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:16])" "${PROF}")"
BL_DIR="${tmp}/baselines"
EV_DIR="${tmp}/evidence"
mkdir -p "${BL_DIR}" "${EV_DIR}"
BL="${BL_DIR}/baseline-ci.json"
python3 - "${PROF}" "${BL}" "${UNAME}" "${PHASH}" <<'PY'
import json, sys
from pathlib import Path
prof, out, uname, phash = sys.argv[1:5]
doc = {
  "baseline_id": "baseline-ci",
  "captured_at": "19700101T000000Z",
  "kernel_version": uname,
  "profile_path": prof,
  "profile_hash": phash,
  "inventory": {
    "os_pretty": "CI",
    "hwe_holds": "",
    "lockdown": "",
    "board_name": "",
    "linux_firmware_version": "",
  },
  "pci_bind": {},
  "modules": {},
}
Path(out).write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
ln -sfn "$(basename "${BL}")" "${BL_DIR}/CURRENT"

export KCG_PROFILE="${PROF}"
export KCG_BASELINES="${BL_DIR}"
export KCG_EVIDENCE="${EV_DIR}"
export KCG_PROGRESS=off

set +e
./scripts/run-compat-suite.sh --skip-soak --self-test-reject
EC=$?
set -e
if [[ "${EC}" -ne 2 ]]; then
  echo "ci-check: --self-test-reject expected exit 2, got ${EC}" >&2
  exit 1
fi

LAST="$(ls -1t "${EV_DIR}"/report-*.json 2>/dev/null | head -1 || true)"
[[ -n "${LAST}" ]] || { echo "ci-check: no report after self-test-reject" >&2; exit 1; }
./scripts/run-compat-suite.sh --offline-schema
# offline-schema uses KCG_EVIDENCE last report — ensure decision REJECT
python3 - "${LAST}" <<'PY'
import json, sys
from pathlib import Path
doc = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if doc.get("decision") != "REJECT":
    print("ci-check: expected decision REJECT, got", doc.get("decision"))
    sys.exit(1)
print("ci-check: self-test-reject OK", doc.get("decision"))
PY

# Do not enable login soak against live host; dry path only under tmp
export KCG_LOGIN_SOAK_DRY=1
export KCG_BOOT_ID=ci-boot
# Skip if no profile resolve for login — we have KCG_PROFILE
set +e
./scripts/run-login-soak.sh >/dev/null 2>&1
LS_EC=$?
set -e
# dry may exit 0; ignore non-zero if session missing
echo "ci-check: login-soak dry exit=${LS_EC} (advisory)"

echo "ci-check: OK"
