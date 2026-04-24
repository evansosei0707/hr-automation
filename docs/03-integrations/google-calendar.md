# Integration — Google Calendar

Two jobs: mirror Ghanaian public holidays into Twenty, and write interview events onto interviewers' personal calendars.

## Auth model

- **Service account** with domain-wide delegation (if the firm uses Google Workspace) OR per-user OAuth 2.0 consent (if Gmail personal accounts).
- Service account is cleaner; consent is required if we are writing to individual personal calendars.

Store service account JSON (or individual refresh tokens) in `secrets/` (gitignored) and reference by path from `.env`.

## Use case 1 — Holidays mirror

**Source calendar:** `en.gh#holiday@group.v.calendar.google.com` (public, read-only, no auth needed).

**Sync job:** scheduled daily by Workflow G's maintenance branch.

**Logic:**

1. Fetch events for the next 12 months from the public holiday calendar:
   ```
   GET https://www.googleapis.com/calendar/v3/calendars/{cal}/events?timeMin=...&timeMax=...&key={API_KEY}
   ```
   (An API key alone is sufficient for public calendars; no OAuth needed.)
2. For each event, upsert a Twenty `Holiday` row:
   - `date = event.start.date`
   - `name = event.summary`
   - `source = 'google'`
   - `isActive = true`
3. For holidays in the local table that are NOT in the feed (i.e. Google removed one), set `isActive=false` but do not delete — keeps audit trail. The Operations Lead can review.

**Override pattern:** if the Operations Lead manually creates or edits a `Holiday` with `source=manual_override`, the sync job never touches it. Their edits win.

**Watch for:** Islamic holiday dates (Eid al-Fitr, Eid al-Adha) are set annually by official proclamation in Ghana; the public feed is usually correct but occasionally lags the proclamation by a few days. Verify manually each year in January.

## Use case 2 — Interview events

When Workflow D claims a slot, we create an event on the interviewer's calendar:

**Endpoint:** `POST https://www.googleapis.com/calendar/v3/calendars/{calendarId}/events`

**Body:**
```json
{
  "summary": "Interview — Kwame Mensah for Frontend Developer",
  "description": "...",
  "start": { "dateTime": "2026-05-12T10:00:00+00:00", "timeZone": "Africa/Accra" },
  "end":   { "dateTime": "2026-05-12T10:45:00+00:00", "timeZone": "Africa/Accra" },
  "attendees": [{ "email": "candidate-not-added" }],
  "conferenceData": {
    "createRequest": {
      "requestId": "{uuid}",
      "conferenceSolutionKey": { "type": "hangoutsMeet" }
    }
  },
  "reminders": { "useDefault": true }
}
```

Notes:
- `conferenceData.createRequest` auto-generates a Google Meet link; add `?conferenceDataVersion=1` to the URL query.
- Do not add the candidate as an attendee — their email is not verified and Google will bounce invites back. Put their contact in the description.
- Respect `Africa/Accra` timezone.

Store the returned `event.id` and `event.htmlLink` on the Twenty `Interview` record.

## Rate limits

- 1,000,000 queries per day per project (generous).
- 500 queries per 100 seconds per user.

Nothing to worry about at our volume.

## Failure handling

If event creation fails (500, transient network), workflow D does NOT roll back the slot claim. Instead it:

1. Logs to `workflow_errors`.
2. Creates a `ReviewTask` with `kind=calendar_sync_failure` and payload including the intended event details.
3. The Operations Lead adds the event manually if the retry (scheduled by Orchestration) also fails.

Rationale: the candidate has already been told their slot is confirmed. Backing out would be worse than a calendar-entry gap.

## Known pitfalls

- **Timezone drift:** always send `timeZone`; do not rely on UTC offsets in the dateTime alone. DST-unaware systems can misparse.
- **`attendees` field:** if you DO add attendees, Google will try to email them, which for our candidates is noisy and unverified. Leave empty.
- **Recurring events:** we do not use these. Interviews are always one-off. If you find yourself writing recurrence rules, stop and ask.

## Configuration

```
GOOGLE_API_KEY=                    # for public holidays calendar read
GOOGLE_SERVICE_ACCOUNT_PATH=secrets/google-sa.json
GOOGLE_HOLIDAYS_CALENDAR_ID=en.gh#holiday@group.v.calendar.google.com
```
