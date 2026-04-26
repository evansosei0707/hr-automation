# Twenty v2.1.0 — API reference snapshot
Date: 2026-04-26 | Source: `twentycrm/twenty:v2.1.0` image + `~/Sandbox/twenty/` source checkout

All claims below are sourced from the read-only source tree at `~/Sandbox/twenty/` unless a docs URL is cited. File paths are relative to that repo root.

---

## Endpoints

Twenty v2 exposes **three separate HTTP API surfaces** from a single process. The routing is established in `packages/twenty-server/src/app.module.ts`.

| Surface | Path | Protocol | Auth required |
|---|---|---|---|
| Core data API (per-workspace CRUD) | `/graphql` | GraphQL (Yoga) | Yes — Bearer JWT |
| Metadata API (schema management) | `/metadata` | GraphQL (Yoga) | Yes — Bearer JWT with DATA_MODEL permission |
| REST data API (per-workspace CRUD) | `/rest/*` | REST over HTTP | Yes — Bearer JWT |
| REST metadata API | `/rest/metadata/*` | REST (proxies to `/metadata` GraphQL) | Yes — Bearer JWT with DATA_MODEL permission |
| Health check | `/healthz` | HTTP GET, no auth | No |

### Critical detail: `/graphql` vs `/metadata` are different endpoints

The `app.module.ts` registers two separate `GraphQLModule.forRootAsync` instances, one with `path: '/graphql'` (data ops) and one with `path: '/metadata'` (schema ops). They serve different GraphQL schemas. Sending a `createOneObject` mutation to `/graphql` will fail — it must go to `/metadata`.

Source: `packages/twenty-server/src/app.module.ts`, `packages/twenty-server/src/engine/api/graphql/metadata.module-factory.ts` (line 66: `path: '/metadata'`)

### REST metadata path restriction

The REST metadata controller only accepts two path segments:
- `GET /rest/metadata/objects` — list all object metadata
- `GET /rest/metadata/objects/{id}` — get one object by UUID
- `POST /rest/metadata/objects` — create object
- `PATCH /rest/metadata/objects/{id}` — update object
- `DELETE /rest/metadata/objects/{id}` — delete object
- Same pattern for `/rest/metadata/fields`

Any other path segment count raises `BadRequestException`. The REST metadata layer is a thin proxy that converts requests into the equivalent GraphQL mutations on `/metadata`.

Source: `packages/twenty-server/src/engine/api/rest/metadata/query-builder/utils/parse-metadata-path.utils.ts`

### Introspection

Introspection is **disabled for unauthenticated requests in production mode** (`NODE_ENV=production`). Authenticated requests (with a valid Bearer token) can introspect freely. In development mode, a GraphiQL playground is rendered at `/metadata` and `/graphql`.

Source: `packages/twenty-server/src/engine/core-modules/graphql/hooks/use-disable-introspection-and-suggestions-for-unauthenticated-users.hook.ts`

---

## Auth and API keys

### Token format

```
Authorization: Bearer <jwt_token>
```

The token is a signed JWT. For API key usage it is of type `API_KEY` (see `JwtTokenTypeEnum` in `packages/twenty-server/src/engine/core-modules/auth/types/auth-context.type.ts`). The JWT payload contains `{ sub: workspaceId, type: "API_KEY", workspaceId, jti: apiKeyId }`.

Source: `packages/twenty-server/src/engine/core-modules/api-key/services/api-key.service.ts` lines 162-175 — the `generateApiKeyToken` method builds the JWT with `sub: workspaceId`, `jti: apiKeyId`.

### API key is workspace-scoped, role-bound

An API key is a workspace-level credential — not a user credential and not global. The entity schema:

```typescript
// packages/twenty-server/src/engine/core-modules/api-key/api-key.entity.ts
@Entity({ name: 'apiKey', schema: 'core' })
class ApiKeyEntity {
  id: string           // UUID, primary key, also the JWT jti
  name: string
  expiresAt: Date      // REQUIRED — key has a hard expiry
  revokedAt: Date|null // set by revokeApiKey mutation; null = active
  workspaceId: string  // implicit via WorkspaceRelatedEntity
}
```

**Every API key must be assigned exactly one Role at creation time.** The `createApiKey` mutation requires a `roleId` field (not optional):

```typescript
// packages/twenty-server/src/engine/core-modules/api-key/dtos/create-api-key.input.ts
class CreateApiKeyInput {
  name: string        // required
  expiresAt: string   // required, ISO date string
  revokedAt?: string  // optional
  roleId: string      // required UUID — the role that governs permissions
}
```

### Creating an API key — two routes

**Route A: UI (Settings → API & Webhooks → + Create key)**
The UI shows the raw token once on creation. Copy it immediately.

