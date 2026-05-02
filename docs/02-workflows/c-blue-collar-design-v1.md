# Workflow C — Blue-Collar Screening Design Note v1

**Status:** Ready for workflow-builder dispatch
**Date:** 2026-05-02
**Author:** architect subagent + Claude Code
**Spec base:** `docs/02-workflows/c-blue-collar.md`

This note resolves the four design questions left open by the spec and fills in the implementation detail Workflow C needs before workflow-builder can produce JSON. Read the spec first; this extends it, not replaces it.

---

## 1. Decision summary

**Q1 — State machine persistence: Option B (new `blue_collar_screening` bookings-DB table)**

A dedicated table gives clean separation from Workflow B's CV facts. Workflow B and Workflow C share `candidate_facts` for separate concerns — mixing screening conversation state with CV parse data in one JSONB blob creates read ambiguity and risks write conflicts if both workflows ever process the same candidate (possible for a candidate who previously applied to a white-collar role and is now applying to a blue-collar one). V009 + V010 migrations required.

**Q2a — Dual trigger for Workflow C**

Workflow C needs two entry paths: (1) the existing `screening_inbox` poll, triggered by a new blue-collar row inserted by Workflow A; (2) a separate Twenty poll (every 5 minutes) that scans for `Application.status = 'received' AND JobPosting.collarType = 'blue'` with no corresponding active `blue_collar_screening` row. This second trigger handles the human-creates-Application-in-Twenty path where no WhatsApp inbound message fires. See §5 for full trigger detail.

**Q2b — Short-lived lock per reply, recursive handoff pattern confirmed**

Workflow C is not long-lived. Each candidate reply flows through Workflow A → `screening_inbox` with `trigger_kind = 'blue_collar_reply'` → Workflow C claims it, acquires lock, validates answer, sends next question, releases lock, exits. The deduplication guard is the existing partial unique index on `(candidate_id) WHERE processed_at IS NULL` in `screening_inbox`, which prevents double-enqueue for rapid-fire messages — the second message is dropped with a 200 and the first proceeds. This is accepted v1 TOCTOU tolerance.

**Q3 — Haiku for free_text normalisation only; deterministic JS Code node for structured types**

Claude Haiku 4.5 is used only for `type: free_text` questions to normalise colloquial answers to a canonical value. All `yes_no`, `number`, `enum`, and `presence_only` questions are validated and scored by a JS Code node with no LLM involvement. This matches Workflow B's scoring pattern: LLM for interpretation, deterministic logic for structured computation.

**Q4 — Screening scripts stored in bookings-DB `screening_scripts` table (Option B)**

Scripts can be bundled in the V010 migration (same migration as the `blue_collar_screening` state table). Hard-coding in workflow JSON (Option A) would require a full workflow redeploy to change a question prompt, which is unacceptable for a system running 200+ candidates per day. Twenty CRM custom object (Option C) adds GraphQL query overhead and schema migration cost for data that changes monthly at most.

**Open question — `shortlist_threshold`: per-job, with a per-category default**

The spec states "per-job, with a category default." This note codifies that as: the `screening_scripts` table carries a `shortlist_threshold NUMERIC(5,2)` per script row, which is the category default. The `twenty_job_posting_id` column on `blue_collar_screening` allows a future Workflow C variant to fetch a job-specific override from Twenty's `JobPosting.shortlistThreshold` field (if added). For v1, the script's category-level threshold is the only gate, consistent with the spec's stated default.

---

## 2. V-migrations needed

Current last applied migration: V008.

### V009 — `blue_collar_screening` state table

