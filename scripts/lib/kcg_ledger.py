#!/usr/bin/env python3
"""Append-only soak ledger + summarize for Plan 1b promote checklist."""
from __future__ import annotations

import argparse
import fcntl
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


def _parse_ts(raw: str) -> Optional[datetime]:
    if not raw:
        return None
    raw = raw.strip().strip('"').strip("'")
    # Compact stamp used in evidence filenames: 20261021T060000Z
    if len(raw) >= 16 and raw[8:9] == "T" and ":" not in raw[:15]:
        try:
            when = datetime.strptime(raw.replace("Z", ""), "%Y%m%dT%H%M%S").replace(
                tzinfo=timezone.utc
            )
            return when
        except ValueError:
            return None
    try:
        ts = raw.replace("Z", "+00:00")
        when = datetime.fromisoformat(ts)
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
        return when.astimezone(timezone.utc)
    except ValueError:
        return None


def observe_start_from_tracking(tracking_path: Path) -> Optional[datetime]:
    text = tracking_path.read_text(encoding="utf-8")
    m = re.search(r"(?m)^\s*observe_start:\s*(.+)\s*$", text)
    if not m:
        return None
    return _parse_ts(m.group(1))


def is_dry_or_smoke(row: dict[str, Any]) -> bool:
    detail = str(row.get("detail") or "").lower()
    source = str(row.get("source") or "").lower()
    if source in ("dry", "smoke"):
        return True
    if "dry-run" in detail or detail.strip() == "dry-run":
        return True
    return False


def append_row(ledger_path: Path, row: dict[str, Any]) -> None:
    ledger_path.parent.mkdir(parents=True, exist_ok=True)
    with ledger_path.open("a", encoding="utf-8") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        try:
            f.write(json.dumps(row, separators=(",", ":")) + "\n")
            f.flush()
        finally:
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)


def filter_uname(rows: list[dict[str, Any]], uname_r: str) -> list[dict[str, Any]]:
    want = (uname_r or "").strip()
    if not want:
        return list(rows)
    return [r for r in rows if str(r.get("uname_r") or "") == want]


def load_rows(ledger_path: Path) -> list[dict[str, Any]]:
    if not ledger_path.is_file():
        return []
    rows: list[dict[str, Any]] = []
    bad = 0
    for line in ledger_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            bad += 1
    if bad:
        print(f"WARN: skipped {bad} corrupt ledger line(s)", file=sys.stderr)
    return rows


def _gate_eligible(row: dict[str, Any], *, require_gate_or_v03: bool) -> bool:
    if str(row.get("decision") or "").upper() == "SKIP":
        return False
    if is_dry_or_smoke(row):
        return False
    if require_gate_or_v03:
        mode = str(row.get("mode") or "")
        ver = str(row.get("suite_version") or "")
        if mode != "gate" and not ver.startswith("0.3"):
            return False
    return True


