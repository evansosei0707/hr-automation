# Status

Current build state. Updated at the end of every work session.

---

**Last updated:** 2026-04-28
**Current phase:** Week 0 — Validation Gate (Phases 1+2+3 complete; Phase 4 in progress: 3/7 vouchers green, 1 parked, 1 in motion)
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

## What's next

- Week 0 / Phase 4 — External API vouchers. **Status: 3 green, 1 parked, 3 active/queued, 1 blocked.**
  - ✅ Telegram (`scripts/voucher/telegram.sh`, commit `79a93d2`)
  - ✅ Google Calendar (`scripts/voucher/google-calendar.sh`, commit `79a93d2`)
  - ✅ Anthropic Sonnet + Haiku (`scripts/voucher/anthropic.sh` + V005 `ai_call_log` table, commit `68210bd`)
  - ⏸ OpenAI Whisper — script committed, run blocked on billing (see What's blocked). Pivoting to Groq Whisper as alternative; researcher in flight, ADR-0006 forthcoming.
  - 🔄 Meta Graph FB — voucher in progress (Page token verified)
  - 🔄 Groq Whisper — researcher dispatched; voucher follows ADR-0006 + signup
  - ⏳ WhatsApp full webhook — needs ngrok
  - ⏳ X — blocked on developer access (application fire-and-forget)
  - ⏳ Instagram — blocked on Meta soft-hold (~48h account hold, retry 2026-04-28/29)
- Week 0 / Phase 5 — Cross-cutting patterns (Redis lock heartbeat with 45s synthetic Claude call, observability via event_log, backup drill).
- Week 0 / Phase 6 — Go/no-go review.

## What's blocked

- **OpenAI billing** — card declined twice (same card that worked on Anthropic; region-specific card-acceptance issue). Pivoting to Groq Whisper as alternative path. ADR-0006 forthcoming. The OpenAI voucher script + WAV fixture are committed (`scripts/voucher/openai-transcribe.sh`, `scripts/voucher/fixtures/voucher_sample.wav`) and runnable if access is ever resolved; not deleted.
- **X developer access** — application submitted, fire-and-forget; voucher waits on approval.
- **Instagram (Meta soft-hold)** — IG link attempts return "Unable to add Instagram account — unknown error" likely due to ~48h soft-hold on new accounts. `META_IG_USER_ID` empty. Retry 2026-04-28 or 2026-04-29; companion `meta-ig.sh` voucher will skip-gate gracefully on empty env.
- **WhatsApp full webhook** — needs ngrok for inbound webhook reachability; voucher this week.

## Last backup drill

Not yet run. Scheduled for first Monday after Week 1 completes.

## Last credential rotation

Initial credentials set during Week 0 bootstrap.

## Notes

- This file is user-facing — Claude Code should update it at the end of each session.
- Short bullets, not prose. If you have more to say, put it in an ADR or a plan.
