# Campaign tracking (example)

Copy this file and fill fields for your observe window. Paths are relative to this extract root unless absolute.

## Campaign lock

```yaml
campaign_id: "YYYY-MM-DD-<candidate-uname>"
status: observing          # open | observing | pre_unhold | promoted | rolled_back | aborted
candidate_abi: "REPLACE_WITH_UNAME_R"
opened_at: "YYYY-MM-DDTHH:MM:SSZ"
single_writer: true
lock_note: "One owner; keep known-good installed for rollback."
```

## Dual-profile paths

```yaml
profile_known_good: /path/to/known-good.yaml
profile_candidate: /path/to/candidate.yaml
```

## Observe window

```yaml
observe_start: "YYYY-MM-DDTHH:MM:SSZ"
login_soak_enabled: no
# login_soak_enabled_at: "YYYY-MM-DDTHH:MM:SSZ"
```

## Hold review (checklist GO on HOLD)

```yaml
hold_reviewed: no
# warn_ids: []   # must match report warn ids ⊆ promotion_allowed_warns
```

## Notes

Ledger summarize binds `--since` to `observe_start`. Soft floor and confidence rules: [CONTRACT.md](CONTRACT.md).
