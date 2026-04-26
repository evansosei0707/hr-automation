# Twenty CRM — Schema & Custom Objects

All candidate, company, job, and interview data lives in Twenty. This doc is the contract between our workflows and the CRM schema.

**Twenty version:** v2.1.0 (pinned in `infrastructure/docker-compose.yml`).
**Status:** Reconciled with v2.1.0 reality on 2026-04-26 per [ADR-0005](../05-decisions/ADR-0005-twenty-v2-migration.md). For full v2 API reference (mutation shapes, field-type semantics, source citations), see [`reference/twenty-v2.1.0-api.md`](../../reference/twenty-v2.1.0-api.md).

## Invariants

### Access via Twenty's HTTP APIs only — never direct SQL

We do not make direct SQL calls into Twenty's Postgres. Every read and write uses Twenty's HTTP surface with a workspace-scoped JWT.

Twenty v2 exposes three endpoints from one process:

| Endpoint | Purpose |
|---|---|
| `POST /graphql` | Per-workspace data CRUD. Per-object generated resolvers like `createCandidate`, `candidates` (findMany), `updateCandidate`. See `reference/twenty-v2.1.0-api.md` for the full naming pattern. |
| `POST /metadata` | Schema management (creating/updating custom objects and fields). |
| `/rest/*` | REST proxy to the same operations — used for introspection (`GET /rest/metadata/objects`) and as an n8n-friendly fallback. |

Reasons to never bypass these:

1. Twenty's schema changes between releases; direct SQL breaks silently when columns move or rename.
2. Twenty enforces validation, hooks, and audit logs at the API layer. Direct SQL bypasses all of them.
3. RBAC is enforced only at the API layer.
4. The separate n8n-owned bookings DB (`docs/01-data-model/bookings-db.md`) handles any hot-path write that would otherwise tempt us into direct SQL.

### Auth

`Authorization: Bearer <jwt>`. Every API key is workspace-scoped and bound to a Role (RBAC, new in v2). The n8n service uses an API key bound to a Role named `n8n-service` with full CRUD on our custom objects. Key generation is via the Twenty UI: `Settings → API & Webhooks → Create API key`. Token is read from `TWENTY_API_KEY` in `.env`. See ADR-0005 for the rationale and the reference doc for header format details.

### No rollups, formulas, or action-button webhooks

Twenty v2 does not support formula fields, rollups, or server-side action-button webhooks. Any computed field is maintained by a scheduled n8n workflow. See "n8n-maintained fields" below.

## Naming convention: when to use Twenty's auto-`name` field

Twenty auto-creates a flat `name` field (type: TEXT — a plain string) on every custom object unless `skipNameField: true` is passed at object-create time. (Verified against Twenty v2.1.0 by tester on 2026-04-26: `createCandidate(data:{name:"Akosua Mensah"})` accepts a flat string. The `FULL_NAME` enum value exists but is not what `skipNameField: false` produces; it would be set explicitly via `createOneField` if needed.)

- **Candidate** — accept the auto-`name`. Candidates are people; the plain-text full name is the natural identifier.
- **All other custom objects** — pass `skipNameField: true`. They aren't people; we define our own canonical identifier per object below.

## SELECT / MULTI_SELECT option values: UPPER_SNAKE_CASE

Twenty v2.1.0 rejects SELECT option `value` strings that aren't UPPER_SNAKE_CASE. Display labels (`label`) stay mixed-case; only the programmatic `value` is uppercased. When migrating a value with bare-camel digit adjacency (`top20`), insert an underscore between letters and digits: `TOP_20`. Values whose source already has an explicit underscore (`default_24mo`) keep that structure: `DEFAULT_24MO`.

n8n workflows, GraphQL queries, and this doc all reference SELECT values in their UPPER form. Discovered the hard way during V001 apply (2026-04-26); see ADR-0005 follow-ups.

## Composite + flat field pattern

For frequently-queried composite fields (PHONES, EMAILS), we store the canonical Twenty composite **and** a flat indexed scalar for fast workflow lookups. Slight redundancy, real query simplicity.

