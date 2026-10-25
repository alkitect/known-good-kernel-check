"""Soak mode resolution + wall-clock helpers (gate peak-rest / deep load cycles)."""
from __future__ import annotations

import os
from typing import Any, Optional


def session_ready() -> bool:
    return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))


def resolve_mode(soak_cfg: dict[str, Any], *, env: Optional[dict[str, str]] = None) -> str:
    env = env if env is not None else os.environ
    raw = (env.get("KCG_SOAK_MODE") or "").strip().lower()
    if raw in ("gate", "deep"):
        return raw
    mode = str(soak_cfg.get("mode") or "gate").strip().lower()
    if mode in ("gate", "deep"):
        return mode
    # Legacy profiles without mode: treat as gate if load cycles present, else deep-idle compat
    return "gate"


def _int(cfg: dict[str, Any], key: str, default: int) -> int:
    try:
        return int(cfg.get(key, default))
    except (TypeError, ValueError):
        return default


def gate_defaults(soak_cfg: dict[str, Any], *, smoke: bool = False) -> dict[str, int]:
    load = soak_cfg.get("load") or {}
    if smoke:
        return {
            "settle_seconds": 5,
            "gap_seconds": 2,
            "post_load_poll_seconds": 5,
            "cycles": 1,
            "window_seconds": 8,
        }
    return {
        "settle_seconds": _int(soak_cfg, "settle_seconds", 45),
        "gap_seconds": _int(soak_cfg, "gap_seconds", 20),
        "post_load_poll_seconds": _int(soak_cfg, "post_load_poll_seconds", 45),
        "cycles": max(1, _int(load, "cycles", 2)),
        "window_seconds": max(1, _int(load, "window_seconds", 90)),
    }


def deep_defaults(soak_cfg: dict[str, Any], *, smoke: bool = False) -> dict[str, int]:
    load = soak_cfg.get("load") or {}
    if smoke:
        return gate_defaults(soak_cfg, smoke=True)
    return {
        "settle_seconds": _int(soak_cfg, "settle_seconds", 60),
        "gap_seconds": _int(soak_cfg, "gap_seconds", 20),
        "post_load_poll_seconds": _int(soak_cfg, "post_load_poll_seconds", 60),
        "cycles": max(1, _int(load, "cycles", 6)),
        "window_seconds": max(1, _int(load, "window_seconds", 120)),
    }


def compute_wall_seconds(
    soak_cfg: dict[str, Any],
    *,
    mode: Optional[str] = None,
    smoke: bool = False,
) -> tuple[str, int, dict[str, int]]:
    """Return (mode, wall_seconds, timing_dict). Peak-rest: settle + N*(window+gap) - gap + post."""
    mode = mode or resolve_mode(soak_cfg)
    timing = deep_defaults(soak_cfg, smoke=smoke) if mode == "deep" else gate_defaults(
        soak_cfg, smoke=smoke
    )
    cycles = timing["cycles"]
    window = timing["window_seconds"]
    gap = timing["gap_seconds"]
    settle = timing["settle_seconds"]
    post = timing["post_load_poll_seconds"]
    # settle + cycles*window + (cycles-1)*gap + post
    wall = settle + cycles * window + max(0, cycles - 1) * gap + post
    return mode, wall, timing


def wall_for_profile_path(profile_path: str, *, smoke: bool = False) -> tuple[str, int]:
    import yaml
    from pathlib import Path

    profile = yaml.safe_load(Path(profile_path).read_text(encoding="utf-8")) or {}
    soak = profile.get("soak") or {}
    mode, wall, _ = compute_wall_seconds(soak, smoke=smoke)
    return mode, wall
