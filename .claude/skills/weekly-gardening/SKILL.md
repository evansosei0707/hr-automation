---
name: weekly-gardening
description: Run the weekly doc and harness maintenance pass. Dispatches doc-gardener, reviews stale plans, prompts for backup-drill status.
---

# /weekly-gardening

## When to use

Once a week, or after a big batch of changes. Keeps the harness healthy.

## Steps

1. **Dispatch `doc-gardener`.** It reports drift, broken refs, stale items. Review the report; decide which items need action. Do not auto-apply — the report is advisory.

2. **Review plans folder.**
   - Any `plans/*.md` older than 14 days and not in `*-DONE.md` state → ask the user if it's still active, should be archived, or picked up.
   - `plans/active-plan.md` — is it still the right active plan?

3. **Check memory.**
   - `.claude/memory/status.md` — is it current? If the last update is > 7 days old, prompt for a status refresh.
   - `.claude/memory/decisions.md` — any decisions from the past week that did not get logged?

4. **Backup drill status.** If it has been > 30 days since the last recorded restore drill (check `memory/status.md` for the record), flag to the user.

5. **Cost check.** Run `scripts/ai-cost-last-week.sh` and compare to budget tiers. Flag if trending up.

6. **Security rotation reminder.** If any rotation date is > 90 days old (Claude API key, Meta token, Postgres passwords), flag.

## Output

A short report to the user:

```
Weekly gardening — YYYY-MM-DD

Doc gardener findings: <summary>
Plans needing attention: [list]
Memory freshness: OK / needs update
Backup drill: OK / overdue
Cost trend: OK / investigate
Rotation reminders: [list]

Recommended actions, in priority order:
  1. ...
  2. ...
```

## Do not

- Auto-apply fixes.
- Mark something DONE without the user confirming.
