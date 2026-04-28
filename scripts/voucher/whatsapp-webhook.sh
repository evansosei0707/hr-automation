#!/usr/bin/env bash
# voucher/whatsapp-webhook.sh — Phase 4 voucher: WhatsApp Cloud webhook handler
#
# Synthetic test harness for the n8n workflow at
# n8n-workflows/communications/a0-whatsapp-webhook-handler.json. Hits the local
# Nginx → n8n path directly. NO ngrok, NO Meta UI dependency. Re-runnable;
# leaves audit rows in event_log + workflow_errors per invocation.
#
# Tests:
#   1. GET verify-handshake (valid token)   — expect 200 + echoed challenge
#   2. GET verify-handshake (wrong token)   — expect 403 + 'Forbidden'
#   3. POST with valid HMAC                  — expect 200 + 'EVENT_RECEIVED'
#                                              + event_log row written
#   4. POST with invalid HMAC                — expect 403 + 'Forbidden'
#                                              + workflow_errors row written
#
# Real-traffic proof lives in event_log rows 12+13 from 2026-04-28T18:28-29Z
# (real WhatsApp messages from a Ghana phone +233 532 751 040, HMAC validated
# by the workflow's Code node — captured via Meta's verify-and-save in
# the Meta App Dashboard pointing at the ngrok URL). This script is the
# re-runnable synthetic harness for verifying the local pipeline still works.
#
# Prerequisites (none of which the script attempts to recreate — the operator
# must have these in place; see the workflow NOTES.md for setup steps):
#   - infrastructure/.env with WHATSAPP_VERIFY_TOKEN, WHATSAPP_APP_SECRET
#   - hr-n8n container running with NODE_FUNCTION_ALLOW_BUILTIN=crypto
#   - hr-bookings-db running, V001 + V005 applied
#   - hr-nginx running with the default_server block (per nginx.conf at HEAD)
#   - a0-whatsapp-webhook-handler workflow ACTIVATED in n8n
#   - curl, jq, openssl, docker on PATH
#
# Override base URL (e.g. ngrok) via WHATSAPP_VOUCHER_BASE_URL env var.
# Default: http://localhost (the Nginx default_server route).
#
# Usage: ./scripts/voucher/whatsapp-webhook.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$ROOT/infrastructure/.env"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { err "$*"; exit 1; }

[ -f "$ENV_FILE" ] || die "$ENV_FILE not found"
# shellcheck source=/dev/null
source "$ENV_FILE"

for var in WHATSAPP_VERIFY_TOKEN WHATSAPP_APP_SECRET BOOKINGS_DB_USER BOOKINGS_DB_PASSWORD BOOKINGS_DB_NAME; do
  [ -n "${!var:-}" ] || die "Required env var '$var' missing"
done
for dep in curl jq openssl docker; do
  command -v "$dep" >/dev/null 2>&1 || die "Required tool '$dep' not found"
done

BOOKINGS_DB_CONTAINER="${BOOKINGS_DB_CONTAINER:-hr-bookings-db}"
BASE_URL="${WHATSAPP_VOUCHER_BASE_URL:-http://localhost}"

psql_exec() {
  docker exec -e PGPASSWORD="$BOOKINGS_DB_PASSWORD" "$BOOKINGS_DB_CONTAINER" \
    psql -U "$BOOKINGS_DB_USER" -d "$BOOKINGS_DB_NAME" -t -A -q -c "$1"
}

T0=$(date -u +%s)
failures=0

http_split() {
  # Splits "<body>\n--HTTP-CODE--<code>" into BODY and CODE globals.
  BODY=$(printf '%s' "$1" | sed 's/--HTTP-CODE--[0-9]*$//')
  CODE=$(printf '%s' "$1" | grep -oE '\-\-HTTP-CODE\-\-[0-9]+$' | sed 's/--HTTP-CODE--//')
}

assert_pass() { log "  ✓ PASS"; }
assert_fail() { err "  ✗ FAIL: $1"; failures=$((failures + 1)); }

log "WhatsApp webhook voucher — synthetic harness"
log "Base URL: $BASE_URL"
log "T0:       $T0"
log ""

# ─────────────────────────────────────────────
# Test 1 — GET valid token
# ─────────────────────────────────────────────
log "Test 1/4: GET verify-handshake (valid token)"
challenge="voucher_challenge_${T0}"
resp=$(curl -s -w "\n--HTTP-CODE--%{http_code}" \
  "${BASE_URL}/webhook/whatsapp?hub.mode=subscribe&hub.verify_token=${WHATSAPP_VERIFY_TOKEN}&hub.challenge=${challenge}")
