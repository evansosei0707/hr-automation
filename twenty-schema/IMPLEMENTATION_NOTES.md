# Twenty Schema V001 — Implementation Notes

Author: schema-designer
Date: 2026-04-26
Migration: `twenty-schema/migrations/V001__init_core_objects.json`
Apply script: `scripts/apply-twenty-schema.sh`
Tracker migration: `database/migrations/V004__twenty_schema_tracker.sql`

---

## Decisions made that were not pre-decided in the spec or prompt

### 1. JSON comments in V001 migration file

The JSON migration file contains `//` comment lines for readability (phase labels, notes). Standard JSON does not support comments. The apply script handles this transparently: every `jq` call on a migration file is preceded by `sed '/^[[:space:]]*\/\//d'` which strips full-line comments before parsing.

**Constraint:** Inline trailing comments (e.g. `"foo": "bar" // note`) are NOT stripped by this pattern. The V001 file uses only full-line comments (lines that start with optional whitespace then `//`), so this is safe. Future migration authors must not add trailing inline comments.

### 2. `ReviewTask` uses two separate MANY_TO_ONE relations, not MORPH_RELATION

The spec explicitly requires two nullable `MANY_TO_ONE` fields (`subjectCandidate`, `subjectApplication`) rather than one `MORPH_RELATION` field. This was the pre-decided choice in `docs/01-data-model/twenty-crm-schema.md` and is consistent with ADR-0005's guidance on reversibility and consumer-side simplicity. No deviation here; noting it because the API reference documents `MORPH_RELATION` as the v2 idiomatic approach for this pattern.

The invariant "exactly one of the two fields is set" is enforced in n8n on every write path, not in Twenty.

### 3. `Interview.meetingLink` is TEXT not LINKS

The spec explicitly says `TEXT` (not the `LINKS` composite) because "we do not need composite UI rendering here." Implemented as TEXT. Tester should verify the Twenty UI does not present this as a hyperlink — it will be plain text.

### 4. `JobPosting.category` SELECT options inferred from `SkillTag.category`

The spec says `JobPosting.category` is "Aligned with SkillTag categories" but does not enumerate the options inline. I used the SkillTag category list directly: `frontend, backend, data, logistics, security, hospitality, admin, other`. These are identical across both objects, which is the intent.

### 5. NUMBER field `settings` for integer vs. float

- `JobPosting.headcount`, `Application.score`: `settings: { "dataType": "int" }` — integer, no decimals.
- `CandidateSkillTag.weight`: `settings: { "dataType": "float", "decimals": 2 }` — float 0.0–1.0.

Source: `packages/twenty-shared/src/types/FieldMetadataSettings.ts` `NumberDataType` enum.

### 6. BOOLEAN `defaultValue` is a JSON boolean, not a string

`FieldMetadataDefaultValueMapping[BOOLEAN]` is typed as `boolean | null` in the source. Therefore `defaultValue: false` and `defaultValue: true` are used directly (not `"false"` or `"true"`). SELECT defaults remain JSON-encoded strings (e.g. `"\"pending\""`).

Source: `packages/twenty-shared/src/types/FieldMetadataDefaultValue.ts`

### 7. `isNullable` defaults and non-nullable fields

The spec marks some fields as "required" without a `DEFAULT`. In Twenty's metadata API, a field with `isNullable: false` and no `defaultValue` will reject creates that omit the field. I set `isNullable: false` only where the spec clearly intends a required field with deterministic content at create time (e.g. `jobPosting.title`, `skillTag.name`, `holiday.date`, `holiday.name`, `workflowError.workflowName`, `workflowError.errorMessage`). All other fields are nullable. This is conservative — it is easier to add a NOT NULL constraint later than to add a default to an existing required field.

### 8. `Interview.bookingId` `isUnique: false` — explicit

The field cross-references `bookings_db.slot.id` and will be unique in practice (one interview per booking), but I did not set `isUnique: true` because Twenty would enforce a unique index at the database level, and a re-try of a failed booking could temporarily create two Interview records pointing to the same booking ID before cleanup. Leaving it non-unique; uniqueness is enforced by the bookings DB side.

### 9. CURRENCY fields have no `defaultValue`

`FieldMetadataDefaultValueMapping[CURRENCY]` expects `{ amountMicros: string|null, currencyCode: string|null }`. The spec does not specify a default for `salaryMinGhs`/`salaryMaxGhs`. Rather than defaulting to `{amountMicros: null, currencyCode: "GHS"}`, I left both fields with no `defaultValue` and `isNullable: true`. n8n workflows set `currencyCode: "GHS"` explicitly on every write.