def confidence_level(
    *,
    ok: bool,
    login_passes: int,
    distinct_boots: int,
    calendar_days: float,
    hard_fails: int,
    prefer_passes: int,
    prefer_days: float,
    high_passes: int,
    high_days: float,
) -> dict[str, Any]:
    """Human-facing confidence for pre-unhold (soft floor ≠ high confidence).

    Confidence **shifts as ledger grows**. Enough independent soak data can raise
    confidence even on a short calendar; calendar days are an alternate path, not
    a hard wall when pass/boot counts are strong.

    low    — below soft floor, or FAIL in window
    medium — soft floor met + prefer evidence (passes/boots and/or days)
    high   — strong multi-boot soak evidence (data-first) or prefer+calendar
    """
    multi = distinct_boots >= 2
    # Data-first paths: volume of clean login soaks across boots
    data_high = login_passes >= high_passes and multi and not hard_fails
    data_medium = login_passes >= prefer_passes and multi and not hard_fails
    # Calendar-assisted paths (when reboots are fewer but days elapsed)
    cal_high = (
        login_passes >= prefer_passes
        and calendar_days >= high_days
        and multi
        and not hard_fails
    )
    cal_medium = (
        login_passes >= max(2, prefer_passes - 1)
        and calendar_days >= prefer_days
        and not hard_fails
        and ok
    )

    if hard_fails or not ok:
        level = "low"
        advice = "Do not pre-unhold — fix FAIL / reset observe_start / soak more"
        path = "blocked"
    elif data_high or cal_high:
        level = "high"
        path = "data" if data_high else "calendar"
        advice = (
            "High confidence — enough clean soak evidence; "
            "fresh --acceptance + checklist GO is reasonable"
        )
    elif data_medium or cal_medium:
        level = "medium"
        path = "data" if data_medium else "calendar"
        advice = (
            "Medium confidence — soak more toward high "
            f"(≥{high_passes} login PASS / ≥2 boots) or accept residual risk"
        )
    elif ok:
        level = "low"
        path = "soft_floor"
        advice = (
            "Soft floor only — keep soaking; confidence will rise as login "
            f"PASSes accumulate (medium ≥{prefer_passes} on ≥2 boots, "
            f"high ≥{high_passes} or ≥{prefer_passes} over ≥{high_days:.0f}d)"
        )
    else:
        level = "low"
        path = "below_floor"
        advice = "Below soft floor — continue login soak"

    return {
        "confidence": level,
        "confidence_path": path,
        "advice": advice,
        "prefer_passes": prefer_passes,
        "prefer_days": prefer_days,
        "high_passes": high_passes,
        "high_days": high_days,
    }


def summarize(
    rows: list[dict[str, Any]],
    *,
    since: Optional[datetime],
    min_runs: int,
    min_pass: int,
    min_source_login: int,
    min_calendar_days: int,
    prefer_passes: int = 3,
    prefer_days: float = 2.0,
    high_passes: int = 5,
    high_days: float = 3.0,
    require_gate_or_v03: bool = True,
    uname_r: str = "",
) -> dict[str, Any]:
    now = datetime.now(timezone.utc)
    filtered: list[dict[str, Any]] = []
    for r in filter_uname(rows, uname_r):
        if not _gate_eligible(r, require_gate_or_v03=require_gate_or_v03):
            continue
        stamp = _parse_ts(str(r.get("stamp") or ""))
        if since and stamp and stamp < since:
            continue
        if since and not stamp:
            continue
        filtered.append(r)

    passes = [
        r
        for r in filtered
        if str(r.get("decision") or "").upper() in ("PASS", "PROMOTE")
    ]
    fails = [r for r in filtered if str(r.get("decision") or "").upper() == "FAIL"]
    # Any FAIL in the observe window is hard for promote
    hard_fails = list(fails)
    boot_ids = {str(r.get("boot_id") or "") for r in filtered if r.get("boot_id")}
    boot_ids.discard("")
    login_rows = [
        r
        for r in filtered
        if str(r.get("source") or "") == "login"
        and str(r.get("decision") or "").upper() != "SKIP"
    ]
    login_passes = [
        r for r in login_rows if str(r.get("decision") or "").upper() == "PASS"
    ]

    calendar_ok = True
    days = 0.0
    if since:
        days = (now - since).total_seconds() / 86400.0
        calendar_ok = days >= float(min_calendar_days)

    reasons: list[str] = []
    if len(filtered) < min_runs:
        reasons.append(f"runs {len(filtered)} < min_runs {min_runs}")
    if len(passes) < min_pass:
        reasons.append(f"passes {len(passes)} < min_pass {min_pass}")
    if hard_fails:
        reasons.append(f"hard_FAIL_count={len(hard_fails)}")
    if len(filtered) >= min_runs and len(boot_ids) < min(3, min_runs):
        reasons.append(f"distinct_boot_ids {len(boot_ids)} too low for field soak")
    if min_source_login > 0 and len(login_passes) < min_source_login:
        reasons.append(
            f"login_PASS_rows {len(login_passes)} < min_source_login {min_source_login}"
        )
    if not calendar_ok:
        reasons.append(f"calendar_days {days:.1f} < min_calendar_days {min_calendar_days}")

    ok = not reasons
    last_fail = hard_fails[-1] if hard_fails else None
    conf = confidence_level(
        ok=ok,
        login_passes=len(login_passes),
        distinct_boots=len(boot_ids),
        calendar_days=days,
        hard_fails=len(hard_fails),
        prefer_passes=prefer_passes,
        prefer_days=prefer_days,
        high_passes=high_passes,
        high_days=high_days,
    )
    return {
        "ok": ok,
        "reasons": reasons,
        "runs": len(filtered),
        "passes": len(passes),
        "fails": len(fails),
        "hard_fails": len(hard_fails),
        "distinct_boot_ids": len(boot_ids),
        "login_rows": len(login_rows),
        "login_passes": len(login_passes),
        "calendar_days": round(days, 2) if since else None,
        "since": since.isoformat() if since else None,
        "last_fail": last_fail,
        **conf,
    }


