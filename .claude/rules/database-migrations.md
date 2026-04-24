# Rule — when touching `database/migrations/`

Load this rule when creating or editing files under `database/migrations/`.

## Conventions

1. **Filename:** `VNNN__description_in_snake_case.sql`. NNN is zero-padded and monotonically increasing. Never reuse a number.

2. **Append-only.** Once a migration has been applied anywhere (even locally), do not edit its content. Write a new migration to correct.

3. **Each migration is one logical change.** Do not bundle "add table X + fix bug Y + add index Z" into one file. Splitting makes rollback practical.

4. **Every migration must include:**
   - A leading comment block: purpose, author, date, related spec doc.
   - The DDL itself.
   - A rollback comment block at the bottom describing what would undo it (even if "undo" is best-effort).

5. **Defaults and NOT NULL.**
   - New columns are `NOT NULL` only if a `DEFAULT` is provided or the table is empty.
   - Dates and timestamps default to `NOW()` when appropriate.
   - Boolean columns have explicit defaults.

6. **Indexes are named:** `CREATE INDEX idx_<table>_<cols>` or `CREATE UNIQUE INDEX uq_<table>_<cols>`.

7. **Foreign keys:**
   - Explicit `ON DELETE` semantics. Default to `RESTRICT` for anything referencing candidate data; `CASCADE` is rare.
   - Named constraints: `CONSTRAINT fk_<table>_<target>_<col>`.

8. **Transactions.** Wrap multi-statement migrations in `BEGIN; ... COMMIT;`. Single DDL statements typically run implicitly wrapped by the migration runner; still wrap explicitly for clarity.

9. **No DROP in migrations** without an ADR. Dropping a column or table is a reversible-only-from-backup operation; it needs a review record.

10. **Test in local first.** The workflow is: write migration → apply to local bookings DB → verify with a SELECT → commit. Never commit a migration you haven't seen execute.

## Applying

```
./scripts/migrate-bookings-db.sh
```

The script applies any new migration files in order. The `schema_migrations` table in the bookings DB records what's applied.

## A skeleton migration

```sql
-- V007__add_candidate_opt_out_flag.sql
-- Purpose: support the DATA_MINIMAL reply from candidates who want to stay in the system
--          but opt out of re-engagement messages.
-- Author: <name / agent>
-- Date: YYYY-MM-DD
-- Spec: docs/02-workflows/h-job-alerts.md §"Anti-spam cooldown"

BEGIN;

ALTER TABLE candidate_facts
  ADD COLUMN re_engagement_opt_out BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX idx_candidate_facts_opt_out
  ON candidate_facts (re_engagement_opt_out)
  WHERE re_engagement_opt_out = TRUE;

COMMIT;

-- Rollback:
--   ALTER TABLE candidate_facts DROP COLUMN re_engagement_opt_out;
--   (will fail if any workflow references it — fix the workflow first)
```
