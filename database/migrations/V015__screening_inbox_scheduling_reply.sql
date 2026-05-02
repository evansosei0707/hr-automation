-- V015__screening_inbox_scheduling_reply.sql
-- Purpose: extend the CHECK constraint on screening_inbox.trigger_kind to include
--   'scheduling_reply', required by Workflow D's claim path (60s Cron context).
--   When a candidate replies to a slot offer, Workflow A detects an active offered
--   slot for that candidate's application and writes trigger_kind='scheduling_reply'
--   into screening_inbox. Workflow D's claim Cron polls for this value.
--
--   This uses the same DROP CONSTRAINT IF EXISTS / ADD CONSTRAINT pattern established
--   by V011 (which extended the constraint from ('new_application') to include
--   'open_conversation', 'blue_collar_new', 'blue_collar_reply').
--   V011 is cited as prior art and must have been applied before this migration runs.
--
--   Retained values (from V011):
--     'new_application'   — written by Workflow A (white-collar new application)
--     'open_conversation' — written by Workflow A (open conversation intent)
--     'blue_collar_new'   — written by Workflow A or Workflow C's 5-min poll
--     'blue_collar_reply' — written by Workflow A (active blue-collar session reply)
--   New value:
--     'scheduling_reply'  — written by Workflow A (reply against an active slot offer);
--                           consumed by Workflow D's 60s claim Cron
--
-- Author: schema-designer
-- Date: 2026-05-02
-- Spec: docs/02-workflows/d-scheduling-design-v1.md §5 (trigger_kind values), §2 (V015)
--       Prior art: V011__screening_inbox_trigger_kinds.sql

BEGIN;

ALTER TABLE screening_inbox
  DROP CONSTRAINT IF EXISTS screening_inbox_trigger_kind_check;

ALTER TABLE screening_inbox
  ADD CONSTRAINT screening_inbox_trigger_kind_check
    CHECK (trigger_kind IN (
      'new_application',
      'open_conversation',
      'blue_collar_new',
      'blue_collar_reply',
      'scheduling_reply'
    ));

COMMIT;

-- Rollback:
--   BEGIN;
--   ALTER TABLE screening_inbox
--     DROP CONSTRAINT IF EXISTS screening_inbox_trigger_kind_check;
--   ALTER TABLE screening_inbox
--     ADD CONSTRAINT screening_inbox_trigger_kind_check
--       CHECK (trigger_kind IN (
--         'new_application',
--         'open_conversation',
--         'blue_collar_new',
--         'blue_collar_reply'
--       ));
--   COMMIT;
--
--   Note: if any rows with trigger_kind='scheduling_reply' already exist, adding
--   the narrower constraint will fail with a CHECK violation.
--   Delete or reclassify those rows first before rolling back.
--   Workflow A's routing branch for scheduling_reply must also be reverted to avoid
--   writing invalid trigger_kind values after the constraint is narrowed.
