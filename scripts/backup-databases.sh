#!/usr/bin/env bash
# backup-databases.sh
#
# LOCAL-DRILL VERSION. Production version (cron-driven, with rclone→B2 sync,
# 30-day rotation, lockfile, paging on failure) is deferred to Week 4 — see
# `plans/tier-2-followups.md` item "Production-grade backup script".
#
# Dumps three Postgres databases via `docker exec` + `pg_dump`, gzips each
# to a timestamped local output directory, prints size + duration per dump,
# exits non-zero if any dump failed or produced a suspiciously small file.
#
# Inventory (per docs/04-operations/backup-dr.md, corrected by 2026-04-29 audit):
#
#   Label      Container        User             DB
#   --------   --------------   --------------   --------
#   twenty     hr-twenty-db     twenty           twenty
#   bookings   hr-bookings-db   n8n_bookings     bookings
#   n8n        hr-bookings-db   n8n              n8n
#
# Redis state is intentionally NOT backed up — locks, dedupe keys, and
# idempotency markers are ephemeral by design (see backup-dr.md "Redis state").
#
# Local-only: this script does NOT push to Backblaze B2, does NOT prune old
# backups, does NOT page on failure. All of that lives in the production
# script.
#
# Usage:
#   ./scripts/backup-databases.sh                    # default: ./backups/<UTC stamp>/
#   ./scripts/backup-databases.sh -o /custom/path    # custom output base

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/infrastructure/.env"
OUTPUT_BASE="$ROOT/backups"

while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUTPUT_BASE="$2"; shift 2 ;;
    *)  echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# .env is config-driven — local dev sources from infrastructure/.env;
# production deployments will source from a deployment-time path
# (decided when the production script lands in Week 4).
[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found" >&2; exit 1; }
# shellcheck source=/dev/null
source "$ENV_FILE"

for v in TWENTY_DB_USER TWENTY_DB_PASSWORD TWENTY_DB_NAME \
         BOOKINGS_DB_USER BOOKINGS_DB_PASSWORD BOOKINGS_DB_NAME \
         N8N_DB_USER N8N_DB_PASSWORD N8N_DB_NAME; do
  [ -n "${!v:-}" ] || { echo "ERROR: required env var '$v' missing in $ENV_FILE" >&2; exit 1; }
done
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found on PATH" >&2; exit 1; }

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$OUTPUT_BASE/$STAMP"
mkdir -p "$OUT"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
log "Output dir: $OUT"

failures=0
dump_db() {
  local label=$1 container=$2 user=$3 db=$4 password=$5
  local outfile="$OUT/${label}.sql.gz"
  local start size human elapsed
  start=$(date +%s.%N)
  # `--clean --if-exists` makes the dump restorable into an existing DB
  # without manual DROP. Sane default for a drill artifact.
  # `set -o pipefail` (top of script) ensures pg_dump's non-zero exit
  # propagates through the gzip pipe, so the `if !` catches DB failures.
  if ! docker exec -e PGPASSWORD="$password" "$container" \
         pg_dump -U "$user" -d "$db" --clean --if-exists \
       | gzip > "$outfile"; then
    log "[FAIL] $label: pg_dump|gzip failed"
    rm -f "$outfile"
    failures=$((failures+1))
    return
  fi
  size=$(stat -c%s "$outfile")
  if [ "$size" -lt 100 ]; then
    log "[FAIL] $label: dump suspiciously small (${size} bytes)"
    failures=$((failures+1))
    return
  fi
  human=$(numfmt --to=iec --suffix=B "$size")
  elapsed=$(awk "BEGIN { printf \"%.2fs\", $(date +%s.%N) - $start }")
  printf "  %-10s %10s  %10s  %s\n" "$label" "$human" "$elapsed" "$outfile"
}

echo
printf "  %-10s %10s  %10s  %s\n" "DB" "SIZE" "DURATION" "FILE"
printf -- "  ------------------------------------------------------------\n"

dump_db twenty   hr-twenty-db   "$TWENTY_DB_USER"   "$TWENTY_DB_NAME"   "$TWENTY_DB_PASSWORD"
dump_db bookings hr-bookings-db "$BOOKINGS_DB_USER" "$BOOKINGS_DB_NAME" "$BOOKINGS_DB_PASSWORD"
dump_db n8n      hr-bookings-db "$N8N_DB_USER"      "$N8N_DB_NAME"      "$N8N_DB_PASSWORD"
echo

if [ "$failures" -gt 0 ]; then
  log "[FAIL] $failures of 3 dumps failed."
  exit 1
fi
log "[PASS] All 3 dumps complete."
exit 0
