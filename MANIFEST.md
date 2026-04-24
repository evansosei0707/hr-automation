# Bundle Manifest — hr-automation-harness

This bundle contains the complete project harness for the HR Automation system. **No workflow code is written yet** — this is the scaffolding that tells Claude Code how to build the system over the coming weeks.

## What's inside — 64 real files

### Root (3)
- `CLAUDE.md` — The Project Constitution. ~150 lines. Claude reads this at the start of every session.
- `README.md` — For humans.
- `.gitignore`

### `docs/` — the knowledge base (33)

The v3 blueprint, refactored into progressive-disclosure form.

- `INDEX.md` — **the map.** Every other doc is one-line-summarised here.
- `00-foundations/` (4) — philosophy, orchestrator role, infrastructure, Ghana context
- `01-data-model/` (3) — Twenty schema, bookings DB, AI memory strategy
- `02-workflows/` (8) — contracts for Workflows A–H (Communications, White-Collar, Blue-Collar, Scheduling, Social Posting, Reporting, Orchestration, Job Alerts)
- `03-integrations/` (7) — WhatsApp, Meta Graph, X, Telegram, Google Calendar, Claude API, OpenAI Transcribe
- `04-operations/` (5) — observability, backup/DR, Ghana DPA, calibration, runbook
- `05-decisions/` (5) — ADR template + 4 accepted ADRs documenting the Blotato/LinkedIn/holidays/Khaya decisions

### `.claude/` — the agent harness (17)

- `settings.json` — permissions (read-safe commands allowed, mutations asked, dangerous ops denied)
- `agents/` (7) — architect, workflow-builder, schema-designer, tester, doc-gardener, code-reviewer, researcher
- `skills/` (3) — new-workflow, validate-n8n-workflow, weekly-gardening
- `rules/` (3) — n8n-workflows, database-migrations, whatsapp-templates (path-scoped)
- `memory/` (3) — status.md, decisions.md, scratchpad.md

### `plans/` (2)
- `TEMPLATE.md` — copy this for every new feature
- `active-plan.md` — Week 0 validation gate (the current plan)

### `infrastructure/` (4)
- `docker-compose.yml` — full stack: Twenty + Twenty-DB + Bookings-DB + Redis + n8n + Nginx + migrate-bookings one-shot
- `.env.example` — every env var the stack needs, with dummy values
- `nginx/nginx.conf`
- `postgres/init-bookings-db.sql`

### `database/` (1)
- `migrations/V001__create_bookings_core.sql` — the bookings DB bootstrap (interviewer, slot with atomic-claim unique index, booking_event_log, workflow_errors, system_incident, event_log)

### `scripts/` (2)
- `bootstrap.sh` — one-time local setup
- `run-migrations.sh` — idempotent migration runner for the bookings DB (called by the compose migrate-bookings service)

### Empty-but-reserved directories (with `.gitkeep`)
- `n8n-workflows/{communications,candidates,scheduling,social,reporting,orchestration,job-alerts}/` — workflows land here as they're built
- `database/seed/`
- `twenty-schema/objects/` — object definitions land here
- `reference/` — vendor doc snapshots
- `.claude/hooks/` — deterministic gates (pre-commit etc.)

Each of these also has a README explaining what goes in it.

## How to use this bundle

1. **Unzip into your sandbox:**
   ```bash
   cd ~/Sandbox
   unzip ~/Downloads/hr-automation-harness.zip
   cd hr-automation
   git init
   git add -A
   git commit -m "chore: initial harness scaffolding"
   ```

2. **Open it with Claude Code:**
   ```bash
   claude
   ```

3. **Give Claude Code exactly this first instruction:**

   > Read CLAUDE.md. Then read docs/INDEX.md. Then read plans/active-plan.md and .claude/memory/status.md. Do not write code yet. Tell me what you understand and what you'd need from me to begin Week 0.

4. **If Claude Code shows real grip on the project** (cites specific docs correctly, knows the five invariants, can describe Week 0's validation gate), the harness works. Proceed.

5. **If the response is vague,** tighten CLAUDE.md or INDEX.md before going further. That's the whole point of this scaffold — surface that gap early.

## The five non-negotiable invariants (a refresher)

Baked into `CLAUDE.md` and reinforced in every subagent:

1. Never write directly to Twenty's Postgres — use GraphQL only. Bookings live in a separate n8n-owned DB.
2. Never assume Twenty has rollups, formula fields, or action-button webhooks.
3. Redis conversation locks: 60s TTL + Lua heartbeat (15s) + Lua CAS release.
4. No LinkedIn / Blotato in v1 — free native social APIs only.
5. No attempted ASR for Ghanaian local languages — English/Pidgin only; unclear → polite retry → human review queue.

## What this bundle does NOT contain

- Any n8n workflow JSON (those are built during Weeks 2–4)
- Any Twenty object TypeScript definitions (built during Week 1)
- Secrets, credentials, or real `.env` values
- The running stack itself (you run `docker compose up -d` to bring it up)

The point of this bundle is to be the **contract**, not the implementation.

---

**Generated:** 2026-04-24
**Version:** v3.1-harness-initial