**Route B: GraphQL mutation on `/metadata`** (requires an already-authenticated session token or admin API key)

```graphql
mutation CreateApiKey {
  createApiKey(input: {
    name: "n8n-hr-automation"
    expiresAt: "2027-04-26T00:00:00Z"
    roleId: "<uuid-of-role>"
  }) {
    id
    name
    expiresAt
    revokedAt
  }
}
```

After creating the key entity, you need a second step to obtain the actual JWT token. The service `generateApiKeyToken` signs a JWT using `jwtWrapperService.sign(...)`. In the UI flow this happens automatically and the token is displayed once. Via the mutation, the raw token is NOT returned by `createApiKey`; the resolver only returns the entity record. The token generation is a separate concern internally.

**Practical implication for n8n setup:** Generate the key via the UI, copy the token on first display. There is no mutation that returns the raw token string after initial creation.

Source: `packages/twenty-server/src/engine/core-modules/api-key/api-key.resolver.ts`, `packages/twenty-server/src/engine/core-modules/api-key/services/api-key.service.ts`

### Permissions / scopes

Permissions are controlled by the **Role** assigned to the API key. Roles are fine-grained:

- `canReadAllObjectRecords` — read access to all workspace objects
- `canUpdateAllObjectRecords` — write access
- `canSoftDeleteAllObjectRecords`
- `canDestroyAllObjectRecords`
- `canUpdateAllSettings` — includes schema changes via metadata API

Settings-level permissions are tracked via `PermissionFlagType` enum. For metadata operations (creating objects/fields), the role must have the `DATA_MODEL` permission flag. For managing API keys themselves: `API_KEYS_AND_WEBHOOKS` flag.

```typescript
// packages/twenty-shared/src/constants/PermissionFlagType.ts
enum PermissionFlagType {
  API_KEYS_AND_WEBHOOKS, WORKSPACE, WORKSPACE_MEMBERS, ROLES,
  DATA_MODEL, SECURITY, WORKFLOWS, ...
}
```

**Roles can also carry per-object permissions** (`objectPermissions`) and per-field permissions (`fieldPermissions`). Object-level row filtering is possible via `rowLevelPermissionPredicates`.

Source: `packages/twenty-server/src/engine/metadata-modules/role/dtos/role.dto.ts`, `packages/twenty-server/src/engine/metadata-modules/role/role.resolver.ts`

### Key expiry and rotation

- Keys have a hard expiry date (`expiresAt`), set at creation, validated on every request.
- `revokeApiKey` mutation sets `revokedAt = now()` and effectively kills the key.
- No automatic rotation mechanism. Rotation = create new key, update n8n credential, revoke old key.
- The service throws `API_KEY_EXPIRED` or `API_KEY_REVOKED` on invalid keys.

Source: `packages/twenty-server/src/engine/core-modules/api-key/services/api-key.service.ts` lines 106-136

### Rate limits

Official documentation states **100 requests per minute** per workspace.

Source: `https://docs.twenty.com/developers/extend/capabilities/apis` (accessed 2026-04-26)

### Example: authenticated curl against data API

```bash
# Data read — substitute your token and workspace domain
curl -s \
  -H "Authorization: Bearer eyJ..." \
  -H "Content-Type: application/json" \
  http://localhost:3000/graphql \
  -d '{"query":"{ __typename }"}'
```

```bash
# Metadata read (different endpoint)
curl -s \
  -H "Authorization: Bearer eyJ..." \
  -H "Content-Type: application/json" \
  http://localhost:3000/metadata \
  -d '{"query":"{ __typename }"}'
```

---

## Metadata API: creating custom objects

### Mutation: `createOneObject`

Target endpoint: `POST http://localhost:3000/metadata`

```graphql
mutation CreateOneObject($input: CreateOneObjectInput!) {
  createOneObject(input: $input) {
    id
    nameSingular
    namePlural
    labelSingular
    labelPlural
    description
    icon
    isCustom
    isActive
    createdAt
    updatedAt
  }
}
```

Variables:
```json
{
  "input": {
    "object": {
      "nameSingular": "candidate",
      "namePlural": "candidates",
      "labelSingular": "Candidate",
      "labelPlural": "Candidates",
      "description": "A person evaluated or communicated with as a potential hire",
      "icon": "IconUser"
    }
  }
}
```

Full `CreateObjectInput` type (required fields marked with `!`):

| Field | Required | Type | Notes |
|---|---|---|---|
| `nameSingular` | Yes | String | camelCase, validated by `@IsValidMetadataName` |
| `namePlural` | Yes | String | camelCase |
| `labelSingular` | Yes | String | human-readable display label |
| `labelPlural` | Yes | String | human-readable plural |
| `description` | No | String | |
| `icon` | No | String | icon name from Twenty's icon set e.g. `"IconUser"` |
| `shortcut` | No | String | keyboard shortcut character |
| `color` | No | String | theme color |
| `skipNameField` | No | Boolean | suppress auto-created `name` field |
| `isRemote` | No | Boolean | remote object (non-Postgres source) |
| `isLabelSyncedWithName` | No | Boolean | auto-derive label from name |

