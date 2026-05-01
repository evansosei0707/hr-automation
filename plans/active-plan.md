# Active Plan — Week 1

**Current work:** Week 1 close-out → then Workflow B
**Spec:** `docs/02-workflows/b-screening.md`
**Status:** Workflow A ✅ complete. Week 1 close-out tasks before Workflow B.

## Week 1 progress

- [x] **Workflow A v1** — DONE. Build 2026-04-30; live test PASSED 2026-05-01. Closing arc: `f811dd6` + `4325099` + `17080c8` + `29aeb5f`. T2-13–T2-17 in `plans/tier-2-followups.md`.
- [x] **Workflow B design** — DONE 2026-05-01. Design note ready at `docs/02-workflows/b-white-collar-design-v1.md`. OQ-1 (Twenty resolvers) and OQ-6 (CV parser, ADR-0010) resolved. Closing arc: `ce46654`..`b0d68ea`.
- [x] **Workflow B build** — DONE 2026-05-01. `b-screening.json` + V008 migration + `a-communications.json` inbox INSERT on both `workflow_reply` and `open_conversation` branches. Rules #19–#24 added.
- [~] **Workflow B v1 live test** — parse failure path ✅ proven 2026-05-01 (empty screening_inbox → no-row exit → parse failure ReviewTask created). Happy path (CV scoring) not yet tested — requires candidate to send actual CV text. Unblocked but deferred.
- [ ] **Next: Workflow B happy path test** OR **Workflow C architect dispatch** — user to decide. Workflow C spec: `docs/02-workflows/c-interview-scheduling.md`.
- [ ] **Week 1 close-out tasks** — T2-18/T2-19 atomic Redis lock upgrade (can run in parallel)

---

# Archived — Week 0: Validation Gate

**Started:** 2026-04-24
**Spec:** This is the validation gate, not a workflow spec. Its output is "go / no-go for Week 1."
**Owner this session:** human (with Claude Code as pair)
**Status:** CLOSED 2026-04-29 — GO decision granted

## Goal

By the end of Week 0, we know the stack works. No workflow code is written. We prove each external dependency before building against it.

## Why this week exists

Every week of implementation we do before verifying the stack is a week of work at risk. The v3 research round surfaced several places where vendor reality could differ from documentation (Twenty custom-object behaviour, WhatsApp template approval timing, X free tier specifics). Week 0 converts unknowns to knowns before they cost us implementation time.

## Acceptance criteria — go to Week 1

- [ ] Local stack (Twenty + n8n + Postgres + Redis + Nginx) running on WSL via Docker Compose, all health checks green.
- [ ] Twenty custom objects (Candidate, JobPosting, Application, Interview, SkillTag, CandidateSkillTag, Holiday, ReviewTask, SocialPost, WorkflowError) created and verified via GraphQL.
- [ ] Bookings DB migrations V001–V003 applied successfully; atomic slot-claim SQL tested with two concurrent inserts (one must fail).
- [ ] WhatsApp Cloud API test: verify phone number registered, webhook receives a test message, `consent_request` template submitted for approval.
- [ ] Claude API test: Sonnet + Haiku both respond; cost logged to `ai_call_log`.
- [ ] OpenAI transcribe test: sample English voice note transcribes cleanly; sample Pidgin transcribes adequately; sample Twi voice note is routed to manual review without being transcribed.
- [ ] Meta Graph test: post a throwaway draft to the firm's Facebook Page via API; verify external post ID returned.
- [ ] X API test: post a throwaway tweet via API; confirm free-tier works.
- [ ] Telegram test: post to the firm's channel via Bot API; confirm delivery.
- [ ] Google Calendar test: read Ghana holiday calendar, write a test event on an interviewer calendar.
- [ ] Redis lock heartbeat pattern validated with a 45-second synthetic Claude call.
- [ ] Backup drill: take a DB dump, wipe the DB, restore from dump, query successfully.

## Preconditions

- [ ] Firm has a Meta Business account with a Facebook Page, Instagram Business account, and WhatsApp Business account linked.
- [ ] Firm has an X account and has applied for Developer access.
- [ ] Firm has a Telegram account and created a bot via @BotFather.
- [ ] Firm has a Google Workspace or Gmail account for the service calendar.
- [ ] Developer has a Hetzner / DigitalOcean VPS ready for staging (can come at the end of Week 0).

