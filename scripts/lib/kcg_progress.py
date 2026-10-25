#!/usr/bin/env python3
"""Progress / ETA helper for known-good-kernel-check.

Stdlib only. All human-visible progress goes to stderr.
Never emits KCG_RESULT (stdout is reserved for check result lines).
"""
from __future__ import annotations

import argparse
import os
import sys
from typing import Optional

# Static priors (seconds) — approximate; soak DUR dominates acceptance.
PRIOR_INVENTORY = 10
PRIOR_BIND = 8
PRIOR_TYPE1 = 7
PRIOR_WIFI_BT = 10
PRIOR_PLUGIN = 15  # per plugin; ollama cold-start may exceed
PRIOR_AGGREGATE = 2

_VALID_MODES = frozenset({"auto", "tty", "plain", "off"})


def resolve_mode(explicit: Optional[str] = None) -> str:
    """Return effective mode: tty | plain | off."""
    raw = (explicit or os.environ.get("KCG_PROGRESS") or "auto").strip().lower()
    if raw not in _VALID_MODES:
        raw = "auto"
    if raw == "off":
        return "off"
    if raw == "tty":
        return "tty"
    if raw == "plain":
        return "plain"
    # auto
    return "tty" if sys.stderr.isatty() else "plain"


def format_duration(seconds: float) -> str:
    s = max(0, int(round(seconds)))
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    if h:
        return f"{h}h{m:02d}m{sec:02d}s"
    if m:
        return f"{m}m{sec:02d}s"
    return f"{sec}s"


def format_mmss(seconds: float) -> str:
    s = max(0, int(round(seconds)))
    m, sec = divmod(s, 60)
    if m >= 60:
        h, m = divmod(m, 60)
        return f"{h}:{m:02d}:{sec:02d}"
    return f"{m:02d}:{sec:02d}"


def _bar(frac: float, width: int = 12) -> str:
    frac = max(0.0, min(1.0, frac))
    filled = int(round(frac * width))
    return "█" * filled + "░" * (width - filled)


def _emit(msg: str, *, mode: Optional[str] = None, newline: bool = True) -> None:
    m = resolve_mode(mode)
    if m == "off":
        return
    end = "\n" if newline else ""
    if m == "tty" and not newline:
        sys.stderr.write("\r" + msg + " " * 8)
        sys.stderr.flush()
        return
    if m == "tty" and newline:
        # Clear any leftover \r line before a newline message
        sys.stderr.write("\r\033[K")
    sys.stderr.write(msg + end)
    sys.stderr.flush()


def short_tier_priors(plugin_count: int) -> int:
    return (
        PRIOR_INVENTORY
        + PRIOR_BIND
        + PRIOR_TYPE1
        + PRIOR_WIFI_BT
        + max(0, plugin_count) * PRIOR_PLUGIN
        + PRIOR_AGGREGATE
    )


def count_suite_steps(plugin_count: int, skip_soak: bool = False) -> int:
    """inventory + bind + type1 + wifi-bt + plugins + soak (+skip) + aggregate.

    skip_soak only affects ETA DUR in suite_start; the soak step still runs
    (tier-d-soak emits result=skip).
    """
    del skip_soak  # reserved for callers; step always present
    return 4 + max(0, plugin_count) + 1 + 1


def suite_start(
    *,
    soak_seconds: int,
    plugin_count: int = 0,
    skip_soak: bool = False,
    mode: Optional[str] = None,
) -> None:
    soak = 0 if skip_soak else max(0, int(soak_seconds))
    total_steps = count_suite_steps(plugin_count, skip_soak)
    short = short_tier_priors(plugin_count)
    total = short + soak
    m = resolve_mode(mode)
    if m == "off":
        return

    if soak >= short * 2 and soak > 0:
        dominance = f"soak {format_duration(soak)} dominates; short tiers ~{format_duration(short)}"
    elif soak == 0:
        dominance = f"soak skipped; short tiers ~{format_duration(short)}"
    else:
        dominance = f"soak {format_duration(soak)} + short tiers ~{format_duration(short)}"

    _emit(f"ETA ~{format_duration(total)} ({dominance})", mode=mode)
    _emit(f"total {_bar(0.0)}  0/{total_steps} steps", mode=mode)


def phase_begin(phase: str, *, mode: Optional[str] = None) -> None:
    _emit(f"[phase {phase}] …", mode=mode)


def phase_end(phase: str, *, mode: Optional[str] = None) -> None:
    _emit(f"[phase {phase}] done", mode=mode)


def step_begin(phase: str, step_id: str, *, mode: Optional[str] = None) -> None:
    _emit(f"[phase {phase}] {step_id} …", mode=mode)