| Composite (canonical) | Flat lookup field | Purpose |
|---|---|---|
| `whatsappNumber: PHONES` | `whatsappNumberE164: TEXT` (unique, indexed) | Match WhatsApp inbound on an existing Candidate in O(1). |
| `email: EMAILS` | `primaryEmailAddress: TEXT` (unique, indexed) | Match CV-extracted email or email-based webhook on an existing Candidate. |

n8n workflows that ingest a phone or email always **write both** (extract the canonical normalised form, set the flat field) and **read the flat field** for lookups. Read-back tests in workflow specs assert both stay in sync.

---

## Custom objects

Twenty ships with Companies and People as built-ins. We add the following ten custom objects.

### `Candidate` (custom object — independent, NOT extending Person)

A person the firm has evaluated or communicated with as a potential hire. Independent custom object per ADR-0005 — Twenty v2 does not have an "extension" pattern, and a separate object gives cleaner version-coupling.

Auto-created by Twenty (`skipNameField` not passed):
| Field | Type |
|---|---|
| `name` | TEXT (auto-created by Twenty; plain string — e.g. "Akosua Mensah") |

Explicit fields:

| Field | Type | Notes |
|---|---|---|
| `email` | EMAILS | Composite. |
| `primaryEmailAddress` | TEXT | Unique, indexed. Mirrors `email.primaryEmail` for fast lookup. |
| `whatsappNumber` | PHONES | Composite. |
| `whatsappNumberE164` | TEXT | Unique, indexed. Normalised E.164 form. |
| `preferredLanguage` | SELECT | Options: `ENGLISH`, `PIDGIN`, `TWI`, `GA`, `EWE`, `DAGBANI`, `OTHER`. Default: `ENGLISH`. |
| `consentStatus` | SELECT | Options: `PENDING`, `GRANTED`, `REFUSED`, `REVOKED`. Default: `PENDING`. |
| `consentGrantedAt` | DATE_TIME | When YES was received. |
| `strengthTier` | SELECT | Options: `TOP_20`, `SOLID`, `DEVELOPING`, `NOT_A_FIT`. Set by workflow B (white-collar) or C (blue-collar). |
| `strengthTierReason` | TEXT | Human-readable rationale. |
| `lastActivityAt` | DATE_TIME | Maintained by n8n on any interaction; used for retention. |
| `dataRetentionPolicy` | SELECT | Options: `DEFAULT_24MO`, `EXTENDED_CONSENT`, `PENDING_DELETION`. Default: `DEFAULT_24MO`. |
| `manualReviewFlag` | BOOLEAN | Default: false. Orchestrator's attention required. |
| `manualReviewReason` | TEXT | |

### `JobPosting`

A role the firm is recruiting for, on behalf of a Company. `skipNameField: true`; `title` is the canonical identifier.

| Field | Type | Notes |
|---|---|---|
| `title` | TEXT | Canonical identifier; required. |
| `client` | RELATION (MANY_TO_ONE → built-in `company`) | Reverse field on Company: `jobPostings` (label: "Job Postings"). |
| `category` | SELECT | Aligned with `SkillTag` categories. |
| `seniority` | SELECT | Options: `ENTRY`, `MID`, `SENIOR`, `LEAD`. |
| `status` | SELECT | Options: `DRAFT`, `OPEN`, `SHORTLISTING`, `CLOSED`, `FILLED`, `CANCELLED`. Default: `DRAFT`. |
| `headcount` | NUMBER | Integer. |
| `postedAt` | DATE_TIME | |
| `closedAt` | DATE_TIME | |
| `description` | RICH_TEXT | Stored as `{ blocknote, markdown }`. |
| `requirements` | RICH_TEXT | |
| `salaryMinGhs` | CURRENCY | Composite: `amountMicros` + `currencyCode` (`GHS`). |
| `salaryMaxGhs` | CURRENCY | |
| `location` | TEXT | Free-form, usually city or `Remote`. |
| `collarType` | SELECT | Options: `BLUE`, `WHITE`. Routes to workflow B or C. |

### `Application`

The join between a Candidate and a JobPosting. `skipNameField: true`; no canonical name (referenced by ID).

