# Workflow A v1 — Implementation Notes

**Workflow:** `a-communications.json` + subflows  
**Date:** 2026-04-29  
**Author:** eofrimpong-collab / Claude Opus 4.7

---

## 1. Conv-lock: Option C — 180s flat TTL

### Decision

CLAUDE.md invariant #3 specifies a 60s TTL with a Lua CAS PEXPIRE heartbeat every 15s. Workflow A v1 **deviates** from this with a 180s flat TTL and no active heartbeat. See T2-12 for the deferred upgrade path.

### Why the standard pattern was non-viable in n8n 1.85.0 regular execution mode

Three options were evaluated:

| Option | Mechanism | Verdict |
|--------|-----------|---------|
| A | Parallel branch: heartbeat loop in second branch | ❌ n8n branches run sequentially, not concurrently. The heartbeat branch would never tick while the main flow is executing. |
| B | Fire-and-forget self-webhook: main flow calls itself to run a detached heartbeat | ❌ The child execution has no reliable termination signal. It can outlive the parent by up to 60s and extend a lock that was already CAS-released, creating a spurious orphan. |
| C | 180s flat TTL, no heartbeat, CAS release on all exit paths | ✅ Adopted. 180s ≥ P99 Claude call latency + all DB ops. Orphan window is bounded at 180s in the worst case (crash after lock acquire, before any CAS release). |

**Source confirmation:** n8n 1.85.0 installed at `/home/devops/Sandbox/twenty/node_modules/n8n`. Branch execution is sequential per the WorkflowExecute runner.

T2-12 in `plans/tier-2-followups.md` tracks true heartbeat implementation once either (a) n8n adds fire-and-forget Execute Workflow or (b) an external cron process manages lock extension.

---

## 2. customData non-writability — DB fallback for lockValue

### Finding

n8n's `$execution.customData` is **not writable at runtime**. It is an API-layer read-only field populated from the `ExecutionMetadata` table after the execution completes. There is no `$setCustomExecutionData()` expression function in n8n 1.85.0 regular mode.

This means the Error Trigger cannot read lockValue from `$execution.customData.lockValue` as originally designed.

### Fallback pattern adopted

Immediately after the successful Redis lock acquire (node ac00015), the workflow writes a row to `event_log`:

```sql
INSERT INTO event_log (workflow_name, execution_id, level, event, message)
VALUES ('workflow_a_communications', $1, 'info', 'lock_acquired', $2)
```

Bindings: `$execution.id`, `lockValue` (from the SET response node).

In the Error Trigger path, node ac_e001 reads it back:

```sql
SELECT message FROM event_log
WHERE execution_id = $1 AND event = 'lock_acquired'
LIMIT 1
```

Binding: `$json.execution.id` (the **failed** execution's ID — see rule #13).

If no row exists (error occurred before lock was acquired), the SELECT returns empty, the CAS DEL is a no-op, and no spurious release occurs.

---

## 3. Six lock-release exit paths

Every path that exits the workflow MUST release the lock via Lua CAS DEL. Confirmed six paths:

| # | Node | Path | Release node |
|---|------|------|--------------|
| 1 | ac00024 | Happy path — consent obtained, message processed | Release Lock — Success |
| 2 | ac00025 | Consent declined — candidate opted out | Release Lock — Opt-Out |
| 3 | ac00026 | Consent pending — sent consent request, awaiting reply | Release Lock — Consent Pending |
| 4 | ac00027 | DPA handled — forwarded to DPA subflow | Release Lock — DPA |
| 5 | ac00028 | Unclassified intent — graceful fallback message sent | Release Lock — Unclassified |
| 6 | ac_e002 | Error Trigger path — any unhandled error | Release Lock — Error |

All six nodes use the same Lua CAS DEL expression:

```
EVAL "if redis.call('get',KEYS[1])==ARGV[1] then return redis.call('del',KEYS[1]) else return 0 end" 1 hra:conv:{candidateId} {lockValue}
```

The `lockValue` is the n8n execution ID (`$execution.id` on success paths; read from `event_log` on the error path).

---

## 4. Subflows

| Subflow | File | Purpose |
|---------|------|---------|
| WA Send | `wa-send.json` | Outbound WhatsApp: enforces 24h service window, falls back to template on error 131047 |
| Claude Call | `claude-call.json` | Claude API wrapper: budget gate ($10/day), ai_call_log write, model routing |
| DPA Handler | `dpa-handler.json` | DATA/ACCESS and DELETE/FORGET intents: ack message + Twenty mutation + event_log |

All three subflows are referenced via `executeWorkflow` with `PLACEHOLDER_*_WORKFLOW_ID` values. **After importing into n8n, update these IDs before activating the workflow.**

---

## 5. T2-6 — Claude confidence thresholds (callout)

The "Classify Intent" Claude call returns a JSON object with `intent`, `confidence`, and `candidateId`. Node ac00020 currently applies a hard rule: `confidence < 0.7` → unclassified path.

**T2-6** tracks calibration of these thresholds against real conversation data. The 0.7 value is a first-pass estimate. After 2 weeks of human review (the calibration window per CLAUDE.md §"Non-negotiable invariants"), revisit against the `ai_call_log` and `event_log` distribution.

---

## 6. V003 tables consumed

| Table | Used by | Purpose |
|-------|---------|---------|
| `candidate_facts` | ac00030 (upsert) | Per-candidate JSONB facts bag |
| `conversation` | ac00017 (upsert), ac00018 (select) | Per-candidate conversation thread metadata |
| `conversation_message` | ac00019 (insert) | Individual message rows; service window lookups in wa-send.json |

Migration: `database/migrations/V003__candidate_conversation_tables.sql` — applied 2026-04-29.

---

## 7. Known limitations and deferred items

| ID | Description | Location |
|----|-------------|----------|
| T2-12 | True Lua CAS PEXPIRE heartbeat (15s cadence) | `plans/tier-2-followups.md` |
| T2-6 | Claude confidence threshold calibration | `plans/tier-2-followups.md` |
| — | PLACEHOLDER_*_WORKFLOW_ID must be replaced post-import | This file §4 |
| — | Human review mandatory for all outputs for first 2 weeks | CLAUDE.md invariant #6 |
| — | Groq Whisper handles English + Pidgin only; local-language voice notes → human queue | CLAUDE.md invariant #5 |
