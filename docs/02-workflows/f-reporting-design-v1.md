# Workflow F — Weekly Reporting — Design Note v1

**Status:** Proposed
**Spec:** `docs/02-workflows/f-reporting.md`
**Author:** architect
**Date:** 2026-05-03

A weekly Monday operations digest. Cron-triggered at 07:00 Africa/Accra, pulls 7-day metrics from Twenty + bookings DB, has Claude Haiku write a one-paragraph narrative, sends to the staff WhatsApp via the existing `wa-send` subflow.

No new migrations. Audit trail goes to the existing `event_log` table.

---

## 1. Trigger

- Schedule Trigger node, cron `0 7 * * 1`, timezone `Africa/Accra`.
- Manual Trigger node also exposed for ad-hoc runs (testing, re-send after fix).
- Both triggers fan into the same first node (`Compute Date Range`).

---

## 2. Data source map

Cite `docs/04-operations/observability.md` for queries already defined; new queries listed inline.

| Metric | Source | Query reference |
|---|---|---|
| New candidates (7d) | Twenty GraphQL | `findManyCandidates` filter `createdAt > 7d ago` |
| New applications, by collar | Twenty GraphQL | `findManyApplications` + `collarType` projection |
| Candidates screened | bookings DB | `event_log WHERE event IN ('screening_completed_b','screening_completed_c')` |
| Interviews scheduled | Twenty GraphQL | `findManyInterviews` filter `createdAt > 7d ago` |
| Interviews completed | Twenty GraphQL | `findManyInterviews` filter `status=COMPLETED AND scheduledAt > 7d ago` |
| Placements | Twenty GraphQL | `findManyApplications` filter `status=PLACED AND updatedAt > 7d ago` |
| ReviewTask open / resolved | Twenty GraphQL | two `findManyReviewTasks` filters |
| Workflow errors (7d) | bookings DB | observability.md §"Errors" |
| Voice-note manual-review queue | bookings DB | `event_log WHERE event='voice_note_routed_to_review'` |
| AI cost (total + per-workflow + WoW) | bookings DB | observability.md §"AI cost" (existing SQL) |
| Calibration: AI vs human agreement (weeks 1–2 only) | bookings DB | observability.md §"Calibration" |