## Phases

### Phase 1 — Local bring-up (target: day 1)

- [x] `cd ~/Sandbox/hr-automation`
- [x] `cp infrastructure/.env.example infrastructure/.env` and fill in local values
- [x] `./scripts/bootstrap.sh` or its manual equivalent
- [x] `docker compose -f infrastructure/docker-compose.yml up -d`
- [x] Hit Twenty, n8n, and a DB `SELECT 1` — all respond

**Phase 1 done 2026-04-26.** All 7 services healthy: hr-twenty-db, hr-bookings-db, hr-redis, hr-twenty, hr-twenty-worker, hr-n8n, hr-nginx. migrate-bookings exited 0; V001 applied. Twenty `/healthz` and `/graphql` return 200; n8n `/healthz` returns 200; bookings DB SELECT 1 returns 1. Scaffolding gaps surfaced and fixed — see decisions.md for the list.

### Phase 2 — Twenty schema (target: day 2)

- [x] **Precondition:** dispatch `researcher` to verify the Twenty v2.1.0 GraphQL metadata API (custom object creation, field types, relations). The original spec was written against a v0.60-era assumption set; v2 may have changed the management API shape. Do not dispatch `schema-designer` until this is confirmed or the spec is updated.
- [x] Dispatch `schema-designer` with the spec at `docs/01-data-model/twenty-crm-schema.md`
- [x] Apply all custom objects
- [x] Create one test Candidate, JobPosting, Application via the Twenty UI and via GraphQL — both paths work

**Phase 2 done 2026-04-26.** 11/11 tester criteria green. Closed via 8 commits (`a532774`..`7ae9083`).

The journey: four RED rounds before tester GREEN, each surfacing a real Twenty enforcement rule we'd been guessing at. One-liner per round:

- **R1 — reserved object name `job` + apply-script networking.** `job`/`jobs` is in Twenty's `RESERVED_METADATA_NAME_KEYWORDS`; apply script also had a wrong REST query param + jq path + assumed-published bookings-db port. Fixed in `54ca502` (rename to `jobPosting`) and `bd05047` (doc rename to match).
- **R2 — SELECT option values must be UPPER_SNAKE_CASE.** All 16 SELECT fields had lowercase values; fixed via Python rewrite in `8a6c88c` (which also added `scripts/reset-twenty-schema.sh` for partial-state recovery).
- **R3 — SELECT `defaultValue` must be SQL-literal single-quoted, not JSON-encoded.** Researcher's initial guidance was wrong on this; corrected with explicit markers + verified against `serialize-default-value.util.ts:66-70`. Fixed in `37e7934`, which also introduced `scripts/audit-twenty-schema.py` (the local mirror of Twenty's validation rules) and the apply-script's pre-apply audit + precondition gate.
- **R4 — code-reviewer round (post-tester-GREEN).** Spec drift on auto-`name` field type (TEXT, not FULL_NAME) and data-API resolver naming (`createCandidate`, NO `One` infix); plus a real bug in the precondition gate jq path that tester missed because tester ran from clean state. Fixed in `c90db9c`. Tier 1.5 audit-coverage extension (NUMERIC + RATING; MULTI_SELECT correctness) shipped in `7ae9083`.

The audit script is the structural antibody: future migration files are format-checked locally before commit and apply, instead of via 15-minute tester round-trips. Tier 2 follow-ups (pre-commit hook wiring, dead-code cleanup, IMPLEMENTATION_NOTES staleness annotations, composite-default validation, README applied_by drift) tracked in `plans/tier-2-followups.md`.

### Phase 3 — Bookings DB (target: day 2)

