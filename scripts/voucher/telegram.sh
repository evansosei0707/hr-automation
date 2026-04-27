#!/usr/bin/env bash
# voucher/telegram.sh — Phase 4 voucher: Telegram Bot API sendMessage
#
# Proves we can post a message to the firm's Telegram channel from this
# environment. NOT the full integration — that's workflow E. This just
# exercises the wire shape.
#
# Per docs/03-integrations/telegram-bot.md and researcher's 2026-04-26
# verification of https://core.telegram.org/bots/api#sendmessage:
#   - Endpoint: POST https://api.telegram.org/bot<token>/sendMessage
#   - Body: JSON with chat_id, text, parse_mode
#   - chat_id can be the @channelusername form (env: TELEGRAM_CHANNEL_ID)
#   - parse_mode: MarkdownV2
#   - Success response: {"ok": true, "result": {"message_id": <int>, ...}}
#
# Test message uses a compact ISO-like timestamp (YYYYMMDDTHHMMSSZ) with no
# hyphens or periods → no MarkdownV2 escaping needed. The em-dash and colon
# pass through unescaped per the researcher's docs check.
#
# Idempotent in the sense that re-running just sends another message; we do
# NOT delete prior test messages (they're harmless and give a visual record
# of when the voucher last ran).
#
# Side effect: writes one event_log row to bookings DB
# (workflow_name='voucher_telegram') with the returned message_id.
#
# Prerequisites:
#   - infrastructure/.env with TELEGRAM_BOT_TOKEN, TELEGRAM_CHANNEL_ID
#   - hr-bookings-db container running
#   - curl, jq, docker on PATH
#
# Usage: ./scripts/voucher/telegram.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$ROOT/infrastructure/.env"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { err "$*"; exit 1; }

[ -f "$ENV_FILE" ] || die "$ENV_FILE not found"
# shellcheck source=/dev/null
source "$ENV_FILE"

for var in TELEGRAM_BOT_TOKEN TELEGRAM_CHANNEL_ID BOOKINGS_DB_USER BOOKINGS_DB_PASSWORD BOOKINGS_DB_NAME; do
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
# Compose the message — compact timestamp avoids MarkdownV2 escape noise.
# Em-dash (U+2014) and 'T'/'Z'/digits/spaces are all safe under MarkdownV2.
# ─────────────────────────────────────────────
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
MSG_TEXT="HRA voucher test — ${TIMESTAMP}"

log "Posting to Telegram channel: ${TELEGRAM_CHANNEL_ID}"
log "  text: ${MSG_TEXT}"

REQUEST_BODY=$(jq -n \
  --arg chat "$TELEGRAM_CHANNEL_ID" \
  --arg text "$MSG_TEXT" \
  '{chat_id: $chat, text: $text, parse_mode: "MarkdownV2"}')

# ─────────────────────────────────────────────
# Send + capture HTTP status + body in one curl
# ─────────────────────────────────────────────
HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 15 \
  -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY")
HTTP_BODY=$(printf '%s' "$HTTP_RESPONSE" | sed '$d')
HTTP_CODE=$(printf '%s' "$HTTP_RESPONSE" | tail -1)

log "  HTTP ${HTTP_CODE}"

if [ "$HTTP_CODE" != "200" ]; then
  err "Telegram returned non-200. Response body:"
  echo "$HTTP_BODY" >&2
  # Log failure to event_log before exiting
  ESCAPED_BODY="${HTTP_BODY//\'/\'\'}"
  psql_exec "
    INSERT INTO event_log (workflow_name, level, event, message, data)
    VALUES (
      'voucher_telegram', 'error', 'send_failed',
      'Telegram sendMessage returned HTTP ${HTTP_CODE}',
      jsonb_build_object('http_code', ${HTTP_CODE}, 'response', '${ESCAPED_BODY}'::jsonb)
    );
  " >/dev/null 2>&1 || true
  exit 1
fi

# ─────────────────────────────────────────────
# Parse response: ok=true, message_id present
# ─────────────────────────────────────────────
OK=$(printf '%s' "$HTTP_BODY" | jq -r '.ok')
if [ "$OK" != "true" ]; then
  err "Telegram response.ok != true. Body:"
  echo "$HTTP_BODY" >&2
  exit 1
fi

MESSAGE_ID=$(printf '%s' "$HTTP_BODY" | jq -r '.result.message_id')
CHAT_ID_NUM=$(printf '%s' "$HTTP_BODY" | jq -r '.result.chat.id')
CHAT_TITLE=$(printf '%s' "$HTTP_BODY" | jq -r '.result.chat.title // .result.chat.username // ""')

if [ -z "$MESSAGE_ID" ] || [ "$MESSAGE_ID" = "null" ]; then
  err "Telegram returned ok=true but no message_id. Body:"
  echo "$HTTP_BODY" >&2
  exit 1
fi

log "  result.message_id: ${MESSAGE_ID}"
log "  result.chat.id:    ${CHAT_ID_NUM}"
log "  result.chat.title: ${CHAT_TITLE}"

# ─────────────────────────────────────────────
# Log to event_log
# ─────────────────────────────────────────────
psql_exec "
  INSERT INTO event_log (workflow_name, level, event, message, data)
  VALUES (
    'voucher_telegram', 'info', 'send_succeeded',
    'Telegram voucher message sent successfully',
    jsonb_build_object(
      'message_id', ${MESSAGE_ID},
      'chat_id', ${CHAT_ID_NUM},
      'chat_title', '${CHAT_TITLE}',
      'channel_handle', '${TELEGRAM_CHANNEL_ID}',
      'sent_text', '${MSG_TEXT}'
    )
  );
" >/dev/null

EVENT_COUNT=$(psql_exec "
  SELECT count(*) FROM event_log
  WHERE workflow_name = 'voucher_telegram'
    AND event = 'send_succeeded'
    AND ts > NOW() - INTERVAL '30 seconds';
")

log ""
log "════════════════════════════════════════════"
log " telegram voucher — PASS"
log "════════════════════════════════════════════"
log "  Channel:             ${TELEGRAM_CHANNEL_ID} (${CHAT_TITLE})"
log "  Message ID:          ${MESSAGE_ID}"
log "  event_log rows just written (workflow_name=voucher_telegram, event=send_succeeded, last 30s): ${EVENT_COUNT}"
log "════════════════════════════════════════════"
