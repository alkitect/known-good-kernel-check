#!/usr/bin/env bash
# Tier D: gate (peak-rest load cycles) or deep (longer load cycles). Idle≠soak.
# Env: KCG_SOAK_MODE=gate|deep, KCG_SOAK_SECONDS (optional wall override),
#      KCG_SOAK_SMOKE=1 (shortened), KCG_SKIP_SOAK=1,
#      KCG_EVIDENCE (samples JSONL), KCG_SOAK_SOURCE=login|acceptance|manual
# Progress heartbeats → stderr via kcg_progress (never on stdout / KCG_RESULT).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KCG_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROFILE="${1:?profile}"
LIB_DIR="${KCG_ROOT}/scripts/lib"
EVIDENCE="${KCG_EVIDENCE:-${KCG_ROOT}/evidence}"

if [[ "${KCG_SKIP_SOAK:-0}" == "1" ]]; then
  python3 -c 'import json; print("KCG_RESULT "+json.dumps({"id":"soak","tier":"D","result":"skip","detail":"KCG_SKIP_SOAK=1","source":"builtin"},separators=(",",":")))'
  exit 0
fi

export KCG_EVIDENCE="${EVIDENCE}"
mkdir -p "${EVIDENCE}"

python3 - "${KCG_ROOT}" "${PROFILE}" "${LIB_DIR}" <<'PY'
import json, os, shutil, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path

kcg_root = Path(sys.argv[1])
profile_path = Path(sys.argv[2])
lib_dir = Path(sys.argv[3])
sys.path.insert(0, str(lib_dir))

import yaml  # noqa: E402
from kcg_journal import (  # noqa: E402
    find_hits,
    hits_summary,
    journalctl_kernel,
    load_patterns,
    patterns_from_profile,
)
from kcg_progress import soak_tick  # noqa: E402
from kcg_soak import (  # noqa: E402
    compute_wall_seconds,
    resolve_mode,
    session_ready,
)

profile = yaml.safe_load(profile_path.read_text(encoding="utf-8")) or {}
soak_cfg = profile.get("soak") or {}
load_cfg = soak_cfg.get("load") or {}
samples_cfg = soak_cfg.get("samples") or {}
patterns_all = patterns_from_profile(kcg_root, profile)

fail_pack_names = load_cfg.get("fail_on_signature_packs") or []
if fail_pack_names:
    pack_paths = []
    for name in fail_pack_names:
        name = str(name).strip()
        p = kcg_root / "signatures" / "packs" / f"{name}.txt"
        if not p.is_file() and name.endswith(".txt"):
            p = kcg_root / "signatures" / "packs" / Path(name).name
        if p.is_file():
            pack_paths.append(p)
    patterns_load = load_patterns(pack_paths) if pack_paths else patterns_all
else:
    patterns_load = patterns_all

smoke = os.environ.get("KCG_SOAK_SMOKE", "0") == "1"
mode, wall_computed, timing = compute_wall_seconds(soak_cfg, smoke=smoke)
# Optional override wall (acceptance smoke / debug) — still runs gate/deep phases
if os.environ.get("KCG_SOAK_SECONDS"):
    try:
        wall = max(1, int(os.environ["KCG_SOAK_SECONDS"]))
    except ValueError:
        wall = wall_computed
else:
    wall = wall_computed

evidence = Path(os.environ.get("KCG_EVIDENCE") or (kcg_root / "evidence"))
evidence.mkdir(parents=True, exist_ok=True)
stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
samples_enabled = bool(samples_cfg.get("enabled", False))
samples_path = evidence / f"soak-samples-{stamp}.jsonl" if samples_enabled else None
sample_interval = max(5, int(samples_cfg.get("interval_seconds") or 30))
source = os.environ.get("KCG_SOAK_SOURCE") or "manual"
load_recipe_used = ""
load_ran = False
journal_hit_total = 0
packs_matched: list[str] = []


def emit(cid, result, detail, **extra):
    obj = {
        "id": cid,
        "tier": "D",
        "result": result,
        "detail": detail,
        "source": "builtin",
        "soak_mode": mode,
        "soak_wall_s": wall,
    }
    obj.update(extra)
    print("KCG_RESULT " + json.dumps(obj, separators=(",", ":")))


def journal_hits(patterns, since_s: int):
    log = journalctl_kernel(since=f"{since_s} seconds ago")
    return find_hits(log, patterns)


def sample(phase: str, load_alive: bool = False, hits: int = 0):
    if not samples_path:
        return
    line = {
        "t": datetime.now(timezone.utc).isoformat(),
        "phase": phase,
        "journal_hits": hits,
        "load_alive": load_alive,
        "mode": mode,
    }
    with samples_path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(line, separators=(",", ":")) + "\n")