| Field | Type | Notes |
|---|---|---|
| `candidate` | RELATION (MANY_TO_ONE → Candidate) | Reverse on Candidate: `Applications`. v2 create payload example: `{ "type": "RELATION", "name": "candidate", "relationCreationPayload": { "type": "MANY_TO_ONE", "targetObjectName": "candidate", "targetFieldLabel": "Applications", "targetFieldIcon": "IconClipboard" } }` — see `twenty-schema/migrations/V001__init_core_objects.json` for all 10 relation examples. |
| `jobPosting` | RELATION (MANY_TO_ONE → JobPosting) | Reverse on JobPosting: `Applications`. |
| `status` | SELECT | Options: `RECEIVED`, `SCREENING`, `SCREENED`, `SHORTLISTED`, `INTERVIEWING`, `OFFERED`, `PLACED`, `NOT_SELECTED`, `WITHDRAWN`. Default: `RECEIVED`. |
| `score` | NUMBER | 0–100; integer. |
| `scoreBreakdown` | RAW_JSON | Per-criterion detail. |
| `notSelectedReason` | SELECT | Options: `POSITION_FILLED`, `NOT_A_MATCH`, `CANDIDATE_WITHDREW`, `OTHER`. |
| `reEngagementEligible` | BOOLEAN | Default: false. Maintained by n8n on status change: true when `status=NOT_SELECTED AND notSelectedReason=POSITION_FILLED`. |
| `reEngagedAt` | DATE_TIME | Set by workflow H. |
| `submittedToClientAt` | DATE_TIME | |

### `Interview`

A scheduled interview slot. `skipNameField: true`.

| Field | Type | Notes |
|---|---|---|
| `application` | RELATION (MANY_TO_ONE → Application) | Reverse on Application: `Interviews`. |
| `scheduledAt` | DATE_TIME | |
| `interviewer` | RELATION (MANY_TO_ONE → built-in `workspaceMember`) | UUID of the `workspaceMember` object resolved at apply-time via `GET /rest/metadata/objects` — do not hard-code. |
| `location` | TEXT | E.g. office address, or `Online — link below`. |
| `meetingLink` | TEXT | Plain URL string. (Not LINKS — we do not need composite UI rendering here.) |
| `status` | SELECT | Options: `PROPOSED`, `CONFIRMED`, `COMPLETED`, `NO_SHOW`, `RESCHEDULED`, `CANCELLED`. Default: `PROPOSED`. |
| `bookingId` | TEXT | Foreign key into `bookings_db.slot.id` (UUID as text). Indexed. |
| `outcomeNote` | RICH_TEXT | |

### `SkillTag`

Structured tags used by workflow H (job alerts) to match candidates to similar new roles. `skipNameField: true`; `name` defined explicitly as TEXT.

| Field | Type | Notes |
|---|---|---|
| `name` | TEXT | Unique, indexed. |
| `category` | SELECT | Options: `FRONTEND`, `BACKEND`, `DATA`, `LOGISTICS`, `SECURITY`, `HOSPITALITY`, `ADMIN`, `OTHER`. Extend as needed. |
| `aliases` | ARRAY | List of plain strings. So "FE developer" matches "Frontend". |

### `CandidateSkillTag` (junction)

Junction object between Candidate and SkillTag, with a weight. `skipNameField: true`. Implements the many-to-many relationship via two `MANY_TO_ONE` relations (v2 has no native MANY_TO_MANY).

| Field | Type | Notes |
|---|---|---|
| `candidate` | RELATION (MANY_TO_ONE → Candidate) | Reverse on Candidate: `Skills`. |
| `skillTag` | RELATION (MANY_TO_ONE → SkillTag) | Reverse on SkillTag: `Candidates`. |
| `weight` | NUMBER | 0.0–1.0; float. Confidence the skill applies. |
| `source` | SELECT | Options: `CV_PARSE`, `SCREENING`, `MANUAL`. |

### `Holiday`

Mirrored from Google Calendar by a daily sync. See `docs/03-integrations/google-calendar.md`. `skipNameField: true`.

| Field | Type | Notes |
|---|---|---|
| `date` | DATE | |
| `name` | TEXT | E.g. "Independence Day". |
| `source` | SELECT | Options: `GOOGLE`, `MANUAL_OVERRIDE`. |
| `isActive` | BOOLEAN | Default: true. |

### `ReviewTask`

The Orchestrator's inbox. `skipNameField: true`.