Source: `packages/twenty-server/src/engine/metadata-modules/object-metadata/dtos/create-object.input.ts`

### Mutation: `createOneField`

After creating an object, add custom fields one at a time.

```graphql
mutation CreateOneField($input: CreateOneFieldMetadataInput!) {
  createOneField(input: $input) {
    id
    type
    name
    label
    description
    isCustom
    isActive
    createdAt
    updatedAt
    options
    settings
    relation {
      type
      targetObjectMetadata { id nameSingular namePlural }
      targetFieldMetadata { id name }
    }
  }
}
```

Minimal variables for a TEXT field:
```json
{
  "input": {
    "field": {
      "objectMetadataId": "<uuid-from-createOneObject>",
      "type": "TEXT",
      "name": "whatsappNumber",
      "label": "WhatsApp Number",
      "description": "Normalised E.164 form. Unique.",
      "isNullable": true
    }
  }
}
```

The `type` value must be one of the `FieldMetadataType` enum values (see Field Types section).

### Mutation: `updateOneObject`

```graphql
mutation UpdateOneObject($input: UpdateOneObjectInput!) {
  updateOneObject(input: $input) {
    id
    isActive
    labelSingular
    labelPlural
  }
}
```

Variables:
```json
{
  "input": {
    "id": "<object-uuid>",
    "update": {
      "isActive": true,
      "labelSingular": "Candidate"
    }
  }
}
```

### Mutation: `deleteOneObject`

```graphql
mutation DeleteOneObject($input: DeleteOneObjectInput!) {
  deleteOneObject(input: $input) {
    id
    nameSingular
  }
}
```

Variables: `{ "input": { "id": "<object-uuid>" } }`

Source for all three: `packages/twenty-server/src/engine/metadata-modules/object-metadata/object-metadata.resolver.ts`

### REST metadata equivalent

```bash
# Create object via REST (proxied to GraphQL internally)
curl -s -X POST \
  -H "Authorization: Bearer eyJ..." \
  -H "Content-Type: application/json" \
  http://localhost:3000/rest/metadata/objects \
  -d '{"nameSingular":"candidate","namePlural":"candidates","labelSingular":"Candidate","labelPlural":"Candidates"}'

# Get object by id
curl -s -H "Authorization: Bearer eyJ..." \
  http://localhost:3000/rest/metadata/objects/<uuid>
```

Source: `packages/twenty-server/src/engine/api/rest/metadata/rest-api-metadata.controller.ts`

---

## Field types and relations

### Complete `FieldMetadataType` enum (v2.1.0)

```typescript
// packages/twenty-shared/src/types/FieldMetadataType.ts
enum FieldMetadataType {
  ACTOR        = 'ACTOR',        // system — tracks who created/modified
  ADDRESS      = 'ADDRESS',      // composite (street, city, country, lat/lng)
  ARRAY        = 'ARRAY',        // list of plain strings
  BOOLEAN      = 'BOOLEAN',
  CURRENCY     = 'CURRENCY',     // composite: amountMicros + currencyCode
  DATE         = 'DATE',
  DATE_TIME    = 'DATE_TIME',
  EMAILS       = 'EMAILS',       // composite: primaryEmail + additionalEmails
  FILES        = 'FILES',        // file attachments
  FULL_NAME    = 'FULL_NAME',    // composite: firstName + lastName
  LINKS        = 'LINKS',        // composite: primaryLinkLabel + primaryLinkUrl + secondaryLinks
  MORPH_RELATION = 'MORPH_RELATION', // polymorphic relation
  MULTI_SELECT = 'MULTI_SELECT',
  NUMBER       = 'NUMBER',       // supports int/float/bigint via settings
  NUMERIC      = 'NUMERIC',      // arbitrary precision (stored as string)
  PHONES       = 'PHONES',       // composite: primaryPhone + additionalPhones
  POSITION     = 'POSITION',     // system — kanban/list position
  RATING       = 'RATING',       // star rating (options define the scale)
  RAW_JSON     = 'RAW_JSON',     // arbitrary JSON (formerly JSON)
  RELATION     = 'RELATION',     // foreign-key relation (see below)
  RICH_TEXT    = 'RICH_TEXT',    // Blocknote/markdown dual storage
  SELECT       = 'SELECT',
  TEXT         = 'TEXT',
  TS_VECTOR    = 'TS_VECTOR',    // system — full-text search
  UUID         = 'UUID',         // system — primary key
}
```

