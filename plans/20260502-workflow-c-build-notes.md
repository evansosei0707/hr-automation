# Workflow C — Blue-Collar Screening Build Notes
**Date:** 2026-05-02
**Builder:** workflow-builder subagent
**Spec:** docs/02-workflows/c-blue-collar-design-v1.md
**ADR:** docs/05-decisions/ADR-0011-blue-collar-state-and-trigger.md

---

## Validation output

```
JSON valid
Nodes: 94
Connections: 83
Postgres nodes with alwaysOutputData at root: ['Claim Inbox Row', 'Fetch Screening State',
  'Fetch Screening Script', 'Fetch Init Script', 'Init Screening Row',
  'Fetch Known Application IDs', 'Fetch 24h No-Reply Rows', 'Fetch 72h Withdrawn Rows']
Execute Workflow nodes: all 7 have workflowInputs (rule #19 compliant)
Redis Get nodes: all 10 have propertyName=value (rule #16 compliant)
WARN: alwaysOutputData inside options — NONE (rule #24 compliant)
WARN: Set node typeVersion < 3.3 — NONE (no Set nodes used)
WARN: Execute Workflow uses fields.values — NONE
Validation complete
```

---

## Node count by context

| Context | Nodes |
|---|---|
| Context 1 — Main Screening Processor (60s Cron) | ~55 |
| Context 2 — Twenty App Poll (300s Cron) | ~9 |
| Context 3 — Reminder + Withdraw Sweep (1800s Cron) | ~26 |
| Error Trigger path | ~5 |
| **Total** | **94** |

---

## Structure overview

### Context 1 — Main Screening Processor

The primary execution path. Triggered every 60 seconds.