`subject` is polymorphic — a review task can be about a Candidate or an Application. v2 ships `MORPH_RELATION` for this case but we deliberately use **two optional `MANY_TO_ONE` fields** (per ADR-0005) for reversibility and consumer-side simplicity. The invariant "exactly one of `subjectCandidate` / `subjectApplication` is set" is enforced in n8n on every write path — see `.claude/rules/n8n-workflows.md` rule #11.

| Field | Type | Notes |
|---|---|---|
| `kind` | SELECT | Options: `LOW_CONFIDENCE_SCORE`, `VOICE_NOTE_MANUAL_REVIEW`, `COMPLIANCE_FLAG`, `WORKFLOW_ERROR`, `OTHER`. |
| `subjectCandidate` | RELATION (MANY_TO_ONE → Candidate, nullable) | Set when the subject is a Candidate. |
| `subjectApplication` | RELATION (MANY_TO_ONE → Application, nullable) | Set when the subject is an Application. |
| `dueBy` | DATE_TIME | |
| `resolvedAt` | DATE_TIME | |
| `resolution` | TEXT | |

### `SocialPost`

A record of each outbound social post. `skipNameField: true`.

| Field | Type | Notes |
|---|---|---|
| `jobPosting` | RELATION (MANY_TO_ONE → JobPosting, nullable) | Optional — some posts are general, not specific to a job posting. |
| `body` | RICH_TEXT | |
| `platform` | SELECT | Options: `FACEBOOK`, `INSTAGRAM`, `X`, `TELEGRAM`. |
| `scheduledFor` | DATE_TIME | |
| `publishedAt` | DATE_TIME | |
| `externalPostId` | TEXT | The platform's post ID. Indexed. |
| `engagementSnapshot` | RAW_JSON | Likes, replies, reach — sampled. |

### `WorkflowError`

Operator-facing record of workflow errors. `skipNameField: true`.

**Duality with bookings DB.** Per CLAUDE.md invariant #1 and `.claude/rules/n8n-workflows.md` rule #1, every n8n workflow error writes first to `bookings_db.workflow_errors` (the canonical, hot-path log; this is what Workflow A's error trigger and every other workflow's error branch hit). The Twenty `WorkflowError` object is a **mirrored projection** maintained by Workflow G (orchestration) for the operator UI — Workflow G periodically pulls unacknowledged rows from `bookings_db.workflow_errors` and creates corresponding Twenty objects so the operator can triage in the Twenty UI. The Twenty side is read-mostly; n8n workflows themselves never write here directly.

| Field | Type | Notes |
|---|---|---|
| `workflowName` | TEXT | Indexed. |
| `executionId` | TEXT | n8n execution ID. |
| `errorMessage` | TEXT | |
| `errorContext` | RAW_JSON | |
| `occurredAt` | DATE_TIME | |
| `acknowledgedAt` | DATE_TIME | When the operator marked it handled in the Twenty UI. Workflow G mirrors this back to `bookings_db.workflow_errors.acknowledged_at`. |

---

## n8n-maintained fields (no Twenty rollups)

Twenty does not support formula fields or rollups natively. Any computed field is maintained by a scheduled n8n workflow.

| Field (on) | Source | Updated by |
|---|---|---|
| `Candidate.lastActivityAt` | max of Application.updatedAt + WhatsApp inbound timestamp | Workflow A on every inbound; nightly sweep covers gaps |
| `Application.reEngagementEligible` | rules above (status + notSelectedReason) | Computed on status change |
| `JobPosting.applicationCount` | COUNT(Application WHERE jobPosting = this) | Nightly sweep |
| `Company.openJobPostingCount` | COUNT(JobPosting WHERE client = this AND status = 'OPEN') | Nightly sweep |

Do not be tempted to add a "just this one" formula field. Either it goes here, or the `schema-designer` subagent declines the change.

---

## Schema management

Custom objects are defined as versioned JSON migration files under `twenty-schema/migrations/V*.json` and applied by `scripts/apply-twenty-schema.sh`. The script is idempotent and tracks applied versions in the bookings DB. See [`twenty-schema/README.md`](../../twenty-schema/README.md) for the script contract: file shape, conflict handling, tracking-table schema, and operating mode.

Schema changes follow the same flow as code changes: open a plan, get architect review, apply in a staging Twenty first, then production. Field deletions and renames go through manual review per the rules in that README.
