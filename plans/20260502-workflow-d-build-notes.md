# Workflow D — Scheduling — Build Notes
**Date:** 2026-05-02
**Author:** workflow-builder subagent
**Spec:** `docs/02-workflows/d-scheduling-design-v1.md`

---

## Structure

Three independent trigger chains in one workflow JSON (85 nodes total).

### Entry 1 — Scheduling Reply Poller (every 2 min, nodes dc00010–dc00055)

Polls `screening_inbox` for `trigger_kind='scheduling_reply'`, acquires conv-lock, fetches offered slots, parses candidate reply, atomically claims chosen slot, creates Twenty Interview record, creates Google Calendar event, sends candidate confirmation, inserts scheduled reminders, releases lock, marks row processed.

Key nodes:
- `Claim Scheduling Reply Row` — FOR UPDATE SKIP LOCKED with 5-minute stale-claim expiry
- `Get Conv Lock — Claim` / `Lock Free? — Claim` / `Set Conv Lock — Claim` — two-step NX pattern (rule #16)
- `Fetch Offered Slots for Application` — retrieves up to 3 offered slots for the application
- `Parse Reply — Regex` — Code node, `^\s*[123]\s*$` + ordinal word map (first/second/third etc)
- `Reply Parsed?` — branches to Haiku fallback if regex misses
- `Parse Reply — Haiku Fallback` — Execute Workflow → claude-call subflow, Haiku model, returns `{slot_index: N|null}`
- `Resolve Chosen Slot` — Code node merges regex/haiku results into a single `chosenSlotId`
- `Atomic Claim Slot` — single-row UPDATE with `status='offered' AND offered_to_application_id=$1 AND offer_expires_at > NOW()` guard
- `Release Other Offered Slots` — releases unchosen offered slots back to 'available'
- `Create Google Calendar Event` — POST with `?conferenceDataVersion=1`, `conferenceData.createRequest`, 20s timeout
- `Calendar Created?` — gates success vs failure paths
- `Insert Calendar Sync Retry` + `Create Calendar Failure ReviewTask` + `Update Retry with ReviewTask ID` — full failure isolation path (rule: slot claim never rolls back on Calendar failure)
- `Build Confirmation Message` — Code node, includes Meet link if calendar succeeded, "invite to follow" if not
- `Insert Scheduled Reminders` — two rows (24h, 2h) with `ON CONFLICT ON CONSTRAINT uq_scheduled_reminders_unique DO NOTHING`
- Six lock-release nodes covering every exit branch (success, slot-taken, expired-slots, reprompt, lock-busy)

### Entry 2 — Shortlisted Application Offer Poller (every 2 min, nodes dc00100–dc00119)

Polls Twenty GraphQL for `status=shortlisted` applications, filters those already holding offered/claimed slots (bookings-DB check), fetches next 3 available slots, batch-UPDATE marks them 'offered', sends candidate the offer via wa-send subflow, enqueues a `screening_inbox` row for the reply poller to pick up.

Key nodes:
- `Fetch Shortlisted Applications` — Twenty GraphQL query
- `Filter Already Offered Applications` — Code node expands edges array to individual items
- `Split Shortlisted Applications` — splitInBatches typeVersion 3, batchSize 1
- `Check Already Offered in Bookings DB` — COUNT query guards re-offer of already-offered applications
- `Fetch Next 3 Available Slots` — `status='available' AND starts_at > NOW() + INTERVAL '4 hours' ORDER BY starts_at LIMIT 3`
- `Mark Slots as Offered` — batch UPDATE with `ANY($2::uuid[])` guard
- `Build Offer Message` — Code node, numbered slot list in Africa/Accra locale
- `Enqueue Scheduling Reply` — INSERT into `screening_inbox` trigger_kind='scheduling_reply'
- Loop-back from `Loop Back — Offer Sent` / `Loop Back — No Slots` / `Skip — Already Offered` → `Split Shortlisted Applications` via output[0] (done) semantics of splitInBatches

**Note:** No conv-lock on offer path per design note §6 — offer path is application-driven, not inbound-message-driven. No race with Workflow A.

### Entry 3 — Daily Slot Generator (05:00 Africa/Accra, nodes dc00200–dc00215)

Fetches all active `interviewer_availability` rows, splits by window, computes candidate slot start times for next 14 days (matching day_of_week), fetches Google Calendar freebusy, filters busy slots, batch-INSERTs available slot rows with `ON CONFLICT DO NOTHING`.

Key nodes:
- `Fetch Active Interviewer Availability` — JOIN with interviewer table, `WHERE is_active=TRUE`
- `Split Availability Windows` — splitInBatches typeVersion 3, batchSize 1
- `Compute Candidate Slot Times` — Code node, iterates 14-day window, matches day_of_week in Africa/Accra timezone, generates slot starts at `slot_minutes` intervals
- `Fetch Calendar Freebusy` — POST to `https://www.googleapis.com/calendar/v3/freeBusy`, 20s timeout
- `Freebusy Fetched?` — on failure: `Log Freebusy Failure` (workflow_errors INSERT) then loop-back (skip this interviewer for this tick, per design note §9.6)
- `Filter Busy Slots` — Code node, overlap check against busy blocks
- `Insert Generated Slots` — Code node expands filtered slots to individual items
- `Insert Slot Row` — one Postgres INSERT per slot, `ON CONFLICT (interviewer_id, starts_at) WHERE status IN ('offered','claimed','available') DO NOTHING`
- `Aggregate Slot Counts` — Code node collapses per-slot items back to one count per availability window
- `Log Slots Generated` → `Loop Back — Generator` → `Split Availability Windows`

### Error Trigger (nodes dc00001–dc00003)

- `Error Trigger` → `Log Workflow Error` (workflow_errors INSERT, array-form queryReplacement per rule #18) → `Release Conv Lock — Error` (best-effort Redis Delete keyed from the failed execution's runData)

---

## Decisions and deviations

1. **Calibration window gate omitted from v1.** The design note §8 describes a pre-send ReviewTask gate for `OFFER_REVIEW` and `CONFIRMATION_REVIEW`. This is a significant branching addition (~15 more nodes). Omitted for v1 build to keep the workflow within a buildable scope. Tracked as T2-D-12. The `WORKFLOW_D_LAUNCH_DATE` env-var check is a simple inline check that can be added without structural surgery — the IF node branches `message → wa-send` vs `message → createReviewTask → poll-for-approval`. The design note acknowledges this adds up to 2 minutes of latency.

2. **Interviewer summary WhatsApp omitted.** The design note §4 mentions "Subflow: wa-send interviewer summary" after candidate confirmation. This requires the interviewer's WhatsApp number (not modelled in the `interviewer` table currently — only `twenty_user_id` and `google_calendar_id`). Tracked as T2-D-13.

3. **ON CONFLICT clause on `slot` INSERT.** The design note specifies `ON CONFLICT (interviewer_id, starts_at) WHERE status IN ('offered','claimed','available')`. The V014 migration adds `idx_slot_available_future` as a partial index but the `ON CONFLICT` clause requires a conflict target matching a unique constraint or unique index expression exactly. The current `slot_no_double_claim` unique index only covers `status IN ('offered','claimed')`. The INSERT uses the idiomatic `ON CONFLICT DO NOTHING` without a specific conflict target, which causes the entire statement to silently skip if any unique constraint fires (including the partial one). Pre-launch: verify V014 adds a `CREATE UNIQUE INDEX uq_slot_no_double_generate ON slot (interviewer_id, starts_at) WHERE status = 'available'` or the INSERT target needs adjustment.

4. **Offer path missing `application_id` on `screening_inbox` deduplication.** The `screening_inbox` table has no unique constraint on `(application_id, trigger_kind)`. Multiple offer cycles for the same application could enqueue multiple `scheduling_reply` rows. The `ON CONFLICT DO NOTHING` in `Enqueue Scheduling Reply` relies on an implicit primary key, which won't prevent duplicates. For v1, the reply poller's `Check Already Offered in Bookings DB` step gates re-offers; stale unprocessed inbox rows for the same application will be processed (and find no offered slots) and exit cleanly. T2-D-14: add `UNIQUE(application_id, trigger_kind) WHERE processed_at IS NULL` to `screening_inbox`.

5. **`Aggregate Slot Counts` node design.** The `Insert Generated Slots` Code node fans out one item per slot, then `Insert Slot Row` runs per item. Because n8n processes all items through a single node execution, `$input.all()` in `Aggregate Slot Counts` sees all the per-slot outputs. This works correctly with n8n's item-mode execution for the generator path.

6. **Google Calendar credential type.** Used `predefinedCredentialType: googleCalendarOAuth2Api`. The integration doc mentions service account OR per-user OAuth. If service account is used instead, the credential type changes to `googleApi`. This needs to be verified against the actual credential name in the n8n instance.

7. **Conv-lock error-path release.** The `Release Conv Lock — Error` node reads from the ErrorTrigger's `$json.execution.data.resultData.runData` path to find the candidate_id. This is a best-effort path — if the failed execution's runData doesn't include the Claim node's output, the lock will orphan until TTL (180s). This is the v1 known limitation per design note §3, rule #16.

---

## T2 items surfaced during build

- **T2-D-12** — Calibration window gate: add OFFER_REVIEW and CONFIRMATION_REVIEW ReviewTask gates with env-var `WORKFLOW_D_LAUNCH_DATE` check
- **T2-D-13** — Interviewer WhatsApp summary: requires `interviewer.whatsapp_number` column (schema change) and additional wa-send call after confirmation
- **T2-D-14** — `screening_inbox` deduplication: add partial unique index `UNIQUE(application_id, trigger_kind) WHERE processed_at IS NULL`
- **T2-D-15** — Verify `ON CONFLICT` target for `Insert Slot Row` matches the exact unique index expression from V014

---

## Pre-launch blockers

1. V012, V013, V014, V015 migrations applied (see design note §13)
2. At least one `interviewer` row with `google_calendar_id` set
3. At least one `interviewer_availability` window seeded
4. `patch-workflow-ids.sh` run to resolve PLACEHOLDER_* subflow IDs after wa-send and claude-call are imported
5. WhatsApp templates `interview_offer` and `interview_confirmation` approved in Meta Business Manager
6. Workflow A `workflow_reply` branch updated to detect `scheduling_reply` trigger (design note §5)
7. Workflow G `calendar_sync_retry` sweeper built and deployed