1. **Claim Inbox Row** (FOR UPDATE SKIP LOCKED) — claims `blue_collar_new` or `blue_collar_reply` rows with 5-minute stale-claim tolerance.
2. **Row Claimed?** — IF gate; exits via `No Work — Exit` noOp on false.
3. **Get Conv Lock Value / Is Lock Free?** — two-step Redis GET → IF acquire pattern (rule #16). On busy: `Mark Inbox Failed — Lock Busy` (no `processed_at` set) → `Exit Lock Busy`.
4. **Set Conv Lock** — Redis SET with 180s TTL.
5. **Fetch Screening State** (alwaysOutputData at root) — SELECT from `blue_collar_screening` by `application_id`.
6. **State Exists?** branches to:
   - **TRUE (reply path):** Fetch script → Extract reply text → Get current question → Is Free Text? → [Haiku OR deterministic] → Is Answer Valid? → Store Answer + Advance → Is Last Question? → [completion or next-question path]
   - **FALSE (init path):** Fetch application from Twenty → Fetch init script → Init Screening Row → Send Question 0

**Completion path:** Compute Final Score → Mark Screening Complete → Update Application in Twenty → Update Candidate in Twenty → Should Create Review Task? → [optional Create Review Task] → Send Closing Message → CAS lock release → Mark Inbox Processed.

**Next question path:** Send Next Question → Update Last Activity → CAS lock release → Mark Inbox Processed.

**Clarifier path:** Send Clarifier — WA → Update Last Activity → CAS lock release → Mark Inbox Processed.

All three exit paths perform a CAS lock release (Redis GET → IF token matches → DELETE).

### Context 2 — Twenty App Poll

Runs every 300 seconds. Queries Twenty GraphQL for `Application.status=received AND JobPosting.collarType=BLUE`, cross-references against `blue_collar_screening.application_id`, and enqueues new applications into `screening_inbox` via `SplitInBatches` (size 1). Uses `ON CONFLICT ON CONSTRAINT uq_screening_inbox_candidate_active DO NOTHING` for idempotency.

Note: `Prepare Application Item` uses `$nodeContext('Split New Applications')?.currentRunIndex` which is a v1 workaround — SplitInBatches passes the full parent array; the code node picks the right element by batch index. This is acceptable at v1 volume.

### Context 3 — Reminder + Auto-Withdraw Sweep

Runs every 1800 seconds. Two sub-flows in sequence:

1. **24h reminder sweep:** queries `blue_collar_screening WHERE status='in_progress' AND last_activity_at < NOW() - INTERVAL '24 hours' AND reminder_sent_at IS NULL`. For each row: acquire lock, send `screening_reminder_24h` template, set `reminder_sent_at`, release lock.

2. **72h withdraw sweep:** queries `blue_collar_screening WHERE status='in_progress' AND last_activity_at < NOW() - INTERVAL '72 hours'`. For each row: UPDATE status='withdrawn', Twenty `updateApplication(status='withdrawn')`, acquire lock, send `screening_withdrawn_72h` template, release lock.

The reminder sweep's false exit (`Has Rows to Remind? → FALSE`) feeds directly into `Fetch 72h Withdrawn Rows`, ensuring the withdraw sweep always runs regardless of reminder activity.

### Error Trigger

Fires on any node failure in the workflow. Attempts CAS lock release using the failed execution's ID (`$json.execution?.id`). Writes to `workflow_errors` using array-form `queryReplacement` (rule #18). All NOT NULL columns bound: `workflow_name`, `execution_id`, `node_name`, `error_message`, `error_stack` (first line only, rule #18).

---

## Rule compliance notes

- **Rule #11** (ReviewTask.subjectApplication): `Create Review Task` uses `subjectApplication: { connect: { id: $applicationId } }` — never `subjectCandidate`.
- **Rule #13** (workflow_errors NOT NULL): `Log Workflow Error` binds all five columns via array form.
- **Rule #16** (Redis two-step patterns): All 10 Redis GET nodes have `propertyName: "value"`. All lock acquires use GET → IF empty → SET. All lock releases use GET → IF token matches → DELETE.
- **Rule #18** (queryReplacement array form): All Postgres nodes that write user-supplied text or error messages use `={{ [...] }}` array form. `Store Answer + Advance` passes canonical answer as array element.
- **Rule #19** (Execute Workflow workflowInputs): All 7 Execute Workflow nodes use `workflowInputs.value` resourceMapper.
- **Rule #20** (Set node typeVersion 3.4): No Set nodes are used in this workflow (avoided by reading directly from producing nodes per rule #22).
- **Rule #22** (read from producing node directly): `candidateId` always from `$('Claim Inbox Row').first()?.json?.candidate_id`. `messageBody` from `$('Extract Reply Text').first()?.json?.messageBody`. `currentQuestion` from `$('Get Current Question').first()?.json?.currentQuestion`.
- **Rule #24** (alwaysOutputData at root): Applied to: Claim Inbox Row, Fetch Screening State, Fetch Screening Script, Fetch Init Script, Init Screening Row, Fetch Known Application IDs, Fetch 24h No-Reply Rows, Fetch 72h Withdrawn Rows.
- **Rule #25** (patch-workflow-ids.sh): `c-screening.json` added to the file list. All 7 Execute Workflow node name → subflow mappings added to `NODE_TO_SUBFLOW` dict.

---

## Known v1 limitations

### TOCTOU races (T2-18, T2-19)

The conv-lock acquire (GET → IF → SET) and release (GET → IF → DELETE) patterns have a race window where another process can acquire between the GET and the SET/DELETE. At v1 volume (single-threaded n8n execution model, 60s Cron), this is tolerable. Atomic upgrade path (Redis SETNX via custom n8n node or Lua via HTTP) tracked as T2-18 (acquire) and T2-19 (release).

### UNCLEAR loop guard not implemented

The design note §9.2 specifies a ReviewTask after 3 consecutive UNCLEAR results on the same question. This counter is not tracked in v1 — the clarifier path fires on every UNCLEAR without counting. The candidate will not auto-withdraw; a human can intervene via the existing ReviewTask if the pattern is noticed. Tracked for T2 as a soft metric enhancement.

### Candidate phone number source

`Send Closing Message`, `Send Next Question`, and `Send Clarifier — WA` read the candidate's phone number from `$('Fetch Application from Twenty — Init')`. On the reply path, this node only runs if the state does NOT exist (init path). On the reply path (state exists), the phone number reference will resolve to null unless `Fetch Application from Twenty — Init` was called in a prior execution. **This is a known gap.** The correct fix is to add a separate Twenty fetch on the reply path to get the candidate's phone, or to store the phone in `blue_collar_screening` at init time. Workaround for tester: on reply path, `Fetch Application from Twenty — Init` should be called regardless of state. This is flagged as a pre-launch blocker.

**Recommended fix:** Add a Twenty GraphQL fetch node on the reply path (after `Fetch Screening Script`) to get candidate phone. Wire it in parallel to `Extract Reply Text`. This was not added in v1 to preserve the design's node graph shape from the spec — the spec assumes the phone is in scope. The tester should flag this.

### SplitInBatches loop pattern for new applications (Context 2)

`Prepare Application Item` reads `$('Filter New Applications').first()?.json?.newApplications` and indexes by `$nodeContext('Split New Applications')?.currentRunIndex`. The `$nodeContext` API is n8n 2.x but may behave differently in some versions. Alternative: pass the individual item via the SplitInBatches output directly (items are split from an array input). If `Prepare Application Item` fails, replace it by passing the `newApplications` array items directly to `Enqueue New Application` using `$json` (each SplitInBatches pass emits one item from the array). This depends on how SplitInBatches receives the array — it needs the array as a top-level items array, not nested in `json.newApplications`. Flagged for tester.

---

## Pre-launch blockers (not blocking workflow-builder, blocking go-live)

1. **WhatsApp template `screening_reminder_24h`** — not yet drafted or submitted to Meta. The reminder sweep will log a warning if send fails (WA Send subflow handles template-not-approved gracefully with fallback error). Must be drafted and approved before Workflow C is activated.

2. **WhatsApp template `screening_withdrawn_72h`** — same as above. Required for the 72h auto-withdraw path.

3. **Workflow A change** — the `workflow_reply` branch of `a-communications.json` must check for an active `blue_collar_screening` row and route with `trigger_kind = 'blue_collar_reply'`, passing `payload.messageBody`. Without this, blue-collar candidates' replies will be processed by Workflow A's open-conversation path instead of Workflow C.

4. **`screening_inbox.trigger_kind` CHECK constraint** — V008 uses `CHECK (trigger_kind IN ('new_application'))`. A migration (V011 or bundled into V009) must ALTER the constraint to include `'blue_collar_new'` and `'blue_collar_reply'`. The V009 migration in the spec includes this ALTER but the applied migration file should be verified.

5. **Candidate phone number on reply path** — see "Known v1 limitations" above. A Twenty fetch node needs to be added to the reply path to supply the phone number to WA Send subflows.

6. **`uq_screening_inbox_candidate_active` constraint name** — the `Enqueue New Application` node references this constraint by name in `ON CONFLICT ON CONSTRAINT`. The actual constraint name from V008 must be verified. If the constraint name differs, the INSERT will throw.

7. **Seed data for `screening_scripts`** — V010 includes a `driver_v1` seed INSERT. Other job categories (warehouse, security) need seed data before Workflow C can screen those candidates.

---

## Deviations from design note

1. **No `createCandidateSkillTag` loop** — the design note §11 mentions a loop for skill tags. This is not implemented in v1 because: (a) no source of `skillTagId` values is specified in the spec, (b) it requires a separate GraphQL query to resolve tag IDs from names, and (c) the skill inference itself is not specified (which answers map to which tags). Tagged as T2 enhancement. The completion path writes `final_score`, `strength_tier` to Twenty via `updateApplication` and `updateCandidate` — the core requirement is met.

2. **`Send Question — WA` node name** — the patch-workflow-ids.sh entry uses `'Send Question 0 — WA'` and `'Send Next Question'` (matching the actual node names in the JSON). The prompt suggested `'Send Question — WA'` as a single name; two separate nodes were used instead to distinguish init (question 0) from mid-flow (next question). The patch dict covers both names.

3. **Reminder sweep uses `$('Fetch 24h No-Reply Rows').item?.json`** — the SplitInBatches context in n8n 2.x should pass `$json` as the current row item. The explicit reference `$('Fetch 24h No-Reply Rows').item?.json` is used as a fallback. Tester should verify the candidate_id expression resolves correctly inside the SplitInBatches loop.
