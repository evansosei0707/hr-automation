# ADR-0005: Adopt Twenty v2.1.0 API surface; retire v0.60-era assumptions

**Status:** Accepted
**Date:** 2026-04-26
**Deciders:** HRA Project Lead

## Context

The original scaffolding pinned `twentycrm/twenty:v0.60` and `docs/01-data-model/twenty-crm-schema.md` was authored against that version's assumption set. v0.60 does not exist on Docker Hub; Twenty's published lineage went 1.x then 2.x, with v2.1.0 released 2026-04-24. We pinned to v2.1.0 during Phase 1 bring-up of Week 0 (see `.claude/memory/decisions.md` 2026-04-26 entry).

Before `schema-designer` is dispatched to create custom objects, we ran a `researcher` pass against the v2.1.0 source (the checkout at `~/Sandbox/twenty/`) and the official docs. The full reference snapshot lives at `reference/twenty-v2.1.0-api.md` (774 lines, source-cited). It enumerates eight material deltas from our v0.60-era spec; each is summarised below and accepted in this ADR.

## Decision

Adopt the v2.1.0 API surface as documented in `reference/twenty-v2.1.0-api.md`. Update `docs/01-data-model/twenty-crm-schema.md` to converge with v2 reality. Have all programmatic Twenty access — from n8n and from the `schema-designer` agent — use v2 mutation names, v2 field types, and v2 auth.

### Findings accepted

1. **Three endpoints, not one.** v2 splits surfaces into `/graphql` (per-workspace data CRUD with per-object generated resolvers), `/metadata` (schema management GraphQL), and `/rest/*` (REST proxy to the same operations). Workflows must address the right endpoint for the right job.
   - Source: `packages/twenty-server/src/app.module.ts`; `packages/twenty-server/src/engine/api/graphql/metadata.module-factory.ts`

2. **Auth model is JWT Bearer with RBAC.** `Authorization: Bearer <jwt>`, workspace-scoped. RBAC is new in v2: every API key requires a `roleId` at creation time. Generate keys via `Settings → API & Webhooks` in the Twenty UI; a programmatic mutation also exists. Keys can carry expiry; rotation is a recreate-and-swap.
   - Source: `packages/twenty-server/src/engine/core-modules/api-key/dtos/create-api-key.input.ts`; `packages/twenty-server/src/engine/core-modules/api-key/services/api-key.service.ts`; `packages/twenty-shared/src/constants/PermissionFlagType.ts`

3. **Metadata mutation names changed.** v2 uses `createOneObject`, `createOneField`, `updateOneObject`, `deleteOneObject`, `updateOneField`, `deleteOneField` on `/metadata`. Our v0.60-era assumption of `createObjectMetadata`-style names is wrong everywhere.
   - Source: `packages/twenty-server/src/engine/metadata-modules/object-metadata/object-metadata.resolver.ts`; `packages/twenty-server/src/engine/metadata-modules/field-metadata/field-metadata.resolver.ts`

4. **Field type renames.** Multiple types in our spec were renamed or replaced in v2: `PHONE` → `PHONES` (composite), `EMAIL` → `EMAILS` (composite), `JSON` → `RAW_JSON`, `URL` → `LINKS` (composite), and `TEXT[]` doesn't exist (use `ARRAY` or model as a relation).
   - Source: `packages/twenty-shared/src/types/FieldMetadataType.ts`

5. **`MANY_TO_MANY` does not exist as a relation type.** v2 only has `ONE_TO_MANY` and `MANY_TO_ONE`. Many-to-many relationships must be modelled with explicit junction objects. Our `CandidateSkillTag` was already a junction; the spec's framing as "many-to-many" is now incorrect — it is a first-class object with two `MANY_TO_ONE` relations.
   - Source: `packages/twenty-shared/src/types/RelationType.ts`

6. **SELECT / MULTI_SELECT options are inline in the field-create call.** The `options` array is passed as part of `createOneField`'s payload, not as a separate call.
   - Source: `packages/twenty-server/src/engine/metadata-modules/field-metadata/dtos/create-field.input.ts`; `packages/twenty-shared/src/types/FieldMetadataOptions.ts`

