# Workflow F — Weekly Reporting — Build Notes

**Date:** 2026-05-03
**Spec:** `docs/02-workflows/f-reporting-design-v1.md`
**Output:** `n8n-workflows/reporting/f-reporting.json`

---

## Node inventory (32 nodes)

| # | Name | Type | Notes |
|---|------|------|-------|
| 1 | Schedule Trigger — Mon 07:00 | scheduleTrigger | cron `0 7 * * 1`, Africa/Accra |
| 2 | Manual Trigger | manualTrigger | ad-hoc runs |
| 3 | Compute Date Range | code | derives weekStartIso, weekEndIso, priorWeek* for WoW |
| 4 | Calibration Window Active? | if | gates on `$env.CALIBRATION_WINDOW_ACTIVE === 'true'` |
| 5 | Query Calibration AI Agreement | postgres | screening agree/disagree pct; alwaysOutputData true, onError continueRegularOutput |
| 6 | Query Calibration Human Decisions | postgres | human_review_resolved count in window |
| 7 | Query Twenty Candidates | httpRequest | findManyCandidates totalCount; 15s timeout, maxTries 2 |
| 8 | Query Twenty Applications | httpRequest | blueCollar + whiteCollar totalCount aliased |
| 9 | Query Twenty Interviews Scheduled | httpRequest | findManyInterviews by createdAt |
| 10 | Query Twenty Interviews Completed | httpRequest | findManyInterviews status=COMPLETED by scheduledAt |
| 11 | Query Twenty Placements | httpRequest | findManyApplications status=PLACED by updatedAt |
| 12 | Query Twenty ReviewTasks Open | httpRequest | findManyReviewTasks status=OPEN |
| 13 | Query Twenty ReviewTasks Resolved | httpRequest | findManyReviewTasks status=RESOLVED |
| 14 | Query Screening Completions | postgres | event_log WHERE event IN (...) in date range |
| 15 | Query Workflow Errors | postgres | workflow_errors count in date range |
| 16 | Query Voice Note Review Queue | postgres | event_log WHERE event='voice_note_routed_to_review' |
| 17 | Query AI Cost This Week | postgres | SUM(cost_usd) from ai_call_log this week |
| 18 | Query AI Cost Last Week | postgres | SUM(cost_usd) from ai_call_log prior week (WoW delta source) |
| 19 | Compose Report Body | code | aggregates all upstream with `?? '— unavailable —'`, returns reportText |
| 20 | Log Metric Failure — Candidates | postgres | conditional INSERT WHERE error IS NOT NULL |
| 21 | Log Metric Failure — Applications | postgres | same pattern |
| 22 | Log Metric Failure — Interviews Scheduled | postgres | same pattern |
| 23 | Log Metric Failure — Interviews Completed | postgres | same pattern |
| 24 | Log Metric Failure — Placements | postgres | same pattern |
| 25 | Log Metric Failure — Screening | postgres | same pattern |
| 26 | Log Metric Failure — AI Cost | postgres | same pattern |
| 27 | Claude Haiku Narrative | executeWorkflow | claude-call subflow, workflowInputs.value resourceMapper (rule #19) |
| 28 | Render Final Message | set | typeVersion 3.4 (rule #20); builds finalMessage with header + Claude + metrics + footer |
| 29 | Send to Staff WA | executeWorkflow | wa-send subflow, workflowInputs.value resourceMapper; template `weekly_report` |
| 30 | Log Run to event_log | postgres | INSERT workflow_name/level/event/execution_id/message; array queryReplacement |
| 31 | Error Trigger | errorTrigger | top-level fatal error catch |
| 32 | Log Fatal Error to workflow_errors | postgres | writes all NOT NULL cols; stack first line only; array queryReplacement |

---

## Key design decisions

### Sequential metric chain
All 13 metric queries run sequentially (not in parallel fan-out). Design note §4 explicitly chose this: simpler to debug, no merge node needed, and `onError: continueRegularOutput` lets any single failure flow through without stopping the chain. At the volumes this firm operates (<500 candidates) the extra ~2s latency from sequential execution is irrelevant at 07:00 Monday.

### Calibration routing
The `Calibration Window Active?` IF node gates on `$env.CALIBRATION_WINDOW_ACTIVE`. True branch runs both calibration queries then merges into the main query chain at `Query Twenty Candidates`. False branch skips directly to `Query Twenty Candidates`. The `Compose Report Body` code node reads calibration results with nullish coalescing — if the env var is false (false branch), those node outputs are absent and the calibration section is silently omitted from the report text.

### Log Metric Failures pattern
Rather than a single `Log Metric Failures` node scanning node names with dynamic references, the build uses one INSERT node per metric query. Each uses `INSERT ... WHERE $4 IS NOT NULL` — the conditional INSERT is a no-op when the metric node succeeded (no `.error` field). This avoids a Code node that would need to iterate over node names dynamically (which is fragile in n8n). The trade-off is more nodes (7 log nodes instead of 1) but each is explicit and auditable.

### queryReplacement array form throughout
All Postgres nodes use `={{ [val1, val2, ...] }}` array form per rule #18. The `Log Fatal Error to workflow_errors` stack trace uses `.split('\n')[0]` truncation and the array form to prevent comma-splitting. The `Log Run to event_log` message uses a manually-crafted `'{"week":"' + iso + '"}'` string (not JSON.stringify) per rule #18's JSONB guidance.

### Execute Workflow input shape
Both `Claude Haiku Narrative` and `Send to Staff WA` use `workflowInputs.value` resourceMapper format (typeVersion 1.3, rule #19). The `Send to Staff WA` node passes `conversationId: ""` (empty string) to match the wa-send subflow's expectation for staff messages that have no prior conversation context — the subflow's `Route Free-Form vs Template` IF node will see `seconds_since_last_inbound` as 0 (no inbound rows match empty UUID) and fall to the template path. This is intentional: the weekly report always uses the `weekly_report` template.

### Render Final Message
Set node with typeVersion 3.4 (rule #20). Combines bold header line (`*HR Weekly Report — <week>*`), Claude paragraph, horizontal rule separator, full raw metrics block, and footer line. The Claude paragraph is sourced from `$('Claude Haiku Narrative').first()?.json?.content` — the claude-call subflow's `Return Claude Response` Set node outputs `content`.

---

## Known limitations (v1)

- **TOCTOU on calibration query SQL**: The calibration SQL references `event_log` fields (`data->>'ai_score'`, `data->>'human_score'`) and a phantom `wt` subquery that always produces zero rows. This query will always return 0 agree/0 total until Workflows B/C start writing `ai_score`/`human_score` to `event_log.data`. The query is structurally correct but the data does not exist yet. Tracking: T2-F-2.
- **Twenty GraphQL field names**: The queries use `findManyCandidates`, `findManyApplications`, `findManyInterviews`, `findManyReviewTasks` with `totalCount`. These resolver names and filter argument shapes must be verified against the live Twenty v2.1.0 API on first import. If Twenty uses a different resolver name convention, update the `jsonBody` expressions. Tracking: T2-F-3.
- **wa-send conversationId empty string**: Staff WhatsApp number has no conversation history in `conversation_message` table. The wa-send subflow will always route to the template path for the weekly report. Once `STAFF_WHATSAPP_NUMBER` has sent messages into the system, this will auto-heal. No code change needed.
- **`weekly_report` template not yet approved**: Pre-launch blocker T2-F-1. The workflow will fail gracefully (wa-send error) until the template is approved in Meta Business Manager.

---

## Infrastructure changes

- `infrastructure/docker-compose.yml`: Added `STAFF_WHATSAPP_NUMBER: ${STAFF_WHATSAPP_NUMBER}` to n8n service env block.
- `infrastructure/.env.example`: Added `STAFF_WHATSAPP_NUMBER=` with comment.
- `scripts/patch-workflow-ids.sh`: Added `n8n-workflows/reporting/f-reporting.json` to file list; added `Claude Haiku Narrative → cc_id` and `Send to Staff WA → wa_id` to `NODE_TO_SUBFLOW` dict.

---

## Pre-launch checklist

- [ ] T2-F-1: `weekly_report` template approved in Meta Business Manager
- [ ] T2-F-2: Verify calibration SQL produces expected output once B/C workflows write `ai_score`/`human_score` to event_log
- [ ] T2-F-3: Verify Twenty GraphQL resolver names against live Twenty v2.1.0 API
- [ ] `STAFF_WHATSAPP_NUMBER` added to `.env` (not just `.env.example`)
- [ ] Container recreated: `docker compose up -d --force-recreate n8n`
- [ ] Dry-run via Manual Trigger reviewed by operator before first Monday
