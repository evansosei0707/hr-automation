-- V012__interviewer_availability.sql
-- Purpose: per-interviewer recurring availability windows. The daily Workflow D
--   slot generator (05:00 Africa/Accra Cron) reads this table to materialise
--   concrete slot rows for the next 14 days, vetoed by Google Calendar busy
--   time from freebusy.query. The Operations Lead seeds one row per interviewer
--   per recurring window; they do not hand-enter weekly slot rows.
--   Times are stored in Africa/Accra local (Ghana has no DST; v1 treats all
--   interviewers as Accra — see T2-D-6 for multi-timezone follow-up).
--   The generator converts starts_local/ends_local to UTC at materialisation.
-- Author: schema-designer
-- Date: 2026-05-02
-- Spec: docs/02-workflows/d-scheduling-design-v1.md §2 (V012), §3 (slot generator)
--       docs/05-decisions/ADR-0012-slot-sourcing-hybrid.md

BEGIN;

CREATE TABLE interviewer_availability (
  id              BIGSERIAL    PRIMARY KEY,
  interviewer_id  UUID         NOT NULL
                    CONSTRAINT fk_interviewer_availability_interviewer
                    REFERENCES interviewer(id) ON DELETE CASCADE,
  day_of_week     INT          NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),  -- 0=Sunday, 6=Saturday
  starts_local    TIME         NOT NULL,   -- e.g. '09:00:00' Africa/Accra
  ends_local      TIME         NOT NULL,   -- e.g. '17:00:00' Africa/Accra
  slot_minutes    INT          NOT NULL DEFAULT 45,
  is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT availability_window_valid CHECK (ends_local > starts_local)
);

-- The daily generator's primary lookup: find all active windows per interviewer.
-- Partial index keeps the index small and the scan fast — inactive rows are excluded.
CREATE INDEX idx_interviewer_availability_active
  ON interviewer_availability (interviewer_id, day_of_week)
  WHERE is_active = TRUE;

COMMIT;

-- Rollback:
--   BEGIN;
--   DROP TABLE interviewer_availability;
--   COMMIT;
--
--   Safe to drop before any Workflow D daily generator run.
--   After the generator has run: slot rows with generation_source='generator' will exist
--   but have no FK back to this table (no physical link), so the DROP itself is clean.
--   Ensure the Workflow D daily Cron is disabled before dropping to prevent a failed run.