def cmd_append(args: argparse.Namespace) -> int:
    row = {
        "stamp": args.stamp
        or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        "boot_id": args.boot_id or "",
        "uname_r": args.uname_r or "",
        "profile": args.profile or "",
        "mode": args.mode or "gate",
        "duration_s": args.duration_s,
        "decision": args.decision,
        "report_path": args.report_path or "",
        "samples_path": args.samples_path or "",
        "journal_hits": args.journal_hits,
        "packs_matched": json.loads(args.packs_matched) if args.packs_matched else [],
        "suite_version": args.suite_version or "0.3.0",
        "load_recipe": args.load_recipe or "",
        "source": args.source or "manual",
        "detail": args.detail or "",
    }
    append_row(Path(args.ledger), row)
    print(json.dumps({"appended": True, "ledger": args.ledger}, separators=(",", ":")))
    return 0


def count_campaign_runs(
    rows: list[dict[str, Any]],
    *,
    since: Optional[datetime],
    login_only: bool = True,
    uname_r: str = "",
) -> int:
    """Count non-SKIP non-dry gate rows since observe_start.

    Default login_only=True so acceptance/manual smokes do not consume the 7-run cap.
    """
    n = 0
    for r in filter_uname(rows, uname_r):
        if not _gate_eligible(r, require_gate_or_v03=True):
            continue
        if login_only and str(r.get("source") or "") != "login":
            continue
        stamp = _parse_ts(str(r.get("stamp") or ""))
        if since and stamp and stamp < since:
            continue
        if since and not stamp:
            continue
        n += 1
    return n


def local_day_key(when: Optional[datetime] = None) -> str:
    """Local calendar day for daily soak pacing (desktop observe)."""
    if when is None:
        when = datetime.now().astimezone()
    elif when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc).astimezone()
    else:
        when = when.astimezone()
    return when.strftime("%Y-%m-%d")


def login_completions_on_local_day(
    rows: list[dict[str, Any]],
    *,
    uname_r: str,
    day_key: str,
    since: Optional[datetime] = None,
) -> list[dict[str, Any]]:
    """Login Tier-D completions (PASS/FAIL/WARN) on a local calendar day, oldest first.

    SKIP / smoke / dry-run do not consume the daily slot.
    """
    out: list[dict[str, Any]] = []
    for r in filter_uname(rows, uname_r):
        if str(r.get("source") or "") != "login":
            continue
        if is_dry_or_smoke(r):
            continue
        dec = str(r.get("decision") or "").upper()
        if dec not in ("PASS", "FAIL", "WARN"):
            continue
        stamp = _parse_ts(str(r.get("stamp") or ""))
        if not stamp:
            continue
        if since and stamp < since:
            continue
        if local_day_key(stamp) != day_key:
            continue
        out.append(r)
    out.sort(key=lambda r: str(r.get("stamp") or ""))
    return out


def login_soaks_on_local_day(
    rows: list[dict[str, Any]],
    *,
    uname_r: str,
    day_key: str,
    since: Optional[datetime] = None,
) -> int:
    """Count login Tier-D completions (PASS/FAIL/WARN) on a local calendar day."""
    return len(
        login_completions_on_local_day(
            rows, uname_r=uname_r, day_key=day_key, since=since
        )
    )


