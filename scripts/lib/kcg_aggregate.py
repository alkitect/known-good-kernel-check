#!/usr/bin/env python3
"""Aggregate KCG_RESULT lines into suite decision + JSON/Markdown reports."""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def load_profile(path: Path) -> dict:
    import yaml

    with path.open(encoding="utf-8") as f:
        return yaml.safe_load(f)


def profile_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()[:16]


def decide(checks: list[dict], hold_on_any_warn: bool) -> tuple[str, int]:
    results = [c.get("result", "fail") for c in checks]
    if any(r == "fail" for r in results):
        return "REJECT", 2
    if hold_on_any_warn and any(r == "warn" for r in results):
        return "HOLD", 1
    return "PROMOTE", 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", required=True)
    ap.add_argument("--baseline", default="")
    ap.add_argument("--preflight-id", default="")
    ap.add_argument("--results-file", required=True, help="File with KCG_RESULT lines")
    ap.add_argument("--out-json", required=True)
    ap.add_argument("--out-md", required=True)
    ap.add_argument("--uname", required=True)
    args = ap.parse_args()

    profile_path = Path(args.profile)
    profile = load_profile(profile_path)
    ph = profile_hash(profile_path)

    checks: list[dict] = []
    for line in Path(args.results_file).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line.startswith("KCG_RESULT "):
            continue
        checks.append(json.loads(line[len("KCG_RESULT ") :]))

    hold = bool(profile.get("hold_on_any_warn", True))
    decision, exit_code = decide(checks, hold)

    report = {
        "schema_version": "1.0",
        "suite_version": "0.4.0",
        "decision": decision,
        "exit_code": exit_code,
        "uname": args.uname,
        "profile_id": profile.get("profile_id", ""),
        "profile_path": str(profile_path),
        "profile_hash": ph,
        "baseline_id": Path(args.baseline).name if args.baseline else "",
        "preflight_snapshot_id": args.preflight_id,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "checks": checks,
    }

    out_json = Path(args.out_json)
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    lines = [
        f"# Known-good kernel check — {decision}",
        "",
        f"- **decision:** {decision} (exit {exit_code})",
        f"- **uname:** {args.uname}",
        f"- **profile:** {profile.get('profile_id')} (`{ph}`)",
        f"- **baseline:** {report['baseline_id'] or '(none)'}",
        f"- **preflight:** {args.preflight_id or '(none)'}",
        "",
        "| id | tier | result | detail |",
        "|----|------|--------|--------|",
    ]
    for c in checks:
        detail = (c.get("detail") or "").replace("|", "\\|")
        lines.append(
            f"| {c.get('id','')} | {c.get('tier','')} | {c.get('result','')} | {detail} |"
        )
    lines.append("")
    Path(args.out_md).write_text("\n".join(lines), encoding="utf-8")

    print(decision)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
