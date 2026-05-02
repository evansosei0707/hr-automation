# Workflow D — Scheduling Design Note v1

**Status:** Ready for workflow-builder dispatch
**Date:** 2026-05-02
**Author:** architect subagent + Claude Code
**Spec base:** `docs/02-workflows/d-scheduling.md`

This note resolves the four design questions surfaced for Workflow D plus the spec's existing rescheduling open question, and fills in the implementation detail workflow-builder needs to produce JSON. Read the spec first; this extends it, not replaces it.

---

## 1. Decision summary

**OQ-1 — Slot sourcing: hybrid (operator-defined weekly windows + daily generator + Calendar busy veto).**

The Operations Lead seeds a small `interviewer_availability` table with weekly recurring windows per interviewer (e.g. Mon–Fri 09:00–17:00). A daily Cron in Workflow D generates concrete `slot` rows for the next 14 days at fixed 45-minute increments. Before INSERTing, the generator queries Google Calendar `freebusy.query` for the same window and skips any slot that overlaps an existing event (interviewer's personal commitments). This keeps the offer-path latency low (no synchronous Calendar call when offering slots) while avoiding manual weekly seeding toil. See ADR-0012.

**OQ-2 — Expiry sweep ownership: Workflow G owns it, per existing spec.**

`g-orchestration.md` §"Stuck state sweepers" already specifies `UPDATE slot SET status='available' WHERE status='offered' AND offer_expires_at < NOW()` runs every 5 minutes in Workflow G. Workflow D depends on this and does NOT duplicate it. The design adds one piece: when D detects on offer-attempt that all 3 candidate slots have expired (rowcount=0 on every claim attempt), D itself triggers an immediate fresh offer cycle rather than waiting for G. This is the same precedent as Workflow C's reminder/withdraw sweep being in C: cross-workflow sweep stays where the spec puts it; in-loop self-correction stays local. Trade-off acknowledged: if G ships late, expired offers will linger as `offered` rows blocking the partial unique index, but D's claim transaction's `offer_expires_at > NOW()` predicate makes them functionally invisible — they just take up a row. Pre-launch blocker: G's expired-slot sweeper must ship at the same time as D, or sooner.

**OQ-3 — Candidate reply parsing: tiered (regex first, Haiku fallback).**

The first node attempts `^\s*[123]\s*$` after trim. On match → claim path with that index. On miss → Claude Haiku `claude-call` subflow with the candidate text + the 3 offered slot descriptions, returning `{slot_index: 1|2|3|null}`. On `null` (cannot determine) → polite reprompt "please reply 1, 2, or 3". Workflow C already uses Haiku for free-text normalisation and the cost is bounded (~$0.0003 per Haiku call). This matches `c-blue-collar-design-v1.md` §1 Q3: deterministic for the structured path, LLM only for ambiguity.

**OQ-4 — Google Calendar failure isolation: confirmed per spec, with explicit recovery path.**

Calendar failure does NOT roll back the slot claim. A `ReviewTask` with `kind=calendar_sync_failure` and a JSONB payload of intended event details is created, owned by the Operations Lead. Workflow G's hourly retry queue (new sweeper, see §V-migration) attempts the Calendar create up to 3 more times before the ReviewTask becomes manual-only. **Notification ordering is changed from the spec's implied order:** D notifies the candidate AFTER the Calendar attempt, so a Calendar failure never leaves a candidate uninformed of a Calendar-less booking — the candidate confirmation message simply omits the Meet link if Calendar failed (and a follow-up message with the link is sent when G's retry succeeds). Interviewer-side notification (WhatsApp summary) fires regardless of Calendar status; the summary explicitly states "calendar pending" if Calendar failed so the interviewer knows to expect a manual entry. See §9.2 for the full path.

**Spec's existing OQ — Rescheduling: fresh offer cycle, flagged `reschedule=true`.**

The spec's stated default holds. Inline rescheduling ("here are 2 alternatives in the same thread") is out of scope for v1 because it requires the candidate to mentally diff the new options against the old; a fresh cycle is cognitively simpler and reuses the entire offer/claim/notify path with only a flag passed to the Twenty `Interview` row (`isReschedule: true`) for analytics. The previous `Interview` is updated to `status=rescheduled` and its calendar event deleted. T2-D-3 covers inline rescheduling once we have data on whether the fresh cycle has acceptable UX cost.

---

## 2. V-migrations needed

Current last applied migration: V011.

### V012 — `interviewer_availability` weekly windows

```sql
-- V012__interviewer_availability.sql
-- Purpose: per-interviewer recurring availability windows. The daily Workflow D
--   slot generator reads this table to materialise concrete slot rows for the
--   next 14 days, vetoed by Google Calendar busy time.
-- Spec: docs/02-workflows/d-scheduling-design-v1.md §3, ADR-0012

CREATE TABLE interviewer_availability (
  id              BIGSERIAL    PRIMARY KEY,
  interviewer_id  UUID         NOT NULL REFERENCES interviewer(id) ON DELETE CASCADE,
  day_of_week     INT          NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),  -- 0=Sun
  starts_local    TIME         NOT NULL,
  ends_local      TIME         NOT NULL,
  slot_minutes    INT          NOT NULL DEFAULT 45,
  is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT availability_window_valid CHECK (ends_local > starts_local)
);

CREATE INDEX idx_interviewer_availability_active
  ON interviewer_availability (interviewer_id, day_of_week)
  WHERE is_active = TRUE;
```

Times are stored in `Africa/Accra` local (per the `interviewer.timezone` column; v1 treats all interviewers as Accra). Generator converts to UTC at materialisation.

### V013 — `scheduled_reminders` + `calendar_sync_retry`

```sql
-- V013__scheduled_reminders_and_calendar_retry.sql
-- Purpose: (a) scheduled_reminders table holds 24h and 2h interview reminders
--   that Workflow G's reminder sweep dispatches. (b) calendar_sync_retry holds
--   pending Google Calendar event-create retries owned by Workflow G's hourly tick.

CREATE TABLE scheduled_reminders (
  id               BIGSERIAL    PRIMARY KEY,
  kind             TEXT         NOT NULL
                     CHECK (kind IN ('interview_24h','interview_2h')),
  fire_at          TIMESTAMPTZ  NOT NULL,
  twenty_interview_id  TEXT     NOT NULL,
  candidate_id     TEXT         NOT NULL,
  application_id   TEXT         NOT NULL,
  payload          JSONB        NOT NULL,         -- pre-rendered template variables
  sent_at          TIMESTAMPTZ,
  failed_at        TIMESTAMPTZ,
  failure_reason   TEXT,
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_scheduled_reminders_due
  ON scheduled_reminders (fire_at)
  WHERE sent_at IS NULL AND failed_at IS NULL;

CREATE UNIQUE INDEX uq_scheduled_reminders_unique
  ON scheduled_reminders (twenty_interview_id, kind);

CREATE TABLE calendar_sync_retry (
  id                BIGSERIAL    PRIMARY KEY,
  slot_id           UUID         NOT NULL REFERENCES slot(id) ON DELETE CASCADE,
  twenty_interview_id  TEXT      NOT NULL,
  intended_event    JSONB        NOT NULL,        -- full event body for retry
  attempts          INT          NOT NULL DEFAULT 0,
  last_attempt_at   TIMESTAMPTZ,
  last_error        TEXT,
  succeeded_at      TIMESTAMPTZ,
  abandoned_at      TIMESTAMPTZ,                  -- set when attempts >= 3
  review_task_id    TEXT,                         -- Twenty ReviewTask UUID
  created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_calendar_sync_retry_pending
  ON calendar_sync_retry (last_attempt_at NULLS FIRST)
  WHERE succeeded_at IS NULL AND abandoned_at IS NULL;
```

### V014 — `slot` table additions

```sql
-- V014__slot_extensions.sql
-- Purpose: support hybrid slot generation and reschedule semantics.

ALTER TABLE slot
  ADD COLUMN generation_source TEXT NOT NULL DEFAULT 'manual'
    CHECK (generation_source IN ('manual','generator','reschedule')),
  ADD COLUMN generated_at TIMESTAMPTZ,
  ADD COLUMN reschedule_of_slot_id UUID REFERENCES slot(id);

CREATE INDEX idx_slot_available_future
  ON slot (interviewer_id, starts_at)
  WHERE status = 'available' AND starts_at > NOW();
```

Migration sequencing: V012, V013, V014 must all apply before Workflow D activates. V012 must apply before the first daily generator run; V013 must apply before the first slot is claimed (else `Interview` create cannot enqueue reminders); V014 supplies the index used on every offer-path query.

---

## 3. Slot sourcing — daily generator (OQ-1 detail)

**Cron: every day 05:00 Africa/Accra.** A separate trigger context on Workflow D.

```
[Cron 05:00 Accra]
  |
[Postgres: SELECT * FROM interviewer JOIN interviewer_availability
           WHERE interviewer.is_active AND interviewer_availability.is_active]
  |
[For each (interviewer, weekly window):]
  |
[Code: enumerate concrete slot start times for next 14 days, in UTC]
  |
[Google Calendar freebusy.query for that interviewer's google_calendar_id,
 timeMin = NOW(), timeMax = NOW() + 14 days]
  |
[Code: filter out slots overlapping any busy block]
  |
[Postgres: INSERT INTO slot (interviewer_id, starts_at, ends_at, status,
           generation_source, generated_at)
           VALUES (..., 'available', 'generator', NOW())
           ON CONFLICT (interviewer_id, starts_at) WHERE status IN
             ('offered','claimed','available') DO NOTHING]
  |
[Exit]
```

**Idempotency:** the partial unique index `uq_slot_no_double_claim` only covers `offered` and `claimed`. To make the generator idempotent across statuses, the INSERT uses `ON CONFLICT DO NOTHING` against a more permissive lookup — see V014's `idx_slot_available_future`. If a row with the same `(interviewer_id, starts_at)` already exists in any status, the generator skips it.

**Calendar veto failure:** if `freebusy.query` errors, the generator skips this interviewer for this tick (no partial generation) and logs `workflow_errors` warning. Next day's Cron retries. Stale-busy risk is tolerable: at most 24h of stale calendar data, mitigated by the operator's ability to manually mark a slot `cancelled` if a personal conflict comes up.

**Manual operator override:** the operator can directly INSERT a slot row with `generation_source='manual'`. The generator never deletes manual rows. Operator-deletes go through `status='cancelled'`, never DELETE.

---

## 4. State machine

```
[Application status → 'shortlisted' detected by Workflow D's 2-min Cron]
  |
[Postgres: SELECT 3 next slots WHERE status='available' AND starts_at > NOW() + INTERVAL '4 hours'
           AND interviewer_id IN (preferred set or all active)
           ORDER BY starts_at LIMIT 3]
  |
[Got 3?]
  NO --> [Twenty: createReviewTask kind=NO_SLOTS_AVAILABLE
          subjectApplication=appId dueBy=NOW()+2h]
         [Exit]
  YES
  |
[BEGIN; UPDATE 3 rows SET status='offered', offered_to_application_id=appId,
                          offered_at=NOW(), offer_expires_at=NOW()+24h
        WHERE id IN (s1,s2,s3) AND status='available' RETURNING id;
        COMMIT]
  |
[rowcount = 3?]
  NO --> [Release any rows that did flip back to 'available' (Code computes diff)]
         [Loop: try next 3 with stricter LIMIT — bounded retry, max 2 iterations]
         [If still <3: createReviewTask NO_SLOTS_AVAILABLE; exit]
  YES
  |
[Build candidate message: numbered 1/2/3 with day + time in Africa/Accra,
 e.g. "1. Tuesday 5 May, 10:00 AM"]
  |
[If calibration window ON: createReviewTask kind=OFFER_REVIEW
   subjectApplication=appId, payload includes the message body]
  |
[Subflow: wa-send (offer message)]
  |
[Postgres: INSERT INTO booking_event_log (slot_id, event_type='offer_sent',
           actor='workflow_d', payload={appId, candidateId})]
  |
[Exit — wait for reply via Workflow A → screening_inbox routing]


─── Claim path (separate Cron context, 60s, claims screening_inbox blue/white-collar
    is unchanged; this adds a new trigger_kind 'scheduling_reply') ────────

[Cron 60s]
  |
[Postgres: claim oldest unprocessed screening_inbox row
           WHERE trigger_kind = 'scheduling_reply' FOR UPDATE SKIP LOCKED LIMIT 1
           — alwaysOutputData: true at root level (rule #24)]
  |
[Row claimed?]
  NO --> [Exit]
  YES
  |
[Redis: acquire conv-lock hra:conv:{candidateId} (180s TTL, rule #16 two-step pattern)]
  |
[Lock acquired?]
  NO --> [Mark inbox failed (leave processed_at NULL); exit — re-claim next tick]
  YES
  |
[Postgres: SELECT 3 most recent offered slots for this application_id
           WHERE status='offered' AND offered_to_application_id=appId
           ORDER BY offered_at DESC LIMIT 3]
  |
[Got 3?]
  NO --> [Subflow: wa-send "your slots have expired, here are fresh options"]
         [Re-enter offer path for this application]
         [Release lock; mark inbox processed; exit]
  YES
  |
[Code: regex parse messageBody for ^\s*[123]\s*$]
  |
[Match?]
  YES --> [chosenIndex = match]
  NO  --> [Subflow: claude-call (Haiku) with messageBody + 3 slot descriptions,
           expecting JSON {slot_index: 1|2|3|null}]
          |
          [Parsed slot_index null?]
            YES --> [Subflow: wa-send reprompt]
                    [Release lock; mark inbox processed; exit]
            NO  --> [chosenIndex = parsed]
  |
[chosenSlotId = slots[chosenIndex - 1].id]
  |
[BEGIN;
 UPDATE slot SET status='claimed', claimed_by_application_id=appId,
                 claimed_at=NOW(), updated_at=NOW()
   WHERE id=chosenSlotId AND status='offered'
         AND offered_to_application_id=appId AND offer_expires_at > NOW();
 INSERT INTO booking_event_log (slot_id, event_type='claim_attempt', ...);
 COMMIT]
  |
[rowcount = 1?]
  NO --> [Subflow: wa-send "that slot is no longer available — here are fresh options"]
         [Re-enter offer path]
         [Release lock; mark inbox processed; exit]
  YES
  |
[Postgres: UPDATE slot SET status='available', offered_to_application_id=NULL,
                           offered_at=NULL, offer_expires_at=NULL
           WHERE offered_to_application_id=appId AND status='offered'
                 AND id != chosenSlotId
           — releases the other two]
  |
[Twenty mutation: createInterview (linked to Application, Candidate, Interviewer)]
  |
[Postgres: UPDATE slot SET twenty_interview_id=$id WHERE id=chosenSlotId]
  |
[Google Calendar: POST event with conferenceData createRequest]
  |
[Calendar success?]
  YES --> [Twenty: updateInterview SET calendarEventId, meetLink]
  NO  --> [Postgres: INSERT calendar_sync_retry (slot_id, twenty_interview_id,
                     intended_event, attempts=0)]
          [Twenty: createReviewTask kind=calendar_sync_failure
                   subjectApplication=appId payload={...}]
          [Postgres: UPDATE calendar_sync_retry SET review_task_id=$id]
  |
[Build candidate confirmation: date, time, interviewer name, Meet link if available
 OR "calendar link to follow shortly" if not]
  |
[If calibration window ON: createReviewTask kind=CONFIRMATION_REVIEW
   subjectApplication=appId, payload=message body — gate the WA send on review]
  |
[Subflow: wa-send candidate confirmation]
  |
[Subflow: wa-send interviewer summary (with "calendar pending" note if applicable)]
  |
[Postgres: INSERT scheduled_reminders for 24h-before and 2h-before]
  |
[Postgres: INSERT booking_event_log event_type='claimed']
  |
[Release conv-lock; mark inbox processed; exit]
```

---

## 5. Triggers

Workflow D has three Cron contexts:

| Context | Cron | Purpose |
|---|---|---|
| 1 — Offer path | every 2 min | Polls Twenty for `Application.status='shortlisted'` not yet linked to an offered slot, sends offer |
| 2 — Claim path | every 60 sec | Polls `screening_inbox` for `trigger_kind='scheduling_reply'`, processes |
| 3 — Slot generator | daily 05:00 Accra | Generates `slot` rows for next 14 days |

Plus the standard Error Trigger.

**Workflow A change required:** the `workflow_reply` branch must check whether the candidate has any active `slot` rows with `status='offered'` AND `offered_to_application_id` matching one of their open Applications. If yes, route as `trigger_kind='scheduling_reply'`. The check is one Postgres query, gated on the existing `workflow_reply` branch — same pattern as the `blue_collar_reply` routing added in V011.

**`screening_inbox.trigger_kind` CHECK update:** V011 currently allows `('new_application','open_conversation','blue_collar_new','blue_collar_reply')`. Workflow D requires adding `'scheduling_reply'`. This is a small CHECK ALTER bundled into V015 (or V013, at the implementor's discretion — recommend V015 to keep migration concerns separate).

### V015 — `screening_inbox` trigger_kind extension

```sql
-- V015__screening_inbox_scheduling_reply.sql
ALTER TABLE screening_inbox
  DROP CONSTRAINT screening_inbox_trigger_kind_check,
  ADD CONSTRAINT screening_inbox_trigger_kind_check
    CHECK (trigger_kind IN (
      'new_application','open_conversation',
      'blue_collar_new','blue_collar_reply',
      'scheduling_reply'
    ));
```

---

## 6. Conv-lock acquisition points

| Event | Lock action | Lock key | Token |
|---|---|---|---|
| Claim path: Workflow D claims `scheduling_reply` inbox row | Acquire (rule #16 two-step) | `hra:conv:{candidateId}` | `$execution.id` |
| Offer path | NO LOCK | — | — |
| All exit branches in claim path | Release (CAS DEL, rule #16 two-step) | same | same |
| Error Trigger | Release (CAS DEL — only if held) | same | same |

**Offer path runs without a conv-lock** because it is application-driven, not inbound-message-driven, and does not race with Workflow A. The single WhatsApp send is to a candidate who, by spec, just had their status set to `shortlisted` by an operator — no live conversation race.

**Lock TTL: 180s flat** (CLAUDE.md invariant #3 footnote: true Lua CAS heartbeat deferred to T2-12).

---

## 7. Twenty GraphQL writes

```graphql
# Offer path: poll for shortlisted Applications without an active offer.
query FindShortlistedNeedingOffer {
  applications(filter: {
    AND: [
      { status: { eq: "shortlisted" } }
      # Cross-checked in n8n against bookings-DB slot table for active offers
    ]
  }) {
    edges { node {
      id
      candidate { id whatsappNumber firstName }
      jobPosting { id title }
      preferredInterviewerId
    } }
  }
}

# Claim path: create the Interview record (Twenty's no-`One`-infix convention)
mutation CreateInterview(
  $applicationId: ID!, $candidateId: ID!, $interviewerId: ID!,
  $scheduledAt: DateTime!, $bookingId: String!, $isReschedule: Boolean!
) {
  createInterview(data: {
    application: { connect: { id: $applicationId } }
    candidate:   { connect: { id: $candidateId } }
    interviewer: { connect: { id: $interviewerId } }
    scheduledAt: $scheduledAt
    bookingId:   $bookingId
    isReschedule: $isReschedule
    status:      "scheduled"
  }) { id }
}

# Update Interview after Calendar event create (success path)
mutation UpdateInterviewCalendar(
  $id: ID!, $calendarEventId: String!, $meetLink: String!
) {
  updateInterview(id: $id, data: {
    calendarEventId: $calendarEventId
    meetLink:        $meetLink
  }) { id }
}

# Update Application status
mutation UpdateApplicationScheduled($id: ID!) {
  updateApplication(id: $id, data: { status: "interview_scheduled" }) { id }
}

# Reschedule path: mark the prior Interview rescheduled
mutation RescheduleInterview($id: ID!) {
  updateInterview(id: $id, data: { status: "rescheduled" }) { id }
}

# ReviewTask — subjectApplication (rule #11)
mutation CreateReviewTask(
  $applicationId: ID!, $kind: String!, $dueBy: DateTime!, $payload: String!
) {
  createReviewTask(data: {
    subjectApplication: { connect: { id: $applicationId } }
    kind:    $kind        # 'OFFER_REVIEW' | 'CONFIRMATION_REVIEW' |
                          # 'NO_SLOTS_AVAILABLE' | 'calendar_sync_failure'
    dueBy:   $dueBy
    status:  "OPEN"
    payload: $payload     # JSON-stringified per Workflow B OQ-8 pattern
  }) { id }
}
```

---

## 8. Calibration-window guard

Per CLAUDE.md procedural rule, every user-facing message in the first 2 weeks after launch must be human-reviewed. Three D-emitted message kinds need gating:

| Message | Calibration gate |
|---|---|
| Offer message ("Here are 3 slots…") | Pre-send `OFFER_REVIEW` ReviewTask; gated send (operator approves before WA goes out) |
| Candidate confirmation ("You're booked for…") | Pre-send `CONFIRMATION_REVIEW` ReviewTask; gated send |
| Interviewer summary | NOT gated — internal recipient, not candidate-facing |
| 24h / 2h reminders (sent by Workflow G) | Workflow G owns its own calibration gate; D writes the `scheduled_reminders` rows but the send-time message body is rendered + reviewed by G |
| Reprompt / "slot expired" / "slot taken" | NOT gated individually — they are short, formulaic, and triggered by candidate ambiguity not workflow choice; spot-checked via `event_log` |

**Env var:** `WORKFLOW_D_LAUNCH_DATE` (ISO-8601). If unset, calibration is ON (fail-safe). Calibration ON: every `OFFER_REVIEW` and `CONFIRMATION_REVIEW` ReviewTask gates the corresponding WA send. Calibration OFF: send proceeds; ReviewTask is created only on tier promotions or anomalies.

**Gate mechanism:** the WA send node sits behind an IF that checks `calibration_active` (computed at workflow start from env). If active, the workflow path branches: createReviewTask, then a separate Cron in Workflow D's claim context polls for `OFFER_REVIEW` tasks with `status='APPROVED'` and emits the WA send. This adds up to 2 minutes of latency per gated send during calibration — acceptable for a 14-day window.

---

## 9. Error paths

### 9.1 Lock contention on claim path

Same pattern as Workflow C §9.1: mark inbox row failed (leave `processed_at` NULL), exit, next 60s tick re-claims after the stale-claim clause `claimed_at < NOW() - INTERVAL '5 minutes'` lets the row through.

### 9.2 Calendar event-create failure

The slot is already `claimed` and the `Interview` record already exists in Twenty. The transaction never rolls back. Path:

1. Insert `calendar_sync_retry` row with full intended event body, `attempts=0`.
2. Create `ReviewTask` `kind=calendar_sync_failure`, link via `review_task_id`.
3. Notify candidate with confirmation that omits the Meet link ("calendar invite to follow shortly").
4. Notify interviewer with "calendar pending" note.
5. Workflow G's hourly tick (new sweeper, see §V-migration V013) iterates `calendar_sync_retry WHERE succeeded_at IS NULL AND abandoned_at IS NULL ORDER BY last_attempt_at NULLS FIRST LIMIT 10`:
   - Increment `attempts`, `last_attempt_at = NOW()`.
   - Try Calendar create.
   - On success: set `succeeded_at`, update Twenty `Interview` with `calendarEventId` and `meetLink`, send candidate a follow-up WhatsApp with the link, close the ReviewTask.
   - On failure: write `last_error`. If `attempts >= 3`: set `abandoned_at = NOW()`, leave the ReviewTask open for the Operations Lead to manually handle.

**Why notify-after-Calendar:** the spec implied claim → Calendar → notify, which leaves a candidate uninformed if Calendar fails. The change to claim → Calendar attempt → notify (with conditional Meet link) means every booking yields a candidate confirmation. This is a minor change to the ordering described in `d-scheduling.md` §"Step sequence — claiming a slot" steps 7–8; the spec authors likely intended notification to be unconditional but did not state it.

### 9.3 Twenty `createInterview` mutation fails after slot claim

The slot row is claimed in bookings DB but no `Interview` exists in Twenty. The Error Trigger:
1. Releases conv-lock.
2. Writes `workflow_errors` (rule #18 array form, rule #13 NOT NULL bindings).
3. Marks inbox row failed (leaves `processed_at` NULL).
4. Next 60s Cron re-claims the inbox row, re-runs the path. The slot-claim UPDATE is idempotent (already-claimed slot with same `claimed_by_application_id` is detected by the Code node before re-attempting; only the `createInterview` step retries).
5. If retry-count exceeds 3 in `screening_inbox.payload.retry_count`: createReviewTask `kind=WORKFLOW_ERROR` and stop retrying.

### 9.4 Candidate replies after `offer_expires_at`

The atomic claim returns rowcount=0 (the predicate `offer_expires_at > NOW()` fails). The reply path catches this and sends "that slot has passed — here are fresh options" then re-enters the offer path with bounded retry (max 2 attempts). The G-owned expired-offer sweeper independently flips the row back to `available`.

### 9.5 Candidate replies "any time" or pure noise

Regex misses → Haiku call returns `slot_index: null` → reprompt sent. Re-prompts are NOT counted; a candidate can reprompt indefinitely. After 3 consecutive reprompts on the same offer set, a `ReviewTask` `kind=SCHEDULING_AMBIGUITY` is created so an operator can intervene by phone. Counter is stored in `screening_inbox.payload.reprompt_count` (incremented per reply against the same offer set).

### 9.6 `freebusy.query` failure during slot generation

Generator skips this interviewer for this tick. Logs `workflow_errors` warning. Next day retries. If `freebusy.query` has been failing for >3 consecutive days for the same interviewer, Workflow G's health sweep raises a `system_incident` (T2-D-5).

### 9.7 No slots available for offer

The next-3-slots query returns < 3 rows. Workflow creates `ReviewTask` `kind=NO_SLOTS_AVAILABLE` with the application context. Operations Lead either adds manual slot rows or extends `interviewer_availability`. Workflow D's 2-min poll re-tries automatically once slots exist.

---

## 10. n8n rule trap-points

Workflow-builder must apply these rules from `.claude/rules/n8n-workflows.md`:

- **Rule #11** — every `ReviewTask` write sets `subjectApplication` (never `subjectCandidate`).
- **Rule #13** — `workflow_errors` NOT NULL bindings: `workflow_name`, `execution_id`, `error_message`. Use array-form queryReplacement.
- **Rule #16** — Redis lock acquire/release uses two-step Get → If → Set/Delete (no `executeCommand`, no NX). `propertyName: "value"` set explicitly on every Redis Get node.
- **Rule #18** — array-form `queryReplacement` for all Postgres nodes writing user-supplied or system text. Targets in D: candidate message bodies in `event_log` payloads, error messages, the offer message body inside `OFFER_REVIEW` ReviewTask payload.
- **Rule #19** — `workflowInputs.value` resourceMapper for all Execute Workflow (claude-call, wa-send) nodes.
- **Rule #20** — `typeVersion: 3.4` on every Set node that uses `assignments`.
- **Rule #21** — every Execute Workflow node name added to `scripts/patch-workflow-ids.sh`'s `NODE_TO_SUBFLOW` dict before commit.
- **Rule #22** — read source data directly from the producing node, not via intermediate Set nodes. Specifically: `chosenSlotId` from the slot-fetch Postgres node, `candidateId` from inbox claim, `messageBody` from inbox `payload.messageBody`.
- **Rule #24** — `alwaysOutputData: true` at node ROOT level (NOT in `parameters.options`) on every Postgres node that may return zero rows: the inbox claim, the offer-path Twenty poll, the offered-slots fetch in claim path, the freebusy filter, the daily generator's "next 14 days" query.
- **Rule #25** — add `n8n-workflows/scheduling/d-scheduling.json` to `scripts/patch-workflow-ids.sh`'s file list AND add each Execute Workflow node name → subflow ID mapping.

---

## 11. Acceptance criteria

| Spec criterion | Design coverage |
|---|---|
| Single candidate happy path: 3 options, replies "2", slot claimed, others released, both notified, calendar created | §4 state machine; tester verifies end-to-end with seeded `interviewer_availability` row |
| Race condition: same slot offered to two apps, second INSERT fails, second app gets alternative | Partial unique index `uq_slot_no_double_claim`; offer-path bounded retry |
| Candidate picks expired slot: rowcount=0, gentle reprompt, fresh offers | §9.4; predicate `offer_expires_at > NOW()` in claim UPDATE |
| Calendar 500: slot still claimed, ReviewTask created, candidate still notified | §9.2; `calendar_sync_retry` table + Workflow G hourly retry; candidate confirmation includes "link to follow" copy |
| Ambiguous reply "the second one please": natural-language parser accepts | §1 OQ-3; Haiku fallback resolves; `slot_index=2` |
| Ambiguous reply "any time works": polite reprompt | §1 OQ-3; Haiku returns `null` → reprompt branch |
| Mid-stream reschedule (T2 marker) | §1 rescheduling OQ; fresh-offer-cycle path works in v1; inline reschedule deferred to T2-D-3 |
| Calibration ON: every offer + confirmation requires operator approval before WA send | §8; gated by `WORKFLOW_D_LAUNCH_DATE` env |
| Generator daily run: 14 days of available slots present, busy times vetoed | §3 generator path; tester seeds `interviewer_availability` and a busy event, verifies generated slot count |
| `scheduled_reminders` rows written on claim, picked up by Workflow G at 24h-before and 2h-before | §4 claim path final step; tested via setting fire_at to NOW()+1min in dev |

---

## 12. v1 limitations and T2 follow-ups

- **T2-D-1** — True Lua CAS PEXPIRE heartbeat for the conv-lock (lifts CLAUDE.md invariant #3 footnote; common to all workflows, tracked centrally).
- **T2-D-2** — Atomic SETNX-equivalent for Redis dedupe + lock acquire (lifts rule #16 TOCTOU caveat; common to all workflows).
- **T2-D-3** — Inline rescheduling: candidate replies "can we move it?" in an existing thread, workflow offers 2 alternatives without a fresh full cycle. Requires UX research on whether candidates actually find the fresh cycle confusing.
- **T2-D-4** — Per-interviewer slot duration (replace fixed 45 min with `slot_minutes` per row).
- **T2-D-5** — `freebusy.query` repeated-failure escalation: if same interviewer fails 3 days in a row, raise `system_incident` automatically.
- **T2-D-6** — Multi-timezone interviewers: v1 assumes all interviewers are in `Africa/Accra`. Workflow honours `interviewer.timezone` at slot generation but does not handle DST transitions. Ghana has no DST, so this is moot for v1; T2 when first non-GH interviewer is added.
- **T2-D-7** — Group/panel interviews (multiple interviewers on one slot). v1 is one-interviewer-per-slot.
- **T2-D-8** — Candidate timezone preference: currently all candidate-facing times rendered in Africa/Accra. T2: detect timezone preference from candidate phone country code or explicit ask.
- **T2-D-9** — Calendar event update on candidate cancellation. v1 path on cancellation: operator manually deletes the event in Calendar; the Twenty `Interview.status` becomes `cancelled` via Workflow A. Automating this requires a Calendar event delete subflow.
- **T2-D-10** — Candidate-initiated reschedule via natural language ("can we do Friday instead?"). v1 requires the operator to set `Application.status='shortlisted'` again to trigger a fresh offer cycle.
- **T2-D-11** — `freebusy.query` caching to avoid repeating the call inside the daily generator if multiple interviewers share a calendar (rare).

---

## 13. Pre-launch blockers (not blocking workflow-builder)

1. V012, V013, V014, V015 migrations applied to bookings DB.
2. At least one `interviewer` row with valid `google_calendar_id` and one `interviewer_availability` window seeded.
3. WhatsApp templates submitted to Meta and approved:
   - `interview_offer` — utility template, candidate-first-name + 3 slot strings (4 vars total).
   - `interview_confirmation` — utility template, with-Meet-link variant.
   - `interview_confirmation_no_link` — utility template, "calendar to follow" variant.
   - `interview_reminder_24h`, `interview_reminder_2h` — already mentioned in `.claude/rules/whatsapp-templates.md`; verify approval status.
4. Workflow A `workflow_reply` branch updated to detect active offered slots and route `trigger_kind='scheduling_reply'`.
5. Workflow G's `calendar_sync_retry` sweeper coded and deployed (or tracked as a known gap with manual operator workaround for the first 2 weeks).
6. `WORKFLOW_D_LAUNCH_DATE` env var set to the planned go-live date.
7. ADR-0012 accepted (slot sourcing decision).

---

## 14. Open questions — RESOLVED

All four design questions plus the spec's existing rescheduling OQ are resolved in §1. No remaining open questions block workflow-builder dispatch.