```sql
-- V009__blue_collar_screening.sql
-- Purpose: per-candidate conversation state for Workflow C's structured Q&A screening.
--   One row per active screening session; Workflow C updates in place on each reply.
--   Keeps multi-step conversation state out of candidate_facts (Workflow B's domain).
-- Author: <implementor>
-- Date: 2026-05-02
-- Spec: docs/02-workflows/c-blue-collar-design-v1.md §2

BEGIN;

CREATE TABLE blue_collar_screening (
  id                    BIGSERIAL    PRIMARY KEY,
  candidate_id          TEXT         NOT NULL,   -- Twenty Candidate UUID
  application_id        TEXT         NOT NULL,   -- Twenty Application UUID
  twenty_job_posting_id TEXT         NOT NULL,   -- Twenty JobPosting UUID
  script_id             TEXT         NOT NULL,   -- FK to screening_scripts.script_id
  question_index        INT          NOT NULL DEFAULT 0,
  answers               JSONB        NOT NULL DEFAULT '{}',
  started_at            TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  last_activity_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  reminder_sent_at      TIMESTAMPTZ,             -- NULL = no reminder sent yet
  status                TEXT         NOT NULL DEFAULT 'in_progress'
                          CHECK (status IN ('in_progress', 'completed', 'withdrawn', 'error')),
  final_score           NUMERIC(5,2),            -- NULL until completed
  strength_tier         TEXT,                    -- NULL until completed; top20|solid|developing|not_a_fit
  created_at            TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- One active session per candidate at a time.
CREATE UNIQUE INDEX uq_blue_collar_screening_active_candidate
  ON blue_collar_screening (candidate_id)
  WHERE status = 'in_progress';

-- Poll index for the 24h reminder sweep and 72h auto-withdraw sweep.
CREATE INDEX idx_blue_collar_screening_active_activity
  ON blue_collar_screening (last_activity_at)
  WHERE status = 'in_progress';

-- Index for the Twenty poll trigger path (scan by application).
CREATE UNIQUE INDEX uq_blue_collar_screening_application
  ON blue_collar_screening (application_id);

COMMIT;

-- Rollback:
--   DROP TABLE blue_collar_screening;
```

### V010 — `screening_scripts` table

```sql
-- V010__screening_scripts.sql
-- Purpose: stores the structured question definitions (script) per job category
--   used by Workflow C. Scripts change rarely (monthly); keeping them in the
--   bookings DB allows prompt updates without a workflow redeploy.
-- Author: <implementor>
-- Date: 2026-05-02
-- Spec: docs/02-workflows/c-blue-collar-design-v1.md §4

BEGIN;

CREATE TABLE screening_scripts (
  script_id            TEXT         PRIMARY KEY,  -- e.g. 'driver_v1', 'warehouse_v1'
  job_category         TEXT         NOT NULL,     -- e.g. 'driver', 'warehouse', 'security'
  version              INT          NOT NULL DEFAULT 1,
  questions            JSONB        NOT NULL,     -- array of question objects (see note below)
  shortlist_threshold  NUMERIC(5,2) NOT NULL DEFAULT 60.00,  -- score >= this → shortlisted
  is_active            BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Only one active script per category at a time.
CREATE UNIQUE INDEX uq_screening_scripts_active_category
  ON screening_scripts (job_category)
  WHERE is_active = TRUE;

COMMIT;

-- Rollback:
--   DROP TABLE screening_scripts;

-- questions JSONB schema:
-- [
--   {
--     "id": "own_transport",
--     "prompt": "Do you own a motorbike or can you use one reliably? (YES / NO)",
--     "type": "yes_no",          -- yes_no | number | enum | free_text | presence_only
--     "weight": 0.30,
--     "scoring": { "yes": 30, "no": 0 },
--     "enum_values": null,       -- populated only for type=enum
--     "tiered_scoring": null     -- for type=number; array of {max, points} ranges
--   },
--   ...
-- ]
```

**Migration sequencing:**

| Version | Table | Apply before |
|---|---|---|
| V009 | `blue_collar_screening` | Workflow C activates |
| V010 | `screening_scripts` | Workflow C activates (and seed data inserted) |

Both must apply before Workflow C's first execution. Seed data for the delivery driver script (from `c-blue-collar.md` spec example) must be INSERTed during or immediately after V010.

---

## 3. New `trigger_kind` values for `screening_inbox`

The existing CHECK constraint on `screening_inbox.trigger_kind` must be relaxed or the new values added via a migration ALTER. Current constraint: `CHECK (trigger_kind IN ('new_application'))`.

**Required new values:**
- `blue_collar_new` — Workflow A or the Twenty poll trigger inserts when a new blue-collar Application is detected. Workflow C picks this up and sends question 0.
- `blue_collar_reply` — Workflow A inserts when an inbound WhatsApp message is a `workflow_reply` intent from a candidate with an active `blue_collar_screening` row (status = `in_progress`).

**V009 or a separate V011 migration** must ALTER the CHECK constraint to include these values:

```sql
ALTER TABLE screening_inbox
  DROP CONSTRAINT screening_inbox_trigger_kind_check,
  ADD CONSTRAINT screening_inbox_trigger_kind_check
    CHECK (trigger_kind IN ('new_application', 'blue_collar_new', 'blue_collar_reply'));
```

This is a small DDL change; it can be bundled into V009 or issued as V011 depending on implementor preference. The constraint is not enforced by n8n — the DB is the only guard.