### 10. Rate-limit pacing and operation count

V001 has 10 createObject + 53 non-relation createField + 21 RELATION createField = 84 total operations. At 1.2s each this is ~101 seconds (~1.7 minutes). The RELATION operations each also trigger the reverse field on the target, which is handled server-side — those do not count as separate API calls from our side.

---

## Ambiguities between spec and API reference, and how I resolved them

### Ambiguity A: `targetObjectName` is not a standard field in `RelationCreationPayload`

The `RelationCreationPayload` type (`packages/twenty-shared/src/types/RelationCreationPayload.ts`) uses `targetObjectMetadataId` (a UUID), not `targetObjectName`. The migration JSON format defined in `twenty-schema/README.md` uses `targetObjectName` as a convenience key that the apply script resolves to a UUID at runtime.

**Resolution:** The migration JSON uses `targetObjectName`. The apply script's `create_field` function strips it, looks up the UUID in `OBJECT_UUID_MAP`, and substitutes `targetObjectMetadataId`. This is documented in the README's "createField" operation kind row. No conflict — the apply script is the translation layer.

### Ambiguity B: `isUnique` on composite PHONES/EMAILS fields

The spec requires `whatsappNumber` and `email` (composite PHONES/EMAILS) to serve as canonical dedupe keys. The API reference (open question #4) notes: "whether Twenty enforces uniqueness at the database level for PHONES composite fields or only at the API layer" is unverified. I passed `isUnique: true` on the flat TEXT fields (`whatsappNumberE164`, `primaryEmailAddress`) which are simple scalar columns — uniqueness enforcement there is unambiguous. I did NOT pass `isUnique: true` on the composite PHONES/EMAILS fields themselves because the uniqueness semantics of composite fields are undefined.

**Tester verification point:** Confirm that `isUnique: true` on TEXT fields creates a unique database index. Also verify Twenty rejects duplicate `whatsappNumberE164` values.

### Ambiguity C: `createOneField` `isNullable` default

The `FieldMetadataDTO` has `isNullable?: boolean` (optional). It is unclear whether omitting it defaults to nullable or non-nullable. I passed `isNullable: true` explicitly on all fields I intend to be nullable, and `isNullable: false` on required fields. This avoids relying on an undocumented default.

### Ambiguity D: `workspaceMember` built-in object name

The spec and API reference agree this must be resolved at runtime via `GET /rest/metadata/objects`. The apply script does this. However, the exact `nameSingular` value for the workspace member built-in is assumed to be `"workspaceMember"` based on Twenty's naming conventions. If the built-in uses a different name (e.g. `"workspaceMembership"`), the relation creation for `Interview.interviewer` will fail with a resolution error.

**Tester verification point:** Before running the apply script, check `GET /rest/metadata/objects | jq '.objects[] | .nameSingular' | grep -i member` to confirm the exact name.

### Ambiguity E: `company` built-in object name for `jobPosting.client`

Same as above: assumed `nameSingular` is `"company"` (standard Twenty built-in). Verify with the same introspection query.

---

## Things that could not be pinned down without hitting the live Twenty

1. **Exact `nameSingular` of the `workspaceMember` built-in.** Assumed `workspaceMember`. Verify via `GET /rest/metadata/objects`.

2. **Exact `nameSingular` of the `company` built-in.** Assumed `company`. Verify via `GET /rest/metadata/objects`.

3. **Whether `isUnique: true` on a TEXT field creates a DB-level unique index** or only API-level validation. The source has the `isUnique` boolean on the DTO but the enforcement mechanism was not traced to the migration generation code.

4. **Whether `PHONES`/`EMAILS` fields accept `isNullable: false`** — these are composite types; the nullability semantics for composite sub-fields vs. the composite root are not fully documented in source.

5. **`skipNameField: true` exact effect** — verified the field exists in `CreateObjectInput` DTO, but whether it suppresses only the `name` composite field or other auto-created fields (like `createdAt`, `updatedAt`, `id`) is not confirmed. Expected: only suppresses `name` (FULL_NAME).

6. **REST endpoint returns `includeStandardObjects` query param** — the apply script sends `?includeStandardObjects=true` to ensure built-in objects like `company` and `workspaceMember` appear in the response. The REST metadata controller param name needs verification; if it is different, the built-in object resolution will fail.

---

## Caveats and known gotchas for tester

### Gotcha 1: JSON comments are handled transparently in the apply script

The `V001__init_core_objects.json` file contains `//` comment lines for readability. The apply script strips these via `sed '/^[[:space:]]*\/\//d'` before every `jq` parse call. No manual preprocessing needed.

**Tester action:** Verify `sed '/^[[:space:]]*\/\//d' twenty-schema/migrations/V001__init_core_objects.json | jq '.operations | length'` returns 84 (the total non-comment operation count). If it fails, the comment-stripping pattern may need adjustment.

### Gotcha 2: Partial-apply detection logic

The conflict detection checks only the first `createObject` operation's `nameSingular`. If the first object was already applied but was never in the tracker, the script exits with a clear message. However, if only field operations partially applied (Phase B or C), the script will not detect this automatically — it will attempt to re-create fields and receive errors from Twenty.

**Recovery:** Use `GET /rest/metadata/objects/<uuid>/fields` to see which fields already exist, remove those operations from the migration file, and re-run.

### Gotcha 3: RELATION operations create a reverse field on the target

When the apply script processes a `createField` with `type: RELATION`, Twenty creates two fields: the forward field (on `objectName`) and the reverse field (on `targetObjectName`). The reverse field label and icon come from `targetFieldLabel` and `targetFieldIcon`. Tester should verify:

- The reverse `Applications` field appears on `Candidate` after creating `application.candidate`.
- The reverse `jobPostings` field (label: "Job Postings") appears on the built-in `company` object after creating `jobPosting.client`.

### Gotcha 4: `workflowError.workflowName` and `errorMessage` are `isNullable: false`

These fields have no default. Creating a `workflowError` record without providing both values will fail. Workflow G must always supply these.

### Gotcha 5: Rate-limit headroom

The script paces at ~50 req/min. If an operator is actively using the Twenty UI during the apply run, the combined request rate could approach the 100 req/min limit. Run during a low-traffic window if possible.

### Gotcha 6: `CURRENCY` fields and GHS

The CURRENCY composite stores `amountMicros` (int64 as string) + `currencyCode`. All n8n workflows writing salary data must set `currencyCode: "GHS"`. Twenty's UI may display an amount-only field if the currency code is missing. No default is set in the schema — this is by design.

---

## Open questions from `reference/twenty-v2.1.0-api.md` that affect this work

**OQ #2 — `workspaceMember` UUID** (directly affects `Interview.interviewer` relation): handled by runtime resolution in the apply script. Tester must verify the built-in object name.

**OQ #4 — `PHONES` uniqueness enforcement**: not resolved. The flat `whatsappNumberE164` TEXT field carries the unique constraint instead; PHONES itself is not marked unique.

**OQ #5 — `RICH_TEXT` GraphQL fragment shape**: does not affect schema creation, but affects n8n workflow queries. Flagged for the workflow-builder agent: when reading `description`, `requirements`, `outcomeNote`, `body` fields, the query must select `.blocknote` or `.markdown` subfields explicitly.

**OQ #6 — rate limit scope (per workspace vs per key vs per IP)**: mitigated by conservative pacing at 50 req/min. No further action needed for this script.

**OQ #3 — `NODE_ENV` and introspection exposure**: does not affect this script but tester should note the recommendation to add `NODE_ENV: production` to the Twenty containers in `infrastructure/docker-compose.yml`.

OQ #1 and OQ #7 are not relevant to this migration.

---

### Confirmed v2.1.0 enforcement: SELECT option `value` must be UPPER_SNAKE_CASE

Discovered during the V001 apply attempt on 2026-04-26: Twenty v2.1.0 rejects lowercase SELECT option values with `Value must be in UPPER_CASE and follow snake_case "{sanitizedValue}"`. All V001 SELECT options + defaults were converted to UPPER form. **MULTI_SELECT not yet exercised — same rule presumed but unverified.** Anyone adding a MULTI_SELECT field in a future migration: assume UPPER_SNAKE_CASE and verify.

## Confidence level on apply script working first-try

**Medium.**

Reasons for medium (not high):

1. The JSON comment issue (Gotcha 1) is a known parse failure that will block the very first run until the comments are stripped or the apply script is updated to pre-process them. This is a mechanical fix but requires tester action.

2. The `workspaceMember` and `company` built-in nameSingular values are assumed. If either differs, the two relation operations that target built-ins will fail.

3. `GET /rest/metadata/objects?includeStandardObjects=true` — the query param name is assumed. If the REST controller uses a different parameter name or requires a different approach to list built-in objects, the state cache will be missing built-in UUIDs.

4. BOOLEAN `defaultValue` format (`false` as a JSON boolean vs a string) — the DTO types confirm `boolean | null` for BOOLEAN defaults, so this should be correct, but it has not been tested live.

Once Gotcha 1 is fixed and the built-in object names are confirmed, confidence rises to high. The mutation shapes, field types, and operation ordering are all sourced directly from the v2.1.0 source DTOs.
