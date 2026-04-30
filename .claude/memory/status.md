# Status

Current build state. Updated at the end of every work session.

---

**Last updated:** 2026-04-30
**Current phase:** Week 1 — Workflow B (white-collar screening) next
**Active plan:** `plans/active-plan.md` (Week 0 closed; Week 1 plan to be drafted at session start)
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
- ✅ **Week 0 / Phase 5 — Cross-cutting patterns (2026-04-29).** Conv-lock 20/20 PASS via `scripts/test-conv-lock.sh` (min PTTL=48196ms during 45s production-canary call); canonical operational queries with real evidence embedded in `docs/04-operations/observability.md` + runbook §0 cross-reference; backup drill three-DB green (twenty 245KB / bookings 7.8KB / n8n 42KB). Audit finding: original spec missed n8n DB — corrected in backup-dr.md. Closing arc: `6a7bf01`..`3256497` + `ac6f418`.
- ✅ **Week 0 / Phase 6 — Go/no-go review (2026-04-29).** Decision: **GO**. 20 findings reviewed (R1-R5, SD1-SD8, C1-C2, RC1-RC5) → 13 closed in commits → 7 carried forward with T2 tracking items. Full auditable record: `docs/05-decisions/week-0-go-no-go.md`. Closing arc: `5bd25c3`..`53361f9` (5 commits).
- ✅ **Week 0 — CLOSED 2026-04-29.**

- ✅ **Week 1 — Workflow A v1 (2026-04-30).** Four workflow JSON files shipped: `a-communications.json` (~70 nodes), `wa-send.json`, `claude-call.json`, `dpa-handler.json`. Design note `a-communications-design-v1.md` written; V003 migration applied (candidate_facts, conversation, conversation_message). Conv-lock Option C (180s flat TTL, CAS DEL on all exit paths). Calibration gate (ac00067) added for 2-week human-review window. Tester 14/14 PASS; code-reviewer APPROVE after 3 blocker fixes (B1: `updateOneCandidate` mutation name, B2: `ON CONFLICT DO NOTHING` on inbound INSERT, B3: PII scrubbed from event_log). Six pre-ship findings in total: lock token mismatch (random suffix in acquire), Error Trigger CAS DEL malformed key (`.params.queryReplacement` raw string), wrong GraphQL endpoint (`/metadata` → `/graphql`), PII in event_log payload, missing idempotency on inbound INSERT, missing calibration gate. T2-13 through T2-17 tracked in `plans/tier-2-followups.md`. Closing arc: `f811dd6` (initial ship) + `4325099` (post-APPROVE cleanup).

## What's next

- **Week 1 — Workflow B (white-collar screening).** Spec at `docs/02-workflows/b-screening.md`.

## What's blocked

(Empty — Week 0 closed with all conditions met.)

## Last backup drill

Last backup drill: superficial 2026-04-29 (script execution + dump output verification only). Production-grade script + full restore drill scheduled per `plans/tier-2-followups.md` (T2-7 Week 4, T2-8 first Monday of Week 2).

## Last credential rotation

Initial credentials set during Week 0 bootstrap.

## Notes

- This file is user-facing — Claude Code should update it at the end of each session.
- Short bullets, not prose. If you have more to say, put it in an ADR or a plan.
