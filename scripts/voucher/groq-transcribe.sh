#!/usr/bin/env bash
# voucher/groq-transcribe.sh — Phase 4 voucher: Groq Whisper transcription
#
# Per ADR-0006 (2026-04-28), Groq replaces OpenAI as the project's
# transcription provider. The wire shape is OpenAI-compatible:
# `https://api.groq.com/openai/v1/audio/transcriptions` accepts the same
# multipart fields and returns `{"text": "..."}` for `response_format=json`.
#
# This voucher proves we can submit audio to Groq and get a transcript back.
# NOT the full integration — that's workflow A's voice-note path with
# language classification, retry templates, manual-review routing, and
# verbose_json confidence gating. The voucher just exercises the wire shape.
#
# Per researcher's 2026-04-28 verification of
# https://console.groq.com/docs/speech-to-text +
# https://console.groq.com/docs/openai:
#   - POST https://api.groq.com/openai/v1/audio/transcriptions
#   - Authorization: Bearer <key>
#   - multipart/form-data with: file, model, language, response_format
#   - Default JSON response: {"text": "..."}
#   - Free tier: 20 RPM, 2K RPD, 28.8K audio-sec/day — 95%+ headroom for
#     our forecast (~22 min/day audio, ~43 calls/day)
#   - Pricing if upgraded: $0.04/hr for whisper-large-v3-turbo
#   - verbose_json (not used in voucher) returns per-segment avg_logprob
#     and no_speech_prob — the routing primitive that informs Workflow A's
#     confidence gating during the calibration window
#
# Fixture: scripts/voucher/fixtures/voucher_sample.wav (shared with the
# OpenAI voucher; espeak-ng-generated). The transcript on synthetic
# espeak-ng audio is approximate, not natural — this voucher proves the
# WIRE SHAPE works, not transcript fidelity. Real-Ghanaian-Pidgin quality
# testing is a separate, post-Phase-4 task and is tracked in
# plans/tier-2-followups.md.
#
# Side effects:
#   - One transcription API call (free tier; cost = $0)
#   - One event_log row (workflow_name='voucher_groq_transcribe')
#
# Prerequisites:
#   - infrastructure/.env with GROQ_API_KEY (required)
#     GROQ_TRANSCRIBE_MODEL and GROQ_API_BASE_URL fall back to documented
#     defaults if absent — script is self-sufficient for non-secret config.
#   - hr-bookings-db container running
#   - curl, jq, docker on PATH
#   - Fixture WAV at scripts/voucher/fixtures/voucher_sample.wav
#
# Usage: ./scripts/voucher/groq-transcribe.sh
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

# GROQ_API_KEY is required (no default — it's a secret).
[ -n "${GROQ_API_KEY:-}" ] || die "GROQ_API_KEY missing in .env. Sign up at https://console.groq.com (no card required for free tier) and add the key. See ADR-0006."

# These two have stable documented defaults; .env override is optional.
GROQ_TRANSCRIBE_MODEL="${GROQ_TRANSCRIBE_MODEL:-whisper-large-v3-turbo}"
GROQ_API_BASE_URL="${GROQ_API_BASE_URL:-https://api.groq.com/openai/v1}"

for var in BOOKINGS_DB_USER BOOKINGS_DB_PASSWORD BOOKINGS_DB_NAME; do
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
log "Provider:  Groq Whisper"
log "Model:     $GROQ_TRANSCRIBE_MODEL"
log "Endpoint:  ${GROQ_API_BASE_URL}/audio/transcriptions"
log "Fixture:   $FIXTURE ($FIXTURE_SIZE bytes)"
log ""
log "Submitting ..."

HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 30 \
  -X POST "${GROQ_API_BASE_URL}/audio/transcriptions" \
  -H "Authorization: Bearer $GROQ_API_KEY" \
  -F "file=@${FIXTURE}" \
  -F "model=${GROQ_TRANSCRIBE_MODEL}" \
  -F "language=en" \
  -F "response_format=json")