Source: `packages/twenty-shared/src/types/FieldMetadataType.ts`

### Field type mapping vs. our existing spec

| Spec type | v2 enum value | Status | Notes |
|---|---|---|---|
| `TEXT` | `TEXT` | OK | unchanged |
| `RICH_TEXT` | `RICH_TEXT` | OK | stores `{ blocknote, markdown }` — dual storage |
| `NUMBER` | `NUMBER` | OK | optional `settings: { dataType: "int"\|"float"\|"bigint", decimals, type: "number"\|"percentage" }` |
| `BOOLEAN` | `BOOLEAN` | OK | |
| `DATE_TIME` | `DATE_TIME` | OK | |
| `SELECT` | `SELECT` | OK | options inline in createOneField call |
| `MULTI_SELECT` | `MULTI_SELECT` | OK | options inline in createOneField call |
| `EMAIL` | **`EMAILS`** | RENAMED | v2 uses `EMAILS` (composite, plural). No bare `EMAIL` type. |
| `PHONE` | **`PHONES`** | RENAMED | v2 uses `PHONES` (composite, plural). No bare `PHONE` type. |
| `ADDRESS` | `ADDRESS` | OK | composite type |
| `RATING` | `RATING` | OK | |
| `CURRENCY` | `CURRENCY` | OK | composite: `amountMicros` (int64 as string) + `currencyCode` |
| `RELATION` | `RELATION` | OK | see below |
| `JSON` | **`RAW_JSON`** | RENAMED | v2 uses `RAW_JSON` |
| `DATE` | `DATE` | OK (new) | separate from DATE_TIME |
| `URL` | `LINKS` | REPLACED | no bare URL type; use `LINKS` composite |


<!-- corrected 2026-04-26 from Twenty source: -->
<!-- - SELECT option `value` strings must match `^[A-Z][A-Z0-9_]*$` (UPPER_SNAKE_CASE). -->
<!--   Researcher's initial example used lowercase; verified against Twenty server v2.1.0 -->
<!--   which rejects lowercase with "Value must be in UPPER_CASE and follow snake_case". -->
<!-- - SELECT `defaultValue` strings must be SQL-literal single-quoted ('VALUE'), -->
<!--   not JSON-encoded double-quoted ("VALUE"). Researcher's initial guidance said -->
<!--   "JSON-encoded strings"; verified against -->
<!--   packages/twenty-server/src/engine/workspace-manager/workspace-migration/ -->
<!--   workspace-migration-builder/utils/serialize-default-value.util.ts:66-70 which -->
<!--   throws "Invalid string default value … should be single quoted" otherwise. -->
### SELECT and MULTI_SELECT options

Options are **inline** in the `createOneField` call — not a separate call. Options are passed as a JSON array in the `options` field:

```json
{
  "input": {
    "field": {
      "objectMetadataId": "<uuid>",
      "type": "SELECT",
      "name": "consentStatus",
      "label": "Consent Status",
      "options": [
        { "value": "PENDING",  "label": "Pending",  "color": "orange", "position": 0 },
        { "value": "GRANTED",  "label": "Granted",  "color": "green",  "position": 1 },
        { "value": "REFUSED",  "label": "Refused",  "color": "red",    "position": 2 },
        { "value": "REVOKED",  "label": "Revoked",  "color": "gray",   "position": 3 }
      ],
      "defaultValue": "'PENDING'"
    }
  }
}
```

Allowed `color` values (from `TagColor` type): `green`, `turquoise`, `sky`, `blue`, `purple`, `pink`, `red`, `orange`, `yellow`, `gray`.

Source: `packages/twenty-shared/src/types/FieldMetadataOptions.ts`, `packages/twenty-server/src/engine/metadata-modules/field-metadata/dtos/options.input.ts`

### RELATION fields and cardinality

v2 supports exactly two `RelationType` values:

```typescript
// packages/twenty-shared/src/types/RelationType.ts
enum RelationType {
  ONE_TO_MANY  = 'ONE_TO_MANY',
  MANY_TO_ONE  = 'MANY_TO_ONE',
}
```

**There is no native MANY_TO_MANY `RelationType`.** Many-to-many is modelled via a junction object (e.g. `CandidateSkillTag`), which has two `MANY_TO_ONE` relations. Twenty's UI hides the junction layer but the API requires you to create it explicitly.

Creating a RELATION field requires a `relationCreationPayload` in the field input:

```json
{
  "input": {
    "field": {
      "objectMetadataId": "<application-object-uuid>",
      "type": "RELATION",
      "name": "candidate",
      "label": "Candidate",
      "relationCreationPayload": {
        "type": "MANY_TO_ONE",
        "targetObjectMetadataId": "<candidate-object-uuid>",
        "targetFieldLabel": "Applications",
        "targetFieldIcon": "IconBriefcase"
      }
    }
  }
}
```

