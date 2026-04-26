-- V004__twenty_schema_tracker.sql
-- Purpose: Create the twenty_schema_migrations table used by scripts/apply-twenty-schema.sh
--          to track which Twenty metadata migrations have been applied. Piggybacks on the
--          bookings DB so that schema state is version-controlled, backed-up, and auditable
--          alongside the bookings-DB migrations themselves.
-- Author: schema-designer
-- Date: 2026-04-26
-- Spec: twenty-schema/README.md §"Tracker table — bookings_db.twenty_schema_migrations"

BEGIN;

CREATE TABLE twenty_schema_migrations (
  version           TEXT        PRIMARY KEY,          -- e.g. 'V001'
  description       TEXT        NOT NULL,
  applied_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  operations_count  INT         NOT NULL,
  applied_by        TEXT        NOT NULL,             -- API-key role or 'apply-twenty-schema.sh'
  applied_against   TEXT        NOT NULL              -- TWENTY_API_BASE_URL at apply time, for audit
);

CREATE INDEX idx_twenty_schema_migrations_applied_at
  ON twenty_schema_migrations (applied_at DESC);

INSERT INTO schema_migrations (version) VALUES ('V004__twenty_schema_tracker');

COMMIT;

-- Rollback:
--   BEGIN;
--   DROP TABLE IF EXISTS twenty_schema_migrations;
--   DELETE FROM schema_migrations WHERE version = 'V004__twenty_schema_tracker';
--   COMMIT;
--
-- Note: rolling back this migration does NOT undo anything that was applied
-- against the live Twenty instance. The tracker is metadata about what was
-- applied; the Twenty objects themselves must be removed manually via the
-- Twenty UI or DELETE mutations if a roll-back of the Twenty schema is needed.