**Workflow A change required:** the `workflow_reply` branch of `a-communications.json` must:
1. Check whether the candidate has an active `blue_collar_screening` row.
2. If yes: insert `trigger_kind = 'blue_collar_reply'` and the candidate's message body in `payload`.
3. If no: fall through to the existing `new_application` or `open_conversation` path.

The message body must be in `payload` because Workflow C needs the raw reply text to validate the current question's answer.

---

## 4. State machine

```
[Application created with collarType=blue]
  |
  +--[via Workflow A inbound message]---> screening_inbox (trigger_kind=blue_collar_new)
  |                                              |
  +--[via Twenty poll every 5 min]--------> screening_inbox (trigger_kind=blue_collar_new)
                                                 |
                                                 v
                                    [Workflow C Cron poll 60s]
                                                 |
                                    [Claim inbox row FOR UPDATE SKIP LOCKED]
                                                 |
                                    [Redis: acquire hra:conv:{candidateId}]
                                    FAIL --> [mark inbox failed, exit]
                                    ACQUIRED
                                                 |
                                    [Check: blue_collar_screening row exists?]
                                    YES (resume) --> jump to SEND QUESTION
                                    NO  (init)  --> INSERT blue_collar_screening
                                                    question_index=0, answers={}
                                                 |
                                    SEND QUESTION (index = question_index):
                                    [Fetch script from screening_scripts]
                                    [Build question text from script.questions[index]]
                                    [Subflow: wa-send]
                                    [Update blue_collar_screening.last_activity_at]
                                    [Redis: release conv-lock]
                                    [Mark inbox row processed]
                                    [Exit — wait for reply]

                                         ... candidate replies ...

[Workflow A receives reply]
    |
    [Check: active blue_collar_screening row?]
    YES --> INSERT screening_inbox (trigger_kind=blue_collar_reply, payload={messageBody})
    NO  --> existing open_conversation path
    |
    [Release Workflow A conv-lock]

[Workflow C Cron poll 60s claims blue_collar_reply row]
    |
    [Redis: acquire hra:conv:{candidateId}]
    FAIL --> [mark inbox failed, retry next tick]
    ACQUIRED
    |
    [Fetch blue_collar_screening row]
    [Get current question from script (questions[question_index])]
    [Validate / normalise answer]:
      type=yes_no, number, enum, presence_only --> JS Code node (deterministic)
      type=free_text --> Subflow: claude-call (Haiku) → canonical value
    |
    [Answer valid?]
    NO --> [Subflow: wa-send gentle clarifier] --> [Release lock] --> [Mark inbox processed] --> Exit
    YES
    |
    [Store answer: UPDATE blue_collar_screening SET answers[$questionId]=$value,
                         question_index = question_index+1,
                         last_activity_at = NOW()]
    |
    [Last question answered? (question_index >= len(questions))]
    NO --> [Subflow: wa-send next question] --> [Release lock] --> [Mark inbox processed] --> Exit
    YES
    |
    [Code: compute final score (deterministic, see §7)]
    [UPDATE blue_collar_screening SET final_score, strength_tier, status='completed']
    [Twenty mutation: updateApplication(score, scoreBreakdown, status='screened')]
    [Twenty mutation: updateCandidate(strengthTier)]
    [Loop: createCandidateSkillTag for inferred skills]
    [Subflow: wa-send closing message]
    [Create ReviewTask if calibration window OR tier in {top20, solid}]
    [Redis: release conv-lock]
    [Mark inbox row processed]
    Exit

[Separate Workflow C sweep — Cron every 30 min]:
    Scan blue_collar_screening WHERE status='in_progress'
      AND last_activity_at < NOW() - INTERVAL '24 hours'
      AND reminder_sent_at IS NULL
    --> [Subflow: wa-send 24h reminder] --> [UPDATE reminder_sent_at=NOW()]

    Scan blue_collar_screening WHERE status='in_progress'
      AND last_activity_at < NOW() - INTERVAL '72 hours'
    --> [Twenty mutation: updateApplication(status='withdrawn')]
    --> [UPDATE blue_collar_screening SET status='withdrawn']
    --> [Subflow: wa-send withdrawal notice (template)]
```

---

## 5. Two trigger paths (Q2a resolution)

### Path 1 — Workflow A enqueue (inbound-message-triggered)

When a candidate messages and Workflow A determines intent = `new_application` with `JobPosting.collarType=blue`:

```
INSERT INTO screening_inbox (candidate_id, application_id, trigger_kind, payload)
VALUES ($candidateId, $applicationId, 'blue_collar_new', '{"source": "workflow_a"}')
ON CONFLICT ON CONSTRAINT uq_screening_inbox_candidate_active DO NOTHING
```

