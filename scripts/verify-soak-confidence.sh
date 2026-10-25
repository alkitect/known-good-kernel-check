#!/usr/bin/env bash
# Assert soft-floor vs data-first confidence paths (advisory; not a promote gate).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KCG_ROOT="$ROOT"
export PYTHONPATH="${ROOT}/scripts/lib${PYTHONPATH:+:$PYTHONPATH}"

python3 - <<'PY'
from datetime import datetime, timedelta, timezone
from pathlib import Path
import os
import sys

from kcg_ledger import (
    confidence_level,
    count_campaign_runs,
    daily_cap_decision,
    load_rows,
    summarize,
)

ROOT = Path(os.environ["KCG_ROOT"])
UNAME_CI = "6.8.0-ci-generic"
UNAME_136 = "6.8.0-136-generic"
UNAME_138 = "6.8.0-138-generic"


def assert_eq(label, got, want):
    if got != want:
        print(f"FAIL {label}: got={got!r} want={want!r}", file=sys.stderr)
        sys.exit(1)
    print(f"ok {label}: {got}")


base = dict(
    hard_fails=0,
    prefer_passes=3,
    prefer_days=2.0,
    high_passes=5,
    high_days=3.0,
)

c = confidence_level(
    ok=True, login_passes=1, distinct_boots=1, calendar_days=1.0, **base
)
assert_eq("soft_floor.confidence", c["confidence"], "low")
assert_eq("soft_floor.path", c["confidence_path"], "soft_floor")

c = confidence_level(
    ok=True, login_passes=3, distinct_boots=2, calendar_days=0.2, **base
)
assert_eq("medium.data.confidence", c["confidence"], "medium")
assert_eq("medium.data.path", c["confidence_path"], "data")

c = confidence_level(
    ok=True, login_passes=5, distinct_boots=2, calendar_days=0.2, **base
)
assert_eq("high.data.confidence", c["confidence"], "high")
assert_eq("high.data.path", c["confidence_path"], "data")

# Soft-floor: short fixture has 2 login PASS / 2 boots — below prefer_passes=3.
# prefer_days=99 so calendar path cannot raise confidence in this assert.
since_short = datetime(2026, 10, 20, tzinfo=timezone.utc)
short = summarize(
    load_rows(ROOT / "fixtures/soak-ledger-short.jsonl"),
    since=since_short,
    min_runs=1,
    min_pass=1,
    min_source_login=1,
    min_calendar_days=1,
    prefer_days=99.0,
    high_days=99.0,
    uname_r=UNAME_CI,
)
assert_eq("fixture.short.ok", short["ok"], True)
assert_eq("fixture.short.confidence", short["confidence"], "low")
assert_eq("fixture.short.path", short["confidence_path"], "soft_floor")

# Data path: enough fixture ≥5 login PASS / multi-boot → high even with short calendar
# (use since that still includes fixture stamps from 2026-10-21..).
since_enough = datetime(2026, 10, 20, tzinfo=timezone.utc)
enough = summarize(
    load_rows(ROOT / "fixtures/soak-ledger-enough.jsonl"),
    since=since_enough,
    min_runs=1,
    min_pass=1,
    min_source_login=1,
    min_calendar_days=1,
    uname_r=UNAME_CI,
)
assert_eq("fixture.enough.ok", enough["ok"], True)
assert_eq("fixture.enough.confidence", enough["confidence"], "high")
assert_eq("fixture.enough.path", enough["confidence_path"], "data")

multi = load_rows(ROOT / "fixtures/soak-ledger-multi-uname.jsonl")
n136 = count_campaign_runs(multi, since=since_enough, uname_r=UNAME_136)
n138 = count_campaign_runs(multi, since=since_enough, uname_r=UNAME_138)
n_all = count_campaign_runs(multi, since=since_enough, uname_r="")
assert_eq("multi.count.136", n136, 3)
assert_eq("multi.count.138", n138, 2)
assert_eq("multi.count.all_gt_lane", n_all > n136, True)

# Daily cap + FAIL retry (synthetic rows; day_key from stamp TZ)
from kcg_ledger import local_day_key, _parse_ts

synth = [
    {
        "stamp": "20261025T100000Z",
        "boot_id": "b1",
        "uname_r": "abi-x",
        "mode": "gate",
        "decision": "FAIL",
        "source": "login",
        "suite_version": "0.4.0",
    },
]
dk = local_day_key(_parse_ts("20261025T100000Z"))
d = daily_cap_decision(synth, uname_r="abi-x", per_day=1, day_key=dk)
assert_eq("daily.fail_retry.allow", d["allow"], True)
assert_eq("daily.fail_retry.reason", d["reason"], "fail_retry")

synth.append(
    {
        "stamp": "20261025T120000Z",
        "boot_id": "b2",
        "uname_r": "abi-x",
        "mode": "gate",
        "decision": "PASS",
        "source": "login",
        "suite_version": "0.4.0",
    }
)
d2 = daily_cap_decision(synth, uname_r="abi-x", per_day=1, day_key=dk)
assert_eq("daily.after_retry.allow", d2["allow"], False)

synth_pass = [
    {
        "stamp": "20261025T100000Z",
        "boot_id": "b1",
        "uname_r": "abi-x",
        "mode": "gate",
        "decision": "PASS",
        "source": "login",
        "suite_version": "0.4.0",
    }
]
d3 = daily_cap_decision(synth_pass, uname_r="abi-x", per_day=1, day_key=dk)
assert_eq("daily.pass.allow", d3["allow"], False)
assert_eq("daily.pass.reason", d3["reason"], "daily_cap")

print("verify-soak-confidence: all paths OK")
PY
