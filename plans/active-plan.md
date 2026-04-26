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

- [ ] **Precondition:** dispatch `researcher` to verify the Twenty v2.1.0 GraphQL metadata API (custom object creation, field types, relations). The original spec was written against a v0.60-era assumption set; v2 may have changed the management API shape. Do not dispatch `schema-designer` until this is confirmed or the spec is updated.
- [ ] Dispatch `schema-designer` with the spec at `docs/01-data-model/twenty-crm-schema.md`
- [ ] Apply all custom objects
- [ ] Create one test Candidate, JobPosting, Application via the Twenty UI and via GraphQL — both paths work

### Phase 3 — Bookings DB (target: day 2)

- [ ] Dispatch `schema-designer` with the spec at `docs/01-data-model/bookings-db.md`
- [ ] Generate `V001__create_bookings.sql`, `V002__create_slot_claim.sql`, `V003__candidate_facts.sql`
- [ ] Apply via `scripts/migrate-bookings-db.sh`
- [ ] Run the concurrency test: two psql sessions attempt to UPDATE the same offered slot. Exactly one succeeds.

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
