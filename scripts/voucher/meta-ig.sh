#!/usr/bin/env bash
# voucher/meta-ig.sh — Phase 4 voucher: Meta Graph API Instagram publish + delete
#
# Companion to meta-fb.sh. Currently SKIP-GATED on META_IG_USER_ID being
# empty — the firm's Instagram link to Meta Business is on a soft-hold
# (~48h) for new accounts. Re-run this voucher once the link unsticks
# and META_IG_USER_ID is populated; the post-and-delete code path is
# fully written below.
#
# Per researcher's 2026-04-26 verification of
# https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login:
#   - Two-step publish:
#       1. POST /v25.0/{ig-user-id}/media         → returns {id: container_id}
#       2. POST /v25.0/{ig-user-id}/media_publish → returns {id: media_id}
#   - DELETE /v25.0/{media_id}                    → returns {success: true}
#   - Image must be hosted at a public URL Meta can fetch (no signed S3
#     URLs that expire). For the voucher we use a stable Wikimedia Commons
#     placeholder image.
#   - Permission: instagram_content_publish on the Page Access Token.
#
# Side effects when not skip-gated:
#   - One IG post created + immediately deleted (post is visible to
#     followers for ~2 seconds during the gap; trade-off accepted —
#     IG has no equivalent of FB's `published: false` draft mode)
#   - One event_log row (workflow_name='voucher_meta_ig')
#
# Skip behaviour:
#   - If META_IG_USER_ID is empty/unset: log "skipped" + exit 0 cleanly.
#     event_log gets a 'skipped' row so the operator can see WHY the
#     voucher hasn't run yet (Meta IG soft-hold, not a missed config).
#
# Prerequisites:
#   - infrastructure/.env with META_PAGE_ACCESS_TOKEN; META_IG_USER_ID
#     optional (skip-gates if empty)
#   - hr-bookings-db container running
#   - curl, jq, docker on PATH
#
# Usage: ./scripts/voucher/meta-ig.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$ROOT/infrastructure/.env"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { err "$*"; exit 1; }

[ -f "$ENV_FILE" ] || die "$ENV_FILE not found"
# shellcheck source=/dev/null
source "$ENV_FILE"

for var in META_PAGE_ACCESS_TOKEN BOOKINGS_DB_USER BOOKINGS_DB_PASSWORD BOOKINGS_DB_NAME; do
  [ -n "${!var:-}" ] || die "Required env var '$var' missing"
done
for dep in curl jq docker; do
  command -v "$dep" >/dev/null 2>&1 || die "Required tool '$dep' not found"
done

BOOKINGS_DB_CONTAINER="${BOOKINGS_DB_CONTAINER:-hr-bookings-db}"
GRAPH_API_VERSION="${META_GRAPH_API_VERSION:-v25.0}"

psql_exec() {
  docker exec -e PGPASSWORD="$BOOKINGS_DB_PASSWORD" "$BOOKINGS_DB_CONTAINER" \
    psql -U "$BOOKINGS_DB_USER" -d "$BOOKINGS_DB_NAME" -t -A -q -c "$1"
}

# ─────────────────────────────────────────────
# Skip-gate: if META_IG_USER_ID is empty, log + exit cleanly.
# ─────────────────────────────────────────────
if [ -z "${META_IG_USER_ID:-}" ]; then
  log "META_IG_USER_ID is empty — Instagram link to Meta Business is not set up yet."
  log "  Likely cause: ~48h soft-hold on new IG accounts (per Phase 4 brief 2026-04-27)."
  log "  Re-run this voucher once IG link unsticks and META_IG_USER_ID is populated."
  log "  No API calls made. No state mutated."

  psql_exec "
    INSERT INTO event_log (workflow_name, level, event, message, data)
    VALUES (
      'voucher_meta_ig', 'warn', 'skipped',
      'Meta IG voucher skipped: META_IG_USER_ID empty (Meta soft-hold on new IG account link)',
      jsonb_build_object('reason', 'META_IG_USER_ID_empty', 'expected_unblock_eta', '2026-04-28_or_29')
    );
  " >/dev/null

  log ""
  log "════════════════════════════════════════════"
  log " meta-ig voucher — SKIPPED (env not set)"
  log "════════════════════════════════════════════"
  exit 0
fi

# ─────────────────────────────────────────────
# Real run path — META_IG_USER_ID is set.
#
# We use a stable placeholder image. Wikimedia Commons "1x1 transparent
# pixel" is too small for IG (min 320x320); use a real photo. The
# Wikipedia Commons "World map" image is a stable choice. If this URL
# rots, swap any other Commons image >= 320x320.
# ─────────────────────────────────────────────
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
IG_IMAGE_URL="${META_IG_TEST_IMAGE_URL:-https://upload.wikimedia.org/wikipedia/commons/thumb/8/83/Equirectangular_projection_SW.jpg/640px-Equirectangular_projection_SW.jpg}"
IG_CAPTION="HRA Phase 4 voucher — deleting immediately. ${TIMESTAMP}"

