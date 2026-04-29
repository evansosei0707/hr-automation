# Workflow A — Communications Design Note v1

**Status:** Draft — awaiting human approval before schema-designer / workflow-builder dispatch
**Date:** 2026-04-29
**Author:** architect subagent + Claude Code
**Spec base:** `docs/02-workflows/a-communications.md`

This note resolves the four open questions from the Week-0 go/no-go review and fills in
the implementation detail the spec deliberately deferred. Read the spec first; this extends
it, not replaces it.

Four design-question answers baked in:
- **Q1** V003 scope = `candidate_facts` + `conversation` + `conversation_message`. `retry_queue` → V006 (Workflow G).
- **Q2** `consent_refusal_ack` is free-form (service window open; no template needed).
- **Q3** Retry max-attempts = 3; third failure → ReviewTask, no fourth retry.
- **Q4** Distress holding reply is free-form (human-sounding response warranted).

---

## 1. Node graph

The Phase-4 webhook handler (`a0-whatsapp-webhook-handler.json`) already owns the dual
GET/POST webhook, HMAC validation, and the fast 200-ack. Workflow A **extends** that file;
the design below starts from the node immediately after HMAC validation passes on the POST
branch.

```
[POST branch — after HMAC validation]
         |
         v
[Code: Normalise phone]          -- strip spaces/dashes; E.164 +233...
         |
         v
[Redis: Dedupe check]            -- SETNX hra:dedupe:{wa_message_id} 1 EX 86400
    |           |
  HIT         MISS
    |           |
[Postgres:  [Postgres: Candidate lookup]   -- candidates(filter:{whatsappNumberE164:{eq:$phone}})
 log dup +       |
 exit 200]   [If: count = 0 / 1 / >1]
              |         |          |
           ZERO        ONE       MANY
              |         |          |
    [HTTP Req:       [set var:   [Twenty GraphQL:
     createCandidate] candidateId] createOneReviewTask
     consentStatus=     |         kind=COMPLIANCE_FLAG]
     PENDING]           |              |
              |         |          [Postgres: log +
    [merge ←--+----←----+          workflow_errors]
         |                              |
         |                         [exit — no reply]
         v
[Redis: Conv-lock acquire]       -- SET hra:conv:{candidateId} {execId}:{uuid} NX PX 60000
    |              |
  FAIL           ACQUIRED
    |              |
[Postgres:    [Subflow: conv-lock-heartbeat]   -- Lua PEXPIRE-CAS every 15s
 write retry       |
 hint to           v
 event_log +  [If: Candidate.consentStatus]
 exit 200]         |
              PENDING | REFUSED/REVOKED | GRANTED
                  |           |               |
           [Send template: [log + exit]   [continue →]
            consent_request]
           [Postgres: log outbound]
           [Redis: release lock]
           [exit 200]


─── GRANTED branch continues ──────────────────────────────────────────────────

[If: message.type = audio]
    |               |
  AUDIO           TEXT
    |               |
[HTTP Req:        [skip transcription]
 Groq Whisper
 /transcriptions]
    |
[Code: confidence gate]          -- avg_logprob / no_speech_prob / compression_ratio
    |           |           |
  HIGH        LOW       UNAVAILABLE
  quality   quality    (silence/noise)
    |           |           |
[continue]  [If: was       [If: was
             retry?]        local lang?]
              |   |            |       |
            YES  NO          YES      NO
              |   |            |       |
        [send:  [send:   [Twenty:   [send:
         please  please  ReviewTask  please
         retype] retype] kind=       retype]
         exit]   exit]   MANUAL_    exit]
                         REVIEW]
                         exit]

─── TEXT (or transcribed audio with HIGH quality) continues ────────────────────

[Postgres: store inbound conversation_message]
         |
         v
[Postgres: fetch last 20 conversation_message rows]
         |
         v
[HTTP Req: Claude Haiku — intent classification]   -- 5-way JSON response
         |
[Code: parse intent + confidence]
         |
    intent →  workflow_reply | dpa_request | open_conversation | distress | spam
         |            |              |              |               |
   [Subflow:   [Subflow:      [HTTP Req:      [send:         [log +
    workflow    dpa-handler]   Claude Sonnet   distress       exit 200]
    dispatch]       |          reply]          hold reply]
         |      [release       |               |
     (Workflow   lock]     [Postgres:      [Twenty:
      B/C/D               store outbound  ReviewTask
      handoff)]           conv_message]   COMPLIANCE_FLAG
                          |               dueBy=NOW()+1h]
                      [Subflow:           |
                       wa-send]       [release lock]
                          |           [exit 200]
                      [Postgres:
                       ai_call_log]
                          |
                      [Redis: release lock]
                      [exit 200]


─── Error Trigger (top-level, any node failure) ────────────────────────────────

[Error Trigger]
    |
[Redis: release lock if held]    -- Lua CAS DEL; no-op if not held or already expired
    |
[Postgres: write workflow_errors]
    |
[If: attempt_number < 3]
    YES → [Postgres: log retry; exit — Workflow G re-dispatches]
    NO  → [Twenty: ReviewTask kind=WORKFLOW_ERROR dueBy=NOW()+4h]
          [exit]
```

