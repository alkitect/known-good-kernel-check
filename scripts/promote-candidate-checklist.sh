#!/usr/bin/env bash
# Plan 1b GO/NO-GO checklist — READ-ONLY. Does not re-run soak or change system state.
# Exit 0 = GO · Exit 1 = NO-GO
set -euo pipefail

KCG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/kcg-common.sh
source "${KCG_ROOT}/scripts/lib/kcg-common.sh"
# shellcheck source=lib/kcg-lane.sh
source "${KCG_ROOT}/scripts/lib/kcg-lane.sh"
kcg_require_root

PROFILE="${KCG_PROFILE:-}"
REPORT=""
PREFLIGHT=""
TRACKING="${KCG_CAMPAIGN_TRACKING:-${KCG_ROOT}/docs/campaign-tracking.example.md}"
MAX_AGE_HOURS="${KCG_PRE_UNHOLD_HOURS:-24}"
SKIP_AGE=0

usage() {
  cat <<EOF
Usage: $0 --report PATH --preflight PATH [--profile PATH] [--tracking PATH] [--max-age-hours N] [--skip-age-check]

READ-ONLY Plan 1b checklist. Never unholds packages or edits GRUB.
GO (exit 0): decision PROMOTE, or HOLD with all warn ids ⊆ profile promotion_allowed_warns
             and TRACKING hold_reviewed: yes with matching warn_ids.
NO-GO (exit 1): REJECT, mismatches, missing review, report older than N hours (default 24),
             or soak ledger summarize fails (min runs/pass since observe_start).

Also requires evidence/soak-ledger.jsonl summarize GO (gate mode / suite>=0.3 rows only).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --report) REPORT="$2"; shift 2 ;;
    --preflight) PREFLIGHT="$2"; shift 2 ;;
    --tracking) TRACKING="$2"; shift 2 ;;
    --max-age-hours) MAX_AGE_HOURS="$2"; shift 2 ;;
    --skip-age-check) SKIP_AGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${REPORT}" || -z "${PREFLIGHT}" ]]; then
  echo "ERROR: --report and --preflight are required" >&2
  usage
  exit 1
fi

if [[ -z "${PROFILE}" ]]; then
  kcg_lane_apply_if_needed
  PROFILE="${KCG_PROFILE}"
  TRACKING="${KCG_CAMPAIGN_TRACKING:-${TRACKING}}"
fi

for f in "${PROFILE}" "${REPORT}" "${PREFLIGHT}" "${TRACKING}"; do
  if [[ ! -f "$f" ]]; then
    echo "NO-GO: missing file: $f"
    exit 1
  fi
done

# Resolve report if symlink
REPORT_RESOLVED="$(readlink -f "${REPORT}")"
PREFLIGHT_RESOLVED="$(readlink -f "${PREFLIGHT}")"
PROFILE_RESOLVED="$(readlink -f "${PROFILE}")"

LEDGER="${KCG_EVIDENCE:-${KCG_ROOT}/evidence}/soak-ledger.jsonl"
LIB="${KCG_ROOT}/scripts/lib"

python3 - "$PROFILE_RESOLVED" "$REPORT_RESOLVED" "$PREFLIGHT_RESOLVED" "$TRACKING" "$MAX_AGE_HOURS" "$SKIP_AGE" "$LEDGER" "$LIB" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
except ImportError:
    print("NO-GO: PyYAML required (python3-yaml)")
    sys.exit(1)

profile_path, report_path, preflight_path, tracking_path, max_age_s, skip_age_s, ledger_path, lib_dir = sys.argv[1:9]
max_age_h = float(max_age_s)
skip_age = skip_age_s == "1"
sys.path.insert(0, lib_dir)
from kcg_ledger import load_rows, observe_start_from_tracking, summarize  # noqa: E402

def fail(msg: str) -> None:
    print(f"NO-GO: {msg}")
    sys.exit(1)

profile = yaml.safe_load(Path(profile_path).read_text(encoding="utf-8"))
report = json.loads(Path(report_path).read_text(encoding="utf-8"))
preflight = json.loads(Path(preflight_path).read_text(encoding="utf-8"))
tracking = Path(tracking_path).read_text(encoding="utf-8")

# Soak ledger (Plan 0.3+) — bound to observe_start; hard-pack FAIL → NO-GO
cadence = (profile.get("soak") or {}).get("cadence") or {}
min_runs = int(cadence.get("min_runs_for_pre_unhold") or 1)
min_pass = int(cadence.get("min_pass_runs_for_pre_unhold") or 1)
min_login = int(cadence.get("min_source_login") or 1)
min_days = int(cadence.get("min_calendar_days") or 1)
prefer_passes = int(cadence.get("prefer_passes_for_confidence") or 3)
prefer_days = float(cadence.get("prefer_calendar_days") or 2)
high_passes = int(cadence.get("high_passes_for_confidence") or 5)
high_days = float(cadence.get("high_calendar_days") or 3)
since = observe_start_from_tracking(Path(tracking_path))
if since is None:
    fail("TRACKING missing observe_start (required for ledger summarize)")
rows = load_rows(Path(ledger_path))
want_kv = str(profile.get("kernel_version") or "")
if not want_kv:
    fail("profile missing kernel_version (required for ledger uname filter)")
