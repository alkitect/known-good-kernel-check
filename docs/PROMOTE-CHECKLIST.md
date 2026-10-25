# Promote checklist (generic)

Read-only gate before you unhold packages or change the boot default. The script `scripts/promote-candidate-checklist.sh` encodes the mechanical checks; this doc is the human protocol.

## Prerequisites

1. Candidate kernel booted (`uname -r` matches profile `kernel_version`).
2. Baseline captured on this profile (`baselines/CURRENT`).
3. Fresh preflight + acceptance report (within `KCG_PRE_UNHOLD_HOURS`, default 24).
4. Campaign tracking file with `observe_start:` (copy [campaign-tracking.example.md](campaign-tracking.example.md)).
5. Soak ledger soft floor met (`kcg_ledger.py summarize` / checklist).

## GO criteria (script exit 0)

- Report decision **PROMOTE**, or **HOLD** with every warn `id` ⊆ profile `promotion_allowed_warns`.
- Tracking records `hold_reviewed: yes` with matching `warn_ids` when decision is HOLD.
- Ledger summarize OK (min runs / passes since `observe_start`; any FAIL in window → NO-GO).
- Report age within max hours (unless `--skip-age-check`).

Confidence (`low` / `medium` / `high`) is **advisory** — checklist does not NO-GO on confidence alone.

## Human-only next (never automated here)

- Unhold HWE / image packages (or equivalent) only after GO.
- Point GRUB / boot default at the candidate only after you accept residual risk.
- Keep the previous known-good kernel installed for rollback.

## Run

```bash
export KCG_PROFILE=/path/to/candidate.yaml
./scripts/promote-candidate-checklist.sh \
  --report evidence/CURRENT_REPORT \
  --preflight evidence/CURRENT_PREFLIGHT \
  --tracking docs/campaign-tracking.example.md   # or your campaign file
```

Exit **0** = GO · **1** = NO-GO.