HTTP_BODY=$(printf '%s' "$HTTP_RESPONSE" | sed '$d')
HTTP_CODE=$(printf '%s' "$HTTP_RESPONSE" | tail -1)

log "  HTTP $HTTP_CODE"

if [ "$HTTP_CODE" != "200" ]; then
  err "Groq returned non-200. Response body:"
  echo "$HTTP_BODY" >&2
  ESCAPED_BODY="${HTTP_BODY//\'/\'\'}"
  psql_exec "
    INSERT INTO event_log (workflow_name, level, event, message, data)
    VALUES (
      'voucher_groq_transcribe', 'error', 'transcribe_failed',
      'Groq audio.transcriptions returned HTTP ${HTTP_CODE}',
      jsonb_build_object('http_code', ${HTTP_CODE}, 'response', '${ESCAPED_BODY}'::jsonb)
    );
  " >/dev/null 2>&1 || true
  exit 1
fi

# ─────────────────────────────────────────────
# Parse + validate response
# Same shape as OpenAI: top-level `text` field with the transcript.
# ─────────────────────────────────────────────
TRANSCRIPT=$(printf '%s' "$HTTP_BODY" | jq -r '.text // ""')
TRANSCRIPT_LEN=${#TRANSCRIPT}

log "  transcript length: $TRANSCRIPT_LEN chars"
log "  transcript:        \"$TRANSCRIPT\""

if [ "$TRANSCRIPT_LEN" -eq 0 ]; then
  err "Groq returned empty transcript. Response body:"
  echo "$HTTP_BODY" >&2
  exit 1
fi

# Loose match — same logic as the OpenAI voucher. Catches "voucher test"
# (correct), "Voucher Test" (case variant), "a test" (partial), but flags
# total nonsense. The fixture's espeak-ng synthesis isn't natural speech,
# so the model may return slightly approximate text — `voucher` or `test`
# present is the floor.
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
  --arg model "$GROQ_TRANSCRIBE_MODEL" \
  --arg base "$GROQ_API_BASE_URL" \
  --arg fixture "$FIXTURE" \
  --argjson size "$FIXTURE_SIZE" \
  --arg transcript "$TRANSCRIPT" \
  --argjson tlen "$TRANSCRIPT_LEN" \
  '{provider: "groq", model: $model, base_url: $base, fixture: $fixture, fixture_bytes: $size, transcript: $transcript, transcript_length: $tlen}')
DATA_JSONB_SQL_SAFE="${DATA_JSONB//\'/\'\'}"

psql_exec "
  INSERT INTO event_log (workflow_name, level, event, message, data)
  VALUES (
    'voucher_groq_transcribe', 'info', 'transcribe_succeeded',
    'Groq ${GROQ_TRANSCRIBE_MODEL} returned ${TRANSCRIPT_LEN}-char transcript',
    '${DATA_JSONB_SQL_SAFE}'::jsonb
  );
" >/dev/null

EVENT_COUNT=$(psql_exec "
  SELECT count(*) FROM event_log
  WHERE workflow_name = 'voucher_groq_transcribe'
    AND event = 'transcribe_succeeded'
    AND ts > NOW() - INTERVAL '60 seconds';
")

log ""
log "════════════════════════════════════════════"
log " groq-transcribe voucher — PASS"
log "════════════════════════════════════════════"
log "  Provider:             Groq"
log "  Model:                $GROQ_TRANSCRIBE_MODEL"
log "  Base URL:             $GROQ_API_BASE_URL"
log "  Fixture bytes:        $FIXTURE_SIZE"
log "  Transcript length:    $TRANSCRIPT_LEN"
log "  Transcript:           \"$TRANSCRIPT\""
log "  event_log rows just written (last 60s): $EVENT_COUNT"
log "════════════════════════════════════════════"
