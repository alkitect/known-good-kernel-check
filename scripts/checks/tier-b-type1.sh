#!/usr/bin/env bash
# Tier B: journal signature packs for current boot (display Type I + reset/MODE1).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KCG_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROFILE="${1:-${KCG_ROOT}/profile/example-generic.yaml.example}"
LIB_DIR="${KCG_ROOT}/scripts/lib"

python3 - "${KCG_ROOT}" "${PROFILE}" "${LIB_DIR}" <<'PY'
import json, sys
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
    patterns_from_profile,
)

profile = yaml.safe_load(profile_path.read_text(encoding="utf-8")) or {}
patterns = patterns_from_profile(kcg_root, profile)

def emit(cid, result, detail):
    print("KCG_RESULT " + json.dumps({
        "id": cid, "tier": "B", "result": result, "detail": detail, "source": "builtin"
    }, separators=(",", ":")))

if not patterns:
    emit("type1-journal", "skip", "no signature packs or type1_path configured")
    sys.exit(0)

log = journalctl_kernel()
hits = find_hits(log, patterns)
if hits:
    emit("type1-journal", "fail", f"matches this boot: {hits_summary(hits)}")
else:
    emit("type1-journal", "pass", "no signature-pack matches this boot")
PY
