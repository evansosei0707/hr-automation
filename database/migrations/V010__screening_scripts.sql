-- V010__screening_scripts.sql
-- Purpose: stores structured question definitions (scripts) per job category for
--   Workflow C's blue-collar screening. Scripts change rarely (monthly at most);
--   keeping them in the bookings DB allows prompt and scoring updates without a
--   full workflow redeploy. Each row is a versioned, per-category script; exactly
--   one row per category may be active at a time (enforced by partial unique index).
-- Author: schema-designer
-- Date: 2026-05-02
-- Spec: docs/02-workflows/c-blue-collar-design-v1.md §2, §4
--       docs/05-decisions/ADR-0011-blue-collar-state-and-trigger.md (Q4 decision)

BEGIN;

CREATE TABLE screening_scripts (
  script_id            TEXT         PRIMARY KEY,  -- e.g. 'driver_v1', 'warehouse_v1'
  job_category         TEXT         NOT NULL,     -- e.g. 'driver', 'warehouse', 'security'
  version              INT          NOT NULL DEFAULT 1,
  questions            JSONB        NOT NULL,     -- array of question objects (schema below)
  shortlist_threshold  NUMERIC(5,2) NOT NULL DEFAULT 60.00,  -- score >= this → shortlisted
  is_active            BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Only one active script per job category at a time.
-- To hot-swap a script: set is_active=FALSE on the old row, INSERT the new row (active=TRUE).
-- This index enforces the invariant at the DB level.
CREATE UNIQUE INDEX uq_screening_scripts_active_category
  ON screening_scripts (job_category)
  WHERE is_active = TRUE;

COMMIT;

-- questions JSONB schema (array of question objects):
-- [
--   {
--     "id":            "own_transport",      -- unique key within script; keyed in answers JSONB
--     "prompt":        "Do you own a motorbike...",
--     "type":          "yes_no",             -- yes_no | number | enum | free_text
--     "weight":        0.30,                 -- informational; scoring drives actual points
--     "scoring":       { "yes": 30, "no": 0 },
--                                            -- for type=free_text presence_only: "presence_only"
--     "enum_values":   null,                 -- array of valid string values; type=enum only
--     "tiered_scoring": null                 -- type=number only; array of { max, points }
--                                            -- max=null means unbounded upper (last tier)
--   },
--   ...
-- ]

-- ---------------------------------------------------------------------------
-- Seed data: delivery driver script v1 (driver_v1)
-- Inserted outside the transaction so it can be re-run independently (idempotent).
-- ---------------------------------------------------------------------------

INSERT INTO screening_scripts (
  script_id,
  job_category,
  version,
  questions,
  shortlist_threshold,
  is_active
) VALUES (
  'driver_v1',
  'driver',
  1,
  '[
    {
      "id": "location",
      "prompt": "Which city are you currently living in?",
      "type": "free_text",
      "weight": 0.05,
      "scoring": "presence_only",
      "enum_values": null,
      "tiered_scoring": null
    },
    {
      "id": "own_transport",
      "prompt": "Do you own a motorbike or can you use one reliably? (YES / NO)",
      "type": "yes_no",
      "weight": 0.30,
      "scoring": {"yes": 30, "no": 0},
      "enum_values": null,
      "tiered_scoring": null
    },
    {
      "id": "driving_experience_years",
      "prompt": "How many years of delivery driving have you done?",
      "type": "number",
      "weight": 0.25,
      "scoring": null,
      "enum_values": null,
      "tiered_scoring": [
        {"max": 1,    "points": 5},
        {"max": 3,    "points": 15},
        {"max": null, "points": 25}
      ]
    },
    {
      "id": "license_class",
      "prompt": "Which driving license do you have? (A, B, C, D, E, none)",
      "type": "enum",
      "weight": 0.20,
      "scoring": {"a": 20, "b": 20, "c": 15, "d": 10, "e": 10, "none": 0},
      "enum_values": ["A", "B", "C", "D", "E", "none"],
      "tiered_scoring": null
    },
    {
      "id": "available_from",
      "prompt": "When can you start if selected? (today / this week / this month / next month)",
      "type": "enum",
      "weight": 0.10,
      "scoring": {"today": 10, "this_week": 10, "this_month": 7, "next_month": 4},
      "enum_values": ["today", "this_week", "this_month", "next_month"],
      "tiered_scoring": null
    },
    {
      "id": "references",
      "prompt": "Can you share one reference (name and phone number) from a previous delivery job?",
      "type": "free_text",
      "weight": 0.10,
      "scoring": "presence_only",
      "enum_values": null,
      "tiered_scoring": null
    }
  ]'::JSONB,
  60.00,
  TRUE
)
ON CONFLICT (script_id) DO NOTHING;

-- Rollback:
--   DROP TABLE screening_scripts;
--   (Data loss — keep the seed INSERT above ready to re-run after recreation.)
--   Ensure Workflow C is disabled first; it fetches scripts at runtime.
--   blue_collar_screening.script_id references this table by convention (no physical FK);
--   existing blue_collar_screening rows will have a dangling script_id reference after drop.