- [x] V001 (`V001__create_bookings_core.sql`) applied during Phase 1 setup — `interviewer`, `slot` (with `uq_slot_no_double_claim` partial unique index), `booking_event_log`, `workflow_errors`, `system_incident`, `event_log`.
- [~] ~~Generate `V002__create_slot_claim.sql`~~ — **superseded.** Atomic claim is an inline UPDATE pattern (see `docs/01-data-model/bookings-db.md` "The atomic claim pattern"), not a stored function. V001's table + partial unique index are the only schema artifacts; the SQL pattern lives in workflow D's n8n nodes. No V002 migration artifact needed.
- [→] ~~Generate `V003__candidate_facts.sql`~~ — **deferred to Workflow C build** (Week 2-3). Per "schema close to workflow" principle: carrying an unused table for two weeks risks the spec evolving and us migrating a shape that doesn't match the final design. Re-attached as a Workflow C precondition; not a Phase 3 deliverable.
- [x] Run the concurrency test: two psql sessions attempt to UPDATE the same offered slot. Exactly one succeeds. **Done 2026-04-26 via `scripts/test-bookings-concurrency.sh`** — 10/10 rounds (5 offer-race + 5 claim-race), both safety legs verified, loser-cleanliness asserted (no error, no rollback, no serialization noise on the WHERE-guard's loser path).

**Phase 3 done 2026-04-26.** Concurrency-test-only scope per user direction. Test run output shows nondeterministic distributions (offer 2A/3B, claim 4A/1B) — real race, not fixed-order. Closed via `8521fda` (test script) + this commit.

### Phase 4 — External API vouchers (target: days 3–5)

Each "voucher" is a minimal working test that proves we can call the API from our environment.

- [x] **WhatsApp:** webhook reachable; inbound test message received and stored. `9f4241d`. Real Ghana traffic verified end-to-end (event_log row 13, +233 532 751 040, HMAC-validated). `consent_request` template submission deferred to Week 1+ as planned.
- [x] **Claude (Anthropic):** Sonnet + Haiku Messages API, costs logged to `ai_call_log` (V005 migration). `68210bd`. Total cost of voucher run: $0.000184 across both models.
- [~] ~~**OpenAI transcribe:**~~ `e5a9b16` — script committed, run BLOCKED on Ghana-region card refusal. **Superseded by Groq Whisper per [ADR-0006](../docs/05-decisions/ADR-0006-groq-whisper-pivot.md)**: `scripts/voucher/groq-transcribe.sh` green at `e0fd320` covers the transcription wire shape that the original OpenAI bullet asked for.
- [x] **Meta Graph (FB):** `scripts/voucher/meta-fb.sh`, `d561219`. Composite post id captured + deleted via `published: false` draft path. Three test audio files (en/pidgin/twi) testing was reframed: voucher proves wire shape only; real-Pidgin quality testing deferred to Workflow A build per Tier 2 item T2-6.
- [→] ~~**Meta Graph (IG):**~~ deferred per [ADR-0007](../docs/05-decisions/ADR-0007-defer-instagram.md). Voucher script `scripts/voucher/meta-ig.sh` committed (`d561219`) and skip-gates on empty `META_IG_USER_ID`; runnable the moment the link unblocks.
- [→] ~~**X:**~~ deferred per [ADR-0008](../docs/05-decisions/ADR-0008-defer-x.md). Free-tier developer access pending since 2026-04-27. 30-day re-trigger at 2026-05-27.
- [x] **Telegram:** `scripts/voucher/telegram.sh`, `79a93d2`. Test message posted to channel; HTTP 200 + `result.message_id` captured.
- [x] **Google Calendar:** `scripts/voucher/google-calendar.sh`, `79a93d2`. 26 events read for 2026; Founder's Day on 2026-09-21 verified (post-2019-reform date, not August).
- [x] **Groq Whisper:** added per ADR-0006. `scripts/voucher/groq-transcribe.sh`, `e0fd320`. espeak-ng fixture transcribed; pipeline proven.

**Phase 4 done 2026-04-29.** 6 active green vouchers, 1 parked-superseded (OpenAI Whisper, ADR-0006), 2 deferred via ADRs (Instagram/ADR-0007 structural Meta refusal, X/ADR-0008 free-tier access pending). Workflow E v1 ships with 2 channels (FB + Telegram). Three structural antibodies landed alongside the vouchers: `scripts/audit-twenty-schema.py` (Phase 2 byproduct, mirrors Twenty's metadata validation locally), `.claude/rules/n8n-workflows.md` rules #11–#13 (ReviewTask invariant, Code-node stdlib gating, Postgres NOT-NULL binding cross-check), and the Nginx default_server pattern + `NODE_FUNCTION_ALLOW_BUILTIN=crypto` env config that unblocks any future webhook handler. Closing arc: 9 commits across `42680aa`..`65f8935`.

### Phase 5 — Cross-cutting patterns (target: day 5)

- [x] Redis lock pattern: scripted bash + redis-cli harness (not an n8n workflow — same property, simpler vehicle) acquires the conv lock with `SET NX PX 60000`, holds for 45s with Lua CAS PEXPIRE heartbeat every 15s, releases with Lua CAS DEL. Four scenarios × 5 rounds = 20/20 PASS, including the foundational stale-heartbeat-after-takeover subtle-bug catcher (refinement #2: deterministic 0.2s gap so we test the takeover path, not the empty-key path). `scripts/test-conv-lock.sh`, commit `6a7bf01`.
- [x] Observability: surveyed live `event_log` + `workflow_errors` content, authored canonical operational queries in `docs/04-operations/observability.md` organized by ops scenario (last-hour / errors / execution-trace / throughput / AI-cost / open-incidents), embedded real query outputs as evidence, added §0 cross-reference in `docs/04-operations/runbook.md`. Commit `852ffd2`.
- [x] Backup drill: scope reduced to local-only verification per session decision (full-restore drill is a half-day exercise — deferred to Tier 2 item T2-8, target first Monday of Week 2). `scripts/backup-databases.sh` runs three pg_dumps (twenty, bookings, n8n) → gzip → timestamped local dir. 2026-04-29 13:20Z run: twenty 245KB / 0.32s, bookings 7.8KB / 0.22s, n8n 42KB / 0.22s, all green. **Audit finding:** original spec inventory was missing the n8n internal DB; corrected in `docs/04-operations/backup-dr.md` (three-DB inventory, hr- container prefixes, explicit Redis-ephemeral statement, config-driven .env path). Production script (cron + B2 + rotation + alerting) deferred to T2-7 (target Week 4). Commit `3256497`.

**Phase 5 done 2026-04-29.** Three cross-cutting patterns proven; closing arc `6a7bf01..3256497`. The conv-lock test catches four bug classes including the foundational "heartbeat extends any lock by key" via S4. The observability queries are operations-ready with real evidence — every embedded output is from running the same query against the live DB. The backup drill surfaced a real spec gap (n8n DB missing from inventory) and produced restorable artifacts; the wider restore-path verification is scoped to T2-8. Scope reductions on tasks 1 (bash harness instead of n8n workflow) and 3 (drill-only, no restore) were both deliberate cost/value calls — full-fidelity proofs of the same invariants without the half-day workflow-builder dispatch or the half-day restore exercise.

### Phase 6 — Go / no-go review

- [x] All acceptance criteria green or explicitly deferred with a note.
- [x] Update `.claude/memory/status.md`.
- [x] Decision: **GO**. Full auditable record in `docs/05-decisions/week-0-go-no-go.md`. Commit `53361f9`.

**Week 0 closed 2026-04-29.** GO decision granted with all four conditions met (Items A/B/C + close-out fix-ups). 20 findings reviewed across 6 categories (R1-R5, SD1-SD8, C1-C2, RC1-RC5) — 13 closed in commits (`5bd25c3`, `8759b6c`, `8117c29`), 7 carried forward into T2 tracking items (`1980c4c`). Week 1 begins with an `architect` dispatch for Workflow A v1; dispatch order documented in go/no-go §6.

## Out of scope

- Any workflow implementation (that's Week 2+).
- UI work.
- LinkedIn anything.

## Open questions

- How fast will WhatsApp template approvals come back? If >48h, we continue Week 0's other work in parallel.
- Does the firm's Instagram account permit API-driven publishing? (Requires Business account, not Creator. Verify in Phase 4.)

## Log

```
2026-04-24 — scaffolded; ready to begin Phase 1
```

## Close-out

See the parent "go / no-go" in Phase 6.
