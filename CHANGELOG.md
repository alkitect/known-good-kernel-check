# Changelog

## Unreleased

## 0.3.0

First public release of the baseline-relative known-good kernel check (suite 0.3).

- Profile-driven suite: inventory, bind, Type I packs, wifi/BT, plugins, peak-rest soak
- Decisions PROMOTE / HOLD / REJECT; `--self-test-reject` synthetic REJECT path
- Multi-lane campaigns: boot selects `campaigns/<uname>/` via lane resolver; explicit `KCG_PROFILE` overrides
- Shared soak ledger with `--uname-r` filter; login SKIP until lane baseline CURRENT
- Cadence: one login soak per local day × seven campaign runs (≥7 calendar days); FAIL grants one same-day retry
- Login soak user unit + soak ledger soft floor / advisory confidence
- Public adapters: `rocm-smoke`, `suspend` (paths under `scripts/adapters/` only)
- Requires profile via resolver or `KCG_PROFILE` (no host default); example + CI smoke profiles
- `./scripts/ci-check.sh` + GitHub Actions smoke
