# HR Automation — Project Constitution

Claude Code reads this file at the start of every session. Keep it short. Point to the truth; do not duplicate it.

## What this project is

An HR automation system for a small Ghanaian HR firm. It handles candidate WhatsApp conversations, CV screening, interview scheduling, social media posting, reporting, and re-engagement of strong-but-not-selected candidates. The stack is self-hosted on a single VPS: Twenty CRM, n8n, Postgres, Redis, behind Nginx. AI reasoning is provided by Claude + OpenAI Whisper. Target users: the HR firm's operations team in Accra.

## Read-first protocol

At the start of every session, read exactly these files, in this order:

1. `docs/INDEX.md` — the map of all project knowledge
2. `plans/active-plan.md` — what we are building right now
3. `.claude/memory/status.md` — current build state
4. `.claude/memory/decisions.md` — decisions already made

Do not open the rest of `docs/` speculatively. When a task needs a specific doc, open only that one. This is a deliberate constraint to preserve context.

## Non-negotiable invariants

These five rules came from a v2 stress-test and a round of implementation research. Violating them is a bug, regardless of what any other doc says.

1. **Never write directly to Twenty's Postgres database.** All Twenty reads and writes go through Twenty's GraphQL API. Bookings live in a separate n8n-owned Postgres database.
2. **Never assume Twenty has rollups, formula fields, or action-button webhooks.** Compute derived fields from n8n. Trigger server-side logic with Manual-triggered workflows, not action buttons.
3. **Redis conversation locks are 60 seconds, with a Lua heartbeat every 15 seconds and a Lua CAS release.** 30-second TTLs break under real Claude latency.
4. **Social posting uses free native APIs only.** Meta Graph API (Facebook + Instagram), X API free tier, Telegram Bot API. LinkedIn is deferred. Blotato is not used.
5. **Ghanaian local-language voice notes are not auto-transcribed.** Groq's `whisper-large-v3-turbo` (per [ADR-0006](docs/05-decisions/ADR-0006-groq-whisper-pivot.md), which superseded the original `gpt-4o-mini-transcribe` choice during Phase 4 voucher work) handles English and Ghanaian Pidgin only. Unclear audio triggers a polite retry. Local-language voice notes go to a human review queue. Typed local-language text is passed directly to Claude.

A sixth rule is procedural: **every user-facing output must be reviewed by a human for the first two weeks after launch.** This is the calibration window.

## Delegation routing

Keep this main context clean. Delegate heavy work to subagents (see `.claude/agents/`):

- Architecture decisions → `architect`, which writes an ADR into `docs/05-decisions/`
- Build or modify an n8n workflow → `workflow-builder`
- Change Twenty CRM custom objects → `schema-designer`
- Verify acceptance criteria → `tester`
- Review completed work against invariants → `code-reviewer`
- Check the `docs/` tree for staleness → `doc-gardener`
- Verify external API behaviour → `researcher`

A feature is not DONE until `tester` returns green AND `code-reviewer` has signed off.

## How we work

1. Read `plans/active-plan.md`. If it is empty or archived, ask the human what we are building.
2. For a new feature, copy `plans/TEMPLATE.md` to `plans/YYYYMMDD-feature.md` and set that as the active plan.
3. Break the work into phases with explicit acceptance criteria.
4. Read the relevant spec in `docs/02-workflows/` or `docs/01-data-model/`.
5. If the work involves architectural choices, dispatch `architect` first. Wait for the ADR before implementing.
6. Delegate implementation to the specialist subagent.
7. Dispatch `tester`. If red, fix and re-dispatch.
8. Dispatch `code-reviewer`. If flagged, fix and re-dispatch.
9. Update `.claude/memory/status.md` and archive the plan.

## Project layout at a glance

```
docs/            progressive-disclosure spec — indexed by INDEX.md
plans/           per-feature working plans, chronological
.claude/         the harness: agents, skills, rules, hooks, memory, settings
infrastructure/  docker-compose, nginx, postgres init — the stack as code
n8n-workflows/   n8n workflow JSON exports, version-controlled
database/        bookings-DB migrations and seed data
twenty-schema/   Twenty CRM custom-object definitions — JSON migrations applied via apply-twenty-schema.sh per ADR-0005
scripts/         bootstrap, backup, deploy helpers
reference/       vendor API docs snapshots for offline agent use
```

## Related code not in this repo

- Twenty CRM source at `~/Sandbox/twenty/`. Read-only reference. Do not modify it. Extensions go through Twenty's public extension API.
- Live service containers, managed by `infrastructure/docker-compose.yml`. Interact with them at runtime via MCP servers or HTTP, not by reading source files.

## Commands always safe to run without asking

Read-only and diagnostic commands only. For anything that mutates state, ask first.

- `git status`, `git diff`, `git log`, `git branch`
- `ls`, `cat`, `head`, `tail`, `grep`, `rg`, `find`, `tree`
- `docker compose ps`, `docker compose logs`, `docker compose config`
- `psql -c '\dt'` and other read-only psql meta-commands against the bookings DB
- `curl -s` against localhost health-check endpoints
- `node --version`, `python --version`, and other version probes

Ask before: editing `docker-compose.yml`, running migrations, installing packages, pushing to any remote, calling any third-party API in a non-dry-run mode.

## Style

- TypeScript for custom code, Python for scripts, SQL for migrations.
- All n8n workflows must have an error-handling branch that writes to the `workflow_errors` table.
- All database writes need a read-back test.
- No `console.log` in committed code; use the structured logger.
- Idempotent operations by default. If it can run twice safely, write it that way.
- Ghana-first: phone numbers validated against MTN, Telecel, AirtelTigo, Glo prefixes; times in Africa/Accra; currency in GHS for internal accounting, USD for cloud bills.

## When in doubt

Ask the human. Do not guess. Do not invent vendor behaviour — dispatch `researcher` to confirm. Do not skip the invariants above, even if a task seems to require it; the right move is to flag the conflict and ask.
