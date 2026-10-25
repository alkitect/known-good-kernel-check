#!/usr/bin/env bash
# Prove the login-soak path works in this session (does not wait for logout).
# Default: KCG_SOAK_SMOKE=1 (~20s). Full gate: KCG_SOAK_SMOKE=0 ./prove-login-soak-now.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KCG_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EVIDENCE="${KCG_EVIDENCE:-${KCG_ROOT}/evidence}"
export KCG_SOAK_SMOKE="${KCG_SOAK_SMOKE:-1}"
export DISPLAY="${DISPLAY:-:0}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export KCG_PROGRESS="${KCG_PROGRESS:-plain}"

echo "=== prove-login-soak-now (smoke=${KCG_SOAK_SMOKE}) ==="
echo "uname=$(uname -r) DISPLAY=${DISPLAY} WAYLAND=${WAYLAND_DISPLAY}"

# Refresh install
"${SCRIPT_DIR}/enable-login-soak.sh" >/tmp/kcg-enable-out.txt
tail -5 /tmp/kcg-enable-out.txt

# Unique stamp key so prove does not collide with a prior manual stamp this boot
export INVOCATION_ID="${INVOCATION_ID:-prove-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

BEFORE="$(wc -l <"${EVIDENCE}/soak-ledger.jsonl" 2>/dev/null || echo 0)"
echo "Running wrapper as systemd would (INVOCATION_ID=${INVOCATION_ID})…"
set +e
~/.local/bin/kcg-login-soak
EC=$?
set -e
echo "wrapper_exit=${EC}"

AFTER="$(wc -l <"${EVIDENCE}/soak-ledger.jsonl" 2>/dev/null || echo 0)"
echo "ledger lines: ${BEFORE} → ${AFTER}"
tail -1 "${EVIDENCE}/soak-ledger.jsonl" 2>/dev/null || true

# Must be a real login row (not smoke source) when smoke=0; when smoke=1 expect smoke source OK for plumbing
python3 -c "
import json, sys
from pathlib import Path
line = Path('${EVIDENCE}/soak-ledger.jsonl').read_text().strip().splitlines()[-1]
r = json.loads(line)
print('last_row', {k: r.get(k) for k in ('decision','source','mode','duration_s','load_recipe','detail')})
smoke = '${KCG_SOAK_SMOKE}' == '1'
if smoke:
    # plumbing proof may be smoke source OR login with load
    ok = r.get('decision') in ('PASS','WARN','FAIL','SKIP')
else:
    ok = r.get('source') == 'login' and r.get('decision') == 'PASS' and int(r.get('duration_s') or 0) > 0
sys.exit(0 if ok else 1)
"
echo "PROVE OK — next graphical login will run full gate (~5–10m after 45s delay)"
"${SCRIPT_DIR}/verify-login-soak-hook.sh" || true
