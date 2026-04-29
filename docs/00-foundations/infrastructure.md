# Infrastructure Stack

The stack that runs the HR automation system. One VPS, Docker-composed.

## Target environment

- **Host:** single Linux VPS, 4 vCPU / 8 GB RAM / 80 GB SSD minimum. Hetzner CX31 or DigitalOcean s-4vcpu-8gb recommended.
- **OS:** Ubuntu 24.04 LTS.
- **Region:** EU (closer to Ghana in latency terms than US West; adequate).
- **Local development:** WSL2 Ubuntu 24.04 on Windows, same compose file.

## Components

| Component | Image / source | Role |
|---|---|---|
| Twenty CRM | `twentycrm/twenty:latest` (pinned) | System of record for candidates, companies, jobs, interviews |
| Twenty Postgres | `postgres:16` | Twenty's own DB — do not touch from outside Twenty |
| n8n | `n8nio/n8n:latest` (pinned) | Workflow engine: all orchestration logic |
| Bookings Postgres | `postgres:16` | n8n-owned DB for interview bookings and slot claiming |
| Redis | `redis:7-alpine` | Conversation locks, short-lived dedupe keys (HRA-owned keys use `hra:` prefix per [ADR-0009](../05-decisions/ADR-0009-redis-namespace-strategy.md)) |
| Nginx | `nginx:stable-alpine` | TLS termination, reverse proxy |

Everything talks over a private Docker network. Only Nginx is exposed on the public interface (ports 80/443).

## Why two Postgres instances

One of our non-negotiable invariants is that we do not write directly into Twenty's database. Bookings, slot claims, and conversation state live in a separate Postgres that n8n fully owns. This keeps us safe from Twenty schema migrations and keeps Twenty safe from our hot-path writes. See `docs/05-decisions/` for the historical record of this choice.

## Redis namespace separation

The single `hr-redis` instance is shared by Twenty and our HRA app. Twenty owns the `bull:` (BullMQ queues), `engine:` (workspace cache), and `module:` (workflow scheduler) prefixes — observed via `docker exec hr-redis redis-cli --scan` and confirmed against Twenty source. Our app uses the `hra:` prefix exclusively (`hra:conv:*`, `hra:dedupe:*`, future kinds follow `hra:<kind>:<id>`). n8n is currently in `regular` mode and writes nothing to Redis; if it's ever switched to `EXECUTIONS_MODE=queue`, the prefix-isolation question must be resolved before the change ships (set `QUEUE_BULL_PREFIX` on n8n, or split Twenty onto a dedicated Redis). Full evidence trail and decision rationale: [ADR-0009](../05-decisions/ADR-0009-redis-namespace-strategy.md).

## Environment variables

All secrets and environment-specific config live in `.env`, which is NOT committed. See `infrastructure/.env.example` for the full list with dummy values.

## Deployment model

- **Local (dev):** `docker compose -f infrastructure/docker-compose.yml up -d` inside WSL.
- **Staging:** identical compose file on a scratch VPS, with a separate `.env.staging`.
- **Production:** same compose file on the prod VPS, with `.env.production`. Promotion is a `git pull` + `docker compose pull` + `docker compose up -d`. No bespoke deploy tooling.

Database migrations (bookings DB) run via a one-shot container in the compose file; `up -d` is safe to run repeatedly.

## Backups

- **Nightly:** `pg_dump` of both Postgres instances, compressed, written to `/var/backups/hr-automation/` on the host.
- **Offsite:** rclone sync to a S3-compatible bucket (Backblaze B2 recommended for cost).
- **Retention:** 14 daily, 8 weekly, 6 monthly.
- **Restore drill:** monthly. Script in `scripts/restore-drill.sh` (build this during Week 4).

## Monitoring

- **Uptime:** external HTTP check on Nginx + Twenty login page, every 1 minute. Uses a free tier (Better Uptime or UptimeRobot).
- **Internal health:** Workflow G (`02-workflows/g-orchestration.md`) runs every 5 minutes, checks n8n health endpoint, Postgres connection, Redis PING, and a synthetic WhatsApp echo test.
- **Alerts:** WhatsApp message to the staff channel on any check failure.

## Limits we are accepting

- Single-VPS: no HA, no automatic failover. If the VPS dies, we restore from backup on a new VPS. RTO ~1 hour, RPO ~24 hours.
- No CDN: all traffic is small (JSON, text), and candidates are on WhatsApp, not on our website.
- No Kubernetes: overkill for this scale and team size. Compose is enough until it is not.

## Local setup (WSL2)

```bash
# One-time host prep
sudo apt update && sudo apt install -y docker.io docker-compose-plugin git
sudo usermod -aG docker $USER
# log out and back in for the group to take effect

# Clone and bootstrap
cd ~/Sandbox
git clone <this-repo> hr-automation
cd hr-automation
cp infrastructure/.env.example infrastructure/.env
# edit .env with local values
./scripts/bootstrap.sh
```

See `scripts/bootstrap.sh` for what the bootstrap script actually does.
