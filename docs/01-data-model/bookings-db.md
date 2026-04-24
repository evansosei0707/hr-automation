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

## Retention

- `slot` rows are soft-kept forever; we use them for analytics. After 3 years, archive to cold storage.
- `booking_event_log` is kept for 2 years, then pruned.
- `workflow_errors` is kept for 1 year.

Prune jobs run nightly in the Orchestration workflow.
