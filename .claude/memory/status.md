# Status

Current build state. Updated at the end of every work session.

---

**Last updated:** 2026-04-26
**Current phase:** Week 0 — Validation Gate (Phases 1 + 2 complete; Phase 3 next)
**Active plan:** `plans/active-plan.md`
**Tier 2 follow-ups:** `plans/tier-2-followups.md`

## What's done

- ✅ v3 blueprint research and stress-test
- ✅ v3.1 design decisions finalised (ADR-0001 through ADR-0004)
- ✅ Project harness scaffolded (CLAUDE.md, docs/, .claude/, skeleton directories)
- ✅ All 8 workflow specs written
- ✅ All 7 integration specs written
- ✅ Operations docs written (observability, backup-DR, DPA, calibration, runbook)
- ✅ **Week 0 / Phase 1 — Local bring-up (2026-04-26).** All 7 services healthy on WSL via Docker Compose. Twenty v2.1.0, n8n 1.85.0, postgres:16 (twenty-db + bookings-db), redis 7, nginx. Bookings DB V001 migration applied. Twenty `/healthz` 200, n8n `/healthz` 200, DB SELECT 1 = 1. Scaffolding fixes captured in decisions.md.
- ✅ **Week 0 / Phase 2 — Twenty schema (2026-04-26).** Twenty schema applied and verified. 11/11 acceptance criteria green. Local validation surface (`scripts/audit-twenty-schema.py`) prevents recurrence of the four bug classes encountered. ADR-0005 captures the v0.60→v2.1.0 deltas; reference doc + IMPLEMENTATION_NOTES carry source-cited correction markers for the format-rule discoveries. Closing arc: 7 commits from `a532774` through `7ae9083`.

## What's next

- Week 0 / Phase 3 — Bookings DB migrations V002 (atomic slot-claim) + V003 (candidate_facts). V001 already in repo and applied; concurrency test required (two psql sessions racing the same offered slot, exactly one must win).
- Week 0 / Phase 4 — External API vouchers (days 3–5).
- Week 0 / Phase 5 — Cross-cutting patterns (Redis lock heartbeat, observability, backup drill).
- Week 0 / Phase 6 — Go/no-go review.

## What's blocked

- **API keys for Phase 4** (target days 3–5): Anthropic (sorting payment, ETA 1–2 days from 2026-04-26), OpenAI, Telegram, Google, X, Meta Graph (FB+IG). To be batch-acquired before Phase 4. WhatsApp creds are already in `.env`.

## Last backup drill

Not yet run. Scheduled for first Monday after Week 1 completes.

## Last credential rotation

Initial credentials set during Week 0 bootstrap.

## Notes

- This file is user-facing — Claude Code should update it at the end of each session.
- Short bullets, not prose. If you have more to say, put it in an ADR or a plan.
