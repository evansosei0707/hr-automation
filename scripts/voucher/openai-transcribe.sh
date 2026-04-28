#!/usr/bin/env bash
# voucher/openai-transcribe.sh — Phase 4 voucher: OpenAI audio transcription
#
# Proves we can submit audio to gpt-4o-mini-transcribe and get a transcript
# back. NOT the full integration — that's workflow A's voice-note path with
# language classification, retry templates, manual-review routing. The
# voucher just exercises the wire shape.
#
# Per researcher's 2026-04-26 verification of
# https://platform.openai.com/docs/api-reference/audio/createTranscription:
#   - POST https://api.openai.com/v1/audio/transcriptions
#   - Authorization: Bearer <key>
#   - multipart/form-data with: file, model, language, response_format
#   - Default JSON response: {"text": "..."}
#   - 25 MB file size limit; mp3, wav, m4a, webm etc. all supported
#
# Fixture: scripts/voucher/fixtures/voucher_sample.wav
#   Generated once via espeak-ng (en-us, speed 150) on 2026-04-27:
#     espeak-ng -w voucher_sample.wav -v en-us -s 150 \
#       "Hello, this is a voucher test."
#   ~107 KB, 16-bit PCM, mono, 22050 Hz. Committed to the repo so the
#   voucher is fully self-contained — no runtime download, no external
#   TTS dependency. Regenerate with the same one-liner if the fixture
#   ever needs updating.
#
# Acceptance:
#   - HTTP 200
#   - response.text non-empty
#   - response.text contains 'voucher' OR 'test' (case-insensitive) —
#     loose match so we don't break on transcription quirks
#     ("woucher", "Hello, this is a") but still confirm the model
#     processed audio rather than silently echoing back nothing
#
# Side effects:
#   - One transcription API call (~$0.0001 — gpt-4o-mini-transcribe is
#     ~$0.003/min, our clip is well under a minute)
#   - One event_log row (workflow_name='voucher_openai_transcribe')
#
# Prerequisites:
#   - infrastructure/.env with OPENAI_API_KEY, OPENAI_TRANSCRIBE_MODEL
#   - hr-bookings-db container running
#   - curl, jq, docker on PATH
#   - The fixture WAV present at scripts/voucher/fixtures/voucher_sample.wav
#
# Usage: ./scripts/voucher/openai-transcribe.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$ROOT/infrastructure/.env"
FIXTURE="$ROOT/scripts/voucher/fixtures/voucher_sample.wav"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { err "$*"; exit 1; }

[ -f "$ENV_FILE" ] || die "$ENV_FILE not found"
# shellcheck source=/dev/null
source "$ENV_FILE"

for var in OPENAI_API_KEY OPENAI_TRANSCRIBE_MODEL BOOKINGS_DB_USER BOOKINGS_DB_PASSWORD BOOKINGS_DB_NAME; do
  [ -n "${!var:-}" ] || die "Required env var '$var' missing"
done
for dep in curl jq docker; do
  command -v "$dep" >/dev/null 2>&1 || die "Required tool '$dep' not found"
done
[ -f "$FIXTURE" ] || die "Fixture not found at $FIXTURE — regenerate via: espeak-ng -w $FIXTURE -v en-us -s 150 \"Hello, this is a voucher test.\""

BOOKINGS_DB_CONTAINER="${BOOKINGS_DB_CONTAINER:-hr-bookings-db}"

psql_exec() {
  docker exec -e PGPASSWORD="$BOOKINGS_DB_PASSWORD" "$BOOKINGS_DB_CONTAINER" \
    psql -U "$BOOKINGS_DB_USER" -d "$BOOKINGS_DB_NAME" -t -A -q -c "$1"
}

FIXTURE_SIZE=$(stat -c %s "$FIXTURE")
log "Fixture: $FIXTURE ($FIXTURE_SIZE bytes)"
log "Model:   $OPENAI_TRANSCRIBE_MODEL"
log "Submitting to https://api.openai.com/v1/audio/transcriptions ..."

HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 30 \
  -X POST "https://api.openai.com/v1/audio/transcriptions" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -F "file=@${FIXTURE}" \
  -F "model=${OPENAI_TRANSCRIBE_MODEL}" \
  -F "language=en" \
  -F "response_format=json")

HTTP_BODY=$(printf '%s' "$HTTP_RESPONSE" | sed '$d')
HTTP_CODE=$(printf '%s' "$HTTP_RESPONSE" | tail -1)

log "  HTTP $HTTP_CODE"

if [ "$HTTP_CODE" != "200" ]; then
  err "OpenAI returned non-200. Response body:"
  echo "$HTTP_BODY" >&2
  ESCAPED_BODY="${HTTP_BODY//\'/\'\'}"
  psql_exec "
    INSERT INTO event_log (workflow_name, level, event, message, data)
    VALUES (
      'voucher_openai_transcribe', 'error', 'transcribe_failed',
      'OpenAI audio.transcriptions returned HTTP ${HTTP_CODE}',
      jsonb_build_object('http_code', ${HTTP_CODE}, 'response', '${ESCAPED_BODY}'::jsonb)
    );
  " >/dev/null 2>&1 || true
  exit 1
fi

# ─────────────────────────────────────────────
# Parse + validate response
# ─────────────────────────────────────────────
TRANSCRIPT=$(printf '%s' "$HTTP_BODY" | jq -r '.text // ""')
TRANSCRIPT_LEN=${#TRANSCRIPT}

log "  transcript length: $TRANSCRIPT_LEN chars"
log "  transcript:        \"$TRANSCRIPT\""

if [ "$TRANSCRIPT_LEN" -eq 0 ]; then
  err "OpenAI returned empty transcript. Response body:"
  echo "$HTTP_BODY" >&2
  exit 1
fi

# Loose match: case-insensitive 'voucher' or 'test'. Catches 'voucher test'
# (correct), 'Voucher Test' (case variant), 'a test' (partial), but flags
# total nonsense like 'thank you for watching' that's known to come back
# from no-audio submissions to some Whisper-style models.
if ! printf '%s' "$TRANSCRIPT" | grep -qiE 'voucher|test'; then
  err "Transcript did not contain 'voucher' or 'test' — model may have failed to process the fixture."
  err "  full transcript: \"$TRANSCRIPT\""
  exit 1
fi
log "  ✓ transcript contains expected token (voucher|test)"

# ─────────────────────────────────────────────
# Log to event_log
# ─────────────────────────────────────────────
DATA_JSONB=$(jq -nc \
  --arg model "$OPENAI_TRANSCRIBE_MODEL" \
  --arg fixture "$FIXTURE" \
  --argjson size "$FIXTURE_SIZE" \
  --arg transcript "$TRANSCRIPT" \
  --argjson tlen "$TRANSCRIPT_LEN" \
  '{model: $model, fixture: $fixture, fixture_bytes: $size, transcript: $transcript, transcript_length: $tlen}')
DATA_JSONB_SQL_SAFE="${DATA_JSONB//\'/\'\'}"

psql_exec "
  INSERT INTO event_log (workflow_name, level, event, message, data)
  VALUES (
    'voucher_openai_transcribe', 'info', 'transcribe_succeeded',
    'OpenAI ${OPENAI_TRANSCRIBE_MODEL} returned ${TRANSCRIPT_LEN}-char transcript',
    '${DATA_JSONB_SQL_SAFE}'::jsonb
  );
" >/dev/null

EVENT_COUNT=$(psql_exec "
  SELECT count(*) FROM event_log
  WHERE workflow_name = 'voucher_openai_transcribe'
    AND event = 'transcribe_succeeded'
    AND ts > NOW() - INTERVAL '60 seconds';
")

log ""
log "════════════════════════════════════════════"
log " openai-transcribe voucher — PASS"
log "════════════════════════════════════════════"
log "  Model:                $OPENAI_TRANSCRIBE_MODEL"
log "  Fixture bytes:        $FIXTURE_SIZE"
log "  Transcript length:    $TRANSCRIPT_LEN"
log "  Transcript:           \"$TRANSCRIPT\""
log "  event_log rows just written (last 60s): $EVENT_COUNT"
log "════════════════════════════════════════════"