### Path 2 — Twenty poll trigger (human-creates-Application path)

A separate Workflow C sub-trigger polls Twenty GraphQL every 5 minutes:

```graphql
query FindUninitialisedBlueCollarApplications {
  applications(filter: {
    AND: [
      { status: { eq: "received" } }
      { jobPosting: { collarType: { eq: "blue" } } }
    ]
  }) {
    edges {
      node {
        id
        candidate { id }
        jobPosting { id }
      }
    }
  }
}
```

The result is cross-referenced against `blue_collar_screening.application_id`. Applications not in that table (no active or completed screening row) get an INSERT into `screening_inbox` with `trigger_kind = 'blue_collar_new'`.

**Why 5 minutes**: short enough to feel responsive to an operator creating an Application in Twenty; not so short that it hammers the GraphQL API. The candidate does not receive question 0 immediately — Workflow C's 60s Cron picks it up within one minute of the Twenty poll.

**Deduplication**: the `uq_blue_collar_screening_application` unique index on `blue_collar_screening(application_id)` prevents double-initialisation. The `uq_screening_inbox_candidate_active` partial index on `screening_inbox` prevents double-enqueueing.

---

## 6. Conv-lock acquisition points

| Event | Lock action | Lock key | Token |
|---|---|---|---|
| Workflow C claims inbox row (new or reply) | Acquire (GET → IF empty → SET PX 180000) | `hra:conv:{candidateId}` | `$execution.id` |
| Lock acquire fails | No lock held → mark inbox failed → exit | — | — |
| WA send complete | Release (GET → IF token → DEL) | same | same |
| Answer invalid (clarifier sent) | Release after clarifier send | same | same |
| All questions answered, closing send complete | Release after closing WA send | same | same |
| Error Trigger (any node) | Release (CAS DEL) | same | same |

