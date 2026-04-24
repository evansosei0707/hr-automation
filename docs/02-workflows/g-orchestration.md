# Workflow G — Master Orchestration

The system's supervisor. Runs every 5 minutes. Keeps things healthy, sweeps stuck state, raises alerts.

## Purpose

In a multi-workflow system, things drift: a slot offer goes stale, a reminder doesn't fire, a workflow_error sits unacknowledged, an API key quietly expires. Rather than bolt a watchdog onto each workflow, one orchestration loop does the janitorial work for all of them.

## Triggers

- Cron: every 5 minutes

## What it does on each tick

For each check below, the workflow asks a simple question and takes a simple corrective action or alerts.

### Service health

- `n8n` health endpoint responds 200 within 2s.
- `twenty` health endpoint responds 200 within 2s.
- `bookings-db` accepts a SELECT 1 in <500ms.
- `redis` PING returns PONG.
- `whatsapp-cloud` synthetic echo test (send a message to a test-account number that auto-replies) — once per hour, not every 5 minutes.

Any failure → alert to staff WhatsApp channel once per 30min (dedupe), write `system_incident` row.

### Stuck state sweepers

- **Expired slot offers:** `UPDATE slot SET status='available' WHERE status='offered' AND offer_expires_at < NOW()`.
- **Unacknowledged errors over 1 hour:** any `workflow_errors` row with `acknowledged_at IS NULL AND occurred_at < NOW() - INTERVAL '1 hour'` → alert.
- **Workflow A lock leaks:** any conversation lock in Redis older than 5 minutes (which should be impossible if heartbeat is working) → log, alert, force-release.
- **Candidates stuck in screening:** Workflow C application with `status=received` and no inbound message for 72h → auto-withdraw.
- **Applications without screenings:** `status=received` and age > 24h for white-collar → raise ReviewTask.

### Scheduled reminders

- Interview reminders 24h and 2h before scheduledAt: send WhatsApp reminders, mark reminder as sent.
- Candidate "still interested?" for shortlisted candidates with no activity for 10 days.

### Cost budget watch

- Sum Claude + OpenAI costs for today. If > $5, alert. If > $10, alert and gate the heaviest workflows (B full re-screens) until midnight.
- Weekly total > $25 warning; > $50 gate.

### Maintenance jobs (once per day, not every 5 minutes)

- Holiday sync from Google Calendar → Twenty `Holiday` table.
- Retention sweeper: candidates past retention horizon → archive.
- `booking_event_log` pruning per policy.

## Invariants

- Orchestration writes to `workflow_errors` and `system_incident` tables, not directly to staff channels. Alerts are emitted via a single `alerter` function that deduplicates and rate-limits.
- It does not cross-invoke other workflows by calling their webhooks; it writes to inbox tables and those workflows pick up on their own schedule. This keeps dependencies one-way.
- It never retries a failed action blindly. Retries are scoped and bounded.

## Acceptance criteria

- **Service down:** kill Redis, next tick detects it, alert fires once, does not re-fire for 30 min, recovery auto-detected.
- **Expired slot:** an `offered` slot with `offer_expires_at` 10 minutes in the past is swept to `available` within 5 minutes.
- **Lock leak:** a conversation lock without heartbeat for 5 minutes is released.
- **Budget gate:** daily AI cost crosses $10; workflow B declines to start a new screening and logs it; message to staff channel sent once.
- **Reminder delivery:** interview in 2h04m — reminder fires in the next tick, not double-fired.

## Monitoring

- `workflow_g_tick_duration_seconds` histogram
- `workflow_g_alerts_fired_total`, labelled by `kind`
- `workflow_g_sweeper_actions_total`, labelled by `sweeper`

## Open questions

- When we add more sweepers, does the workflow stay in one monolithic n8n flow, or do we split per concern? Default: split if and only if any single sweeper exceeds 15s per tick.
