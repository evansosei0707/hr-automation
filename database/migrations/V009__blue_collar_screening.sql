-- V009__blue_collar_screening.sql
-- Purpose: per-candidate conversation state for Workflow C's structured Q&A screening.
--   One row per active (or completed / withdrawn) screening session. Workflow C updates
--   this row in place on each candidate reply — advancing question_index, accumulating
--   answers, and finally writing final_score + strength_tier when all questions are done.
--   Keeps multi-step conversation state out of candidate_facts (Workflow B's domain).
--   The 30-minute reminder/withdraw sweep reads this table via the status+activity index.
-- Author: schema-designer
-- Date: 2026-05-02
-- Spec: docs/02-workflows/c-blue-collar-design-v1.md §2, §4
--       docs/05-decisions/ADR-0011-blue-collar-state-and-trigger.md

BEGIN;

CREATE TABLE blue_collar_screening (
  id                    BIGSERIAL    PRIMARY KEY,
  candidate_id          TEXT         NOT NULL,   -- Twenty Candidate UUID (no FK — cross-DB)
  application_id        TEXT         NOT NULL,   -- Twenty Application UUID (no FK — cross-DB)
  twenty_job_posting_id TEXT         NOT NULL,   -- Twenty JobPosting UUID (no FK — cross-DB)
  -- script_id references screening_scripts.script_id (V010).
  -- Physical FK omitted: screening_scripts is created in V010; restore order is not guaranteed.
  -- Workflow C must validate that script_id exists before INSERT.
  script_id             TEXT         NOT NULL,
  question_index        INT          NOT NULL DEFAULT 0,
  answers               JSONB        NOT NULL DEFAULT '{}',
  started_at            TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  last_activity_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  reminder_sent_at      TIMESTAMPTZ,             -- NULL = no reminder sent yet
  status                TEXT         NOT NULL DEFAULT 'in_progress'
                          CHECK (status IN ('in_progress', 'completed', 'withdrawn', 'error')),
  final_score           NUMERIC(5,2),            -- NULL until status = 'completed'
  strength_tier         TEXT,                    -- NULL until completed; top20|solid|developing|not_a_fit
  created_at            TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- One active session per candidate at a time.
-- Prevents double-initialisation when Workflow A and the Five-minute Twenty poll both fire
-- for the same candidate within one polling cycle.
CREATE UNIQUE INDEX uq_blue_collar_screening_active_candidate
  ON blue_collar_screening (candidate_id)
  WHERE status = 'in_progress';

-- Poll index for the 24h reminder sweep and 72h auto-withdraw sweep (Cron every 30 min).
-- Covers: WHERE status='in_progress' AND last_activity_at < NOW() - INTERVAL '...'
CREATE INDEX idx_blue_collar_screening_active_activity
  ON blue_collar_screening (last_activity_at)
  WHERE status = 'in_progress';

-- One screening session per Application. Prevents double-enqueue from the Twenty poll path.
-- The five-minute poll cross-references application_id against this index before inserting
-- a new screening_inbox row.
CREATE UNIQUE INDEX uq_blue_collar_screening_application
  ON blue_collar_screening (application_id);

-- Composite index for the sweep Cron: scan in-progress rows ordered by last_activity_at.
-- Covers both the 30-min reminder sweep and the 72h withdraw sweep efficiently.
CREATE INDEX idx_blue_collar_screening_status
  ON blue_collar_screening (status, last_activity_at);

COMMIT;

-- Rollback:
--   DROP TABLE blue_collar_screening;
--   No downstream FK constraints in v1 — table can be dropped cleanly.
--   Ensure Workflow C is disabled before dropping; active executions may hold references.