http_split "$resp"
log "  body: $BODY"
log "  code: $CODE"
if [ "$CODE" = "200" ] && [ "$BODY" = "$challenge" ]; then assert_pass; else assert_fail "expected 200 + body='$challenge'"; fi
log ""

# ─────────────────────────────────────────────
# Test 2 — GET wrong token
# ─────────────────────────────────────────────
log "Test 2/4: GET verify-handshake (wrong token)"
resp=$(curl -s -w "\n--HTTP-CODE--%{http_code}" \
  "${BASE_URL}/webhook/whatsapp?hub.mode=subscribe&hub.verify_token=WRONG_VOUCHER_TOKEN&hub.challenge=should_not_echo")
http_split "$resp"
log "  body: $BODY"
log "  code: $CODE"
if [ "$CODE" = "403" ] && [ "$BODY" = "Forbidden" ]; then assert_pass; else assert_fail "expected 403 + 'Forbidden'"; fi
log ""

# ─────────────────────────────────────────────
# Test 3 — POST valid HMAC
# ─────────────────────────────────────────────
log "Test 3/4: POST with valid HMAC"
body_valid=$(jq -nc --arg id "wamid.voucher_${T0}" --arg ts "$T0" \
  '{object:"whatsapp_business_account",entry:[{id:"voucher_test",changes:[{value:{messaging_product:"whatsapp",metadata:{display_phone_number:"15556325095",phone_number_id:"voucher_test"},contacts:[{profile:{name:"Voucher Synthetic"},wa_id:"233244000001"}],messages:[{from:"233244000001",id:$id,timestamp:$ts,type:"text",text:{body:"voucher synthetic test — valid HMAC"}}]},field:"messages"}]}]}')
sig=$(printf '%s' "$body_valid" | openssl dgst -sha256 -hmac "$WHATSAPP_APP_SECRET" | awk '{print $2}')
resp=$(curl -s -w "\n--HTTP-CODE--%{http_code}" \
  -X POST "${BASE_URL}/webhook/whatsapp" \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: sha256=${sig}" \
  -d "$body_valid")
http_split "$resp"
log "  body: $BODY"
log "  code: $CODE"
if [ "$CODE" = "200" ] && [ "$BODY" = "EVENT_RECEIVED" ]; then assert_pass; else assert_fail "expected 200 + 'EVENT_RECEIVED'"; fi
log ""

# ─────────────────────────────────────────────
# Test 4 — POST invalid HMAC
# ─────────────────────────────────────────────
log "Test 4/4: POST with INVALID HMAC"
resp=$(curl -s -w "\n--HTTP-CODE--%{http_code}" \
  -X POST "${BASE_URL}/webhook/whatsapp" \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: sha256=0000000000000000000000000000000000000000000000000000000000000000" \
  -d '{"object":"whatsapp_business_account","entry":[{"id":"spoof"}]}')
http_split "$resp"
log "  body: $BODY"
log "  code: $CODE"
if [ "$CODE" = "403" ] && [ "$BODY" = "Forbidden" ]; then assert_pass; else assert_fail "expected 403 + 'Forbidden'"; fi
log ""

# ─────────────────────────────────────────────
# DB row counts — Test 3 should add 1 to event_log; Test 4 should add 1 to workflow_errors
# ─────────────────────────────────────────────
log "DB row count check (since T0=$T0):"
event_count=$(psql_exec "SELECT count(*) FROM event_log WHERE workflow_name='workflow_a_inbound_whatsapp' AND ts >= to_timestamp(${T0})")
err_count=$(psql_exec "SELECT count(*) FROM workflow_errors WHERE workflow_name='workflow_a_inbound_whatsapp' AND occurred_at >= to_timestamp(${T0})")
log "  event_log new rows:        $event_count  (expected: 1)"
log "  workflow_errors new rows:  $err_count  (expected: 1)"
if [ "$event_count" = "1" ] && [ "$err_count" = "1" ]; then assert_pass; else assert_fail "row counts unexpected"; fi
log ""

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
echo "════════════════════════════════════════════"
if [ "$failures" -eq 0 ]; then
  echo " whatsapp-webhook voucher — PASS"
else
  echo " whatsapp-webhook voucher — FAIL ($failures issue(s))"
fi
echo "════════════════════════════════════════════"
echo " Provider:           Meta WhatsApp Cloud API"
echo " Workflow:           a0-whatsapp-webhook-handler (must be ACTIVE in n8n)"
echo " Base URL tested:    $BASE_URL/webhook/whatsapp"
echo " Tests:              4 synthetic"
echo " event_log delta:    $event_count"
echo " workflow_errors Δ:  $err_count"
echo "════════════════════════════════════════════"

[ "$failures" -eq 0 ] || exit 1
