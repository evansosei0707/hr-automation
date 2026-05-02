-- V014__slot_extensions.sql
-- Purpose: extend the slot table to support the hybrid slot generator (ADR-0012)
--   and the reschedule fresh-cycle path.
--
--   (1) generation_source — marks how a slot row was created:
--       'manual'    : inserted directly by the Operations Lead (legacy / one-off overrides)
--       'generator' : materialised by Workflow D's daily 05:00 Cron from interviewer_availability
--       'reschedule': fresh slot created for a candidate reschedule cycle (the old slot's
--                     status is set to 'cancelled'; this new slot links back via reschedule_of_slot_id)
--       Existing rows receive the DEFAULT 'manual', which is the correct classification for
--       all rows created before the daily generator existed.
--
--   (2) generated_at — timestamp when the daily generator created this row. NULL for
--       manually-inserted slots. Useful for diagnosing stale inventory (T2-D-5).
--
--   (3) reschedule_of_slot_id — self-referential FK linking a reschedule slot back to
--       the original claimed slot. NULL on first-offer rows. Set only on rows with
--       generation_source='reschedule'. ON DELETE SET NULL so that if the original slot
--       row is ever soft-deleted (status=cancelled is the norm; physical DELETE is rare
--       but possible in ops cleanup), the reschedule row does not become an orphan.
--
--   (4) idx_slot_available — partial index on (interviewer_id, starts_at) WHERE
--       status='available'. Used by the offer-path query "find next 3 available slots
--       for this interviewer, ordered by starts_at". Also used by the generator's
--       idempotency check (ON CONFLICT DO NOTHING scans this index).
--
--       Note on the original design-note partial index predicate: the design note shows
--       `WHERE status = 'available' AND starts_at > NOW()`. Postgres rejects non-immutable
--       functions (NOW()) in partial index predicates with ERROR:
--       "functions in index predicate must be marked IMMUTABLE". The predicate is therefore
--       written as `WHERE status = 'available'` only. The query planner still uses this
--       index efficiently when the caller adds `AND starts_at > NOW() + INTERVAL '4 hours'`
--       as a run-time predicate — Postgres can range-scan the index over starts_at and apply
--       the time filter as a heap re-check.
--
-- Author: schema-designer
-- Date: 2026-05-02
-- Spec: docs/02-workflows/d-scheduling-design-v1.md §2 (V014), §3 (generator idempotency)
--       docs/05-decisions/ADR-0012-slot-sourcing-hybrid.md

BEGIN;

ALTER TABLE slot
  ADD COLUMN generation_source TEXT NOT NULL DEFAULT 'manual'
    CHECK (generation_source IN ('manual', 'generator', 'reschedule')),
  ADD COLUMN generated_at TIMESTAMPTZ,
  ADD COLUMN reschedule_of_slot_id UUID
    CONSTRAINT fk_slot_reschedule_of_slot
    REFERENCES slot(id) ON DELETE SET NULL;

-- Offer-path index: find the next N available slots for an interviewer quickly.
-- Partial index on status='available' keeps the index small and the scan tight.
-- The NOW() comparison is applied as a run-time predicate against the index range —
-- Postgres does not need it in the predicate to use the index selectively.
CREATE INDEX idx_slot_available
  ON slot (interviewer_id, starts_at)
  WHERE status = 'available';

COMMIT;

-- Rollback:
--   BEGIN;
--   DROP INDEX idx_slot_available;
--   ALTER TABLE slot
--     DROP COLUMN reschedule_of_slot_id,
--     DROP COLUMN generated_at,
--     DROP COLUMN generation_source;
--   COMMIT;
--
--   The DROP COLUMN on generation_source will succeed regardless of existing values
--   (column has no downstream FK references). If Workflow D has been running and has
--   set generation_source='generator' on rows, those values are simply lost on rollback.
--   Ensure Workflow D is disabled before rolling back.
