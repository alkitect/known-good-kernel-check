#!/usr/bin/env python3
"""Resolve or bootstrap a per-uname campaign lane under campaigns/<uname>/."""
from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML required (python3-yaml)", file=sys.stderr)
    sys.exit(2)

_OBSERVE_RE = re.compile(r"(?m)^\s*observe_start:\s*(.+)\s*$")


def _parse_observe(raw: str) -> Optional[str]:
    raw = raw.strip().strip('"').strip("'")
    if not raw:
        return None
    # Accept compact or ISO; must be non-empty parseable-looking
    if len(raw) < 8:
        return None
    return raw


def observe_start_raw(tracking: Path) -> Optional[str]:
    if not tracking.is_file():
        return None
    m = _OBSERVE_RE.search(tracking.read_text(encoding="utf-8"))
    if not m:
        return None
    return _parse_observe(m.group(1))


def lane_valid(lane: Path) -> bool:
    return observe_start_raw(lane / "tracking.md") is not None


def default_template(kcg_root: Path) -> Path:
    env = os.environ.get("KCG_LANE_TEMPLATE", "").strip()
    if env:
        return Path(env)
    # Prefer generic example. Topic wrappers pass an explicit --template host profile.
    generic = kcg_root / "profile" / "example-generic.yaml.example"
    if generic.is_file():
        return generic
    raise FileNotFoundError(
        "no lane template — set KCG_LANE_TEMPLATE or pass --template"
    )


def _rewrite_profile(src: Path, dest: Path, uname: str) -> None:
    data: dict[str, Any] = yaml.safe_load(src.read_text(encoding="utf-8")) or {}
    safe_id = "lane-" + re.sub(r"[^A-Za-z0-9._-]+", "-", uname)
    data["profile_id"] = safe_id
    data["kernel_version"] = uname
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(
        yaml.safe_dump(data, default_flow_style=False, sort_keys=False),
        encoding="utf-8",
    )


def _tracking_bootstrap(uname: str, observe_start: str) -> str:
    return f"""# Campaign lane tracking ({uname})

Paths under this lane directory unless absolute.

## Campaign lock

```yaml
campaign_id: "{observe_start[:10]}-{uname}"
status: observing
candidate_abi: "{uname}"
opened_at: "{observe_start}"
single_writer: true
lock_note: "Boot-selected lane; suite resumes on this uname."
```

## Observe window

```yaml
observe_start: "{observe_start}"
observe_end: ""
incidents: []
login_soak_enabled: no
```

## Hold review

```yaml
hold_reviewed: no
```
"""


def bootstrap_lane(kcg_root: Path, uname: str, template: Path) -> Path:
    lane = kcg_root / "campaigns" / uname
    if lane.exists() and any(lane.iterdir()):
        if lane_valid(lane):
            return lane
        print(
            f"ERROR: incomplete lane {lane} (missing parseable observe_start) — "
            "fail-closed (do not bootstrap over it)",
            file=sys.stderr,
        )
        sys.exit(2)

    staging = kcg_root / "campaigns" / f".staging-{uname}"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    (staging / "baselines").mkdir()
    _rewrite_profile(template, staging / "profile.yaml", uname)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    # Write tracking last so resume predicate is atomic with rename
    (staging / "tracking.md").write_text(
        _tracking_bootstrap(uname, now), encoding="utf-8"
    )
    lane.parent.mkdir(parents=True, exist_ok=True)
    staging.rename(lane)
    return lane


def resolve(
    kcg_root: Path,
    *,
    uname: Optional[str] = None,
    template: Optional[Path] = None,
    bootstrap: bool = True,
) -> dict[str, str]:
    """Return env map for the active lane. Honors existing KCG_PROFILE override."""
    uname = uname or os.uname().release
    profile_override = os.environ.get("KCG_PROFILE", "").strip()
    if profile_override:
        if not Path(profile_override).is_file():
            print(f"ERROR: KCG_PROFILE not found: {profile_override}", file=sys.stderr)
            sys.exit(2)
        # Override: no lane rewrite. Still expose lane paths if valid for tracking/baselines.
        out = {
            "KCG_PROFILE": profile_override,
            "KCG_UNAME": uname,
        }
        lane = kcg_root / "campaigns" / uname
        if lane_valid(lane):
            out.setdefault(
                "KCG_BASELINES",
                os.environ.get("KCG_BASELINES") or str(lane / "baselines"),
            )
            out.setdefault(
                "KCG_CAMPAIGN_TRACKING",
                os.environ.get("KCG_CAMPAIGN_TRACKING") or str(lane / "tracking.md"),
            )
        return out

    lane = kcg_root / "campaigns" / uname
    if lane.exists():
        if not lane_valid(lane):
            print(
                f"ERROR: incomplete lane {lane} — fix tracking.md observe_start "
                "or remove the dir before bootstrap",
                file=sys.stderr,
            )
            sys.exit(2)
    elif bootstrap:
        tpl = template or default_template(kcg_root)
        if not tpl.is_file():
            print(f"ERROR: lane template missing: {tpl}", file=sys.stderr)
            sys.exit(2)
        lane = bootstrap_lane(kcg_root, uname, tpl)
    else:
        print(f"ERROR: no campaign lane for {uname}", file=sys.stderr)
        sys.exit(2)

    profile = lane / "profile.yaml"
    if not profile.is_file():
        print(f"ERROR: lane missing profile.yaml: {lane}", file=sys.stderr)
        sys.exit(2)

    return {
        "KCG_PROFILE": str(profile.resolve()),
        "KCG_BASELINES": str((lane / "baselines").resolve()),
        "KCG_CAMPAIGN_TRACKING": str((lane / "tracking.md").resolve()),
        "KCG_UNAME": uname,
        "KCG_LANE_DIR": str(lane.resolve()),
    }


def emit_exports(env: dict[str, str]) -> None:
    for k, v in env.items():
        # shell-safe single-quoted
        esc = v.replace("'", "'\"'\"'")
        print(f"export {k}='{esc}'")


def main() -> int:
    ap = argparse.ArgumentParser(description="kcg multi-lane resolver")
    ap.add_argument("--root", default="", help="KCG_ROOT (default: env or cwd)")
    ap.add_argument("--uname", default="", help="Override uname -r")
    ap.add_argument("--template", default="", help="Bootstrap template YAML")
    ap.add_argument(
        "--no-bootstrap",
        action="store_true",
        help="Fail if lane missing (no create)",
    )
    ap.add_argument(
        "--exports",
        action="store_true",
        help="Print bash export lines",
    )
    ap.add_argument(
        "--json",
        action="store_true",
        help="Print JSON env map",
    )
    args = ap.parse_args()
    root = Path(args.root or os.environ.get("KCG_ROOT") or Path.cwd())
    tpl = Path(args.template) if args.template else None
    env = resolve(
        root,
        uname=args.uname or None,
        template=tpl,
        bootstrap=not args.no_bootstrap,
    )
    if args.exports:
        emit_exports(env)
    elif args.json:
        import json

        print(json.dumps(env, indent=2))
    else:
        for k, v in env.items():
            print(f"{k}={v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
