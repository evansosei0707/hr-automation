# Twenty Schema — versioned migrations for custom objects and fields

Custom objects and field definitions for our Twenty workspace, expressed as versioned JSON migrations and applied via the Twenty Metadata GraphQL API.

**Authoritative spec for what the schema looks like:** [`docs/01-data-model/twenty-crm-schema.md`](../docs/01-data-model/twenty-crm-schema.md).
**Authoritative spec for the v2.1.0 API surface (mutation shapes, field types):** [`reference/twenty-v2.1.0-api.md`](../reference/twenty-v2.1.0-api.md).
**Decision record:** [ADR-0005](../docs/05-decisions/ADR-0005-twenty-v2-migration.md).

## Why migrations, not the UI

Twenty supports custom objects and fields via its UI. UI-only changes are:
- Not reviewable in code review.
- Not idempotent across environments (local, staging, production).
- Not version-controlled.

Versioned migration files give us diff-able history, replayability into a fresh workspace, and review-as-code parity with our bookings DB migrations.

## Layout

```
twenty-schema/
├── README.md                       # this file
├── migrations/
│   ├── V001__init_core_objects.json
│   ├── V002__add_skill_tags.json
│   └── ...
└── (objects/ — DEPRECATED, removed; the v0.60-era TS approach does not apply to v2)
```

## Migration file format

Each migration is a single JSON document:

```json
{
  "version": "V001",
  "description": "Initial custom objects: Candidate, JobPosting, Application",
  "author": "schema-designer",
  "date": "2026-04-26",
  "operations": [
    {
      "kind": "createObject",
      "input": {
        "nameSingular": "candidate",
        "namePlural": "candidates",
        "labelSingular": "Candidate",
        "labelPlural": "Candidates",
        "icon": "IconUser",
        "skipNameField": false,
        "isLabelSyncedWithName": false
      }
    },
    {
      "kind": "createField",
      "input": {
        "objectName": "candidate",
        "name": "whatsappNumber",
        "label": "WhatsApp Number",
        "type": "PHONES",
        "icon": "IconBrandWhatsapp"
      }
    },
    {
      "kind": "createField",
      "input": {
        "objectName": "candidate",
        "name": "consentStatus",
        "label": "Consent Status",
        "type": "SELECT",
        "options": [
          { "value": "pending", "label": "Pending", "color": "orange", "position": 0 },
          { "value": "granted", "label": "Granted", "color": "green",  "position": 1 },
          { "value": "refused", "label": "Refused", "color": "red",    "position": 2 },
          { "value": "revoked", "label": "Revoked", "color": "gray",   "position": 3 }
        ],
        "defaultValue": "\"pending\""
      }
    },
    {
      "kind": "createField",
      "input": {
        "objectName": "application",
        "name": "candidate",
        "label": "Candidate",
        "type": "RELATION",
        "relationCreationPayload": {
          "type": "MANY_TO_ONE",
          "targetObjectName": "candidate",
          "targetFieldLabel": "Applications",
          "targetFieldIcon": "IconBriefcase"
        }
      }
    }
  ]
}
```

### Operation kinds

| `kind` | Maps to | Notes |
|---|---|---|
| `createObject` | `createOneObject` mutation on `/metadata` | `skipNameField` and `isLabelSyncedWithName` default to false if omitted. |
| `createField` | `createOneField` mutation on `/metadata` | `input.objectName` is resolved to the object's UUID at apply time. For RELATION fields, `relationCreationPayload.targetObjectName` is also resolved to a UUID. SELECT/MULTI_SELECT options are inline. |
| `updateObject` | `updateOneObject` mutation | Use `nameSingular` to identify the target. Field deletions/renames are NOT permitted via this script — see Rules below. |

`updateField`, `deleteObject`, `deleteField` are intentionally **not implemented**. Field deletions go through a manual review per rules below.

## Apply script — `scripts/apply-twenty-schema.sh`

### Inputs

- **Env vars** (read from `infrastructure/.env`):
  - `TWENTY_API_KEY` — JWT bearer token for an API key bound to a Role with `DATA_MODEL` permission. Required.
  - `TWENTY_API_BASE_URL` — base URL for the Twenty server (e.g. `http://localhost:3000`). Required.
  - Bookings DB credentials (for the migration tracker) — same vars n8n uses.
- **Migration files** — `twenty-schema/migrations/V*.json`, applied in numeric version order.

### Behaviour (what the script does)

