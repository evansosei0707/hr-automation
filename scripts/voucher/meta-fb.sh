#!/usr/bin/env bash
# voucher/meta-fb.sh — Phase 4 voucher: Meta Graph API Facebook Page post + delete
#
# Proves we can post to and delete from the firm's Facebook Page using a
# Page Access Token. NOT the full integration (workflow E does the
# multi-platform fan-out with engagement sampling). The voucher posts ONE
# test message with `published: false` (never publicly visible) and
# immediately deletes it, so the Page isn't littered with test posts.
#
# Per researcher's 2026-04-27 verification of
# https://developers.facebook.com/docs/graph-api/changelog +
# https://developers.facebook.com/docs/graph-api/reference/page/feed/ +
# https://developers.facebook.com/docs/pages-api/posts:
#   - Pin Graph API v25.0 (released 2026-02-18; v20.0 deprecates 2026-09-24)
#   - POST https://graph.facebook.com/v25.0/{page-id}/feed
#       body: message (required), published (optional), access_token
#       response: {"id": "{page-id}_{post-id}"}  ← composite id
#   - DELETE https://graph.facebook.com/v25.0/{composite-id}
#       response: {"success": true}
#   - Permission: pages_manage_posts on a Page Access Token
#   - `published: false` creates a draft post visible to Page admins only —
#     not publicly visible. Cleanest voucher strategy: post invisibly,
#     capture id, delete the draft.
#
# Side effects:
#   - One POST + one DELETE against the Page (both invisible to public)
#   - One event_log row (workflow_name='voucher_meta_fb')
#
# Prerequisites:
#   - infrastructure/.env with META_PAGE_ID, META_PAGE_ACCESS_TOKEN
#   - hr-bookings-db container running
#   - curl, jq, docker on PATH
#
# Usage: ./scripts/voucher/meta-fb.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$ROOT/infrastructure/.env"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { err "$*"; exit 1; }

[ -f "$ENV_FILE" ] || die "$ENV_FILE not found"
# shellcheck source=/dev/null
source "$ENV_FILE"

for var in META_PAGE_ID META_PAGE_ACCESS_TOKEN BOOKINGS_DB_USER BOOKINGS_DB_PASSWORD BOOKINGS_DB_NAME; do
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

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MSG_TEXT="HRA Phase 4 voucher — invisible draft post, deleting in ~2s. ${TIMESTAMP}"

# ─────────────────────────────────────────────
# POST /{page-id}/feed
# ─────────────────────────────────────────────
log "Posting to Page ${META_PAGE_ID} (Graph API ${GRAPH_API_VERSION}, published=false) ..."

POST_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 15 \
  -X POST "https://graph.facebook.com/${GRAPH_API_VERSION}/${META_PAGE_ID}/feed" \
  -F "message=${MSG_TEXT}" \
  -F "published=false" \
  -F "access_token=${META_PAGE_ACCESS_TOKEN}")

POST_BODY=$(printf '%s' "$POST_RESPONSE" | sed '$d')
POST_CODE=$(printf '%s' "$POST_RESPONSE" | tail -1)
log "  POST HTTP ${POST_CODE}"

if [ "$POST_CODE" != "200" ]; then
  err "POST returned non-200. Body:"
  echo "$POST_BODY" >&2
  ESCAPED_BODY="${POST_BODY//\'/\'\'}"
  psql_exec "
    INSERT INTO event_log (workflow_name, level, event, message, data)
    VALUES (
      'voucher_meta_fb', 'error', 'post_failed',
      'Meta FB POST returned HTTP ${POST_CODE}',
      jsonb_build_object('http_code', ${POST_CODE}, 'response', '${ESCAPED_BODY}'::jsonb)
    );
  " >/dev/null 2>&1 || true
  exit 1
fi

COMPOSITE_ID=$(printf '%s' "$POST_BODY" | jq -r '.id // ""')
if [ -z "$COMPOSITE_ID" ] || [ "$COMPOSITE_ID" = "null" ]; then
  err "POST returned 200 but no id. Body:"
  echo "$POST_BODY" >&2
  exit 1
fi

