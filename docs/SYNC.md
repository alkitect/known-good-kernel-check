# Private↔public product sync

This extract is the published copy of **Known-good kernel check** (GitHub `alkitect/known-good-kernel-check`). A private topic tree remains the authoring home (separate path on purpose; dual-name is intentional). Shared product changes sync **here** on drift. Host campaign notes, host-named profiles, and monorepo-only adapters **never** sync.

| Face | Value |
|------|--------|
| Display name | Known-good kernel check |
| Public slug | `known-good-kernel-check` |
| Former public slug | `known-good-kernel-check` (GitHub redirect) |
| Engine prefix | `KCG_*` (unchanged) |

## Ownership map

| Layer | Lives in | Sync? |
|-------|----------|-------|
| Shared **product** (suite runner, checks, lib, packs, login-soak, rocm-smoke, suspend, example-generic, CONTRACT/ARCHITECTURE/SUITE-GAPS schemas) | Private topic = authoring home; this repo = published scrubbed copy | **Yes** — topic → public on drift |
| Private **host campaign** (host-named profiles, campaign TRACKING with host ABIs, promote protocol tied to one machine) | Topic only | **Never** |
| Private **adapters** (host-only plugins) | Topic only | **Never** |
| Public **extract scaffolding** (`ci-check.sh`, GHA, LICENSE, FUNDING, PUBLISH, portal README, CONTRIBUTING, this SYNC.md) | This repo | Topic may **point** here; do not copy host campaign into these |

## Direction and drift rule

1. Improve shared product in the private topic → sync the same change into this extract (adapt paths / `KCG_PROFILE` / omit private files) → scrub + `./scripts/ci-check.sh` → ship gate (bump/tag/release unless tip-only).
2. Triggers include: suite behavior / schema / `KCG_SUITE_VERSION`; new public-shippable check or adapter; CONTRACT/ARCHITECTURE semantics; login-soak ledger rules; signature packs used by generic profiles.
3. Do **not** sync hostboard names, host profiles, campaign fields with host ABIs, monorepo-only paths, or journal evidence.
4. Public-first edits (README portal, ci-check, Ko-fi) may land only here; if they change product semantics, back-port the semantic note into topic CONTRACT/ARCHITECTURE without importing portal voice into the campaign README.

## Sync ladder

1. Diff shared product paths; apply here with required public edits (`KCG_PROFILE` required, standalone `KCG_ROOT`, adapter allowlist, omit excludes).
2. Rewrite any leaked hostname / login prose to anonymous language (“this host” / “your profile”).
3. Scrub worktree (and history if rewriting commits); monorepo scan for live hostname / home basename must be empty under this tree.
4. `(cd this-repo && ./scripts/ci-check.sh)` including `--self-test-reject`.
5. Align version triad (`KCG_SUITE_VERSION` + CHANGELOG + PUBLISH `Current tag:`) when user-visible.
6. Ship gate: tag with/before `main` + `gh release` + parent submodule pin (unless tip-only).
7. Update topic TRACKING `last-public-sync` (tag or date).

## Campaigns layout (Plan 1c)

| Sync? | What |
|-------|------|
| **Yes** | Empty `campaigns/` layout, resolver, ledger `--uname-r`, example-generic bootstrap |
| **Never** | Host lane trees (`campaigns/6.8.0-…`), host-named profiles, PLAN1B campaign content |

## Constraints checklist (never waive)

- No hostname / hostboard / login in tree; no hostname needles in `ci-check`
- No host-named profiles; no host-only adapters; no AI runtime catalog
- MIT + alkitect identity; Ko-fi FUNDING; README portal dual-lane (ci ≠ voice)
- `ALKITECT_CI_TMP` / tmp XDG for any install/enable scripts; no live host uninstall in ci-check
- Plugin paths under `scripts/adapters/` only
