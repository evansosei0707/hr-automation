-- V001__create_bookings_core.sql
-- Purpose: core tables for the n8n-owned bookings DB.
--          Implements the schema described in docs/01-data-model/bookings-db.md.
-- Author: scaffold
-- Date: 2026-04-24
-- Spec: docs/01-data-model/bookings-db.md

BEGIN;

-- ─────────────────────────────────────────────
-- interviewer
-- ─────────────────────────────────────────────
CREATE TABLE interviewer (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  twenty_user_id TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  timezone TEXT NOT NULL DEFAULT 'Africa/Accra',
  google_calendar_id TEXT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_interviewer_active ON interviewer (is_active) WHERE is_active = TRUE;

-- ─────────────────────────────────────────────
-- slot
-- ─────────────────────────────────────────────
CREATE TABLE slot (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  interviewer_id UUID NOT NULL REFERENCES interviewer(id) ON DELETE RESTRICT,
  starts_at TIMESTAMPTZ NOT NULL,
  ends_at TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('available','offered','claimed','cancelled','completed')),
  offered_to_application_id TEXT,
  offered_at TIMESTAMPTZ,
  offer_expires_at TIMESTAMPTZ,
  claimed_by_application_id TEXT,
  claimed_at TIMESTAMPTZ,
  twenty_interview_id TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT slot_times_valid CHECK (ends_at > starts_at)
);

-- The teeth: at most one offered-or-claimed slot per interviewer-time pair
CREATE UNIQUE INDEX uq_slot_no_double_claim
  ON slot (interviewer_id, starts_at)
  WHERE status IN ('offered','claimed');

CREATE INDEX idx_slot_lookup ON slot (status, starts_at);
CREATE INDEX idx_slot_offer_expiry ON slot (offer_expires_at) WHERE status = 'offered';

-- ─────────────────────────────────────────────
-- booking_event_log
-- ─────────────────────────────────────────────
CREATE TABLE booking_event_log (
  id BIGSERIAL PRIMARY KEY,
  slot_id UUID NOT NULL REFERENCES slot(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL,
  actor TEXT NOT NULL,
  payload JSONB,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_booking_event_slot ON booking_event_log (slot_id, occurred_at DESC);

-- ─────────────────────────────────────────────
-- workflow_errors (shared across all n8n workflows)
-- ─────────────────────────────────────────────
CREATE TABLE workflow_errors (
  id BIGSERIAL PRIMARY KEY,
  workflow_name TEXT NOT NULL,
  execution_id TEXT NOT NULL,
  node_name TEXT,
  error_message TEXT NOT NULL,
  error_stack TEXT,
  context JSONB,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  acknowledged_at TIMESTAMPTZ
);

CREATE INDEX idx_workflow_errors_unack ON workflow_errors (occurred_at) WHERE acknowledged_at IS NULL;
CREATE INDEX idx_workflow_errors_by_workflow ON workflow_errors (workflow_name, occurred_at DESC);

-- ─────────────────────────────────────────────
-- system_incident (from orchestration workflow)
-- ─────────────────────────────────────────────
CREATE TABLE system_incident (
  id BIGSERIAL PRIMARY KEY,
  kind TEXT NOT NULL,
  severity TEXT NOT NULL CHECK (severity IN ('info','warning','critical')),
  summary TEXT NOT NULL,
  details JSONB,
  opened_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ
);

CREATE INDEX idx_system_incident_open ON system_incident (opened_at DESC) WHERE resolved_at IS NULL;

-- ─────────────────────────────────────────────
-- event_log (structured observability log)
-- ─────────────────────────────────────────────
CREATE TABLE event_log (
  id BIGSERIAL PRIMARY KEY,
  ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  workflow_name TEXT NOT NULL,
  execution_id TEXT,
  candidate_id TEXT,
  application_id TEXT,
  level TEXT NOT NULL CHECK (level IN ('debug','info','warn','error')),
  event TEXT NOT NULL,
  message TEXT,
  data JSONB
);

CREATE INDEX idx_event_log_ts ON event_log (ts DESC);
CREATE INDEX idx_event_log_candidate ON event_log (candidate_id, ts DESC) WHERE candidate_id IS NOT NULL;
CREATE INDEX idx_event_log_workflow ON event_log (workflow_name, ts DESC);

-- ─────────────────────────────────────────────
-- Record migration
-- ─────────────────────────────────────────────
INSERT INTO schema_migrations (version) VALUES ('V001__create_bookings_core');

COMMIT;

-- Rollback:
--   DROP TABLE IF EXISTS event_log, system_incident, workflow_errors,
--                        booking_event_log, slot, interviewer CASCADE;
--   DELETE FROM schema_migrations WHERE version = 'V001__create_bookings_core';
