#!/usr/bin/env bash
# Migration runner for the bookings DB.
# Applies any VNNN__*.sql file in database/migrations/ that has not yet been recorded
# in the schema_migrations table.
#
# Called by docker-compose's migrate-bookings service on every `up`.
# Safe to run repeatedly.
set -euo pipefail

MIGRATIONS_DIR="${MIGRATIONS_DIR:-/migrations}"

if [ ! -d "$MIGRATIONS_DIR" ]; then
  echo "ERROR: migrations directory not found: $MIGRATIONS_DIR" >&2
  exit 1
fi

# Wait for DB to be reachable
until pg_isready -q; do
  echo "Waiting for database..."
  sleep 1
done

# Get already-applied versions
APPLIED=$(psql -tA -c "SELECT version FROM schema_migrations ORDER BY version;" 2>/dev/null || true)

echo "Already applied:"
echo "$APPLIED" | sed 's/^/  /'

shopt -s nullglob
for file in "$MIGRATIONS_DIR"/V*.sql; do
  version=$(basename "$file" .sql)
  if echo "$APPLIED" | grep -qx "$version"; then
    continue
  fi
  echo "==> Applying $version"
  psql -v ON_ERROR_STOP=1 -f "$file"
done

echo "==> All migrations applied."