This simultaneously creates the forward relation field on `Application` (MANY_TO_ONE → Candidate) and the reverse relation field on `Candidate` (ONE_TO_MANY → Application) using `targetFieldLabel` and `targetFieldIcon`.

`RelationCreationPayload` type:
```typescript
// packages/twenty-shared/src/types/RelationCreationPayload.ts
type RelationCreationPayload = {
  type: RelationType;               // 'ONE_TO_MANY' | 'MANY_TO_ONE'
  targetObjectMetadataId: string;   // UUID of the target object
  targetFieldLabel: string;         // label for the reverse field
  targetFieldIcon: string;          // icon for the reverse field
};
```

Source: `packages/twenty-shared/src/types/RelationCreationPayload.ts`, `packages/twenty-server/src/engine/metadata-modules/field-metadata/dtos/create-field.input.ts`

### RELATION settings (onDelete)

After creating the relation, or by passing `settings` in the field input, you can specify cascade behaviour:

```typescript
// packages/twenty-shared/src/types/RelationOnDeleteAction.type.ts
enum RelationOnDeleteAction {
  CASCADE   = 'CASCADE',
  RESTRICT  = 'RESTRICT',
  SET_NULL  = 'SET_NULL',
  NO_ACTION = 'NO_ACTION',
}
```

Source: `packages/twenty-shared/src/types/RelationOnDeleteAction.type.ts`

### MORPH_RELATION (polymorphic)

A `MORPH_RELATION` field allows a record to relate to objects of multiple types (e.g. `ReviewTask.subject` can point to either a `Candidate` or an `Application`). Use `morphRelationsCreationPayload: RelationCreationPayload[]` (array) in the field input. This is a v2 addition; it did not exist in v0.60.

Source: `packages/twenty-server/src/engine/metadata-modules/field-metadata/dtos/create-field.input.ts` line 46

### NUMBER settings

```json
{
  "settings": {
    "dataType": "float",   // "int" | "float" | "bigint"
    "decimals": 2,
    "type": "number"       // "number" | "percentage"
  }
}
```

Source: `packages/twenty-shared/src/types/FieldMetadataSettings.ts`

---

## Standard data operations (read, create, update, delete)

### Key architectural point: generated per-object resolver names

v2 generates per-object resolver names from the object's `nameSingular`/`namePlural` using the patterns:
- `findOne<ObjectNameSingularCapitalized>` — e.g. `findOneCandidate`
- `findMany<ObjectNamePluralCapitalized>` — e.g. `findManyCandidates`
- `createOne<ObjectNameSingularCapitalized>` — e.g. `createOneCandidate`
- `createMany<ObjectNamePluralCapitalized>` — e.g. `createManyCandidates`
- `updateOne<ObjectNameSingularCapitalized>` — e.g. `updateOneCandidate`
- `deleteOne<ObjectNameSingularCapitalized>` — e.g. `deleteOneCandidate`
- `destroyOne<ObjectNameSingularCapitalized>` — hard delete (bypasses soft-delete)
- `restoreOne<ObjectNameSingularCapitalized>` — restore from soft delete

There is NO generic `createRecord(objectName: ...)` shape. Each object gets its own typed resolver. These are served from `/graphql`.

Source: `packages/twenty-server/src/engine/api/graphql/workspace-resolver-builder/factories/factories.ts`, `packages/twenty-server/src/engine/api/graphql/workspace-resolver-builder/constants/resolver-method-names.ts`

### Find one record by filter

```bash
curl -s -X POST \
  -H "Authorization: Bearer eyJ..." \
  -H "Content-Type: application/json" \
  http://localhost:3000/graphql \
  -d '{
    "query": "query FindCandidate($filter: CandidateFilterInput) { findOneCandidate(filter: $filter) { id name { firstName lastName } whatsappNumber consentStatus } }",
    "variables": {
      "filter": {
        "whatsappNumber": { "like": "+233%" }
      }
    }
  }'
```

### Create one record

```bash
curl -s -X POST \
  -H "Authorization: Bearer eyJ..." \
  -H "Content-Type: application/json" \
  http://localhost:3000/graphql \
  -d '{
    "query": "mutation CreateCandidate($data: CandidateCreateInput!) { createOneCandidate(data: $data) { id name { firstName lastName } whatsappNumber createdAt } }",
    "variables": {
      "data": {
        "name": { "firstName": "Akosua", "lastName": "Mensah" },
        "whatsappNumber": "+233244000001",
        "consentStatus": "PENDING"
      }
    }
  }'
```

Note: `data` is the argument name for createOne (see `CreateOneResolverArgs` interface: `data: Data`).

### Update one record

