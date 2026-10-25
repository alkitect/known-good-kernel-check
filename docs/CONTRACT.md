# Known-good kernel check — contracts

Schema versions today: profile + report `schema_version: "1.0"` · suite `suite_version: "0.4.0"`.

## Vocabulary (soak)

| Term | Meaning |
|------|---------|
| **gate** | Short peak–rest load soak (~5–10 min). Default for `--acceptance` and login PBIT. |
| **deep** | Longer load-cycle endurance (~15–30 min). Opt-in only (`mode: deep` / `KCG_SOAK_MODE=deep`). |
| **peak–rest** | Settle → load → journal gap → load → post poll (not long idle). |
| **PBIT** | `run-login-soak.sh` — once per boot, Tier D only. |
| **CBIT / observe** | Multi-day observe window + `soak-ledger.jsonl` accumulation. |

**Idle time alone is not soak evidence.** Journal polls without load only yield binary hit/miss.

## Profile YAML (required keys)

| Key | Meaning |
|-----|---------|
| `profile_id` | Stable id (e.g. `example-generic`, `ci-smoke`, or your local name) |
| `schema_version` | `"1.0"` |
| `kernel_version` | Exact `uname -r` required for suite/baseline |
| `hold_on_any_warn` | If true, any `warn` → HOLD |
| `promotion_allowed_warns` | Warn `id`s allowed for promote checklist GO on HOLD |
| `signatures.packs[]` | Pack names under `signatures/packs/<name>.txt` (preferred) |
| `signatures.type1_path` | Compat fallback single file if packs empty |
| `reject_on_drift` | Inventory keys that escalate warn→fail |
| `pci[]` | `id`, `driver`, `role`, `required` (may be empty for generic) |
| `modules[]` | Required loaded modules (names) |
| `kfd.require_dev_kfd` | Prefer `/dev/kfd` over module name |
| `plugins[]` | `id`, `adapter`, `required`, `decision_weight` (`hard`\|`warn`), `preflight`, optional `enabled: false` |
| `drm.min_cards` | Min DRM cards |
| `wifi` / `bluetooth` | Iface / HCI expectations (`expected` hci may warn if UP) |
| `soak.mode` | `gate` (default) \| `deep` |
| `soak.settle_seconds` / `gap_seconds` / `post_load_poll_seconds` | Peak–rest timing |
| `soak.default_seconds` | Legacy / ETA hint only when mode unset — prefer computed wall from mode |
| `soak.load` | `enabled`, `missing` (`fail`\|`warn`), `cycles`, `window_seconds`, `recipe`, `fail_on_signature_packs[]` |
| | `glxgears` launches `64x64` corner geometry; renamed/hidden via `wmctrl` to **KCG kernel soak — GPU load** when available (mesa has no `--title` / minimize) |
| `soak.samples` | `enabled`, `interval_seconds` → `evidence/soak-samples-<stamp>.jsonl` |
| `soak.cadence` | Soft floor + **min_calendar_days default 7**; `max_runs_for_campaign` (7) × `max_login_soaks_per_day` (1) ⇒ ≥7 local days; **FAIL grants one same-day login retry**; PASS/WARN consume the day |
| `inventory_keys[]` | Tier A fields compared to baseline |

**Migration (suite-gaps → 0.3):** gate `load.missing` defaults to **fail** after session-ready (DISPLAY/WAYLAND). Missing session → `soak-session` **warn** (does not reset observe).

Public template: `profile/example-generic.yaml.example`. CI template: `profile/ci-smoke.yaml`. Copy either to a local path and set `kernel_version` to your `uname -r`. Scripts **require** `KCG_PROFILE` (or `--profile`); there is no host default.

## Plugins (security)

- `adapter` paths must resolve under `scripts/adapters/` only (reject `..` and escapes).
- Treat profiles as untrusted input: no secrets, tokens, or keyring instructions in YAML.
- Ship adapters today: `rocm-smoke.sh`, `suspend.sh`. Add your own under `scripts/adapters/` and reference them from the profile.

## `KCG_RESULT` wire format

Stdout line from checks/adapters (never exit 2 for a soft check):

```text
KCG_RESULT {"id":"…","tier":"A|B|C|D","result":"pass|fail|skip|expected|warn","detail":"…","source":"builtin|plugin",…}
```

Plugins may add `mapped_result`, `plugin_exit`. Runner aggregates; adapters must not be the decision authority.

