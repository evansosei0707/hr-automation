# Workflow B — White-Collar Screening Design Note v1

**Status:** Ready for workflow-builder dispatch — OQ-1 resolved (`docs/03-integrations/twenty-application-schema.md`, commit `de875e2`), OQ-6 resolved (`docs/05-decisions/ADR-0010-cv-parser.md`, commit `8a3ec6e`)
**Date:** 2026-05-01
**Author:** architect subagent + Claude Code
**Spec base:** `docs/02-workflows/b-white-collar.md`

This note resolves the design questions left open by the spec and fills in
the implementation detail Workflow B needs before workflow-builder can produce JSON.
Read the spec first; this extends it, not replaces it. All eight OQs are resolved
(see §14); workflow-builder dispatch is unblocked.

OQ resolutions:
- **OQ-1** Twenty v2.1.0 resolvers — `application(filter: { id: { eq: $id } })` for singular fetch (returns plain object, no Connection wrap), `applications(filter: ...)` for collection, `updateApplication(id, data)` for updates. Same pattern for Candidate. Full Application field list at `docs/03-integrations/twenty-application-schema.md` (commit `de875e2`).
- **OQ-2** ReviewTask `kind` for score review = existing `LOW_CONFIDENCE_SCORE` option value (no new option).
- **OQ-3** Workflow A's `workflow_reply` branch INSERTs the `screening_inbox` row.
- **OQ-4** State coherence gap during scoring window accepted as v1 limitation; deferred to T2.
- **OQ-5** Stay with JSONB in `candidate_facts.facts`; no new `Application.screeningState` field.
- **OQ-6** CV parser = n8n's built-in "Extract from File" node (PDF/DOCX → text in-process) + Claude Sonnet for fact extraction and scoring. Image-only CVs route to `parse_failure` ReviewTask per spec. No new container; DPA-clean. Full rationale at `docs/05-decisions/ADR-0010-cv-parser.md` (commit `8a3ec6e`).
- **OQ-7** Single scoring pass for v1; second-opinion pass deferred to T2.
- **OQ-8** `scoreBreakdown` is JSON-stringified into a TEXT slot inside `candidate_facts.facts.score_breakdown`; no Twenty RAW_JSON field.

---

## 1. Node graph

Workflow B is **NOT a subflow of Workflow A.** Per `a-communications.md`, A writes to an inbox table and downstream workflows poll. B is a separate top-level workflow on a 60-second Cron poll, FIFO over `screening_inbox` rows.

