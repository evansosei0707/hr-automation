# Operations — Backup & Disaster Recovery

Single-VPS, single-region, pragmatic. If the VPS dies, we restore from off-site backups to a new VPS.

## What we back up

> **2026-04-29 audit finding.** The original spec listed two databases: Twenty + Bookings. The local drill on 2026-04-29 surfaced that the **n8n DB was missing from the inventory**. n8n stores its workflow DEFINITIONS in git (via the export process documented in `n8n-workflows/README.md`), but its **execution history, schedules, encrypted credentials, and any UI-edited workflows** live in a Postgres database (DB `n8n`, user `n8n`, hosted on the `hr-bookings-db` container alongside the bookings DB). Without a dump of this DB, a VPS-failure restore loses every n8n execution log, every queued webhook, and any workflow change a user made in the UI between exports. **The inventory below is the corrected, post-audit version.** The drill script `scripts/backup-databases.sh` reflects the corrected list.

| Data | Frequency | Destination | Retention |
|---|---|---|---|
| Twenty Postgres | Nightly 02:00 Accra | Backblaze B2 via rclone | 14 daily, 8 weekly, 6 monthly |
| Bookings Postgres | Nightly 02:00 Accra | Same | Same |
| **n8n internal Postgres** | **Nightly 02:00 Accra** | **Same** | **Same** |
| n8n workflow JSON definitions | On every export (manual or scripted) | Git repo | Forever (version controlled) |
| n8n credentials | Never automated; manual export via n8n UI | Encrypted file in 1Password / Bitwarden | Rotate on change |
| WhatsApp media uploads | Nightly sync | Backblaze B2 | 36 months |
| `.env` files | Never in git; per-environment | 1Password / Bitwarden | Rotate on change |
| Docker images | Not backed up | Pulled from registry | N/A |

### Per-database connection details

The corrected inventory in concrete terms — these are what `scripts/backup-databases.sh` actually runs:

| Label | Container | User | DB | Notes |
|---|---|---|---|---|
| `twenty` | `hr-twenty-db` | `twenty` | `twenty` | Twenty CRM's own database. Owns `core`, `metadata`, and tenant schemas. |
| `bookings` | `hr-bookings-db` | `n8n_bookings` | `bookings` | The n8n-owned operational DB — bookings, event_log, workflow_errors, ai_call_log, system_incident, twenty_schema_migrations. |
| `n8n` | `hr-bookings-db` | `n8n` | `n8n` | n8n's own internal store: executions, credentials (encrypted), settings, queue state. Provisioned by `infrastructure/postgres/init-n8n-user.sh`. |

**Redis state is intentionally NOT backed up.** Conversation locks, dedupe keys, idempotency markers, and BullMQ queues are ephemeral by design — losing them on a VPS failure means at most a few minutes of in-flight work is replayed (workflows are written idempotent per the project style guide). A dumped Redis would be stale within seconds anyway, and re-acquired locks after restore are correct behaviour, not a recovery problem.

## How

One script will eventually live at `scripts/backup-databases.sh`, run by cron on the host. As of 2026-04-29 the script exists in **local-drill form only** — three pg_dumps + gzip + local timestamped output. The production version (cron, B2 sync via rclone, 30-day rotation, lockfile, paging on failure) is deferred to Week 4 — see `plans/tier-2-followups.md` item "Production-grade backup script".

The local-drill skeleton corresponds to the production script's bones:

```bash
#!/usr/bin/env bash
set -euo pipefail
# .env path is config-driven. Local: $REPO_ROOT/infrastructure/.env.
# Production (Week 4): a deployment-time path, e.g. /etc/hr-automation/.env.
source "${ENV_FILE:-$REPO_ROOT/infrastructure/.env}"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT=$BACKUP_DIR/$STAMP
mkdir -p "$OUT"

# Three DBs (all corrected container names — note hr- prefix):
docker exec -e PGPASSWORD="$TWENTY_DB_PASSWORD"   hr-twenty-db   pg_dump -U "$TWENTY_DB_USER"   -d "$TWENTY_DB_NAME"   --clean --if-exists | gzip > "$OUT/twenty.sql.gz"
docker exec -e PGPASSWORD="$BOOKINGS_DB_PASSWORD" hr-bookings-db pg_dump -U "$BOOKINGS_DB_USER" -d "$BOOKINGS_DB_NAME" --clean --if-exists | gzip > "$OUT/bookings.sql.gz"
docker exec -e PGPASSWORD="$N8N_DB_PASSWORD"      hr-bookings-db pg_dump -U "$N8N_DB_USER"      -d "$N8N_DB_NAME"      --clean --if-exists | gzip > "$OUT/n8n.sql.gz"

# (Production-only, not in local drill:)
# rclone sync /var/lib/hr-automation/media b2:${B2_BUCKET}/media --transfers 4
# rclone copy "$OUT" b2:${B2_BUCKET}/db/$STAMP
# find $BACKUP_DIR/ -type d -mtime +14 -exec rm -rf {} +
```

Production-grade hardening (lockfile so two crons can't overlap, paging on failure, retention rotation that respects the 14d/8w/6m policy, B2 push idempotency on retry, alerting via Workflow G) all lands in Week 4 alongside the cron schedule.

## Restore drills

**Monthly exercise** (first Monday of each month, 15 minutes):

1. Spin up a throwaway VPS or Docker sandbox.
2. Run `scripts/restore-drill.sh <backup-date>`.
3. Script pulls the latest backups, spins up postgres containers, restores, and runs a read smoke test.
4. Record success/failure in `memory/status.md`.

**A restore drill that we have not run in 60 days is broken.** Workflow G alerts on this.

## RTO / RPO

- **RPO (recovery point objective):** 24 hours. If the VPS dies, we lose at most the last day's data.
- **RTO (recovery time objective):** 2 hours. Provision new VPS, pull repo, run compose, restore DB, update DNS.

These are acceptable for the firm's scale. Revisit if the business grows.

## What's NOT in scope (v1)

- Hot standby / read replica
- Multi-region
- Automatic failover
- Point-in-time recovery (PITR)

All of these are more cost and ops overhead than a single-firm-scale system justifies. When the firm outgrows this, the first upgrade is Postgres streaming replication to a second VPS.

## Data-protection-specific backup rules

- Backups containing candidate data are **encrypted at rest** on Backblaze (B2 server-side encryption enabled + rclone encryption layer with our own key).
- Backup access is limited to two people — Operations Lead and CEO. Not even the system itself can read its own backups back.
- If a candidate requests data deletion (DPA), the deletion propagates to live data immediately, and to backups at the next monthly prune. Document the deletion request in `data_deletion_log` table so we can evidence compliance.

## The disaster-recovery runbook entry

See `runbook.md` §8 for the step-by-step. The short version:

1. Provision new Ubuntu 24.04 VPS (Hetzner, DigitalOcean — the cheapest is fine).
2. `git clone` the repo.
3. Install Docker per `scripts/bootstrap.sh`.
4. Restore both DBs from Backblaze.
5. Pull Docker images, `docker compose up -d`.
6. Update DNS to the new IP.
7. Restore `.env` from the password manager.
8. Verify synthetic WhatsApp echo test.
9. Announce restore on the staff channel.

Expect 60–90 minutes for a practised operator.
