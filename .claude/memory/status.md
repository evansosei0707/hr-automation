# Status

Current build state. Updated at the end of every work session.

---

**Last updated:** 2026-05-02
**Current phase:** Week 1 — Workflow C complete; Workflow A routing patch next
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
- ✅ **Week 0 / Phase 5 — Cross-cutting patterns (2026-04-29).** Conv-lock 20/20 PASS via `scripts/test-conv-lock.sh` (min PTTL=48196ms during 45s production-canary call); canonical operational queries with real evidence embedded in `docs/04-operations/observability.md` + runbook §0 cross-reference; backup drill three-DB green (twenty 245KB / bookings 7.8KB / n8n 42KB). Audit finding: original spec missed n8n DB — corrected in backup-dr.md. Closing arc: `6a7bf01`..`3256497` + `ac6f418`.
- ✅ **Week 0 / Phase 6 — Go/no-go review (2026-04-29).** Decision: **GO**. 20 findings reviewed (R1-R5, SD1-SD8, C1-C2, RC1-RC5) → 13 closed in commits → 7 carried forward with T2 tracking items. Full auditable record: `docs/05-decisions/week-0-go-no-go.md`. Closing arc: `5bd25c3`..`53361f9` (5 commits).
- ✅ **Week 0 — CLOSED 2026-04-29.**

- ✅ **Week 1 — Workflow A v1 (2026-04-30 build, 2026-05-01 live test PASSED).** End-to-end confirmed: WhatsApp message in → candidate lookup → consent flow → Claude Sonnet reply → WhatsApp message delivered. Four workflow JSON files: `a-communications.json`, `wa-send.json`, `claude-call.json`, `dpa-handler.json`. V003 migration applied. Tester 14/14 PASS; code-reviewer APPROVE. Live test surfaced five categories of n8n 2.x compatibility bugs (all fixed, rules #14–#23 added to `.claude/rules/n8n-workflows.md`):
  1. **Execute Workflow schema mismatch** — n8n 2.x Execute Workflow typeV 1.3 reads `workflowInputs.value` (resourceMapper), silently ignores `fields.values`. All 13 Execute Workflow nodes converted.
  2. **Set node typeVersion/assignments mismatch** — typeVersion 3 reads `fields.values` (old schema); `assignments` format requires typeVersion ≥ 3.3. `Return Claude Response` and 3 other nodes emitted `{success:true}` (the Postgres INSERT passthrough) until bumped to 3.4. Diagnosed by reading `manual.mode.js` in the container.
  3. **patch-workflow-ids.sh keyword routing** — keyword-based matching misrouted "Generate Reply" (contains 'reply') to WA Send subflow. Replaced with explicit node-name → subflow map.
  4. **n8n 2.x env var access** — `$env.*` silently `undefined` without `N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"` in docker-compose.
  5. **queryReplacement comma-splitting** — user text and stack traces split on commas, corrupting Postgres parameter counts. Array form `={{ [...] }}` bypasses splitting.
  Closing arc: `f811dd6` (initial ship) + `4325099` (post-APPROVE cleanup) + `17080c8` + `29aeb5f` (live-test fixes).

- ✅ **Workflow B design (2026-05-01).** Design note at `docs/02-workflows/b-white-collar-design-v1.md` (status: Ready). OQ-1 resolved — Twenty Application resolvers confirmed at `docs/03-integrations/twenty-application-schema.md` (`de875e2`). OQ-6 resolved — ADR-0010 at `docs/05-decisions/ADR-0010-cv-parser.md` (`8a3ec6e`): n8n "Extract from File" + Claude Sonnet, DPA-clean, no new container. Closing arc: `ce46654` + `de875e2` + `8a3ec6e` + `b0d68ea`.

- ✅ **Workflow B v1 build (2026-05-01).** `n8n-workflows/screening/b-screening.json` (28 nodes) + `database/migrations/V008__screening_inbox.sql` + `a-communications.json` inbox INSERT on both `workflow_reply` and `open_conversation` branches. Rules #19–#24 added. Key fixes during build/test: `alwaysOutputData` at node root level (rule #24), `wa-send` Return Success node, n8n-debug.sh RecursionError fix.

- ✅ **Workflow B v1 live test (2026-05-01) — complete.** Parse failure path proven (empty inbox → no-row exit → ReviewTask). Happy path proven: CV text → Extract Structured Facts (Claude Sonnet) → Score Against Rubric (Claude Sonnet) → score stored in candidate_facts → ReviewTask created → WA Ack sent → inbox row marked processed. Rules #25 added. **Workflow B v1 DONE.**

- ✅ **Workflow C v1 (2026-05-02) — complete.** Blue-collar screening state machine. Architect design note at `docs/02-workflows/c-blue-collar-design-v1.md`; ADR-0011 (`docs/05-decisions/ADR-0011-blue-collar-state-and-trigger.md`). Migrations V009 (blue_collar_screening), V010 (screening_scripts + driver_v1 seed), V011 (trigger_kind constraint). JSON: `n8n-workflows/screening/c-screening.json` (98 nodes, 3 cron contexts: 60s main, 300s Twenty poll, 1800s reminder/withdraw sweep). Tester 5/5 PASS. Eight bugs found and fixed during tester rounds (isEmpty operator, Workflow B row-stealing, collarType null mapping, splitInBatches v3 output semantics, IF boolean routing, withdraw chain resequencing, forward refs on lock keys). Rules #26+ not added — bugs captured in commit messages.
  **Pre-launch blockers carried to T2:** (a) WA templates `screening_reminder_24h` + `screening_withdrawn_72h` need Meta approval (T2-21). (b) Workflow A `workflow_reply` branch needs `trigger_kind='blue_collar_reply'` routing for candidates with active `blue_collar_screening` rows (T2-22). (c) `createCandidateSkillTag` loop deferred — no `skillTagId` source in v1 (T2-23). **Workflow C v1 DONE.**

## What's next

- **Workflow A routing patch** — add `blue_collar_reply` trigger_kind detection to `a-communications.json`'s `workflow_reply` branch (T2-22). Candidates with active `blue_collar_screening` rows must route to Workflow C's reply path.
- **Workflow D architect dispatch** — spec at `docs/02-workflows/d-scheduling.md`. Interview scheduling with atomic slot-claim and Google Calendar write.

## What's blocked

(Empty — Week 0 closed with all conditions met.)

## Last backup drill

Last backup drill: superficial 2026-04-29 (script execution + dump output verification only). Production-grade script + full restore drill scheduled per `plans/tier-2-followups.md` (T2-7 Week 4, T2-8 first Monday of Week 2).

## Last credential rotation

Initial credentials set during Week 0 bootstrap.

## Notes

- This file is user-facing — Claude Code should update it at the end of each session.
- Short bullets, not prose. If you have more to say, put it in an ADR or a plan.