```
[Cron Trigger every 60s]
         |
         v
[Postgres: claim oldest unprocessed inbox row]   -- UPDATE screening_inbox SET claimed_by=$execId,
    |                |                              claimed_at=NOW() WHERE id = (
  ZERO              ONE                              SELECT id FROM screening_inbox
   |                 |                               WHERE processed_at IS NULL AND claimed_by IS NULL
[exit]               |                               ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED
                     |                              ) RETURNING *;
                     v
[Redis: Conv-lock acquire]      -- SET hra:conv:{candidateId} {execId} NX PX 60000
    |              |
   FAIL          ACQUIRED
    |              |
[Postgres:    [Twenty GraphQL: fetch Application + Candidate]
 mark inbox        |                  -- includes JobPosting.requirements,
 row failed   [Twenty GraphQL:           Candidate.cvDocumentUrl
 with         fetch JobPosting]
 lock-fail         |
 reason]           v
   exit]      [HTTP: download CV bytes]   -- from Twenty Document URL
                   |
              [CV parse → text]            -- n8n "Extract from File" node (ADR-0010)
                   |
              [Validate rubric weights]    -- §6 invariant
                   |
                  [If: weights sum ≠ 1.0]
                   |              |
                  YES            NO
                   |              |
              [Twenty:        [Redis: release conv-lock]
               ReviewTask          |
               PARSE_FAILURE]      v
              [Postgres:     [Subflow: claude-call — extract facts]
               mark inbox         |     model=claude-sonnet-4-6
               row failed]        |     system=fact-extraction prompt
              [release lock]      v
              [exit]         [Subflow: claude-call — score against rubric]
                                  |     model=claude-sonnet-4-6
                                  |     input: rubric + extracted facts + cv_text
                                  v
                             [Code: compute weighted total + map to strengthTier]
                                  |
                             [Postgres: write candidate_facts.facts JSONB]
                                  |    -- includes score_breakdown (OQ-8 stringified)
                                  v
                             [Twenty mutation: updateApplication]
                                  |    -- score, scoreBreakdown (text), status=screened
                                  v
                             [Twenty mutation: updateCandidate]
                                  |    -- strengthTier
                                  v
                             [Loop over inferred skills:
                              Twenty: upsert CandidateSkillTag(source=cv_parse)]
                                  |
                                  v
                             [Redis: re-acquire conv-lock]
                                  |    -- short window: only for WA send
                                  v
                             [Subflow: wa-send (ack message)]
                                  |    -- text varies by tier; does not reveal score
                                  v
                             [Postgres: log outbound conversation_message]
                                  |
                                  v
                             [Twenty mutation: createReviewTask]
                                  |    -- kind=SCORE_REVIEW for top20/solid
                                  |       OR LOW_CONFIDENCE_SCORE if calibration window OR
                                  |       low-confidence boundary; subjectApplication (rule #11)
                                  v
                             [Postgres: mark screening_inbox row processed_at=NOW()]
                                  |
                                  v
                             [Redis: release conv-lock]
                                  |
                                  v
                             [exit]


─── Error Trigger (top-level, any node failure) ────────────────────────────────

[Error Trigger]
    |
[Redis: release conv-lock if held]    -- Lua CAS DEL
    |
[Postgres: write workflow_errors]     -- array-form queryReplacement (rule #18)
    |
[Postgres: mark screening_inbox row failed with error_message]
    |
[If: attempt_number < 3]
    YES → [exit — next Cron tick re-claims after claimed_at expiry sweep]
    NO  → [Twenty: ReviewTask kind=WORKFLOW_ERROR subjectApplication=appId dueBy=NOW()+4h]
          [exit]
```

**Subflows reused from Workflow A:**
1. `claude-call` — model routing, budget gate, `ai_call_log` write (V005). Two invocations per row: facts extraction, then scoring.
2. `wa-send` — 24h service window enforcement, template fallback on error 131047.

**No new subflows produced for Workflow B in v1.** CV parsing is in-line via n8n's built-in "Extract from File" node (ADR-0010); fact extraction and scoring reuse the existing `Subflow — Claude Call`.

---

## 2. Trigger and entry shape

**Why poll rather than subflow.** Three reasons drive the inbox-poll pattern:

1. Workflow A's spec already mandates inbox-table hand-off ("downstream workflows poll").
2. CV parsing + 2× Claude Sonnet calls take 10–60s. Holding A's conv-lock that long blocks any further messages from the same candidate. Releasing A's lock at hand-off and re-acquiring B's lock only for the WhatsApp send minimises blocking.
3. Cron poll gives free retry semantics — a failed row stays unprocessed and is retried next tick.

**`screening_inbox` row shape** (V008 migration, §10):

| Column | Source | Notes |
|---|---|---|
| `id` | DB default | UUID PK |
| `application_id` | Workflow A | Twenty Application UUID; FK to nothing (cross-DB) |
| `candidate_id` | Workflow A | Twenty Candidate UUID |
| `trigger_kind` | Workflow A | `'new_application'` for v1 |
| `payload` | Workflow A | JSONB; `{ "from_workflow": "a", "execution_id": "...", "first_message_at": "..." }` |
| `claimed_by` | Workflow B | n8n execution ID (`$execution.id`) |
| `claimed_at` | Workflow B | NOW() at claim |
| `processed_at` | Workflow B | NOW() on success; NULL on failure |
| `error_message` | Workflow B | Last error if failed |
| `created_at` | DB default | FIFO ordering |