**Subflows produced alongside `a-communications.json`:**
1. `conv-lock-heartbeat` — Lua PEXPIRE-CAS loop, fires every 15s while lock is held.
2. `wa-send` — enforces 24h service window; falls back to template on error 131047.
3. `claude-call` — model routing, budget gate, `ai_call_log` write.
4. `dpa-handler` — DATA/DELETE/ACCESS intent routing (hands off to Workflow H logic).

---

## 2. Dedupe

```
SET hra:dedupe:{wa_message_id} 1 NX EX 86400
```

- **TTL:** 86400 seconds (24 hours). WhatsApp deduplication guarantees 24h; we match it.
- **On HIT:** write one `event_log` row (`level=info, event=dedupe_hit`), return 200 to Meta, exit. No WhatsApp reply, no candidate processing.
- **Key:** `wa_message_id` is the `entry[0].changes[0].value.messages[0].id` field from Meta's payload — already extracted by the Phase-4 handler before this node.

---

## 3. Conv-lock acquire

```
SET hra:conv:{candidateId} {executionId}:{uuid4} NX PX 60000
```

- **TTL:** 60 000 ms (60 seconds), per CLAUDE.md invariant #3.
- **Token:** `{executionId}:{uuid4}` ensures global uniqueness across n8n instances.
- **Heartbeat:** subflow `conv-lock-heartbeat` invokes Lua PEXPIRE-CAS every 15 seconds while the workflow holds the lock. Refreshes to 60s each time. Stops after lock is released or subflow is terminated.
- **On FAIL (contention):** write `event_log` row (`event=lock_contention`), exit 200. Workflow G observes the event_log and re-dispatches after the TTL window. No retry Wait node in Workflow A — contention retries are Workflow G's responsibility.
- **Release:** Lua CAS DEL fires in BOTH success path AND error path (Error Trigger). The Error Trigger fires the DEL before writing `workflow_errors`.

---

## 4. Candidate resolution

**Query:**
```graphql
query FindCandidate($phone: String!) {
  candidates(filter: { whatsappNumberE164: { eq: $phone } }) {
    edges { node { id consentStatus firstName lastName } }
  }
}
```

Note: resolver name is `candidates`, not `candidatesOne`. Data-API resolvers have no `One` infix per ADR-0005.

| Result count | Action |
|---|---|
| 0 | `createCandidate` mutation: `whatsappNumberE164=$phone`, `consentStatus=PENDING`. Proceed with new candidate. |
| 1 | Extract `id`, continue. |
| >1 | Data-integrity error: create `ReviewTask(kind=COMPLIANCE_FLAG, subjectCandidate=first_result_id)`, write `workflow_errors`, release lock, exit 200. |

**Phone normalisation** (Code node before lookup): strip spaces and dashes, assert `+233` prefix, reject if length ≠ 13 characters. Invalid → `event_log(level=warn, event=invalid_phone)` + exit 200.

---

## 5. Consent state machine

