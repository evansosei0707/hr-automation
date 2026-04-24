-- Bookings DB initialization.
-- Runs once on first container start. Idempotent.
-- Creates the schema_migrations tracking table; real schema is applied
-- by the migration runner from database/migrations/V*.sql files.

CREATE TABLE IF NOT EXISTS schema_migrations (
  version TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  checksum TEXT
);

-- Useful extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
