#!/usr/bin/env bash
# voucher/anthropic.sh — Phase 4 voucher: Anthropic Messages API
#
# Proves we can call Claude from this environment. Two minimal calls — Sonnet
# and Haiku — each with a 1-sentence prompt. Each call writes one row to
# ai_call_log (V005 migration created the table); a summary row goes to
# event_log.
#
# NOT the full integration — that's the central claude.ts wrapper described in
# docs/03-integrations/claude-api.md. The voucher just exercises the wire
# shape and the cost-logging path so we know the table + math work end-to-end.
#
# Per researcher's 2026-04-26 verification of
# https://platform.claude.com/docs/en/api/messages:
#   - POST https://api.anthropic.com/v1/messages
#   - Headers: x-api-key, anthropic-version: 2023-06-01, content-type: application/json
#   - Body: {model, max_tokens, messages: [{role, content}]}
#   - Response: {content: [{type:"text", text:"..."}], usage: {input_tokens, output_tokens}, ...}
#
# Pricing (per researcher, 2026-04-26):
#   claude-sonnet-4-6: $3.00 / Mtok input, $15.00 / Mtok output
#   claude-haiku-4-5:  $1.00 / Mtok input, $5.00  / Mtok output
#
# Side effects:
#   - Two API calls (~30 input tokens + ~10 output tokens each → cost < $0.001 total)
#   - Two ai_call_log rows (one per model)
#   - One event_log row (workflow_name='voucher_anthropic')
#
# Prerequisites:
#   - infrastructure/.env with ANTHROPIC_API_KEY, ANTHROPIC_MODEL_SONNET, ANTHROPIC_MODEL_HAIKU
#   - hr-bookings-db container running, V005 applied
#   - curl, jq, docker, awk on PATH
#
# Usage: ./scripts/voucher/anthropic.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$ROOT/infrastructure/.env"

