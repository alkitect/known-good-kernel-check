# Publish notes

Before tag: README must pass `./scripts/ci-check.sh` (required H2s + README ban tokens + Ko-fi `FUNDING.yml` / tip link). See [CONTRIBUTING.md](../CONTRIBUTING.md) § README conventions.

README variant: A

First public tag: v0.3.0

Current tag: v0.4.0

Default first tag is 0.1.0. Never copy another alkitect repo’s tag. This extract intentionally started at **v0.3.0** to match suite `KCG_SUITE_VERSION` (V-001 recorded before first tag). **v0.4.0** is the branding rename release (Known-good kernel check / `known-good-kernel-check`).

Former GitHub name: `alkitect/known-good-kernel-check` (GitHub redirects to the new slug).

```bash
./scripts/ci-check.sh
git tag -a v0.4.0 -m "v0.4.0"
git push origin v0.4.0 main
gh release create v0.4.0 --title "v0.4.0" --notes-file - <<'EOF'
## 0.4.0

Branding rename: Known-good kernel check (`known-good-kernel-check`). Human keep/wait/go back wording in the portal README; suite still exits PROMOTE/HOLD/REJECT. History rewritten for the new product name.
EOF
```

Repo URL: `https://github.com/alkitect/known-good-kernel-check`

## GitHub About

| Field | Value |
|-------|--------|
| Description | Compare a new Ubuntu kernel to a snapshot from a day this machine was fine, then keep it, wait, or go back |
| Website | _(empty — tip via README Ko-fi badge)_ |
| Topics | `linux`, `ubuntu`, `kernel`, `hwe`, `kernel-regression`, `ubuntu-desktop`, `amdgpu`, `regression-testing` |

```bash
gh repo edit alkitect/known-good-kernel-check \
  --description "Compare a new Ubuntu kernel to a snapshot from a day this machine was fine, then keep it, wait, or go back" \
  --homepage "" \
  --add-topic linux --add-topic ubuntu --add-topic kernel \
  --add-topic hwe --add-topic kernel-regression --add-topic ubuntu-desktop \
  --add-topic amdgpu --add-topic regression-testing
```
