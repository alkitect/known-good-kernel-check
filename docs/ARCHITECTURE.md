# Known-good kernel check — architecture

Baseline-relative kernel gate for a single host profile. Not LTP, Checkbox, or a generic health scoreboard. Decisions are **PROMOTE / HOLD / REJECT** relative to a captured baseline on a known-good `uname -r`, not “kernel looks healthy.”

**Contract detail:** [CONTRACT.md](CONTRACT.md) · **Promote steps:** [PROMOTE-CHECKLIST.md](PROMOTE-CHECKLIST.md) · **Private↔public sync:** [SYNC.md](SYNC.md)

## Context

```text
┌─────────────────────────────────────────────────────────────┐
│  Human                                                      │
│  Captures baseline → boots candidate → runs suite / soak    │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│  run-compat-suite.sh                                        │
│  Profile YAML + baseline CURRENT → checks → aggregate       │
│  Exit: 0 PROMOTE · 1 HOLD · 2 REJECT                        │
└───────┬───────────┬───────────┬───────────┬─────────────────┘
        │           │           │           │
   Tier A      Tier B      Tier C      Tier D
 inventory    bind+Type I  wifi/BT     soak (gate|deep)
              +plugins     +adapters
```

## Multi-lane campaigns

Boot choice selects the lane. Layout:

```text
campaigns/<uname-r>/
  tracking.md      # observe_start, campaign lock
  profile.yaml     # lane profile (kernel_version = that uname)
  baselines/       # lane CURRENT (gitignored contents)
```

| Rule | Behavior |
|------|----------|
| Resolver | `scripts/lib/kcg-lane.sh` when `KCG_PROFILE` unset — resume if tracking has parseable `observe_start`, else fail-closed; absent → bootstrap from `example-generic.yaml.example` |
| Override | Explicit `KCG_PROFILE` / `--profile` wins |
| Login without baseline | Ledger SKIP, no once-per-boot stamp |
| Ledger | `summarize` / `count` require `--uname-r` (shared `evidence/soak-ledger.jsonl`) |
| Cadence | `max_login_soaks_per_day` (default 1) × `max_runs_for_campaign` (7) with `min_calendar_days` 7; FAIL grants one same-day login retry |

Ship a scrubbed tracking stub: [campaign-tracking.example.md](campaign-tracking.example.md). Do not commit host lane trees.

## Tiers

| Tier | Scripts | Role |
|------|---------|------|
| A | `tier-a-inventory.sh` | Inventory vs baseline (OS, lockdown, optional keys) |
| B | `tier-b-bind.sh`, `tier-b-type1.sh` | PCI/module bind; journal signature packs |
| C | `tier-c-wifi-bt.sh` + adapters | Wi-Fi/BT; **rocm-smoke** (warn); **suspend** opt-in (`enabled: false` by default) |
| D | `tier-d-soak.sh` | Peak–rest soak; ledger append; session-aware load |

Adapters live only under `scripts/adapters/`. Profile `adapter` paths are realpath-prefixed to that directory.

## Profiles

```text
example-generic.yaml.example   ← public template (copy + fill kernel_version)
ci-smoke.yaml                  ← CI / Agent smoke (load.enabled: false)
campaigns/<uname>/profile.yaml ← lane copy (gitignored host trees)
local.yaml / *-candidate.yaml  ← your copies (gitignored patterns)
```

Unset `KCG_PROFILE` → lane resolver. Set `export KCG_PROFILE=/path/to/your.yaml` (or `--profile`) to override. No host-named defaults ship in this extract.

## Evidence layout

```text
baselines/CURRENT → baseline-<uname>-<stamp>.json   # or per-lane under campaigns/
evidence/CURRENT_PREFLIGHT → pre-run-*.json
evidence/CURRENT_REPORT → report-*.json
evidence/soak-ledger.jsonl
```

`baselines/` and `evidence/` contents are gitignored; capture scripts create them locally.

## Login soak (optional)

`systemd/user/kcg-login-soak.service` → `run-login-soak.sh` once per graphical login (Tier D gate only). Enable with `enable-login-soak.sh` under a real session; CI must not enable the live unit (use tmp `HOME` / `ALKITECT_CI_TMP` if testing install wrappers).

## Campaign discipline

One campaign owner at a time (your tracking file’s campaign lock). Suite and soak share the desktop; do not parallelize long soaks with other heavy GPU work. See [PROMOTE-CHECKLIST.md](PROMOTE-CHECKLIST.md) and [campaign-tracking.example.md](campaign-tracking.example.md).