# Helpers — write to stderr so stdout is reserved for value-returning functions.
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
err() { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { err "$*"; exit 1; }

[ -f "$ENV_FILE" ] || die "$ENV_FILE not found"
# shellcheck source=/dev/null
source "$ENV_FILE"

for var in ANTHROPIC_API_KEY ANTHROPIC_MODEL_SONNET ANTHROPIC_MODEL_HAIKU \
           BOOKINGS_DB_USER BOOKINGS_DB_PASSWORD BOOKINGS_DB_NAME; do
  [ -n "${!var:-}" ] || die "Required env var '$var' missing"
done
for dep in curl jq docker awk; do
  command -v "$dep" >/dev/null 2>&1 || die "Required tool '$dep' not found"
done

BOOKINGS_DB_CONTAINER="${BOOKINGS_DB_CONTAINER:-hr-bookings-db}"

psql_exec() {
  docker exec -e PGPASSWORD="$BOOKINGS_DB_PASSWORD" "$BOOKINGS_DB_CONTAINER" \
    psql -U "$BOOKINGS_DB_USER" -d "$BOOKINGS_DB_NAME" -t -A -q -c "$1"
}

# Verify ai_call_log table exists (V005 must be applied).
TBL_EXISTS=$(psql_exec "SELECT count(*) FROM information_schema.tables WHERE table_name='ai_call_log'")
if [ "$TBL_EXISTS" != "1" ]; then
  die "Table ai_call_log not present. Run V005 migration first: docker compose -f infrastructure/docker-compose.yml run --rm migrate-bookings"
fi

# ─────────────────────────────────────────────
# The shared prompt — short, deterministic-leaning, model-cheap.
# Single sentence, no PII, no instructions to elaborate.
# ─────────────────────────────────────────────
PROMPT="Reply with exactly the word 'pong' and nothing else."

# Pricing table (USD per million tokens), per researcher 2026-04-26.
SONNET_INPUT_RATE=3.00
SONNET_OUTPUT_RATE=15.00
HAIKU_INPUT_RATE=1.00
HAIKU_OUTPUT_RATE=5.00

# ─────────────────────────────────────────────
# Issue one Messages API call. Logs the result, writes to ai_call_log,
# echoes the per-call cost on stdout for caller aggregation.
# Args: label model_id input_rate output_rate
# ─────────────────────────────────────────────
call_messages_api() {
  local label="$1"
  local model="$2"
  local input_rate="$3"
  local output_rate="$4"

  local request_body
  request_body=$(jq -n --arg model "$model" --arg prompt "$PROMPT" \
    '{model: $model, max_tokens: 32, messages: [{role: "user", content: $prompt}]}')

  local resp
  resp=$(curl -s -w "\n%{http_code}" --max-time 30 \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    https://api.anthropic.com/v1/messages \
    -d "$request_body")
  local http_code body
  http_code=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')

  if [ "$http_code" != "200" ]; then
    err "$label ($model): HTTP $http_code"
    echo "$body" >&2
    return 1
  fi

  local content input_tokens output_tokens
  content=$(printf '%s' "$body" | jq -r '.content[0].text // ""')
  input_tokens=$(printf '%s' "$body" | jq -r '.usage.input_tokens')
  output_tokens=$(printf '%s' "$body" | jq -r '.usage.output_tokens')

  if [ -z "$input_tokens" ] || [ -z "$output_tokens" ]; then
    err "$label: response missing usage tokens"
    echo "$body" >&2
    return 1
  fi

  # Note: gawk reserves `or` as a builtin, so we use full names for the rates.
  local cost
  cost=$(awk -v i="$input_tokens" -v o="$output_tokens" \
    -v inrate="$input_rate" -v outrate="$output_rate" \
    'BEGIN { printf "%.6f", (i * inrate + o * outrate) / 1000000 }')

  log "  $label ($model)"
  log "    content:      \"$content\""
  log "    input/output: $input_tokens / $output_tokens tokens"
  log "    cost:         \$$cost"

  # Truncate prompt to 200 chars (V005 schema convention; redaction-safe).
  local prompt_excerpt="${PROMPT:0:200}"
  local prompt_excerpt_sql="${prompt_excerpt//\'/\'\'}"

  psql_exec "
    INSERT INTO ai_call_log (workflow_name, model, input_tokens, output_tokens, cost_usd, prompt_excerpt)
    VALUES ('voucher_anthropic', '$model', $input_tokens, $output_tokens, $cost, '$prompt_excerpt_sql');
  " >/dev/null

  # Stdout: bare cost for caller aggregation.
  echo "$cost"
}

# ─────────────────────────────────────────────
# Run both calls
# ─────────────────────────────────────────────
log "Anthropic voucher — calling Sonnet then Haiku"
log ""
log "Sonnet call ..."
sonnet_cost=$(call_messages_api "Sonnet" "$ANTHROPIC_MODEL_SONNET" "$SONNET_INPUT_RATE" "$SONNET_OUTPUT_RATE")
log ""
log "Haiku call ..."
haiku_cost=$(call_messages_api "Haiku" "$ANTHROPIC_MODEL_HAIKU" "$HAIKU_INPUT_RATE" "$HAIKU_OUTPUT_RATE")

total_cost=$(awk -v s="$sonnet_cost" -v h="$haiku_cost" 'BEGIN { printf "%.6f", s + h }')

# ─────────────────────────────────────────────
# Summary to event_log
# ─────────────────────────────────────────────
DATA_JSONB=$(jq -nc \
  --arg sm "$ANTHROPIC_MODEL_SONNET" \
  --arg hm "$ANTHROPIC_MODEL_HAIKU" \
  --argjson sc "$sonnet_cost" \
  --argjson hc "$haiku_cost" \
  --argjson tc "$total_cost" \
  '{sonnet_model: $sm, haiku_model: $hm, sonnet_cost_usd: $sc, haiku_cost_usd: $hc, total_cost_usd: $tc}')
DATA_JSONB_SQL_SAFE="${DATA_JSONB//\'/\'\'}"

psql_exec "
  INSERT INTO event_log (workflow_name, level, event, message, data)
  VALUES (
    'voucher_anthropic', 'info', 'calls_succeeded',
    'Anthropic voucher: Sonnet + Haiku Messages API ping calls succeeded',
    '${DATA_JSONB_SQL_SAFE}'::jsonb
  );
" >/dev/null

# ─────────────────────────────────────────────
# Verify per-run row counts
# ─────────────────────────────────────────────
ai_rows=$(psql_exec "
  SELECT count(*) FROM ai_call_log
  WHERE workflow_name = 'voucher_anthropic'
    AND ts > NOW() - INTERVAL '60 seconds';
")
event_rows=$(psql_exec "
  SELECT count(*) FROM event_log
  WHERE workflow_name = 'voucher_anthropic'
    AND event = 'calls_succeeded'
    AND ts > NOW() - INTERVAL '60 seconds';
")

log ""
log "════════════════════════════════════════════"
log " anthropic voucher — PASS"
log "════════════════════════════════════════════"
log "  Sonnet cost:           \$$sonnet_cost"
log "  Haiku cost:            \$$haiku_cost"
log "  Total cost:            \$$total_cost"
log "  ai_call_log rows:      $ai_rows  (this run, last 60s)"
log "  event_log summary row: $event_rows  (this run, last 60s)"
log "════════════════════════════════════════════"
