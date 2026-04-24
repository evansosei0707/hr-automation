# Workflow F — Reporting

Weekly Monday morning summary of everything that happened in the past 7 days. Delivered to the staff WhatsApp channel.

## Purpose

No-one should have to run a report. The system pushes the numbers. Operators see the week at a glance; deeper analytics they can pull from Twenty directly.

## Triggers

- Cron: Monday 07:00 Africa/Accra
- Manual trigger for ad-hoc reports with custom date range

## Inputs

- Date range (default: past 7 days, Mon–Sun)

## Outputs

- A formatted WhatsApp message to the staff channel
- A `ReportRun` record (simple table in bookings DB) for audit trail
- Optionally: a PDF attachment with extended detail (Phase 2)

## Metrics included

**Pipeline volume:**
- New candidates this week
- New applications this week
- Applications by collar type (blue / white)

**Throughput:**
- Candidates screened (workflow B + C completions)
- Interviews scheduled
- Interviews completed
- Placements closed

**Health:**
- Review tasks opened / resolved / outstanding
- Manual-review voice notes this week
- Workflow error count

**AI cost:**
- Total Claude + OpenAI cost this week
- Per-workflow cost breakdown
- Trend vs. prior week

**Calibration (first 2 weeks only):**
- AI score vs. human review agreement rate
- Top 3 disagreement categories

## Step sequence

1. Assemble raw numbers via parameterised queries against Twenty (GraphQL) and the bookings DB.
2. Compute week-over-week deltas.
3. Feed numbers to Claude Haiku for a one-paragraph narrative summary — "this was a busy week for blue-collar driver roles; we had one client push back a shortlist for re-review."
4. Render the message template (plain text with light markdown; WhatsApp renders *bold* and _italics_).
5. Send via WhatsApp Cloud API to the staff channel.
6. Record the run in `report_run` table.

## Invariants

- Numbers must be reproducible. Every metric in the report has a canonical SQL/GraphQL query documented in `reference/report-queries.md`.
- The narrative is clearly marked as AI-generated. "Summary (AI draft):" prefix.
- If any metric query fails, the report still goes out with the working metrics and a clear "— unavailable —" for the failed ones, plus a workflow_errors row.

## Acceptance criteria

- **Monday 07:00:** the report arrives in the staff channel within 2 minutes.
- **Reproducibility:** running the report manually for last week's range produces identical numbers.
- **Degraded mode:** if the bookings DB is down, the report still includes Twenty-side numbers and explicitly notes the bookings data is unavailable.
- **Calibration block:** during weeks 1–2 after launch, the calibration metrics appear; after week 2, they are suppressed unless explicitly requested.

## Monitoring

- `workflow_f_last_run_at` gauge
- `workflow_f_metric_failures_total` counter

## Open questions

- Should the CEO get a separate, shorter version focused on placements and revenue? Probably yes in Phase 2 — not v1.
