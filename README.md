# Known-good kernel check

Compare a new Ubuntu kernel to a snapshot from a day this machine was fine, then keep it, wait, or go back.

[Quick start](#quick-start) · [Releases](https://github.com/alkitect/known-good-kernel-check/releases) · [License](#license)

Latest release notes: [CHANGELOG.md](CHANGELOG.md) and [GitHub Releases](https://github.com/alkitect/known-good-kernel-check/releases). A plain `git clone` follows the default branch tip unless you check out a tag; prefer a tagged release for day-to-day use.

## What this does

Ubuntu often offers a newer HWE or point-release kernel. Last time that happened, Wi-Fi, Bluetooth, GPU, or suspend may have gone weird on *your* box. Generic “kernel health” scores do not know what was good here last week.

This tool captures a baseline on a day the machine felt fine, then re-checks inventory, device bind, journal signatures, Wi-Fi/BT, optional adapters, and a short peak-rest soak against that snapshot. The suite exits **0**, **1**, or **2**. In plain words that is keep, wait, or go back (machine tokens: PROMOTE, HOLD, REJECT). HOLD with allowlisted warns can still be a keep after you read the report; REJECT means stop.

Safe by default: you copy a profile, set `KCG_PROFILE`, capture a baseline, and run without unholding packages or changing GRUB until your promote checklist says GO.

## Who this is for

This is for Ubuntu (or similar) desktops where you care whether a *candidate* kernel still matches a known-good baseline on the same machine. You keep a recovery kernel installed and can run a short soak.

It is not a multi-host CI farm, an LTP replacement, or a generic “is my GPU fine” scoreboard. Suspend hard-gating and vendor-only campaigns stay out of the default path.

## Quick start

Copy the example profile, set `kernel_version` to your current `uname -r`, export `KCG_PROFILE`, capture a baseline on the known-good kernel, then boot the candidate and run the suite. Login soak is optional later.

Then: [Install](#install) → [1. Profile and baseline](#1-profile-and-baseline) → [2. Run the suite](#2-run-the-suite).

### Install

You need bash, python3, PyYAML (`python3-yaml`), `journalctl`, and a graphical session if you enable GPU load soak.

Stable path: clone or download a release tag from [Releases](https://github.com/alkitect/known-good-kernel-check/releases). Tip of the default branch is fine for contributors.

```bash
git clone https://github.com/alkitect/known-good-kernel-check.git
cd known-good-kernel-check
# optional: git checkout vX.Y.Z   # pin to a release tag
cp profile/example-generic.yaml.example ~/kcg-profile.yaml
# edit kernel_version to match: uname -r
export KCG_PROFILE="$HOME/kcg-profile.yaml"
```

There is no `install-to-local.sh`. Point `KCG_PROFILE` at your YAML and run scripts from the clone.

### 1. Profile and baseline

On the known-good kernel (profile `kernel_version` must match `uname -r`):

```bash
export KCG_PROFILE="$HOME/kcg-profile.yaml"
./scripts/capture-baseline.sh
```

That writes under `baselines/` and points `baselines/CURRENT` at the new snapshot.

### 2. Run the suite

Boot the candidate kernel (still with a recovery kernel available), then:

```bash
./scripts/capture-preflight.sh   # before acceptance runs
./scripts/run-compat-suite.sh --acceptance
# expect exit 0 / 1 / 2 → keep / wait / go back
```

<details>
<summary>Optional: login soak and campaign lanes</summary>

By default the suite can resolve a campaign lane from `uname -r` under `campaigns/<uname>/` (bootstrap from the example profile on first boot). Set `KCG_PROFILE` to override.

Background Tier D once per graphical login (does not change GRUB):

```bash
export KCG_PROFILE="$HOME/kcg-profile.yaml"
./scripts/enable-login-soak.sh
./scripts/verify-login-soak-hook.sh
```

Disable with `./scripts/enable-login-soak.sh --disable`.

</details>

## Check it works

Success is a clean baseline capture, a suite decision you understand (keep, or a documented wait), and knowing exit **2** means go back. Optional: ledger summarize against your campaign tracking file after several login soaks.

<details>
<summary>Optional confirmation scripts</summary>

```bash
export KCG_PROFILE="$HOME/kcg-profile.yaml"
./scripts/run-compat-suite.sh --skip-soak --self-test-reject
# expect exit 2
./scripts/ci-check.sh
```

</details>

Questions or a stuck install: open a GitHub [Issue](https://github.com/alkitect/known-good-kernel-check/issues) or see [CONTRIBUTING.md](CONTRIBUTING.md).

## Support my work

Tip jar for the next desktop fix. Or a coffee so the next script stays boring on purpose.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/alkitect/?hidefeed=true&widget=true&embed=true)

## Uninstall

Remove the clone (or stop using it). If you enabled login soak:

```bash
./scripts/enable-login-soak.sh --disable
```

Delete your local profile and any `baselines/` / `evidence/` trees you created. Nothing is installed system-wide by default.

## Configure

- Profile keys and env: [docs/CONTRACT.md](docs/CONTRACT.md)
- Architecture / tiers / multi-lane campaigns: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Promote GO/NO-GO: [docs/PROMOTE-CHECKLIST.md](docs/PROMOTE-CHECKLIST.md)
- Plugins: only paths under `scripts/adapters/` (shipped: `rocm-smoke`, `suspend`)

## How it works

Checks emit `KCG_RESULT` lines; the runner aggregates against the baseline and profile policy. Progress ticks go to stderr only. Soak evidence accumulates in `evidence/soak-ledger.jsonl` for the promote checklist soft floor and advisory confidence.

## Limits & safety

This can influence how you judge a kernel; it does **not** unhold packages or edit GRUB for you.

- Platform: Linux desktop with journal access; GPU load soak needs a session and (when enabled) a load recipe binary.
- Baseline-relative: empty PCI/modules lists skip those checks; a wrong `kernel_version` hard-refuses.
- Plugins: treat profile YAML as untrusted; adapters must stay under `scripts/adapters/`.
- Login soak: user systemd unit only; do not enable against a live host from CI (use tmp `HOME`).

## License

MIT. See [LICENSE](LICENSE).

Prefer [Ko-fi](https://ko-fi.com/alkitect/?hidefeed=true&widget=true&embed=true) if you want to tip.