log "  composite id: ${COMPOSITE_ID}"

# Sanity check the id format: {page-id}_{post-id}
if ! printf '%s' "$COMPOSITE_ID" | grep -qE '^[0-9]+_[0-9]+$'; then
  log "  WARN: id does not match {page-id}_{post-id} pattern; using verbatim for DELETE"
fi

# ─────────────────────────────────────────────
# Brief pause so the post is observably-created on Meta's side before we
# delete (defends against a race where Meta hasn't yet propagated the
# create to all internal stores when DELETE arrives — anecdotal, but
# adds <1s wall time to the voucher).
# ─────────────────────────────────────────────
sleep 1

# ─────────────────────────────────────────────
# DELETE /{composite-id}
# ─────────────────────────────────────────────
log "Deleting ${COMPOSITE_ID} ..."

DELETE_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 15 \
  -X DELETE "https://graph.facebook.com/${GRAPH_API_VERSION}/${COMPOSITE_ID}?access_token=${META_PAGE_ACCESS_TOKEN}")

DELETE_BODY=$(printf '%s' "$DELETE_RESPONSE" | sed '$d')
DELETE_CODE=$(printf '%s' "$DELETE_RESPONSE" | tail -1)
log "  DELETE HTTP ${DELETE_CODE}"

if [ "$DELETE_CODE" != "200" ]; then
  err "DELETE returned non-200. Body:"
  echo "$DELETE_BODY" >&2
  err "  WARNING: post ${COMPOSITE_ID} may still exist on the Page. Manual cleanup required."
  ESCAPED_BODY="${DELETE_BODY//\'/\'\'}"
  psql_exec "
    INSERT INTO event_log (workflow_name, level, event, message, data)
    VALUES (
      'voucher_meta_fb', 'error', 'delete_failed',
      'Meta FB DELETE returned HTTP ${DELETE_CODE} for ${COMPOSITE_ID}',
      jsonb_build_object('http_code', ${DELETE_CODE}, 'composite_id', '${COMPOSITE_ID}', 'response', '${ESCAPED_BODY}'::jsonb)
    );
  " >/dev/null 2>&1 || true
  exit 1
fi

DELETE_SUCCESS=$(printf '%s' "$DELETE_BODY" | jq -r '.success // false')
if [ "$DELETE_SUCCESS" != "true" ]; then
  err "DELETE returned 200 but body.success != true:"
  echo "$DELETE_BODY" >&2
  exit 1
fi

log "  delete confirmed: success=true"

# ─────────────────────────────────────────────
# Log to event_log
# ─────────────────────────────────────────────
DATA_JSONB=$(jq -nc \
  --arg page "$META_PAGE_ID" \
  --arg ver "$GRAPH_API_VERSION" \
  --arg cid "$COMPOSITE_ID" \
  --arg text "$MSG_TEXT" \
  '{page_id: $page, graph_api_version: $ver, composite_id: $cid, sent_text: $text, published: false, deleted: true}')
DATA_JSONB_SQL_SAFE="${DATA_JSONB//\'/\'\'}"

psql_exec "
  INSERT INTO event_log (workflow_name, level, event, message, data)
  VALUES (
    'voucher_meta_fb', 'info', 'post_and_delete_succeeded',
    'Meta FB voucher: invisible draft posted (${COMPOSITE_ID}) + deleted',
    '${DATA_JSONB_SQL_SAFE}'::jsonb
  );
" >/dev/null

EVENT_COUNT=$(psql_exec "
  SELECT count(*) FROM event_log
  WHERE workflow_name = 'voucher_meta_fb'
    AND event = 'post_and_delete_succeeded'
    AND ts > NOW() - INTERVAL '60 seconds';
")

log ""
log "════════════════════════════════════════════"
log " meta-fb voucher — PASS"
log "════════════════════════════════════════════"
log "  Page:              ${META_PAGE_ID}"
log "  Graph API:         ${GRAPH_API_VERSION}"
log "  Composite post id: ${COMPOSITE_ID}  (created with published=false, then deleted)"
log "  event_log rows just written (last 60s): ${EVENT_COUNT}"
log "════════════════════════════════════════════"