| `consentStatus` | Inbound message | Action |
|---|---|---|
| `PENDING` | any | Send `consent_request` template; store outbound; release lock; exit. |
| `PENDING` | YES / I agree / Ok (case-insensitive) | Set `consentStatus=GRANTED`, `consentGrantedAt=NOW()`. Continue processing the message. |
| `PENDING` | NO / STOP / Don't / Refuse | Send free-form `consent_refusal_ack` (see §7). Set `consentStatus=REFUSED`. Set `dataRetentionPolicy=PENDING_DELETION`. Release lock. Exit. |
| `PENDING` | DATA / DELETE / ACCESS | Handle as DPA request before consent; send free-form acknowledgement; route to `dpa-handler` subflow. |
| `PENDING` | other | Resend `consent_request` template once. If still ambiguous: ReviewTask + exit. |
| `GRANTED` | any | Normal processing (continue to §6 voice/text routing). |
| `REFUSED` | any | Send free-form "you previously opted out" reply once. No further processing. |
| `REVOKED` | any | Same as REFUSED. |

**Template:** `consent_request`. Variable `{{1}}` = candidate `firstName`, or "there" if not yet known.

---

## 6. Voice note branch

**Routing trigger:** `message.type = "audio"` in Meta's payload.

**Step 1 — Language detection (10s audio cap):**
Submit first 10s to Groq `whisper-large-v3-turbo`. Inspect output language field.
- `language = en` or `language = null` (Pidgin often returns null) → proceed to full transcription.
- Any other language code → `ReviewTask(kind=MANUAL_REVIEW, subjectCandidate=id)` + send "please retype" reply + release lock + exit.

**Step 2 — Full transcription:**
Submit full audio (up to 25 MB / ~25 minutes per Groq limit).

**Step 3 — Confidence gate** (thresholds from `docs/03-integrations/groq-whisper.md`):

| Metric | HIGH quality | LOW quality | Notes |
|---|---|---|---|
| `avg_logprob` | ≥ −0.3 | < −0.3 | Per segment average |
| `no_speech_prob` | ≤ 0.5 | > 0.5 | |
| `compression_ratio` | 1.5–3.5 | outside range | Very low = silence; very high = repetition |

- **HIGH quality:** attach transcript to conversation_message, continue to intent.
- **LOW quality on first message:** send "please retype" reply. Set `voice_note_retry_at = NOW()` in candidate_facts.
- **LOW quality on retry (voice_note_retry_at is set):** ReviewTask + exit. Two strikes, route to human.
- **UNAVAILABLE (Groq error / empty):** same path as LOW quality on retry.

`transcript_quality` stored in `conversation_message`: `'high'`, `'low'`, or `'unavailable'`.

> ⚠️ **T2-6 PENDING:** The confidence thresholds above (`avg_logprob` ≥ −0.3, `no_speech_prob` ≤ 0.5, `compression_ratio` 1.5–3.5) are initial estimates from `docs/03-integrations/groq-whisper.md`. They have NOT been validated against real Ghanaian Pidgin audio. T2-6 (pre-launch catastrophic check) must run before Workflow A is promoted to production. If T2-6 reveals the thresholds are wrong, update this section and the n8n Code node before go-live.

---

## 7. Free-form message drafts (subject to Operations Lead review)

**`consent_refusal_ack`:**
> "No problem at all, [firstName]. We won't contact you again via WhatsApp. If you change your mind later, just send us a message and we'll start fresh."

**Distress holding reply:**
> "Hi [firstName], thank you for reaching out. We want to make sure you're okay. One of our team will be in touch with you shortly."

**"Please retype" (voice note, low quality):**
> "Hi [firstName], we couldn't quite make that out. Could you type your message instead? That'll help us get back to you faster."

All three fire as free-form n8n HTTP Request nodes via the `wa-send` subflow.

---

## 8. Claude call