**Lock TTL: 180s flat** (same as Workflow B and Workflow A v1 — CLAUDE.md invariant #3 footnote: true Lua CAS heartbeat deferred to T2-12).

**Contention handling**: if Workflow A holds the lock (candidate just sent the reply and A hasn't released yet), Workflow C's next 60s Cron tick re-claims the same inbox row (the `claimed_at < NOW() - INTERVAL '5 minutes'` clause from Workflow B's claim query, applied here too). This gives A's lock time to expire.

**Lock is held for the minimum window:** acquire → validate answer (+ optional Haiku call, 5–15s) → send next question → release. The lock is NOT held across the 24h wait between questions.

---

## 7. Scoring algorithm

```javascript
// Input: script (array of question objects), answers (object keyed by question.id)
// Output: { score: number, breakdown: object, strengthTier: string }

function computeScore(script, answers) {
  const breakdown = {};
  let totalScore = 0;

  for (const q of script) {
    const raw = answers[q.id] ?? null;

    if (q.type === 'yes_no') {
      const canonical = normaliseYesNo(raw);  // 'yes' | 'no' | null (Haiku already ran)
      const pts = canonical !== null ? (q.scoring[canonical] ?? 0) : 0;
      breakdown[q.id] = { raw, canonical, pts, weight: q.weight };
      totalScore += pts;

    } else if (q.type === 'number') {
      const n = parseFloat(raw);
      const pts = isNaN(n) ? 0 : scoreNumberTiered(n, q.tiered_scoring);
      breakdown[q.id] = { raw, n, pts, weight: q.weight };
      totalScore += pts;

    } else if (q.type === 'enum') {
      // raw already normalised by Haiku if free-text was given; otherwise direct match
      const canonical = (raw ?? '').toLowerCase();
      const pts = q.scoring[canonical] ?? 0;
      breakdown[q.id] = { raw, canonical, pts, weight: q.weight };
      totalScore += pts;

    } else if (q.type === 'presence_only') {
      const present = raw !== null && String(raw).trim().length > 0;
      const maxPts = Object.values(q.scoring)[0] ?? 5;
      const pts = present ? maxPts : 0;
      breakdown[q.id] = { raw, present, pts, weight: q.weight };
      totalScore += pts;

    } else if (q.type === 'free_text') {
      // After Haiku normalisation, stored as canonical value in answers.
      // Scored via presence_only unless script provides explicit scoring keys.
      if (q.scoring === 'presence_only') {
        const present = raw !== null && String(raw).trim().length > 0;
        const pts = present ? 5 : 0;
        breakdown[q.id] = { raw, present, pts, weight: q.weight };
        totalScore += pts;
      } else {
        const canonical = (raw ?? '').toLowerCase();
        const pts = q.scoring[canonical] ?? 0;
        breakdown[q.id] = { raw, canonical, pts, weight: q.weight };
        totalScore += pts;
      }
    }
  }

  const tier = scoreToTier(totalScore);
  return { score: totalScore, breakdown, strengthTier: tier };
}

function scoreNumberTiered(n, ranges) {
  // ranges: array of { max: number, points: number }, sorted ascending by max
  for (const range of ranges) {
    if (n <= range.max) return range.points;
  }
  return ranges[ranges.length - 1]?.points ?? 0;
}

function scoreToTier(score) {
  if (score >= 80) return 'top20';
  if (score >= 60) return 'solid';
  if (score >= 40) return 'developing';
  return 'not_a_fit';
}
```

The `shortlist_threshold` from `screening_scripts` governs Workflow H eligibility: `score >= shortlist_threshold AND status != 'selected' → reEngagementEligible=true`.

---

## 8. Claude Haiku call contract

**When used:** only for `type: free_text` questions where the answer needs canonical mapping (e.g. "I drive okada every day" → `yes` for `own_transport`).

**Input shape (to `claude-call` subflow):**

```json
{
  "model": "claude-haiku-4-5",
  "workflowName": "workflow_c_screening_normalise",
  "systemPrompt": "You are a normaliser for a structured HR screening system. You receive a candidate's raw WhatsApp reply to a specific question and must return a single canonical value. Return ONLY the canonical value — no explanation, no punctuation, no extra text. If you cannot determine the answer, return the exact string: UNCLEAR",
  "messages": [
    {
      "role": "user",
      "content": "Question: [question prompt]\nExpected answer type: [type]\nValid values (if applicable): [enum_values or yes/no]\nCandidate reply: [raw answer]\n\nReturn the canonical value."
    }
  ]
}
```

**Output shape (from `claude-call` subflow):**

The subflow returns `content[0].text` as a plain string. The Code node post-processing trims whitespace and validates:

```javascript
const canonical = response.trim().toLowerCase();
if (canonical === 'unclear') {
  // trigger clarifier path — do NOT advance question_index
  return [{ json: { valid: false, canonical: null } }];
}
// For yes_no: accept 'yes', 'no'
// For enum: accept any value in q.enum_values
// For free_text presence_only: any non-empty non-UNCLEAR is valid
```

**Failure handling:**

| Failure | Action |
|---|---|
| Haiku returns `UNCLEAR` | Send gentle clarifier: "Sorry, I didn't quite get that. [question prompt]" Do not advance. |
| Haiku returns unrecognised enum value | Treat as `UNCLEAR` — send clarifier. |
| `claude-call` subflow times out or errors | Log to `workflow_errors`. Mark inbox row failed. Release conv-lock. On retry, Workflow C re-sends the same question (idempotent via question_index). |
| Budget gate returns empty (claude-call) | Same as timeout error. ReviewTask `WORKFLOW_ERROR` created. |

**Silent-failure edge cases:**
- Haiku may confidently return a plausible but wrong canonical (e.g. misreading sarcasm). Mitigation: the deterministic scoring is forgiving — a wrong `yes_no` loses at most the question's weight, not the entire score.
- Haiku may return a value that passes validation but encodes meaning differently (e.g. "no" when candidate meant "not yet, but soon"). This is an inherent ambiguity in free-text screening; the calibration window's human review catches systematic bias.
- Pidgin replies to English prompts: Haiku 4.5 handles Ghanaian Pidgin well for short utterances. Unknown local-language replies (not English, not Pidgin) should produce `UNCLEAR`, triggering the clarifier. Per CLAUDE.md invariant #5, these are not force-transcribed; the clarifier is the right response.

---

## 9. Error paths

### 9.1 Lock contention

Workflow C attempts to acquire `hra:conv:{candidateId}` and the key already exists (Workflow A is mid-processing, or a prior C execution crashed without releasing):

- Mark inbox row failed (do NOT set `processed_at`; leave row for re-claim).
- Do NOT send any WhatsApp message.
- Next 60s Cron tick re-claims via the `claimed_at < NOW() - INTERVAL '5 minutes'` stale-claim clause.
- If lock expires (180s) before C retries, the next C execution succeeds.

### 9.2 Haiku normalisation failure

Covered in §8 above. The key invariant: `question_index` is NOT incremented on an `UNCLEAR` result. The candidate receives the same question again as a gentle clarifier. A candidate who triggers `UNCLEAR` 3 times in a row on the same question does NOT auto-withdraw — the counter is soft; a human ReviewTask is created after 3 consecutive UNCLEAR results on the same question (log `workflow_c_interpretation_failures_total` metric).

### 9.3 All questions answered but Twenty mutation fails

The `final_score` and `strength_tier` are written to `blue_collar_screening` before the Twenty mutations. If `updateApplication` or `updateCandidate` fails:

- Error Trigger fires.
- `workflow_errors` row written.
- Conv-lock released.
- `blue_collar_screening.status` remains `in_progress` (NOT set to `completed`).
- Next Cron tick re-claims the row (if inbox row is not yet processed — it won't be if the error happened before `processed_at` was set).
- Workflow C re-runs the completion path (re-applies same score to Twenty — idempotent, `updateApplication` is a PUT-style operation).

### 9.4 24h reminder

The reminder sweep (separate Cron, every 30 min) queries:

```sql
SELECT * FROM blue_collar_screening
WHERE status = 'in_progress'
  AND last_activity_at < NOW() - INTERVAL '24 hours'
  AND reminder_sent_at IS NULL;
```

For each row: acquire conv-lock, send reminder via `wa-send`, set `reminder_sent_at = NOW()`, release lock.

The reminder is a WhatsApp **template message** (24h service window may be closed). Template: `still_interested_10d` is not appropriate here — a separate `screening_reminder_24h` template should be submitted for approval (pending; track as pre-launch blocker). If the template is not yet approved, the reminder is skipped and logged to `workflow_errors` as a warning-level event — NOT a hard failure.

### 9.5 72h auto-withdraw

The auto-withdraw sweep (same 30-min Cron, separate query):

```sql
SELECT * FROM blue_collar_screening
WHERE status = 'in_progress'
  AND last_activity_at < NOW() - INTERVAL '72 hours';
```

For each row:
1. `UPDATE blue_collar_screening SET status = 'withdrawn'`.
2. `Twenty mutation: updateApplication(status = 'withdrawn')`.
3. Send withdrawal notice via `wa-send` (template: new `screening_withdrawn_72h` template needed — pre-launch blocker).
4. Log `workflow_c_auto_withdrawn_total` metric.

### 9.6 No-send error: WhatsApp template not approved

If a required template (`screening_reminder_24h`, `screening_withdrawn_72h`) is rejected or not yet approved by Meta:

- Skip the WA send.
- Log to `workflow_errors` (level=warning).
- Create a ReviewTask `kind=WORKFLOW_ERROR` with description "WhatsApp template not approved: [template name]".
- Continue processing (do not halt the sweep).

---

## 10. Node graph

Workflow C has three distinct execution contexts:

### Context 1 — Main screening processor (60s Cron)

```
[Cron Trigger every 60s]
    |
[Postgres: claim oldest unprocessed inbox row (blue_collar_new OR blue_collar_reply)]
    |               |
  ZERO             ONE
  [exit]            |
                [Redis: acquire conv-lock hra:conv:{candidateId}]
                    |              |
                  FAIL          ACQUIRED
                    |              |
                [mark inbox    [Postgres: fetch blue_collar_screening row]
                 failed]           |              |
                [exit]         EXISTS         NOT EXISTS
                                   |              |
                            (reply path)    (init path)
                               |                  |
                         [Fetch script]      [Fetch script via
                         [Get current q]      twenty_job_posting_id]
                               |              [INSERT blue_collar_screening]
                               |              [Send question 0]
                               |                  |
                        [Extract messageBody       |
                         from payload.messageBody] |
                               |              (join)
                        [Validate answer]:
                          type != free_text --> [Code: deterministic validation]
                          type == free_text --> [Subflow: claude-call (Haiku)]
                               |              |
                            VALID          INVALID / UNCLEAR
                               |              |
                        [Code: store answer]  [Subflow: wa-send clarifier]
                        [Increment            [Update last_activity_at]
                         question_index]       [Release lock]
                               |              [Mark inbox processed]
                        [Last question?]       [Exit]
                          NO      YES
                          |        |
                   [wa-send  [Code: computeScore]
                    next q]   [UPDATE blue_collar_screening
                          |    SET final_score, strength_tier, status='completed']
                          |   [Twenty: updateApplication]
                          |   [Twenty: updateCandidate]
                          |   [Loop: createCandidateSkillTag]
                          |   [Subflow: wa-send closing message]
                          |   [If: calibration window OR tier in {top20, solid}]
                          |       YES --> [Twenty: createReviewTask SCORE_REVIEW]
                          |   [Release conv-lock]
                          |   [Mark inbox processed]
                   (join)  |   [Exit]
                          |
                   [Update last_activity_at]
                   [Release conv-lock]
                   [Mark inbox processed]
                   [Exit]


─── Error Trigger ──────────────────────────────────────────────────────────────

[Error Trigger]
    |
[Redis: release conv-lock (CAS DEL — only if held)]
    |
[Postgres: write workflow_errors — array-form queryReplacement (rule #18)]
    |
[Postgres: mark inbox row failed (leave processed_at NULL)]
    |
[If: attempt < 3]
    YES → [exit — Cron re-claims next tick]
    NO  → [Twenty: createReviewTask kind=WORKFLOW_ERROR subjectApplication=appId dueBy=NOW()+4h]
          [exit]
```

### Context 2 — Twenty poll trigger (every 5 minutes)

```
[Cron Trigger every 5 min]
    |
[Twenty GraphQL: query applications(status=received, collarType=blue)]
    |
[Postgres: query blue_collar_screening for known application_ids]
    |
[Code: find applications NOT in blue_collar_screening]
    |
[For each new application: INSERT screening_inbox (trigger_kind=blue_collar_new)]
    |   -- ON CONFLICT (candidate_id) WHERE processed_at IS NULL DO NOTHING
[Exit]
```

### Context 3 — Reminder + auto-withdraw sweep (every 30 minutes)

```
[Cron Trigger every 30 min]
    |
[Postgres: query 24h no-activity, reminder_sent_at IS NULL]
    |
[For each: acquire lock, wa-send reminder template, set reminder_sent_at, release]
    |
[Postgres: query 72h no-activity, status=in_progress]
    |
[For each: acquire lock, UPDATE status=withdrawn, Twenty updateApplication(withdrawn),
           wa-send withdrawal template, release lock, log metric]
[Exit]
```

**Subflows reused from Workflows A + B:**
1. `claude-call` — model routing, budget gate, `ai_call_log` write. One invocation per `free_text` answer (Haiku).
2. `wa-send` — 24h service window enforcement, template fallback.

**No new subflows** for Workflow C v1.

---

## 11. Twenty GraphQL writes

Same pattern as Workflow B (ADR-0005, invariant #1). Resolver names follow the no-`One`-infix convention.

```graphql
# Mark Application screened after all questions answered
mutation UpdateApplication(
  $id: ID!, $score: Float!, $scoreBreakdown: String!, $status: String!
) {
  updateApplication(id: $id, data: {
    score: $score
    scoreBreakdown: $scoreBreakdown   # JSON-stringified per Workflow B OQ-8 pattern
    status: $status                    # 'screened'
  }) { id }
}

# Update Candidate tier
mutation UpdateCandidate($id: ID!, $strengthTier: String!, $reEngagementEligible: Boolean!) {
  updateCandidate(id: $id, data: {
    strengthTier: $strengthTier
    reEngagementEligible: $reEngagementEligible
  }) { id }
}

# Mark withdrawn
mutation WithdrawApplication($id: ID!) {
  updateApplication(id: $id, data: { status: "withdrawn" }) { id }
}

# Upsert skill tag (one per inferred skill, looped)
mutation CreateCandidateSkillTag(
  $candidateId: ID!, $skillTagId: ID!, $source: String!
) {
  createCandidateSkillTag(data: {
    candidate: { connect: { id: $candidateId } }
    skillTag:  { connect: { id: $skillTagId } }
    source:    $source                           # 'blue_collar_screening'
  }) { id }
}

# ReviewTask — subjectApplication (rule #11)
mutation CreateReviewTask(
  $applicationId: ID!, $kind: String!, $dueBy: DateTime!
) {
  createReviewTask(data: {
    subjectApplication: { connect: { id: $applicationId } }
    kind:   $kind
    dueBy:  $dueBy
    status: "OPEN"
  }) { id }
}
```

**reEngagementEligible logic:** `score >= script.shortlist_threshold AND application.status != 'selected'` → set to `true`. This feeds Workflow H. Computed in the Code node after final scoring.

---

## 12. Calibration gate

Identical pattern to Workflow B §12. Env var: `WORKFLOW_C_LAUNCH_DATE` (ISO-8601). If unset, calibration is ON (fail-safe). Calibration ON: every completed screening → ReviewTask `SCORE_REVIEW`. Calibration OFF: only `top20` and `solid` tiers get a review task.

---

## 13. n8n rule trap-points

Workflow-builder must apply these rules from `.claude/rules/n8n-workflows.md`:

- **Rule #18** — array-form `queryReplacement` for all Postgres nodes writing user-supplied or system text (answer bodies, error messages). The `answers` JSONB and `error_message` columns are the primary targets.
- **Rule #19** — `workflowInputs.value` resourceMapper for all Execute Workflow (claude-call, wa-send) nodes.
- **Rule #20** — `typeVersion: 3.4` on every Set node.
- **Rule #22** — no intermediate Set node re-references; read from producing node directly. `candidateId` from inbox claim Postgres node; `messageBody` from inbox `payload.messageBody`; `questionIndex` from the `blue_collar_screening` fetch Postgres node.
- **Rule #24** — `alwaysOutputData: true` at node root level (not inside `parameters.options`) on any Postgres node that may return zero rows: the inbox claim query, the `blue_collar_screening` fetch, the 24h/72h sweep queries.
- **Rule #25** — add all three Workflow C files to `scripts/patch-workflow-ids.sh`'s file list before commit.
- **Rule #13** — `workflow_errors` NOT NULL bindings: `workflow_name`, `execution_id`, `error_message`. Use array-form queryReplacement.
- **Rule #11** — every `ReviewTask` write sets `subjectApplication`, not `subjectCandidate`.

---

## 14. Acceptance criteria mapping

| Spec criterion | Design coverage |
|---|---|
| Full pass: all 6 questions answered, final score matches spec, tier correct | §7 scoring algorithm; tester verifies with driver script sample data |
| Mid-stream disconnect: 24h reminder fires once, 72h auto-withdraw fires once, no spam | §9.4 + §9.5 sweep; `reminder_sent_at` guards double-send |
| 50 parallel candidates, no cross-talk, all scores correct | V009 unique index per application; per-candidate conv-lock; inbox FIFO |
| Re-interpretation: "I drive okada every day" → YES | §8 Haiku call with `own_transport` prompt; `valid: true, canonical: 'yes'` |
| Pidgin reply to English prompt continues without breakage | §8 edge cases; Haiku handles Pidgin for short utterances; `UNCLEAR` → clarifier |

---

## 15. Open questions — RESOLVED

All four design questions are resolved in §1. No remaining open questions block workflow-builder dispatch.

**Pre-launch blockers (not blocking workflow-builder, but blocking go-live):**
1. WhatsApp template `screening_reminder_24h` — draft, submit to Meta for approval.
2. WhatsApp template `screening_withdrawn_72h` — draft, submit to Meta for approval.
3. Seed data INSERT for delivery driver script in V010 migration.
4. Workflow A change: `workflow_reply` branch must check `blue_collar_screening` and route `trigger_kind = 'blue_collar_reply'`.
5. CHECK constraint ALTER on `screening_inbox.trigger_kind` to add new values.

---

## 16. Design decisions and trade-offs

**1. Dedicated state table vs. `candidate_facts` JSONB.** Separate table chosen (Q1). Trade-off: one more V-migration. Win: no write conflict risk between Workflow B (CV facts) and Workflow C (Q&A state); explicit schema makes the state machine readable in SQL; `question_index` and `status` are indexable for sweep queries.

**2. Dual trigger path.** Twenty poll added (Q2a). Trade-off: a second Cron workflow running every 5 minutes hitting the Twenty GraphQL API. Win: the human-creates-Application path is fully handled without requiring a Twenty webhook (which violates invariant #2 — no action-button webhooks). The 5-minute poll adds at most 5 minutes of latency on the human-created path, which is acceptable.

**3. Short-lived lock per reply.** Confirmed (Q2b). Trade-off: Workflow A must detect the blue-collar routing context. Win: no long-lived n8n execution; lock TTL is short; pattern is consistent with Workflow B.

**4. Haiku for free_text only.** Confirmed (Q3). Trade-off: `UNCLEAR` returns require a second round-trip. Win: structured types (yes_no, number, enum, presence_only) have zero LLM latency and zero LLM cost. Haiku is 10× cheaper than Sonnet; the total per-candidate LLM cost is bounded by the number of `free_text` questions in the script (typically 1–2).

**5. Scripts in bookings DB.** Chosen (Q4). Trade-off: an extra Postgres query per screening session to fetch the script. Win: script changes go live without a workflow redeploy; scripts are versioned via `version INT` and `is_active BOOLEAN`; a script can be hot-swapped (deactivate old row, insert new) without touching n8n. Hard-coded (Option A) is faster but unacceptable for a live 200-candidates/day system.

**6. No new subflows.** C reuses A's `claude-call` and `wa-send`. Consistent with Workflow B's design decision #7.
