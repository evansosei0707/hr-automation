#!/usr/bin/env bash
# voucher/google-calendar.sh — Phase 4 voucher: Google Calendar API events.list
#
# Proves we can read the Ghana public-holidays calendar from this environment.
# NOT the full sync (that's workflow G's holiday-mirror branch). This just
# exercises the read shape.
#
# Per docs/03-integrations/google-calendar.md and researcher's 2026-04-26
# verification of https://developers.google.com/calendar/api/v3/reference/events/list:
#   - Endpoint: GET https://www.googleapis.com/calendar/v3/calendars/{calendarId}/events
#   - calendarId must be URL-encoded: '#' → '%23', '@' → '%40'
#   - Public calendars are accessible with API key only (no OAuth)
#   - All-day events use start.date (YYYY-MM-DD); timed use start.dateTime
#
# Window: full calendar year 2026 — gives a clean, predictable holiday set.
# (User asked for "next 12 months" but the substantive assertion is "≥10
# events for 2026", so an exact calendar-year query is the cleanest test
# range.)
#
# Side effects:
#   - GET request to Google Calendar API (read-only)
#   - One event_log row in bookings DB (workflow_name='voucher_google_calendar')
#   - Does NOT write to Twenty's Holiday object — that's the workflow build
#
# Specific correctness check: Founder's Day must be on September 21
# (modern Ghana, post-2019 reform), not August 4. Failure here would
# indicate either a stale/wrong calendar ID or the calendar contains
# pre-reform dates.
#
# Prerequisites:
#   - infrastructure/.env with GOOGLE_API_KEY, GOOGLE_HOLIDAYS_CALENDAR_ID
#   - hr-bookings-db container running
#   - curl, jq, docker on PATH
#
# Usage: ./scripts/voucher/google-calendar.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$ROOT/infrastructure/.env"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { err "$*"; exit 1; }

[ -f "$ENV_FILE" ] || die "$ENV_FILE not found"
# shellcheck source=/dev/null
source "$ENV_FILE"

for var in GOOGLE_API_KEY GOOGLE_HOLIDAYS_CALENDAR_ID BOOKINGS_DB_USER BOOKINGS_DB_PASSWORD BOOKINGS_DB_NAME; do
  [ -n "${!var:-}" ] || die "Required env var '$var' missing"
done
for dep in curl jq docker; do
  command -v "$dep" >/dev/null 2>&1 || die "Required tool '$dep' not found"
done

BOOKINGS_DB_CONTAINER="${BOOKINGS_DB_CONTAINER:-hr-bookings-db}"

psql_exec() {
  docker exec -e PGPASSWORD="$BOOKINGS_DB_PASSWORD" "$BOOKINGS_DB_CONTAINER" \
    psql -U "$BOOKINGS_DB_USER" -d "$BOOKINGS_DB_NAME" -t -A -q -c "$1"
}

# ─────────────────────────────────────────────
# URL-encode the calendarId path segment.
# Researcher confirmed this is required: '#' is a fragment delimiter in
# URLs, '@' is reserved per RFC 3986 in path segments. curl will not
# auto-encode characters already in the URL string — we encode by hand.
# ─────────────────────────────────────────────
CAL_ID_RAW="$GOOGLE_HOLIDAYS_CALENDAR_ID"
CAL_ID_ENCODED="${CAL_ID_RAW//#/%23}"
CAL_ID_ENCODED="${CAL_ID_ENCODED//@/%40}"

log "Calendar ID (raw):     ${CAL_ID_RAW}"
log "Calendar ID (encoded): ${CAL_ID_ENCODED}"

TIME_MIN="2026-01-01T00:00:00Z"
TIME_MAX="2026-12-31T23:59:59Z"
URL="https://www.googleapis.com/calendar/v3/calendars/${CAL_ID_ENCODED}/events"
URL+="?key=${GOOGLE_API_KEY}"
URL+="&timeMin=$(printf %s "$TIME_MIN" | jq -sRr @uri)"
URL+="&timeMax=$(printf %s "$TIME_MAX" | jq -sRr @uri)"
URL+="&singleEvents=true"
URL+="&orderBy=startTime"

log "Querying Google Calendar (window: $TIME_MIN .. $TIME_MAX) ..."

HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 30 "$URL")
HTTP_BODY=$(printf '%s' "$HTTP_RESPONSE" | sed '$d')
HTTP_CODE=$(printf '%s' "$HTTP_RESPONSE" | tail -1)

log "  HTTP ${HTTP_CODE}"

