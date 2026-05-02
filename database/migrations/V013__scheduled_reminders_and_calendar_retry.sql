-- V013__scheduled_reminders_and_calendar_retry.sql
-- Purpose: two runtime-support tables for Workflow D's claim path.
--
--   (a) scheduled_reminders — holds 24h and 2h pre-interview reminder jobs.
--       Workflow D inserts two rows per confirmed booking (kind='interview_24h'
--       and kind='interview_2h', with fire_at computed from slot.starts_at).
--       Workflow G's reminder sweep polls this table every hour, fires the
--       WhatsApp template send, and marks sent_at or failed_at accordingly.
--       The unique index prevents double-scheduling for the same interview+kind pair.
--
--   (b) calendar_sync_retry — holds pending Google Calendar event-create retries.
--       When Calendar fails after a slot is claimed, Workflow D inserts one row
--       here with the full intended event body. Workflow G's hourly retry sweep
--       increments attempts, retries the Calendar call, and on success updates
--       Twenty via GraphQL and closes the ReviewTask. After 3 attempts, the row
--       is abandoned (abandoned_at set) and the ReviewTask is left open for the
--       Operations Lead.
--
-- These two tables ship together: both are required before the first slot can be
-- claimed (D writes scheduled_reminders rows on the claim path; a Calendar failure
-- on the same path writes calendar_sync_retry).
--
-- Author: schema-designer
-- Date: 2026-05-02
-- Spec: docs/02-workflows/d-scheduling-design-v1.md §2 (V013), §4 (claim path),
--       §9.2 (Calendar failure recovery)

BEGIN;

-- ─────────────────────────────────────────────
-- scheduled_reminders
-- ─────────────────────────────────────────────
CREATE TABLE scheduled_reminders (
  id                  BIGSERIAL    PRIMARY KEY,
  kind                TEXT         NOT NULL
                        CHECK (kind IN ('interview_24h', 'interview_2h')),
  fire_at             TIMESTAMPTZ  NOT NULL,
  twenty_interview_id TEXT         NOT NULL,   -- Twenty Interview UUID (no FK — cross-DB)
  candidate_id        TEXT         NOT NULL,   -- Twenty Candidate UUID (no FK — cross-DB)
  application_id      TEXT         NOT NULL,   -- Twenty Application UUID (no FK — cross-DB)
  payload             JSONB        NOT NULL,   -- pre-rendered template variables for wa-send subflow
  sent_at             TIMESTAMPTZ,             -- NULL = not yet sent
  failed_at           TIMESTAMPTZ,             -- NULL = not failed
  failure_reason      TEXT,
  created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Workflow G's reminder sweep: find pending reminders due to fire.
-- Partial index on fire_at covering only rows not yet sent and not failed.
CREATE INDEX idx_scheduled_reminders_due
  ON scheduled_reminders (fire_at)
  WHERE sent_at IS NULL AND failed_at IS NULL;

-- Prevent double-scheduling: at most one row per interview + reminder kind.
-- If Workflow D's claim path runs twice (e.g. idempotent retry after a
-- downstream failure), the second INSERT should be skipped via ON CONFLICT.
CREATE UNIQUE INDEX uq_scheduled_reminders_unique
  ON scheduled_reminders (twenty_interview_id, kind);

-- ─────────────────────────────────────────────
-- calendar_sync_retry
-- ─────────────────────────────────────────────
CREATE TABLE calendar_sync_retry (
  id                  BIGSERIAL    PRIMARY KEY,
  slot_id             UUID         NOT NULL
                        CONSTRAINT fk_calendar_sync_retry_slot
                        REFERENCES slot(id) ON DELETE CASCADE,
  twenty_interview_id TEXT         NOT NULL,   -- Twenty Interview UUID (no FK — cross-DB)
  intended_event      JSONB        NOT NULL,   -- full POST body from the failed Calendar API call
  attempts            INT          NOT NULL DEFAULT 0,
  last_attempt_at     TIMESTAMPTZ,             -- NULL = never attempted since insert
  last_error          TEXT,
  succeeded_at        TIMESTAMPTZ,             -- NULL = not yet succeeded
  abandoned_at        TIMESTAMPTZ,             -- set when attempts >= 3; NULL = still retrying
  review_task_id      TEXT,                    -- Twenty ReviewTask UUID; set after ReviewTask created
  created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Workflow G's hourly retry sweep: find pending Calendar retries ordered by
-- last_attempt_at NULLS FIRST (never-attempted rows come first).
-- Partial index covers only rows that have not yet succeeded or been abandoned.
CREATE INDEX idx_calendar_sync_retry_pending
  ON calendar_sync_retry (last_attempt_at NULLS FIRST)
  WHERE succeeded_at IS NULL AND abandoned_at IS NULL;

COMMIT;

-- Rollback:
--   BEGIN;
--   DROP TABLE calendar_sync_retry;
--   DROP TABLE scheduled_reminders;
--   COMMIT;
--
--   calendar_sync_retry has a FK to slot; drop it first.
--   Safe to drop if Workflow D and Workflow G are disabled first.
--   Any in-flight reminder jobs or pending Calendar retries will be lost.