```bash
curl -s -X POST \
  -H "Authorization: Bearer eyJ..." \
  -H "Content-Type: application/json" \
  http://localhost:3000/graphql \
  -d '{
    "query": "mutation UpdateCandidate($id: ID!, $data: CandidateUpdateInput!) { updateOneCandidate(id: $id, data: $data) { id consentStatus consentGrantedAt } }",
    "variables": {
      "id": "0d4389ef-ea9c-4ae8-ada1-1cddc440fb56",
      "data": {
        "consentStatus": "granted",
        "consentGrantedAt": "2026-04-26T09:30:00Z"
      }
    }
  }'
```

### REST data API equivalent

```bash
# Read one — /rest/{objectNamePlural}/{id}
curl -s \
  -H "Authorization: Bearer eyJ..." \
  http://localhost:3000/rest/candidates/0d4389ef-ea9c-4ae8-ada1-1cddc440fb56

# Create one — POST /rest/{objectNamePlural}
curl -s -X POST \
  -H "Authorization: Bearer eyJ..." \
  -H "Content-Type: application/json" \
  http://localhost:3000/rest/candidates \
  -d '{"name":{"firstName":"Akosua","lastName":"Mensah"},"whatsappNumber":"+233244000001"}'

# Batch create — POST /rest/batch/{objectNamePlural}
curl -s -X POST \
  -H "Authorization: Bearer eyJ..." \
  -H "Content-Type: application/json" \
  http://localhost:3000/rest/batch/candidates \
  -d '[{"name":{"firstName":"A"}}, {"name":{"firstName":"B"}}]'
```

Batch limit is 60 records per request.

Source: `packages/twenty-server/src/engine/api/rest/core/controllers/rest-api-core.controller.ts`

### Soft delete vs. hard delete

- `deleteOne` — soft delete (sets `deletedAt`, record still queryable with filter)
- `destroyOne` — hard delete (permanent, no restore)
- `restoreOne` — undo a soft delete

Source: `packages/twenty-server/src/engine/api/graphql/workspace-resolver-builder/factories/factories.ts`

---

## Deltas from `docs/01-data-model/twenty-crm-schema.md`

### Section: "Invariant: access Twenty via GraphQL only"

**STILL TRUE.** The invariant holds. v2 adds a REST API but it is still GraphQL under the hood. Direct SQL is still wrong for all the same reasons.

### Section: "Custom objects are defined in `twenty-schema/objects/*.ts` using `twenty-sdk/define`"

**WRONG in v2.1.0.**

The spec says to use `twenty-sdk/define` and a TypeScript SDK. In v2, the officially-documented approach for extending the data model is via the **Metadata GraphQL API** (`/metadata`). The `twenty-sdk` approach is for building **apps/plugins distributed via npm**, not for a self-hosted workspace defining its own custom objects. For our use case (one workspace, self-hosted), the right approach is:

1. POST mutations to `/metadata` (via the schema-designer agent or a bootstrap script)
2. Or: use the UI (Settings → Data Model) and export the schema definition

There is no `twenty-sdk` package in the v2 server source that performs the `define` + `apply` flow described in the old spec. The spec's reference to `twenty-schema/README.md` and an "apply process" does not correspond to anything in the v2 architecture.

### Section: `Candidate` field `whatsappNumber` — type `PHONE`

**WRONG.** There is no `PHONE` type in v2. Use `PHONES` (composite), which stores `{ primaryPhoneNumber, primaryPhoneCountryCode, primaryPhoneCallingCode, additionalPhones }`.

When writing a PHONES value via GraphQL, the input will be:
```json
{
  "whatsappNumber": {
    "primaryPhoneNumber": "244000001",
    "primaryPhoneCountryCode": "GH",
    "primaryPhoneCallingCode": "+233"
  }
}
```

Source: `packages/twenty-shared/src/types/FieldMetadataDefaultValue.ts` — `FieldMetadataDefaultValuePhones`

### Section: `Interview.meetingLink` — type `URL`

**WRONG.** There is no bare `URL` type. Use `LINKS` (composite) or `TEXT`. For a single URL, `TEXT` is simpler. If you want the Twenty UI to render it as a hyperlink, use `LINKS`.

### Section: `Application.scoreBreakdown` — type `JSON`

**WRONG (type name).** Use `RAW_JSON`. The enum value is `RAW_JSON`, not `JSON`.

### Section: `SocialPost.engagementSnapshot` and `WorkflowError.errorContext` — type `JSON`

**WRONG (type name).** Same issue — use `RAW_JSON`.

### Section: `SkillTag.aliases` — type `TEXT[]`

**PARTIALLY WRONG.** There is no `TEXT[]` type. The closest is `ARRAY` (`FieldMetadataType.ARRAY`), which stores a list of plain strings. Use `ARRAY` for the `aliases` field.

### Section: `ReviewTask.subject` — type `RELATION → Candidate or Application`

