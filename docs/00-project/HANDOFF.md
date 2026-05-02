# Project Handoff — HR Automation

**Last updated:** 2026-05-02
**Status:** Week 1 in progress. Workflows A + B + C live. Workflow A routing patch next, then Workflow D.
**Repo:** `github.com/evansosei0707/hr-automation` (branch: `main`, user: `eofrimpong-collab`)

---

## What we are building

A WhatsApp-first recruitment automation system for a small Ghanaian HR firm. Candidates apply for jobs by sending a WhatsApp message. The system handles the entire intake pipeline — consent, screening, interview scheduling, social media posting, reporting, and re-engagement of strong-but-not-selected candidates — with minimal human intervention. The Operations Lead in Accra is the primary user; they interact via Twenty CRM and WhatsApp.

**Key constraints:**
- All candidate data stays in Ghana (DPA rule — no SaaS CV parsing, no data sent to non-Ghana clouds)
- WhatsApp is the only candidate-facing channel
- Ghanaian Pidgin and English are the two languages; local-language voice notes go to human review
- All AI output is reviewed by humans during a two-week calibration window post-launch

---

## Tech stack

| Component | Version | URL (local) |
|-----------|---------|-------------|
| Twenty CRM | v2.1.0 | http://localhost:3000 |
| n8n | 1.85.0 (2.18.5 in compose) | http://localhost:5678 |
| Postgres | 16 | bookings-db: `hr-bookings-db:5432`, Twenty DB: `hr-twenty-db:5432` |
| Redis | 7 | `hr-redis:6379` |
| Nginx | latest | http://localhost:80 |
| WSL2 | Ubuntu on Windows | host: `devops@...` |
| Docker Compose | — | `infrastructure/docker-compose.yml` |

**ngrok** tunnels `localhost:80` to a public URL for Meta (WhatsApp) webhooks. Must be running for inbound WhatsApp to work. The public URL is set in Meta Business Manager and in `infrastructure/.env` as `WEBHOOK_BASE_URL`.

**n8n database:** n8n stores its internal state in the bookings Postgres DB (separate schema/database called `n8n`, user `n8n_bookings`). Not the Twenty DB.

**AI models in use:**
- Claude Sonnet 4.x — primary reasoning (CV extraction, scoring, reply generation)
- Claude Haiku 4.x — lightweight tasks (intent classification, answer validation)
- Groq `whisper-large-v3-turbo` — voice note transcription (English + Pidgin only; per ADR-0006)

---

## Architecture — 8 workflows

| ID | Name | Collar | Status | Spec |
|----|------|--------|--------|------|
| **A** | Communications | — | ✅ Live (proven 2026-05-01) | `docs/02-workflows/a-communications.md` |
| **B** | White-Collar Screening | White | ✅ Live (proven 2026-05-01) | `docs/02-workflows/b-white-collar.md` |
| **C** | Blue-Collar Screening | Blue | ✅ Live (proven 2026-05-02) | `docs/02-workflows/c-blue-collar.md` |
| **D** | Interview Scheduling | — | ⬜ Not started | `docs/02-workflows/d-scheduling.md` |
| **E** | Social Posting | — | ⬜ Not started | `docs/02-workflows/e-social-posting.md` |
| **F** | Reporting | — | ⬜ Not started | `docs/02-workflows/f-reporting.md` |
| **G** | Orchestration / Watchdog | — | ⬜ Not started | `docs/02-workflows/g-orchestration.md` |
| **H** | Job Alerts / Re-engagement | — | ⬜ Not started | `docs/02-workflows/h-job-alerts.md` |

### What each workflow does

**A — Communications:** The front door. Receives all WhatsApp inbound events, runs dedup, acquires a per-candidate Redis conversation lock, classifies intent (consent / DPA / open_conversation / workflow_reply / distress / retype / opt_out), routes to the appropriate handler, calls Claude Sonnet for free-form replies, sends outbound via WA Send subflow, enqueues to `screening_inbox` for B/C processing. All candidates enter through here.

**B — White-Collar Screening:** Polls `screening_inbox` for unprocessed rows. Fetches the candidate's CV text from `conversation_message`. Calls Claude Sonnet twice: (1) Extract Structured Facts → `candidate_facts`, (2) Score Against Rubric → `Application.score` + `scoreBreakdown`. Creates a ReviewTask. Sends a WhatsApp acknowledgement. Marks the inbox row processed.