def step_end(
    phase: str,
    step_id: str,
    *,
    mode: Optional[str] = None,
    result_hint: str = "",
    elapsed_seconds: Optional[float] = None,
    done: Optional[int] = None,
    total: Optional[int] = None,
) -> None:
    elapsed_s = float(elapsed_seconds) if elapsed_seconds is not None else 0.0
    hint = f" {result_hint}" if result_hint else ""
    msg = f"[phase {phase}] {step_id} … done ({format_duration(elapsed_s)}){hint}"
    _emit(msg, mode=mode)
    if done is not None and total is not None and total > 0:
        frac = min(1.0, max(0.0, done / total))
        _emit(f"total {_bar(frac)}  {done}/{total} steps", mode=mode)


def soak_tick(
    elapsed: float,
    duration: float,
    *,
    mode: Optional[str] = None,
    final: bool = False,
) -> None:
    m = resolve_mode(mode)
    if m == "off":
        return
    duration = max(0.0, float(duration))
    elapsed = max(0.0, min(float(elapsed), duration if duration else float(elapsed)))
    remaining = max(0.0, duration - elapsed)
    pct = (100.0 * elapsed / duration) if duration > 0 else 100.0
    frac = (elapsed / duration) if duration > 0 else 1.0
    line = (
        f"[phase D] soak  {_bar(frac)}  "
        f"{format_mmss(elapsed)} / {format_mmss(duration)}  "
        f"{pct:5.1f}%  ETA {format_mmss(remaining)} remaining"
    )
    if m == "tty" and not final:
        _emit(line, mode=mode, newline=False)
    else:
        _emit(line, mode=mode, newline=True)


def suite_done(
    decision: str = "",
    exit_code: Optional[int] = None,
    *,
    mode: Optional[str] = None,
) -> None:
    m = resolve_mode(mode)
    if m == "off":
        return
    if m == "tty":
        sys.stderr.write("\r\033[K")
        sys.stderr.flush()
    parts = []
    if decision:
        parts.append(f"decision={decision}")
    if exit_code is not None:
        parts.append(f"exit={exit_code}")
    if parts:
        _emit("[suite] " + " ".join(parts), mode=mode)


def _cmd_suite_start(args: argparse.Namespace) -> int:
    suite_start(
        soak_seconds=args.soak_seconds,
        plugin_count=args.plugin_count,
        skip_soak=args.skip_soak,
        mode=args.mode,
    )
    return 0


def _cmd_phase_begin(args: argparse.Namespace) -> int:
    phase_begin(args.phase, mode=args.mode)
    return 0


def _cmd_phase_end(args: argparse.Namespace) -> int:
    phase_end(args.phase, mode=args.mode)
    return 0


def _cmd_step_begin(args: argparse.Namespace) -> int:
    step_begin(args.phase, args.id, mode=args.mode)
    return 0


def _cmd_step_end(args: argparse.Namespace) -> int:
    step_end(
        args.phase,
        args.id,
        mode=args.mode,
        result_hint=args.hint or "",
        elapsed_seconds=args.elapsed,
        done=args.done,
        total=args.total,
    )
    return 0


def _cmd_soak_tick(args: argparse.Namespace) -> int:
    soak_tick(args.elapsed, args.duration, mode=args.mode, final=args.final)
    return 0


def _cmd_suite_done(args: argparse.Namespace) -> int:
    suite_done(args.decision or "", args.exit_code, mode=args.mode)
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="kcg_progress",
        description="known-good-kernel-check progress helper (stderr only; never KCG_RESULT)",
    )
    p.add_argument(
        "--mode",
        default=None,
        help="Override KCG_PROGRESS for this call (auto|tty|plain|off)",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("suite-start", help="Print ETA banner")
    s.add_argument("--soak-seconds", type=int, required=True)
    s.add_argument("--plugin-count", type=int, default=0)
    s.add_argument("--skip-soak", action="store_true")
    s.set_defaults(func=_cmd_suite_start)

    s = sub.add_parser("phase-begin")
    s.add_argument("--phase", required=True)
    s.set_defaults(func=_cmd_phase_begin)

    s = sub.add_parser("phase-end")
    s.add_argument("--phase", required=True)
    s.set_defaults(func=_cmd_phase_end)

    s = sub.add_parser("step-begin")
    s.add_argument("--phase", required=True)
    s.add_argument("--id", required=True)
    s.set_defaults(func=_cmd_step_begin)

    s = sub.add_parser("step-end")
    s.add_argument("--phase", required=True)
    s.add_argument("--id", required=True)
    s.add_argument("--hint", default="")
    s.add_argument("--elapsed", type=float, default=0.0, help="Wall seconds for this step")
    s.add_argument("--done", type=int, default=None, help="Steps completed so far")
    s.add_argument("--total", type=int, default=None, help="Total suite steps")
    s.set_defaults(func=_cmd_step_end)

    s = sub.add_parser("soak-tick")
    s.add_argument("--elapsed", type=float, required=True)
    s.add_argument("--duration", type=float, required=True)
    s.add_argument("--final", action="store_true")
    s.set_defaults(func=_cmd_soak_tick)

    s = sub.add_parser("suite-done")
    s.add_argument("--decision", default="")
    s.add_argument("--exit-code", type=int, default=None)
    s.set_defaults(func=_cmd_suite_done)

    return p


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
