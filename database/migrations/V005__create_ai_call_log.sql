-- V005__create_ai_call_log.sql
-- Purpose: per-call cost + token-usage log for Anthropic Messages API calls.
--          Created during Phase 4 Anthropic voucher; the wrapper described in
--          docs/03-integrations/claude-api.md ("Cost controls" section) will
--          write here from every Claude call. Workflow G aggregates daily for
--          budget warnings ($5 warn, $10 gate).
-- Author: scaffold (Phase 4 voucher)
-- Date: 2026-04-27
-- Spec: docs/03-integrations/claude-api.md

BEGIN;

CREATE TABLE ai_call_log (
  id              BIGSERIAL PRIMARY KEY,
  ts              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  workflow_name   TEXT NOT NULL,
  model           TEXT NOT NULL,
  input_tokens    INT,
  output_tokens   INT,
  cost_usd        NUMERIC(10, 6),
  prompt_excerpt  TEXT  -- first 200 chars only; redaction-safe.
                        -- Never store full prompt content here — PII +
                        -- candidate data exposure risk. The full prompt
                        -- lives in the n8n execution log (private) if at all.
);

CREATE INDEX idx_ai_call_log_ts ON ai_call_log (ts DESC);
CREATE INDEX idx_ai_call_log_workflow ON ai_call_log (workflow_name, ts DESC);

INSERT INTO schema_migrations (version) VALUES ('V005__create_ai_call_log');

COMMIT;

-- Rollback:
--   DROP TABLE IF EXISTS ai_call_log CASCADE;
--   DELETE FROM schema_migrations WHERE version = 'V005__create_ai_call_log';
