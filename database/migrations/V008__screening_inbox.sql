-- V008__screening_inbox.sql
-- Purpose: inbox table for Workflow B (white-collar screening) FIFO processing.
--   Workflow A writes a row on the workflow_reply intent path; Workflow B polls
--   on a 60s Cron, claims one unclaimed row with FOR UPDATE SKIP LOCKED, and
--   processes it. Prevents double-processing via the partial unique index and
--   the claim-then-process pattern.
-- Author: workflow-builder
-- Date: 2026-05-01
-- Spec: docs/02-workflows/b-white-collar-design-v1.md §2 (trigger/entry shape)

BEGIN;

CREATE TABLE screening_inbox (
  id             BIGSERIAL    PRIMARY KEY,
  candidate_id   TEXT         NOT NULL,   -- Twenty Candidate UUID (text; no FK to Twenty)
  application_id TEXT,                    -- Twenty Application UUID; NULL for v1 (A doesn't create Applications yet)
  trigger_kind   TEXT         NOT NULL CHECK (trigger_kind IN ('new_application')),
  payload        JSONB,                   -- optional context snapshot at insert time
  claimed_by     TEXT,                    -- n8n execution ID that claimed this row
  claimed_at     TIMESTAMPTZ,             -- NULL = unclaimed; set by Workflow B on claim
  processed_at   TIMESTAMPTZ,             -- NULL = not yet done; set by B on success or failure
  error_message  TEXT,                    -- last error if processing failed
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- FIFO poll index: the Workflow B SELECT ... WHERE claimed_at IS NULL ORDER BY created_at
CREATE INDEX idx_screening_inbox_unclaimed
  ON screening_inbox (created_at)
  WHERE claimed_at IS NULL;

-- Prevent double-enqueue: one active (unprocessed) row per candidate at a time.
-- Workflow A uses ON CONFLICT ON CONSTRAINT to skip if a row is already pending.
CREATE UNIQUE INDEX uq_screening_inbox_candidate_active
  ON screening_inbox (candidate_id)
  WHERE processed_at IS NULL;

COMMIT;

-- Rollback:
--   DROP TABLE screening_inbox;
--   (no downstream FK dependencies in v1)
