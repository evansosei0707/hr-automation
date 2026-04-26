# Plan — Week 0: Validation Gate

**Started:** 2026-04-24
**Spec:** This is the validation gate, not a workflow spec. Its output is "go / no-go for Week 1."
**Owner this session:** human (with Claude Code as pair)
**Status:** In Progress

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

- [ ] **WhatsApp:** webhook reachable; inbound test message received and stored; `consent_request` template submitted (approval may lag into Week 1 — that's fine, the test is submission).
- [ ] **Claude:** `curl` against the API with both models; costs logged.
- [ ] **OpenAI transcribe:** three test audio files (en, pidgin, twi) → expected outcomes.
- [ ] **Meta Graph (FB + IG):** draft-and-immediately-delete a test post on both. Capture returned post IDs.
- [ ] **X:** post + delete a single test tweet.
- [ ] **Telegram:** post to the test channel + delete. (Telegram supports message deletion via `deleteMessage`.)
- [ ] **Google Calendar:** read + write test.

### Phase 5 — Cross-cutting patterns (target: day 5)

- [ ] Redis lock pattern: write a standalone n8n workflow that acquires the conv lock, holds for 45s with heartbeat extending TTL, releases with CAS. Verify another n8n workflow attempting the same lock waits correctly.
- [ ] Observability: one workflow logs a structured event to the `event_log` table; query it back.
- [ ] Backup drill: run `scripts/backup.sh`, wipe DB, restore, query.

### Phase 6 — Go / no-go review

- [ ] All acceptance criteria green or explicitly deferred with a note.
- [ ] Update `.claude/memory/status.md`.
- [ ] If green: set `plans/active-plan.md` to Week 1's plan (to be drafted then) and archive this plan as `plans/20260424-week-0-validation-DONE.md`.
- [ ] If red on a critical item: write an ADR describing the show-stopper and the redesign, then revise the spec and restart relevant parts of Week 0.

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
