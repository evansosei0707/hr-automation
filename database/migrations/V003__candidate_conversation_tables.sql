-- V003__candidate_conversation_tables.sql
-- Purpose: conversation transcript storage, rolling summary, and candidate
--          facts read-cache for Workflow A.
-- Author: schema-designer
-- Date: 2026-04-29
-- Spec: docs/01-data-model/ai-memory.md, docs/02-workflows/a-communications.md

BEGIN;

CREATE TABLE candidate_facts (
  twenty_candidate_id  TEXT        PRIMARY KEY,
  facts                JSONB       NOT NULL DEFAULT '{}',
  voice_note_retry_at  TIMESTAMPTZ,
  scheduled_purge_at   TIMESTAMPTZ,
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- twenty_candidate_id: Twenty GraphQL UUID as TEXT. No FK — cross-DB boundary.
-- facts: freeform JSONB read-cache (conversation state, opt-outs, etc.).
-- voice_note_retry_at: set on first low-quality voice note; cleared on HIGH.
-- scheduled_purge_at: set when consentStatus=REFUSED; Workflow G sweeps this.

CREATE TABLE conversation (
  id                       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  twenty_candidate_id      TEXT        NOT NULL UNIQUE,
  summary                  TEXT        NOT NULL DEFAULT '',
  summary_updated_at       TIMESTAMPTZ,
  window_start_message_id  BIGINT,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- UNIQUE on twenty_candidate_id: one conversation record per candidate.
-- summary: rolling Claude-Haiku narrative; starts empty.
-- window_start_message_id: BIGSERIAL id of earliest message in recent window.

CREATE TABLE conversation_message (
  id                   BIGSERIAL   PRIMARY KEY,
  conversation_id      UUID        NOT NULL REFERENCES conversation(id) ON DELETE RESTRICT,
  direction            TEXT        NOT NULL CHECK (direction IN ('inbound','outbound')),
  body                 TEXT        NOT NULL,
  wa_message_id        TEXT        UNIQUE,        -- NULL for outbound
  media_type           TEXT,
  media_url            TEXT,
  transcript           TEXT,                      -- Groq Whisper output
  transcript_quality   TEXT        CHECK (transcript_quality IN ('high','low','unavailable')),
  occurred_at          TIMESTAMPTZ NOT NULL
);

CREATE INDEX idx_conversation_message_window
  ON conversation_message (conversation_id, occurred_at DESC);
-- conversation_id equality + occurred_at range scan descending.
-- Serves "fetch last N turns" in O(log n).

COMMIT;

-- Rollback:
--   DROP TABLE conversation_message;   -- FK must go first
--   DROP TABLE conversation;
--   DROP TABLE candidate_facts;
--   (order matters: FK from conversation_message -> conversation)
