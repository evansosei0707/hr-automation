# Status

Current build state. Updated at the end of every work session.

---

**Last updated:** 2026-04-29
**Current phase:** Week 0 — Validation Gate (Phases 1+2+3+4 complete; Phase 5 next)
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
- ✅ **Week 0 / Phase 3 — Bookings DB concurrency test (2026-04-26).** 10/10 rounds PASS via `scripts/test-bookings-concurrency.sh`. Both safety legs verified: partial unique index (offer-side, SQLSTATE 23505 with named constraint) and WHERE-clause guard (claim-side, rowcount=0 with no error / rollback / serialization noise). Concurrency-test-only scope; V002 struck (no separate migration artifact — atomic claim is inline UPDATE), V003 deferred to Workflow C build per "schema close to workflow" principle.
- ✅ **Week 0 / Phase 4 — External API vouchers (2026-04-29).** Original plan: 7 vouchers; final count: 9 (OpenAI/Groq pivot per ADR-0006 added the Groq voucher; Meta FB/IG split into separate vouchers per ADR-0007). Final state: **6 active green** (Telegram `79a93d2`, Google Calendar `79a93d2`, Anthropic `68210bd`, Meta FB `d561219`, Groq Whisper `e0fd320`, WhatsApp webhook `9f4241d`); **1 parked-superseded** (OpenAI Whisper `e5a9b16`, superseded by Groq per ADR-0006 — script kept as historical artifact); **2 deferred via ADRs** (Instagram per ADR-0007 — Meta structural refusal; X per ADR-0008 — free-tier developer access pending). Real Ghana traffic verified end-to-end on the WhatsApp webhook (event_log row 13: real +233 number, real Meta-signed payload, HMAC-validated). Workflow E v1 ships with FB + Telegram only — no IG (ADR-0007), no X (ADR-0008), no LinkedIn (ADR-0002). Three structural antibodies landed alongside the vouchers: `scripts/audit-twenty-schema.py` (local mirror of Twenty's metadata validation), `.claude/rules/n8n-workflows.md` rules #11–#13 (ReviewTask invariant, Code-node stdlib gating via `NODE_FUNCTION_ALLOW_BUILTIN`, Postgres NOT-NULL binding cross-check against V-migrations), and the Nginx default_server pattern enabling any future off-host webhook handler. Closing arc: 9 commits across `42680aa`..`65f8935`.

## What's next

- Week 0 / Phase 5 — **Cross-cutting patterns.**
  - Redis lock pattern: standalone n8n workflow that acquires the conv lock, holds for 45s with heartbeat extending TTL, releases with CAS. Verify another workflow attempting the same lock waits correctly. (CLAUDE.md non-negotiable invariant #3 — the production-shape proof.)
  - Observability: one workflow logs a structured event to `event_log`, query it back. (Already partially exercised by Phase 4 vouchers' event_log writes; Phase 5 formalises the read/aggregate path.)
  - Backup drill: `scripts/backup.sh`, wipe DB, restore from dump, query.
- Week 0 / Phase 6 — Go/no-go review.

**Pidgin quality testing for Groq Whisper:** deferred to Workflow A build (Week 2/3) per Tier 2 item T2-6. Voucher proves wire shape; real Pidgin samples required before auto-handling ships.

## What's blocked

(Empty — Phase 4 close-out cleared all entries.)

The three Phase 4 deferrals are tracked structurally in their ADRs, not as "blocked" items here:
- OpenAI Whisper → parked, superseded by Groq (ADR-0006). Not a blocker — Groq covers the role.
- Instagram → deferred (ADR-0007). Revisit triggers documented in the ADR.
- X → deferred (ADR-0008). 30-day re-trigger at 2026-05-27.

If a Phase 5 task surfaces an external blocker, log it here.

## Last backup drill

Not yet run. Scheduled for first Monday after Week 1 completes.

## Last credential rotation

Initial credentials set during Week 0 bootstrap.

## Notes

- This file is user-facing — Claude Code should update it at the end of each session.
- Short bullets, not prose. If you have more to say, put it in an ADR or a plan.