**Progress ≠ `KCG_RESULT`.** Suite progress / ETA / soak heartbeats from `kcg_progress.py` go to **stderr only**.

## Report JSON (required fields)

Validated by `run-compat-suite.sh --offline-schema`:

`schema_version`, `suite_version`, `decision`, `exit_code`, `uname`, `profile_id`, `profile_path`, `profile_hash`, `baseline_id`, `started_at`, `checks` (list).

Also written: `preflight_snapshot_id`. Markdown twin: `report-*.md`.

Login PBIT writes `evidence/login-soak-*.json` (kind `login-soak`) — not a full acceptance report.


## Multi-lane campaigns

Boot choice selects the lane. Layout: `campaigns/<uname-r>/{tracking.md,profile.yaml,baselines/}`.

| Rule | Behavior |
|------|----------|
| Resolver | `scripts/lib/kcg-lane.sh` when `KCG_PROFILE` unset — resume if tracking has parseable `observe_start`, else fail-closed; absent → bootstrap from `example-generic.yaml.example` |
| Override | Explicit `KCG_PROFILE` / `--profile` wins |
| Login without baseline | Ledger SKIP, no once-per-boot stamp |
| Ledger | `summarize` / `count` require `--uname-r` |

## Soak ledger

Append-only `evidence/soak-ledger.jsonl` (via `kcg_ledger.py append`). Fields: `stamp`, `boot_id`, `uname_r`, `profile`, `mode`, `duration_s`, `decision`, `report_path`, `samples_path`, `journal_hits`, `packs_matched`, `suite_version`, `load_recipe`, `source` (`login`\|`acceptance`\|`manual`\|`skip`).

`kcg_ledger.py summarize --ledger … --tracking <campaign.md>` binds `--since` to `observe_start`. Pre-0.3 / non-gate / **smoke|dry-run** rows do **not** count. Campaign `count` defaults to **login-only** (acceptance/manual do not consume `max_runs_for_campaign`). Checklist **must** call summarize (NO-GO if soft floor unmet). Any FAIL in window → NO-GO. Summarize JSON also emits advisory `confidence` (`low`\|`medium`\|`high`) + `confidence_path` (`soft_floor`\|`data`\|`calendar`\|…) — soft floor alone is not high confidence; confidence **shifts** as login PASSes / distinct boots accumulate (calendar is an alternate path). Checklist prints advice / WARN on low|medium but does **not** NO-GO on confidence alone.

Ship a scrubbed stub: [campaign-tracking.example.md](campaign-tracking.example.md). Promote steps: [PROMOTE-CHECKLIST.md](PROMOTE-CHECKLIST.md).

## Baseline / preflight / fixture

`capture-baseline.sh`, `capture-preflight.sh`, `fixtures/expected-decision.json`, ledger fixtures under `fixtures/`.

## Env bundle

| Variable | Default / meaning |
|----------|-------------------|
| `KCG_PROFILE` | Lane via resolver, or **required** explicit path |
| `KCG_BASELINES` | `baselines/` |
| `KCG_EVIDENCE` | `evidence/` |
| `KCG_PRE_UNHOLD_HOURS` | `24` (checklist freshness) |
| `KCG_PROGRESS` | `auto` |
| `KCG_SOAK_MODE` | Override `soak.mode` (`gate`\|`deep`) |
| `KCG_SOAK_SECONDS` | Optional wall override (ticks); prefer mode timings |
| `KCG_SOAK_SMOKE` | `1` = shortened gate for Agent verify; asserts load ran when session ready |
| `KCG_SOAK_SOURCE` | `login`\|`acceptance`\|`manual` (ledger) |
| `KCG_SKIP_SOAK` | Skip Tier D (forbidden with `--acceptance`) |
| `KCG_LOGIN_SOAK` | Set by `run-login-soak.sh` |
| `KCG_SKIP_LOGIN_SOAK` | Skip PBIT; append ledger SKIP |
| `KCG_LOGIN_SOAK_DRY` | Dry PBIT (stamp + ledger PASS) |
| `KCG_BOOT_ID` | Injectable boot id for smoke |
| `KCG_CANDIDATE_PROFILE` | Optional candidate yaml for login picker |
| `KCG_KNOWN_GOOD_PROFILE` | Optional known-good yaml for login picker |
| `KCG_CAMPAIGN_TRACKING` | Optional campaign tracking markdown (observe_start) |