**C — Blue-Collar Screening:** State-machine Q&A over WhatsApp. No CV needed. Sends one structured question at a time, validates answers (Claude Haiku for free text, regex for structured types), scores the completed set, tiers the candidate. Design note: `docs/02-workflows/b-white-collar-design-v1.md` is the model; C is next to be designed.

**D — Scheduling:** Offers 2–3 interview slots to shortlisted candidates. Atomically claims the chosen slot (V-migration partial-unique-index + WHERE-guard pattern). Creates a Twenty Interview record. Books the interviewer's Google Calendar. Sends reminders at 24h and 2h.

**E — Social Posting:** Fans a job post out to Facebook (confirmed working), Telegram (confirmed working), Instagram (deferred — ADR-0007 Meta structural refusal), X (deferred — ADR-0008 free-tier access pending). One `SocialPost` record in Twenty triggers posts to all live channels.

**F — Reporting:** Monday 07:00 Accra cron. Pushes a formatted weekly summary (pipeline volume, applications, collar split, screening results, AI cost) to the staff WhatsApp channel.

**G — Orchestration:** 5-minute cron supervisor. Sweeps expired slot offers, alerts on unacknowledged errors, checks service health, monitors API budget pace, watches for stuck conversations.

**H — Job Alerts:** On a new JobPosting going open, finds candidates who applied for a similar role in the last 6 months and were strong but not selected. Sends a personalised re-engagement WhatsApp. On YES reply, creates a fast-track Application and ReviewTask.

---

## What's done

### Week 0 (2026-04-26 to 2026-04-29) — CLOSED, GO decision

1. **Local bring-up** — All 7 Docker services healthy (Twenty, n8n, Postgres ×2, Redis, Nginx, migrate-bookings). All health checks green.
2. **Twenty schema** — 10 custom objects applied: Candidate, JobPosting, Application, Interview, SkillTag, CandidateSkillTag, Holiday, ReviewTask, SocialPost, WorkflowError. Validated via `scripts/audit-twenty-schema.py`.
3. **Bookings DB concurrency** — 10/10 rounds PASS on atomic slot-claim pattern. V001 migration applied.
4. **External API vouchers** — 6 active green: WhatsApp webhook (real Ghana traffic verified, HMAC-validated), Claude Sonnet+Haiku, Meta FB, Groq Whisper, Telegram, Google Calendar. 2 deferred: Instagram (ADR-0007), X (ADR-0008).
5. **Cross-cutting patterns** — Redis conv-lock 20/20 PASS (45s canary), observability queries with live evidence, backup drill (three DBs: twenty 245KB, bookings 7.8KB, n8n 42KB).
6. **Go / no-go review** — GO. 20 findings reviewed; 13 closed; 7 in T2.

### Week 1 (2026-04-30 to 2026-05-01) — CLOSED

**Workflow A v1** (build 2026-04-30, live test PASSED 2026-05-01):
- End-to-end: WhatsApp message in → candidate lookup → consent flow → Claude Sonnet reply → WhatsApp delivery
- JSON files: `a-communications.json`, `wa-send.json`, `claude-call.json`, `dpa-handler.json`
- V003 migration applied (`candidate_facts` table)
- Five categories of n8n 2.x bugs fixed and codified as rules #14–#23

**Workflow B v1** (build + test 2026-05-01):
- Design note: `docs/02-workflows/b-white-collar-design-v1.md`; ADR-0010 (CV parser: n8n Extract from File + Claude Sonnet)
- JSON file: `b-screening.json` (28 nodes)
- V008 migration applied (`screening_inbox` table)
- `a-communications.json` enqueues on both `workflow_reply` AND `open_conversation` branches
- Happy path proven: CV text → Extract Facts → Score → `candidate_facts` updated → ReviewTask created → WA Ack → inbox marked processed
- Parse-failure path proven: empty inbox → no-row → ReviewTask for manual review
- Rules #24–#25 added

**Workflow C v1** (build + test 2026-05-02):
- Design note: `docs/02-workflows/c-blue-collar-design-v1.md`; ADR-0011 (dedicated state table + dual-trigger)
- JSON file: `c-screening.json` (98 nodes, 3 cron contexts: 60s main, 300s Twenty poll, 1800s reminder/withdraw sweep)
- Migrations V009 (`blue_collar_screening`), V010 (`screening_scripts` + `driver_v1` seed), V011 (trigger_kind constraint)
- Tester 5/5 PASS. Eight bugs fixed across 4 tester rounds (isEmpty operator, splitInBatches v3 output semantics, IF boolean routing, withdraw chain sequencing, forward-reference lock keys)
- **3 pre-launch blockers (T2):** WA template approvals (T2-21), Workflow A `blue_collar_reply` routing (T2-22), SkillTag loop deferred (T2-23)