7. **The `twenty-schema/objects/*.ts` + `twenty-sdk/define` approach has no v2 implementation.** Our spec's "Defining objects as code" section describes a workflow that does not exist in v2 source. `schema-designer` must use direct GraphQL mutations against `/metadata` instead. The `twenty-schema/` directory in our repo layout (CLAUDE.md project map) is therefore re-purposed to hold the GraphQL mutation files and a small apply script — not TypeScript SDK calls.
   - Source: absence in `~/Sandbox/twenty/packages/` — verified by the researcher.

8. **Rate limit: 100 requests/minute per workspace.** All metadata + data API traffic counts. n8n workflows that fan out per-record mutations need to chunk and rate-limit, especially the initial schema apply.
   - Source: https://docs.twenty.com/developers/extend/capabilities/apis (cited in researcher report)

### One open item carried forward

The raw JWT string returned at API-key creation is not traceable to a specific resolver in v2 source (researcher's open question #1). Workaround: generate keys via the UI until verified. This affects how we automate API-key provisioning later but does not block Phase 2.

## Consequences

**Positive:**

- We adopt a current, supported version with active development rather than chasing a tag that never existed.
- RBAC gives us a clean way to scope the n8n service account narrowly, vs. the v0.60 model's blanket access.
- The new generated-resolver naming (`createOneCandidate` etc.) makes n8n workflows more readable than a generic `createRecord(objectName: ...)` would.
- The reference snapshot at `reference/twenty-v2.1.0-api.md` is dense and source-cited, so future agents can self-serve without re-researching.

**Negative / trade-offs accepted:**

- Every mention of `createObjectMetadata`, `PHONE`, `EMAIL`, `JSON`, `URL`, `TEXT[]`, or `MANY_TO_MANY` in our project docs must be revised. This ADR + the schema-doc update cover the data-model spec; downstream workflow specs in `docs/02-workflows/` may also need touch-ups when their respective workflows are built — flagged for `schema-designer` and `code-reviewer` to catch.
- The 100 req/min rate limit constrains bulk-import shapes. Backfill scripts and the schema-apply step must paginate.
- v2 RBAC is unfamiliar; the `n8n-service` role we'll create needs to be tested for permission gaps before Phase 4 workflows depend on it.

**Neutral / follow-up work:**

- Update `docs/01-data-model/twenty-crm-schema.md` in the same series of commits that include this ADR.
- Add `TWENTY_API_KEY` to `infrastructure/.env.example`.
- When the open question on JWT-at-creation is verified (likely by observing the UI flow once a key is generated), append a short follow-up note here or supersede with an ADR-0005a.
- Consider a dedicated ADR if observed Redis key-prefix collisions force us to split Twenty's BullMQ off the shared Redis (carried forward from `.claude/memory/decisions.md` 2026-04-26 entry).

## Alternatives considered

- **Pin to a v1.x release** (e.g. `v1.23.9`) to minimise the surface area of change. Rejected: v1.x is on its way out, the doc churn would still be substantial because v1 also differs from v0.60, and we have no installed data to migrate, so picking newest stable costs nothing.
- **Retain v0.60-era spec verbatim and let `schema-designer` translate at apply time.** Rejected: the spec is the durable artifact; downstream readers (humans and agents) would silently consume wrong information. Translation lives in code, not in a mental gap between doc and reality.
- **Stand up a fresh research task per workflow as we build it.** Rejected: the deltas are foundational, not workflow-specific. One reference snapshot + one ADR is more efficient than re-doing the work eight times.

## References

- Researcher report (full reference, 774 lines, source-cited): [`reference/twenty-v2.1.0-api.md`](../../reference/twenty-v2.1.0-api.md)
- Phase 1 scaffolding fixes preceding this work: `.claude/memory/decisions.md` (2026-04-26 entries)
- Related: ADR-0003 Google Calendar holidays — same pattern of "verify vendor reality before specifying against it."
- Twenty v2.1.0 release notes: https://github.com/twentyhq/twenty/releases (latest tag at time of decision)
- Twenty docs (rate limits + auth header): https://docs.twenty.com/developers/extend/capabilities/apis