def daily_cap_decision(
    rows: list[dict[str, Any]],
    *,
    uname_r: str,
    per_day: int,
    day_key: Optional[str] = None,
    since: Optional[datetime] = None,
) -> dict[str, Any]:
    """Whether another login soak may run today.

    Default: at most ``per_day`` completions/day. If the last completion today is
    FAIL and count == per_day, allow **one** same-day retry (max per_day+1).
    PASS/WARN consume the day with no retry. Does not reset observe_start.
    """
    day = day_key or local_day_key()
    if per_day <= 0:
        return {
            "allow": True,
            "reason": "daily_cap_disabled",
            "day": day,
            "count": 0,
            "per_day": per_day,
            "last_decision": None,
            "fail_retry": False,
        }
    comps = login_completions_on_local_day(
        rows, uname_r=uname_r, day_key=day, since=since
    )
    n = len(comps)
    last = str(comps[-1].get("decision") or "").upper() if comps else None
    if n < per_day:
        return {
            "allow": True,
            "reason": "under_daily_cap",
            "day": day,
            "count": n,
            "per_day": per_day,
            "last_decision": last,
            "fail_retry": False,
        }
    if n == per_day and last == "FAIL":
        return {
            "allow": True,
            "reason": "fail_retry",
            "day": day,
            "count": n,
            "per_day": per_day,
            "last_decision": last,
            "fail_retry": True,
        }
    return {
        "allow": False,
        "reason": "daily_cap",
        "day": day,
        "count": n,
        "per_day": per_day,
        "last_decision": last,
        "fail_retry": False,
    }


def _require_uname(args: argparse.Namespace) -> str:
    uname = (getattr(args, "uname_r", None) or "").strip()
    if not uname and not getattr(args, "allow_any_uname", False):
        print(
            "ERROR: --uname-r is required (refuse empty filter on promote/soak paths); "
            "pass --allow-any-uname only for intentional cross-ABI debug",
            file=sys.stderr,
        )
        sys.exit(2)
    return uname


def cmd_count(args: argparse.Namespace) -> int:
    uname = _require_uname(args)
    since = _parse_ts(args.since) if args.since else None
    if args.tracking and not since:
        since = observe_start_from_tracking(Path(args.tracking))
    rows = load_rows(Path(args.ledger))
    login_only = not args.all_sources
    n = count_campaign_runs(
        rows, since=since, login_only=login_only, uname_r=uname
    )
    print(
        json.dumps(
            {
                "count": n,
                "login_only": login_only,
                "uname_r": uname or None,
                "since": since.isoformat() if since else None,
            }
        )
    )
    return 0


def cmd_day_count(args: argparse.Namespace) -> int:
    uname = (args.uname_r or "").strip()
    if not uname:
        print("ERROR: --uname-r required", file=sys.stderr)
        return 2
    since = _parse_ts(args.since) if args.since else None
    if args.tracking and not since:
        since = observe_start_from_tracking(Path(args.tracking))
    day = (args.day or "").strip() or local_day_key()
    rows = load_rows(Path(args.ledger))
    n = login_soaks_on_local_day(
        rows, uname_r=uname, day_key=day, since=since
    )
    print(
        json.dumps(
            {
                "day": day,
                "count": n,
                "uname_r": uname,
                "since": since.isoformat() if since else None,
            }
        )
    )
    return 0


def cmd_daily_cap(args: argparse.Namespace) -> int:
    uname = (args.uname_r or "").strip()
    if not uname:
        print("ERROR: --uname-r required", file=sys.stderr)
        return 2
    since = _parse_ts(args.since) if args.since else None
    if args.tracking and not since:
        since = observe_start_from_tracking(Path(args.tracking))
    day = (args.day or "").strip() or local_day_key()
    decision = daily_cap_decision(
        load_rows(Path(args.ledger)),
        uname_r=uname,
        per_day=int(args.per_day),
        day_key=day,
        since=since,
    )
    decision["uname_r"] = uname
    decision["since"] = since.isoformat() if since else None
    print(json.dumps(decision))
    return 0 if decision.get("allow") else 1