if [ "$HTTP_CODE" != "200" ]; then
  err "Google Calendar returned non-200. Response body:"
  echo "$HTTP_BODY" >&2
  ESCAPED_BODY="${HTTP_BODY//\'/\'\'}"
  psql_exec "
    INSERT INTO event_log (workflow_name, level, event, message, data)
    VALUES (
      'voucher_google_calendar', 'error', 'fetch_failed',
      'events.list returned HTTP ${HTTP_CODE}',
      jsonb_build_object('http_code', ${HTTP_CODE}, 'response', '${ESCAPED_BODY}'::jsonb)
    );
  " >/dev/null 2>&1 || true
  exit 1
fi

# ─────────────────────────────────────────────
# Parse response — items[] with summary + start.date (all-day events)
# ─────────────────────────────────────────────
EVENT_COUNT=$(printf '%s' "$HTTP_BODY" | jq -r '.items | length')
log "  events in window: ${EVENT_COUNT}"

if [ "$EVENT_COUNT" -lt 10 ]; then
  err "Expected ≥10 events for 2026, got ${EVENT_COUNT}"
  echo "$HTTP_BODY" | jq '.items[] | {summary, start}' >&2
  exit 1
fi

# Print sanity-readable summary
log ""
log "Holiday summary (date — name):"
printf '%s' "$HTTP_BODY" | jq -r '.items[] | "  \(.start.date // .start.dateTime)  \(.summary)"'

# ─────────────────────────────────────────────
# Founder's Day correctness check — must be on September 21, not August.
# We accept any summary containing "founder" (case-insensitive) and check
# its start.date begins with 2026-09-21.
# ─────────────────────────────────────────────
FOUNDERS_ENTRIES=$(printf '%s' "$HTTP_BODY" | \
  jq -r '.items[] | select(.summary | test("founder"; "i")) | "\(.start.date // .start.dateTime)\t\(.summary)"')

if [ -z "$FOUNDERS_ENTRIES" ]; then
  err "Founder's Day not found in 2026 events. Calendar may be missing it."
  exit 1
fi

log ""
log "Founder's Day candidates:"
printf '%s\n' "$FOUNDERS_ENTRIES" | sed 's/^/  /'

FOUNDERS_ON_SEP_21=$(printf '%s' "$FOUNDERS_ENTRIES" | grep -c '^2026-09-21' || true)
if [ "$FOUNDERS_ON_SEP_21" -lt 1 ]; then
  err "Founder's Day is NOT on 2026-09-21. Got entries above. This is the known"
  err "correctness check from docs/00-foundations/ghana-context.md (post-2019"
  err "reform: Sept 21, not Aug 4)."
  exit 1
fi
log "  ✓ Founder's Day on 2026-09-21 confirmed (post-2019 reform date)"

# ─────────────────────────────────────────────
# Log to event_log
# Build the entire `data` JSONB via jq (proper string escaping for free),
# then pass it to psql as a single-quoted JSON literal. Doubling any
# embedded single-quotes for SQL safety. Avoids the $$-quoting trap
# (bash expands $$ to the shell PID before psql ever sees it).
# ─────────────────────────────────────────────
HOLIDAY_LIST_JSON=$(printf '%s' "$HTTP_BODY" | jq -c '[.items[] | {date: (.start.date // .start.dateTime), summary}]')
DATA_JSONB=$(jq -nc \
  --arg cid "$CAL_ID_RAW" \
  --arg tmin "$TIME_MIN" \
  --arg tmax "$TIME_MAX" \
  --argjson ec "$EVENT_COUNT" \
  --argjson holidays "$HOLIDAY_LIST_JSON" \
  '{calendar_id: $cid, time_min: $tmin, time_max: $tmax, event_count: $ec, founders_day_correct: true, holidays: $holidays}')
DATA_JSONB_SQL_SAFE="${DATA_JSONB//\'/\'\'}"

psql_exec "
  INSERT INTO event_log (workflow_name, level, event, message, data)
  VALUES (
    'voucher_google_calendar', 'info', 'fetch_succeeded',
    'Google Calendar voucher: ${EVENT_COUNT} 2026 holidays read; Founder''s Day verified on 2026-09-21',
    '${DATA_JSONB_SQL_SAFE}'::jsonb
  );
" >/dev/null

EVENT_LOG_COUNT=$(psql_exec "
  SELECT count(*) FROM event_log
  WHERE workflow_name = 'voucher_google_calendar'
    AND event = 'fetch_succeeded'
    AND ts > NOW() - INTERVAL '30 seconds';
")

log ""
log "════════════════════════════════════════════"
log " google-calendar voucher — PASS"
log "════════════════════════════════════════════"
log "  Calendar:                ${CAL_ID_RAW}"
log "  Window:                  ${TIME_MIN} .. ${TIME_MAX}"
log "  2026 holidays read:      ${EVENT_COUNT}"
log "  Founder's Day on Sep 21: ✓"
log "  event_log rows just written (workflow_name=voucher_google_calendar, event=fetch_succeeded, last 30s): ${EVENT_LOG_COUNT}"
log "════════════════════════════════════════════"