**Claim query** (Postgres node, queryReplacement array form per rule #18):

```sql
UPDATE screening_inbox
SET claimed_by = $1, claimed_at = NOW()
WHERE id = (
  SELECT id FROM screening_inbox
  WHERE processed_at IS NULL
    AND (claimed_by IS NULL OR claimed_at < NOW() - INTERVAL '5 minutes')
  ORDER BY created_at
  LIMIT 1
  FOR UPDATE SKIP LOCKED
)
RETURNING *;
```

The `claimed_at < NOW() - INTERVAL '5 minutes'` clause re-claims rows that were claimed but never marked processed (crashed worker case). 5 minutes is the maximum reasonable scoring window.

---

## 3. Workflow A change-request

Workflow A's `workflow_reply` intent branch must INSERT into `screening_inbox` after releasing its conv-lock. This is a **small, self-contained edit** to `a-communications.json` to land alongside Workflow B's first build:

```
[Subflow dispatch: workflow_reply]
         |
         v
[Postgres: INSERT into screening_inbox]
         |    -- application_id = (resolve via Candidate.applications? Or carry from intent classification?)
         |    -- candidate_id = $('Resolve Candidate by Phone').first()?.json?...
         |    -- trigger_kind = 'new_application'
         |    -- payload = JSONB with execution_id and message context
         v
[Redis: release conv-lock]   -- existing release node
         |
         v
[exit 200]
```

**Open sub-question for the Workflow A change:** which `application_id` is the inbox row for? In v1, the assumption is each Candidate has at most one Application in `received` status at any time. If the candidate has no Application yet, the inbox INSERT is skipped and Workflow A handles the conversation as `open_conversation`. **This sub-question must be confirmed with the spec author before the change ships** — track as part of the OQ-1 researcher follow-up.

---

## 4. State machine

| Stage | Persistence | Owner |
|---|---|---|
| Inbox queued | `screening_inbox.processed_at IS NULL` | Workflow A wrote |
| Inbox claimed | `screening_inbox.claimed_by IS NOT NULL AND processed_at IS NULL` | Workflow B holds |
| CV parsed | `candidate_facts.facts.cv_text` | Workflow B writes |
| Facts extracted | `candidate_facts.facts.extracted` | Workflow B writes |
| Scored | `candidate_facts.facts.score`, `.score_breakdown` (JSON-stringified per OQ-8) | Workflow B writes |
| Twenty updated | `Application.score`, `.scoreBreakdown`, `.status=screened`; `Candidate.strengthTier` | Workflow B mutates |
| Inbox processed | `screening_inbox.processed_at IS NOT NULL` | Workflow B closes |

No new bookings-DB tables for state beyond `screening_inbox`. All transient state lands in `candidate_facts.facts` (V003, already live).

**`candidate_facts.facts` shape after Workflow B run:**

```jsonc
{
  // ... existing fields from Workflow A
  "cv_text": "<extracted plain-text CV>",
  "extracted": {
    "years_of_experience": 5,
    "current_role": "Frontend Developer",
    "skills": ["React", "TypeScript", "Node.js"],
    "education": [{ "degree": "BSc Computer Science", "institution": "KNUST", "year": 2019 }]
  },
  "rubric": [
    { "criterion": "5+ years experience", "weight": 0.3 },
    { "criterion": "React/TypeScript", "weight": 0.4 },
    { "criterion": "BSc or equivalent", "weight": 0.3 }
  ],
  "score": 72,
  "score_breakdown": "{\"5+ years experience\":{\"score\":80,\"evidence\":\"...\",\"rationale\":\"...\"},\"React/TypeScript\":...}",
  "screened_at": "2026-05-02T14:23:00Z"
}
```

---

## 5. Twenty GraphQL writes

Per CLAUDE.md invariant #1 and ADR-0005 conventions: all Twenty interaction goes through `/graphql` with the `TWENTY_API_KEY` Bearer header. Mutation names follow ADR-0005 (no `One` infix on data-API resolvers): `updateApplication`, `updateCandidate`, `createReviewTask`, `createCandidateSkillTag`, `updateCandidateSkillTag`.

> ✅ **OQ-1 RESOLVED:** Twenty v2.1.0 uses `application(filter: { id: { eq: $id } })` for singular fetch (returns plain object, no Connection unwrap) and `updateApplication(id, data)` for updates. Same pattern for Candidate. Full field list and example queries at `docs/03-integrations/twenty-application-schema.md`.

**Mutations Workflow B issues:**

```graphql
# Update Application after scoring
mutation UpdateApplication(
  $id: ID!, $score: Float!, $scoreBreakdown: String!, $status: String!
) {
  updateApplication(id: $id, data: {
    score: $score
    scoreBreakdown: $scoreBreakdown    # OQ-8: stringified JSON in TEXT field
    status: $status                     # 'screened'
  }) { id }
}

# Update Candidate strengthTier
mutation UpdateCandidate($id: ID!, $strengthTier: String!) {
  updateCandidate(id: $id, data: {
    strengthTier: $strengthTier         # 'top20' | 'solid' | 'developing' | 'not_a_fit'
  }) { id }
}

# Upsert skill tag (one mutation per inferred skill, looped in n8n)
mutation CreateCandidateSkillTag(
  $candidateId: ID!, $skillTagId: ID!, $source: String!
) {
  createCandidateSkillTag(data: {
    candidate: { connect: { id: $candidateId } }
    skillTag:  { connect: { id: $skillTagId } }
    source:    $source                  # 'cv_parse'
  }) { id }
}

# ReviewTask — subjectApplication (NOT subjectCandidate; rule #11)
mutation CreateReviewTask(
  $applicationId: ID!, $kind: String!, $dueBy: DateTime!
) {
  createReviewTask(data: {
    subjectApplication: { connect: { id: $applicationId } }
    kind:   $kind                       # 'SCORE_REVIEW' | 'LOW_CONFIDENCE_SCORE' | 'PARSE_FAILURE' | 'WORKFLOW_ERROR'
    dueBy:  $dueBy
    status: "OPEN"
  }) { id }
}
```

**ReviewTask invariant (rule #11):** Workflow B writes `subjectApplication` only. `subjectCandidate` is always null in B — the screening is anchored to a specific Application, not the candidate generically.

---

## 6. Rubric extraction and validation

Per spec invariant: rubric weights must sum to exactly 1.0 or workflow refuses to run.

**Source:** `JobPosting.requirements` (TEXT). Format expected: one criterion per line, optionally with `[weight=0.3]` suffix. If no weights present, equal weighting is applied.

**Code node** parses the requirements, builds the rubric, and validates:

```javascript
const requirements = $json.jobPosting.requirements ?? '';
const lines = requirements.split('\n').map(l => l.trim()).filter(Boolean);
const rubric = lines.map(line => {
  const m = line.match(/\[weight=([\d.]+)\]\s*$/);
  return {
    criterion: line.replace(/\s*\[weight=[\d.]+\]\s*$/, '').trim(),
    weight: m ? parseFloat(m[1]) : (1.0 / lines.length),
  };
});
const total = rubric.reduce((s, r) => s + r.weight, 0);
const ok = Math.abs(total - 1.0) < 0.001;
return [{ json: { rubric, weight_sum: total, weights_ok: ok } }];
```

**On `weights_ok = false`:** ReviewTask `kind=PARSE_FAILURE` with the bad weight sum in the description; mark inbox row failed; release lock; exit. Spec invariant honoured.

---

## 7. Claude calls

Both Claude calls go through the existing `claude-call` subflow. Subflow already handles model routing, budget gate, and `ai_call_log` writes.

**Call 1 — Fact extraction (Sonnet):**
- `model`: `claude-sonnet-4-6`
- `workflowName`: `workflow_b_screening_extract`
- `systemPrompt`: extract structured facts; respond with strict JSON; no commentary.
- `messages`: `[{ role: "user", content: cv_text }]`
- Expected output `content`: JSON parseable to `{ years_of_experience, current_role, skills[], education[] }`.

**Call 2 — Rubric scoring (Sonnet):**
- `model`: `claude-sonnet-4-6`
- `workflowName`: `workflow_b_screening_score`
- `systemPrompt`: HR scoring assistant; cite evidence quotes from CV; output strict JSON; no unsupported judgements (spec invariant).
- `messages`: `[{ role: "user", content: <rubric + facts + full cv_text> }]`
- Expected output `content`: JSON parseable to `{ "<criterion>": { "score": 0–100, "evidence": "<quote>", "rationale": "<bounded>" }, ... }`.

**Cost gate:** the existing `claude-call` subflow's daily-spend gate covers Workflow B too. No B-specific budget logic.

**Idempotency tolerance (spec acceptance criterion):** ±5 points across re-runs is accepted. n8n re-running on the same row is rare (only on retry after a failed Twenty mutation) but the contract allows it.

---

## 8. WhatsApp acknowledgement

Spec: text varies by tier; **never reveals the numeric score.**

**Free-form drafts (subject to Operations Lead review):**

| Tier | Message |
|---|---|
| `top20` | "Hi {firstName}, thanks for sending your CV for the {jobTitle} role. We've reviewed it and we'd like to take the next step. We'll be in touch shortly with interview details." |
| `solid` | "Hi {firstName}, thanks for sending your CV for the {jobTitle} role. We've reviewed it. We'll be in touch within a few days about next steps." |
| `developing` | "Hi {firstName}, thanks for your interest in the {jobTitle} role and for sending your CV. We've received it and will get back to you." |
| `not_a_fit` | "Hi {firstName}, thanks for your CV for the {jobTitle} role. We've received it; we'll let you know if there's a fit." |

All four fire as free-form messages via the `wa-send` subflow. **No template; the 24h service window is open** because Workflow A just had a conversation.

The conv-lock is re-acquired immediately before the WA send and released immediately after. Lock window for the send: ≤2s.

---

## 9. Error handling

Error Trigger pattern follows Workflow A (rule #13 NOT NULL bindings on `workflow_errors`):

| `workflow_errors` column | Binding | Notes |
|---|---|---|
| `workflow_name` | `$workflow.name` | |
| `execution_id` | `$json.execution.id` | Error Trigger context — failed execution |
| `node_name` | `$json.error.node.name` | |
| `error_message` | `$json.error.message` | |
| `error_stack` | `$json.error.stack?.split('\n')[0]` | First line only (rule #18) |

**queryReplacement uses array form per rule #18:**

```
"queryReplacement": "={{ [$workflow.name, $json.execution.id, $json.error.node?.name ?? '', $json.error.message ?? '', ($json.error.stack ?? '').split('\\n')[0]] }}"
```

**ReviewTask triggers from Workflow B:**

| Trigger | `kind` | `dueBy` |
|---|---|---|
| Rubric weights ≠ 1.0 | `PARSE_FAILURE` | NOW() + 4h |
| CV unparseable (image-only PDF, etc.) | `PARSE_FAILURE` | NOW() + 4h |
| Score boundary case (within 5 points of tier edge) | `LOW_CONFIDENCE_SCORE` | NOW() + 24h |
| `top20` or `solid` tier (post-screening) | `SCORE_REVIEW` | NOW() + 24h |
| **Calibration window (first 2 weeks):** ALL tiers | `SCORE_REVIEW` | NOW() + 24h |
| Third Cron-retry failure | `WORKFLOW_ERROR` | NOW() + 4h |

All carry `subjectApplication`; `subjectCandidate` is null (rule #11).

---

## 10. V008 migration scope

**One table:** `screening_inbox`. No other schema changes for Workflow B v1 — `candidate_facts.facts` JSONB (V003) covers transient state.

```sql
-- V008__create_screening_inbox.sql
-- Purpose: hand-off table from Workflow A's workflow_reply branch to
--          Workflow B's 60s Cron poll. FIFO with claim-then-process.
-- Author: <implementor>
-- Date: 2026-05-02
-- Spec: docs/02-workflows/b-white-collar-design-v1.md §2

BEGIN;

CREATE TABLE screening_inbox (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id  TEXT        NOT NULL,                   -- Twenty Application UUID
  candidate_id    TEXT        NOT NULL,                   -- Twenty Candidate UUID
  trigger_kind    TEXT        NOT NULL CHECK (trigger_kind IN ('new_application')),
  payload         JSONB       NOT NULL DEFAULT '{}',
  claimed_by      TEXT,                                   -- n8n execution_id
  claimed_at      TIMESTAMPTZ,
  processed_at    TIMESTAMPTZ,
  error_message   TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- One unprocessed row per application; double-INSERT from A is rejected at DB level.
CREATE UNIQUE INDEX uq_screening_inbox_application_unprocessed
  ON screening_inbox (application_id)
  WHERE processed_at IS NULL;

-- FIFO polling support.
CREATE INDEX idx_screening_inbox_pending
  ON screening_inbox (created_at)
  WHERE processed_at IS NULL;

COMMIT;

-- Rollback:
--   DROP TABLE screening_inbox;
```

**Migration sequencing:**

| Version | Tables | Notes |
|---|---|---|
| V001–V005 | (already applied) | per Workflow A design note §12 |
| V006 | `retry_queue` | Workflow G build |
| V007 | (reserved) | possible `transcript_quality` ALTER per A §13 #5 |
| V008 | `screening_inbox` | **Must apply before Workflow B activates** |

Workflow A's change-request (§3) does not require a new migration — it only adds an INSERT node in `a-communications.json`.

---

## 11. Conv-lock interaction with Workflow A

Workflow B does **not** share a lock instance with Workflow A. The contract:

1. Workflow A holds `hra:conv:{candidateId}` while it's processing the inbound message and routing intent. On `workflow_reply` intent, A INSERTs the inbox row, then releases its lock, then exits.
2. Workflow B's Cron tick claims the inbox row (no lock held yet).
3. Workflow B acquires `hra:conv:{candidateId}` (same key) using its own execution ID as the token. If A is still processing a follow-up message, B waits one Cron tick (60s) and retries via the inbox claim.
4. Workflow B fetches Twenty data, **releases the lock for the parsing/scoring window** (10–60s), then re-acquires only for the WA send.
5. After WA send and ReviewTask, B releases and marks the inbox row processed.

> ⚠️ **OQ-4 acceptance — known v1 limitation.** Between B releasing the lock for parsing and re-acquiring for the WA send, a candidate inbound message would land on an empty lock and Workflow A could process it. The race is acceptable for v1 because: (a) the candidate just sent a CV and is unlikely to fire another message in the 30s window; (b) any follow-up message is processed by A as a normal `open_conversation` and the eventual screening result is unchanged. T2 follow-up: hold the lock through the scoring window, accepting the latency cost.

**Lock token = `$execution.id`** alone (rule #15); no random suffix.
**Lock release on every exit path** — six paths in Workflow B mirror Workflow A's invariant (CLAUDE.md #3):

1. Lock-acquire fail → exit (no release; lock not held)
2. CV parse failure → release → exit
3. Rubric weights invalid → release → exit
4. Twenty mutation failure → Error Trigger → release → workflow_errors → exit
5. Normal completion → release → mark inbox processed → exit
6. Error Trigger (any node failure) → release → workflow_errors → exit

---

## 12. Calibration gate

Same 2-week window as Workflow A's `ac00067`. Workflow B implements it as an IF node before the ReviewTask creation:

```
[Code: calibration_window_active = (NOW() - launch_date) < 14 days]
   |                |
  YES              NO
   |                |
[ReviewTask    [If: tier ∈ {top20, solid}]
 kind=                 |             |
 SCORE_REVIEW         YES           NO
 for ALL tiers]        |             |
                  [ReviewTask    [no review task —
                   kind=          screening completes
                   SCORE_REVIEW]  unsupervised]
```

`launch_date` is read from the n8n environment (env var `WORKFLOW_B_LAUNCH_DATE`, ISO-8601). If not set, default behaviour is **calibration ON** (fail-safe to human review).

---

## 13. Rule trap-points (n8n 2.x compatibility)

Live test of Workflow A surfaced rules #19–#23 (added to `.claude/rules/n8n-workflows.md` 2026-05-01). Workflow-builder must apply them everywhere relevant in B:

**Rule #19 — Execute Workflow uses `workflowInputs.value` resourceMapper, NOT `fields.values`.**
B has 3 Execute Workflow nodes (claude-call ×2, wa-send ×1). All three must use:

```json
"workflowInputs": {
  "mappingMode": "defineBelow",
  "value": { "model": "...", "workflowName": "...", "messages": "..." },
  "schema": [ ... ]
}
```

**Rule #20 — Set node `typeVersion: 3.4`, NOT 3.**
Every Set node in B must carry `"typeVersion": 3.4`. The validator (`./scripts/validate-n8n-workflow.sh`) should be extended to flag any Set node with typeVersion < 3.3 and `assignments` parameter.

**Rule #22 — Read source data directly from producing nodes, NOT from intermediate Set nodes.**
B's expressions reference data from these source nodes by name:
- `phoneE164` (for wa-send) → `$('Fetch Application + Candidate').first()?.json?.data?.candidate?.whatsappNumberE164`
- `candidateId` → `$('Fetch Application + Candidate').first()?.json?.data?.application?.candidate?.id`
- `applicationId` → `$('Fetch Application + Candidate').first()?.json?.data?.application?.id`
- `cv_text` → `$('CV parse').first()?.json?.text`
- `score`, `breakdown` → `$('Score against rubric').first()?.json?.content?.[0]?.text` (parsed)

No Set Candidate Context style intermediary in B.

**Rule #23 — consent/state-gate IFs read directly from the GraphQL fetch node.**
B does not check `consentStatus` (the candidate is already past consent — Workflow A let them through to `workflow_reply`). The structurally analogous gate is `Application.status` — checked from `$('Fetch Application + Candidate').first()?.json?.data?.application?.status`, never from a Set node.

**Rule #18 — `queryReplacement` array form for any TEXT column.**
Every Postgres node in B writing user-supplied or system-generated text (cv_text excerpts, error messages, JSON-stringified score breakdown) uses array form:

```
"queryReplacement": "={{ [val1, val2, val3] }}"
```

**Rule #13 — every Postgres write node binds all NOT NULL columns from the migration.**
For `screening_inbox`: `application_id`, `candidate_id`, `trigger_kind`, `payload`. For `workflow_errors`: `workflow_name`, `execution_id`, `error_message`. For `ai_call_log` (via claude-call subflow): `workflow_name`, `model`.

**Rule #11 — ReviewTask polymorphic subject invariant.**
Every ReviewTask Workflow B writes has `subjectApplication` set, `subjectCandidate` null. Defensive read: any node reading a ReviewTask must verify exactly one is set.

---

## 14. Open questions — RESOLVED

All eight OQs are resolved. Workflow-builder dispatch is unblocked.

**OQ-1 — Twenty v2.1.0 singular-by-ID resolver names.** ✅ Resolved at `docs/03-integrations/twenty-application-schema.md` (commit `de875e2`). Singular fetch uses `application(filter: { id: { eq: $id } })` and returns a plain object (no `edges.node` unwrap). Updates use `updateApplication(id, data)` — no `One` infix on the data API. Same pattern for Candidate. The reference doc has the full Application field list and ready-to-paste example queries for the fetch + update nodes.

**OQ-6 — CV parser choice.** ✅ Resolved at `docs/05-decisions/ADR-0010-cv-parser.md` (commit `8a3ec6e`). v1 uses **n8n's built-in "Extract from File" node** in-process for PDF/DOCX → text, then Claude Sonnet for fact extraction (step 2) and scoring (step 4) via the existing `Subflow — Claude Call`. No new container, no new credentials, all data stays in Ghana — DPA-clean.

**Image-only CV behaviour:** image CVs (no embedded text layer) trigger the existing `parse_failure` ReviewTask path per spec §"Edge cases" — no zero-score fallback. PDF/DOCX with text layers extract directly with no candidate-friction. PDF/DOCX with no text layer (rare; usually scanned-to-PDF) also route to `parse_failure`. **No "please send as text" branch is needed** for v1 — the spec already routes parse failures to ReviewTask, and the operator handles them during the calibration window.

**Tier 2 trigger:** if real candidate traffic shows >20% of CVs hitting `parse_failure`, ADR-0010 spec'd Option B (Python microservice with `pdfplumber` + `pytesseract` OCR) as the v2 path.

---

## 15. Acceptance criteria mapping

Spec acceptance criteria (from `b-white-collar.md` §"Acceptance criteria") to design coverage:

| Spec criterion | Design coverage |
|---|---|
| Happy path: mid-level frontend CV scores within 10pts of human rubric | §7 — two Sonnet calls with strict JSON output; tester verifies on representative sample |
| Malformed CV (image without OCR) → ReviewTask, not 0 | §6 + §9 — PARSE_FAILURE ReviewTask path |
| Rubric with zero weights → workflow refuses | §6 — weight-sum validation + PARSE_FAILURE |
| Calibration mode: every score human-reviewed | §12 — 2-week window creates SCORE_REVIEW for ALL tiers |
| Idempotency: re-runs ±5pts, no duplicate skill tags | §7 + §5 — Twenty mutations are upserts on (candidate, skillTag) pair; Sonnet variance accepted |

---

## 16. Design decisions and trade-offs

**1. Inbox-poll vs. direct subflow.** Inbox-poll chosen (§2). Trade-off: 60s polling latency vs. holding A's lock through expensive scoring. Scoring latency dominates; releasing A's lock at hand-off is the win.

**2. Single scoring pass (OQ-7).** v1 does one Sonnet scoring call. Spec lists "second-opinion pass for boundary cases" as an open question; deferred to T2. Boundary cases (within 5pts of tier edge) get a `LOW_CONFIDENCE_SCORE` ReviewTask instead — human eyes resolve the boundary, not a second model.

**3. JSONB-only state (OQ-5).** No `Application.screeningState` field added in Twenty. `candidate_facts.facts` JSONB carries the transient state. Trade-off: weak typing, no Twenty-side filtering by screening state. Win: zero new Twenty schema migrations for B.

**4. Stringified breakdown (OQ-8).** `Application.scoreBreakdown` is a TEXT column receiving a JSON string. Twenty has no first-class JSONB column type in v2.1.0 (per ADR-0005 audit). Reading the breakdown requires a JSON.parse on the consumer side; documented in `twenty-crm-schema.md`.

**5. Calibration always-on by default (§12).** If `WORKFLOW_B_LAUNCH_DATE` env var is missing, calibration mode stays active (every screening goes to human review). Fail-safe to safety, not to throughput. Operations Lead must explicitly set the launch date to disable calibration.

**6. Conv-lock released during scoring (§11).** Accepted v1 race window of ~30s where a follow-up message from the same candidate could be processed by A while B is scoring. T2 follow-up: hold the lock through scoring, paying ~30s of WA-send latency in worst case.

**7. No new subflows.** B reuses A's `claude-call` and `wa-send`. CV parsing uses n8n's built-in "Extract from File" node in-process (ADR-0010 Option A). If real traffic forces ADR-0010 Option B (Python microservice) in v2, a thin `cv-parse` subflow MAY be introduced — but not before v1.
