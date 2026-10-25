# Publish notes

Before tag: README must pass `./scripts/ci-check.sh` (required H2s + README ban tokens + Ko-fi `FUNDING.yml` / tip link). See [CONTRIBUTING.md](../CONTRIBUTING.md) § README conventions.

README variant: A

First public tag: v0.3.0

Current tag: v0.3.0

Default first tag is 0.1.0. Never copy another alkitect repo’s tag. This extract intentionally starts at **v0.3.0** to match suite `KCG_SUITE_VERSION` (V-001 recorded here before tag).

```bash
./scripts/ci-check.sh
git tag -a v0.3.0 -m "v0.3.0"
git push origin main v0.3.0
gh release create v0.3.0 --title "v0.3.0" --notes-file - <<'EOF'
## 0.3.0

First public release of the baseline-relative known-good kernel check (suite 0.3): profile + baseline, PROMOTE/HOLD/REJECT, multi-lane boot campaigns, peak-rest soak, login PBIT with daily cap and FAIL retry, rocm-smoke/suspend adapters, ci-check self-test-reject.
EOF
```

Repo URL: `https://github.com/alkitect/known-good-kernel-check`

## GitHub About

| Field | Value |
|-------|--------|
| Description | Baseline-relative kernel gate: PROMOTE, HOLD, or REJECT a candidate kernel against a known-good capture on this host |
| Website | _(empty — tip via README Ko-fi badge)_ |
| Topics | `linux`, `ubuntu`, `kernel`, `systemd`, `amdgpu`, `compatibility` |

```bash
gh repo edit alkitect/known-good-kernel-check \
  --description "Baseline-relative kernel gate: PROMOTE, HOLD, or REJECT a candidate kernel against a known-good capture on this host" \
  --homepage "" \
  --add-topic linux --add-topic ubuntu --add-topic kernel \
  --add-topic systemd --add-topic amdgpu --add-topic compatibility
```
