# Operations — Observability

What we log, what we measure, how we look at it.

## Three layers

**Logs** — structured events, human-readable timeline. Answer "what happened?"
**Metrics** — numeric counters/gauges/histograms. Answer "how often / how slow / how many?"
**Traces** — not used in v1. Revisit when we have more than 3 services.

## Logging

- **Format:** JSON lines, one event per line.
- **Destination (v1):** Postgres `event_log` table in the bookings DB + stdout for Docker.
- **Destination (Phase 2):** forward to Loki or a hosted service.

Every log line carries:
- `timestamp`
- `workflow_name` (one of A–H, or 'system')
- `execution_id`
- `candidate_id` or `application_id` if applicable (never raw phone numbers — use Candidate IDs for correlation, the phone is stored in Twenty)
- `level` (info, warn, error)
- `event` (a short snake_case identifier)
- `message` (human-readable)
- `data` (arbitrary JSON payload)

Sensitive data redaction: never log message bodies for candidate WhatsApp content beyond the first 40 chars. Never log transcribed voice content. Never log Claude prompts containing candidate PII at `info` level — only at `debug`.

## Metrics

Prometheus-format, scraped from each service's `/metrics` endpoint (v1: n8n exposes its own; we add a tiny exporter for our workflow metrics in `scripts/metrics-exporter.py`). For v1, we do not run Prometheus itself — we aggregate nightly into a `metrics_daily` table in the bookings DB and read from there in the weekly report.

**Core counters (per workflow A–H):**
- `_invocations_total`
- `_errors_total` labelled by `error_kind`
- `_duration_seconds` histogram
- `_ai_cost_total_usd` counter

**Domain counters:**
- `candidates_total`
- `applications_total` labelled by `status`
- `interviews_scheduled_total`, `interviews_completed_total`, `interviews_no_show_total`
- `placements_total`
- `social_posts_published_total` labelled by `platform`
- `re_engagement_yes_rate` gauge

**Infrastructure:**
- `redis_lock_wait_seconds` histogram
- `bookings_db_connections_active` gauge
- `claude_api_latency_seconds` histogram labelled by `model`

## Alerts

Not every alert goes to WhatsApp. Three levels:

| Level | Channel | Example |
|---|---|---|
| Critical | WhatsApp staff + SMS to Operations Lead | DB down, WhatsApp integration failing, no inbound processed for 15 min |
| Warning | WhatsApp staff | AI daily budget > $5, workflow error rate > 3%, quality rating drop |
| Info | Daily digest in weekly report | Individual workflow_errors entries, stuck state sweeps |

Alert deduplication lives in the `alerter` helper: same `alert_key` within 30 min = one message. Resolved alerts emit a "cleared" message.

## Dashboards (v1 minimum)

Three views, implemented as Twenty saved views (which handle filtering and grouping natively):

1. **Review Queue** — all `ReviewTask` where `resolvedAt IS NULL`. Sorted by `dueBy`. This is the Orchestrator's primary inbox.
2. **System Alerts** — `workflow_errors` where `acknowledgedAt IS NULL`, grouped by `workflowName`.
3. **Pipeline Health** — Applications by status, counts per day for the last 14 days.

Phase 2: Grafana with Prometheus. Not v1.

## Runbook triggers

Every alert has a one-line summary and a link to a specific section in `docs/04-operations/runbook.md`. E.g.:

> "redis_ping_failed — candidates may not be replied to. Runbook: §5."

This is how we bridge observability to action.