1. **Preflight checks.** Verify env vars present. Verify reachability: `GET ${TWENTY_API_BASE_URL}/healthz` → 200. Verify auth: `POST /metadata` with a trivial query. Verify bookings DB reachable.
2. **Ensure tracker table exists.** Create `twenty_schema_migrations` in the bookings DB if it does not exist (see schema below).
3. **Load existing state.** `GET /rest/metadata/objects` → all custom objects + their fields with UUIDs. Cached in memory for the rest of the run.
4. **Determine pending migrations.** Read the tracker; compare to files in `migrations/`; pending set = files whose `version` is not in the tracker, in version order.
5. **For each pending migration, in order:**
   a. Begin a logical batch (no DB transaction; Twenty's metadata API has no batch).
   b. For each operation:
      - Resolve any `objectName` / `targetObjectName` strings to UUIDs (from cached state, or from objects created earlier in the same migration).
      - Issue the corresponding mutation against `/metadata` with `Authorization: Bearer ${TWENTY_API_KEY}`.
      - Update the in-memory state cache with the result.
   c. On any error: log the error with `{version, operationIndex, kind, input, errorMessage}`, write a row to `bookings_db.workflow_errors`, and **exit non-zero**. Do NOT mark the migration applied.
   d. On success: insert a row into `twenty_schema_migrations` with `{version, applied_at, operations_count, applied_by}`.
6. **Print summary** of applied migrations.

### Conflict handling

- **Idempotent re-runs.** Re-running the script after a successful apply is a no-op. The tracker prevents replay; even if the tracker were lost, the existence checks against Twenty's actual schema (step 3) prevent duplicate creation — though the script will surface this as a warning rather than silently succeeding, because a missing tracker row indicates state drift worth investigating.
- **Fail-fast within a migration.** If operation N of migration V005 fails, V005 is NOT marked applied. Operations 1..N-1 may have succeeded against Twenty (Twenty has no transactional metadata API). The fix: identify which operations succeeded (via `GET /rest/metadata/objects`), edit the migration file to remove the already-applied ops, fix the failing op, and re-run. Then on success, the migration is marked applied.

  This is the single most important caveat about the script: **partial-apply state is possible** because Twenty's metadata API is not transactional. The script makes this loud (logs every op, fails on the first error) but cannot prevent it.

- **Rate limit.** Twenty enforces 100 req/min per workspace. The script paces itself to ~50 req/min to leave headroom for any concurrent UI activity by an operator.

### Tracker table — `bookings_db.twenty_schema_migrations`

Created by a bookings DB migration (`V004__twenty_schema_tracker.sql`, to be authored when the apply script lands).

```sql
CREATE TABLE twenty_schema_migrations (
  version           TEXT PRIMARY KEY,           -- e.g. 'V001'
  description       TEXT NOT NULL,
  applied_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  operations_count  INT NOT NULL,
  applied_by        TEXT NOT NULL,              -- the API key's role/user identifier or 'apply-twenty-schema.sh'
  applied_against   TEXT NOT NULL               -- TWENTY_API_BASE_URL at apply time, for audit
);
```

This piggybacks on infrastructure we already have (bookings DB, backups, single source of operational truth) and keeps Twenty's own state untouched.

## Rules

These mirror `.claude/rules/database-migrations.md` (load that rule when editing migrations under this directory):

1. **Filename:** `VNNN__description_in_snake_case.json`. NNN zero-padded, monotonically increasing. Never reuse a number.
2. **Append-only.** Once a migration has been applied anywhere (including locally), do not edit its content. Write a new migration to correct.
3. **One logical change per file.** Splitting makes partial-apply recovery practical.
4. **Field name additions/changes must be reflected in `docs/01-data-model/twenty-crm-schema.md` in the same commit.** The doc is the contract; migrations are the apply mechanism.
5. **No deletions or renames via this script.** A field deletion is irrecoverable; even Twenty's soft-delete leaves the data shape behind. Archive instead (e.g. set `isActive: false` if the object has such a field, or move the field to a deprecated section in the schema doc). Renames are equivalent to delete + create — same rule.
6. **Test in local first.** Apply against the local Twenty (current dev workspace) → manually verify in the UI → commit.

## A skeleton migration

```json
{
  "version": "V003",
  "description": "Add candidate.dataRetentionPolicy SELECT field",
  "author": "schema-designer",
  "date": "2026-05-10",
  "operations": [
    {
      "kind": "createField",
      "input": {
        "objectName": "candidate",
        "name": "dataRetentionPolicy",
        "label": "Data Retention Policy",
        "type": "SELECT",
        "options": [
          { "value": "default_24mo",     "label": "Default (24 months)",  "color": "blue",   "position": 0 },
          { "value": "extended_consent", "label": "Extended (consented)", "color": "green",  "position": 1 },
          { "value": "pending_deletion", "label": "Pending Deletion",     "color": "red",    "position": 2 }
        ],
        "defaultValue": "\"default_24mo\""
      }
    }
  ]
}
```