**Intent classification (Haiku):**
- Input: last 5 conversation_message rows (body only) + new message body.
- System prompt: classify into `workflow_reply`, `dpa_request`, `open_conversation`, `distress`, `spam`. Return `{ "intent": "...", "confidence": 0.0–1.0 }`.
- Low confidence (< 0.7) on `workflow_reply`, `dpa_request`, or `distress` → escalate to human review.
- Low confidence on `open_conversation` or `spam` → default to `open_conversation`.

**Open reply (Sonnet):**
- Input: rolling summary from `conversation.summary` + last 10 conversation_message rows + new message.
- System prompt: HR assistant persona, Ghana-first, plain Ghanaian English, do not make hiring commitments, do not hallucinate job details.
- Response goes to `wa-send` subflow.

**Both calls go through `claude-call` subflow.** The subflow handles:
- Budget gate (skip if daily spend > $X threshold from `ai_call_log` sum).
- `ai_call_log` INSERT: `workflow_name`, `model` (NOT NULL per V005); also bind `execution_id`, `input_tokens`, `output_tokens`, `cost_usd` for tracing.

---

## 9. Error handling

**Error Trigger fires on any node failure.** Must bind all `workflow_errors` NOT NULL columns (rule #13):

| Column | Binding |
|---|---|
| `workflow_name` | `$workflow.name` |
| `execution_id` | `$json.execution.id` (Error Trigger context — failed execution, not current) |
| `error_message` | `$json.error.message` |
| `node_name` | `$json.error.node.name` |
| `error_stack` | `$json.error.stack` (nullable; bind anyway) |

> ⚠️ **n8n 1.85.0 quirk:** In the Error Trigger context, `execution_id` binding is `$json.execution.id` (the FAILED execution, surfaced by the Error Trigger) — NOT `$execution.id`, which returns the current execution. Workflow-builder must use the Error Trigger context path specifically. This distinction was the root cause of the `workflow_errors` NOT NULL constraint failure that produced rule #13.

**ReviewTask triggers from Workflow A:**

| Trigger | `kind` | `subjectCandidate` | `dueBy` |
|---|---|---|---|
| >1 candidate match | `COMPLIANCE_FLAG` | first result id | NOW() + 4h |
| Third retry failure | `WORKFLOW_ERROR` | candidateId | NOW() + 4h |
| Local-language voice note | `MANUAL_REVIEW` | candidateId | NOW() + 4h |
| Two-strike low-confidence audio | `MANUAL_REVIEW` | candidateId | NOW() + 4h |
| Low-confidence distress classification | `COMPLIANCE_FLAG` | candidateId | NOW() + 1h |
| Direct distress signal | `COMPLIANCE_FLAG` | candidateId | NOW() + 1h |

Rule #11 invariant: exactly one of `subjectCandidate` / `subjectApplication` set. `subjectApplication` is always null in Workflow A — we're pre-application.

**Operations Lead alert:** delegated to Workflow G (orchestration health sweep). Workflow A writes the ReviewTask; Workflow G surfaces it. Workflow A does not send WhatsApp alerts directly.

---

## 10. Conv-lock release invariant

Six exit paths that hold the lock — all must call Lua CAS DEL:

1. Consent pending → sent template → **release → exit**
2. Consent refused → sent ack → **release → exit**
3. Voice note low quality → sent "please retype" → **release → exit**
4. Voice note manual review → created ReviewTask → **release → exit**
5. Normal completion (reply sent) → **release → exit**
6. Error Trigger → **release → write workflow_errors → exit**

The heartbeat subflow is terminated when the main workflow exits. TTL expiry is the safety net if a crash prevents the CAS DEL; 60 seconds is the maximum orphaned-lock window.

---

## 11. V003 migration scope

**Tables:** `candidate_facts`, `conversation`, `conversation_message`. One migration file.
**Not in V003:** `retry_queue` (deferred to V006 / Workflow G), `event_log`, `ai_call_log`, `workflow_errors` (already in V001/V005).

### Schema

```sql
-- V003__candidate_conversation_tables.sql
-- Purpose: conversation transcript storage, rolling summary, and candidate
--          facts read-cache for Workflow A.
-- Author: <implementor>
-- Date: YYYY-MM-DD
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
  conversation_id      UUID        NOT NULL REFERENCES conversation(id),
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
```

**Per-column justification:**

| Column | Used by |
|---|---|
| `candidate_facts.twenty_candidate_id` | Every lookup by candidateId |
| `candidate_facts.facts` | Workflow A intent context; Workflows B/C read structured facts |
| `candidate_facts.voice_note_retry_at` | Voice note two-strike check (§6) |
| `candidate_facts.scheduled_purge_at` | Workflow G 48h REFUSED purge sweep |
| `conversation.summary` | System prompt context for Claude Sonnet call |
| `conversation.window_start_message_id` | Efficient window boundary query |
| `conversation_message.direction` | Distinguish inbound / outbound in context assembly |
| `conversation_message.body` | Message text for intent + reply context |
| `conversation_message.wa_message_id` | Idempotency check (dedupe node stores in Redis; this enables SQL dedup too) |
| `conversation_message.transcript` | Voice note transcription result |
| `conversation_message.transcript_quality` | Voice note confidence gate result |

---

## 12. Migration sequencing

| Version | Tables | Notes |
|---|---|---|
| V001 | `interviewer`, `slot`, `booking_event_log`, `workflow_errors`, `system_incident`, `event_log` | Phase 1 bring-up |
| V002 | (atomic-claim refinements — no new tables) | Phase 3 |
| V003 | `candidate_facts`, `conversation`, `conversation_message` | **Must apply before Workflow A activates** |
| V004 | `twenty_schema_migrations` | apply-script-owned |
| V005 | `ai_call_log` | Phase 4 voucher |
| V006 | `retry_queue` | Workflow G build |

---

## 13. Design decisions and trade-offs

**1. Single workflow file vs. child-workflow handoff.**
Workflow A is one n8n workflow file that extends `a0-whatsapp-webhook-handler.json`. The Phase-4 handler already holds the Webhook node, HMAC validation, and 200-ack; Workflow A adds its full node graph in the same file. Alternative was a parent/child split (handler triggers child Workflow A via Execute Workflow node). Rejected: adds latency and an extra execution record for every message; the Phase-4 handler is already small.

**2. Spin-wait vs. queue-and-exit for lock contention.**
Lock contention → exit 200 immediately; Workflow G re-dispatches. Alternative was spin-wait with an n8n Wait node (poll every 5s, up to 60s). Rejected: a stuck lock (crashed worker) means the spin would block for the full TTL. Queue-and-exit is cleaner and observable; Workflow G can apply smarter back-off.

**3. `candidate_facts` JSONB vs. typed columns.**
`facts` is JSONB rather than individual columns for the freeform read-cache. Typed columns (`candidate_facts.opt_out_flag`, etc.) are still appropriate for columns Workflow A queries directly (added as explicit columns: `voice_note_retry_at`, `scheduled_purge_at`). The JSONB facts cache holds structured data from Workflows B/C that Workflow A reads but does not write; its schema evolves with those workflows.

**4. Heartbeat as subflow vs. in-line Wait/Loop.**
The 15s heartbeat is a child subflow (`conv-lock-heartbeat`) invoked by n8n's Execute Workflow node in a loop. Alternative was a top-level Cron workflow that sweeps all active locks. Rejected: a sweep needs a lock registry (extra Redis SET or Postgres row), complicating the lock contract. A per-execution subflow stays self-contained.

**5. `medium` transcript quality tier.**
The `transcript_quality` check constraint uses `('high','low','unavailable')`, not a four-value enum. The architect's first pass considered a `medium` tier; dropped here because the confidence-gate thresholds in `groq-whisper.md` are binary (above/below). If post-launch calibration (T2-6) reveals a useful middle band, add it in a V007 ALTER.

**6. `conv_state` in Postgres vs. Redis.**
Conversation state (PENDING / GRANTED / REFUSED) is stored in Twenty (`Candidate.consentStatus`), not in a Redis key or a Postgres `conv_state` column. This is intentional: Twenty is the system of record for candidate identity; state fragmentation would require reconciliation. The cost is a Twenty GraphQL read on every message. At expected volume (<200 msgs/day in Week 1), this is negligible.