---

## What's next

1. **Workflow A routing patch** (T2-22) — add `blue_collar_reply` trigger_kind detection to `a-communications.json`. In the `workflow_reply` branch, check `blue_collar_screening` for an active row for `candidate_id`; if found, insert into `screening_inbox` with `trigger_kind='blue_collar_reply'`. Without this, blue-collar candidates' answers are not routed to Workflow C.
2. **Workflow D architect dispatch** — spec at `docs/02-workflows/d-scheduling.md`. Interview scheduling with atomic slot-claim (V001 partial-unique-index pattern) and Google Calendar write. Dispatch `architect` before building.
3. **WA template submissions** (T2-21) — submit `screening_reminder_24h` and `screening_withdrawn_72h` to Meta Business Manager. Workflow C is blocked from sending real outbound messages until these are approved.
4. **Workflow E** — social posting (FB + Telegram confirmed, IG/X deferred per ADR-0007/0008).
5. **Workflows F, G, H** — reporting, orchestration/watchdog, job alerts.

---

## Critical invariants — never break these

From `CLAUDE.md`. Violating any of these is a bug.

1. **Never write directly to Twenty's Postgres database.** All Twenty reads/writes go through Twenty's GraphQL API. The bookings DB (`hr-bookings-db`) is the only Postgres database n8n writes to directly.
2. **Never assume Twenty has rollups, formula fields, or action-button webhooks.** Compute derived fields in n8n. Trigger server-side logic via Manual-triggered workflows.
3. **Redis conversation locks are 60s TTL.** v1 uses 180s flat (no heartbeat) due to n8n 1.85.0 sequential model — CAS DEL on all 6 exit paths preserves the safety property. True Lua CAS heartbeat is T2-12 (post-Week-1).
4. **Social posting uses free native APIs only.** Meta Graph (FB only at launch), Telegram. No LinkedIn, no Blotato.
5. **Ghanaian local-language voice notes are not auto-transcribed.** Groq handles English + Pidgin. Local-language (Twi, Ga, etc.) → human review queue. Typed local-language text passes directly to Claude.

---

## Key files — read in this order

| Priority | File | Why |
|----------|------|-----|
| 1 | `CLAUDE.md` | Project constitution — invariants, delegation routing, style |
| 2 | `.claude/rules/n8n-workflows.md` | 25 rules for n8n workflow construction — read before touching any JSON |
| 3 | `.claude/memory/status.md` | Current build state, what's done, what's next |
| 4 | `plans/active-plan.md` | Current active work item with acceptance criteria |
| 5 | `plans/tier-2-followups.md` | T2 backlog — items that aren't blocking but must not be forgotten |
| 6 | `docs/02-workflows/<letter>-*.md` | Spec for the workflow being built |
| 7 | `docs/02-workflows/<letter>-*-design-v1.md` | Design note for built workflows (A, B) — key decisions |
| 8 | `docs/05-decisions/ADR-*.md` | Decision records — consult before changing any architectural choice |
| 9 | `docs/INDEX.md` | Full map of all project knowledge |

**Do NOT open `docs/` speculatively.** Open only the spec for the current task. The context window is a finite resource.

---

## Key scripts

```
./scripts/n8n-reimport.sh [workflow-file.json]
```
Patches subflow IDs, validates JSON, then PUTs to n8n REST API. Always run this after editing a workflow JSON rather than using the n8n UI import. Strips read-only fields (active, meta, tags, id, versionId, updatedAt, createdAt) before PUT.

