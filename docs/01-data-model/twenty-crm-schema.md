# Twenty CRM — Schema & Custom Objects

All candidate, company, job, and interview data lives in Twenty. This doc is the contract between our workflows and the CRM schema.

## Invariant: access Twenty via GraphQL only

We do not make direct SQL calls into Twenty's Postgres. Every read and write uses Twenty's GraphQL API with a service-account token. See `docs/03-integrations/` for the client pattern (TODO: add if needed).

Reasons:

1. Twenty's schema changes between releases; direct SQL breaks silently when columns move or rename.
2. Twenty enforces validation, hooks, and audit logs at the API layer. Direct SQL bypasses all of them.
3. The separate n8n-owned bookings DB (`docs/01-data-model/bookings-db.md`) handles any hot-path write that would otherwise tempt us into direct SQL.

## Custom objects

Twenty ships with Companies and People as built-ins. We add the following:

### `Candidate` (extends `Person`)

A person the firm has evaluated or communicated with as a potential hire.

Custom fields on top of the built-in Person fields:

| Field | Type | Purpose |
|---|---|---|
| `whatsappNumber` | PHONE | Normalised E.164 form. Unique. |
| `preferredLanguage` | SELECT | English, Pidgin, Twi, Ga, Ewe, Dagbani, Other |
| `consentStatus` | SELECT | pending, granted, refused, revoked |
| `consentGrantedAt` | DATE_TIME | When YES was received |
| `strengthTier` | SELECT | top20, solid, developing, not_a_fit — set by `b-white-collar` or `c-blue-collar` |
| `strengthTierReason` | TEXT | Human-readable rationale |
| `lastActivityAt` | DATE_TIME | Updated by n8n on any interaction; used for retention |
| `dataRetentionPolicy` | SELECT | default_24mo, extended_consent, pending_deletion |
| `manualReviewFlag` | BOOLEAN | Orchestrator's attention required |
| `manualReviewReason` | TEXT | Why |

### `Job` (new)

A role the firm is recruiting for, on behalf of a Company.

| Field | Type |
|---|---|
| `title` | TEXT |
| `client` | RELATION → Company |
| `category` | SELECT (aligned with `SkillTag` categories) |
| `seniority` | SELECT (entry, mid, senior, lead) |
| `status` | SELECT (draft, open, shortlisting, closed, filled, cancelled) |
| `headcount` | NUMBER |
| `postedAt` | DATE_TIME |
| `closedAt` | DATE_TIME |
| `description` | RICH_TEXT |
| `requirements` | RICH_TEXT |
| `salaryMinGhs` | CURRENCY |
| `salaryMaxGhs` | CURRENCY |
| `location` | TEXT (free-form, usually city or "Remote") |
| `collarType` | SELECT (blue, white) — routes to workflow B or C |

### `Application` (new)

The join between a Candidate and a Job.

| Field | Type |
|---|---|
| `candidate` | RELATION → Candidate |
| `job` | RELATION → Job |
| `status` | SELECT (received, screening, screened, shortlisted, interviewing, offered, placed, not_selected, withdrawn) |
| `score` | NUMBER (0–100) |
| `scoreBreakdown` | JSON (per-criterion detail) |
| `notSelectedReason` | SELECT (position_filled, not_a_match, candidate_withdrew, other) |
| `reEngagementEligible` | BOOLEAN — true when `status=not_selected AND notSelectedReason=position_filled` |
| `reEngagedAt` | DATE_TIME — set by workflow H |
| `submittedToClientAt` | DATE_TIME |

### `Interview` (new)

A scheduled interview slot.

| Field | Type |
|---|---|
| `application` | RELATION → Application |
| `scheduledAt` | DATE_TIME |
| `interviewer` | RELATION → User |
| `location` | TEXT (or "Online — link below") |
| `meetingLink` | URL |
| `status` | SELECT (proposed, confirmed, completed, no_show, rescheduled, cancelled) |
| `bookingId` | TEXT — foreign key into the bookings DB |
| `outcomeNote` | RICH_TEXT |

### `SkillTag` (new)

Structured tags used by workflow H (job alerts) to match candidates to similar new roles.

| Field | Type |
|---|---|
| `name` | TEXT (unique) |
| `category` | SELECT (e.g. frontend, backend, data, logistics, security, hospitality, admin, etc.) |
| `aliases` | TEXT[] (so "FE developer" matches "Frontend") |

### `CandidateSkillTag` (new, join)

Many-to-many between Candidate and SkillTag, with a weight.

| Field | Type |
|---|---|
| `candidate` | RELATION → Candidate |
| `skillTag` | RELATION → SkillTag |
| `weight` | NUMBER (0.0–1.0) — confidence the skill applies |
| `source` | SELECT (cv_parse, screening, manual) |

### `Holiday` (new)

Mirrored from Google Calendar by a daily sync. See `docs/03-integrations/google-calendar.md`.

| Field | Type |
|---|---|
| `date` | DATE |
| `name` | TEXT |
| `source` | SELECT (google, manual_override) |
| `isActive` | BOOLEAN |

### `ReviewTask` (new)

The Orchestrator's inbox.

| Field | Type |
|---|---|
| `kind` | SELECT (low_confidence_score, voice_note_manual_review, compliance_flag, workflow_error, other) |
| `subject` | RELATION → Candidate or Application |
| `dueBy` | DATE_TIME |
| `resolvedAt` | DATE_TIME |
| `resolution` | TEXT |

### `SocialPost` (new)

A record of each outbound social post.

| Field | Type |
|---|---|
| `job` | RELATION → Job (optional) |
| `body` | RICH_TEXT |
| `platform` | SELECT (facebook, instagram, x, telegram) |
| `scheduledFor` | DATE_TIME |
| `publishedAt` | DATE_TIME |
| `externalPostId` | TEXT |
| `engagementSnapshot` | JSON (likes, replies, reach — sampled) |

### `WorkflowError` (new)

Every n8n workflow that hits its error branch writes here.

| Field | Type |
|---|---|
| `workflowName` | TEXT |
| `executionId` | TEXT |
| `errorMessage` | TEXT |
| `errorContext` | JSON |
| `occurredAt` | DATE_TIME |
| `acknowledgedAt` | DATE_TIME |

## n8n-maintained fields (no Twenty rollups)

Twenty does not support formula fields or rollups natively. Any computed field is maintained by a scheduled n8n workflow. The current set:

| Field (on) | Source | Updated by |
|---|---|---|
| `Candidate.lastActivityAt` | max of Application.updatedAt + WhatsApp inbound | Workflow A on every inbound; nightly sweep |
| `Application.reEngagementEligible` | rules above | Computed on status change |
| `Job.applicationCount` | COUNT(Application WHERE job = this) | Nightly sweep |
| `Company.openJobCount` | COUNT(Job WHERE client = this AND status = 'open') | Nightly sweep |

Do not be tempted to add a "just this one" formula field. Either it goes here, or the `schema-designer` subagent declines the change.

## Defining objects as code

Custom objects are defined in `twenty-schema/objects/*.ts` using `twenty-sdk/define`. See `twenty-schema/README.md` for the apply process.

Schema changes follow the same flow as code changes: open a plan, get architect review, apply in a staging Twenty first, then production.
