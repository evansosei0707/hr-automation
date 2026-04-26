# Workflow D — Scheduling

Offer interview slots to a shortlisted candidate and atomically book their choice. No double-bookings, no phone tag.

## Purpose

When the Operations Lead moves an Application to `status=shortlisted`, we offer the candidate 2–3 interview slots on WhatsApp. They pick one, we book it atomically, we notify both the candidate and the interviewer, we create a Twenty `Interview` record linked to the Application.

## Triggers

- Application status change to `shortlisted` (poll-based: workflow runs every 2 minutes on the delta)
- Candidate reply in a pending-offer thread (routed from Workflow A)

## Inputs

- `applicationId`, linked candidate/jobPosting/interviewer
- Interviewer availability (from Google Calendar or manual slots in `slot` table with `status=available`)

## Outputs

- `slot.status=offered` rows, one per proposed slot, with `offer_expires_at = NOW() + 24h`
- WhatsApp message to candidate presenting 2–3 slot options
- On claim: `slot.status=claimed`, `Interview` record in Twenty via GraphQL, calendar event in the interviewer's Google Calendar, confirmation messages both ways
- Reminder 24h and 2h before the interview

## Step sequence — offering slots

1. Find the next 3 available slots for any configured interviewer in the candidate's preferred time window (default business hours).
2. Create 3 `slot` rows with `status=offered`, `offered_to_application_id`, `offer_expires_at = NOW() + 24h`.
3. Send the candidate one WhatsApp message listing the options (numbered 1 / 2 / 3 with day + time in Accra local format).
4. Start a wait-for-reply with a 24h timeout.

## Step sequence — claiming a slot

1. Candidate replies "1" (or "2" or "3"). Workflow A routes it here.
2. Parse the number. If ambiguous, ask again politely; do not guess.
3. Run the atomic claim transaction on the chosen slot (see `01-data-model/bookings-db.md` for the SQL).
4. If `rowcount=1`: proceed. If `rowcount=0`: the slot has gone; offer the next available alternative.
5. Release the other two offered slots (`status=available`, clear `offered_*` fields).
6. Create the Twenty `Interview` record linked to this Application, populate `bookingId` with the slot ID.
7. Create a Google Calendar event on the interviewer's calendar (see `03-integrations/google-calendar.md`).
8. Send candidate a confirmation with the date, time, location / link, and interviewer's name.
9. Send the interviewer a summary (WhatsApp or email, per their preference).
10. Schedule the 24h-before and 2h-before reminders (by writing rows to `scheduled_reminders` which the orchestration workflow pulls hourly).

## Invariants

- **The atomic claim is the only way to book a slot.** Any code path that sets `status=claimed` without going through the transactional UPDATE is a bug.
- The partial unique index on `(interviewer_id, starts_at) WHERE status IN ('offered','claimed')` is not a performance hint — it is a correctness constraint. Do not drop it.
- Offer expiry is 24h. Expired offers are swept by the orchestration workflow back to `available`.
- Never offer the same slot to two candidates simultaneously — the insert of a second `offered` row on the same (interviewer, start_time) is rejected by the unique index.
- If the interviewer's Google Calendar event creation fails, the slot claim is NOT rolled back. Instead, a `ReviewTask` is created for manual calendar entry. Candidate has their slot; calendar can catch up.

## Acceptance criteria

- **Single candidate, happy path:** candidate gets 3 options, replies "2", slot 2 is claimed, other two go back to available, both parties notified, calendar event created.
- **Race condition:** two candidates sent the same slot (different applications, same interviewer+time — should not happen because of the unique index, but we test anyway). The second INSERT fails, the second candidate is offered an alternative.
- **Candidate picks an expired slot:** slot was offered 25 hours ago. UPDATE returns 0 rows. Candidate gets a gentle "that slot has passed — here are fresh options" and a new offer set.
- **Calendar failure:** Google API returns 500. Slot is still claimed, ReviewTask is created for the Orchestrator, candidate is still notified.
- **Candidate ambiguous reply:** "the second one please" — natural-language parser accepts it. "Any time works" — workflow replies asking to pick one of 1/2/3.

## Monitoring

- `workflow_d_offers_sent_total`
- `workflow_d_offers_accepted_total`
- `workflow_d_offers_expired_total`
- `workflow_d_claim_failures_total` (race losses)
- `workflow_d_calendar_sync_failures_total`

## Open questions

- Rescheduling flow — is it a fresh offer cycle or a simpler "reply with one of these alternatives" in the existing thread? Default: fresh offer cycle, flagged `reschedule=true` on the new offer set.
