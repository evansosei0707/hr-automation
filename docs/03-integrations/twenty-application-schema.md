# Twenty Application schema — confirmed for Workflow B (OQ-1)

**Resolved:** 2026-05-01
**Question:** What are the correct GraphQL resolver names for singular-by-ID lookups, field shapes, and update mutations for `Application` (and `Candidate` cross-check) in the live Twenty v2.1.0 instance?
**Confidence:** High. Live curl introspection was not executed (researcher could not read `infrastructure/.env`), but findings derive from `reference/twenty-v2.1.0-api.md` (built from `~/Sandbox/twenty/` source tree on 2026-04-26) and are consistent with the live Workflow A deployment, which uses the same resolver-naming function and was live-tested PASS on 2026-05-01.

## Summary

In Twenty v2.1.0, resolver names on the data API (`/graphql`) are generated deterministically from the object's `nameSingular` and `namePlural` via `packages/twenty-server/src/engine/utils/get-resolver-name.util.ts`. For `Application`:

- **Singular fetch:** `application(filter: { id: { eq: $id } })` — returns the object directly, no Connection wrap
- **Collection fetch:** `applications(filter: ...)` — returns `{ edges { node { ... } } }`
- **Update mutation:** `updateApplication(id: $id, data: $data)` — NO `One` infix on data API

The `One` infix (e.g. `updateOneApplication`) is exclusive to **metadata** mutations on the `/metadata` endpoint, not the data API. The same naming function produces the verified `candidate` / `updateCandidate` (live-tested PASS in Workflow A as of 2026-05-01).

## Resolver names

| Operation | Resolver | Shape |
|---|---|---|
| Find one Application by filter/ID | `application(filter: { id: { eq: $id } })` | Plain object |
| Find many Applications | `applications(filter: ...)` | `{ edges { node { ... } } }` Connection |
| Create Application | `createApplication(data: ...)` | Created object |
| Update Application | `updateApplication(id: $id, data: $data)` | Updated object |
| Soft delete Application | `deleteApplication(id: $id)` | Sets `deletedAt` |
| Hard delete Application | `destroyApplication(id: $id)` | Permanent erasure |
| Find one Candidate by filter/ID | `candidate(filter: { id: { eq: $id } })` | Plain object |
| Update Candidate | `updateCandidate(id: $id, data: $data)` | Live-tested PASS in Workflow A |

## Application fields (canonical from `docs/01-data-model/twenty-crm-schema.md`)

| Field | Twenty type | Notes |
|---|---|---|
| `id` | UUID | System primary key |
| `candidate` | RELATION (MANY_TO_ONE → Candidate) | Reverse on Candidate: `applications` |
| `jobPosting` | RELATION (MANY_TO_ONE → JobPosting) | Reverse on JobPosting: `applications` |
| `status` | SELECT | `RECEIVED`, `SCREENING`, `SCREENED`, `SHORTLISTED`, `INTERVIEWING`, `OFFERED`, `PLACED`, `NOT_SELECTED`, `WITHDRAWN`. Default: `RECEIVED` |
| `score` | NUMBER | Integer 0–100 |
| `scoreBreakdown` | RAW_JSON | Per-criterion detail; returned as a JS object, no sub-field selection needed |
| `notSelectedReason` | SELECT | `POSITION_FILLED`, `NOT_A_MATCH`, `CANDIDATE_WITHDREW`, `OTHER` |
| `reEngagementEligible` | BOOLEAN | Default: false; maintained by n8n |
| `reEngagedAt` | DATE_TIME | Set by Workflow H |
| `submittedToClientAt` | DATE_TIME | Operator-set |
| `createdAt` | DATE_TIME | System-managed |
| `updatedAt` | DATE_TIME | System-managed |
| `deletedAt` | DATE_TIME | Non-null = soft-deleted |

## Example queries for Workflow B

### Singular fetch by known ID

```graphql
query GetApplication($filter: ApplicationFilterInput) {
  application(filter: $filter) {
    id
    status
    score
    scoreBreakdown
    candidate {
      id
      name
      primaryEmailAddress
      whatsappNumberE164
    }
    jobPosting {
      id
      title
      collarType
    }
  }
}
```

Variables:

```json
{ "filter": { "id": { "eq": "APPLICATION-UUID" } } }
```

### Polling for unprocessed Applications (collection form)

```graphql
query PollApplications($filter: ApplicationFilterInput) {
  applications(filter: $filter) {
    edges {
      node {
        id
        status
        candidate { id name primaryEmailAddress whatsappNumberE164 }
        jobPosting { id title collarType }
      }
    }
  }
}
```

Variables:

```json
{ "filter": { "status": { "eq": "RECEIVED" } } }
```

### Status update after screening

```graphql
mutation UpdateApplication($id: ID!, $data: ApplicationUpdateInput!) {
  updateApplication(id: $id, data: $data) {
    id
    status
    score
    scoreBreakdown
    reEngagementEligible
    updatedAt
  }
}
```

Variables:

```json
{
  "id": "APPLICATION-UUID",
  "data": {
    "status": "SCREENED",
    "score": 78,
    "scoreBreakdown": { "skills": 80, "experience": 75 }
  }
}
```

## Recommended pattern for Workflow B

For a known-ID single fetch, use `application(filter: { id: { eq: $applicationId } })`. The singular resolver returns a plain object — no `edges.node` unwrap. For polling unprocessed applications, use the collection form with `edges` unwrap. For all updates, use `updateApplication(id: $id, data: $data)`.

The Twenty endpoint **inside Docker** is `http://twenty:3000/graphql` (internal hostname), not `localhost:3000`. Auth header: `Authorization: Bearer {{ $env.TWENTY_API_KEY }}`.

## Caveats

- The `RICH_TEXT` sub-field selection caveat (need `{ blocknote }` or `{ markdown }`) does NOT apply to Application — it has no RICH_TEXT fields. The `RAW_JSON` `scoreBreakdown` needs no sub-selection.
- Relation fields (`candidate`, `jobPosting`) must be queried with explicit sub-selections; requesting them as bare scalars will error.
- Live curl introspection was deferred (researcher had no read access to `infrastructure/.env`). The risk of discrepancy is low — Twenty is pinned at `twentycrm/twenty:v2.1.0` and the schema was applied from that same source. Confidence is reinforced by Workflow A's live PASS using `candidate` / `updateCandidate`, which come from the same naming function.

## Sources

- `reference/twenty-v2.1.0-api.md` lines 529–611 — resolver naming rules + working `updateCandidate` example. Source-cited: `packages/twenty-server/src/engine/utils/get-resolver-name.util.ts`.
- `docs/01-data-model/twenty-crm-schema.md` lines 115–130 — canonical Application field definitions
- `.claude/memory/status.md` — Workflow A live PASS 2026-05-01 (`updateCandidate` confirmed in production)
