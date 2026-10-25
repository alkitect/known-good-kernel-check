# Suite gaps (living list)

Intentional omissions and deferred work for suite **0.3.x**. Product semantics: [CONTRACT.md](CONTRACT.md) · [ARCHITECTURE.md](ARCHITECTURE.md).

## Covered in 0.3

| Area | Notes |
|------|-------|
| Profile-driven PCI / wifi / BT / plugins | Empty lists OK for generic |
| Signature packs | `signatures/packs/` + Type I fallback |
| Bus-agnostic journal greps | No PCI BDF in packs |
| Peak–rest soak (gate/deep) | Ledger + login PBIT |
| Plugin `KCG_RESULT` | Runner aggregates |
| Progress on stderr | Never mixed into RESULTS |
| Public adapters | `rocm-smoke`, `suspend` |

## Deferred

| Item | Note |
|------|------|
| Auto-detect PCI / iface wizard | UX only; not required for gate correctness |
| Extra vendor packs (i915, nvidia, mt76, …) | Add under `signatures/packs/`; reference from profile |
| Multi-host CI matrix | Today: single-runner smoke with `ci-smoke` + fixtures |
| Pip-installable package | Shell + profile stays the product |
| Hard suspend gate | Lab / consent only — never default daily-driver |
| Checklist GO for suspend | Forbidden as a promote criterion |

## Not shipped here

Host-named profiles, private campaign tracking with host ABIs, and monorepo-only adapters stay out of this extract. Extend via your own `scripts/adapters/` plugins and local profiles.