**REQUIRES NEW APPROACH.** A field that can point to either a Candidate or an Application is a **polymorphic relation**. In v2 this is `MORPH_RELATION`, not a standard `RELATION`. Use `morphRelationsCreationPayload` (array of targets) when creating the field.

Source: `packages/twenty-server/src/engine/metadata-modules/field-metadata/dtos/create-field.input.ts` lines 43-46

### Section: `Interview.interviewer` — type `RELATION → User`

**NEEDS VERIFICATION.** Relations to Twenty's built-in `User` object (workspace members) are possible, but the exact `objectMetadataId` for the built-in `WorkspaceMember` object needs to be retrieved at runtime. Use `GET /rest/metadata/objects` to list all objects and find the UUID for the `workspaceMember` object. Do not hard-code a UUID.

### Section: Many-to-many (CandidateSkillTag)

**STILL TRUE in intent, clarified in implementation.**
- v2 has no native `MANY_TO_MANY` `RelationType`.
- `CandidateSkillTag` as a junction object with two `MANY_TO_ONE` relations is correct.
- From `CandidateSkillTag`, create: `candidate` field (MANY_TO_ONE → Candidate) and `skillTag` field (MANY_TO_ONE → SkillTag).
- Each `MANY_TO_ONE` call also creates the reverse `ONE_TO_MANY` on the target object.

### Section: "n8n-maintained fields (no Twenty rollups)"

**STILL TRUE.** v2 does not add formula fields or rollups. This constraint is unchanged.

### NEW BEHAVIOR — Roles system is new in v2

The spec does not mention Roles. v2 has a full RBAC system. Every API key must be associated with a Role, and that Role determines what the key can access. This affects how we create and configure API keys for n8n.

**Action required:** Before creating the n8n API key, create a Role with the appropriate permissions:
- `canReadAllObjectRecords: true`
- `canUpdateAllObjectRecords: true`
- `canSoftDeleteAllObjectRecords: true`
- Plus object-level permissions for each custom object if fine-grained control is desired.

Source: `packages/twenty-server/src/engine/metadata-modules/role/dtos/role.dto.ts`

### NEW BEHAVIOR — `applicationId` on objects and fields

All objects and fields in v2 carry an `applicationId` UUID. This relates to the new "apps" architecture. For custom objects created directly (not through an app), `applicationId` will be the workspace's custom application ID. This is opaque to the schema-designer but must be present in responses.

### NEW BEHAVIOR — `isLabelSyncedWithName` on objects

New optional boolean that auto-derives the label from the name. Set to `false` for explicit control.

### NEW BEHAVIOR — Data API has `destroyOne` (hard delete) in addition to `deleteOne` (soft delete)

Our existing workflows should use `deleteOne` (soft) unless explicit data erasure (GDPR/Ghana DPA right-to-erasure) is required, in which case `destroyOne` is the correct mutation.

---

## Open questions (things that could not be verified from source alone)

1. ~~**API key token delivery mechanism**~~ **CLOSED 2026-04-26.** Verified by observing the UI flow on Twenty v2.1.0: after creating an API key (`Settings → API & Webhooks → Create API key`), the JWT is shown **inline in a textarea on the keys page**, not in a one-time modal. The token remains recoverable from that page within the same session if you forget to copy it — gentler than typical "shown once" secret flows, but treat it as one-time anyway: rotate if missed. The corresponding programmatic delivery field on the `createApiKey` mutation response is therefore present even if not surfaced in the source files we traced; future agents can introspect against `/metadata` once a working API key exists to confirm the exact field name.

2. **`workspaceMember` object UUID**: Relations to `Interview.interviewer` (a workspace member) require the `objectMetadataId` of the built-in `workspaceMember` object. This UUID is workspace-specific and must be fetched from `GET /rest/metadata/objects` at bootstrap time. It cannot be hardcoded.

3. **Introspection in our stack**: Our `docker-compose.yml` does not set `NODE_ENV`. The default in Twenty appears to be development mode which enables the GraphiQL playground. For production, `NODE_ENV=production` should be set to disable unauthenticated introspection. Recommend adding `NODE_ENV: production` to the `twenty:` and `twenty-worker:` environment blocks in `infrastructure/docker-compose.yml`.

4. **`PHONES` field uniqueness**: Our spec requires `whatsappNumber` to be unique. The `createOneField` mutation accepts an `isUnique` boolean. This needs verification to confirm whether Twenty enforces uniqueness at the database level for `PHONES` composite fields or only at the API layer.

5. **`RICH_TEXT` in data queries**: The `RICH_TEXT` type stores `{ blocknote, markdown }`. When reading a `RICH_TEXT` field via GraphQL, n8n workflows must request one of those subfields explicitly (not the field name alone). The exact GraphQL fragment shape for rich-text fields should be verified against the introspection schema.