```
./scripts/patch-workflow-ids.sh
```
Rewrites all Execute Workflow node references to use current n8n workflow IDs. Must be run before `n8n-reimport.sh` when any subflow has been re-imported and its ID changed. Maintains an explicit node-name → subflow-ID map (rule #21).

```
./scripts/n8n-debug.sh <command>
```
Diagnostic tool. Commands:
- `executions` — last 10 executions with status, workflow name, duration
- `execution <id>` — all nodes that ran in one execution + error details (reads `execution_data` table directly — n8n 2.x REST returns empty runData)
- `last-error` — details of the most recent failed execution
- `workflow-status` — all workflows with active/archived state
- `cleanup` — delete all archived workflow versions

```
./scripts/migrate-bookings-db.sh
```
Applies any unapplied V-migrations from `database/migrations/` against the bookings DB. Run this after adding a new migration file.

```
./scripts/validate-n8n-workflow.sh <file.json>
```
Must pass before committing any workflow JSON. Run by `n8n-reimport.sh` automatically.

```
./scripts/backup-databases.sh
```
pg_dump of all three DBs (twenty, bookings, n8n) to a timestamped local directory.

```
./scripts/audit-twenty-schema.py
```
Local mirror of Twenty's metadata validation rules. Run before applying any Twenty schema migration.

---

## Active infrastructure state

```
docker compose -f infrastructure/docker-compose.yml ps
```
Expected: 7 services running — `hr-twenty-db`, `hr-bookings-db`, `hr-redis`, `hr-twenty`, `hr-twenty-worker`, `hr-n8n`, `hr-nginx`.

**ngrok** must be running for inbound WhatsApp. After `ngrok http 80`, update `WEBHOOK_BASE_URL` in `infrastructure/.env` and re-register in Meta Business Manager if the URL changed.

**n8n credentials** are stored in n8n's internal DB (not in `.env`). They do not appear in workflow JSON exports. The encryption key is `N8N_ENCRYPTION_KEY` in `infrastructure/.env` — must match what's in the DB or all credentials break on restore.

**Bookings DB migrations applied:** V001 (core tables), V003 (candidate_facts), V004 (twenty_schema_migrations), V005 (ai_call_log), V008 (screening_inbox), V009 (blue_collar_screening), V010 (screening_scripts), V011 (trigger_kind constraint). Check with:
```
docker exec hr-bookings-db psql -U n8n_bookings -d bookings -c "SELECT version, description FROM schema_migrations ORDER BY version;"
```

---

## Working patterns

### The build cycle

1. **Architect dispatch** (`architect` agent) for any non-trivial design decision → ADR in `docs/05-decisions/`
2. **Schema dispatch** (`schema-designer`) for new bookings DB tables → migration file in `database/migrations/`
3. **Build** (`workflow-builder`) → workflow JSON in `n8n-workflows/<category>/`
4. **Test** (`tester`) → must be GREEN before code review
5. **Review** (`code-reviewer`) → must APPROVE before marking DONE
6. **Reimport** → `./scripts/n8n-reimport.sh` (patch IDs first if subflows changed)
7. **Live test** → manually trigger, inspect with `n8n-debug.sh execution <id>`

### Model selection

- `architect` agent → **Opus** (complex trade-off analysis)
- `workflow-builder`, `tester`, `code-reviewer`, `schema-designer` → **Sonnet** (default)
- `researcher` → Sonnet
- For Claude calls inside n8n workflows → Claude Sonnet for reasoning, Haiku for validation/classification

### n8n workflow JSON conventions

All 25 rules are in `.claude/rules/n8n-workflows.md`. The most operationally critical:
- **Rule #18**: `queryReplacement` array form `={{ [v1, v2] }}` for any user text or error strings (comma-split bug)
- **Rule #19**: Execute Workflow uses `workflowInputs.value` (resourceMapper), not `fields.values`
- **Rule #20**: Set nodes need `typeVersion: 3.4` for `assignments` format
- **Rule #24**: `alwaysOutputData: true` goes at node root level, not inside `parameters.options`
- **Rule #25**: New workflow files referencing subflows must be added to `patch-workflow-ids.sh`

### Commit hygiene

- Commit after every meaningful milestone (not just at end of session)
- Tag commits with component prefix: `feat(workflow-b)`, `fix(wa-send)`, `chore(debug)`, `docs(adr-0010)`
- Never commit workflow JSON with credentials (pre-commit hook blocks it)
- Run `./scripts/validate-n8n-workflow.sh` before committing any workflow JSON

---

## T2 backlog — must not be forgotten

| ID | Summary | When |
|----|---------|------|
| T2-6 | Pidgin transcription quality check with real Ghanaian audio | Pre-Workflow-A voice-note handling |
| T2-7 | Production backup script (cron + B2 + rotation + alerting) | Week 4 |
| T2-8 | Full backup-restore drill (live RTO measurement) | First Monday Week 2 |
| T2-9 | Rules consolidation pass (RC1–RC5: nginx, docker bind-mount, webhook rawBody, Twenty resolver naming, reserved names) | After Week 1 close |
| T2-12 | True conv-lock heartbeat (Lua CAS PEXPIRE every 15s) | Post-Week-1 / n8n queue mode |
| T2-13 | ReviewTask error path when candidateId missing | Post-Week-1 |
| T2-14 | wa-send `Force Template — Window Expired` wrong default template | Pre-launch |
| T2-15 | Outbound messages not stored in `conversation_message` | Pre-launch (DPA compliance) |
| T2-16 | Budget Gate — Workflow A exempt from $10/day cap (spam risk) | Pre-launch |
| T2-17 | `ai_call_log.prompt_excerpt` — reduce from 200 to 40 chars (PII minimisation) | Pre-launch |
| T2-18 | Atomic Redis lock acquire (SETNX — needs `executeCommand` or n8n upgrade) | Post-Week-1 |
| T2-19 | Atomic Redis lock release (Lua CAS DEL) | Bundle with T2-18 |
| T2-20 | Soft-deleted candidate re-messages → null candidateId (pre-launch blocker once DPA erasure live) | Pre-launch |
| T2-21 | WA template approvals for Workflow C (`screening_reminder_24h` + `screening_withdrawn_72h`) | Pre-launch (C) |
| T2-22 | Workflow A — route `blue_collar_reply` trigger_kind to Workflow C reply path | **Immediate** |
| T2-23 | Workflow C — SkillTag loop deferred (no `skillTagId` source in v1) | Post-launch Week 2 |

Full details: `plans/tier-2-followups.md`

---

## Known production concerns

### Soft-delete trap (T2-20) — pre-launch blocker

If a candidate is soft-deleted in Twenty (e.g. DPA erasure) and then messages again: `Resolve Candidate` returns empty, `Create Candidate` fails with unique constraint, both fallbacks evaluate to null, downstream writes silently store null candidateId. Fix: add IF node after `Create Candidate` to detect failure and re-query with `deletedAt: { is: NOT_NULL }` filter. Must ship before DPA erasure is enabled for real traffic.

### Conv-lock heartbeat (T2-12) — accuracy concern

CLAUDE.md invariant #3 specifies 60s TTL + 15s Lua heartbeat. Current v1 uses 180s flat TTL (no heartbeat) due to n8n 1.85.0 sequential execution model. Safety property preserved by CAS DEL on all exit paths; orphan-lock window is 180s vs 60s. Not a crash risk, but should be upgraded when n8n moves to queue mode.

### n8n version (not in T2) — informational

Running n8n 1.85.0 (via docker image tagged 2.18.5). Several workarounds are in place for this version: no `executeCommand` Redis support (T2-18/19), 2-step lock patterns, no true parallelism in execution chains. If n8n is upgraded, re-check all 25 rules — several are version-specific.

### Force Template — Window Expired (T2-14) — wrong default

`wa-send.json` `Force Template — Window Expired` node has no outgoing connection and defaults to `still_interested_10d` (re-engagement template) for callers that pass no `templateName`. Multiple callers should never use a re-engagement template as fallback. Not triggered until a 24h service window has expired; benign for now but semantically wrong.

---

## ADR index (most important)

| ADR | Decision |
|-----|---------|
| ADR-0001 | Drop Blotato — use free native social APIs |
| ADR-0002 | Defer LinkedIn — no API path without paid approval |
| ADR-0003 | Google Calendar as Ghana holiday source of truth |
| ADR-0004 | Single VPS architecture (vs. separate services) |
| ADR-0005 | Twenty v0.60→v2.1.0 API migration — ReviewTask MORPH_RELATION → two MANY_TO_ONE |
| ADR-0006 | Groq Whisper pivot (replaces OpenAI Whisper — Ghana card refusal) |
| ADR-0007 | Defer Instagram (Meta structural refusal for account link) |
| ADR-0008 | Defer X (free-tier developer access pending; retry 2026-05-27) |
| ADR-0009 | Redis namespace strategy — `hra:` prefix, `hra:conv:`, `hra:dedupe:` |
| ADR-0010 | CV parser: n8n Extract from File + Claude Sonnet (DPA-safe, no new container) |
| ADR-0011 | Blue-collar screening: dedicated `blue_collar_screening` state table + dual-trigger (screening_inbox + Five-min Twenty poll) |

Full records: `docs/05-decisions/`

---

## How to update this document

At the end of each session that changes the project state, update:
- The "Last updated" date at the top
- The workflow status table (A–H)
- "What's done" — add a line for the completed phase
- "What's next" — reflect current next task
- T2 table — mark closed items (cite commit), add new items

Keep it dense. If more than 2–3 lines are needed on a topic, write an ADR or design note and link here.
