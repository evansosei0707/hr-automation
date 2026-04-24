# Documentation Index

The map of all project knowledge. **Open files from here only when a specific task needs them.** Every file is one-line-summarised so you can pick without opening.

## How to use this index

- You are Claude Code, reading this as part of your startup protocol.
- When you need details for a task, look up the relevant section below, open **only that file**, and work from it.
- Do not scan the tree speculatively. The whole point of this index is to keep your context clean.
- If a doc is missing and you need it, say so — do not invent.

---

## 00 — Foundations (read these first when onboarding to the domain)

| File | Read when |
|---|---|
| [`00-foundations/philosophy.md`](00-foundations/philosophy.md) | Establishing project principles, deciding scope trade-offs |
| [`00-foundations/orchestrator-role.md`](00-foundations/orchestrator-role.md) | Understanding what the human operator does vs. what the system does |
| [`00-foundations/infrastructure.md`](00-foundations/infrastructure.md) | Setting up, deploying, or modifying the stack |
| [`00-foundations/ghana-context.md`](00-foundations/ghana-context.md) | Anything Ghana-specific: phone numbers, languages, holidays, compliance |

## 01 — Data Model

| File | Read when |
|---|---|
| [`01-data-model/twenty-crm-schema.md`](01-data-model/twenty-crm-schema.md) | Changing Twenty custom objects, querying Twenty via GraphQL |
| [`01-data-model/bookings-db.md`](01-data-model/bookings-db.md) | Touching the interview-bookings database, scheduling logic |
| [`01-data-model/ai-memory.md`](01-data-model/ai-memory.md) | Designing how Claude remembers a conversation, rolling-summary logic |

## 02 — Workflows (the main features)

| Workflow | Role | Doc |
|---|---|---|
| A — Communications | Handle inbound WhatsApp on any topic | [`02-workflows/a-communications.md`](02-workflows/a-communications.md) |
| B — White-Collar Screening | CV ingestion + AI scoring for office roles | [`02-workflows/b-white-collar.md`](02-workflows/b-white-collar.md) |
| C — Blue-Collar Screening | Structured WhatsApp screening for high-volume roles | [`02-workflows/c-blue-collar.md`](02-workflows/c-blue-collar.md) |
| D — Scheduling | Interview slot offer + atomic claim | [`02-workflows/d-scheduling.md`](02-workflows/d-scheduling.md) |
| E — Social Posting | Fan out a job post to FB, IG, X, Telegram | [`02-workflows/e-social-posting.md`](02-workflows/e-social-posting.md) |
| F — Reporting | Weekly Monday summary to team WhatsApp | [`02-workflows/f-reporting.md`](02-workflows/f-reporting.md) |
| G — Orchestration | Health check, alerting, stuck-task sweeper | [`02-workflows/g-orchestration.md`](02-workflows/g-orchestration.md) |
| H — Job Alerts | Re-engage strong-but-not-selected candidates | [`02-workflows/h-job-alerts.md`](02-workflows/h-job-alerts.md) |

## 03 — Integrations (external APIs)

| File | Read when |
|---|---|
| [`03-integrations/whatsapp-cloud.md`](03-integrations/whatsapp-cloud.md) | Any inbound/outbound WhatsApp work, template approval |
| [`03-integrations/meta-graph-fb-ig.md`](03-integrations/meta-graph-fb-ig.md) | Posting to Facebook or Instagram |
| [`03-integrations/x-api.md`](03-integrations/x-api.md) | Posting to X (Twitter) |
| [`03-integrations/telegram-bot.md`](03-integrations/telegram-bot.md) | Posting to Telegram or receiving Telegram commands |
| [`03-integrations/google-calendar.md`](03-integrations/google-calendar.md) | Pulling holidays or syncing interviewer availability |
| [`03-integrations/claude-api.md`](03-integrations/claude-api.md) | Any Claude call, model selection, cost control |
| [`03-integrations/openai-transcribe.md`](03-integrations/openai-transcribe.md) | Voice-note transcription |

## 04 — Operations

| File | Read when |
|---|---|
| [`04-operations/observability.md`](04-operations/observability.md) | Logging, metrics, alerting |
| [`04-operations/backup-dr.md`](04-operations/backup-dr.md) | Backups, restore drills, disaster recovery |
| [`04-operations/ghana-dpa.md`](04-operations/ghana-dpa.md) | Data protection, consent, retention, right-to-delete |
| [`04-operations/calibration.md`](04-operations/calibration.md) | The 2-week human-review window after launch |
| [`04-operations/runbook.md`](04-operations/runbook.md) | Incident response; "what do I do when X breaks" |

## 05 — Architectural Decisions (ADRs)

Immutable records of *why* we made a choice. Do not edit an ADR after it is accepted; write a new one that supersedes it.

| ID | Title | Status |
|---|---|---|
| [ADR-0001](05-decisions/ADR-0001-drop-blotato.md) | Drop Blotato; use native social APIs | Accepted |
| [ADR-0002](05-decisions/ADR-0002-defer-linkedin.md) | Defer LinkedIn integration | Accepted |
| [ADR-0003](05-decisions/ADR-0003-google-calendar-holidays.md) | Google Calendar as holidays source | Accepted |
| [ADR-0004](05-decisions/ADR-0004-drop-khaya.md) | Drop GhanaNLP Khaya ASR; English/Pidgin only | Accepted |
| [ADR template](05-decisions/ADR-template.md) | — | — |

---

## Reading-order recipes

For common tasks, here is the minimum set of docs to open.

**"Set up the stack on a new machine"**
→ `00-foundations/infrastructure.md`

**"Build Workflow C (blue-collar screening)"**
→ `02-workflows/c-blue-collar.md` → `01-data-model/ai-memory.md` → `03-integrations/whatsapp-cloud.md` → `03-integrations/claude-api.md`

**"Add a new Twenty custom field"**
→ `01-data-model/twenty-crm-schema.md` → (if changing behaviour) the relevant `02-workflows/` file

**"Debug a candidate reply that never got a response"**
→ `04-operations/runbook.md` → `02-workflows/a-communications.md` → `04-operations/observability.md`

**"Audit compliance before go-live"**
→ `04-operations/ghana-dpa.md` → `00-foundations/ghana-context.md`