6. **Rate limit applies per-workspace or per-API-key**: The documented 100 req/min limit was sourced from the official docs page. It is not confirmed whether this is per workspace, per API key, or per IP. Under our expected load (n8n workflows) this is unlikely to be an issue but should be confirmed for the reporting and nightly sweep workflows.

7. **`skipNameField` behaviour**: The spec implies Candidate extends Person (a built-in). In v2, custom objects do not "extend" built-in objects — they are independent. Creating a `candidate` custom object will auto-create a `name` composite field (FULL_NAME) unless `skipNameField: true` is passed. Whether to use the auto-created `name` field or add a separate identifier needs a decision before schema-designer runs.

---

## Source file index (all citations)

| Claim | Source file |
|---|---|
| Endpoints (`/graphql`, `/metadata`, `/rest`) | `packages/twenty-server/src/app.module.ts` |
| Metadata path `/metadata` | `packages/twenty-server/src/engine/api/graphql/metadata.module-factory.ts` |
| REST metadata controller paths | `packages/twenty-server/src/engine/api/rest/metadata/rest-api-metadata.controller.ts` |
| REST metadata path validation | `packages/twenty-server/src/engine/api/rest/metadata/query-builder/utils/parse-metadata-path.utils.ts` |
| Introspection hook | `packages/twenty-server/src/engine/core-modules/graphql/hooks/use-disable-introspection-and-suggestions-for-unauthenticated-users.hook.ts` |
| `createOneObject` resolver | `packages/twenty-server/src/engine/metadata-modules/object-metadata/object-metadata.resolver.ts` |
| `CreateObjectInput` DTO | `packages/twenty-server/src/engine/metadata-modules/object-metadata/dtos/create-object.input.ts` |
| `createOneField` resolver | `packages/twenty-server/src/engine/metadata-modules/field-metadata/field-metadata.resolver.ts` |
| `CreateFieldInput` DTO | `packages/twenty-server/src/engine/metadata-modules/field-metadata/dtos/create-field.input.ts` |
| `FieldMetadataDTO` | `packages/twenty-server/src/engine/metadata-modules/field-metadata/dtos/field-metadata.dto.ts` |
| `FieldMetadataType` enum | `packages/twenty-shared/src/types/FieldMetadataType.ts` |
| `FieldMetadataOptions` (SELECT/MULTISELECT) | `packages/twenty-shared/src/types/FieldMetadataOptions.ts` |
| `FieldMetadataSettings` (NUMBER, RELATION, etc.) | `packages/twenty-shared/src/types/FieldMetadataSettings.ts` |
| `FieldMetadataDefaultValue` | `packages/twenty-shared/src/types/FieldMetadataDefaultValue.ts` |
| `RelationType` enum | `packages/twenty-shared/src/types/RelationType.ts` |
| `RelationOnDeleteAction` enum | `packages/twenty-shared/src/types/RelationOnDeleteAction.type.ts` |
| `RelationCreationPayload` | `packages/twenty-shared/src/types/RelationCreationPayload.ts` |
| `RelationDTO` | `packages/twenty-server/src/engine/metadata-modules/field-metadata/dtos/relation.dto.ts` |
| `ApiKeyEntity` schema | `packages/twenty-server/src/engine/core-modules/api-key/api-key.entity.ts` |
| `CreateApiKeyInput` DTO | `packages/twenty-server/src/engine/core-modules/api-key/dtos/create-api-key.input.ts` |
| `ApiKeyService` (token generation, expiry) | `packages/twenty-server/src/engine/core-modules/api-key/services/api-key.service.ts` |
| `ApiKeyResolver` (mutations) | `packages/twenty-server/src/engine/core-modules/api-key/api-key.resolver.ts` |
| `JwtTokenTypeEnum` / `ApiKeyTokenJwtPayload` | `packages/twenty-server/src/engine/core-modules/auth/types/auth-context.type.ts` |
| `RoleDTO` (permissions model) | `packages/twenty-server/src/engine/metadata-modules/role/dtos/role.dto.ts` |
| `PermissionFlagType` enum | `packages/twenty-shared/src/constants/PermissionFlagType.ts` |
| Per-object resolver names | `packages/twenty-server/src/engine/api/graphql/workspace-resolver-builder/constants/resolver-method-names.ts` |
| `CreateOneResolverArgs` interface | `packages/twenty-server/src/engine/api/graphql/workspace-resolver-builder/interfaces/workspace-resolvers-builder.interface.ts` |
| REST core controller (data CRUD paths) | `packages/twenty-server/src/engine/api/rest/core/controllers/rest-api-core.controller.ts` |
| Rate limit (100 req/min) | https://docs.twenty.com/developers/extend/capabilities/apis |
