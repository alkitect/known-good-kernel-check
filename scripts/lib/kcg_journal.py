"""Shared journal signature pack loading + match helpers (no KCG_RESULT)."""
from __future__ import annotations

import re
import subprocess
from pathlib import Path
from typing import Any, Iterable, Optional


def _read_pattern_file(path: Path) -> list[str]:
    if not path.is_file():
        return []
    out: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        out.append(line)
    return out


def resolve_pack_paths(kcg_root: Path, profile: dict[str, Any]) -> list[Path]:
    """Return signature files from profile packs[] or type1_path fallback."""
    sig = profile.get("signatures") or {}
    packs = sig.get("packs") or []
    root = kcg_root
    paths: list[Path] = []
    if packs:
        for name in packs:
            name = str(name).strip()
            if not name:
                continue
            # allow "amdgpu-display-type1" or "packs/amdgpu-display-type1.txt"
            if name.endswith(".txt"):
                p = root / name if not name.startswith("/") else Path(name)
                if not p.is_file():
                    p = root / "signatures" / name
            else:
                p = root / "signatures" / "packs" / f"{name}.txt"
            if p.is_file():
                paths.append(p)
        if paths:
            return paths
    # Fallback: legacy single file
    rel = sig.get("type1_path") or "signatures/amdgpu-type1.txt"
    p = root / rel
    if p.is_file():
        return [p]
    return []


def load_patterns(paths: Iterable[Path]) -> list[str]:
    patterns: list[str] = []
    seen: set[str] = set()
    for path in paths:
        for pat in _read_pattern_file(Path(path)):
            if pat not in seen:
                seen.add(pat)
                patterns.append(pat)
    return patterns


def patterns_from_profile(kcg_root: Path, profile: dict[str, Any]) -> list[str]:
    return load_patterns(resolve_pack_paths(kcg_root, profile))


def compile_regex(patterns: list[str]) -> Optional[re.Pattern[str]]:
    if not patterns:
        return None
    return re.compile("|".join(patterns), re.IGNORECASE)


def journalctl_kernel(
    *,
    since: Optional[str] = None,
    boot: str = "0",
) -> str:
    cmd = ["journalctl", "-k", "-b", boot, "--no-pager"]
    if since:
        cmd.extend(["--since", since])
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def find_hits(log: str, patterns: list[str]) -> list[str]:
    rx = compile_regex(patterns)
    if not rx or not log:
        return []
    return rx.findall(log)


def hits_summary(hits: list[str], limit: int = 8) -> str:
    return ", ".join(sorted(set(hits))[:limit])