# Step 1 — create container
log "IG step 1: create media container (image_url=${IG_IMAGE_URL}) ..."
CONTAINER_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 30 \
  -X POST "https://graph.facebook.com/${GRAPH_API_VERSION}/${META_IG_USER_ID}/media" \
  -F "image_url=${IG_IMAGE_URL}" \
  -F "caption=${IG_CAPTION}" \
  -F "access_token=${META_PAGE_ACCESS_TOKEN}")

CONTAINER_BODY=$(printf '%s' "$CONTAINER_RESPONSE" | sed '$d')
CONTAINER_CODE=$(printf '%s' "$CONTAINER_RESPONSE" | tail -1)
log "  HTTP ${CONTAINER_CODE}"

if [ "$CONTAINER_CODE" != "200" ]; then
  err "Container create returned non-200. Body:"
  echo "$CONTAINER_BODY" >&2
  ESCAPED_BODY="${CONTAINER_BODY//\'/\'\'}"
  psql_exec "
    INSERT INTO event_log (workflow_name, level, event, message, data)
    VALUES ('voucher_meta_ig', 'error', 'container_create_failed',
            'IG container create returned HTTP ${CONTAINER_CODE}',
            jsonb_build_object('http_code', ${CONTAINER_CODE}, 'response', '${ESCAPED_BODY}'::jsonb));
  " >/dev/null 2>&1 || true
  exit 1
fi

CONTAINER_ID=$(printf '%s' "$CONTAINER_BODY" | jq -r '.id // ""')
[ -n "$CONTAINER_ID" ] && [ "$CONTAINER_ID" != "null" ] || die "Container create OK but no id returned"
log "  container_id: ${CONTAINER_ID}"

# Step 2 — publish container
log "IG step 2: publish container ..."
PUBLISH_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 30 \
  -X POST "https://graph.facebook.com/${GRAPH_API_VERSION}/${META_IG_USER_ID}/media_publish" \
  -F "creation_id=${CONTAINER_ID}" \
  -F "access_token=${META_PAGE_ACCESS_TOKEN}")

PUBLISH_BODY=$(printf '%s' "$PUBLISH_RESPONSE" | sed '$d')
PUBLISH_CODE=$(printf '%s' "$PUBLISH_RESPONSE" | tail -1)
log "  HTTP ${PUBLISH_CODE}"

if [ "$PUBLISH_CODE" != "200" ]; then
  err "Publish returned non-200. Body:"
  echo "$PUBLISH_BODY" >&2
  exit 1
fi

MEDIA_ID=$(printf '%s' "$PUBLISH_BODY" | jq -r '.id // ""')
[ -n "$MEDIA_ID" ] && [ "$MEDIA_ID" != "null" ] || die "Publish OK but no media_id returned"
log "  media_id: ${MEDIA_ID}"

sleep 1   # let the post propagate before delete

# Step 3 — delete published media
log "Deleting media ${MEDIA_ID} ..."
DELETE_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 15 \
  -X DELETE "https://graph.facebook.com/${GRAPH_API_VERSION}/${MEDIA_ID}?access_token=${META_PAGE_ACCESS_TOKEN}")
DELETE_BODY=$(printf '%s' "$DELETE_RESPONSE" | sed '$d')
DELETE_CODE=$(printf '%s' "$DELETE_RESPONSE" | tail -1)
log "  DELETE HTTP ${DELETE_CODE}"

if [ "$DELETE_CODE" != "200" ]; then
  err "DELETE returned non-200. Body:"
  echo "$DELETE_BODY" >&2
  err "  WARNING: media ${MEDIA_ID} may still be on the IG account. Manual cleanup required."
  exit 1
fi

DELETE_SUCCESS=$(printf '%s' "$DELETE_BODY" | jq -r '.success // false')
[ "$DELETE_SUCCESS" = "true" ] || die "DELETE returned 200 but body.success != true"
log "  delete confirmed: success=true"

# ─────────────────────────────────────────────
# Log to event_log
# ─────────────────────────────────────────────
DATA_JSONB=$(jq -nc \
  --arg ig "$META_IG_USER_ID" \
  --arg ver "$GRAPH_API_VERSION" \
  --arg cid "$CONTAINER_ID" \
  --arg mid "$MEDIA_ID" \
  --arg img "$IG_IMAGE_URL" \
  --arg cap "$IG_CAPTION" \
  '{ig_user_id: $ig, graph_api_version: $ver, container_id: $cid, media_id: $mid, image_url: $img, caption: $cap, deleted: true}')
DATA_JSONB_SQL_SAFE="${DATA_JSONB//\'/\'\'}"

psql_exec "
  INSERT INTO event_log (workflow_name, level, event, message, data)
  VALUES (
    'voucher_meta_ig', 'info', 'publish_and_delete_succeeded',
    'Meta IG voucher: image posted (${MEDIA_ID}) + deleted',
    '${DATA_JSONB_SQL_SAFE}'::jsonb
  );
" >/dev/null

log ""
log "════════════════════════════════════════════"
log " meta-ig voucher — PASS"
log "════════════════════════════════════════════"
log "  IG user:      ${META_IG_USER_ID}"
log "  Container id: ${CONTAINER_ID}"
log "  Media id:     ${MEDIA_ID}  (published, then deleted)"
log "════════════════════════════════════════════"
