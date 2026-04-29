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

## Operational queries — looking at what's happening

Where the dashboards stop, SQL begins. The bookings DB carries four observability tables:

| Table | Holds | Written by |
|---|---|---|
| `event_log` | Structured info/warn/error timeline events. Levels: `debug`, `info`, `warn`, `error` (CHECK-constrained). | Workflows + voucher scripts via Postgres INSERT |
| `workflow_errors` | Error Trigger writes (effectively always error-level; no `level` column). | Every n8n workflow's Error Trigger branch (rule #1 in `.claude/rules/n8n-workflows.md`) |
| `ai_call_log` | Claude / AI usage + per-call token counts + USD cost | Claude subflow (rule #6) |
| `system_incident` | Paged incidents (severity: `info` / `warning` / `critical`) | Workflow G + operator (manual) |

**Connect:**

```bash
source infrastructure/.env
docker exec -it -e PGPASSWORD="$BOOKINGS_DB_PASSWORD" hr-bookings-db \
  psql -U "$BOOKINGS_DB_USER" -d "$BOOKINGS_DB_NAME"
```

The queries below were run against the live bookings DB on **2026-04-29** during Phase 5. Embedded outputs are the actual results from that run, so you can sanity-check shape before copy-pasting and see what "normal" looks like in the current demo dataset (Phase 4 vouchers + Workflow A webhook test traffic). All windows are relative to `NOW()` — fine for production ops, but in the demo dataset (events ended 2026-04-28 18:44 UTC) "last 1 hour" returns zero rows. Where that matters, a stretched-window variant follows.

### Current-state snapshot (as of 2026-04-29)

```
table              | rows
-------------------+-----
ai_call_log        |    2
event_log          |   14
system_incident    |    0
workflow_errors    |   14
```

Distribution of `event_log` by workflow + level:

```
workflow_name               | level | count
----------------------------+-------+------
voucher_anthropic           | info  |   1
voucher_google_calendar     | info  |   1
voucher_groq_transcribe     | info  |   1
voucher_meta_fb             | info  |   1
voucher_meta_ig             | warn  |   1   ← ADR-0007 (Meta soft-hold)
voucher_openai_transcribe   | error |   1   ← ADR-0006 (superseded by Groq)
voucher_telegram            | info  |   1
workflow_a_inbound_whatsapp | info  |   7   ← Phase 4 webhook test traffic
```

### What happened in the last hour

```sql
SELECT ts, workflow_name, level, event,
       LEFT(COALESCE(message, ''), 60) AS msg
FROM event_log
WHERE ts > NOW() - INTERVAL '1 hour'
ORDER BY ts DESC;
```

**Result (live ops query):** 0 rows. In production this is a strong signal — either the system is genuinely quiet or workflows have stopped logging (cross-check via §1/§4 of `runbook.md`). In the demo dataset it just means the last event is older than 1 hour.

**Stretched to 48 hours** (covers the demo dataset):

```sql
SELECT ts, workflow_name, level, event,
       LEFT(COALESCE(message, ''), 60) AS msg
FROM event_log
WHERE ts > NOW() - INTERVAL '48 hours'
ORDER BY ts DESC;
```

```
              ts               |        workflow_name        | level |           event           |                             msg
-------------------------------+-----------------------------+-------+---------------------------+--------------------------------------------------------------
 2026-04-28 18:44:25.969003+00 | workflow_a_inbound_whatsapp | info  | webhook_received          | {"object":"whatsapp_business_account","entry":[{"id":"vouche
 2026-04-28 18:29:52.487691+00 | workflow_a_inbound_whatsapp | info  | webhook_received          | {"object":"whatsapp_business_account","entry":[{"id":"140269
 2026-04-28 18:28:33.005794+00 | workflow_a_inbound_whatsapp | info  | webhook_received          | {"object":"whatsapp_business_account","entry":[{"id":"140269
 2026-04-28 18:14:16.224906+00 | workflow_a_inbound_whatsapp | info  | webhook_received          | {"object":"whatsapp_business_account","entry":[{"id":"0","ch
 2026-04-28 18:10:23.888398+00 | workflow_a_inbound_whatsapp | info  | webhook_received          | {"object":"whatsapp_business_account","entry":[{"id":"0","ch
 2026-04-28 17:49:32.30144+00  | workflow_a_inbound_whatsapp | info  | webhook_received          | {"object":"whatsapp_business_account","entry":[{"id":"123456
 2026-04-28 17:41:12.763163+00 | workflow_a_inbound_whatsapp | info  | webhook_received          | {"object":"whatsapp_business_account","entry":[{"id":"123456
 2026-04-28 14:37:35.752971+00 | voucher_groq_transcribe     | info  | transcribe_succeeded      | Groq whisper-large-v3-turbo returned 31-char transcript
 2026-04-28 14:20:06.633198+00 | voucher_meta_ig             | warn  | skipped                   | Meta IG voucher skipped: META_IG_USER_ID empty (Meta soft-ho
 2026-04-28 14:20:06.198365+00 | voucher_meta_fb             | info  | post_and_delete_succeeded | Meta FB voucher: invisible draft posted (546388758556061_122
 2026-04-27 23:53:22.796792+00 | voucher_openai_transcribe   | error | transcribe_failed         | OpenAI audio.transcriptions returned HTTP 429
 2026-04-27 23:43:08.999472+00 | voucher_anthropic           | info  | calls_succeeded           | Anthropic voucher: Sonnet + Haiku Messages API ping calls su
 2026-04-27 21:23:18.901339+00 | voucher_google_calendar     | info  | fetch_succeeded           | Google Calendar voucher: 26 2026 holidays read; Founder's Da
 2026-04-27 21:21:30.760936+00 | voucher_telegram            | info  | send_succeeded            | Telegram voucher message sent successfully
(14 rows)
```

### Errors today / this week

**Unacknowledged workflow_errors — the operator's inbox.** Mirrors the `workflow_errors_unack` partial index.

```sql
SELECT id, occurred_at, workflow_name, node_name,
       LEFT(error_message, 70) AS err
FROM workflow_errors
WHERE acknowledged_at IS NULL
ORDER BY occurred_at DESC
LIMIT 20;
```

```
 id |          occurred_at          |        workflow_name        |      node_name       |                            err
----+-------------------------------+-----------------------------+----------------------+-----------------------------------------------------------
 38 | 2026-04-28 18:44:26.04427+00  | workflow_a_inbound_whatsapp | Validate HMAC        | X-Hub-Signature-256 mismatch — refused
 37 | 2026-04-28 17:41:12.852583+00 | workflow_a_inbound_whatsapp | Validate HMAC        | X-Hub-Signature-256 mismatch — refused
 36 | 2026-04-28 17:25:44.178021+00 | workflow_a_inbound_whatsapp | Validate HMAC        | crypto is not defined [line 53]
 35 | 2026-04-28 17:25:44.139021+00 | workflow_a_inbound_whatsapp | Validate HMAC        | crypto is not defined [line 53]
 34 | 2026-04-28 17:21:19.274605+00 | workflow_a_inbound_whatsapp | Node With Error      | Example Error Message
 33 | 2026-04-28 17:21:14.722531+00 | workflow_a_inbound_whatsapp | Validate HMAC        | raw_body_unavailable
 32 | 2026-04-28 17:16:13.62227+00  | workflow_a_inbound_whatsapp | Validate HMAC        | raw_body_unavailable
 31 | 2026-04-28 17:16:01.330213+00 | workflow_a_inbound_whatsapp | Validate HMAC        | raw_body_unavailable
 30 | 2026-04-28 17:15:51.691496+00 | workflow_a_inbound_whatsapp | Validate HMAC        | raw_body_unavailable
 29 | 2026-04-28 17:15:44.571406+00 | workflow_a_inbound_whatsapp | Node With Error      | Example Error Message
 28 | 2026-04-28 17:15:34.574468+00 | workflow_a_inbound_whatsapp | Validate HMAC        | raw_body_unavailable
  3 | 2026-04-28 17:08:36.500475+00 | workflow_a_inbound_whatsapp | Node With Error      | Example Error Message
  2 | 2026-04-26 14:39:55.911031+00 | apply-twenty-schema.sh      | V001[14] createField | Migration action 'create' for 'fieldMetadata' failed
  1 | 2026-04-26 14:23:24.950058+00 | apply-twenty-schema.sh      | V001[14] createField | Multiple validation errors occurred while creating fields
(14 rows)
```

**Top error patterns.** Groups by `(workflow, node, error_message-prefix)` so noisy repeat-bugs collapse to one row:

```sql
SELECT workflow_name, node_name,
       LEFT(error_message, 50) AS err_excerpt,
       count(*) AS hits,
       max(occurred_at) AS last_seen
FROM workflow_errors
WHERE occurred_at > NOW() - INTERVAL '7 days'
GROUP BY workflow_name, node_name, LEFT(error_message, 50)
ORDER BY hits DESC, last_seen DESC;
```

```
        workflow_name        |      node_name       |                    err_excerpt                     | hits |           last_seen
-----------------------------+----------------------+----------------------------------------------------+------+-------------------------------
 workflow_a_inbound_whatsapp | Validate HMAC        | raw_body_unavailable                               |    5 | 2026-04-28 17:21:14.722531+00
 workflow_a_inbound_whatsapp | Node With Error      | Example Error Message                              |    3 | 2026-04-28 17:21:19.274605+00
 workflow_a_inbound_whatsapp | Validate HMAC        | X-Hub-Signature-256 mismatch — refused             |    2 | 2026-04-28 18:44:26.04427+00
 workflow_a_inbound_whatsapp | Validate HMAC        | crypto is not defined [line 53]                    |    2 | 2026-04-28 17:25:44.178021+00
 apply-twenty-schema.sh      | V001[14] createField | Migration action 'create' for 'fieldMetadata' fail |    1 | 2026-04-26 14:39:55.911031+00
 apply-twenty-schema.sh      | V001[14] createField | Multiple validation errors occurred while creating |    1 | 2026-04-26 14:23:24.950058+00
(6 rows)
```

The pattern view is how you tell "5 retries of one bug" from "5 different bugs." Above: every Phase 4 hiccup we hit (`crypto is not defined`, `raw_body_unavailable`) is visible as its own pattern row — exactly the rationale for rules #12 and #13 in `.claude/rules/n8n-workflows.md`.

**warn/error events from `event_log`.** Operational events that workflows logged at non-info level — different signal from Error Trigger writes. The two streams are complementary, not duplicative.

```sql
SELECT ts, workflow_name, level, event,
       LEFT(COALESCE(message, ''), 70) AS msg
FROM event_log
WHERE level IN ('warn', 'error')
  AND ts > NOW() - INTERVAL '7 days'
ORDER BY ts DESC;
```

```
              ts               |       workflow_name       | level |       event       |                                  msg
-------------------------------+---------------------------+-------+-------------------+------------------------------------------------------------------------
 2026-04-28 14:20:06.633198+00 | voucher_meta_ig           | warn  | skipped           | Meta IG voucher skipped: META_IG_USER_ID empty (Meta soft-hold on new
 2026-04-27 23:53:22.796792+00 | voucher_openai_transcribe | error | transcribe_failed | OpenAI audio.transcriptions returned HTTP 429
(2 rows)
```

Both rows are documented deferrals (ADR-0007 IG, ADR-0006 OpenAI→Groq). Useful as the canonical example of "this is what an in-band, ADR-tracked failure looks like in `event_log`" vs. an Error-Trigger surprise in `workflow_errors`.

### Specific execution trace

When you have an `execution_id` (from an alert, a workflow_error row, or n8n's UI), pull every related event and error in one query:

```sql
WITH eid AS (SELECT '64' AS x)   -- substitute your execution_id
SELECT 'event' AS source, ts AS at, workflow_name, level AS lvl,
       event AS what, LEFT(COALESCE(message, ''), 60) AS msg
FROM event_log, eid
WHERE execution_id = eid.x
UNION ALL
SELECT 'error', occurred_at, workflow_name, 'error',
       node_name, LEFT(error_message, 60)
FROM workflow_errors, eid
WHERE execution_id = eid.x
ORDER BY at;
```

```
 source |              at               |        workflow_name        | lvl  |       what       |                             msg
--------+-------------------------------+-----------------------------+------+------------------+--------------------------------------------------------------
 event  | 2026-04-28 18:29:52.487691+00 | workflow_a_inbound_whatsapp | info | webhook_received | {"object":"whatsapp_business_account","entry":[{"id":"140269
(1 row)
```

For execution 64 (a successful Workflow A run), the only artifact is the inbound `webhook_received` event with no errors — the clean-success shape. A failed execution would show one `event_log` row plus one or more `workflow_errors` rows interleaved by timestamp.

**Conversation trace by candidate** — once Workflow A starts populating `candidate_id`:

```sql
SELECT ts, workflow_name, level, event,
       LEFT(COALESCE(message, ''), 50) AS msg
FROM event_log
WHERE candidate_id = 'cand_example_id'  -- substitute candidate UUID from Twenty
ORDER BY ts DESC
LIMIT 50;
```

Returns 0 rows on the demo dataset (vouchers and the Phase 4 webhook test don't populate `candidate_id`); becomes the primary lens for Workflow A debugging once real candidate flows ship.

### Workflow throughput

**Hourly heatmap (last 48h).** Shows when the system is busy and which workflows are active.

```sql
SELECT to_char(date_trunc('hour', ts), 'YYYY-MM-DD HH24:00') AS hour,
       workflow_name,
       count(*) AS n
FROM event_log
WHERE ts > NOW() - INTERVAL '48 hours'
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
```

```
       hour       |        workflow_name        | n
------------------+-----------------------------+---
 2026-04-28 18:00 | workflow_a_inbound_whatsapp | 5
 2026-04-28 17:00 | workflow_a_inbound_whatsapp | 2
 2026-04-28 14:00 | voucher_groq_transcribe     | 1
 2026-04-28 14:00 | voucher_meta_fb             | 1
 2026-04-28 14:00 | voucher_meta_ig             | 1
 2026-04-27 23:00 | voucher_anthropic           | 1
 2026-04-27 23:00 | voucher_openai_transcribe   | 1
 2026-04-27 21:00 | voucher_google_calendar     | 1
 2026-04-27 21:00 | voucher_telegram            | 1
(9 rows)
```

**Daily totals (last 7d).** Coarser view; better for the weekly report.

```sql
SELECT date_trunc('day', ts)::date AS day,
       workflow_name,
       count(*) AS n
FROM event_log
WHERE ts > NOW() - INTERVAL '7 days'
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
```

```
    day     |        workflow_name        | n
------------+-----------------------------+---
 2026-04-28 | voucher_groq_transcribe     | 1
 2026-04-28 | voucher_meta_fb             | 1
 2026-04-28 | voucher_meta_ig             | 1
 2026-04-28 | workflow_a_inbound_whatsapp | 7
 2026-04-27 | voucher_anthropic           | 1
 2026-04-27 | voucher_google_calendar     | 1
 2026-04-27 | voucher_openai_transcribe   | 1
 2026-04-27 | voucher_telegram            | 1
(8 rows)
```

**Top events by frequency.** Tells you which event names dominate (and which never fire — a shape of "is the workflow path you think exists actually executing?").

```sql
SELECT workflow_name, event, count(*) AS n
FROM event_log
WHERE ts > NOW() - INTERVAL '7 days'
GROUP BY 1, 2
ORDER BY n DESC
LIMIT 20;
```

```
        workflow_name        |           event           | n
-----------------------------+---------------------------+---
 workflow_a_inbound_whatsapp | webhook_received          | 7
 voucher_groq_transcribe     | transcribe_succeeded      | 1
 voucher_openai_transcribe   | transcribe_failed         | 1
 voucher_google_calendar     | fetch_succeeded           | 1
 voucher_anthropic           | calls_succeeded           | 1
 voucher_meta_ig             | skipped                   | 1
 voucher_telegram            | send_succeeded            | 1
 voucher_meta_fb             | post_and_delete_succeeded | 1
(8 rows)
```

### AI cost

**By model, last 24h.** Use this when an alert says costs spiked.

```sql
SELECT model,
       count(*) AS calls,
       sum(input_tokens)  AS in_tok,
       sum(output_tokens) AS out_tok,
       ROUND(sum(cost_usd), 6) AS total_usd
FROM ai_call_log
WHERE ts > NOW() - INTERVAL '24 hours'
GROUP BY model
ORDER BY total_usd DESC NULLS LAST;
```

**Result (live):** 0 rows. In production a row per active model with non-trivial calls; here, the only AI traffic happened during the Anthropic voucher on 2026-04-27 (out of the 24h window).

**By workflow, last 7d.** The right cross-section for runbook §10 (AI cost surge).

```sql
SELECT workflow_name,
       count(*) AS calls,
       ROUND(sum(cost_usd), 6) AS total_usd
FROM ai_call_log
WHERE ts > NOW() - INTERVAL '7 days'
GROUP BY workflow_name
ORDER BY total_usd DESC NULLS LAST;
```

```
   workflow_name   | calls | total_usd
-------------------+-------+-----------
 voucher_anthropic |     2 |  0.000184
(1 row)
```

**Top expensive individual calls.** When `total_usd` for a workflow looks wrong, this finds the smoking gun.

```sql
SELECT ts, workflow_name, model,
       input_tokens AS in_tok, output_tokens AS out_tok,
       cost_usd, LEFT(COALESCE(prompt_excerpt, ''), 50) AS prompt
FROM ai_call_log
ORDER BY cost_usd DESC NULLS LAST
LIMIT 5;
```

```
              ts               |   workflow_name   |       model       | in_tok | out_tok | cost_usd |                       prompt
-------------------------------+-------------------+-------------------+--------+---------+----------+----------------------------------------------------
 2026-04-27 23:43:07.873575+00 | voucher_anthropic | claude-sonnet-4-6 |     21 |       5 | 0.000138 | Reply with exactly the word 'pong' and nothing els
 2026-04-27 23:43:08.788171+00 | voucher_anthropic | claude-haiku-4-5  |     21 |       5 | 0.000046 | Reply with exactly the word 'pong' and nothing els
(2 rows)
```

### Open incidents

```sql
SELECT id, opened_at, kind, severity, summary
FROM system_incident
WHERE resolved_at IS NULL
ORDER BY opened_at DESC;
```

**Result (live):** 0 rows. `system_incident` is intentionally empty until Workflow G ships and starts opening incidents (or the operator opens one manually). Severity is CHECK-constrained to `info` / `warning` / `critical`.

### Acknowledging an error after action

After investigating a `workflow_errors` row and either patching the workflow or confirming it's expected behaviour:

```sql
UPDATE workflow_errors
   SET acknowledged_at = NOW()
 WHERE id IN (33, 34, 35);  -- IDs from the unacknowledged-inbox query
```

This drops them off the unack inbox without losing the audit trail. Don't `DELETE` workflow_errors rows — historical evidence is the whole point of the table.

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
