# Bookings Database (n8n-Owned)

A separate Postgres instance dedicated to interview slot management. Owned by n8n, never by Twenty.

## Why it exists

Two invariants force this design:

1. **No direct writes to Twenty's DB.** Twenty is accessed via GraphQL only.
2. **Slot claiming must be atomic.** Two candidates cannot accidentally book the same slot. Twenty's GraphQL API, as of v0.x, does not expose the primitives we need for a race-free claim (row-level lock, `SELECT … FOR UPDATE`).

So we own this one database. n8n writes; n8n reads; Twenty never touches it. The link back to Twenty is a `twenty_interview_id` column that we update via GraphQL once a booking is confirmed.

## Connection

- Host: `bookings-db` on the Docker network
- Port: 5432
- Database: `bookings`
- User: `n8n_bookings`
- Password: from env `BOOKINGS_DB_PASSWORD`

Only n8n should connect. Migrations run as a one-shot container via `scripts/migrate-bookings-db.sh`.

## Schema

Current tables, in the order they were introduced. New tables go through a migration file under `database/migrations/`.

### `interviewer`

```sql
CREATE TABLE interviewer (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  twenty_user_id TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  timezone TEXT NOT NULL DEFAULT 'Africa/Accra',
  google_calendar_id TEXT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### `slot`

A proposed interview slot, pending or booked.

```sql
CREATE TABLE slot (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  interviewer_id UUID NOT NULL REFERENCES interviewer(id),
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
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX slot_no_double_claim
  ON slot (interviewer_id, starts_at)
  WHERE status IN ('offered','claimed');

CREATE INDEX slot_lookup ON slot (status, starts_at);
```

The partial unique index is the teeth: it guarantees that for a given interviewer at a given start time, only one offered-or-claimed slot can exist. Any attempt to create a second one fails at the database level, not at the application level.

### `booking_event_log`

Every state transition on a slot. Append-only.

```sql
CREATE TABLE booking_event_log (
  id BIGSERIAL PRIMARY KEY,
  slot_id UUID NOT NULL REFERENCES slot(id),
  event_type TEXT NOT NULL,
  actor TEXT NOT NULL, -- n8n workflow name
  payload JSONB,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### `workflow_errors`

Shared with all n8n workflows. Any workflow that catches an exception in its error branch writes here.

```sql
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

CREATE INDEX workflow_errors_unack ON workflow_errors (occurred_at) WHERE acknowledged_at IS NULL;
```

## The atomic claim pattern

The core of workflow D. When a candidate replies YES to a slot offer, we do this in a single transaction:

```sql
BEGIN;

UPDATE slot
SET
  status = 'claimed',
  claimed_by_application_id = $1,
  claimed_at = NOW(),
  updated_at = NOW()
WHERE
  id = $2
  AND status = 'offered'
  AND offered_to_application_id = $1
  AND offer_expires_at > NOW();

-- Exactly one row affected means success. Zero means the offer expired,
-- was withdrawn, or someone else got in first. We never overwrite.

INSERT INTO booking_event_log (slot_id, event_type, actor, payload)
VALUES ($2, 'claim_attempt', $3, $4);

COMMIT;
```

The workflow checks `rowcount` on the UPDATE. If 1, we proceed to update Twenty via GraphQL and notify the candidate. If 0, we tell the candidate their preferred slot is no longer available and offer the next two.

## Why an UPDATE-with-WHERE, not SELECT-FOR-UPDATE

Both would work. UPDATE-with-guarded-WHERE is:
- Simpler to express correctly across n8n's node types.
- Inherently idempotent: if the update runs twice, the second run is a no-op.
- Safe against accidental long-held locks from a hanging n8n execution.

The partial unique index above guards against the belt-and-braces case where two concurrent UPDATEs both match: at most one can succeed.

### `screening_inbox`

Hand-off queue for Workflow B (white-collar) and Workflow C (blue-collar). Workflow A writes a row when it detects a candidate who needs CV screening or blue-collar Q&A screening. Workflow B/C polls every 60 seconds, claims one unclaimed row with `FOR UPDATE SKIP LOCKED`, and processes it.

```sql
CREATE TABLE screening_inbox (
  id             BIGSERIAL    PRIMARY KEY,
  candidate_id   TEXT         NOT NULL,   -- Twenty Candidate UUID
  application_id TEXT,                    -- Twenty Application UUID; NULL for v1 white-collar path
  trigger_kind   TEXT         NOT NULL
                   CHECK (trigger_kind IN (
                     'new_application',
                     'open_conversation',
                     'blue_collar_new',
                     'blue_collar_reply'
                   )),
  payload        JSONB,
  claimed_by     TEXT,                    -- n8n execution ID
  claimed_at     TIMESTAMPTZ,
  processed_at   TIMESTAMPTZ,
  error_message  TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

`trigger_kind` values:

| Value | Written by | Consumed by |
|---|---|---|
| `new_application` | Workflow A (white-collar new application path) | Workflow B |
| `open_conversation` | Workflow A (open conversation intent) | Workflow B |
| `blue_collar_new` | Workflow A or Workflow C's 5-min Twenty poll | Workflow C |
| `blue_collar_reply` | Workflow A (reply from candidate with active blue-collar session) | Workflow C |

Migrations: V008 (table creation), V011 (expanded `trigger_kind` CHECK).

### `blue_collar_screening`

Per-candidate conversation state for Workflow C's structured Q&A screening (blue-collar roles). One row per screening session. Workflow C updates the row in place on each candidate reply: advancing `question_index`, accumulating `answers`, and writing `final_score` + `strength_tier` when all questions are answered.

Introduced by: V009 (2026-05-02).

```sql
CREATE TABLE blue_collar_screening (
  id                    BIGSERIAL    PRIMARY KEY,
  candidate_id          TEXT         NOT NULL,   -- Twenty Candidate UUID
  application_id        TEXT         NOT NULL,   -- Twenty Application UUID
  twenty_job_posting_id TEXT         NOT NULL,   -- Twenty JobPosting UUID
  script_id             TEXT         NOT NULL,   -- references screening_scripts.script_id (no physical FK)
  question_index        INT          NOT NULL DEFAULT 0,
  answers               JSONB        NOT NULL DEFAULT '{}',
  started_at            TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  last_activity_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  reminder_sent_at      TIMESTAMPTZ,             -- NULL = no reminder sent yet
  status                TEXT         NOT NULL DEFAULT 'in_progress'
                          CHECK (status IN ('in_progress','completed','withdrawn','error')),
  final_score           NUMERIC(5,2),            -- NULL until status = 'completed'
  strength_tier         TEXT,                    -- NULL until completed; top20|solid|developing|not_a_fit
  created_at            TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
```

Indexes:

| Index | Type | Columns / Predicate | Purpose |
|---|---|---|---|
| `uq_blue_collar_screening_active_candidate` | UNIQUE | `(candidate_id) WHERE status='in_progress'` | One active session per candidate |
| `idx_blue_collar_screening_active_activity` | INDEX | `(last_activity_at) WHERE status='in_progress'` | 24h reminder and 72h withdraw sweeps |
| `uq_blue_collar_screening_application` | UNIQUE | `(application_id)` | One session per Application; guards duplicate Twenty-poll inserts |
| `idx_blue_collar_screening_status` | INDEX | `(status, last_activity_at)` | Composite sweep query efficiency |

`answers` JSONB shape: `{ "<question_id>": "<canonical_value>", ... }` — one key per answered question, keyed by `screening_scripts.questions[n].id`.

`strength_tier` values align with Workflow B: `top20`, `solid`, `developing`, `not_a_fit`. Candidates with `final_score >= shortlist_threshold` are eligible for Workflow H re-engagement.

### `screening_scripts`

Structured question definitions used by Workflow C. Scripts change rarely (monthly at most); storing them here allows prompt and scoring updates without a workflow redeploy. Exactly one active script per `job_category` is enforced by a partial unique index.

Introduced by: V010 (2026-05-02).

```sql
CREATE TABLE screening_scripts (
  script_id            TEXT         PRIMARY KEY,
  job_category         TEXT         NOT NULL,
  version              INT          NOT NULL DEFAULT 1,
  questions            JSONB        NOT NULL,
  shortlist_threshold  NUMERIC(5,2) NOT NULL DEFAULT 60.00,
  is_active            BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX uq_screening_scripts_active_category
  ON screening_scripts (job_category)
  WHERE is_active = TRUE;
```

`questions` JSONB is an array of question objects. Each object carries:

| Field | Type | Notes |
|---|---|---|
| `id` | string | Unique within script; used as key in `blue_collar_screening.answers` |
| `prompt` | string | WhatsApp message text sent to the candidate |
| `type` | string | `yes_no`, `number`, `enum`, `free_text` |
| `weight` | number | Informational fraction; scoring drives actual points |
| `scoring` | object or `"presence_only"` | Map of canonical value → points; `"presence_only"` for free-text presence check |
| `enum_values` | array or null | Valid string values for `type=enum` |
| `tiered_scoring` | array or null | `[{max, points}, ...]` for `type=number`; `max=null` = unbounded upper tier |

**Seed data:** `driver_v1` (delivery driver, `job_category='driver'`) is inserted by V010 as an idempotent `ON CONFLICT DO NOTHING` INSERT. To hot-swap a script: set `is_active=FALSE` on the old row, insert the new row with `is_active=TRUE`.

## Retention

- `slot` rows are soft-kept forever; we use them for analytics. After 3 years, archive to cold storage.
- `booking_event_log` is kept for 2 years, then pruned.
- `workflow_errors` is kept for 1 year.
- `blue_collar_screening` rows are retained indefinitely for analytics and audit. Completed/withdrawn rows older than 2 years may be archived to cold storage.
- `screening_scripts` rows are never deleted (append-only versioning via `is_active` flag).

Prune jobs run nightly in the Orchestration workflow.
