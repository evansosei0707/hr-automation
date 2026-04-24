# HR Automation — Ghanaian HR Firm

A self-hosted, AI-assisted HR operations system. WhatsApp is the primary interface for candidates; Twenty CRM is the system of record; n8n orchestrates everything.

## Status

**Phase:** Week 0 — validation gate.
**Not yet live.** Do not point production traffic at this system until the calibration window closes (two weeks after Week 5).

## Quick links

- **For Claude Code:** read `CLAUDE.md`
- **Full project map:** `docs/INDEX.md`
- **What we are building right now:** `plans/active-plan.md`
- **Decisions log:** `.claude/memory/decisions.md`
- **Architecture decisions (formal):** `docs/05-decisions/`

## Getting started locally

```bash
# One-time
./scripts/bootstrap.sh

# Day-to-day
docker compose -f infrastructure/docker-compose.yml up -d
docker compose -f infrastructure/docker-compose.yml logs -f n8n
```

Open:
- Twenty CRM: http://localhost:3000
- n8n: http://localhost:5678

See `docs/00-foundations/infrastructure.md` for the full setup.

## How the project is structured

This repo is organised as a **harness for Claude Code**, not as a traditional codebase. Most of what you see is documentation and configuration that tells AI agents how to work on the system. The running stack (Twenty, n8n, Postgres, Redis) is provisioned by Docker and lives in containers, not as source in this repo.

```
CLAUDE.md        Project Constitution. Claude reads this every session.
docs/            The knowledge base, progressive disclosure.
plans/           Chronological working plans, one per feature.
.claude/         The agent harness (subagents, skills, rules, hooks).
infrastructure/  Docker compose and service configs.
n8n-workflows/   Exported n8n workflows as JSON (version controlled).
database/        Migrations and seed data for the bookings DB.
twenty-schema/   Twenty custom-object definitions.
scripts/         Setup and utility scripts.
reference/       Snapshots of vendor API docs for offline use.
```

## Contributing

This is an internal project for one HR firm. Not open to external contributions.

## License

Proprietary. All rights reserved.
