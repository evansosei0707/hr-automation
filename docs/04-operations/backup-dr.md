# Operations — Backup & Disaster Recovery

Single-VPS, single-region, pragmatic. If the VPS dies, we restore from off-site backups to a new VPS.

## What we back up

| Data | Frequency | Destination | Retention |
|---|---|---|---|
| Twenty Postgres | Nightly 02:00 Accra | Backblaze B2 via rclone | 14 daily, 8 weekly, 6 monthly |
| Bookings Postgres | Nightly 02:00 Accra | Same | Same |
| n8n workflows | On every export (manual or scripted) | Git repo | Forever (version controlled) |
| n8n credentials | Never automated; manual export via n8n UI | Encrypted file in 1Password / Bitwarden | Rotate on change |
| WhatsApp media uploads | Nightly sync | Backblaze B2 | 36 months |
| `.env` files | Never in git; per-environment | 1Password / Bitwarden | Rotate on change |
| Docker images | Not backed up | Pulled from registry | N/A |

## How

One script: `scripts/backup.sh`, run by cron on the host.

```
#!/usr/bin/env bash
set -euo pipefail
source /etc/hr-automation/.env

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT=/var/backups/hr-automation/$STAMP
mkdir -p "$OUT"

# Twenty
docker exec twenty-db pg_dump -U twenty -d twenty | gzip > "$OUT/twenty.sql.gz"

# Bookings
docker exec bookings-db pg_dump -U n8n_bookings -d bookings | gzip > "$OUT/bookings.sql.gz"

# WhatsApp media (rsync-style)
rclone sync /var/lib/hr-automation/media b2:${B2_BUCKET}/media --transfers 4

# Push SQL backups
rclone copy "$OUT" b2:${B2_BUCKET}/db/$STAMP

# Prune local
find /var/backups/hr-automation/ -type d -mtime +14 -exec rm -rf {} +
```

This is skeletal — harden with proper lockfile, paging on failure, etc. The `workflow-builder` subagent will write it properly in Week 4.

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