def cmd_summarize(args: argparse.Namespace) -> int:
    uname = _require_uname(args)
    ledger = Path(args.ledger)
    rows = load_rows(ledger)
    since = _parse_ts(args.since) if args.since else None
    if args.tracking and not since:
        since = observe_start_from_tracking(Path(args.tracking))
    summary = summarize(
        rows,
        since=since,
        min_runs=args.min_runs,
        min_pass=args.min_pass,
        min_source_login=args.min_source_login,
        min_calendar_days=args.min_calendar_days,
        prefer_passes=args.prefer_passes,
        prefer_days=args.prefer_days,
        high_passes=args.high_passes,
        high_days=args.high_days,
        uname_r=uname,
    )
    summary["uname_r"] = uname or None
    print(json.dumps(summary, indent=2, default=str))
    # Exit 0 = soft floor met; confidence is advisory in JSON
    return 0 if summary["ok"] else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="known-good-kernel-check soak ledger")
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("append")
    a.add_argument("--ledger", required=True)
    a.add_argument("--stamp", default="")
    a.add_argument("--boot-id", default="")
    a.add_argument("--uname-r", default="")
    a.add_argument("--profile", default="")
    a.add_argument("--mode", default="gate")
    a.add_argument("--duration-s", type=int, default=0)
    a.add_argument("--decision", required=True)
    a.add_argument("--report-path", default="")
    a.add_argument("--samples-path", default="")
    a.add_argument("--journal-hits", type=int, default=0)
    a.add_argument("--packs-matched", default="")
    a.add_argument("--suite-version", default="0.4.0")
    a.add_argument("--load-recipe", default="")
    a.add_argument("--source", default="manual")
    a.add_argument("--detail", default="")
    a.set_defaults(func=cmd_append)

    s = sub.add_parser("summarize")
    s.add_argument("--ledger", required=True)
    s.add_argument("--since", default="")
    s.add_argument("--tracking", default="")
    s.add_argument("--uname-r", default="", help="Required lane filter (exact uname -r)")
    s.add_argument(
        "--allow-any-uname",
        action="store_true",
        help="Debug only: allow empty --uname-r (cross-ABI)",
    )
    s.add_argument("--min-runs", type=int, default=1)
    s.add_argument("--min-pass", type=int, default=1)
    s.add_argument("--min-source-login", type=int, default=1)
    s.add_argument("--min-calendar-days", type=int, default=1)
    s.add_argument("--prefer-passes", type=int, default=3)
    s.add_argument("--prefer-days", type=float, default=2.0)
    s.add_argument("--high-passes", type=int, default=5)
    s.add_argument("--high-days", type=float, default=3.0)
    s.set_defaults(func=cmd_summarize)

    c = sub.add_parser("count")
    c.add_argument("--ledger", required=True)
    c.add_argument("--since", default="")
    c.add_argument("--tracking", default="")
    c.add_argument("--uname-r", default="", help="Required lane filter (exact uname -r)")
    c.add_argument(
        "--allow-any-uname",
        action="store_true",
        help="Debug only: allow empty --uname-r (cross-ABI)",
    )
    c.add_argument(
        "--all-sources",
        action="store_true",
        help="Count login+acceptance+manual (default: login only)",
    )
    c.set_defaults(func=cmd_count)

    d = sub.add_parser(
        "day-count",
        help="Login soaks (PASS/FAIL/WARN) on a local calendar day for daily cap",
    )
    d.add_argument("--ledger", required=True)
    d.add_argument("--uname-r", required=True)
    d.add_argument("--day", default="", help="YYYY-MM-DD local (default: today)")
    d.add_argument("--tracking", default="")
    d.add_argument("--since", default="")
    d.set_defaults(func=cmd_day_count)

    dc = sub.add_parser(
        "daily-cap",
        help="Allow login soak today? (FAIL grants one same-day retry)",
    )
    dc.add_argument("--ledger", required=True)
    dc.add_argument("--uname-r", required=True)
    dc.add_argument("--per-day", type=int, default=1)
    dc.add_argument("--day", default="", help="YYYY-MM-DD local (default: today)")
    dc.add_argument("--tracking", default="")
    dc.add_argument("--since", default="")
    dc.set_defaults(func=cmd_daily_cap)

    args = ap.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
