# Workflow H — Job Alerts / Re-Engagement — Build Notes

Date: 2026-05-03
Builder: workflow-builder (claude-sonnet-4-6)

---

## File produced

`n8n-workflows/job-alerts/h-job-alerts.json` — 31 nodes

---

## Structure

Three independent cron chains inside one workflow, all sharing a single Error Trigger.

### Chain 1 — JobPosting scanner (5-min cron, nodes 1–21)

| Node | Type | Role |
|---|---|---|
| Schedule Trigger — 5 min | scheduleTrigger | Fires every 5 minutes |
| Manual Trigger | manualTrigger | Second entry point for ad-hoc backfill |
| Compute Scan Window | Code | Computes `windowStart`, `sixMonthsAgo`, `ninetyDaysAgo`, `fourteenDaysAgo`, `currentYear` |
| Query New Open JobPostings | httpRequest | Twenty GraphQL `findManyJobPostings` filtered by `status=OPEN, postedAt >= windowStart` |
| Any New Postings? | IF | Length check — exits early if no new postings |
| Read Dedup State | Postgres executeQuery | Reads `h_processed_postings` JSON array from `candidate_facts` system row |
| Filter Unprocessed Postings | Code | Removes already-processed posting IDs from the current batch |
| Any Unprocessed? | IF | Exits if all postings already processed in a previous run |
| SplitInBatches — Postings | splitInBatches | batchSize=1, iterates one posting at a time |
| Query Eligible Applications | httpRequest | Twenty GraphQL `findManyApplications` with `reEngagementEligible=true, createdAt >= sixMonthsAgo, category=<posting.category>` — includes nested candidate fields and application statuses |
| Filter Candidates | Code | Phase-2 filter: consent, dataRetentionPolicy, lastActivityAt, busy-status exclusion, anti-spam proxy (reEngagedAt field), sort by strengthTier/recency, limit 20 |
| Any Candidates? | IF | Exits to `Mark Posting Processed` if no eligible candidates |
| SplitInBatches — Candidates | splitInBatches | batchSize=1, iterates one candidate at a time |
| Read Anti-Spam State | Postgres executeQuery | Reads `last_reengaged_at` and `reengagement_count_ytd` per candidate, `alwaysOutputData: true` at node root |
| Evaluate Anti-Spam Eligibility | Code | Computes `spamCheckOk = 'yes' or ''` — avoids boolean-equal-JS-expr audit pattern (Rule #28 analogue) |
| Anti-Spam Check | IF | Tests `spamCheckOk notEmpty` — passes if candidate is outside 14-day cooldown AND under 4/year limit |
| Compose WA Message | executeWorkflow → claude-call | claude-haiku-4-5, max 120 tokens, strict system prompt |
| Create Application | httpRequest | Twenty GraphQL `createApplication` with `status=RE_ENGAGEMENT_OFFERED, reEngagedAt=NOW()` |
| Send Re-engagement WA | executeWorkflow → wa-send | templateName=re_engagement_v1 (always a template — candidate is cold) |
| Update Anti-Spam State | Postgres INSERT...ON CONFLICT | Updates `last_reengaged_at` and `reengagement_count_ytd`; year-rollover resets count to 1 |
| Mark Posting Processed | Postgres INSERT...ON CONFLICT | Appends posting ID to `h_processed_postings` array on `system-h-dedup` row |
| Log Run | Postgres INSERT | event_log: `re_engagement_run_completed` |

Loop flow: `Update Anti-Spam State → SplitInBatches — Candidates` (continue loop). `Log Run → SplitInBatches — Postings` (continue posting loop).

### Chain 2 — 72h timeout sweep (hourly cron, nodes 30–36)

| Node | Type | Role |
|---|---|---|
| Schedule Trigger — Hourly | scheduleTrigger | Fires every hour |
| Compute Timeout Cutoff | Code | Computes `seventyTwoHoursAgo` |
| Query Expired Offers | httpRequest | Twenty GraphQL: applications where `status=RE_ENGAGEMENT_OFFERED AND reEngagedAt < 72hAgo` |
| Any Expired? | IF | Length check on returned edges |
| SplitInBatches — Expired | splitInBatches | batchSize=1 |
| Withdraw Application | httpRequest | Twenty GraphQL `updateApplication` → `status=WITHDRAWN` |
| Log Timeout | Postgres INSERT | event_log: `re_engagement_timeout` |

Loop: `Log Timeout → SplitInBatches — Expired`.

### Error Trigger (nodes 99–100)

Standard Error Trigger → `Log Workflow Error` (Postgres INSERT into `workflow_errors`). Stack trace truncated to first line. All NOT NULL columns bound (`workflow_name`, `execution_id`, `error_message`). Array-form queryReplacement (Rule #18).

---

## Non-obvious choices

**Dedup via `candidate_facts` JSONB on `system-h-dedup` row.** No new table needed. The existing `candidate_facts` table with JSONB `facts` column is the appropriate place for system-scoped state as per the design note (OQ-3). The system row is created on first INSERT via `ON CONFLICT DO UPDATE`.

**Two-phase candidate filtering.** Phase 1 is done in Twenty GraphQL (category match, eligibility flag, 6-month window). Phase 2 is a Code node that applies the remaining in-memory filters (consent, busy-check, anti-spam proxy). This avoids N+1 queries and keeps the busy-check zero-cost (nested `applications.edges` in the same query).

**Anti-spam evaluated twice.** `Filter Candidates` uses `reEngagedAt` from Twenty as a cheap proxy to prune the list. The authoritative per-candidate check is `Read Anti-Spam State` → `Evaluate Anti-Spam Eligibility` → `Anti-Spam Check` which reads the bookings DB `candidate_facts` JSONB. This two-stage approach avoids the bookings DB read for obviously ineligible candidates.

**`spamCheckOk` Code node pattern.** The IF node uses `string notEmpty` on `spamCheckOk` instead of a `boolean equal true` on a JS-expression leftValue. This avoids the `BOOLEAN_EQUAL_JS_EXPR` audit failure (n8n 2.18.5 routes all items to false when boolean-equal is used with a JS IIFE expression).

**SplitInBatches output[0] = loop body.** Consistent with c-screening.json and d-scheduling.json in this project. The audit tool flags this as informational only; it is the correct wiring for the n8n 2.x splitInBatches typeVersion=3.

**`alwaysOutputData: true` on all Postgres write nodes.** INSERT...ON CONFLICT queries return 0 rows on a no-op conflict update. Without `alwaysOutputData: true` at node root, the execution chain halts. Set on: `Update Anti-Spam State`, `Mark Posting Processed`, `Log Run`, `Log Timeout`, `Log Workflow Error`.

**No Redis lock.** Workflow H does not hold a conversation lock. It is a background cron, not a real-time message handler. Dedup is handled via the `h_processed_postings` JSONB array.

---

## Rules compliance checklist

| Rule | Status |
|---|---|
| #1 Error Trigger → workflow_errors | Done |
| #2 HTTP Request timeout + retry | Done (all HTTP nodes: timeout 15000, maxTries 2) |
| #3 Postgres credentials via n8n system | Done (PLACEHOLDER_POSTGRES credential) |
| #8 Human-readable node names | Done |
| #9 Workflow tags | Done (hr-automation, workflow-h, version-1) |
| #13 NOT NULL columns bound | Done |
| #18 queryReplacement array form | Done on all Postgres writes |
| #19 Execute Workflow workflowInputs.value | Done on both subflow calls |
| #20 Set node typeVersion 3.4 | N/A (no Set nodes in this workflow) |
| #21 patch-workflow-ids.sh explicit mapping | Done |
| #24 alwaysOutputData at node root | Done on all read+write Postgres nodes |
| #25 h-job-alerts.json added to patch script file list | Done |
| #29 $env vars in docker-compose | TWENTY_API_URL, TWENTY_API_KEY already mapped |

---

## Pre-launch blockers (from design note)

- [ ] V017 Twenty schema migration: add `RE_ENGAGEMENT_OFFERED`, `RE_ENGAGEMENT_ACCEPTED` to Application.status, `FAST_TRACK_CANDIDATE` to ReviewTask.kind
- [ ] `re_engagement_v1` WhatsApp template approved in Meta Business Manager
- [ ] Workflow A routing updated for `re_engagement_reply` trigger_kind (T2-H-1)

---

## Known v1 limitations / T2 items

- **T2-H-1 (Workflow A):** Workflow A must detect candidates with an open `RE_ENGAGEMENT_OFFERED` Application and enqueue their replies with `trigger_kind='re_engagement_reply'`. Chain 2 (reply handler from design note) is deferred until Workflow A routing is updated.
- **One-per-day invariant:** The spec says "no candidate gets a re-engagement from more than one open job on the same day." The current Code node uses a 14-day cooldown (more restrictive than daily), which satisfies the invariant but does not implement the "queue others for later" fallback. T2 item.
- **TOCTOU on dedup:** The `Read Dedup State` + `Mark Posting Processed` pattern has a race if two executions overlap. Acceptable at v1 cron volume.
