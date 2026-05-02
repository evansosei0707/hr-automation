-- V011__screening_inbox_trigger_kinds.sql
-- Purpose: extend the CHECK constraint on screening_inbox.trigger_kind to include the
--   two new values required by Workflow C (blue_collar_new, blue_collar_reply) and the
--   design-intent value open_conversation used by Workflow A's open_conversation branch.
--
--   The existing inline constraint in V008 is unnamed (Postgres assigns a system-generated
--   name at CREATE TABLE time; the generated name is deterministic per the column position
--   but is not guaranteed across Postgres versions or restore paths). The safe approach is
--   to DROP the constraint by its standard generated name (screening_inbox_trigger_kind_check,
--   which Postgres generates from <table>_<col>_check) using DROP CONSTRAINT IF EXISTS, then
--   re-add it with the same system-generated name and the expanded value list. Using IF EXISTS
--   means this migration is safe to re-run on a schema where the old constraint was already
--   manually altered.
--
-- Author: schema-designer
-- Date: 2026-05-02
-- Spec: docs/02-workflows/c-blue-collar-design-v1.md §3
--       docs/05-decisions/ADR-0011-blue-collar-state-and-trigger.md

BEGIN;

ALTER TABLE screening_inbox
  DROP CONSTRAINT IF EXISTS screening_inbox_trigger_kind_check;

ALTER TABLE screening_inbox
  ADD CONSTRAINT screening_inbox_trigger_kind_check
    CHECK (trigger_kind IN (
      'new_application',
      'open_conversation',
      'blue_collar_new',
      'blue_collar_reply'
    ));

COMMIT;

-- Rollback:
--   BEGIN;
--   ALTER TABLE screening_inbox
--     DROP CONSTRAINT IF EXISTS screening_inbox_trigger_kind_check;
--   ALTER TABLE screening_inbox
--     ADD CONSTRAINT screening_inbox_trigger_kind_check
--       CHECK (trigger_kind IN ('new_application'));
--   COMMIT;
--
--   Note: if any rows with trigger_kind IN ('open_conversation','blue_collar_new','blue_collar_reply')
--   already exist, adding the narrower constraint will fail with a CHECK violation.
--   Purge or reclassify those rows first before rolling back.
