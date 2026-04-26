#!/usr/bin/env bash
# reset-twenty-schema.sh
# Hard-resets the Twenty workspace + the apply-script tracker to a clean state.
#
# Deletes every custom object from Twenty (built-ins like company, person,
# workspaceMember are NEVER touched — `isCustom: false` is a hard filter).
# Truncates twenty_schema_migrations.
# Does NOT touch workflow_errors — that is historical evidence and stays.
#
# When to use:
#   - After a partial-apply failure that left orphan objects in Twenty.
#   - Before re-running apply-twenty-schema.sh from a clean baseline.
#
# This is destructive. Belt-and-braces companion to the apply script's
# partial-apply-detection refusal: when the apply script bails, this is
# the codified path forward instead of UI-clicking.
#
# Prerequisites:
#   - curl, jq, docker on PATH
#   - infrastructure/.env with TWENTY_API_KEY, TWENTY_API_BASE_URL, bookings DB vars
#
# Usage:
#   ./scripts/reset-twenty-schema.sh           # interactive confirm
#   ./scripts/reset-twenty-schema.sh --yes     # skip prompt (CI/scripting)
set -euo pipefail

# ─────────────────────────────────────────────
# Paths + helpers
# ─────────────────────────────────────────────
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/infrastructure/.env"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { err "$*"; exit 1; }

# ─────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────
[ -f "$ENV_FILE" ] || die "$ENV_FILE not found. Run ./scripts/bootstrap.sh first."
# shellcheck source=/dev/null
source "$ENV_FILE"

for var in TWENTY_API_KEY TWENTY_API_BASE_URL BOOKINGS_DB_USER BOOKINGS_DB_PASSWORD BOOKINGS_DB_NAME; do
  [ -n "${!var:-}" ] || die "Required env var '$var' missing in .env"
done

for dep in curl jq docker; do
  command -v "$dep" >/dev/null 2>&1 || die "Required tool '$dep' not found on PATH"
done

TWENTY_BASE="${TWENTY_API_BASE_URL%/}"
BOOKINGS_DB_CONTAINER="${BOOKINGS_DB_CONTAINER:-hr-bookings-db}"

psql_exec() {
  docker exec -e PGPASSWORD="$BOOKINGS_DB_PASSWORD" "$BOOKINGS_DB_CONTAINER" \
    psql -U "$BOOKINGS_DB_USER" -d "$BOOKINGS_DB_NAME" -t -A -q -c "$1"
}

# ─────────────────────────────────────────────
# Discover state to be reset
# ─────────────────────────────────────────────
log "Listing custom objects in $TWENTY_BASE ..."
LIST=$(curl -s --max-time 15 -X POST "$TWENTY_BASE/metadata" \
  -H "Authorization: Bearer $TWENTY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"query { objects(paging:{first:200}) { edges { node { nameSingular id isCustom } } } }"}')

LIST_ERRORS=$(echo "$LIST" | jq -r '.errors // empty')
[ -z "$LIST_ERRORS" ] || { err "Failed to list objects:"; echo "$LIST" >&2; exit 1; }

declare -a NAMES=() UUIDS=()
while IFS=$'\t' read -r name uuid; do
  [ -n "$name" ] || continue
  NAMES+=("$name")
  UUIDS+=("$uuid")
done < <(echo "$LIST" | jq -r '.data.objects.edges[] | select(.node.isCustom) | [.node.nameSingular, .node.id] | @tsv')

TRACKER_COUNT=$(psql_exec "SELECT COUNT(*) FROM twenty_schema_migrations" 2>/dev/null || echo "0")

# ─────────────────────────────────────────────
# Show plan + confirm
# ─────────────────────────────────────────────
echo
echo "════════════════════════════════════════════"
echo " reset-twenty-schema.sh — Plan"
echo "════════════════════════════════════════════"
echo " Target:                  $TWENTY_BASE"
echo " Custom objects to delete: ${#NAMES[@]}"
for n in "${NAMES[@]}"; do echo "   - $n"; done
echo " Tracker rows to clear:   $TRACKER_COUNT"
echo " workflow_errors:         NOT touched (historical)"
echo "════════════════════════════════════════════"
echo

if [ ${#NAMES[@]} -eq 0 ] && [ "$TRACKER_COUNT" = "0" ]; then
  log "Already clean. Nothing to do."
  exit 0
fi

if [ "${1:-}" != "--yes" ]; then
  read -p "Proceed with reset? [y/N] " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
fi

# ─────────────────────────────────────────────
# Delete each custom object
# ─────────────────────────────────────────────
for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"
  uuid="${UUIDS[$i]}"
  log "Deleting $name ($uuid) ..."
  RESP=$(curl -s --max-time 15 -X POST "$TWENTY_BASE/metadata" \
    -H "Authorization: Bearer $TWENTY_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"mutation { deleteOneObject(input: {id: \\\"$uuid\\\"}) { id } }\"}")
  RESP_ERR=$(echo "$RESP" | jq -r '.errors // empty')
  if [ -n "$RESP_ERR" ]; then
    err "Failed to delete $name. Response:"
    echo "$RESP" >&2
    exit 1
  fi
  sleep 1.2   # respect ~50 req/min pacing (apply script's pattern)
done

# ─────────────────────────────────────────────
# Clear tracker (workflow_errors stays — historical evidence)
# ─────────────────────────────────────────────
if [ "$TRACKER_COUNT" != "0" ]; then
  log "Clearing twenty_schema_migrations tracker ..."
  psql_exec "TRUNCATE TABLE twenty_schema_migrations" >/dev/null
fi

# ─────────────────────────────────────────────
# Verify clean
# ─────────────────────────────────────────────
VERIFY=$(curl -s --max-time 15 -X POST "$TWENTY_BASE/metadata" \
  -H "Authorization: Bearer $TWENTY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"query { objects(paging:{first:200}) { edges { node { isCustom } } } }"}')
REMAINING=$(echo "$VERIFY" | jq '[.data.objects.edges[] | select(.node.isCustom)] | length')
TRACKER_NOW=$(psql_exec "SELECT COUNT(*) FROM twenty_schema_migrations")

echo
echo "════════════════════════════════════════════"
echo " Reset complete"
echo "════════════════════════════════════════════"
echo " Custom objects remaining: $REMAINING (expected: 0)"
echo " Tracker rows now:         $TRACKER_NOW (expected: 0)"
echo "════════════════════════════════════════════"

[ "$REMAINING" = "0" ] && [ "$TRACKER_NOW" = "0" ] || die "Reset did not result in a clean state."