summary = summarize(
    rows,
    since=since,
    min_runs=min_runs,
    min_pass=min_pass,
    min_source_login=min_login,
    min_calendar_days=min_days,
    prefer_passes=prefer_passes,
    prefer_days=prefer_days,
    high_passes=high_passes,
    high_days=high_days,
    uname_r=want_kv,
)
if not summary.get("ok"):
    fail("soak ledger summarize: " + "; ".join(summary.get("reasons") or ["failed"]))
conf = summary.get("confidence") or "low"
print(
    f"ledger OK: runs={summary['runs']} passes={summary['passes']} "
    f"boots={summary['distinct_boot_ids']} "
    f"login_pass={summary.get('login_passes', summary.get('login_rows'))} "
    f"days={summary.get('calendar_days')} "
    f"confidence={conf} path={summary.get('confidence_path')}"
)
print(f"confidence advice: {summary.get('advice')}")
if conf == "low":
    print(
        "WARN: soft floor met but confidence=low — prefer more login soaks "
        "before unhold unless Human accepts residual risk"
    )
elif conf == "medium":
    print("NOTE: confidence=medium — soak more for high, or proceed accepting residual risk")
# Soft advisory: campaign should have enabled login soak at some point
if "login_soak_enabled: yes" not in tracking and "login_soak_enabled_at:" not in tracking:
    print("WARN: TRACKING never recorded login_soak_enabled — confirm PBIT ran this campaign")

want_kv = str(profile.get("kernel_version") or "")
allowed = set(profile.get("promotion_allowed_warns") or [])
decision = report.get("decision")
uname = report.get("uname") or ""
pf_uname = preflight.get("uname") or ""

if not want_kv:
    fail("profile missing kernel_version")
if uname != want_kv:
    fail(f"report uname {uname!r} != profile kernel_version {want_kv!r}")
if pf_uname != want_kv:
    fail(f"preflight uname {pf_uname!r} != profile kernel_version {want_kv!r}")
if uname != pf_uname:
    fail(f"report/preflight uname mismatch {uname!r} vs {pf_uname!r}")

# Soft check: report.profile_id matches profile when present
rp = report.get("profile_id") or ""
pp = profile.get("profile_id") or ""
if rp and pp and rp != pp:
    fail(f"report profile_id {rp!r} != profile {pp!r}")

# Freshness vs report.started_at
if not skip_age:
    started = report.get("started_at") or ""
    if not started:
        fail("report missing started_at (cannot verify N-hour freshness)")
    try:
        # support Z and +00:00
        ts = started.replace("Z", "+00:00")
        when = datetime.fromisoformat(ts)
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
    except ValueError:
        fail(f"unparseable started_at: {started!r}")
    age_h = (datetime.now(timezone.utc) - when.astimezone(timezone.utc)).total_seconds() / 3600.0
    if age_h > max_age_h:
        fail(f"report age {age_h:.1f}h > max {max_age_h}h (pre-unhold freshness N)")

checks = report.get("checks") or []
warn_ids = sorted({c.get("id") for c in checks if c.get("result") == "warn" and c.get("id")})
fail_ids = sorted({c.get("id") for c in checks if c.get("result") == "fail" and c.get("id")})

if decision == "REJECT" or fail_ids:
    fail(f"decision={decision} fail_ids={fail_ids}")

if decision == "PROMOTE":
    if warn_ids and profile.get("hold_on_any_warn", True):
        # inconsistent but treat as NO-GO if warns present under hold_on_any_warn
        fail(f"PROMOTE with warn ids present: {warn_ids}")
    print("GO: PROMOTE")
    print(f"  report={report_path}")
    print(f"  preflight={preflight_path}")
    print(f"  profile={profile_path}")
    print("  Human-only next: unhold / GRUB per docs/PROMOTE-CHECKLIST.md")
    sys.exit(0)

if decision != "HOLD":
    fail(f"unknown decision {decision!r}")

# HOLD path: allowlist + TRACKING review
extra = [w for w in warn_ids if w not in allowed]
if extra:
    fail(f"HOLD warn ids not in promotion_allowed_warns: {extra} (allowed={sorted(allowed)})")

# Parse TRACKING yaml-ish fields from markdown
def field_bool(name: str):
    m = re.search(rf"(?m)^\s*{re.escape(name)}:\s*(.+)\s*$", tracking)
    return m.group(1).strip().strip('"').strip("'") if m else None

def field_list(name: str) -> list[str]:
    # warn_ids: [] or warn_ids:\n  - a\n  - b
    m = re.search(rf"(?ms)^\s*{re.escape(name)}:\s*(\[[^\]]*\]|(?:\n(?:\s*-\s*.+\n?)+))", tracking)
    if not m:
        return []
    raw = m.group(1).strip()
    if raw.startswith("["):
        try:
            val = yaml.safe_load(raw)
            return [str(x) for x in (val or [])]
        except Exception:
            return []
    items = []
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("-"):
            items.append(line[1:].strip().strip('"').strip("'"))
    return items

reviewed = (field_bool("hold_reviewed") or "no").lower()
if reviewed not in ("yes", "true", "1"):
    fail("TRACKING hold_reviewed is not yes (required for HOLD GO)")

tracked_warns = field_list("warn_ids")
if set(tracked_warns) != set(warn_ids):
    fail(f"TRACKING warn_ids {tracked_warns} != report warns {warn_ids}")

print("GO: reviewed HOLD")
print(f"  report={report_path}")
print(f"  preflight={preflight_path}")
print(f"  profile={profile_path}")
print(f"  warn_ids={warn_ids}")
print("  Human-only next: unhold / GRUB per docs/PROMOTE-CHECKLIST.md")
sys.exit(0)
PY