All bookings DB Postgres `executeQuery` nodes use the array form for `queryReplacement` (rule #18).

---

## 3. Node flow

1. Schedule / Manual Trigger
2. `Compute Date Range` — Code node, derives `weekStartIso`, `weekEndIso`, prior-week range for WoW deltas
3. Metric query nodes (sequential, not parallel — each `onError: continueRegularOutput`):
   - `Query Twenty Candidates`
   - `Query Twenty Applications`
   - `Query Twenty Interviews Scheduled`
   - `Query Twenty Interviews Completed`
   - `Query Twenty Placements`
   - `Query Twenty ReviewTasks Open` / `... Resolved`
   - `Query Workflow Errors` (Postgres)
   - `Query Voice Note Review Queue` (Postgres)
   - `Query Screening Completions` (Postgres)
   - `Query AI Cost This Week` (Postgres)
   - `Query AI Cost Last Week` (Postgres) — WoW delta source
   - Conditional calibration queries (gated by `$env.CALIBRATION_WINDOW_ACTIVE`)
4. `Compose Report Body` — Code node aggregates upstream outputs with `?? '— unavailable —'`, returns pre-formatted text block
5. `Claude Haiku Narrative` — Execute Workflow → `claude-call` subflow with `model: haiku`, prompt produces one paragraph (≤80 words, plain English with light Pidgin, no emojis, "AI draft" header)
6. `Render Final Message` — Set node combines header, Claude paragraph, raw metrics block, footer
7. `Send to Staff WA` — Execute Workflow → `wa-send` subflow with recipient `$env.STAFF_WHATSAPP_NUMBER` and template fallback `weekly_report`
8. `Log Run to event_log` — Postgres INSERT (`workflow_name='workflow_f_reporting'`, `event='report_run_completed'`, `level='info'`, `message=<JSON of metric values + claude_paragraph>`)
9. `Log Metric Failures` (between steps 4 and 5) — scans named upstream nodes; for each that errored, writes one row to `workflow_errors`

---

## 4. Open question resolutions

- **OQ-1 Data sources:** Twenty GraphQL for candidate/application/interview/review-task counts; bookings DB direct for `workflow_errors`, `event_log`, and `ai_call_log`. Reuse observability.md SQL where it already exists.
- **OQ-2 Narrative input shape:** **Pre-formatted human-readable text block**, not JSON. Claude Haiku writes better prose from prose; easier to debug; "— unavailable —" fits inline.
- **OQ-3 Delivery:** Reuse the `wa-send` subflow. Staff number is just another recipient; wa-send already handles the 24h-window + template-fallback logic. Recipient phone via new env var `STAFF_WHATSAPP_NUMBER` (E.164).
- **OQ-4 Failure mode:** Each metric query node has `onError: continueRegularOutput`. The `Compose Report Body` Code node reads each upstream via `$('NodeName').first()?.json?.field ?? '— unavailable —'`. A single `Log Metric Failures` node before send writes one `workflow_errors` row per failed query. No fan-out/fan-in, no IF nodes for missing data.

---

## 5. Template requirement (pre-launch blocker)

A `weekly_report` template must be approved in Meta Business Manager before Workflow F goes live.

- Category: **Utility**
- Body variables: `{{1}}` = candidate-equivalent recipient name (operator first name); `{{2}}` = full rendered report text
- Document under `reference/whatsapp-templates/weekly_report.md` per the WhatsApp templates rule
- Tracking item: **T2-F-1** (analogous to T2-21 for Workflow C templates)

The template is the fallback path. Inside the 24h service window (operator messaged the bot in the last day), wa-send sends free-form first; on Meta error 131047 it falls back to this template.

---

## 6. Calibration block (weeks 1–2 only)

Gated by env var `CALIBRATION_WINDOW_ACTIVE` (already wired in `infrastructure/docker-compose.yml`).

- IF node after `Compute Date Range` checks `$env.CALIBRATION_WINDOW_ACTIVE === 'true'`
- True branch runs two extra queries (AI score vs human review-task resolution agreement, drawn from observability.md §"Calibration")
- Compose node detects calibration values and appends a "Calibration this week:" sentence to the report
- False branch skips both queries; compose node sees `undefined` → no calibration section rendered

After week 2 the operator flips the env var to `false` and recreates the n8n container; no workflow change needed.

---

## 7. Acceptance criteria (from spec)

- AC-F-1: Report delivered to staff WhatsApp every Monday 07:00 ± 5 min Africa/Accra.
- AC-F-2: Reproducible — re-running the manual trigger for the same week range produces a substantively-equivalent report (Claude paragraph wording will vary; metrics block must be identical).
- AC-F-3: Degraded mode — if any single metric query fails, the report still sends with `— unavailable —` for that metric. A `workflow_errors` row exists for each failed query.
- AC-F-4: During calibration window, the calibration block is present; outside it, absent.

---

## 8. No migrations

Explicit decision to keep v1 zero-migration:

- Spec mentions a `ReportRun` audit-trail table. **Not building it in v1.**
- Audit trail uses `event_log` instead: `workflow_name='workflow_f_reporting'`, `event='report_run_completed'`, `message` is a JSONB blob containing all metric values, the Claude paragraph, and the WA send result.
- `event_log` already has the right shape (V001 NOT NULLs: `workflow_name`, `level`, `event`); satisfies rule #13 cross-check.
- If future operational needs require a structured `report_run` table (e.g. weekly trend dashboards), revisit in v2 with a proper migration.

---

## 9. Out of scope for v1

- CEO-targeted short version (3-bullet executive summary). Deferred — operator can forward the staff report.
- PDF attachment with charts. Deferred — WhatsApp text body only.
- Per-recruiter breakdown. Deferred — the firm is small enough that the aggregate view is sufficient.
- Auto-flipping `CALIBRATION_WINDOW_ACTIVE` on day 14. Deferred — manual flip is fine for a one-time event.

---

## 10. Pre-launch checklist

- [ ] T2-F-1: `weekly_report` template approved in Meta Business Manager
- [ ] `STAFF_WHATSAPP_NUMBER` added to `.env.example` and `infrastructure/docker-compose.yml` n8n env block
- [ ] `reference/whatsapp-templates/weekly_report.md` written with purpose / variables / approval state
- [ ] Dry-run via Manual Trigger against last week's data; output reviewed by operator before first live Monday
