# Contributing

## README conventions

Public README required H2s (exact strings; enforced by `./scripts/ci-check.sh`):

```text
## What this does
## Who this is for
## Quick start
## Check it works
## Uninstall
## Limits & safety
## License
```

Put the beginner path (profile / baseline / suite) above limits. Do not put private monorepo paths or the token `SSOT` in README prose — say “release source” instead.

Also enforced by `./scripts/ci-check.sh`:

- `.github/FUNDING.yml` with `ko_fi: alkitect`
- README Ko-fi GitHub button (`githubbutton_sm.svg` → tip-panel `https://ko-fi.com/alkitect/?hidefeed=true&widget=true&embed=true`) in `## Support my work` (Support section after Check it works / before Uninstall)
- README soft tip containing `ko-fi.com/alkitect` (after License)
- README must not link Patreon or Buy Me a Coffee

Gate: `./scripts/ci-check.sh`.

**Maintainer note:** do not enable login soak or uninstall against the live host during extract or CI work — use a tmp `HOME` (and matching `XDG_*`) with `ALKITECT_CI_TMP=1` when testing enable wrappers.

## Versioning

First public tag is recorded in `docs/PUBLISH.md` (`First public tag:`). Default is **0.1.0**. Never copy another alkitect repo’s tag. Use `RC-BEFORE-1.0` in PUBLISH only for an intentional 0.9.x RC. After the first tag, bump from CHANGELOG Unreleased (`feat` → minor, `fix` → patch). Maintainers: `./scripts/ci-check.sh` must pass before tag.

This product’s first tag is **v0.3.0** (suite version alignment); see PUBLISH.

## Bug reports

Please include:

- Distro and desktop
- `uname -r` and profile `kernel_version`
- Decision + exit code from `run-compat-suite.sh`
- Redacted `report-*.json` excerpts (no hostnames, no home paths)
- Whether `--self-test-reject` exits 2

## Behavior changes

If you change suite semantics, update:

- [docs/CONTRACT.md](docs/CONTRACT.md)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/SUITE-GAPS.md](docs/SUITE-GAPS.md) when deferrals move

Run before PR:

```bash
find scripts -type f -name '*.sh' -print0 | xargs -0 -r bash -n
python3 -m py_compile scripts/lib/kcg_*.py
./scripts/ci-check.sh
```

## Sync policy (dual maintenance)

Shared product code is dual-home with a private authoring topic. On product drift, sync into this extract under the ladder and constraints in [docs/SYNC.md](docs/SYNC.md). Host campaign notes, host-named profiles, and monorepo-only adapters never sync. Portal README / ci-check / FUNDING stay public-only.