# Visible title after wmctrl rename (mesa glxgears has no --title)
KCG_LOAD_TITLE = "KCG kernel soak — GPU load"


def tame_load_window(bin_name: str) -> None:
    """Rename + hide/minimize load window when wmctrl/xdotool available (X11/XWayland)."""
    time.sleep(0.5)
    if shutil.which("wmctrl"):
        # Match default window names from mesa demos
        for old in (bin_name, "glxgears", "vkcube", "cube"):
            subprocess.run(
                ["wmctrl", "-r", old, "-N", KCG_LOAD_TITLE],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        # Prefer hide; fall back to iconify (minimize)
        for action in (
            ["wmctrl", "-r", KCG_LOAD_TITLE, "-b", "add,hidden"],
            ["wmctrl", "-r", KCG_LOAD_TITLE, "-b", "add,below"],
        ):
            subprocess.run(
                action,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        return
    if shutil.which("xdotool"):
        subprocess.run(
            [
                "xdotool",
                "search",
                "--name",
                bin_name,
                "set_window",
                "--name",
                KCG_LOAD_TITLE,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        subprocess.run(
            ["xdotool", "search", "--name", KCG_LOAD_TITLE, "windowminimize"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )


def pick_load_cmd(recipe: str):
    recipe = (recipe or "auto").lower()
    candidates = []
    if recipe in ("auto", "glxgears") and shutil.which("glxgears"):
        # Tiny corner window — glxgears has no minimize/title flags; wmctrl tames it after start
        candidates.append(["glxgears", "-geometry", "64x64+8+8"])
    if recipe in ("auto", "vkcube") and shutil.which("vkcube"):
        candidates.append(["vkcube"])
    if recipe in ("auto", "mpv_smoke"):
        for bin_name in ("mpv", "ffplay"):
            if shutil.which(bin_name):
                if bin_name == "mpv":
                    candidates.append(
                        [
                            "mpv",
                            "--ao=null",
                            "--vo=null",
                            "--length=5",
                            "--quiet",
                            "av://lavfi:color=c=black:s=64x64:d=5",
                        ]
                    )
                else:
                    candidates.append(
                        [
                            "ffplay",
                            "-autoexit",
                            "-nodisp",
                            "-t",
                            "5",
                            "-f",
                            "lavfi",
                            "color=c=black:s=64x64:d=5",
                        ]
                    )
                break
    if recipe == "none":
        return None, "recipe=none"
    if not candidates:
        return None, "no load binary (glxgears/vkcube/mpv/ffplay)"
    return candidates[0], "ok"


def poll_journal(patterns, window_s: int, phase: str) -> list:
    global journal_hit_total
    t0 = time.time()
    deadline = t0 + max(1, window_s)
    interval = min(sample_interval, max(1, window_s // 3 or 1))
    while time.time() < deadline:
        hits = journal_hits(patterns, window_s + 60) if patterns else []
        sample(phase, hits=len(hits))
        if hits:
            journal_hit_total += len(hits)
            return hits
        elapsed = time.time() - t0
        soak_tick(elapsed + phase_offset, float(wall))
        remaining = deadline - time.time()
        if remaining <= 0:
            break
        time.sleep(min(interval, remaining))
    return []


def run_load_window(window_s: int, patterns) -> tuple[bool, str, list]:
    global load_recipe_used, load_ran
    recipe = str(load_cfg.get("recipe") or "auto")
    cmd, why = pick_load_cmd(recipe)
    missing_policy = str(load_cfg.get("missing") or "fail").lower()
    if cmd is None:
        if recipe == "none" or not load_cfg.get("enabled", True):
            emit("soak-load", "skip", why)
            return True, why, []
        if missing_policy == "fail":
            emit("soak-load", "fail", why)
            return False, why, []
        emit("soak-load", "warn", why)
        return True, why, []

    load_recipe_used = cmd[0]
    load_ran = True
    print(
        f"[phase D] soak-load start recipe={cmd[0]} window={window_s}s mode={mode}",
        file=sys.stderr,
        flush=True,
    )
    t0 = time.time()
    proc = None
    try:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        if cmd[0] in ("glxgears", "vkcube"):
            try:
                tame_load_window(cmd[0])
            except Exception as e:  # noqa: BLE001 — best-effort UX only
                print(f"[phase D] soak-load window tame skipped: {e}", file=sys.stderr)
        deadline = t0 + max(1, window_s)
        while time.time() < deadline:
            alive = proc.poll() is None
            hits = journal_hits(patterns, window_s + 30)
            sample("load", load_alive=alive, hits=len(hits))
            if hits:
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                return False, f"signature during load: {hits_summary(hits)}", hits
            elapsed = time.time() - t0
            soak_tick(elapsed + phase_offset, float(wall))
            time.sleep(min(5, max(0.5, deadline - time.time())))
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        emit("soak-load", "pass", f"ran {cmd[0]} ~{window_s}s without pack hits")
        return True, "ok", []
    except OSError as e:
        if proc and proc.poll() is None:
            proc.kill()
        if missing_policy == "fail":
            emit("soak-load", "fail", f"load spawn failed: {e}")
            return False, str(e), []
        emit("soak-load", "warn", f"load spawn failed: {e}")
        return True, str(e), []


def finish(result: str, detail: str):
    soak_tick(float(wall), float(wall), final=True)
    extra = {
        "soak_mode": mode,
        "load_recipe": load_recipe_used or str(load_cfg.get("recipe") or "auto"),
        "load_ran": load_ran,
        "samples_path": str(samples_path) if samples_path and samples_path.is_file() else "",
        "journal_hits": journal_hit_total,
        "source": source,
    }
    # Persist sidecar for login runner / ledger
    meta = {
        "stamp": stamp,
        "mode": mode,
        "duration_s": wall,
        "decision": result.upper() if result in ("pass", "fail", "warn", "skip") else result,
        "result": result,
        "detail": detail,
        "samples_path": extra["samples_path"],
        "journal_hits": journal_hit_total,
        "packs_matched": packs_matched,
        "load_recipe": extra["load_recipe"],
        "load_ran": load_ran,
        "source": source,
        "suite_hint": "0.3.0",
    }
    meta_path = evidence / f"soak-meta-{stamp}.json"
    meta_path.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    emit("soak", result, detail, **extra, meta_path=str(meta_path))
    sys.exit(0)


# --- peak-rest / deep load-cycle soak ---
phase_offset = 0.0
start = time.time()
soak_tick(0.0, float(wall))

settle = timing["settle_seconds"]
gap = timing["gap_seconds"]
post = timing["post_load_poll_seconds"]
cycles = timing["cycles"]
window_s = timing["window_seconds"]
load_enabled = bool(load_cfg.get("enabled", True))

print(
    f"[phase D] mode={mode} wall~{wall}s settle={settle} cycles={cycles}x{window_s}s "
    f"gap={gap} post={post} smoke={int(smoke)}",
    file=sys.stderr,
    flush=True,
)

# Settle journal poll
hits = poll_journal(patterns_all, settle, "settle")
if hits:
    packs_matched = [hits_summary(hits)]
    finish("fail", f"signature during settle: {hits_summary(hits)}")
phase_offset = float(settle)

if load_enabled:
    if not session_ready():
        # Do not hard-FAIL observe clock on headless / pre-GUI
        emit(
            "soak-session",
            "warn",
            "DISPLAY/WAYLAND_DISPLAY unset — skipping load cycles (session not ready)",
        )
        hits = poll_journal(patterns_all, max(post, 15), "post-no-session")
        if hits:
            packs_matched = [hits_summary(hits)]
            finish("fail", f"signature after session-skip: {hits_summary(hits)}")
        finish(
            "warn",
            f"completed {mode} soak without load (session not ready); journal clean",
        )
    else:
        for i in range(cycles):
            ok, detail, hits = run_load_window(window_s, patterns_load)
            phase_offset += float(window_s)
            if not ok:
                packs_matched = [hits_summary(hits)] if hits else [detail]
                finish("fail", detail)
            if i < cycles - 1 and gap > 0:
                hits = poll_journal(patterns_all, gap, f"gap-{i+1}")
                phase_offset += float(gap)
                if hits:
                    packs_matched = [hits_summary(hits)]
                    finish("fail", f"signature during gap: {hits_summary(hits)}")
else:
    # load disabled: short journal-only post (still not long idle-as-data)
    emit("soak-load", "skip", "load.enabled=false")

hits = poll_journal(patterns_all, post, "post")
if hits:
    packs_matched = [hits_summary(hits)]
    finish("fail", f"signature during post-load poll: {hits_summary(hits)}")

elapsed = time.time() - start
# Soft assert for smoke: load should have run when session ready + enabled
if smoke and load_enabled and session_ready() and not load_ran:
    finish("fail", "KCG_SOAK_SMOKE: expected load to run")

detail = (
    f"completed {mode} soak ~{int(elapsed)}s "
    f"(settle/load×{cycles}/post) without signature-pack hits"
)
if samples_path and samples_path.is_file():
    detail += f"; samples={samples_path.name}"
finish("pass", detail)
PY
