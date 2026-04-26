#!/bin/sh
# Provisions the n8n role and database on bookings-db at first init.
# Runs once on first container start, after init-bookings-db.sql,
# via the postgres official-image entrypoint.
# Idempotent: docker only runs this when the data dir is empty.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER "$N8N_DB_USER" WITH PASSWORD '$N8N_DB_PASSWORD';
    CREATE DATABASE "$N8N_DB_NAME" OWNER "$N8N_DB_USER";
    GRANT ALL PRIVILEGES ON DATABASE "$N8N_DB_NAME" TO "$N8N_DB_USER";
EOSQL
